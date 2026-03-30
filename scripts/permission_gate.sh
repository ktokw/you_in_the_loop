#!/bin/bash
# you_in_the_loop — Permission Gate
# Claude Code PermissionRequest hook: 모든 세션에서 실행됨
# 안전한 작업은 자동 허가, 위험한 작업은 AR Manager에 에스컬레이션
#
# 설치 방법:
#   ~/.claude/settings.json 의 hooks.PermissionRequest 에 이 스크립트 경로 등록
#   예: "hooks": { "PermissionRequest": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/you_in_the_loop/scripts/permission_gate.sh" }] }] }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

LOG_FILE="$PERM_DIR/gate.log"
mkdir -p "$PERM_DIR"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

# Worker 식별: 현재 tmux 창 이름
WORKER_ID=$(tmux display-message -p '#{session_name}:#{window_name}' 2>/dev/null || echo "unknown")

INPUT=$(cat)

# temp 파일 방식으로 single-quote 취약점 방지
TMPFILE=$(mktemp /tmp/pgate_XXXXXX.json)
echo "$INPUT" > "$TMPFILE"

TOOL_NAME=$(python3 - <<PYEOF 2>/dev/null || echo ""
import json
with open("$TMPFILE") as f:
    d = json.load(f)
print(d.get("tool_name", ""))
PYEOF
)

CMD=$(python3 - <<PYEOF 2>/dev/null || echo ""
import json
with open("$TMPFILE") as f:
    d = json.load(f)
ti = d.get("tool_input", {})
if isinstance(ti, dict):
    print(ti.get("command", ""))
PYEOF
)

# TODO: worker_status.yaml 경로에서 현재 작업 조회
CURRENT_TASK=$(python3 - <<PYEOF 2>/dev/null || echo "unknown"
import os
worker_id = "$WORKER_ID"
worker_name = worker_id.split(":")[-1] if ":" in worker_id else worker_id
status_file = os.path.expanduser("$STATUS_FILE")
try:
    import yaml
    with open(status_file) as f:
        data = yaml.safe_load(f)
    for w in data.get("workers", []):
        if w.get("name") == worker_name or w.get("window") == worker_id:
            task = w.get("current_task")
            print(task if task else "unknown")
            raise SystemExit(0)
    print("unknown")
except SystemExit:
    pass
except Exception:
    print("unknown")
PYEOF
)

log() {
  echo "[$TIMESTAMP] [worker:$WORKER_ID] [task:$CURRENT_TASK] [$TOOL_NAME] $1" >> "$LOG_FILE"
}

allow() {
  log "ALLOW | $1"
  rm -f "$TMPFILE"
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"allow"}}'
  exit 0
}

escalate() {
  local REASON="$1"
  local REQ_ID="req_$(date +%s%3N)"
  local REQ_FILE="$PERM_DIR/${REQ_ID}.json"
  log "ESCALATE | $REASON"

  python3 - <<PYEOF 2>/dev/null || cp "$TMPFILE" "$REQ_FILE"
import json
with open("$TMPFILE") as f:
    data = json.load(f)
data["reason"] = "$REASON"
data["timestamp"] = "$TIMESTAMP"
data["req_id"] = "$REQ_ID"
data["worker_id"] = "$WORKER_ID"
data["status"] = "pending"
with open("$REQ_FILE", "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

  rm -f "$TMPFILE"

  MSG="[PERMISSION ESCALATION] $REASON | worker: $WORKER_ID | req: $REQ_ID"
  tmux send-keys -t "$AR_WINDOW" "$MSG" 2>/dev/null || \
  tmux send-keys -t "$AR_FALLBACK" "$MSG" 2>/dev/null || true

  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"ask"}}'
  exit 0
}

# ── 1. 읽기 전용 도구 → 항상 허가
if [[ "$TOOL_NAME" =~ ^(Read|Glob|Grep|WebFetch|WebSearch)$ ]]; then
  allow "read-only tool"
fi

# ── 2. 파일 쓰기/편집 → 항상 허가 (AR Manager 사전 위임)
if [[ "$TOOL_NAME" =~ ^(Write|Edit|NotebookEdit)$ ]]; then
  allow "file write — pre-delegated"
fi

# ── 3. Bash 판단
if [[ "$TOOL_NAME" == "Bash" ]]; then

  # 3-a. rm 명령 (직접 rm + find/xargs 우회 패턴)
  if echo "$CMD" | grep -qE "(^|\s|;|&&|\|\|)\s*rm\s" || \
     echo "$CMD" | grep -qE "\-exec\s+rm\s" || \
     echo "$CMD" | grep -qE "xargs\s+(rm|unlink)"; then
    # 임시/생성 파일 → 허가
    if echo "$CMD" | grep -qE "(\.tmp|\.log|\.pyc|__pycache__|\.DS_Store|/tmp/|dist/|build/|\.egg-info|\.cache|node_modules/.cache)"; then
      allow "rm temp/generated file"
    fi
    escalate "rm on potentially important file: $CMD"
  fi

  # 3-b. 유료 API / 결제 관련
  # TODO: 프로젝트에 맞게 추가 패턴을 여기에 추가하세요
  if echo "$CMD" | grep -qiE "(stripe\.|paypal\.|twilio\.|sendgrid\.|billing|charge[^r]|purchase|checkout)"; then
    escalate "potential paid API/service: $CMD"
  fi

  # 3-c. 패키지 설치 → 허가 (의심 패키지 제외)
  if echo "$CMD" | grep -qE "(npm install|pip install|pip3 install|yarn add|pnpm add)"; then
    PKG=$(echo "$CMD" | grep -oE "(npm install|pip install|pip3 install|yarn add|pnpm add)\s+\S+" | awk '{print $NF}')
    # TODO: 의심 패키지 목록을 프로젝트에 맞게 확장하세요
    if echo "$PKG" | grep -qiE "^(os-extra|subprocess2|sys-utils|builtins-plus|eval-pkg|socket-helper)$"; then
      escalate "suspicious package: $PKG"
    fi
    allow "package install: $PKG"
  fi

  # 3-d. 위험 시스템 명령
  if echo "$CMD" | grep -qE "^(sudo\s|su\s|mkfs|fdisk|diskutil\s+erase|format\s)"; then
    escalate "dangerous system command: $CMD"
  fi

  # 3-e. 나머지 Bash → 허가
  allow "bash — pre-delegated"
fi

# ── 4. 기타 도구 → 허가
rm -f "$TMPFILE"
allow "other tool"

#!/bin/bash
# ============================================================
# you_in_the_loop — 한 번 실행 설치 스크립트
#
# 사용법: bash scripts/install.sh
#
# 포함:
#   1. 디렉토리 구조 생성
#   2. crontab 등록 (dispatch_router, watch_signals, org_snapshot, daily_report)
#   3. ~/.claude/settings.json permission_gate 훅 등록 (기존 있으면 merge)
#   4. tmux 세션/창 구조 생성 (secretary + ar-manager + worker 6개)
#   5. 01_origin/ skeleton 파일 초기화
#
# idempotent: 이미 설치된 경우 중복 실행해도 안전
# 요구: macOS/Linux, tmux, claude CLI 설치 완료
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$SCRIPT_DIR")"

# config.sh 로드
if [ ! -f "$SCRIPT_DIR/config.sh" ]; then
    echo "[ERROR] scripts/config.sh 없음. 레포가 올바르게 클론됐는지 확인하세요."
    exit 1
fi
source "$SCRIPT_DIR/config.sh"

echo "=============================================="
echo " you_in_the_loop 설치 시작"
echo " BASE: $BASE"
echo " TMUX_SESSION: $TMUX_SESSION"
echo "=============================================="
echo ""

# ── 1. 디렉토리 구조 생성 ──────────────────────────
echo "[1/6] 디렉토리 구조 생성..."
mkdir -p "$BASE/context_logs"
mkdir -p "$BASE/ar_signal_queue"
mkdir -p "$BASE/dispatch_inbox"
mkdir -p "$BASE/permission_queue"
mkdir -p "$BASE/tasks"
mkdir -p "$BASE/01_origin/self_state/roles"
mkdir -p "$BASE/01_origin/self_state/core/iframe"
mkdir -p "$BASE/01_origin/self_state/core/identity_delta"
mkdir -p "$BASE/01_origin/self_state/calibration"
echo "  완료."

# ── 2. skeleton → 01_origin/self_state 초기화 ──────
echo "[2/6] 01_origin skeleton 초기화..."

SKELETON_DIR="$BASE/01_origin/skeleton"

copy_if_missing() {
    local src="$1"
    local dst="$2"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        echo "  복사: $(basename "$src")"
    elif [ -f "$dst" ]; then
        echo "  이미 있음: $(basename "$dst") (생략)"
    else
        echo "  [WARN] 소스 없음: $src"
    fi
}

copy_if_missing "$SKELETON_DIR/core/iframe/v001.yaml" \
                "$BASE/01_origin/self_state/core/iframe/v001.yaml"
copy_if_missing "$SKELETON_DIR/roles/secretary.yaml" \
                "$BASE/01_origin/self_state/roles/secretary.yaml"
copy_if_missing "$SKELETON_DIR/roles/ar-manager.yaml" \
                "$BASE/01_origin/self_state/roles/ar-manager.yaml"

# _registry.yaml 자동 생성 (없는 경우)
REGISTRY="$BASE/01_origin/self_state/roles/_registry.yaml"
if [ ! -f "$REGISTRY" ]; then
    cat > "$REGISTRY" << 'YAML'
# ============================================================
# Role Registry — 전체 역할 목록 및 상태
# ============================================================
# 역할 생성 원칙: 빈 의자를 만들지 않는다 (실적 없는 역할 생성 금지)
# ============================================================

schema_version: "001"

roles:
  - id: "secretary"
    file: "secretary.yaml"
    type: "strategic"
    status: "active"
    sessions: 0
    last_active: null

  - id: "ar-manager"
    file: "ar-manager.yaml"
    type: "meta"
    status: "active"
    sessions: 0
    last_active: null

# 향후 추가할 Worker 역할은 아래에 등록하세요
# 예:
#  - id: "worker-vibe"
#    file: "worker-vibe.yaml"
#    type: "operational"
#    status: "active"
#    sessions: 0
#    last_active: null

stances: []

ensemble_protocol:
  levels:
    light: "position만 (빠른 관점 수집)"
    full: "position → cross → synthesis (완전 토론)"
  trigger: "의사결정이 필요하고, 활성 stance가 2개 이상이거나 TSO가 요청할 때"
  record: "ensemble/ 디렉토리에 기록"
YAML
    echo "  생성: _registry.yaml"
fi

echo "  완료."

# ── 3. crontab 등록 ───────────────────────────────
echo "[3/6] crontab 등록..."

# PATH 포함 필수 — brew 설치 바이너리 인식용
CRON_PATH="PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CRON_DISPATCH="* * * * * $CRON_PATH $BASE/scripts/dispatch_router.sh >> $BASE/context_logs/dispatch_router.log 2>&1"
CRON_WATCH="*/2 * * * * $CRON_PATH $BASE/scripts/watch_signals.sh >> $BASE/context_logs/watch_signals.log 2>&1"
CRON_SNAPSHOT="*/10 * * * * $CRON_PATH $BASE/scripts/org_snapshot.sh >> $BASE/context_logs/org_snapshot.log 2>&1"
CRON_DAILY="0 9 * * * $CRON_PATH $BASE/scripts/daily_report.sh >> $BASE/context_logs/daily_report.log 2>&1"

CURRENT_CRONTAB=$(crontab -l 2>/dev/null || echo "")
NEW_CRONTAB="$CURRENT_CRONTAB"
CHANGED=0

for ENTRY in \
    "dispatch_router.sh|$CRON_DISPATCH" \
    "watch_signals.sh|$CRON_WATCH" \
    "org_snapshot.sh|$CRON_SNAPSHOT" \
    "daily_report.sh|$CRON_DAILY"
do
    SCRIPT_NAME="${ENTRY%%|*}"
    CRON_LINE="${ENTRY#*|}"
    if ! echo "$CURRENT_CRONTAB" | grep -q "$SCRIPT_NAME"; then
        NEW_CRONTAB="$NEW_CRONTAB"$'\n'"$CRON_LINE"
        echo "  추가: $SCRIPT_NAME"
        CHANGED=1
    else
        echo "  이미 있음: $SCRIPT_NAME (생략)"
    fi
done

if [ "$CHANGED" = "1" ]; then
    echo "$NEW_CRONTAB" | crontab -
    echo "  crontab 업데이트 완료."
else
    echo "  crontab 변경 없음."
fi

# ── 4. permission_gate 훅 등록 ────────────────────
echo "[4/6] permission_gate 훅 등록..."

SETTINGS_FILE="$HOME/.claude/settings.json"
GATE_CMD="$BASE/scripts/permission_gate.sh"
mkdir -p "$HOME/.claude"

if [ ! -f "$SETTINGS_FILE" ]; then
    # 신규 생성
    python3 - <<PYEOF
import json

gate_cmd = "$GATE_CMD"
settings = {
    "hooks": {
        "PermissionRequest": [
            {
                "matcher": "",
                "hooks": [{"type": "command", "command": gate_cmd}]
            }
        ]
    }
}
with open("$SETTINGS_FILE", "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYEOF
    echo "  settings.json 신규 생성 완료"
elif ! grep -q "permission_gate" "$SETTINGS_FILE" 2>/dev/null; then
    # 기존 파일에 훅 merge
    python3 - <<PYEOF
import json, sys

settings_file = "$SETTINGS_FILE"
gate_cmd = "$GATE_CMD"

try:
    with open(settings_file) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

hooks = settings.setdefault("hooks", {})
perm_requests = hooks.setdefault("PermissionRequest", [])

new_hook = {
    "matcher": "",
    "hooks": [{"type": "command", "command": gate_cmd}]
}
# 동일 command 중복 방지
existing_cmds = [
    h.get("command") for entry in perm_requests
    for h in entry.get("hooks", [])
]
if gate_cmd not in existing_cmds:
    perm_requests.append(new_hook)
    with open(settings_file, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    print("  settings.json 훅 merge 완료")
else:
    print("  permission_gate 이미 있음 (생략)")
PYEOF
else
    echo "  permission_gate 이미 등록됨 (생략)"
fi

# ── 5. 스크립트 실행 권한 ──────────────────────────
echo "[5/6] 스크립트 실행 권한 설정..."
chmod +x "$BASE/scripts/"*.sh
echo "  완료."

# ── 6. tmux 세션/창 구조 생성 ─────────────────────
echo "[6/6] tmux 세션 초기화..."

if ! command -v tmux &>/dev/null; then
    echo "  [WARN] tmux 미설치. tmux 설치 후 수동으로 세션을 생성하세요:"
    echo "    tmux new-session -s $TMUX_SESSION -n secretary"
else
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        # secretary 창 (Window 0)
        tmux new-session -d -s "$TMUX_SESSION" -n "secretary" -c "$BASE"
        # ar-manager 창 (Window 1)
        tmux new-window -t "$TMUX_SESSION" -n "ar-manager" -c "$BASE"
        # worker 창 6개 (Window 2~7)
        for WORKER in worker-1 worker-2 worker-3 worker-4 worker-5 worker-6; do
            tmux new-window -t "$TMUX_SESSION" -n "$WORKER" -c "$BASE"
        done
        # secretary로 포커스
        tmux select-window -t "$TMUX_SESSION:secretary"
        echo "  tmux 세션 '$TMUX_SESSION' 생성 완료"
        echo "  창 구성: secretary, ar-manager, worker-1~6"
    else
        echo "  tmux 세션 '$TMUX_SESSION' 이미 있음 (생략)"
    fi
fi

# ── 완료 ──────────────────────────────────────────
echo ""
echo "=============================================="
echo " 설치 완료. secretary 창에서 claude를 시작하세요."
echo "=============================================="
echo ""
echo "  1. tmux attach -t $TMUX_SESSION"
echo "     └─ 이미 tmux 안이면 생략"
echo ""
echo "  2. Ctrl+B 0  →  secretary 창"
echo "     claude    ←  입력 후 엔터"
echo ""
echo "  3. [부팅 완료] 블록이 나오면 준비 완료!"
echo ""
echo "  다음 단계: docs/02_first-session.md 참고"
echo ""

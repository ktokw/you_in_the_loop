#!/bin/bash
# you_in_the_loop — Dispatch Router
# dispatch_inbox/disp_*.yaml (status: pending) 감지 → Worker tmux 창에 자동 전달
#
# 설정 방법: scripts/config.sh 편집
# crontab 등록: * * * * * ~/you_in_the_loop/scripts/dispatch_router.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

LOG_FILE="$LOG_DIR/dispatch_router.log"
mkdir -p "$LOG_DIR"

timestamp() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }

# pending 파일 목록 (생성 시간 오름차순 — FIFO)
PENDING_FILES=$(python3 - <<PYEOF 2>/dev/null
import glob, yaml, os

inbox = "$INBOX_DIR"
files = sorted(glob.glob(f"{inbox}/disp_*.yaml"))
for f in files:
    try:
        with open(f) as fh:
            d = yaml.safe_load(fh)
        if d.get("status") == "pending":
            print(f)
    except Exception:
        pass
PYEOF
)

if [ -z "$PENDING_FILES" ]; then
  exit 0
fi

# worker 이름 → tmux window 인덱스/이름 매핑
get_window() {
  local TARGET="$1"
  python3 - <<PYEOF 2>/dev/null || echo ""
import yaml

target = "$TARGET"
result = target  # fallback: worker 이름 = 창 이름
try:
    with open("$STATUS_FILE") as f:
        data = yaml.safe_load(f)
    for w in data.get("workers", []):
        if w.get("name") == target:
            window = w.get("window", "")
            result = window.split(":", 1)[-1] if ":" in window else window
            break
except Exception:
    pass

print(result)
PYEOF
}

update_status() {
  local FILE="$1"
  local NEW_STATUS="$2"
  local DELIVERED_AT="$3"
  python3 - <<PYEOF 2>/dev/null
import yaml

with open("$FILE") as f:
    d = yaml.safe_load(f)
d["status"] = "$NEW_STATUS"
if "$DELIVERED_AT":
    d["delivered_at"] = "$DELIVERED_AT"
with open("$FILE", "w") as f:
    yaml.dump(d, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
PYEOF
}

while IFS= read -r DISP_FILE; do
  [ -z "$DISP_FILE" ] && continue

  EXTRACT_DIR=$(mktemp -d /tmp/disp_extract_XXXXXX)
  python3 - <<PYEOF 2>/dev/null
import yaml, os

with open("$DISP_FILE") as f:
    d = yaml.safe_load(f)

extract_dir = "$EXTRACT_DIR"
with open(os.path.join(extract_dir, "id"),     "w") as f: f.write(d.get("id", "unknown"))
with open(os.path.join(extract_dir, "target"), "w") as f: f.write(d.get("target", ""))
with open(os.path.join(extract_dir, "packet"), "w") as f: f.write(d.get("packet", ""))
PYEOF

  DISP_ID=$(cat "$EXTRACT_DIR/id" 2>/dev/null)
  DISP_TARGET=$(cat "$EXTRACT_DIR/target" 2>/dev/null)
  DISP_PACKET=$(cat "$EXTRACT_DIR/packet" 2>/dev/null)
  rm -rf "$EXTRACT_DIR"

  if [ -z "$DISP_TARGET" ]; then
    log "SKIP $(basename $DISP_FILE) — target 없음"
    continue
  fi

  WINDOW=$(get_window "$DISP_TARGET")
  if [ -z "$WINDOW" ]; then
    log "SKIP $DISP_ID — worker '$DISP_TARGET' window 매핑 실패"
    continue
  fi

  if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}:#{window_name}' 2>/dev/null \
      | grep -qE "^${WINDOW}:|:${WINDOW}$"; then
    log "SKIP $DISP_ID → $DISP_TARGET (${TMUX_SESSION}:${WINDOW}) — 창 없음"
    continue
  fi

  # 멀티라인 패킷 전달
  TMPBUF=$(mktemp /tmp/dispatch_XXXXXX.txt)
  printf '%s' "$DISP_PACKET" > "$TMPBUF"
  tmux load-buffer "$TMPBUF"
  tmux paste-buffer -t "${TMUX_SESSION}:${WINDOW}"
  tmux send-keys -t "${TMUX_SESSION}:${WINDOW}" "" Enter
  rm -f "$TMPBUF"

  DELIVERED_AT=$(timestamp)
  update_status "$DISP_FILE" "delivered" "$DELIVERED_AT"

  log "DELIVERED $DISP_ID → $DISP_TARGET (${TMUX_SESSION}:${WINDOW})"

done <<< "$PENDING_FILES"

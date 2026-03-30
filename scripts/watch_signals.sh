#!/bin/bash
# you_in_the_loop — Watch Signals
# AR Manager 자율 감지 루프: ar_signal_queue/ + dispatch_inbox/ pending 파일 → AR Manager 알림
#
# 설정 방법: scripts/config.sh 편집
# crontab 등록: */2 * * * * ~/you_in_the_loop/scripts/watch_signals.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

NOTIFIED_LOG="$LOG_DIR/watch_signals_notified.log"
LOG_FILE="$LOG_DIR/watch_signals.log"

mkdir -p "$LOG_DIR"
touch "$NOTIFIED_LOG"

timestamp() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(timestamp)] $*" >> "$LOG_FILE"; }

# tmux 세션 없으면 조용히 종료
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  log "SKIP — tmux session '$TMUX_SESSION' 없음"
  exit 0
fi

# AR Manager 창 알림 함수
notify_ar() {
  local MSG="$1"
  tmux send-keys -t "$AR_WINDOW" "$MSG" Enter 2>/dev/null || \
  tmux send-keys -t "$AR_FALLBACK" "$MSG" Enter 2>/dev/null || \
  log "WARN — AR Manager 창 없음. 미전달: $MSG"
}

already_notified() {
  grep -qxF "$1" "$NOTIFIED_LOG" 2>/dev/null
}

mark_notified() {
  echo "$1" >> "$NOTIFIED_LOG"
}

cleanup_notified() {
  python3 - <<PYEOF 2>/dev/null
import yaml, os

notified_log = "$NOTIFIED_LOG"
signal_dir   = "$SIGNAL_DIR"
inbox_dir    = "$INBOX_DIR"

try:
    with open(notified_log) as f:
        entries = [l.strip() for l in f if l.strip()]
except FileNotFoundError:
    entries = []

active = []
for fname in entries:
    for search_dir in [signal_dir, inbox_dir]:
        fpath = os.path.join(search_dir, fname)
        if os.path.exists(fpath):
            try:
                with open(fpath) as f:
                    d = yaml.safe_load(f)
                if d.get("status") == "pending":
                    active.append(fname)
            except Exception:
                pass
            break

with open(notified_log, "w") as f:
    f.write("\n".join(active) + ("\n" if active else ""))
PYEOF
}

PENDING_TMP=$(mktemp /tmp/watch_signals_XXXXXX.tsv)
NEW_COUNT=0

python3 -c "
import yaml, os, glob, sys

dirs = [('$SIGNAL_DIR', 'sig_*.yaml'), ('$INBOX_DIR', 'disp_*.yaml')]
for d, pattern in dirs:
    for fpath in sorted(glob.glob(os.path.join(d, pattern))):
        try:
            with open(fpath) as f:
                data = yaml.safe_load(f)
            if data.get('status') == 'pending':
                fname    = os.path.basename(fpath)
                summary  = (data.get('summary') or data.get('title') or data.get('id') or fname)[:80]
                sig_type = data.get('type', 'dispatch')
                priority = data.get('priority', '')
                label    = sig_type + '[' + priority + ']' if priority else sig_type
                sys.stdout.write(fname + '\t' + label + '\t' + summary + '\n')
        except Exception:
            pass
" > "$PENDING_TMP" 2>/dev/null

while IFS=$'\t' read -r FNAME TYPE SUMMARY; do
  [ -z "$FNAME" ] && continue
  if already_notified "$FNAME"; then
    continue
  fi
  MSG="[SIGNAL] ${FNAME} (${TYPE}) — ${SUMMARY}"
  notify_ar "$MSG"
  mark_notified "$FNAME"
  log "NOTIFY → $AR_WINDOW | $MSG"
  NEW_COUNT=$((NEW_COUNT + 1))
done < "$PENDING_TMP"
rm -f "$PENDING_TMP"

cleanup_notified

if [ "$NEW_COUNT" -gt 0 ]; then
  log "DONE — ${NEW_COUNT}건 새 신호 알림 전송"
fi

#!/bin/bash
# you_in_the_loop — Org Snapshot
# tmux 전 창 상태 수집 → tasks/org_health_snapshot.yaml
#
# 설정 방법: scripts/config.sh 편집
# crontab 등록: */10 * * * * ~/you_in_the_loop/scripts/org_snapshot.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

SNAPSHOT="$BASE/tasks/org_health_snapshot.yaml"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "[org_snapshot] tmux session '$TMUX_SESSION' 없음. 종료." >&2
  exit 1
fi

WINDOWS=$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}:#{window_name}' 2>/dev/null)

python3 - <<PYEOF
import subprocess, re, yaml, sys
from datetime import datetime

session   = "$TMUX_SESSION"
timestamp = "$TIMESTAMP"

raw_windows = """$WINDOWS""".strip().splitlines()
workers = []

for line in raw_windows:
    if not line.strip():
        continue
    idx, name = line.split(":", 1)
    idx  = idx.strip()
    name = name.strip().rstrip("*-").strip()

    try:
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", f"{session}:{idx}", "-p"],
            capture_output=True, text=True, timeout=3
        )
        pane_text = result.stdout
    except Exception:
        pane_text = ""

    lines = [l for l in pane_text.splitlines() if l.strip()]
    last_line = lines[-1].strip() if lines else ""

    tail_lines = pane_text.splitlines()[-8:]
    tail_text  = "\n".join(tail_lines)

    # 상태 판단
    if re.search(r'\bYes\b.*\bNo\b|\bNo\b.*\bYes\b|\(y/n\)|Y/n|y/N', tail_text, re.IGNORECASE):
        status = "blocked"
    elif "esc to interrupt" in tail_text.lower():
        status = "working"
    elif "? for shortcuts" in tail_text or re.search(r'❯\s*$', tail_text):
        status = "idle"
    elif lines:
        status = "active"
    else:
        status = "unknown"

    # context_pct 파싱
    context_pct = None
    match = re.search(r'(\d+)\s*%\s*until\s*auto.?compact', pane_text, re.IGNORECASE)
    if match:
        context_pct = int(match.group(1))

    # 마지막 의미있는 줄
    meaningful = [
        l.strip() for l in lines
        if l.strip()
        and not re.match(r'^[─━═\-─]{5,}$', l.strip())
        and l.strip() not in ("❯", "$", ">", "%")
    ]
    last_meaningful = meaningful[-1] if meaningful else last_line

    entry = {
        "window_index": int(idx),
        "window_name":  name,
        "status":       status,
        "last_line":    last_meaningful[:120],
        "timestamp":    timestamp,
    }
    if context_pct is not None:
        entry["context_pct"] = context_pct

    workers.append(entry)

snapshot = {
    "generated_at": timestamp,
    "session":      session,
    "workers":      sorted(workers, key=lambda w: w["window_index"]),
}

with open("$SNAPSHOT", "w", encoding="utf-8") as f:
    yaml.dump(snapshot, f, allow_unicode=True, default_flow_style=False, sort_keys=False)

status_icons = {"idle": "⚪", "working": "🟢", "blocked": "🔴", "active": "🟡", "unknown": "❔"}
print(f"[org_snapshot] {timestamp}")
for w in snapshot["workers"]:
    icon = status_icons.get(w["status"], "❔")
    ctx  = f" ({w['context_pct']}% ctx)" if "context_pct" in w else ""
    print(f"  {icon} {w['window_index']}:{w['window_name']:20s} {w['status']}{ctx}")
PYEOF

#!/bin/bash
# you_in_the_loop — Daily Report
# Telegram 데일리 시스템 현황 리포트
#
# 설정 방법:
#   1. scripts/config.sh 에서 TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID 설정
#   2. crontab 등록: 0 9 * * * ~/you_in_the_loop/scripts/daily_report.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
  echo "[daily_report] ERROR: TELEGRAM_BOT_TOKEN 또는 TELEGRAM_CHAT_ID 없음." >&2
  echo "[daily_report] scripts/config.sh 에서 설정하세요." >&2
  exit 1
fi

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
NOW=$(date '+%Y-%m-%d %H:%M')
TODAY=$(date '+%Y-%m-%d')

# ── 섹션 1: Worker 현황 ──
worker_section() {
  if [ ! -f "$STATUS_FILE" ]; then
    echo "worker\\_status.yaml 없음"
    return
  fi
  python3 - <<PYEOF
import yaml, sys

with open("$STATUS_FILE") as f:
    data = yaml.safe_load(f)

workers = data.get("workers", [])
lines   = []
icons   = {"작업중": "🟢", "대기": "⚪", "블로킹": "🔴", "완료대기": "🟡", "종료": "⬛"}

for w in workers:
    name   = w.get("name", "?")
    status = w.get("status", "?")
    task   = w.get("current_task") or "-"
    icon   = icons.get(status, "❔")
    lines.append(f"{icon} {name}: {status} | {task}")

print("\n".join(lines) if lines else "Worker 없음")
PYEOF
}

# ── 섹션 2: ar_signal_queue 미처리 신호 ──
signal_section() {
  if [ ! -d "$SIGNAL_DIR" ]; then
    echo "신호 없음"
    return
  fi
  python3 - <<PYEOF
import os, yaml, glob

files   = sorted(glob.glob("$SIGNAL_DIR/sig_*.yaml"))
pending = []

for f in files:
    try:
        with open(f) as fh:
            d = yaml.safe_load(fh)
        if d.get("status") in (None, "pending"):
            sig_type     = d.get("type", "?")
            priority     = d.get("priority", "")
            summary      = d.get("summary", os.path.basename(f))
            priority_str = f" [{priority}]" if priority else ""
            pending.append(f"• [{sig_type}{priority_str}] {summary}")
    except Exception:
        pass

print("\n".join(pending) if pending else "미처리 신호 없음 ✅")
PYEOF
}

# ── 섹션 3: permission_queue 미처리 수 ──
perm_section() {
  if [ ! -d "$PERM_DIR" ]; then
    echo "0건"
    return
  fi
  PENDING=$(ls "$PERM_DIR"/*.json 2>/dev/null | grep -v "_resolved" | wc -l | tr -d ' ')
  TOTAL=$(ls "$PERM_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "$PENDING" -gt 0 ]; then
    echo "⚠️ 미처리 ${PENDING}건 (전체 ${TOTAL}건)"
  else
    echo "미처리 없음 ✅ (전체 ${TOTAL}건)"
  fi
}

# ── 섹션 4: 세션 연속성 State 파일 ──
state_section() {
  if [ ! -d "$LOG_DIR" ]; then
    echo "state 파일 없음"
    return
  fi
  python3 - <<PYEOF
import os, glob

files = sorted(glob.glob("$LOG_DIR/state_*.yaml"), reverse=True)
seen  = {}
for f in files:
    base  = os.path.basename(f)
    parts = base.replace("state_", "").replace(".yaml", "").rsplit("_", 2)
    worker = parts[0] if parts else base
    if worker not in seen:
        seen[worker] = base

if seen:
    for worker in sorted(seen):
        print(f"• {worker}: {seen[worker]}")
else:
    print("state 파일 없음 ⚠️")
PYEOF
}

# ── 메시지 조립 ──
WORKERS=$(worker_section)
SIGNALS=$(signal_section)
PERMS=$(perm_section)
STATES=$(state_section)

# TODO: 시스템 이름을 원하는 이름으로 변경하세요
SYSTEM_NAME="you_in_the_loop"

MESSAGE="🗓 *${SYSTEM_NAME} Daily — ${NOW}*

👥 *Worker 현황*
${WORKERS}

📡 *AR Signal Queue*
${SIGNALS}

🔐 *Permission Queue*
${PERMS}

💾 *세션 연속성*
${STATES}"

# ── Telegram 발송 ──
PAYLOAD=$(python3 -c "
import json
msg = '''$MESSAGE'''
payload = {
    'chat_id': '$TELEGRAM_CHAT_ID',
    'text': msg,
    'parse_mode': 'Markdown'
}
print(json.dumps(payload, ensure_ascii=False))
")

RESPONSE=$(curl -s -X POST "$TELEGRAM_API" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

OK=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ok','false'))" 2>/dev/null)
if [ "$OK" = "True" ]; then
  echo "[daily_report] $NOW — Telegram 발송 성공"
else
  echo "[daily_report] $NOW — Telegram 발송 실패: $RESPONSE" >&2
  exit 1
fi

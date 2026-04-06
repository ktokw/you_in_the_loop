#!/bin/bash
# auto_enter.sh — Worker 자동 Enter 주입
# crontab: */2 * * * * ~/you_in_the_loop/scripts/auto_enter.sh
#
# 패치 이력:
#   v2 (2026-03-31): awk YAML 파싱, capture-pane -S -50, 패턴 보강,
#                    전역 lock, 로그 제한, DRY_RUN 모드
#   v3 (2026-03-31): [보안] "Do you want to" 제거 (tool permission 자동승인 방지)
#                    [안정] "esc to cancel" 제거 (Claude 작업 중 오감지 방지)
#                    [안정] capture-pane 범위 -S -10으로 축소 (과거 텍스트 오감지 방지)

WORKER_STATUS="$HOME/you_in_the_loop/tasks/worker_status.yaml"
LOG_FILE="$HOME/you_in_the_loop/context_logs/auto_enter.log"
GLOBAL_LOCK="/tmp/auto_enter.lock"
LOCK_TTL=30       # 창별 lock TTL (초)
LOG_MAX_LINES=5000
LOG_TRIM_LINES=1000

mkdir -p "$(dirname "$LOG_FILE")"

# 전역 lock — 동시 실행 방지
if [ -f "$GLOBAL_LOCK" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$GLOBAL_LOCK" 2>/dev/null || echo 0) ))  # macOS
  if [ "$LOCK_AGE" -lt 60 ]; then
    exit 0
  fi
fi
touch "$GLOBAL_LOCK"
trap 'rm -f "$GLOBAL_LOCK"' EXIT

# 로그 파일 크기 제한 (5000줄 초과 시 앞 1000줄 삭제)
if [ -f "$LOG_FILE" ]; then
  LINE_COUNT=$(wc -l < "$LOG_FILE")
  if [ "$LINE_COUNT" -gt "$LOG_MAX_LINES" ]; then
    TMPLOG=$(mktemp)
    tail -n +"$LOG_TRIM_LINES" "$LOG_FILE" > "$TMPLOG" && mv "$TMPLOG" "$LOG_FILE"
  fi
fi

# tmux 세션 존재 확인
if ! tmux has-session -t tso 2>/dev/null; then
  exit 0
fi

# worker_status.yaml 존재 확인
if [ ! -f "$WORKER_STATUS" ]; then
  exit 0
fi

# awk 블록 파싱: status=작업중이고 name!=ar-manager 인 window 목록 추출
# 출력 형식: "window\tname"
ACTIVE_WORKERS=$(awk '
  /^  - name:/ { name=$3; gsub(/"/, "", name); window="" }
  /^    window:/ { window=$2; gsub(/"/, "", window) }
  /status:.*작업중/ && name != "ar-manager" && window != "" { print window "\t" name }
' "$WORKER_STATUS" 2>/dev/null)

if [ -z "$ACTIVE_WORKERS" ]; then
  exit 0
fi

# 감지 패턴 (grep -iE 로 대소문자 무시)
PATTERNS=(
  "Press Enter"
  # "esc to cancel" — 제거 (v3): Claude 작업 중에도 표시되어 작업 중단 위험
  "Hit enter"
  # "Do you want to" — 제거 (v3): tool permission 자동 승인 보안 위험
  # "[[(][yY]/[nN][)\]]" — 보류: 일반 y/n 선택지 자동 승인 위험
  "Continue[?？]"
  "Proceed[?？]"
  # "Are you sure" — 보류: 위험 확인 프롬프트 자동 승인 금지
  # "Confirm[?？]" — 보류: 위험 확인 프롬프트 자동 승인 금지
  "엔터"
)

while IFS=$'\t' read -r WINDOW WORKER_NAME; do
  [ -z "$WINDOW" ] && continue

  # 창 존재 여부 확인
  tmux has-session -t "$WINDOW" 2>/dev/null || continue

  # 창별 lock 파일
  WINDOW_SAFE="${WINDOW//:/_}"
  LOCK_FILE="/tmp/auto_enter_${WINDOW_SAFE}.lock"

  if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))  # macOS
    if [ "$LOCK_AGE" -lt "$LOCK_TTL" ]; then
      continue
    fi
  fi

  # 화면 캡처 (-S -10: 최근 10줄만 — 과거 텍스트 오감지 방지 v3)
  PANE_CONTENT=$(tmux capture-pane -t "$WINDOW" -p -S -10 2>/dev/null) || continue

  # 패턴 매칭
  MATCHED=""
  for PATTERN in "${PATTERNS[@]}"; do
    if echo "$PANE_CONTENT" | grep -qiE "$PATTERN"; then
      MATCHED="$PATTERN"
      break
    fi
  done

  if [ -n "$MATCHED" ]; then
    TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[$TIMESTAMP] DRY-RUN $WINDOW ($WORKER_NAME) — \"$MATCHED\" 패턴 감지 (Enter 미주입)" >> "$LOG_FILE"
    else
      tmux send-keys -t "$WINDOW" "" Enter 2>/dev/null
      touch "$LOCK_FILE"
      echo "[$TIMESTAMP] $WINDOW ($WORKER_NAME) — \"$MATCHED\" 패턴 감지 → Enter 주입" >> "$LOG_FILE"
    fi
  fi
done <<< "$ACTIVE_WORKERS"

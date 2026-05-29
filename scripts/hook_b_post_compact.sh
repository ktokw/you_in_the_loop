#!/usr/bin/env bash
# Hook B — PostCompact: compact 재시작 경량화 플래그 생성
# DISP-ENG-HOOK-B-F-001 | worker-engineer-finn | 2026-04-02
#
# 동작:
#   /compact 완료 직후 실행.
#   .compact_resume_flag 파일 생성 → 다음 부팅에서 감지 시 Step 0-4 생략.
#   부팅 완료 후 플래그 파일은 CLAUDE.md 규칙에 따라 삭제됨.

REPO="$HOME/you_in_the_loop"
FLAG_FILE="$REPO/.compact_resume_flag"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

# 현재 window 식별 (DEF-20260408-13: flag에 window 필드 추가)
WINDOW_NAME=""
WINDOW_ID=""
if [ -n "${TMUX_PANE:-}" ]; then
    WINDOW_NAME=$(tmux display-message -p -t "$TMUX_PANE" '#{window_index}:#{window_name}' 2>/dev/null || true)
    # Hook A와 동일한 session:index 형식 (state 파일명 매칭용)
    WINDOW_ID=$(tmux display-message -p -t "$TMUX_PANE" '#S:#I' 2>/dev/null || true)
fi
# DEF-20260410-13: 윈도우 필터링 — state_파일을 자기 윈도우 기준으로만 탐색
WINDOW_SAFE="${WINDOW_ID//[:/]/_}"

# 최신 state 파일 경로 탐색 (부팅 시 참조용)
LATEST_STATE=""
if [ -n "$WINDOW_SAFE" ]; then
    LATEST_STATE=$(ls -t "$REPO"/context_logs/state_"${WINDOW_SAFE}"_*.yaml 2>/dev/null | head -1 || true)
fi
# fallback: 윈도우 필터링 실패 시 전체에서 최신
if [ -z "$LATEST_STATE" ]; then
    LATEST_STATE=$(ls -t "$REPO"/context_logs/state_*.yaml 2>/dev/null | head -1 || true)
fi

cat > "$FLAG_FILE" << EOF
compact_resume: true
compacted_at: "$TIMESTAMP"
window: "${WINDOW_ID:-unknown}"
ttl_seconds: 3600
latest_state: "${LATEST_STATE:-없음}"
instruction: |
  이 파일이 존재하면 compact 직후 재개 세션임.
  부팅 시 확인 사항:
    1. window 필드가 현재 윈도우와 일치하는지 확인 → 불일치면 무시(삭제)
    2. compacted_at + ttl_seconds(1시간) 경과 시 무효 → 삭제
    3. 유효하면 CLAUDE.md compact_resume 규칙 적용
  latest_state 경로를 읽어 [HANDOFF RECEIVED] 블록 출력 후 작업 재개.
EOF

# ar_signal_queue에 compact 완료 신호 (compact_log.txt 대신 단일 파일 덮어쓰기)
SIGNAL_DIR="$REPO/ar_signal_queue"
mkdir -p "$SIGNAL_DIR"

PANE="${TMUX_PANE:-unknown}"
# DEF-20260413-10: window 필드를 pane ID(%N) 대신 session:index(tso:N) 형식으로 기록
# worker_watchdog이 worker_status.json의 window 값과 매칭할 수 있도록 수정
cat > "$SIGNAL_DIR/compact_alert_${PANE//\%/pane}.yaml" << EOF
type: compact_alert
window: "${WINDOW_ID:-$PANE}"
compacted_at: "$TIMESTAMP"
resume_flag: "$FLAG_FILE"
latest_state: "${LATEST_STATE:-없음}"
EOF

# dispatch_inbox에서 본인 앞으로 온 미처리(dispatched) 작업 탐색
DISPATCH_DIR="$REPO/dispatch_inbox"
if [ ! -d "$DISPATCH_DIR" ]; then
    # DEF-20260402-07: tasks/dispatches/dispatch_inbox 삭제됨. 올바른 fallback으로 교정.
    DISPATCH_DIR="$REPO/tasks/dispatches"
fi

WORKER_NAME="${CLAUDE_WORKER_NAME:-}"
if [ -z "$WORKER_NAME" ] && [ -n "${TMUX_PANE:-}" ]; then
    WORKER_NAME=$(tmux display-message -p -t "$TMUX_PANE" '#W' 2>/dev/null || true)
fi

if [ -n "$WORKER_NAME" ] && [ -d "$DISPATCH_DIR" ]; then
    PENDING_DISPATCHES=$(grep -rEl "(target|assigned_to):.*${WORKER_NAME}" "$DISPATCH_DIR" 2>/dev/null \
        | xargs grep -l "status:.*dispatched" 2>/dev/null || true)  # DEF-20260410-29: target: 필드 포함

    if [ -n "$PENDING_DISPATCHES" ]; then
        echo ""
        echo "=== [Hook B] compact 재개 — 미처리 dispatch 감지 ==="
        echo "$PENDING_DISPATCHES" | while IFS= read -r f; do
            echo "  PENDING: $f"
        done
        echo "즉시 위 dispatch 파일을 읽고 작업을 재개하세요."
        echo "======================================================="
    fi
fi

exit 0

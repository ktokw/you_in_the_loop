#!/bin/bash
# Layer 0: PreCompact 직전 emergency state 저장
# compact가 예고 없이 들어와도 최소한의 machine-observable 상태 보존

# TMUX_PANE으로 정확한 창 식별 (DEF-20260407-05)
if [ -n "$TMUX_PANE" ]; then
    WINDOW=$(tmux display-message -t "$TMUX_PANE" -p '#S:#I' 2>/dev/null || echo "unknown")
else
    WINDOW=$(tmux display-message -p '#S:#I' 2>/dev/null || echo "unknown")
fi
WINDOW_SAFE="${WINDOW//[:/]/_}"
TS=$(date +%Y%m%d_%H%M%S)
TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE_DIR=~/you_in_the_loop/context_logs

mkdir -p "$STATE_DIR"

# 최신 state가 5분 이내면 skip (이미 충분히 fresh)
LATEST=$(ls -t "$STATE_DIR"/state_${WINDOW_SAFE}_*.yaml 2>/dev/null | head -1)
LATEST_AGE=999999
if [ -n "$LATEST" ]; then
    LATEST_AGE=$(( $(date +%s) - $(stat -f %m "$LATEST" 2>/dev/null || echo 0) ))
fi

if [ "$LATEST_AGE" -lt 300 ]; then
    echo "[precompact] 최신 state가 ${LATEST_AGE}초 전 — skip" >&2
    exit 0
fi

# machine-observable 상태 캡처
CHANGES=$(cd ~/you_in_the_loop && git diff --stat HEAD 2>/dev/null | tail -5)
PENDING_DISP=$(grep -rl "status:.*dispatched\|status:.*in_progress" \
    ~/you_in_the_loop/dispatch_inbox/*.yaml 2>/dev/null | wc -l | tr -d ' ')  # DEF-20260409-16: 경로 수정

# DEF-20260410-17: worklog 파일명 통일 — CLAUDE_WORKER_NAME 우선, 없으면 tmux 창 이름, 폴백 WINDOW_SAFE
WORKLOG_KEY=""
if [ -n "${CLAUDE_WORKER_NAME:-}" ]; then
    WORKLOG_KEY="$CLAUDE_WORKER_NAME"
elif [ -n "$TMUX_PANE" ]; then
    _WIN_NAME=$(tmux display-message -t "$TMUX_PANE" -p '#W' 2>/dev/null || echo "")
    [ -n "$_WIN_NAME" ] && WORKLOG_KEY="$_WIN_NAME"
fi
[ -z "$WORKLOG_KEY" ] && WORKLOG_KEY="$WINDOW_SAFE"
# worklog가 있으면 최근 이벤트 포함
WORKLOG="$STATE_DIR/worklog_${WORKLOG_KEY}_$(date +%Y%m%d).jsonl"
RECENT_EVENTS=""
ACTIVE_DISP=""
RECENT_FILES=""
if [ -f "$WORKLOG" ]; then
    RECENT_EVENTS=$(tail -10 "$WORKLOG" | sed 's/^/    /')
    # 마지막 disp_start에서 현재 작업 DISP ID 추출
    ACTIVE_DISP=$(grep '"disp_start"' "$WORKLOG" | tail -1 | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('disp',''))
except Exception as e:
    print(f'[precompact] disp parse: {e}', file=__import__('sys').stderr)
" 2>/dev/null)
    # 최근 file_edit 이벤트에서 파일 경로 추출 (중복 제거, 최근 5개)
    RECENT_FILES=$(grep '"file_edit"' "$WORKLOG" | tail -10 | python3 -c "
import sys,json
seen=set()
files=[]
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        n=d.get('note','')
        if n and n not in seen:
            seen.add(n)
            files.append(n)
    except Exception: pass
for f in files[-5:]:
    print(f'    - \"{f}\"')
" 2>/dev/null)
fi

STATE_FILE="${STATE_DIR}/state_${WINDOW_SAFE}_${TS}.yaml"

cat > "$STATE_FILE" << YAML
auto_saved: true
trigger: precompact_emergency
timestamp: "${TS_ISO}"
window: "${WINDOW}"
status: precompact_auto_save
stale_seconds: ${LATEST_AGE}
previous_state: "${LATEST:-없음}"

machine_observed:
  uncommitted_changes: |
$(echo "$CHANGES" | sed 's/^/    /')
  pending_dispatches: ${PENDING_DISP}

YAML

# worklog 이벤트가 있으면 추가
if [ -n "$RECENT_EVENTS" ]; then
    cat >> "$STATE_FILE" << YAML
recent_worklog: |
${RECENT_EVENTS}

YAML
fi

# DEF-20260414-09: ACTIVE_DISP 있을 때 :+ :- 혼용으로 DISP ID 이중 출력 버그 수정
# "${X:+A}${X:-B}" → X 있으면 "AX" (B 대신 X가 출력), X 없으면 "B" — 의도와 다름
# 수정: if/else로 ACTION_LINE 결정 후 heredoc에 단일 변수로 삽입
if [ -n "$ACTIVE_DISP" ]; then
    ACTION_LINE="현재 작업 중: ${ACTIVE_DISP} — dispatch 파일 읽어 맥락 확인"
else
    ACTION_LINE="dispatch_inbox 미완료 dispatch 확인"
fi

cat >> "$STATE_FILE" << YAML
active_dispatch: "${ACTIVE_DISP:-없음}"
recently_edited_files:
${RECENT_FILES:-    - "없음"}

next_session:
  first_actions:
    - "WARNING: compact 직전 자동 저장. Claude 자율 state가 ${LATEST_AGE}초 전이므로 stale할 수 있음"
    - "${ACTION_LINE}"
    - "recently_edited_files 목록의 파일 re-read하여 코드 맥락 복구"
  context_needed: "PreCompact 자동 — Claude 내부 맥락 없음. machine observation + worklog 기반."
YAML

# compact_log도 기록 (기존 기능 유지)
mkdir -p ~/you_in_the_loop/ar_signal_queue
# DEF-20260413-04: compact_log.txt 로테이션 — 500줄 초과 시 최근 200줄만 유지
COMPACT_LOG=~/you_in_the_loop/ar_signal_queue/compact_log.txt
if [ -f "$COMPACT_LOG" ]; then
  _clog_lines=$(wc -l < "$COMPACT_LOG")
  if [ "$_clog_lines" -gt 500 ]; then
    tail -200 "$COMPACT_LOG" > "${COMPACT_LOG}.tmp" && mv "${COMPACT_LOG}.tmp" "$COMPACT_LOG"
  fi
fi
echo "{type: compact_alert, window: ${WINDOW}, timestamp: ${TS_ISO}, state_saved: ${STATE_FILE}}" >> "$COMPACT_LOG"

echo "[precompact] Emergency state 저장: ${STATE_FILE}" >&2

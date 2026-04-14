#!/usr/bin/env bash
# ============================================================
# session_keepalive.sh — Worker 세션 자동 감지 + 재시작
#
# DISP-ENG-SESSION-KEEPALIVE-001 | Marcus 발령 | Kai 구현
#
# 사용법:
#   bash scripts/session_keepalive.sh                 # 전체 Worker 일괄 체크
#   bash scripts/session_keepalive.sh worker-name     # 특정 Worker만 체크
#   bash scripts/session_keepalive.sh --window tso:7  # 특정 window만 체크
#
# cron (heartbeat 5분):
#   */5 * * * * bash ~/tso_in_the_loop/scripts/session_keepalive.sh >> ~/tso_in_the_loop/context_logs/session_keepalive.log 2>&1
# ============================================================

set -uo pipefail

# ── PID lock — 동시 실행 방지 (DEF-20260410-07) ──────────
# DEF-20260414-NEW: bash noclobber(O_CREAT|O_EXCL)로 원자적 락 — 기존 TOCTOU 수정
# compact_resume_flag 이중 삭제 로그(동시 실행 확인)로 문제 검증.
# macOS에 flock 없으므로 set -C 를 서브쉘에서만 적용.
PIDFILE="/tmp/session_keepalive.pid"
LOCKFILE="/tmp/session_keepalive.lock"

# 원자적 락 획득: O_CREAT|O_EXCL — 이미 존재하면 즉시 exit
if ! ( set -C; echo $$ > "$LOCKFILE" ) 2>/dev/null; then
    # 락 파일 존재 — 선행 인스턴스 생존 여부 확인
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null && [ "$LOCK_AGE" -le 240 ]; then
        exit 0  # 정상 실행 중인 인스턴스 존재 → skip
    fi
    # stale lock (프로세스 사망 or 240초 초과) → 강제 재취득
    [ -n "$LOCK_PID" ] && kill "$LOCK_PID" 2>/dev/null
    rm -f "$LOCKFILE"
    ( set -C; echo $$ > "$LOCKFILE" ) 2>/dev/null || exit 0
fi
trap 'rm -f "$LOCKFILE" "$PIDFILE"' EXIT
echo $$ > "$PIDFILE"

TSO_DIR="$HOME/tso_in_the_loop"
STATUS_JSON="$TSO_DIR/worker_status.json"
LOG_FILE="$TSO_DIR/context_logs/session_keepalive.log"
COOLDOWN=300  # 5분 — 동일 Worker 재시작 쿨다운
COOLDOWN_DIR="/tmp/session_keepalive_cooldown"
IDLE_AUTOPULL_COOLDOWN=3600  # 1시간 — idle autopull 초기 쿨다운 (IMP-S-001: 30분→1시간)
IDLE_AUTOPULL_DIR="/tmp/session_idle_autopull"
IDLE_AUTOPULL_LOG="$TSO_DIR/context_logs/idle_autopull.log"
# 재시작 제외 (TSO 직접 관할 또는 의도적 종료)
EXCLUDE="worker-music worker-vibe-reef"
# idle autopull 제외 (Marcus=TSO 대화, Morgan=TSO 대기+Marcus 소통, Eli=TSO 직접 관할)
IDLE_EXCLUDE="ar-manager-marcus secretary-morgan worker-writer-eli"

mkdir -p "$(dirname "$LOG_FILE")" "$COOLDOWN_DIR" "$IDLE_AUTOPULL_DIR"
# inter-worker message rate limiting (DISP-ENG-INTER-WORKER-MSG-001)
MSG_RATE_DIR="/tmp/session_inter_worker_msg_rate"
mkdir -p "$MSG_RATE_DIR"

# 로그 로테이션 — 1000줄 초과 시 최근 300줄만 유지
if [ -f "$LOG_FILE" ]; then
  _log_lines=$(wc -l < "$LOG_FILE")
  if [ "$_log_lines" -gt 1000 ]; then
    tail -300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
fi
if [ -f "$IDLE_AUTOPULL_LOG" ]; then
  _idle_lines=$(wc -l < "$IDLE_AUTOPULL_LOG")
  if [ "$_idle_lines" -gt 1000 ]; then
    tail -300 "$IDLE_AUTOPULL_LOG" > "${IDLE_AUTOPULL_LOG}.tmp" && mv "${IDLE_AUTOPULL_LOG}.tmp" "$IDLE_AUTOPULL_LOG"
  fi
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [KEEPALIVE] $1" | tee -a "$LOG_FILE"
}

# ── DEF-20260410-14: compact_resume_flag TTL 초과 자동 정리 ──
FLAG_FILE="$TSO_DIR/.compact_resume_flag"
if [ -f "$FLAG_FILE" ]; then
    FLAG_AGE=$(( $(date +%s) - $(stat -f %m "$FLAG_FILE" 2>/dev/null || echo 0) ))
    # TTL 기본 3600초 + 여유 300초 = 3900초 초과 시 삭제
    if [ "$FLAG_AGE" -gt 3900 ]; then
        rm -f "$FLAG_FILE"
        log "compact_resume_flag TTL 초과 (${FLAG_AGE}초) — 자동 삭제"
    fi
fi

# ── rate limit 감지 (DISP-ENG-RATELIMIT-PHASE-001, OMCC-4a) ──

RATE_LIMIT_PATTERNS="rate.limit|usage.limit|quota.exceeded|too.many.requests|hit.your.limit|hit .+ limit|rate_limited|Error code: 429|529"
RATE_LIMIT_COOLDOWN_DIR="/tmp/session_ratelimit_cooldown"
mkdir -p "$RATE_LIMIT_COOLDOWN_DIR"

check_rate_limit() {
    local window="$1"
    local worker_name="$2"

    # tmux capture-pane 마지막 20줄에서 rate limit 패턴 탐색
    local pane_text
    pane_text=$(tmux capture-pane -t "$window" -p -l 20 2>/dev/null || echo "")
    [ -z "$pane_text" ] && return 1  # 판단 불가

    if echo "$pane_text" | grep -qiE "$RATE_LIMIT_PATTERNS"; then
        # 쿨다운 확인 — 같은 워커에 대해 30분 내 중복 알림 방지
        local rl_cooldown_file="$RATE_LIMIT_COOLDOWN_DIR/${window//[:\/ ]/_}.lock"
        if [ -f "$rl_cooldown_file" ]; then
            local age=$(( $(date +%s) - $(stat -f %m "$rl_cooldown_file" 2>/dev/null || echo 0) ))
            if [ "$age" -lt 1800 ]; then
                return 0  # 이미 알림 발송됨, 쿨다운 중
            fi
        fi

        touch "$rl_cooldown_file"
        log "RATE_LIMITED: $worker_name ($window) — rate limit 감지"

        # ar_signal_queue에 alert 신호 생성
        local ts_iso
        ts_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        local alert_file="$TSO_DIR/ar_signal_queue/alert_ratelimit_$(date +%Y%m%d_%H%M%S)_${worker_name}.yaml"
        cat > "$alert_file" << AEOF
type: anomaly_alert
anomaly_type: RATE_LIMIT_DETECTED
from: session_keepalive.sh
to: ar-manager-marcus
created_at: "$ts_iso"
worker: "$worker_name"
window: "$window"
subject: "[RATE LIMIT] $worker_name rate limit 감지"
message: |
  $worker_name ($window) 세션에서 rate limit 패턴이 감지되었습니다.
  자동 재개 대기 중. 모델 전환 또는 대기가 필요할 수 있습니다.
AEOF

        # worker_status.json에 rate_limited 상태 기록
        python3 -c "
import json, os
from datetime import datetime, timezone
f = '$STATUS_JSON'
try:
    js = json.load(open(f))
except: js = {}
name = '$worker_name'
if name not in js:
    js[name] = {}
js[name]['rate_limited'] = True
js[name]['rate_limited_at'] = datetime.now(timezone.utc).isoformat()
js[name]['status'] = 'rate_limited'
# DEF-20260414-18: mkstemp으로 PID-unique 임시파일
import tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=os.path.dirname(f), suffix='.ws.tmp')
try:
    with os.fdopen(_fd, 'w') as fh:
        json.dump(js, fh, indent=2, ensure_ascii=False)
    os.replace(_tmp, f)
except Exception:
    try: os.unlink(_tmp)
    except: pass
" 2>/dev/null

        return 0  # rate limited — idle autopull 하지 않음
    fi

    # rate limit 해제 감지 — 이전에 rate_limited였으면 상태 복구
    local rl_cooldown_file="$RATE_LIMIT_COOLDOWN_DIR/${window//[:\/ ]/_}.lock"
    if [ -f "$rl_cooldown_file" ]; then
        # rate limit 해제: 쿨다운 파일 삭제 + 상태 복구
        rm -f "$rl_cooldown_file"
        python3 -c "
import json, os
f = '$STATUS_JSON'
try:
    js = json.load(open(f))
except: js = {}
name = '$worker_name'
if name in js and js[name].get('rate_limited'):
    js[name]['rate_limited'] = False
    js[name]['status'] = 'working'
    import tempfile as _tf
    _fd, _tmp = _tf.mkstemp(dir=os.path.dirname(f), suffix='.ws.tmp')
    try:
        with os.fdopen(_fd, 'w') as fh:
            json.dump(js, fh, indent=2, ensure_ascii=False)
        os.replace(_tmp, f)
    except Exception:
        try: os.unlink(_tmp)
        except: pass
" 2>/dev/null
        log "RATE_LIMIT_CLEARED: $worker_name ($window) — rate limit 해제"
    fi

    return 1  # rate limit 아님
}

# ── idle autopull (DISP-ENG-IDLE-AUTOPULL-001) ──────────────

check_idle_autopull() {
    local window="$1"
    local worker_name="$2"

    # 제외 대상
    for ex in $IDLE_EXCLUDE; do
        if [[ "$worker_name" == *"$ex"* ]]; then
            return 0
        fi
    done

    # rate limit 체크 — rate limited면 idle autopull 하지 않음
    if check_rate_limit "$window" "$worker_name"; then
        return 0
    fi

    # tmux capture-pane으로 마지막 비공백 줄 확인
    local last_line
    last_line=$(tmux capture-pane -t "$window" -p 2>/dev/null | grep -v '^$' | tail -1)

    # working 패턴 — 건드리지 않음 + backoff 카운터 리셋
    # 대소문자 무시(-i) + 현재 Claude Code 패턴(esc to interrupt/cancel) 포함
    if echo "$last_line" | grep -qiE '⏺|Working|Thinking|Gitifying|esc to cancel|esc to interrupt|Generating|reading|writing|editing'; then
        local count_file="$IDLE_AUTOPULL_DIR/${window//[:\/ ]/_}.count"
        local halted_file="$IDLE_AUTOPULL_DIR/${window//[:\/ ]/_}.halted"
        rm -f "$count_file" 2>/dev/null   # 작업 시작됨 → backoff 리셋
        rm -f "$halted_file" 2>/dev/null  # 에스컬레이션 중단 해제 → 재가동 허용
        return 0
    fi

    # MCP permission 프롬프트 감지 — 자동 승인 후 skip (DISP-ENG-MCP-PERM-DEBUG-001)
    local pane_full
    pane_full=$(tmux capture-pane -t "$window" -p -l 5 2>/dev/null || echo "")
    if echo "$pane_full" | grep -qE 'Allow mcp__|Allow tool|allow once|allow for this'; then
        if echo "$pane_full" | grep -qF "mcp__tso-memory__"; then
            tmux send-keys -t "$window" "2" Enter  # Allow for this session
            local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
            echo "$ts [IDLE_AUTOPULL] $worker_name ($window) — MCP permission 자동 승인" | tee -a "$IDLE_AUTOPULL_LOG" >> "$LOG_FILE"
        fi
        return 0  # permission 프롬프트 대기 중 — idle autopull 하지 않음
    fi

    # idle 패턴 — 프롬프트만 대기 중
    if ! echo "$last_line" | grep -qE '\? for shortcuts|new task\?|accept edits|bypass permissions|❯'; then
        return 0  # 패턴 불일치 — 판단 불가, skip
    fi

    # 쿨다운 + exponential backoff 확인
    local cooldown_file="$IDLE_AUTOPULL_DIR/${window//[:\/ ]/_}.lock"
    local count_file="$IDLE_AUTOPULL_DIR/${window//[:\/ ]/_}.count"

    # 연속 트리거 횟수 읽기
    local count=0
    if [ -f "$count_file" ]; then
        count=$(cat "$count_file" 2>/dev/null || echo 0)
    fi

    # DEF-20260410-06: max_retries 상한 — 50회 초과 시 Marcus 에스컬레이션 + 트리거 중단
    # DEF-20260412-02: halted 플래그로 one-shot 보장 (timestamp 기반 파일명 → 매 실행 중복 생성 버그 수정)
    local MAX_AUTOPULL_COUNT=50
    local halted_file="$IDLE_AUTOPULL_DIR/${window//[:\/ ]/_}.halted"
    if [ "$count" -ge "$MAX_AUTOPULL_COUNT" ]; then
        if [ ! -f "$halted_file" ]; then
            # 첫 번째 상한 도달 시에만 에스컬레이션 발송
            local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
            local esc_file="$TSO_DIR/ar_signal_queue/escalation_idle_autopull_${worker_name}.yaml"
            cat > "$esc_file" << ESCEOF
type: escalation
from: session_keepalive
to: ar-manager-marcus
timestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
subject: "idle_autopull 상한 도달: $worker_name ($window)"
detail: |
  $worker_name에 대해 idle_autopull이 ${count}회 트리거됨.
  상한(${MAX_AUTOPULL_COUNT}회) 도달로 자동 트리거 중단.
  원인 조사 필요: Worker가 standing task를 처리하지 못하는 이유 확인.
  재가동: Worker가 작업을 시작하면 자동 해제됨.
ESCEOF
            touch "$halted_file"
            echo "$ts [IDLE_AUTOPULL] $worker_name ($window) — MAX_COUNT(${MAX_AUTOPULL_COUNT}) 도달. 에스컬레이션 발송. 트리거 중단." | tee -a "$IDLE_AUTOPULL_LOG" >> "$LOG_FILE"
        fi
        return 0
    fi

    # DISP-ENG-IDLE-MSG-SENDER-001: backoff 최소 1시간(IDLE_AUTOPULL_COOLDOWN) 보장
    # 이전: count>=1 시 1800s 상한 → 30분마다 트리거 가능 (5분 cron 환경에서 컨텍스트 낭비)
    # 수정: IDLE_AUTOPULL_COOLDOWN(3600)을 하한+기본값으로 유지, count 증가 시 자연 증가
    local backoff=$IDLE_AUTOPULL_COOLDOWN
    if [ "$count" -ge 1 ]; then
        backoff=$(( IDLE_AUTOPULL_COOLDOWN + (count * 300) ))  # +5분씩 선형 증가, 하한 1h
    fi

    if [ -f "$cooldown_file" ]; then
        local age=$(( $(date +%s) - $(stat -f %m "$cooldown_file" 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$backoff" ]; then
            return 0  # 쿨다운 중
        fi
    fi

    # idle autopull 트리거 — 구체적 지시 생성
    # 1단계: dispatch_inbox에서 이 Worker 대상 미착수 dispatch 확인
    local has_dispatch=""
    local dispatch_msg=""
    local role_name=$(echo "$worker_name" | sed 's/worker-//')

    for df in "$TSO_DIR"/dispatch_inbox/*.yaml; do
        [ -f "$df" ] || continue
        local d_target=$(grep "^target:" "$df" 2>/dev/null | head -1 | sed -E 's/^target:[[:space:]]*//' | tr -d '"')
        local d_status=$(grep "^status:" "$df" 2>/dev/null | head -1 | sed -E 's/^status:[[:space:]]*//' | tr -d '"')
        local d_id=$(grep "^id:" "$df" 2>/dev/null | head -1 | sed -E 's/^id:[[:space:]]*//' | tr -d '"')
        local d_title=$(grep "^title:" "$df" 2>/dev/null | head -1 | sed -E 's/^title:[[:space:]]*//' | tr -d '"')
        if [[ "$d_target" == *"$role_name"* ]] && [[ "$d_status" == "dispatched" || "$d_status" == "sent" ]]; then
            has_dispatch="yes"
            dispatch_msg="[시스템 자동 — session_keepalive] dispatch_inbox에 $d_id ($d_title) 가 dispatched 상태로 대기 중이야. 즉시 착수해줘. (이의 제기: Marcus에게 ar_signal_queue fyi)"
            break
        fi
    done

    local msg=""
    if [ -n "$has_dispatch" ]; then
        msg="$dispatch_msg"
    else
        # 2단계: standing_task_picker.sh로 cooldown 경과 + 우선순위 기반 선택 (DEF-20260409-13 수정)
        local picker_result=""
        local picker_role=""
        # role_name에서 picker용 역할명 결정 (worker- 접두사 포함)
        for candidate_role in "${role_name}" "worker-${role_name}" "worker-$(echo $role_name | cut -d- -f1)"; do
            if [ -f "$TSO_DIR/tasks/standing_tasks/${candidate_role}.yaml" ]; then
                picker_role="$candidate_role"
                break
            fi
        done

        if [ -n "$picker_role" ]; then
            picker_result=$(bash "$TSO_DIR/scripts/standing_task_picker.sh" "$picker_role" 2>/dev/null || echo "")
        fi

        if echo "$picker_result" | grep -q '착수 가능:'; then
            # picker 결과에서 첫 번째 항목 추출 (우선순위 순)
            local st_id=$(echo "$picker_result" | grep -oE 'STAND-[A-Z]+-[0-9]+' | head -1)
            local st_task=$(echo "$picker_result" | grep -A1 "$st_id" | tail -1 | sed 's/^[[:space:]]*//' | cut -c1-120)

            # DISP-ENG-STANDING-SKIP-001: 마지막 트리거 이후 파일 변경 없으면 스킵
            local window_safe="${window//[:\/ ]/_}"
            local last_trigger_file="/tmp/tso_standing_last_${window_safe}_${st_id}"
            local scan_path="$TSO_DIR/dispatch_inbox"

            # standing task yaml의 scan_paths 필드 읽기 (있으면)
            if [ -n "$picker_role" ] && [ -f "$TSO_DIR/tasks/standing_tasks/${picker_role}.yaml" ]; then
                local task_scan
                task_scan=$(python3 -c "
import re
try:
    with open('$TSO_DIR/tasks/standing_tasks/${picker_role}.yaml') as f:
        content = f.read()
    blocks = re.split(r'\n- id:', content)
    for block in blocks:
        if '$st_id' in block:
            m = re.search(r'scan_paths:\s*\n((?:[ \t]+-[^\n]+\n?)+)', block)
            if m:
                paths = re.findall(r'-\s*(.+)', m.group(1))
                print('\n'.join(p.strip() for p in paths))
            break
except Exception:
    pass
" 2>/dev/null || echo "")
                [ -n "$task_scan" ] && scan_path="$task_scan"
            fi

            if [ -f "$last_trigger_file" ]; then
                local has_changes=0
                while IFS= read -r scan_dir; do
                    scan_dir="${scan_dir/#\~/$HOME}"
                    [ -d "$scan_dir" ] || continue
                    if [ -n "$(find "$scan_dir" -maxdepth 1 -newer "$last_trigger_file" 2>/dev/null | head -1)" ]; then
                        has_changes=1; break
                    fi
                done <<< "$scan_path"

                if [ "$has_changes" -eq 0 ]; then
                    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
                    echo "$ts [IDLE_AUTOPULL] $worker_name ($window) — [skip] $st_id: no changes since last trigger" | tee -a "$IDLE_AUTOPULL_LOG" >> "$LOG_FILE"
                    return 0
                fi
            fi

            date +%s > "$last_trigger_file"

            # DEF-20260414-23: last_run 즉시 갱신 — cooldown 우회 방지
            if [ -n "$picker_role" ] && [ -f "$TSO_DIR/tasks/standing_tasks/${picker_role}.yaml" ]; then
                local _st_yaml="$TSO_DIR/tasks/standing_tasks/${picker_role}.yaml"
                local _st_id="$st_id"
                local _st_now; _st_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                python3 << PYEOF
import re, os, tempfile
st_yaml = "$_st_yaml"
task_id = "$_st_id"
now = "$_st_now"
try:
    with open(st_yaml) as f:
        content = f.read()
    parts = re.split(r'(\n- id:)', content)
    result = [parts[0]]
    i = 1
    while i < len(parts):
        if parts[i] == '\n- id:' and i + 1 < len(parts):
            block = parts[i + 1]
            if task_id in block:
                if re.search(r'\n  last_run:', block):
                    block = re.sub(r'(\n  last_run:\s*)[^\n]+', r"\g<1>" + f"'{now}'", block)
                else:
                    block = re.sub(r'(\n  report_to:[^\n]+)', r"\g<1>" + f"\n  last_run: '{now}'", block, count=1)
            result.append(parts[i] + block)
            i += 2
        else:
            result.append(parts[i])
            i += 1
    new_content = ''.join(result)
    tmp_fd, tmp = tempfile.mkstemp(dir=os.path.dirname(st_yaml), suffix='.standing.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            f.write(new_content)
        os.replace(tmp, st_yaml)
    except Exception:
        try: os.unlink(tmp)
        except: pass
except Exception:
    pass
PYEOF
            fi

            msg="[시스템 자동 — session_keepalive] 유휴 상태야. $st_id 착수해줘: $st_task 완료 후 ar_signal_queue에 fyi 보내고, 다음 standing task도 이어서 진행해. (이의 제기: Marcus에게 ar_signal_queue fyi)"
        else
            # DISP-ENG-STANDING-SKIP-001: 자율 개선 메시지도 동일 스킵 로직 적용
            local window_safe="${window//[:\/ ]/_}"
            local last_trigger_file="/tmp/tso_standing_last_${window_safe}_generic"

            if [ -f "$last_trigger_file" ]; then
                local has_changes=0
                if [ -n "$(find "$TSO_DIR/dispatch_inbox" -maxdepth 1 -newer "$last_trigger_file" 2>/dev/null | head -1)" ]; then
                    has_changes=1
                fi
                if [ "$has_changes" -eq 0 ]; then
                    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
                    echo "$ts [IDLE_AUTOPULL] $worker_name ($window) — [skip] generic: no changes since last trigger" | tee -a "$IDLE_AUTOPULL_LOG" >> "$LOG_FILE"
                    return 0
                fi
            fi

            date +%s > "$last_trigger_file"
            msg="[시스템 자동 — session_keepalive] 유휴 상태야. 네 역할에서 할 수 있는 자율 개선 작업을 찾아서 착수해줘. 예: deficiency_log 미해결 항목 수정, 코드 품질 개선, 문서 갱신 등. 완료 시 fyi 발송. (이의 제기: Marcus에게 ar_signal_queue fyi)"
        fi
    fi

    # DEF-20260409-10: staggering — dispatch는 즉시, standing task/자율개선은 랜덤 jitter
    if [ -z "$has_dispatch" ]; then
        local jitter=$(( RANDOM % 90 ))
        sleep "$jitter"
    fi

    tmux send-keys -t "$window" "$msg" Enter
    touch "$cooldown_file"
    echo $(( count + 1 )) > "$count_file"

    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local jitter_info=""
    [ -z "$has_dispatch" ] && jitter_info=" jitter=${jitter:-0}s"
    echo "$ts [IDLE_AUTOPULL] $worker_name ($window) — standing task 트리거 (count=$((count+1)), next_backoff=${backoff}s${jitter_info})" | tee -a "$IDLE_AUTOPULL_LOG" >> "$LOG_FILE"
}

# ── inter-worker 메시지 전달 (DISP-ENG-INTER-WORKER-MSG-001) ──

check_inter_worker_messages() {
    for msg_file in "$TSO_DIR/ar_signal_queue"/msg_*.yaml; do
        [ -f "$msg_file" ] || continue

        local status; status=$(grep "^status:" "$msg_file" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '"')
        [ "$status" != "unread" ] && continue

        local to_field; to_field=$(grep "^to:" "$msg_file" 2>/dev/null | head -1 | sed 's/^to:[[:space:]]*//' | tr -d '"')
        local from_field; from_field=$(grep "^from:" "$msg_file" 2>/dev/null | head -1 | sed 's/^from:[[:space:]]*//' | tr -d '"')
        local subject; subject=$(grep "^subject:" "$msg_file" 2>/dev/null | head -1 | sed 's/^subject:[[:space:]]*//' | tr -d '"')
        local priority; priority=$(grep "^priority:" "$msg_file" 2>/dev/null | head -1 | sed 's/^priority:[[:space:]]*//' | tr -d '"')
        local basename_msg; basename_msg=$(basename "$msg_file")

        # 대상 Worker tmux 윈도우 조회
        local window
        window=$(python3 -c "
import json
try:
    js = json.load(open('$STATUS_JSON'))
    for k, v in js.items():
        if k == '$to_field' or '$to_field' in v.get('aliases', []):
            print(v.get('window', ''))
            break
except: pass
" 2>/dev/null)
        [ -z "$window" ] && { log "INTER_MSG: $to_field window 없음 — skip"; continue; }

        # 대상 세션 alive 확인
        local pane_cmd
        pane_cmd=$(tmux display-message -t "$window" -p '#{pane_current_command}' 2>/dev/null || echo "NOWINDOW")
        if [ "$pane_cmd" = "NOWINDOW" ]; then
            log "INTER_MSG: $to_field ($window) 세션 없음 — 다음 주기로 연기"
            continue
        fi

        # rate limit: normal priority는 from→to 쌍당 5분 1건
        if [ "${priority:-normal}" != "urgent" ]; then
            local rate_key="${from_field}__${to_field}"
            local rate_file="$MSG_RATE_DIR/${rate_key//[^a-zA-Z0-9_]/_}"
            if [ -f "$rate_file" ]; then
                local rate_age=$(( $(date +%s) - $(stat -f %m "$rate_file" 2>/dev/null || echo 0) ))
                if [ "$rate_age" -lt 300 ]; then
                    log "INTER_MSG: rate limit — $from_field→$to_field 5분 내 중복. 큐잉."
                    continue
                fi
            fi
            touch "$rate_file"
        fi

        # 메시지 알림 주입 (셸 메타문자 소독)
        local safe_subject safe_file
        safe_subject=$(echo "$subject" | sed "s/[\$\`\\\\;|&<>!'\"()]//g" | tr -d '\n' | cut -c1-120)
        safe_file=$(echo "$basename_msg" | sed "s/[\$\`\\\\;|&<>!'\"()]//g")
        tmux send-keys -t "$window" "ar_signal_queue에 메시지 도착. 파일: ${safe_file}. 제목: ${safe_subject}. 읽고 응답해줘." Enter

        # status: unread → delivered (atomic write)
        python3 -c "
import re, os, tempfile
f = '$msg_file'
try:
    txt = open(f).read()
    txt = re.sub(r'^(status:\s*)unread\s*$', r'\g<1>delivered', txt, flags=re.MULTILINE)
    # DEF-20260414-14: mkstemp — msg 상태 갱신 .tmp 경쟁 방지
    _fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), suffix='.msg.tmp')
    try:
        os.write(_fd, txt.encode()); os.close(_fd)
        os.replace(tmp, f)
    except:
        try: os.unlink(tmp)
        except: pass
except: pass
" 2>/dev/null

        log "INTER_MSG: $basename_msg → $to_field ($window) 전달 완료"
    done
}

# ── 세션 alive 체크 ─────────────────────────────────────────

check_session() {
    local window="$1"
    local worker_name="${2:-$window}"

    # 제외 대상
    for ex in $EXCLUDE; do
        if [[ "$worker_name" == *"$ex"* ]]; then
            return 0
        fi
    done

    # tmux 윈도우 존재 확인
    if ! tmux has-session -t tso 2>/dev/null; then
        log "ERROR: tmux 세션 'tso' 없음"
        return 1
    fi

    local pane_cmd
    pane_cmd=$(tmux display-message -t "$window" -p '#{pane_current_command}' 2>/dev/null || echo "NOWINDOW")

    if [ "$pane_cmd" = "NOWINDOW" ]; then
        log "WARN: $worker_name ($window) — 윈도우 없음"
        return 1
    fi

    # claude 실행 중이면 alive — worker_status 갱신 + idle autopull 체크
    if [ "$pane_cmd" != "bash" ] && [ "$pane_cmd" != "zsh" ] && [ "$pane_cmd" != "sh" ] && [ "$pane_cmd" != "" ]; then
        # DEF-20260410-02: worker_status.json 주기적 갱신 (5분마다 alive 확인)
        python3 -c "
import json, os
from datetime import datetime, timezone
f = '$STATUS_JSON'
try:
    js = json.load(open(f))
except: js = {}
name = '$worker_name'
if name not in js:
    js[name] = {}
now = datetime.now(timezone.utc).isoformat()
js[name]['updated_at'] = now
js[name]['window'] = '$window'
if js[name].get('status') not in ('rate_limited',):
    if js[name].get('status') in ('restarting', 'dead', ''):
        js[name]['status'] = 'working'
import tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=os.path.dirname(f), suffix='.ws.tmp')
try:
    with os.fdopen(_fd, 'w') as fh:
        json.dump(js, fh, indent=2, ensure_ascii=False)
    os.replace(_tmp, f)
except Exception:
    try: os.unlink(_tmp)
    except: pass
" 2>/dev/null
        check_idle_autopull "$window" "$worker_name"
        return 0  # 살아있음
    fi

    # 쉘 프롬프트 = claude 미실행 → 재시작 필요
    # 쿨다운 확인
    local cooldown_file="$COOLDOWN_DIR/${window//[:\/ ]/_}.lock"
    if [ -f "$cooldown_file" ]; then
        local age=$(( $(date +%s) - $(stat -f %m "$cooldown_file" 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$COOLDOWN" ]; then
            return 0  # 쿨다운 중
        fi
    fi

    # 재시작
    log "RESTART: $worker_name ($window) — pane_cmd='$pane_cmd', claude 재시작"
    tmux send-keys -t "$window" "cd \"$TSO_DIR\" && claude --resume" Enter
    touch "$cooldown_file"

    # worker_status.json에 restart 기록
    python3 -c "
import json, os
from datetime import datetime, timezone
f = '$STATUS_JSON'
try:
    js = json.load(open(f))
except: js = {}
name = '$worker_name'
if name in js:
    js[name]['restart_sent_at'] = datetime.now(timezone.utc).isoformat()
    js[name]['status'] = 'restarting'
    import tempfile as _tf
    _fd, _tmp = _tf.mkstemp(dir=os.path.dirname(f), suffix='.ws.tmp')
    try:
        with os.fdopen(_fd, 'w') as fh:
            json.dump(js, fh, indent=2, ensure_ascii=False)
        os.replace(_tmp, f)
    except Exception:
        try: os.unlink(_tmp)
        except: pass
" 2>/dev/null

    return 2  # 재시작 수행
}

# ── 메인 ─────────────────────────────────────────────────────

MODE="${1:-all}"

case "$MODE" in
    --window)
        # 특정 윈도우만 체크
        WINDOW="${2:-}"
        [ -z "$WINDOW" ] && { echo "Usage: $0 --window tso:N"; exit 1; }
        check_session "$WINDOW"
        ;;
    all)
        # 전체 Worker 일괄 체크
        RESTARTED=0
        TOTAL=0

        # worker_status.json에서 window 매핑 읽기
        python3 -c "
import json
try:
    js = json.load(open('$STATUS_JSON'))
    for name, info in js.items():
        w = info.get('window', '')
        if w:
            print(f'{w}\t{name}')
except: pass
" 2>/dev/null | while IFS=$'\t' read -r window name; do
            TOTAL=$((TOTAL + 1))
            check_session "$window" "$name"
            rc=$?
            if [ "$rc" -eq 2 ]; then
                RESTARTED=$((RESTARTED + 1))
            fi
        done

        # inter-worker 메시지 전달 (normal priority)
        check_inter_worker_messages

        ;;
    *)
        # worker 이름으로 체크 — window 자동 조회
        WORKER_NAME="$MODE"
        WINDOW=$(python3 -c "
import json
try:
    js = json.load(open('$STATUS_JSON'))
    print(js.get('$WORKER_NAME', {}).get('window', ''))
except: pass
" 2>/dev/null)
        if [ -n "$WINDOW" ]; then
            check_session "$WINDOW" "$WORKER_NAME"
        else
            log "ERROR: $WORKER_NAME 의 window 정보 없음"
            exit 1
        fi
        ;;
esac

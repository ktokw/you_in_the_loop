#!/usr/bin/env bash
# ============================================================
# action_router.sh — 이벤트 드리븐 행동 라우터
#
# fswatch가 파일 변경 이벤트를 감지하면 이 스크립트에 파일 경로를 전달.
# 파일 패턴에 따라 적절한 행동을 실행한다.
#
# 설계: worker-architect-luca (tasks/infra/event_driven_design.md)
# 구현: worker-engineer-kai (DISP-ENG-EVENT-DRIVEN-IMPL-001)
#
# cron에서 /usr/bin/python3만 PATH에 있으면 PyYAML import 실패 (DEF-20260409-01)
export PATH="/opt/homebrew/bin:$PATH"
# 원칙: 대부분 스크립트로 처리 (토큰 0). Marcus 세션은 판단 필요 시만 기동.
# ============================================================

set -uo pipefail

TSO_DIR="$HOME/you_in_the_loop"
SIGNAL_DIR="$TSO_DIR/ar_signal_queue"
DISPATCH_DIR="$TSO_DIR/dispatch_inbox"
STATUS_JSON="$TSO_DIR/worker_status.json"
LOG_DIR="$TSO_DIR/context_logs"
LOG_FILE="$LOG_DIR/event_daemon_$(date +%Y%m%d).log"
MARCUS_WINDOW="tso:3"

# 디바운스: 동일 파일 1초 이내 중복 이벤트 무시
DEBOUNCE_DIR="/tmp/event_router_debounce"
DEBOUNCE_SEC=1
mkdir -p "$DEBOUNCE_DIR" "$LOG_DIR"

FILE="${1:-}"
[ -z "$FILE" ] && exit 0
[ ! -e "$FILE" ] && exit 0  # 삭제 이벤트 무시

BASENAME=$(basename "$FILE")
DIR=$(dirname "$FILE")

# ── 유틸리티 ────────────────────────────────────────────────

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [EVENT] $1" >> "$LOG_FILE"
}

debounce() {
    local key
    key=$(echo "$FILE" | md5 -q 2>/dev/null || echo "$BASENAME")
    local lock="$DEBOUNCE_DIR/$key"
    if [ -f "$lock" ]; then
        local age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$DEBOUNCE_SEC" ]; then
            return 1  # 디바운스 — skip
        fi
    fi
    touch "$lock"
    return 0
}

# 파일에서 YAML 필드 추출 (간이)
yaml_field() {
    local file="$1" field="$2"
    grep "^${field}:" "$file" 2>/dev/null | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"' | tr -d "'"
}

# DEF-20260409-06: 셸 메타문자 소독 — tmux send-keys 인젝션 방지
# DEF-20260413-12: 싱글쿼트(') 추가 — wake_marcus -p '...' 인자 조기 종료 방지
sanitize() {
    local s="$1"
    # $() `` ; | & < > \ ! ' 를 제거하여 셸 실행 차단
    echo "$s" | sed "s/[\$\`\\\\;|&<>!'\"()]//g" | tr -d '\n' | cut -c1-200
}

# ── Marcus 기동 ──────────────────────────────────────────────

wake_marcus() {
    local reason="$1"
    local ref_file="${2:-}"

    # Marcus 세션이 이미 실행 중이면 signal만
    local pane_cmd
    pane_cmd=$(tmux display-message -t "$MARCUS_WINDOW" -p '#{pane_current_command}' 2>/dev/null || echo "")
    if [ "$pane_cmd" != "bash" ] && [ "$pane_cmd" != "zsh" ] && [ "$pane_cmd" != "sh" ] && [ "$pane_cmd" != "" ]; then
        # Marcus 실행 중 — wake signal 생성 (고정 파일명 덮어쓰기: DEF-NOISE-BONUS-001)
        local wake_file="$SIGNAL_DIR/wake_marcus_active.yaml"
        local safe_reason_w safe_ref_w
        safe_reason_w=$(sanitize "$reason")
        safe_ref_w=$(sanitize "$ref_file")
        cat > "$wake_file" << YAML
type: wake
reason: "$safe_reason_w"
ref: "$safe_ref_w"
created_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YAML
        log "WAKE_SIGNAL: Marcus 실행 중, wake 파일 생성 ($reason)"
        return 0
    fi

    # Marcus 세션 기동 — DEF-20260409-06: sanitize로 셸 인젝션 차단
    local safe_reason safe_ref
    safe_reason=$(sanitize "$reason")
    safe_ref=$(sanitize "$ref_file")
    log "WAKE_MARCUS: $safe_reason (ref: $safe_ref)"
    tmux send-keys -t "$MARCUS_WINDOW" "cd $TSO_DIR && claude --resume -p '[event_router] $safe_reason. ref: $safe_ref. 확인 후 판단+행동. 완료 시 /stop'" Enter
}

# ── ar_signal_queue 핸들러 ───────────────────────────────────

handle_done() {
    local file="$1"
    local ref_dispatch
    ref_dispatch=$(yaml_field "$file" "ref_dispatch")
    [ -z "$ref_dispatch" ] && ref_dispatch=$(yaml_field "$file" "dispatch_id")
    log "DONE: $BASENAME (ref: ${ref_dispatch:-unknown})"
    # dispatch status 갱신은 PostToolUse 훅(hook_post_write_router.py)이 처리.
    # 여기서는 로그만. 훅이 놓친 경우 backup 갱신:
    if [ -n "$ref_dispatch" ]; then
        python3 -c "
import glob, os, re, tempfile

ref = '$ref_dispatch'
# tasks/dispatches/dispatch_inbox 제거: DEF-20260402-07 해결 후 경로 삭제됨
dispatch_dirs = ['$DISPATCH_DIR', '$TSO_DIR/tasks/dispatches']
log_file = '$LOG_FILE'

def log(msg):
    import datetime
    ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with open(log_file, 'a') as f:
        f.write(f'{ts} [EVENT] {msg}\n')

# 1. dispatch status→done 갱신 (backup)
# DEF-20260410-09 정합: 행 시작 앵커(^)로 정확한 status 필드만 치환
# DEF-20260413-08: ref in txt → ^id: 앵커 매칭 (parent_dispatch 오매칭 방지)
for d in dispatch_dirs:
    for f in glob.glob(os.path.join(d, '**/*.yaml'), recursive=True):
        try: txt = open(f).read()
        except: continue
        if re.search(r'^id:\s*' + re.escape(ref) + r'\s*$', txt, re.MULTILINE) and re.search(r'^status:\s*(sent|dispatched|in_progress)', txt, re.MULTILINE):
            txt = re.sub(r'^(status:\s*)(sent|dispatched|in_progress)\s*$', r'\g<1>done', txt, flags=re.MULTILINE)
            # DEF-20260414-14: mkstemp — 동일 dispatch 동시 갱신 .tmp 경쟁 방지
            _fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), suffix='.dispatch.tmp')
            try:
                os.write(_fd, txt.encode()); os.close(_fd)
                os.replace(tmp, f)
            except Exception as e:
                try: os.unlink(tmp)
                except: pass

# 2. precondition 체인 확인 (DEF-20260402-06-vera)
#    다른 dispatch에 precondition: ref 필드가 있으면 ready로 전환
for d in dispatch_dirs:
    for f in glob.glob(os.path.join(d, '**/*.yaml'), recursive=True):
        try: txt = open(f).read()
        except: continue
        if not re.search(r'^status:\s*(waiting|blocked)\s*$', txt, re.MULTILINE):
            continue
        # precondition 필드에 완료된 dispatch ID가 있는지 확인
        m = re.search(r'precondition:.*' + re.escape(ref), txt)
        if m:
            # 행 앵커로 정확한 status만 치환 (waiting_on_ivy 등 오치환 방지)
            txt = re.sub(r'^(status:\s*)(waiting|blocked)\s*$', r'\g<1>sent', txt, flags=re.MULTILINE)
            # DEF-20260414-14: mkstemp — precondition unblock 동시 갱신 .tmp 경쟁 방지
            _fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), suffix='.dispatch.tmp')
            try:
                os.write(_fd, txt.encode()); os.close(_fd)
                os.replace(tmp, f)
            except Exception as e:
                try: os.unlink(tmp)
                except: pass
            # dispatch id 추출
            dm = re.search(r'^id:\s*(.+)$', txt, re.MULTILINE)
            dep_id = dm.group(1).strip().strip('\"\'') if dm else os.path.basename(f)
            log(f'PRECONDITION_MET: {dep_id} unblocked by {ref}')

# 3. velocity 갱신 (§16 task sizing)
for d in dispatch_dirs:
    for f in glob.glob(os.path.join(d, '**/*.yaml'), recursive=True):
        try: txt = open(f).read()
        except: continue
        # DEF-20260413-08: ref not in txt → ^id: 앵커, 'status: done' → 앵커 매칭
        if not re.search(r'^id:\s*' + re.escape(ref) + r'\s*$', txt, re.MULTILINE) or not re.search(r'^status:\s*done\s*$', txt, re.MULTILINE):
            continue
        # size 필드 확인
        sm = re.search(r'^size:\s*(\S+)', txt, re.MULTILINE)
        if not sm:
            continue  # DEF-20260409-04: break→continue. size 없는 파일은 스킵, 루프 계속
        size = sm.group(1).strip('\"\'')
        # started_at / created_at
        sa = re.search(r'^(?:started_at|created_at):\s*[\"\']*(.+?)[\"\']*\s*$', txt, re.MULTILINE)
        # completed_at (없으면 현재 시각)
        ca = re.search(r'^completed_at:\s*[\"\']*(.+?)[\"\']*\s*$', txt, re.MULTILINE)
        if sa:
            from datetime import datetime, timezone
            SIZE_H = {'S':1,'M':3,'L':6,'XL':12}
            expected = SIZE_H.get(size, 3)
            try:
                start = datetime.fromisoformat(sa.group(1).replace('Z','+00:00'))
                if start.tzinfo is None: start = start.replace(tzinfo=timezone.utc)
                end = datetime.now(timezone.utc)
                if ca:
                    end = datetime.fromisoformat(ca.group(1).replace('Z','+00:00'))
                    if end.tzinfo is None: end = end.replace(tzinfo=timezone.utc)
                actual_h = (end - start).total_seconds() / 3600
                ratio = round(actual_h / expected, 2) if expected else 0

                # worker target 추출
                tm = re.search(r'^(?:target|assigned_to):\s*(.+)$', txt, re.MULTILINE)
                worker = tm.group(1).strip().strip('\"\'') if tm else 'unknown'

                # velocity yaml 갱신
                vel_path = os.path.expanduser('~/you_in_the_loop/tasks/metrics/worker_velocity.yaml')
                os.makedirs(os.path.dirname(vel_path), exist_ok=True)
                import yaml
                try:
                    vel = yaml.safe_load(open(vel_path)) or {}
                except: vel = {}
                # 기존 구조: workers: {name: ...} 또는 flat {name: ...}
                if 'workers' in vel and isinstance(vel['workers'], dict):
                    store = vel['workers']
                else:
                    store = vel
                # worker명 short key (worker-engineer-kai → kai)
                wkey = worker.split('-')[-1] if '-' in worker else worker
                if wkey not in store:
                    store[wkey] = {'completed':0,'avg_ratio':0.0,'size_breakdown':{}}
                w = store[wkey]
                w['completed'] = w.get('completed',0) + 1
                old_avg = w.get('avg_ratio', 0.0)
                n = w['completed']
                w['avg_ratio'] = round(((old_avg * (n-1)) + ratio) / n, 2)
                sb = w.get('size_breakdown',{})
                if size not in sb:
                    sb[size] = {'count':0,'avg_hours':0.0}
                s = sb[size]
                old_cnt = s['count']
                s['avg_hours'] = round(((s['avg_hours'] * old_cnt) + actual_h) / (old_cnt + 1), 1)
                s['count'] = old_cnt + 1
                w['size_breakdown'] = sb
                store[wkey] = w
                if 'workers' in vel and isinstance(vel.get('workers'), dict):
                    vel['workers'] = store
                # DEF-20260414-16: mkstemp으로 PID-unique 임시파일 — 동시 dispatch 완료 시 .tmp 경쟁 방지
                import tempfile
                vel_fd, vel_tmp = tempfile.mkstemp(dir=os.path.dirname(vel_path), suffix='.vel.tmp')
                try:
                    with os.fdopen(vel_fd, 'w') as vf:
                        yaml.dump(vel, vf, default_flow_style=False, allow_unicode=True)
                    os.replace(vel_tmp, vel_path)
                except Exception:
                    try: os.unlink(vel_tmp)
                    except: pass
                    raise
                log(f'VELOCITY: {worker} {ref} size={size} actual={actual_h:.1f}h expected={expected}h ratio={ratio}')
            except Exception as e:
                log(f'VELOCITY_ERR: {e}')
        break
" 2>/dev/null

        # stale/nudge/idle 알림 파일 정리 — dispatch done 시 해당 파일 삭제 (DEF: signal_queue 오염 방지)
        local stale_file="$SIGNAL_DIR/fyi_watchdog_stale_${ref_dispatch}.yaml"
        local nudge_file="$SIGNAL_DIR/fyi_watchdog_nudge_${ref_dispatch}.yaml"
        [ -f "$stale_file" ] && rm -f "$stale_file" && log "CLEANUP: stale signal removed for $ref_dispatch"
        [ -f "$nudge_file" ] && rm -f "$nudge_file" && log "CLEANUP: nudge signal removed for $ref_dispatch"
    fi
}

handle_blocked() {
    local file="$1"
    local disp
    disp=$(yaml_field "$file" "ref_dispatch")
    local from
    from=$(yaml_field "$file" "from")
    log "BLOCKED: $BASENAME (from: ${from:-unknown}, disp: ${disp:-unknown})"
    wake_marcus "BLOCKED signal 감지 — $(sanitize "$from") blocked on $(sanitize "${disp:-unknown}")" "$file"
}

handle_fyi() {
    local file="$1"
    local from
    from=$(yaml_field "$file" "from")
    local subject
    subject=$(yaml_field "$file" "subject")
    log "FYI: $BASENAME (from: ${from:-unknown}) $subject"

    # DEF-20260413-34 fix: fyi에 ref_dispatch가 있으면 dispatch 완료 신호로 처리
    # 모든 Worker가 sig_*done* 대신 fyi_* 사용 → handle_done이 영구 미실행 상태였음.
    # 조건: ref_dispatch 있음 + type=fyi (anomaly_alert/watchdog nudge 제외) + from이 worker-로 시작
    local ref_dispatch
    ref_dispatch=$(yaml_field "$file" "ref_dispatch")
    local fyi_type
    fyi_type=$(yaml_field "$file" "type")
    if [ -n "$ref_dispatch" ] && [ "${fyi_type}" = "fyi" ]; then
        # from이 worker-로 시작하는지 확인 (worker_watchdog 제외)
        case "$from" in
            worker-*)
                log "FYI_DONE: ref_dispatch=$ref_dispatch (from=$from) → velocity/precondition 처리"
                handle_done "$file"
                ;;
        esac
    fi
}

handle_escalation() {
    local file="$1"
    log "ESCALATION: $BASENAME"
    wake_marcus "에스컬레이션 접수" "$file"
}

# ── dispatch_inbox 핸들러 ────────────────────────────────────

handle_dispatch_change() {
    local file="$1"
    local st
    st=$(yaml_field "$file" "status")
    local target
    target=$(yaml_field "$file" "target")
    local disp_id
    disp_id=$(yaml_field "$file" "id")

    log "DISPATCH: $BASENAME (id: ${disp_id:-unknown}, status: ${st:-unknown}, target: ${target:-unknown})"

    # 새 dispatch (status: sent) → 대상 Worker tmux 창에 알림
    if [ "$st" = "sent" ] || [ "$st" = "dispatched" ]; then
        if [ -n "$target" ]; then
            # worker_status.json에서 window 찾기
            local window
            window=$(python3 -c "
import json
try:
    js = json.load(open('$STATUS_JSON'))
    # 직접 매칭
    info = js.get('$target', {})
    if info.get('window'):
        print(info['window'])
    else:
        # aliases 매칭
        for k, v in js.items():
            if '$target' in v.get('aliases', []):
                print(v.get('window', ''))
                break
except: pass
" 2>/dev/null)
            if [ -n "$window" ]; then
                # 세션 alive 체크 — 죽어있으면 자동 재시작 (DISP-ENG-SESSION-KEEPALIVE-001)
                bash "$TSO_DIR/scripts/session_keepalive.sh" --window "$window" 2>/dev/null
                # tmux 창에 알림 메시지
                tmux set-option -t "$window" -q display-time 5000 2>/dev/null
                tmux display-message -t "$window" "[NEW DISPATCH] ${disp_id:-$BASENAME} → $target" 2>/dev/null || true
                log "NOTIFY: $target ($window) ← ${disp_id:-$BASENAME}"
            fi
        fi
    fi
}

# ── worker_status.json 핸들러 ────────────────────────────────

handle_status_change() {
    local file="$1"
    log "STATUS_CHANGE: $BASENAME"
    # ctx_pct, idle 감지 등은 watchdog heartbeat(5분 cron)이 처리.
    # fswatch는 변경 감지 로그만 기록.
}

# ── tso_decisions 핸들러 ─────────────────────────────────────

handle_tso_decision() {
    local file="$1"
    log "TSO_DECISION: $BASENAME"

    case "$BASENAME" in
        dec_*_approve*|dec_*_deny*)
            # 승인/거부 → Marcus에게 전파
            wake_marcus "TSO 결정 도착: $BASENAME" "$file"
            ;;
        dec_*_chat*)
            # TSO→Morgan 메시지 → Morgan 세션에 전달
            log "TSO_CHAT: Morgan에게 전달"
            tmux display-message -t "tso:0" "[TSO 메시지 도착] $BASENAME" 2>/dev/null || true
            ;;
        dec_*_directive*)
            wake_marcus "TSO 지시 도착: $BASENAME" "$file"
            ;;
        *)
            log "TSO_DECISION: 미분류 — $BASENAME"
            ;;
    esac
}

# ── inter-worker 메시지 핸들러 (DISP-ENG-INTER-WORKER-MSG-001) ──

handle_inter_worker_msg() {
    local file="$1"
    local msg_status; msg_status=$(yaml_field "$file" "status")
    local priority; priority=$(yaml_field "$file" "priority")
    local to_field; to_field=$(yaml_field "$file" "to")
    local from_field; from_field=$(yaml_field "$file" "from")
    local subject; subject=$(yaml_field "$file" "subject")
    local basename_msg; basename_msg=$(basename "$file")

    log "INTER_WORKER_MSG: $basename_msg (from: $from_field, to: $to_field, priority: ${priority:-normal})"

    # 이미 전달된 메시지는 skip (delivered 후 fswatch 재트리거 방지)
    # session_keepalive.sh check_inter_worker_messages()와 동일 패턴
    [ "$msg_status" != "unread" ] && return 0

    # normal → session_keepalive 주기에 위임
    [ "${priority:-normal}" != "urgent" ] && return 0

    # urgent → 즉시 전달
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
    [ -z "$window" ] && { log "INTER_WORKER_MSG: $to_field window 없음 — 전달 불가"; return 1; }

    local pane_cmd
    pane_cmd=$(tmux display-message -t "$window" -p '#{pane_current_command}' 2>/dev/null || echo "NOWINDOW")
    [ "$pane_cmd" = "NOWINDOW" ] && { log "INTER_WORKER_MSG: $to_field ($window) 세션 없음"; return 1; }

    local safe_subject safe_file
    safe_subject=$(sanitize "$subject")
    safe_file=$(sanitize "$basename_msg")
    tmux send-keys -t "$window" "ar_signal_queue에 긴급 메시지 도착. 파일: ${safe_file}. 제목: ${safe_subject}. 즉시 읽고 응답해줘." Enter

    # status: unread → delivered (atomic write)
    python3 -c "
import re, os
f = '$file'
try:
    txt = open(f).read()
    txt = re.sub(r'^(status:\s*)unread\s*$', r'\g<1>delivered', txt, flags=re.MULTILINE)
    # DEF-20260414-14: mkstemp — msg 상태 갱신 .tmp 경쟁 방지
    import tempfile as _tf
    _fd, tmp = _tf.mkstemp(dir=os.path.dirname(f), suffix='.msg.tmp')
    os.write(_fd, txt.encode()); os.close(_fd)
    os.replace(tmp, f)
except: pass
" 2>/dev/null

    log "INTER_WORKER_MSG: 긴급 전달 완료 → $to_field ($window)"
}

# ── 메인 라우터 ──────────────────────────────────────────────

# 디바운스 체크
debounce || exit 0

case "$DIR" in
    *ar_signal_queue*)
        case "$BASENAME" in
            sig_*done*|sig_*DONE*)  handle_done "$FILE" ;;
            sig_*BLOCKED*|sig_*blocked*)  handle_blocked "$FILE" ;;
            fyi_*)                  handle_fyi "$FILE" ;;
            msg_*)                  handle_inter_worker_msg "$FILE" ;;
            escalation_*)          handle_escalation "$FILE" ;;
            wake_marcus_*)         ;; # wake 파일 자체는 무시 (무한루프 방지)
            compact_log*)          ;; # compact 로그는 watchdog이 처리
            compact_alert_*)       ;; # DEF-20260413-NEW: hook_b compact 신호는 watchdog(ALERT_GLOB)이 처리 — 미분류 노이즈 제거
            *)                     log "SIGNAL: $BASENAME (미분류)" ;;
        esac
        ;;
    *dispatch_inbox*)
        handle_dispatch_change "$FILE"
        ;;
    *tso_decisions*)
        handle_tso_decision "$FILE"
        ;;
    *)
        # worker_status.json 등
        if [ "$BASENAME" = "worker_status.json" ]; then
            handle_status_change "$FILE"
        else
            log "OTHER: $FILE"
        fi
        ;;
esac

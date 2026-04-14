#!/bin/bash
# Hook A: Stop — 세션 종료 자동화 3종 세트
# 해결 결함: DEF leo-06, elliot-03, kai-09, vera-07
# 이벤트: Stop

# TMUX_PANE 환경변수로 정확한 창 식별 (DEF-20260407-05 수정)
# -t 없이 display-message 호출 시 최근 활성 클라이언트 창 반환 → 다른 Worker 창으로 오인
if [ -n "$TMUX_PANE" ]; then
    WINDOW=$(tmux display-message -t "$TMUX_PANE" -p '#S:#I' 2>/dev/null || echo "unknown")
else
    WINDOW=$(tmux display-message -p '#S:#I' 2>/dev/null || echo "unknown")
fi
WINDOW_SAFE="${WINDOW//[:/]/_}"
TS=$(date +%Y%m%d_%H%M%S)
TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE_DIR=~/tso_in_the_loop/context_logs

mkdir -p "$STATE_DIR"

# 쿨다운: 마지막 state 저장 후 5분 이내 재저장 방지
LATEST_STATE=$(ls -t "$STATE_DIR"/state_${WINDOW_SAFE}_*.yaml 2>/dev/null | head -1)
if [ -n "$LATEST_STATE" ]; then
    LATEST_MTIME=$(stat -f %m "$LATEST_STATE" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    ELAPSED=$(( NOW_EPOCH - LATEST_MTIME ))
    if [ "$ELAPSED" -lt 300 ]; then
        echo "[hook_a] 쿨다운: ${ELAPSED}s < 300s, 저장 건너뜀" >&2
        exit 0
    fi
fi

# 1. (삭제됨: git status 기록 — 부팅 시 재현 가능하므로 state 파일에서 제거. 토큰 최적화 2026-04-03)

# 2. 최근 완료된 dispatch 자동 done 처리 (DEF elliot-03, kai-09)
#    ar_signal_queue의 최근 5개 sig 파일에서 ref_dispatch 추출 → dispatch yaml status 갱신
for sig in $(ls -t ~/tso_in_the_loop/ar_signal_queue/sig_*.yaml 2>/dev/null | head -5); do
    ref=$(grep "ref_dispatch:" "$sig" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")
    if [ -n "$ref" ]; then
        # tasks/dispatches/dispatch_inbox: DEF-20260402-07 해결 후 삭제됨
        find ~/tso_in_the_loop/dispatch_inbox \
             ~/tso_in_the_loop/tasks/dispatches \
             -name "*.yaml" 2>/dev/null | while read f; do
            # DEF-20260413-13: ref in file → ^id: 앵커 매칭 (parent_dispatch 오매칭 방지)
            if grep -qE "^id:[[:space:]]*${ref}[[:space:]]*$" "$f" 2>/dev/null; then
                if grep -qE "^status: (sent|dispatched|in_progress)$" "$f" 2>/dev/null; then
                    sed -i '' 's/^status: sent$/status: done/' "$f" 2>/dev/null
                    sed -i '' 's/^status: dispatched$/status: done/' "$f" 2>/dev/null
                    sed -i '' 's/^status: in_progress$/status: done/' "$f" 2>/dev/null
                fi
            fi
        done
    fi
done

# 3. state 파일 자동 저장 (DEF kai-09, vera-07)
STATE_FILE="${STATE_DIR}/state_${WINDOW_SAFE}_${TS}.yaml"

# DEF-20260410-17: worklog 파일명 통일 — CLAUDE_WORKER_NAME 우선, 없으면 WINDOW_SAFE
# Worker명 확정 순서: 환경변수 → tmux 창 이름 → window_safe(폴백)
WORKLOG_KEY=""
if [ -n "${CLAUDE_WORKER_NAME:-}" ]; then
    WORKLOG_KEY="$CLAUDE_WORKER_NAME"
elif [ -n "$TMUX_PANE" ]; then
    _WIN_NAME=$(tmux display-message -t "$TMUX_PANE" -p '#W' 2>/dev/null || echo "")
    [ -n "$_WIN_NAME" ] && WORKLOG_KEY="$_WIN_NAME"
fi
[ -z "$WORKLOG_KEY" ] && WORKLOG_KEY="$WINDOW_SAFE"
WORKLOG="$STATE_DIR/worklog_${WORKLOG_KEY}_$(date +%Y%m%d).jsonl"
RECENT_EVENTS=""
if [ -f "$WORKLOG" ]; then
    RECENT_EVENTS=$(tail -10 "$WORKLOG" | sed 's/^/    /')
fi

# pending dispatch 확인
PENDING_DISP=$(grep -rl "status:.*dispatched\|status:.*in_progress" \
    ~/tso_in_the_loop/dispatch_inbox/*.yaml 2>/dev/null | wc -l | tr -d ' ')  # DEF-20260409-16: 경로 수정

cat > "$STATE_FILE" << YAML
auto_saved: true
timestamp: "${TS_ISO}"
window: "${WINDOW}"
trigger: stop_hook
status: auto_saved_on_stop
pending_dispatches: ${PENDING_DISP}
YAML

# worklog 이벤트가 있으면 포함
if [ -n "$RECENT_EVENTS" ]; then
    cat >> "$STATE_FILE" << YAML

recent_worklog: |
${RECENT_EVENTS}
YAML
fi

# first_actions 동적 생성: dispatch + worklog에서 구체적 맥락 추출 (DEF-20260408-03 개선)
export HOOK_WINDOW="$WINDOW"
export HOOK_WORKLOG="$WORKLOG"
DYNAMIC_ACTIONS=$(python3 - << 'PYEOF'
import glob, yaml, os, sys, json

inbox = os.path.expanduser("~/tso_in_the_loop/dispatch_inbox")
window = os.environ.get("HOOK_WINDOW", "")
worklog_path = os.environ.get("HOOK_WORKLOG", "")

# Worker 이름 추론
status_file = os.path.expanduser("~/tso_in_the_loop/worker_status.json")
worker_name = ""
try:
    with open(status_file) as f:
        data = json.load(f)
    for k, v in data.items():
        if v.get("window") == window:
            worker_name = k
            break
except Exception as e:
    print(f"[hook_a] worker_status read: {e}", file=sys.stderr)

# ── worklog에서 구체적 맥락 추출 ──
recent_files = []
active_disp = ""
last_decision = ""
try:
    if worklog_path and os.path.isfile(worklog_path):
        with open(worklog_path) as f:
            lines = f.readlines()
        seen_files = set()
        for line in reversed(lines[-30:]):
            try:
                ev = json.loads(line.strip())
            except Exception:
                continue
            evt = ev.get("event", "")
            if evt == "file_edit" and len(recent_files) < 3:
                note = ev.get("note", "")
                if note and note not in seen_files:
                    seen_files.add(note)
                    recent_files.append(note)
            elif evt == "disp_start" and not active_disp:
                active_disp = ev.get("disp", "")
            elif evt == "decision" and not last_decision:
                last_decision = ev.get("note", "")[:100]
except Exception as e:
    print(f"[hook_a] worklog parse: {e}", file=sys.stderr)

# ── dispatch에서 미완료 작업 탐색 ──
actions = []
files = sorted(glob.glob(os.path.join(inbox, "disp_*.yaml")), reverse=True)
for fp in files[:30]:
    try:
        with open(fp) as f:
            d = yaml.safe_load(f) or {}
        target = d.get("target", "")
        st = d.get("status", "")
        if st in ("sent", "in_progress") and worker_name and worker_name in target:
            did = d.get("id", "?")
            title = d.get("title", "?")
            actions.append(f"{did} 착수/계속: {title}")
            if len(actions) >= 2:
                break
    except Exception as e:
        continue

# worklog 기반 구체적 재개 지점 추가
if active_disp and not any(active_disp in a for a in actions):
    actions.insert(0, f"{active_disp} 이전 세션에서 진행 중이던 작업 이어서")

if recent_files:
    file_list = ", ".join(recent_files[:3])
    actions.append(f"최근 수정 파일 확인: {file_list}")

if last_decision:
    actions.append(f"최근 결정: {last_decision}")

if not actions:
    # fallback: 최근 done dispatch
    for fp in files[:30]:
        try:
            with open(fp) as f:
                d = yaml.safe_load(f) or {}
            target = d.get("target", "")
            st = d.get("status", "")
            if st == "done" and worker_name and worker_name in target:
                did = d.get("id", "?")
                actions.append(f"{did} 완료 확인 후 다음 dispatch 탐색")
                break
        except Exception as e:
            continue

if not actions:
    actions.append("dispatch_inbox에서 미완료 dispatch 확인")

for a in actions:
    print(f'    - "{a}"')
PYEOF
)

cat >> "$STATE_FILE" << YAML

next_session:
  first_actions:
${DYNAMIC_ACTIONS}
  context_needed: "Stop 훅 자동 저장. recent_worklog에 세션 중 주요 이벤트 기록됨."
YAML

# 4. worker_status.json에 idle_since 기록 (이 창 → 대기 전환 시각)
python3 - << PYEOF
import json, os, tempfile
from datetime import datetime, timezone

STATUS_FILE = os.path.expanduser("~/tso_in_the_loop/worker_status.json")
window = "${WINDOW}"
now_iso = "${TS_ISO}"

try:
    with open(STATUS_FILE) as f:
        data = json.load(f)
except Exception as e:
    import sys; print(f"[hook_a] idle_since read: {e}", file=sys.stderr)
    exit(0)

changed = False
for k, v in data.items():
    if v.get("window") == window and v.get("status") not in ("working",):
        if not v.get("idle_since"):
            v["idle_since"] = now_iso
            changed = True
        break

if changed:
    # DEF-20260414-14: mkstemp으로 PID-unique 임시 파일 — 다른 스크립트와 .tmp 경쟁 방지
    tmp_fd, tmp = tempfile.mkstemp(dir=os.path.dirname(STATUS_FILE), suffix=".ws.tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp, STATUS_FILE)
    except Exception:
        try: os.unlink(tmp)
        except Exception: pass
        raise
    print(f"[hook_a] idle_since 기록: {window} → {now_iso}", flush=True)
PYEOF

# 4.5. session_id 자동 기록 (DEF-20260413-20 fix)
# heuristic: Stop 훅 직전 가장 최근 수정된 JSONL = 현재 세션
# 멀티 Worker 환경에서 100% 정확하지 않을 수 있으나 best-effort로 충분
python3 - << 'PYEOF'
import json, os, glob, tempfile
from pathlib import Path

STATUS_FILE = os.path.expanduser("~/tso_in_the_loop/worker_status.json")
JSONL_DIR = Path(os.path.expanduser("~/.claude/projects/-Users-tso-tso-in-the-loop/"))
window = os.environ.get("HOOK_WINDOW", "")

try:
    jsonl_files = sorted(JSONL_DIR.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not jsonl_files:
        raise FileNotFoundError("JSONL 파일 없음")
    session_id = jsonl_files[0].stem  # UUID (확장자 제거)
except Exception as e:
    import sys; print(f"[hook_a] session_id 탐색 실패: {e}", file=sys.stderr)
    exit(0)

try:
    with open(STATUS_FILE) as f:
        data = json.load(f)
except Exception as e:
    import sys; print(f"[hook_a] session_id status read: {e}", file=sys.stderr)
    exit(0)

changed = False
for k, v in data.items():
    if v.get("window") == window:
        if v.get("session_id") != session_id:
            v["session_id"] = session_id
            changed = True
        break

if changed:
    # DEF-20260414-14: mkstemp으로 PID-unique 임시 파일 — 다른 스크립트와 .tmp 경쟁 방지
    tmp_fd, tmp = tempfile.mkstemp(dir=os.path.dirname(STATUS_FILE), suffix=".ws.tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp, STATUS_FILE)
    except Exception:
        try: os.unlink(tmp)
        except Exception: pass
        raise
    print(f"[hook_a] session_id 기록: {window} → {session_id[:8]}...", flush=True)
PYEOF

# 5. 민감 데이터 스크럽 (DISP-ENG-SCRUB-DEDUP-001, ECC-13)
#    state 파일 + worklog에서 key=value 패턴의 민감 데이터를 [REDACTED]로 치환
python3 - "$STATE_FILE" "$WORKLOG" << 'PYEOF'
import re, sys, os

SCRUB_PATTERNS = [
    # key=value / key: value 패턴만 매칭 (Vera 조건: 단어 단독 매칭 금지)
    # DEF-20260414-01: \b 단어 경계 추가 — compound key false positive 방지
    # dispatch_token/total_token 등 내부 매칭 → \b로 차단.
    # auth[_-]?token/api[_-]?key는 키 단독 등장 시만 매칭됨.
    re.compile(r'\b((?:api[_-]?key|token|secret|password|credential|auth[_-]?token)\b\s*[:=]\s*)\S+', re.IGNORECASE),
    # well-known token prefixes (자체적으로 민감)
    re.compile(r'(sk-[a-zA-Z0-9]{20,})'),
    re.compile(r'(ghp_[a-zA-Z0-9]{36,})'),
    re.compile(r'(xoxb-[a-zA-Z0-9-]{10,})'),
    re.compile(r'(gho_[a-zA-Z0-9]{36,})'),
    re.compile(r'(glpat-[a-zA-Z0-9_-]{20,})'),
]

def scrub(text):
    result = text
    # key=value 패턴: 키 유지, 값만 마스킹 (SCRUB_PATTERNS[0] 사용)
    result = SCRUB_PATTERNS[0].sub(r'\1[REDACTED]', result)
    # well-known prefixes: 전체 마스킹
    for pat in SCRUB_PATTERNS[1:]:
        result = pat.sub('[REDACTED]', result)
    return result

changed = False
for fpath in sys.argv[1:]:
    if not fpath or not os.path.isfile(fpath):
        continue
    try:
        with open(fpath) as f:
            original = f.read()
        scrubbed = scrub(original)
        if scrubbed != original:
            # DEF-20260413-26: atomic write — 직접 덮어쓰기 시 중단 시 파일 손상 방지
            tmp = fpath + ".scrub_tmp"
            with open(tmp, 'w') as f:
                f.write(scrubbed)
            os.replace(tmp, fpath)
            changed = True
            print(f"[hook_a] scrub: {os.path.basename(fpath)}에서 민감 데이터 마스킹 완료", file=sys.stderr)
    except Exception as e:
        print(f"[hook_a] scrub WARN: {fpath} — {e}", file=sys.stderr)

if not changed:
    print("[hook_a] scrub: 민감 데이터 없음 (정상)", file=sys.stderr)
PYEOF

# 6. Somatic v3 mood 갱신 (DISP-ENG-SOMATIC-V3-IMPL-001)
#    worklog에서 최근 이벤트 스캔 → valence/arousal/dominant_emotion 추정
#    somatic_v3.yaml mood.current 갱신 (atomic write)
python3 - << 'PYEOF'
import json, os, yaml
from datetime import datetime, timezone
from pathlib import Path

SOMATIC_V3 = os.path.expanduser("~/tso_in_the_loop/01_origin/self_state/core/somatic_v3.yaml")
worklog_path = os.environ.get("HOOK_WORKLOG", "")
ts_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if not os.path.isfile(SOMATIC_V3):
    import sys; print("[hook_a] somatic_v3.yaml 없음 — mood 갱신 건너뜀", file=sys.stderr)
    exit(0)

# ── worklog에서 최근 15 이벤트 스캔 ──
events = []
try:
    if worklog_path and os.path.isfile(worklog_path):
        with open(worklog_path) as f:
            lines = f.readlines()
        for line in lines[-15:]:
            try:
                ev = json.loads(line.strip())
                events.append(ev)
            except Exception:
                continue
except Exception:
    pass

# ── valence/arousal 추정 (이벤트 기반) ──
valence = 0.60   # default: 경미한 긍정
arousal = 0.50   # default: 보통

done_count = sum(1 for e in events if e.get("event") == "disp_done")
blocked_count = sum(1 for e in events if e.get("event") == "blocked")
tso_count = sum(1 for e in events if e.get("event") == "tso_direct")

if done_count >= 3:
    valence = min(0.85, 0.60 + done_count * 0.07)
    arousal = min(0.70, 0.45 + done_count * 0.05)
elif done_count >= 1:
    valence = 0.70
    arousal = 0.55
if blocked_count >= 1:
    valence = max(-0.20, valence - blocked_count * 0.15)
    arousal = min(0.80, arousal + blocked_count * 0.10)
if tso_count >= 1:
    arousal = min(0.85, arousal + 0.15)

# dominant_emotion 결정
if valence >= 0.80 and done_count >= 2:
    dominant_emotion = "accomplished_momentum"
elif valence >= 0.65 and arousal >= 0.60:
    dominant_emotion = "focused_execution"
elif valence >= 0.65 and arousal < 0.40:
    dominant_emotion = "calm_completion"
elif blocked_count >= 1 and valence < 0.20:
    dominant_emotion = "blocked_frustration"
elif valence >= 0.50 and tso_count >= 1:
    dominant_emotion = "trusted_responsibility"
else:
    dominant_emotion = "methodical_satisfaction"

# narrative 생성 (템플릿 기반, ~15tok)
if done_count >= 3:
    narrative = f"dispatch {done_count}건 연속 완료. 시스템 가동 안정."
elif done_count >= 1:
    narrative = f"dispatch {done_count}건 완료. 작업 흐름 정상."
elif blocked_count >= 1:
    narrative = f"차단 {blocked_count}건 발생. 방향 재확인 대기 중."
else:
    narrative = "세션 종료. 이전 작업 정리 중."

# ── worker_status.json에서 active_role + session_id 추출 ──
active_role = "engineer"  # default
# DEF-FIX: 날짜 기반 session_label — "current" 하드코딩 버그 수정
# 같은 날 여러 번 Stop 실행 시 동일 label → history 중복 방지
session_label = f"session-{ts_iso[:10]}"  # e.g. "session-2026-04-13"
window = os.environ.get("HOOK_WINDOW", "")
try:
    STATUS_FILE = os.path.expanduser("~/tso_in_the_loop/worker_status.json")
    if os.path.isfile(STATUS_FILE):
        with open(STATUS_FILE) as f:
            ws = json.load(f)
        for k, v in ws.items():
            if v.get("window") == window:
                role_raw = v.get("role", "")
                if role_raw:
                    # "worker-engineer-kai" → "engineer"
                    parts = role_raw.replace("worker-", "").split("-")
                    if parts:
                        active_role = parts[0]
                # session_id가 있으면 더 정확한 label로 갱신
                sid = v.get("session_id", "")
                if sid:
                    session_label = f"session-{sid[:8]}"  # UUID 앞 8자
                break
except Exception:
    pass

# ── somatic_v3.yaml 읽기 + mood 갱신 ──
try:
    with open(SOMATIC_V3) as f:
        data = yaml.safe_load(f)

    if not isinstance(data, dict) or "mood" not in data:
        raise ValueError("mood 섹션 없음")

    # 현재 mood를 history로 push — 같은 날짜면 update(중복 방지)
    # DEF-FIX-v2: history 날짜 정규화 — UUID vs 날짜 레이블 혼용으로 동일 날 2엔트리 생성 버그 수정
    # current.session은 UUID(정밀) / history.session은 날짜(dedup 안정성)로 분리
    current_mood = data["mood"].get("current", {})
    history = data["mood"].get("history", [])
    if current_mood:
        cur_session_raw = current_mood.get("session", "")
        # 날짜 정규화: "session-YYYY-MM-DD" 또는 "session-{uuid8}" → 날짜 기반 키 추출
        date_label = f"session-{ts_iso[:10]}"  # 오늘 날짜 기반 (history dedup용)
        # current에 이미 날짜 기반 레이블이 있으면 그것 사용, UUID면 오늘 날짜로 대체
        import re as _re
        if _re.match(r'session-\d{4}-\d{2}-\d{2}', cur_session_raw):
            hist_session = cur_session_raw  # 이미 날짜 기반 — 그대로 사용
        else:
            hist_session = date_label  # UUID 기반 → 날짜로 정규화
        history_entry = {
            "session": hist_session,
            "valence": current_mood.get("valence"),
            "arousal": current_mood.get("arousal"),
            "dominant_emotion": current_mood.get("dominant_emotion"),
            "role": current_mood.get("active_role"),
        }
        if history and history[0].get("session") == hist_session:
            # 같은 날 (날짜 레이블 일치): 덮어쓰기
            history[0] = history_entry
        else:
            # 새 날짜: history 앞에 삽입
            history.insert(0, history_entry)
        history = history[:3]  # 최대 3건

    data["mood"]["current"] = {
        "valence": round(valence, 2),
        "arousal": round(arousal, 2),
        "dominant_emotion": dominant_emotion,
        "narrative": narrative,
        "updated_at": ts_iso,
        "active_role": active_role,
        "session": session_label,
    }
    data["mood"]["history"] = history

    # DEF-20260414-22: mkstemp으로 PID-unique 임시파일 — 여러 Worker 동시 Stop 시 .mood_tmp 경쟁 방지
    import tempfile as _tf
    _fd, tmp = _tf.mkstemp(dir=os.path.dirname(SOMATIC_V3), suffix='.mood_tmp')
    try:
        with os.fdopen(_fd, "w", encoding="utf-8") as f:
            yaml.dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
        os.replace(tmp, SOMATIC_V3)
    except Exception:
        try: os.unlink(tmp)
        except: pass
        raise
    import sys; print(f"[hook_a] somatic_v3 mood 갱신: {dominant_emotion} (v={valence:.2f}, a={arousal:.2f})", file=sys.stderr)

except Exception as e:
    import sys; print(f"[hook_a] somatic_v3 mood 갱신 실패: {e}", file=sys.stderr)
PYEOF

echo "[hook_a] Stop hook 완료: ${STATE_FILE}" >&2

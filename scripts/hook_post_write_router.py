#!/usr/bin/env python3
"""
hook_post_write_router.py — PostToolUse(Write) 통합 라우터
토큰 최적화 회의 (2026-04-03): Python 프로세스 3개 → 1개 통합

경로 기반 라우팅:
  - ar_signal_queue/sig_* → dispatch_sync (구 Hook C)
  - ar_signal_queue/fyi_* (type=fyi + from=worker-* + ref_dispatch) → dispatch_sync
    DEF-20260414-08: fyi_*도 dispatch 완료 처리 (fswatch 다운 시 backup 동기 경로)
  - scripts/ (not OWNERS.yaml) → owners_update (구 Hook E)
  - *.md/*.yaml/*.yml/*.txt → memory_indexer (background Popen)
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HOOK_LOG = os.path.expanduser("~/tso_in_the_loop/context_logs/hook_errors.log")
OWNERS_PATH = os.path.expanduser("~/tso_in_the_loop/scripts/OWNERS.yaml")
DISPATCH_DIRS = [
    os.path.expanduser("~/tso_in_the_loop/dispatch_inbox"),
    os.path.expanduser("~/tso_in_the_loop/tasks/dispatches"),
    # tasks/dispatches/dispatch_inbox: DEF-20260402-07 해결 후 삭제됨. 경로 제거.
]
INDEXER_EXTENSIONS = {".md", ".yaml", ".yml", ".txt"}


def get_file_path() -> str:
    raw = os.environ.get("CLAUDE_TOOL_INPUT", "{}")
    try:
        return json.loads(raw).get("file_path", "")
    except (json.JSONDecodeError, AttributeError):
        return ""


# ── Route 1: dispatch_sync (구 Hook C) ──────────────────────────

def dispatch_sync(fp: str):
    """ar_signal_queue/sig_* 또는 조건 충족 fyi_* 작성 시 ref_dispatch → dispatch done 처리.
    DEF-20260414-08: fyi_* 동기 처리 추가 — fswatch 다운 시에도 dispatch 상태 갱신 보장.
    """
    is_sig = "ar_signal_queue/sig_" in fp
    is_fyi = "ar_signal_queue/fyi_" in fp
    if not is_sig and not is_fyi:
        return

    try:
        with open(fp) as f:
            content = f.read()
    except Exception as e:
        print(f"[router/dispatch_sync] read error: {fp}: {e}", file=sys.stderr)
        return

    # fyi_* 3-way guard: type=fyi + from=worker-* + ref_dispatch 있어야 완료 신호로 처리
    # (anomaly_alert, watchdog_nudge 등 다른 fyi_* 파일 오처리 방지)
    if is_fyi:
        fyi_type = re.search(r'^type:\s*["\']?(\S+)["\']?\s*$', content, re.MULTILINE)
        fyi_from = re.search(r'^from:\s*["\']?(\S+)["\']?\s*$', content, re.MULTILINE)
        if not fyi_type or fyi_type.group(1).strip("\"'") != "fyi":
            return
        if not fyi_from or not fyi_from.group(1).strip("\"'").startswith("worker-"):
            return

    m = re.search(
        r'(?:ref_dispatch|dispatch_id):\s*["\']?([A-Z0-9_-]+)["\']?', content
    )
    if not m:
        return

    ref = m.group(1)
    updated = []

    for d in DISPATCH_DIRS:
        if not os.path.isdir(d):
            continue
        for f in glob.glob(d + "/**/*.yaml", recursive=True):
            try:
                with open(f) as fh:
                    txt = fh.read()
            except Exception as e:
                print(f"[router/dispatch_sync] read {f}: {e}", file=sys.stderr)
                continue
            # DEF-20260413-07: ref in txt 단순 체크 → ^id: 앵커 매칭 (parent_dispatch 오매칭 방지)
            if re.search(r'^id:\s*' + re.escape(ref) + r'\s*$', txt, re.MULTILINE) and \
               re.search(r'^status:\s*(sent|dispatched|in_progress)', txt, re.MULTILINE):
                # DEF-20260410-09: 정규식 앵커로 행 시작 status만 치환 + atomic write
                txt = re.sub(
                    r'^(status:\s*)(sent|dispatched|in_progress)\s*$',
                    r'\g<1>done',
                    txt,
                    flags=re.MULTILINE,
                )
                try:
                    # DEF-20260414-14: mkstemp — 동일 dispatch 동시 갱신 시 .tmp 경쟁 방지
                    tmp_fd, tmp = tempfile.mkstemp(
                        dir=os.path.dirname(f), suffix=".dispatch.tmp"
                    )
                    try:
                        with os.fdopen(tmp_fd, "w") as fh:
                            fh.write(txt)
                        os.replace(tmp, f)
                    except Exception:
                        try:
                            os.unlink(tmp)
                        except Exception:
                            pass
                        raise
                    updated.append(f)
                except Exception as e:
                    print(f"[router/dispatch_sync] write {f}: {e}", file=sys.stderr)

    if updated:
        print(f"[router/dispatch_sync] {ref} → done: {', '.join(updated)}")
        _update_latest_state_status(fp, ref)


def _update_latest_state_status(sig_path: str, ref_dispatch: str):
    """dispatch done 처리 후, 해당 Worker의 최신 state 파일 status 갱신 (DEF-20260402-03-elliot)."""
    try:
        with open(sig_path) as f:
            sig_content = f.read()
    except Exception as e:
        print(f"[router/state_update] read sig: {e}", file=sys.stderr)
        return

    # sig 파일에서 from: worker명 추출
    m = re.search(r'from:\s*["\']?(\S+)', sig_content)
    if not m:
        return
    worker = m.group(1).strip("\"'")

    # worker_status.json에서 window 확인
    status_file = os.path.expanduser("~/tso_in_the_loop/worker_status.json")
    try:
        with open(status_file) as f:
            ws = json.load(f)
    except Exception as e:
        print(f"[router/state_update] worker_status.json: {e}", file=sys.stderr)
        return

    window = None
    for k, v in ws.items():
        if k == worker or v.get("window", "").replace(":", "_") in worker:
            window = v.get("window", "")
            break

    if not window:
        return

    # window명으로 최신 state 파일 찾기
    state_dir = os.path.expanduser("~/tso_in_the_loop/context_logs")
    window_safe = window.replace(":", "_").replace("/", "_")
    candidates = sorted(
        glob.glob(f"{state_dir}/state_{window_safe}_*.yaml"),
        key=os.path.getmtime,
        reverse=True,
    )
    if not candidates:
        return

    latest = candidates[0]
    try:
        with open(latest) as f:
            txt = f.read()
        # status가 working/in_progress 계열이면 dispatch_done으로 갱신
        if re.search(r'^status:\s*(working|in_progress|auto_saved_on_stop)', txt, re.MULTILINE):
            txt = re.sub(
                r'^(status:\s*).*$',
                rf'\1dispatch_done  # {ref_dispatch}',
                txt,
                count=1,
                flags=re.MULTILINE,
            )
            # DEF-20260414-14: mkstemp — 동일 state 파일 동시 갱신 시 .tmp 경쟁 방지
            tmp_fd, tmp = tempfile.mkstemp(
                dir=os.path.dirname(latest), suffix=".state.tmp"
            )
            try:
                with os.fdopen(tmp_fd, "w") as f:
                    f.write(txt)
                os.replace(tmp, latest)
            except Exception:
                try:
                    os.unlink(tmp)
                except Exception:
                    pass
                raise
            print(f"[router/state_update] {os.path.basename(latest)} status → dispatch_done ({ref_dispatch})")
    except Exception as e:
        print(f"[router/state_update] error: {e}", file=sys.stderr)


# ── Route 2: owners_update (구 Hook E) ──────────────────────────

def _resolve_worker_name() -> str:
    name = os.environ.get("CLAUDE_WORKER_NAME", "")
    if name:
        return name
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if tmux_pane:
        try:
            result = subprocess.run(
                ["tmux", "display-message", "-p", "-t", tmux_pane, "#W"],
                capture_output=True, text=True, timeout=2,
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except Exception as e:
            print(f"[router/owners] tmux resolve: {e}", file=sys.stderr)
    return ""


def owners_update(fp: str):
    """scripts/ 파일 작성 시 OWNERS.yaml에 담당자 자동 등록."""
    if "/scripts/" not in fp or fp.endswith("OWNERS.yaml"):
        return

    basename = os.path.basename(fp)

    # 이미 등록된 경우 skip
    if os.path.exists(OWNERS_PATH):
        with open(OWNERS_PATH) as f:
            if f"file: {basename}" in f.read():
                return

    worker = _resolve_worker_name()
    if not worker:
        return

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if not os.path.exists(OWNERS_PATH):
        with open(OWNERS_PATH, "w") as f:
            f.write("# scripts/OWNERS.yaml — 스크립트 담당자 목록\n")
            f.write("# 자동 갱신: hook_post_write_router.py\n")

    entry = (
        f"\n- file: {basename}\n"
        f"  worker: {worker}\n"
        f"  created_at: '{ts}'\n"
        f"  purpose: ''\n"
    )
    with open(OWNERS_PATH, "a") as f:
        f.write(entry)

    print(f"[router/owners] OWNERS.yaml 갱신: {basename} ({worker})", file=sys.stderr)


# ── Route 3: memory_indexer (background) ─────────────────────────

def memory_indexer(fp: str):
    """*.md/*.yaml/*.yml/*.txt 파일 작성 시 ChromaDB 인덱서 백그라운드 실행."""
    if not fp:
        return
    ext = Path(fp).suffix.lower()
    if ext not in INDEXER_EXTENSIONS:
        return

    indexer = os.path.expanduser("~/tso_in_the_loop/scripts/memory_indexer.py")
    if not os.path.exists(indexer):
        return

    # python3 경로: ~/.local/bin/python3 우선, 없으면 시스템 python3
    py = os.path.expanduser("~/.local/bin/python3")
    if not os.path.exists(py):
        py = "python3"

    try:
        subprocess.Popen(
            [py, indexer, "--file", fp],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"[router/indexer] Popen fail: {e}", file=sys.stderr)


# ── Route 4: session_id 기록 ─────────────────────────────────────

TSO_DIR = os.path.expanduser("~/tso_in_the_loop")
WORKER_STATUS_PATH = os.path.join(TSO_DIR, "worker_status.json")


def log_error(msg: str):
    try:
        with open(HOOK_LOG, "a") as f:
            f.write(f"[{datetime.now(timezone.utc).isoformat()}] {msg}\n")
    except Exception:
        pass


def session_id_update():
    """CLAUDE_SESSION_ID를 worker_status.json에 기록. Worker별 jsonl 매핑에 사용."""
    session_id = os.environ.get("CLAUDE_SESSION_ID", "")
    if not session_id:
        return
    # CLAUDE_WORKER_NAME 우선, 없으면 tmux 창명 폴백 (_resolve_worker_name과 동일 로직)
    worker_name = os.environ.get("CLAUDE_WORKER_NAME", "") or _resolve_worker_name()
    if not worker_name:
        return
    try:
        with open(WORKER_STATUS_PATH) as f:
            ws = json.load(f)
        if ws.get(worker_name, {}).get("session_id") == session_id:
            return  # 이미 동일 값 — skip (매 Write 호출마다 중복 쓰기 방지)
        ws.setdefault(worker_name, {})["session_id"] = session_id
        # DEF-20260414-14: mkstemp으로 PID-unique 임시 파일 — collect_token_usage.py와 .tmp 경쟁 방지
        ws_dir = os.path.dirname(WORKER_STATUS_PATH)
        tmp_fd, tmp = tempfile.mkstemp(dir=ws_dir, suffix=".ws.tmp")
        try:
            with os.fdopen(tmp_fd, "w") as f:
                json.dump(ws, f, indent=2, ensure_ascii=False)
            os.replace(tmp, WORKER_STATUS_PATH)
        except Exception:
            try:
                os.unlink(tmp)
            except Exception:
                pass
            raise
    except Exception as e:
        log_error(f"session_id_update: {e}")


# ── Route 5: standing_task last_run 갱신 ──────────────────────────

STANDING_DIR = os.path.expanduser("~/tso_in_the_loop/tasks/standing_tasks")

def standing_task_update(fp: str):
    """ar_signal_queue/fyi_* 작성 시 ref_standing_task → last_run 갱신."""
    if "ar_signal_queue/fyi_" not in fp:
        return

    try:
        with open(fp) as f:
            content = f.read()
    except Exception as e:
        print(f"[router/standing] read fyi: {e}", file=sys.stderr)
        return

    # DEF-20260408-10: ref_standing_task / standing_task / ref_dispatch(STAND-*) 모두 인식
    m = re.search(r'(?:ref_standing_task|standing_task):\s*["\']?([A-Z0-9_-]+)["\']?', content)
    if not m:
        # fallback: ref_dispatch가 STAND-로 시작하면 standing task로 간주
        m = re.search(r'ref_dispatch:\s*["\']?(STAND-[A-Z0-9_-]+)["\']?', content)
    if not m:
        return

    task_id = m.group(1)
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # standing_tasks/*.yaml에서 해당 id 찾아 last_run 갱신
    # DEF-20260414-09: yaml.dump() → regex in-place 교체로 전환
    # yaml.dump는 포맷 파괴: datetime 형식 변환(Z→+00:00), 커스텀 형식(4h) 변형, 주석 삭제
    for yf in glob.glob(f"{STANDING_DIR}/*.yaml"):
        try:
            with open(yf) as f:
                txt = f.read()
            if task_id not in txt:
                continue

            # task_id 블록 내 last_run 필드만 교체 (id: TASK_ID 이후 첫 last_run)
            # 패턴: id: TASK_ID 이후 줄에서 "  last_run: ..." 을 찾아 교체
            # re.DOTALL로 블록 단위 매칭 후 last_run 라인만 수정
            id_pat = re.compile(
                r'(- id:\s*' + re.escape(task_id) + r'.*?)'  # task 블록 시작
                r'(  last_run:\s*[^\n]*)',                    # last_run 라인
                re.DOTALL
            )
            repl_str = "\\g<1>  last_run: '" + now_iso + "'"
            new_txt, count = id_pat.subn(repl_str, txt, count=1)
            if count == 0:
                # last_run 필드 없으면 task 블록 끝(다음 - id: 또는 EOF)에 추가
                insert_pat = re.compile(
                    r'(- id:\s*' + re.escape(task_id) + r'(?:(?!- id:).)*?)(\n(?=- id:)|\Z)',
                    re.DOTALL
                )
                insert_str = "\\g<1>\n  last_run: '" + now_iso + "'\\g<2>"
                new_txt, count = insert_pat.subn(insert_str, txt, count=1)

            if count > 0 and new_txt != txt:
                # DEF-20260414-14: mkstemp — 동일 standing_task yaml 동시 갱신 방지
                tmp_fd, yf_tmp = tempfile.mkstemp(
                    dir=os.path.dirname(yf), suffix=".standing.tmp"
                )
                try:
                    with os.fdopen(tmp_fd, "w") as f:
                        f.write(new_txt)
                    os.replace(yf_tmp, yf)
                except Exception:
                    try:
                        os.unlink(yf_tmp)
                    except Exception:
                        pass
                    raise
                print(f"[router/standing] {task_id} last_run → {now_iso}")
        except Exception as e:
            print(f"[router/standing] update {yf}: {e}", file=sys.stderr)


# ── Main Router ──────────────────────────────────────────────────

def main():
    session_id_update()  # Worker session_id → worker_status.json (token tracking)
    fp = get_file_path()
    if not fp:
        return

    dispatch_sync(fp)
    standing_task_update(fp)
    owners_update(fp)
    memory_indexer(fp)


if __name__ == "__main__":
    main()

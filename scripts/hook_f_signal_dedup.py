#!/usr/bin/env python3
"""
Hook F — PreToolUse(Write): ar_signal_queue 파일명 충돌 방지
DEF-20260402-03 (Reef), DEF-20260402-07 (Finn) 해결

동작:
  - Write 도구로 ar_signal_queue/sig_* 파일을 생성하려 할 때
  - 해당 파일이 이미 존재하면 → deny
  - 이유: 타임스탬프 충돌로 다른 Worker 내용 덮어쓰기 방지
  - 해결책: 파일명에 worker 식별자(CLAUDE_WORKER_NAME) 포함 요구

Claude Code Hook 환경:
  - CLAUDE_TOOL_INPUT: JSON string {"file_path": "...", "content": "..."}
  - stdout: hookSpecificOutput JSON (결정 전달)
  - exit 0 = 계속 허용, exit 2 = block (deny)
"""

import json
import os
import sys
from pathlib import Path

def main():
    tool_input_raw = os.environ.get("CLAUDE_TOOL_INPUT", "{}")
    try:
        tool_input = json.loads(tool_input_raw)
    except json.JSONDecodeError as e:
        # DEF-20260413-07: fail-open 유지(중복 차단 실패가 쓰기 차단보다 낫다) + 오류 가시화
        print(f"[hook_f] WARN: CLAUDE_TOOL_INPUT 파싱 실패 — {e}", file=sys.stderr)
        sys.exit(0)

    file_path = tool_input.get("file_path", "")

    # ar_signal_queue/sig_, fyi_, msg_ 패턴인지 확인
    # DEF-20260410-12: fyi_ 파일도 dedup 대상에 포함
    # DEF-20260414-07: msg_ 파일도 dedup 대상에 포함 (inter-worker 메시지 중복 Write 방지)
    is_sig = "ar_signal_queue/sig_" in file_path
    is_fyi = "ar_signal_queue/fyi_" in file_path
    is_msg = "ar_signal_queue/msg_" in file_path
    if not is_sig and not is_fyi and not is_msg:
        sys.exit(0)  # 대상 아님 → 허용

    target = Path(os.path.expanduser(file_path))

    if not target.exists():
        sys.exit(0)  # 신규 파일 → 허용

    # 파일이 이미 존재 → deny
    worker_name = os.environ.get("CLAUDE_WORKER_NAME", "")
    if is_sig:
        file_type = "sig"
    elif is_msg:
        file_type = "msg"
    else:
        file_type = "fyi"
    suggestion = (
        f"파일명에 worker 식별자를 포함하세요.\n"
        f"예: {file_type}_{{timestamp}}_{worker_name or 'worker-name'}_{{type}}.yaml"
    )

    output = {
        "permissionDecision": "deny",
        "reason": (
            f"ar_signal_queue 파일 충돌: '{target.name}' 이미 존재합니다. "
            f"{suggestion}"
        ),
    }
    print(json.dumps(output))
    sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        # DEF-20260409-14: crash → fail-closed + 로그
        from datetime import datetime
        HOOK_LOG = os.path.expanduser("~/you_in_the_loop/context_logs/hook_errors.log")
        try:
            with open(HOOK_LOG, "a") as lf:
                lf.write(f"{datetime.now().isoformat()} [hook_f] CRASH: {e}\n")
        except Exception:
            pass
        output = {
            "permissionDecision": "deny",
            "reason": f"[Hook F] 내부 오류 발생. 안전을 위해 차단: {e}"
        }
        print(json.dumps(output))
        sys.exit(2)

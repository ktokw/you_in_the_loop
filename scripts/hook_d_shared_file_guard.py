#!/usr/bin/env python3
"""
Hook D: PreToolUse(Edit, Write) — 공유 파일 Edit/Write 충돌 방지
shared_files.yaml 목록에 있는 파일에 Edit/Write 시도 시 차단 → Bash append 안내

DEF-20260408-14: Write matcher 추가 (기존 Edit만 → Edit+Write)
DEF-20260409-14: 최상위 try-except + 로깅 추가 (crash → silent allow 방지)
"""
import json, os, sys

HOOK_LOG = os.path.expanduser("~/tso_in_the_loop/context_logs/hook_errors.log")

try:
    tool_name = os.environ.get('CLAUDE_TOOL', 'Edit')
    inp = os.environ.get('CLAUDE_TOOL_INPUT', '{}')
    try:
        fp = json.loads(inp).get('file_path', '')
    except Exception as e:
        print(f"[hook_d] JSON parse warning: {e}", file=sys.stderr)
        fp = ''

    if not fp:
        raise SystemExit(0)

    # shared_files.yaml 로드 (없으면 기본값 사용)
    sf_path = os.path.expanduser(
        '~/tso_in_the_loop/tasks/infra/autonomous_improvement/shared_files.yaml'
    )
    patterns = ['peer_review', 'deficiency_log', 'collab_design']

    try:
        import yaml
        with open(sf_path) as f:
            sf = yaml.safe_load(f)
        if sf and 'patterns' in sf:
            patterns = sf['patterns']
    except Exception as e:
        print(f"[hook_d] shared_files.yaml load warning: {e}", file=sys.stderr)

    if any(p in fp for p in patterns):
        print(json.dumps({
            "permissionDecision": "deny",
            "reason": (
                f"[Hook D] 공유 파일 '{os.path.basename(fp)}'에는 {tool_name} 대신 "
                f"Bash append를 사용하세요:\n"
                f"  echo '내용' >> {fp}\n"
                f"여러 Worker가 동시에 편집하면 충돌이 발생합니다.\n"
                f"Write로 전체 덮어쓰기는 데이터 손실 위험이 있습니다."
            )
        }))
        sys.exit(2)

except SystemExit:
    raise
except Exception as e:
    # crash 시 deny (fail-closed) + 로그 기록
    from datetime import datetime
    try:
        with open(HOOK_LOG, "a") as lf:
            lf.write(f"{datetime.now().isoformat()} [hook_d] CRASH: {e}\n")
    except Exception:
        pass
    print(json.dumps({
        "permissionDecision": "deny",
        "reason": f"[Hook D] 내부 오류 발생. 안전을 위해 차단: {e}"
    }))
    sys.exit(2)

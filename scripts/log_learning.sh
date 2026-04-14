#!/usr/bin/env bash
# log_learning.sh — Worker 학습 기록 유틸 (DISP-ENG-LEARNINGS-IMPL-001)
# 설계: tasks/research/learnings_jsonl_design.md (Luca, 2026-04-10)
#
# 사용법:
#   bash scripts/log_learning.sh \
#     --type failure \
#     --context "DISP-ENG-XXX" \
#     --learning "내용 (1~2문장)" \
#     --applies-to "키워드1,키워드2" \
#     --severity high \
#     [--worker worker-engineer-kai]
#
# type:      failure | workaround | insight
# severity:  high | medium | low  (기본: medium)
# applies-to: 쉼표 구분 키워드. RAG 검색 + 프리로드 매칭에 사용.
# worker:    미지정 시 TMUX 윈도우명에서 자동 감지

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTEXT_LOGS="$REPO_ROOT/context_logs"

TYPE=""
CONTEXT=""
LEARNING=""
APPLIES_TO=""
SEVERITY="medium"
WORKER=""

usage() {
  echo "사용법: bash scripts/log_learning.sh --type <failure|workaround|insight> --context <상황> --learning <내용> [--applies-to <키워드>] [--severity <high|medium|low>] [--worker <worker-role>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)       TYPE="$2";       shift 2 ;;
    --context)    CONTEXT="$2";    shift 2 ;;
    --learning)   LEARNING="$2";   shift 2 ;;
    --applies-to) APPLIES_TO="$2"; shift 2 ;;
    --severity)   SEVERITY="$2";   shift 2 ;;
    --worker)     WORKER="$2";     shift 2 ;;
    *) echo "알 수 없는 옵션: $1"; usage ;;
  esac
done

# 필수 필드 검증
if [[ -z "$TYPE" || -z "$CONTEXT" || -z "$LEARNING" ]]; then
  echo "오류: --type, --context, --learning은 필수입니다."
  usage
fi

if [[ "$TYPE" != "failure" && "$TYPE" != "workaround" && "$TYPE" != "insight" ]]; then
  echo "오류: --type은 failure|workaround|insight 중 하나여야 합니다. 받은 값: $TYPE"
  exit 1
fi

if [[ "$SEVERITY" != "high" && "$SEVERITY" != "medium" && "$SEVERITY" != "low" ]]; then
  echo "오류: --severity는 high|medium|low 중 하나여야 합니다. 받은 값: $SEVERITY"
  exit 1
fi

# worker 자동 감지 (미지정 시)
if [[ -z "$WORKER" ]]; then
  if [[ -n "${TMUX_PANE:-}" ]]; then
    WIN_NAME=$(tmux display-message -p '#W' 2>/dev/null || echo "")
    case "$WIN_NAME" in
      *kai*)     WORKER="worker-engineer-kai" ;;
      *finn*)    WORKER="worker-engineer-finn" ;;
      *leo*)     WORKER="worker-engineer-leo" ;;
      *luca*)    WORKER="worker-architect-luca" ;;
      *vera*)    WORKER="worker-qa-vera" ;;
      *ivy*)     WORKER="worker-growth-ivy" ;;
      *eli*)     WORKER="worker-writer-eli" ;;
      *felix*)   WORKER="worker-sentinel-felix" ;;
      *elliot*)  WORKER="worker-paper-elliot" ;;
      *morgan*)  WORKER="secretary-morgan" ;;
      *marcus*)  WORKER="ar-manager-marcus" ;;
      *)         WORKER="worker-unknown" ;;
    esac
  else
    WORKER="worker-unknown"
  fi
fi

mkdir -p "$CONTEXT_LOGS"
LEARNINGS_FILE="$CONTEXT_LOGS/learnings_${WORKER}.jsonl"

# JSON 레코드 생성 — 인자로 전달하여 이스케이프 안전 보장
RECORD=$(python3 -c "
import json, sys
from datetime import datetime, timezone

ltype, ctx, learning, applies_to, severity = sys.argv[1:]
rec = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'type': ltype,
    'context': ctx,
    'learning': learning,
    'applies_to': applies_to,
    'severity': severity,
}
print(json.dumps(rec, ensure_ascii=False))
" "$TYPE" "$CONTEXT" "$LEARNING" "$APPLIES_TO" "$SEVERITY")

# >> append은 원자적 (단일 파일 기준) — mkstemp 불필요
echo "$RECORD" >> "$LEARNINGS_FILE"

echo "[log_learning] 기록 완료 → $LEARNINGS_FILE"
echo "  severity=${SEVERITY} type=${TYPE} context=${CONTEXT}"

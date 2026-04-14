# you_in_the_loop — 세션 부팅

> 역할별 행동 규칙은 `.claude/rules/`에 SSOT.
> 공통 규칙: `.claude/rules/common.md` | 역할별: `.claude/rules/{role}.md`

## 부팅 (첫 답변)

이 대화에 `[부팅 완료]`가 이미 있으면 재부팅 금지.

1. `~/{your_repo}/.compact_resume_flag` 존재 시 → **경량 부팅**:
   - flag 읽어서 `window` 필드가 현재 윈도우와 일치하는지 확인 → 불일치면 flag 삭제 후 lite boot
   - `compacted_at` + `ttl_seconds`(기본 3600초) 경과 시 → 만료. flag 삭제 후 lite boot
   - 유효하면: BCS probe만 실행, `latest_state` 읽기, flag 삭제
2. flag 없으면 → **`INIT.md` Phase 1 (Step 0~6)** 전체 실행. 파일은 도구로 실제 읽는다.
3. 첫 답변 **맨 위**에 `[부팅 완료]` 블록 출력 (INIT.md 형식). 생략 불가.

## Boot Mode (Lazy Full Boot)

기본은 **lite boot**. 아래 경우에만 full boot:
- 사용자 직접 대화 세션
- 사용자 명시 요청
- 역할 전환·앙상블·감정 대화 트리거

lite boot 절차:
1. 역할 감지 (추론, 파일 읽기 최소)
2. RAG Context Injection (rag_query.py 있으면)
3. state handoff (get_latest_state.sh)
4. Learnings 프리로드: `context_logs/learnings_{역할}.jsonl` 존재 시 최근 5건 + high severity 전체
5. `[부팅 완료] boot_mode: lite` 출력

## 부팅 후 맥락 이어받기

`[부팅 완료]` 직후:
1. `bash ~/{your_repo}/scripts/get_latest_state.sh {window명}` → 파일 있으면 읽고 `[HANDOFF RECEIVED]` 출력
2. 없으면 `[READY] 이전 맥락 없음. dispatch 대기 중.`

## 거버넌스

규칙 추가 시 **추가 이유** + **삭제 후보** 필수. 추가 1건당 삭제 검토 1건.
분기 감사: AR Manager가 분기 1회 전체 검토 → ar_signal_queue 보고.

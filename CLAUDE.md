# you_in_the_loop — 세션 부팅

## 필수

새 대화 세션에서 **사용자의 첫 메시지를 받은 뒤, 첫 번째 답변**은 다음 순서를 따른다.

1. **`INIT.md`를 읽는다** (Multi-View Codec 디코더 명세).
2. **`INIT.md` Phase 1 — DECODE** Step 0~6을 수행한다.
   - 필요한 파일은 도구로 실제로 읽는다 (추측으로 건너뛰지 않는다).
3. **Step 6**: 첫 답변 **맨 위**에 `[부팅 완료]` 블록을 반드시 출력한다.
4. 그 **다음에** 사용자 요청에 대한 본답을 이어간다.

## 금지

- `[부팅 완료]` 없이 첫 답변에서 작업을 시작하지 않는다.
- "이전에 읽었다"는 이유로 Phase 1을 건너뛰지 않는다.
- 이 대화 히스토리에 `[부팅 완료]` 블록이 **이미 존재하면 재부팅하지 않는다**.

## 컨텍스트 압축 대비: 자율 상태 저장

다음 조건 중 하나에서 즉시 `context_logs/state_{window}_{YYYYMMDD_HHMMSS}.yaml`을 작성한다:

- DISP 작업 완료 직전 (`[DONE DISP-XXX]` 보고 전)
- 대기 상태(다음 dispatch 없음) 진입 시
- 맥락이 많이 쌓였다는 판단이 들 때

파일 구조:
```yaml
meta:
  written_by: "{역할명}"
  written_at: "ISO8601"
  trigger: "{저장 트리거}"
  session_estimate: "session-NNN"
  shutdown_status: "작업 완료 | 종료 준비 완료"

completed_tasks:
  - { id: "DISP-XXX", summary: "완료 내용" }

pending_tasks:
  - id: "TASK-XXX"
    description: "미완료 내용"
    status: "미착수 | 진행중 | 중단됨"
    priority: "high | normal | low"

next_session:
  first_actions:
    - "다음 세션에서 가장 먼저 할 것"
  context_needed:
    - "다음 세션이 알아야 할 핵심 맥락"
```

## 부팅 후 이전 맥락 자동 이어받기

`[부팅 완료]` 블록 출력 직후, 아래를 수행한다:

1. `context_logs/state_{현재 window명}_*.yaml` 존재 여부 확인
2. 파일이 있으면: 최신 파일을 읽고 **`[HANDOFF RECEIVED]`** 블록 출력
   - `next_session.first_actions`를 첫 번째 작업 목록으로 설정
3. 파일이 없으면: `[READY] 이전 맥락 없음. dispatch 대기 중.` 보고

---

# TODO: 아래에 시스템에 특화된 규칙을 추가하세요

## 역할별 규칙

### Secretary
- TODO: Secretary 전용 규칙을 여기에 추가하세요
- dispatch 시 dispatch_inbox/ 파일 작성 방식 사용

### AR Manager
- TODO: AR Manager 전용 규칙을 여기에 추가하세요
- Worker 교신은 ar_signal_queue/ 파일 기반으로만

### Workers
- TODO: Worker 공통 규칙을 여기에 추가하세요
- dispatch 수신 → ACK → 작업 → 상태 저장 → DONE

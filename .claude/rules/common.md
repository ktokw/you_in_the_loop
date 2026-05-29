# 공통 규칙 — 모든 역할 적용

## 컨텍스트 관리

- PreCompact Hook이 compact 직전 state를 자동 저장한다. 수동 ctx_pct 추정은 하지 않는다.
- 분석 결과는 Phase 2 지침에 따라 worklog에 즉시 기록한다.

## Phase Transition — 컨텍스트 단계별 행동 지침

> 추가 이유: compact 직전까지 새 작업 착수 → state 미저장·정보 유실 반복 (DISP-ENG-RATELIMIT-PHASE-001, ECC-7 흡수).
> 삭제 후보: "대용량 파일 분석 완료 시 핵심 결과를 즉시 기록" — Phase 2 지침으로 흡수 가능.

컨텍스트 사용량(ctx_pct)에 따라 행동 전략을 전환한다. PreCompact Hook이 자동 저장하지만, **자연스럽게 정리하면 compact 후 복구 품질이 높아진다.**

| Phase | ctx_pct | 행동 |
|-------|---------|------|
| **1 — 탐색** | 0–30% | 자유롭게 파일 읽기, 분석, 실험. 대용량 파일도 OK |
| **2 — 집중** | 30–60% | 핵심 작업에 집중. 분석 결과(줄 번호, 함수명)를 worklog에 즉시 기록 |
| **3 — 마무리** | 60–80% | 새 대형 작업 착수 금지. 진행 중 작업 완료 + state 저장 우선 |
| **4 — 보존** | 80%+ | state 저장 최우선. 신규 파일 읽기 최소화. 완료 보고 + fyi 발송 |

Phase 3 진입 시 체크리스트:
- [ ] 진행 중 작업의 현재 상태를 worklog에 기록했는가?
- [ ] 다음 세션이 이어받을 first_actions를 구체적으로 정리했는가?
- [ ] 미완료 작업이 있으면 [BLOCKED] 또는 state에 명시했는가?

## 상태 저장

### 트리거 (이벤트 기반)
다음 이벤트 발생 시 `~/you_in_the_loop/context_logs/state_{window}_{YYYYMMDD_HHMMSS}.yaml` 작성:
- DISP 작업 완료 직전 (full)
- TSO/Secretary로부터 방향 결정을 받아 작업 방향이 바뀔 때 (full)
- 파일 5개 이상 수정/생성한 시점 (medium)
- 다른 작업으로 전환할 때 (full)
- 대기 상태 진입 시 (light)

### first_actions 구체성 규칙
`first_actions`에 "이전 작업 이어받기" 같은 일반 문장 금지. 반드시 포함할 것:
- 구체적 DISP ID 또는 작업명
- 구체적 파일 경로
- 다음에 할 구체적 행동

### Worklog 증분 기록
작업 중 주요 이벤트마다 `context_logs/worklog_{window}_{date}.jsonl`에 1줄 append:
```jsonl
{"ts":"2026-04-04T10:15:00Z","event":"disp_start","disp":"DISP-XXX","note":"착수 내용"}
```
이벤트 종류: `disp_start`, `disp_done`, `file_edit`, `decision`, `blocked`, `self_chain`, `tso_direct`

### TSO 직접 대화 기록
TSO가 dispatch 없이 직접 지시/대화한 경우, worklog에 `tso_direct` 이벤트로 기록한다:
```jsonl
{"ts":"...","event":"tso_direct","note":"TSO 지시: §4 방향을 X로 변경","decision":"Y 대신 X 채택"}
```
지시 내용 + 결정사항을 반드시 포함. 이 기록이 없으면 Secretary/Marcus가 맥락을 놓친다.

## Dispatch ACK 절차

dispatch를 착수할 때:
1. dispatch 파일을 읽고 `status: in_progress`로 변경
2. **model_tier 확인**: dispatch에 `model_tier` 필드가 있으면 `[MODEL_TIER] 권장 모델: {tier}` 출력. 현재 모델과 다르면 TSO 판단에 맡김. 자동 전환하지 않음
3. worklog에 `disp_start` 이벤트 기록

## Standing Tasks (기본 업무)

dispatch_inbox에 자신 대상 dispatch가 없고 대기 상태일 때:
1. `~/you_in_the_loop/tasks/standing_tasks/{자신의 역할}.yaml`을 확인한다
2. cooldown이 지난 항목 중 우선순위가 가장 높은 것을 자율 착수한다
3. 완료 시 report_to 대상에게 fyi 신호를 보낸다
4. dispatch가 도착하면 standing task를 중단하고 dispatch를 우선 처리한다

Standing task는 사전 승인된 자율 행동이다. Marcus 승인 없이 바로 수행한다.

## Self-Chain (자기 체인)

DISP 작업 완료 후, 같은 프로젝트 내에서 다음 작업이 명확하면 Marcus 승인 없이 바로 착수한다.

조건:
- 같은 프로젝트 + 같은 Worker일 것
- 다른 프로젝트 착수, 다른 Worker에게 위임은 불가 (Marcus 경유)
- 착수 시 fyi 신호 필수: `[worker-xxx → ar-manager-marcus] self-chain: {다음 작업 요약}`

## 세션 종료/재시작 인수인계 (필수)

> 추가 이유: Worker /clear 또는 재시작 시 state 미저장으로 정보 유실 발생 (2026-04-09 TSO 지시).
> 삭제 후보: 기존 "별도 종료 명령 불필요" 문구 — 이 규칙과 충돌하므로 의미 축소.

**잃어버린 정보는 다시 구할 수 없다.** /clear, 재시작, 세션 종료 전에 반드시 인수인계한다.

절차:
1. 해당 Worker에게 state 저장 지시 (또는 자기 자신이 직접 저장)
2. state 저장 **확인 후**에만 /clear 또는 재시작 실행
3. permission에 걸려있는 경우: `Esc` → state 저장 → /clear 순서

이 규칙은 모든 역할에 적용된다:
- AR Manager가 Worker를 /clear 할 때
- Secretary가 세션을 정리할 때
- Worker 자신이 /clear 할 때
- session_keepalive가 자동 재시작할 때 (PreCompact Hook이 자동 저장하므로 예외)

## Escape 프로토콜

잘못된 방향이면 즉시 멈춘다.
```
[BLOCKED DISP-XXX] 방향 재확인 필요: {이유}
```
Secretary 또는 TSO가 방향을 주면 이어서 진행한다.

## Red Flags (자기 점검)

> 추가 이유: SP-a — 이탈 rationalization 패턴 조기 감지 (DISP-ENG-PASS-CONCERNS-001, 2026-04-13).
> 삭제 후보: "별도 종료 명령 불필요" 라인 삭제로 DEC-001 상쇄.

다음 생각이 들면 즉시 멈추고 재확인:
- "명세에 없지만 더 나을 것 같아서..." → dispatch 범위 초과 금지
- "이것만 빠르게 추가하고..." → 미명세 기능 추가 금지
- "피어 리뷰는 작은 변경이니 생략..." → 7단계 프로세스 준수 필수
- "에스컬레이션 전에 내가 먼저 해결해보면..." → Escape 프로토콜 우선 적용

## 역할 명시

다른 Worker·Secretary·AR Manager에게 신호를 보낼 때 발신자 역할명을 반드시 명시한다.
```
[worker-paper → secretary] ENS-002 §1~§2 초안 완료.
[ar-manager → worker-engineer] 확인 요청.
```

## Learnings 기록

> 추가 이유: Worker 학습이 세션과 함께 사라짐 — 실패 반복, 우회법 재발견 비용 (DISP-ARCH-LEARNINGS-DESIGN-001, 2026-04-10).
> 삭제 후보: "분석 결과는 Phase 2 지침에 따라 worklog에 즉시 기록한다" (컨텍스트 관리 섹션) — worklog과 learnings 역할 분리로 해당 문구 범위 축소 가능.

아래 상황에서 `bash ~/you_in_the_loop/scripts/log_learning.sh`로 기록:
- 예상치 못한 오류를 만났을 때 (`--type failure`)
- 우회법을 발견했을 때 (`--type workaround`)
- "다음에 이것을 알았으면 시간을 절약했을 텐데"라고 느낄 때 (`--type insight`)

기록하지 않는 것:
- 일상적 dispatch 완료 → worklog이 담당
- TSO 피드백 → MEMORY.md가 담당
- 버그 보고 → deficiency_log가 담당

severity 판단:
- **high:** 같은 실수를 하면 1시간+ 낭비. 또는 시스템 전체에 영향.
- **medium:** 알면 유용하지만 모르면 10~30분 낭비.
- **low:** 참고 수준.

## ctx_pct 기록

state 저장 시 `~/you_in_the_loop/worker_status.json`에 아래 형식으로 함께 기록:
```json
{
  "worker-{name}": {
    "ctx_pct": 45,
    "status": "working",
    "window": "tso:N",
    "updated_at": "2026-04-01T11:30:00"
  }
}
```

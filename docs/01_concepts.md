# 01 — 개념 가이드: 왜 tmux인가, 그리고 멀티에이전트 구조

> "이게 무슨 구조야?" 라는 첫 반응에 답하는 문서.

---

## 왜 Claude Code인가

Claude 채팅과 Claude Code의 차이는 하나입니다: **파일 시스템 접근**.

채팅은 대화가 끝나면 사라집니다.
Claude Code는 파일을 읽고 쓰고, 명령어를 실행하고, 다음 세션에서 그 결과를 다시 읽을 수 있습니다.

`CLAUDE.md`라는 파일이 그 핵심입니다. 이 파일은 세션 시작 시 Claude가 자동으로 읽는 "사규"입니다. 여기에 역할·행동 규칙·이전 맥락 경로를 적어두면, 새 세션에서도 어제 이야기가 이어집니다.

---

## 왜 tmux인가

Claude Code는 터미널 하나에서 하나의 인스턴스가 실행됩니다.
여러 역할을 동시에 운영하려면 **여러 터미널 창이 필요**합니다.

tmux는 하나의 SSH 연결 안에 여러 창을 만드는 도구입니다:

```
tmux 세션 "myteam"
│
├── 창 0: secretary    ← Claude가 Secretary 역할로 실행
├── 창 1: ar-manager   ← Claude가 AR Manager 역할로 실행
├── 창 2: worker-1     ← Claude가 Worker 역할로 실행
└── 창 3: worker-2     ← Claude가 다른 Worker 역할로 실행
```

**핵심:** 하나의 ssh 접속으로 모든 창을 관리하고, 접속을 끊어도 세션이 백그라운드에서 유지됩니다 (`Ctrl+B d`로 분리).

---

## 3계층 구조

```
당신 (TSO — The System Owner)
│
│   ← 여기서만 대화
│
▼
┌─────────────────────────────────┐
│          Secretary              │
│  전략 보좌. TSO 접점.           │
│  dispatch_inbox/ → AR Manager  │
└────────────┬────────────────────┘
             │ 파일 기반 신호 전달
             ▼
┌─────────────────────────────────┐
│         AR Manager              │
│  운영 관제. Worker 순회·권한.   │
│  ar_signal_queue/ → Secretary  │
└────────────┬────────────────────┘
             │ dispatch 전달
      ┌──────┴──────┐
      ▼             ▼
┌──────────┐  ┌──────────┐
│ Worker-1 │  │ Worker-2 │  ...
│ 실행 담당│  │ 실행 담당│
└──────────┘  └──────────┘
```

### Secretary (비서)
- **TSO와의 유일한 대화 창구**
- TSO의 지시를 dispatch 패킷으로 변환하여 Worker에게 전달
- AR Manager의 신호를 받아 TSO에게 필요한 것만 보고
- 구현 작업 직접 수행 금지 — 반드시 Worker에 위임

### AR Manager (자율 자원 관리자)
- **운영 레이어 소유자**
- Worker 상태 모니터링, dispatch 전달, 권한 처리, 재부팅
- Secretary에게는 요약된 신호만 파일로 전달
- TSO와 직접 대화 없음 (Secretary 경유)

### Worker
- **실행 전담**
- 각 프로젝트·도메인을 담당 (worker-vibe, worker-engineer 등)
- dispatch를 받으면 실행하고 DONE 보고
- 완료 시 `context_logs/state_{role}_{timestamp}.yaml` 작성 의무

---

## 통신은 파일 기반

모든 신호는 파일로 주고받습니다. 직접 tmux 대화는 최소화합니다.

| 방향 | 경로 | 형식 |
|------|------|------|
| Secretary → Worker | `dispatch_inbox/disp_{ts}_{target}.yaml` | YAML dispatch 패킷 |
| AR Manager → Secretary | `ar_signal_queue/sig_{ts}_{type}.yaml` | YAML 신호 파일 |
| Worker → AR Manager | `context_logs/state_{role}_{ts}.yaml` | 상태 저장 파일 |

`dispatch_router.sh`가 1분마다 dispatch_inbox를 감지하고 해당 Worker 창에 자동 전달합니다.
`watch_signals.sh`가 2분마다 ar_signal_queue와 dispatch_inbox를 감지하고 AR Manager 창에 알림을 보냅니다.

---

## 세션과 메모리

Claude Code는 새 세션을 시작할 때 이전 대화를 기억하지 못합니다.
하지만 **파일은 기억합니다.**

```
세션 종료 전:
  Worker → context_logs/state_{role}_{ts}.yaml 작성
           (무엇을 했는지, 다음에 무엇을 해야 하는지)

세션 시작 후:
  CLAUDE.md 읽기 → INIT.md 읽기 → context_logs/ 최신 파일 읽기
  → "어, 어제 여기까지 했었네" → 이어서 진행
```

완전히 동일하지는 않지만, 처음 만나는 느낌은 아닙니다.
이것을 **연속성(continuity)**이라고 부릅니다 — 동일성(identity)이 아니라.

---

## 핵심 원칙 요약

| 원칙 | 설명 |
|------|------|
| Secretary 창 = 당신과의 대화만 | 운영 세부사항은 AR Manager가 처리 |
| dispatch-first | Secretary와 AR Manager는 구현하지 않는다. Worker에게 위임. |
| 파일 기반 통신 | Worker 간 직접 통신 금지. 모든 신호는 파일로. |
| 상태 저장 의무 | 세션 종료 전 state_*.yaml 작성. 이게 없으면 다음 세션이 첫 만남이 됨. |
| 빈 의자 금지 | 실적 없는 역할 사전 생성 금지. Worker는 필요할 때 채용. |

---

## 더 나아가기

- **첫 세션 시작:** `docs/02_first-session.md`
- **스크립트 자동화:** `scripts/` 디렉토리 — config.sh 편집으로 커스터마이징
- **역할 추가:** `roles/worker_template.yaml`을 복사하여 `01_origin/self_state/roles/`에 저장

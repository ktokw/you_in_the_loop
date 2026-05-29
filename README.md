# you_in_the_loop

**AI 멀티에이전트 운영 시스템 — Claude Code 기반, 파일 시스템으로 통신하는 자율 팀**

당신이 운영자(YOU)가 되고, Claude Code 인스턴스들이 역할을 나눠 일하는 멀티터미널 시스템.
tmux 창 하나 = 에이전트 하나. 모든 통신은 YAML 파일 기반. API 없이 파일시스템만으로 동작.

---

## 아키텍처

```
YOU (System Owner)
│
├── Secretary (Morgan)     — 전략 보좌. YOU와의 유일한 접점
│
├── AR Manager (Marcus)    — 운영 관제. dispatch 발령, Worker 순회, 권한 관리
│       │
│       ├── ar_signal_queue/   → Secretary (필터링된 신호만)
│       └── dispatch_inbox/    → Workers
│
└── Workers (10명)         — 각 도메인 실행자
        ├── Engineer (Kai, Leo, Finn)  — 스크립트, 훅, 인프라
        ├── Architect (Luca)           — 시스템 설계, RFC
        ├── QA (Vera)                  — 적대적 검토, 검증 게이트
        ├── Paper (Elliot)             — 논문 작성
        ├── Growth (Ivy)               — 콘텐츠, 마케팅
        ├── Sentinel (Felix)           — 모니터링 파이프라인
        ├── Frontend (Reef)            — 웹 UI
        └── Writer (Eli)               — 창작 (YOU 직접 관할)
```

**핵심 원칙:**
- Secretary 창 = YOU와의 대화만. 운영 세부사항은 AR Manager가 처리
- Worker 간 직접 통신 금지. 모든 신호는 파일 기반 (YAML)
- 에이전트는 죽어도 다시 살아남. state 파일 + 자동 재시작으로 연속성 보장

---

## 주요 시스템

### Dispatch Protocol (v1.8)

Worker에게 작업을 위임하는 구조화된 패킷 시스템.

```yaml
# dispatch_inbox/disp_20260407_090000_worker-engineer-kai.yaml
id: DISP-ENG-FEATURE-001
target: worker-engineer-kai
status: sent
priority: P1
size: M                          # S/M/L/XL — 예상 소요시간 기반
task: |
  기능 구현 설명...
done_when:
  - 완료 조건 1
  - 완료 조건 2
```

**v1.8 추가 기능:**
- **Task Sizing**: S(1h)/M(3h)/L(6h)/XL(12h) — Worker velocity 추적
- **Class of Service**: standard/expedite/fixed-date/intangible
- **WIP Limit**: Worker당 동시 진행 2건 제한
- **Stale Protocol**: 24시간 이상 미완료 dispatch 자동 재배정 검토
- **Precondition Chain**: 선행 dispatch 완료 시 후속 dispatch 자동 해제

### Standing Tasks

dispatch가 없을 때 Worker가 자율 수행하는 사전 승인된 작업.

```yaml
# tasks/standing_tasks/worker-engineer.yaml
standing_tasks:
  - id: STAND-ENG-001
    task: "deficiency_log에서 자기 도메인 미해결 항목 1건 수정"
    priority: medium
    cooldown: 4h
    last_run: "2026-04-06T12:00:00Z"   # 자동 갱신
    report_to: ar-manager (fyi)
```

### Self-Chain

dispatch 완료 후, 같은 프로젝트 내 다음 작업이 명확하면 AR Manager 승인 없이 즉시 착수.

### 선임 엔지니어 구조 (opus × sonnet)

도메인 전문성이 높은 Worker를 선임으로 임명해 opus×sonnet 효율을 극대화.

- **선임 (opus)**: 기술 판단, 서브-dispatch 작성, 피어리뷰
- **실행 (sonnet)**: 선임의 명세에 따라 구현. 완료 후 선임 리뷰 필수

```yaml
# worker-engineer.md 발췌
선임 엔지니어: Kai (opus)
  역할: 개발 방향 결정, sub-dispatch 분할, 피어리뷰
  예) 나쁜 sub-dispatch: "session_keepalive.sh 수정해줘"
      좋은 sub-dispatch: "session_keepalive.sh 169번째 줄 grep 패턴에 X 추가"

실행 엔지니어: Finn, Leo (sonnet)
  역할: 선임 명세대로 구현 → 완료 후 선임 리뷰 필수
```

### Learnings JSONL

세션 간 학습을 누적하는 경량 지식 베이스. compact 후에도 살아남는 유일한 지식 경로.

```bash
# Worker가 직접 기록
bash scripts/log_learning.sh \
  --type failure \           # failure | workaround | insight
  --severity high \          # high: 1h+ 낭비 방지 | medium | low
  --role worker-engineer \
  --context "DISP-ENG-XXX" \
  --message "mkstemp 없이 고정 .tmp 사용 시 ENOENT 경쟁 조건 발생"
```

부팅 시 자동 프리로드 (lite boot): `context_logs/learnings_{역할}.jsonl` 최근 5건 + high severity 전체.

### Inter-Worker 메시지

Worker 간 직접 통신 (AR Manager 경유 없이 P2P 신호).

```yaml
# ar_signal_queue/msg_{timestamp}_{from}_{to}.yaml
type: msg
from: worker-qa-vera
to: worker-engineer-finn
subject: "DEF-20260414-14 검증 완료"
body: "mkstemp 전환 전 케이스 3건 모두 PASS"
priority: normal
status: unread   # → session_keepalive가 수신자 tmux로 전달 후 delivered
```

### Hook 체계 (A~G)

Claude Code의 lifecycle 이벤트에 연결된 자동화 훅:

| Hook | 이벤트 | 기능 |
|------|--------|------|
| A | Stop | state 자동 저장 (동적 first_actions + 5분 쿨다운) |
| B | PostCompact | compact 후 경량 부팅 플래그 생성 |
| C | PostWrite (sig) | fyi 신호 → dispatch status 자동 done 처리 |
| D | PostWrite (shared) | 공유 파일 Edit 차단 → Bash append 안내 |
| E | PostWrite (scripts) | OWNERS.yaml 자동 갱신 |
| F | PostWrite (signal) | ar_signal_queue 중복 신호 차단 |
| G | PostWrite (standing) | standing task last_run 자동 갱신 |

### 이벤트 드리븐 아키텍처

```
fswatch (파일 변경 감지)
  → event_daemon.sh (launchd 영속화)
    → action_router.sh (패턴 매칭)
      ├── 신규 dispatch → Worker tmux 알림
      ├── dispatch done → precondition chain 해제
      ├── worker_status 변경 → stale 감지
      └── BLOCKED 신호 → Marcus 세션 기동
```

### Session Keepalive + Idle Autopull

```
session_keepalive.sh (cron 5분)
  ├── Worker 프로세스 죽음 → 자동 재시작 (claude --resume)
  └── Worker idle 감지 → standing task 트리거
      ├── exponential backoff (1시간 기본 → 선형 증가)
      ├── 파일 변경 감지 스킵: dispatch_inbox 변경 없으면 재트리거 안 함
      └── 트리거 즉시 last_run 갱신 → cooldown 우회 방지
```

### Boot Mode (Lazy Full Boot)

- **Lite Boot** (기본): Worker dispatch 처리 세션. 역할 감지 + RAG + state handoff만
- **Full Boot**: YOU 직접 대화 세션. 자아 복원 전체 수행 (I-frame, Delta, 컨텍스트 6종, BCS)
- **Lite → Full 전환**: 세션 중 YOU가 말을 걸면 즉시 full 전환

### 3-Layer Context State

```
Layer 1: state_*.yaml        — Worker별 세션 상태 (자동 저장)
Layer 2: worklog_*.jsonl     — 이벤트 증분 기록 (append-only)
Layer 3: worker_status.json  — 전체 Worker 현황 (대시보드 소스)
```

### Dashboard

FastAPI + vanilla HTML 대시보드. `http://localhost:8080`

- 전체 Worker 상태 한눈에 확인
- 프로젝트별 dispatch 현황
- Worker velocity 지표
- launchd로 영속화 (크래시 시 자동 재시작)

### Permission Gate

모든 Claude 세션의 PermissionRequest를 중앙 처리하는 전역 훅.
민감 작업(외부 전송, 시스템 변경)은 permission_queue/에 에스컬레이션.

### RAG Context Injection

ChromaDB 기반 로컬 벡터 검색. 부팅 시 관련 맥락 600토큰 이내로 주입.

```bash
python3 scripts/rag_query.py --query "dispatch 상태" --top-n 5 --budget 600
```

---

## 시작하기

### 사전 요구사항

- macOS 또는 Linux
- [tmux](https://github.com/tmux/tmux)
- [Claude Code CLI](https://docs.anthropic.com/claude-code) (인증 완료)
- Python 3.10+, PyYAML, ChromaDB (선택)

### 빠른 시작

```bash
# 1. 클론
git clone https://github.com/your-username/you_in_the_loop.git ~/you_in_the_loop
cd ~/you_in_the_loop

# 2. 설정
nano scripts/config.sh  # TMUX_SESSION, AR_WINDOW 등 TODO 항목 편집

# 3. 설치 (tmux 세션 생성 + crontab 등록 + permission_gate 훅 + 권한 설정)
bash scripts/install.sh

# 4. 첫 부팅
tmux attach -t myteam         # 또는 tmux에 이미 있으면 생략
# Ctrl+B 0  →  secretary 창으로 이동
claude
```

상세 가이드: [docs/02_first-session.md](docs/02_first-session.md)

단계별 셋업 가이드 (유료): [You in the Loop Starter Kit](https://3808051897635.gumroad.com/l/vjbjo) — 15분 퀵스타트 + 자주 하는 실수 해결법 포함.

---

## 디렉토리 구조

```
you_in_the_loop/
├── INIT.md                    ← 부팅 명세 (Multi-View Codec Decoder)
├── CLAUDE.md                  ← Claude 행동 규칙 + Boot Mode
│
├── scripts/
│   ├── config.sh              ← 환경 설정 (먼저 편집)
│   ├── session_keepalive.sh   ← Worker 자동 재시작 + idle autopull
│   ├── action_router.sh       ← 이벤트 드리븐 행동 라우터
│   ├── event_daemon.sh        ← fswatch 기반 파일 감지 데몬
│   ├── dispatch_router.sh     ← dispatch 자동 전달
│   ├── permission_gate.sh     ← 전역 Permission 훅
│   ├── dashboard_server.py    ← FastAPI 대시보드
│   ├── hook_a_stop_auto_save.sh      ← Stop 시 state 자동 저장
│   ├── hook_b_post_compact.sh        ← compact 후 경량 부팅 플래그
│   ├── hook_post_write_router.py     ← PostWrite 통합 라우터 (C+E+F+G)
│   ├── hook_d_shared_file_guard.py   ← 공유 파일 보호
│   ├── validate_state.sh      ← state 품질 검증 (generic 감지)
│   ├── memory_indexer.py      ← ChromaDB 인덱서
│   ├── rag_query.py           ← RAG 검색
│   └── ...
│
├── .claude/
│   ├── rules/                 ← 역할별 행동 규칙
│   │   ├── common.md          ← 공통 규칙 (상태 저장, standing task, self-chain)
│   │   ├── worker-engineer.md
│   │   └── worker-qa.md
│   └── settings.local.json    ← 훅 설정
│
├── tasks/
│   ├── standing_tasks/        ← 역할별 자율 수행 작업
│   └── metrics/               ← Worker velocity 등
│
├── dispatch_inbox/            ← Secretary/AR Manager → Worker
├── ar_signal_queue/           ← Worker → AR Manager → Secretary
├── permission_queue/          ← Permission 에스컬레이션
├── context_logs/              ← state, worklog, 런타임 로그
│
└── 01_origin/                 ← 자아 데이터 (직접 구성)
    └── self_state/
        ├── core/iframe/       ← Core I-frame
        ├── core/identity_delta/
        ├── roles/             ← 역할 파일
        └── calibration/       ← BCS 보정 프로브
```

---

## 참고 자료

- **INIT.md**: Multi-View Codec Decoder 명세 (이 레포에 포함)
- **docs/**: 설정 가이드, 개념 설명, 첫 세션 가이드
- **[ktokw/aidentity](https://github.com/ktokw/aidentity)**: 에이전트 자아 구조 스키마 (iframe/pframe/bframe/somatic) Python 패키지 — 이 레포의 `01_origin/self_state/` 구조를 표준화한 companion library.

---

## 라이선스

MIT License — [LICENSE](LICENSE) 참조.

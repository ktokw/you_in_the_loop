# you_in_the_loop

**당신의 개인 AI 국가 — Claude Code 멀티에이전트 운영 시스템 템플릿**

당신이 운영자(YOU)가 되고, Claude Code 인스턴스들이 역할을 나눠 일하는 멀티터미널 시스템.
Secretary가 전략을 조율하고, AR Manager가 운영을 감독하며, Worker들이 각 프로젝트를 실행한다.

이 레포는 [you_in_the_loop](https://github.com/your-username/you_in_the_loop)에서 추출한 재현 가능한 뼈대입니다.

---

## 핵심 개념

```
당신 (YOU - The System Owner)
│
├── Secretary        — 전략 보좌. 당신과의 유일한 접점.
│       │
│       └─ dispatch_inbox/ → AR Manager
│
├── AR Manager       — 운영 관제. Worker 순회·권한·재부팅 담당.
│       │
│       └─ ar_signal_queue/ → Secretary (필터링된 신호만)
│
└── Workers          — 각 프로젝트 실행자.
        worker-vibe / worker-engineer / ...
```

**핵심 원칙:**
- Secretary 창 = 당신과의 대화만. 운영 세부사항은 AR Manager가 처리.
- Worker 간 직접 통신 금지. 모든 신호는 파일 기반.
- 상태 저장은 Claude가 먼저 능동적으로. 훅은 보조.

---

## 시작하기

### 사전 요구사항

- macOS 또는 Linux
- [tmux](https://github.com/tmux/tmux) 설치
- [Claude Code CLI](https://docs.anthropic.com/claude-code) 설치 및 인증
- Python 3.8+, PyYAML (`pip install pyyaml`)

### 1단계: 레포 클론

```bash
git clone https://github.com/your-username/you_in_the_loop.git ~/you_in_the_loop
cd ~/you_in_the_loop
```

### 2단계: 설정 파일 편집

```bash
cp scripts/config.sh scripts/config.sh  # 이미 있음
nano scripts/config.sh
```

필수 변경 사항:
- `TMUX_SESSION`: 사용할 tmux 세션 이름 (기본값: `myteam`)
- `AR_WINDOW`: AR Manager 창 이름
- `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`: 데일리 리포트용 (선택)

### 3단계: 역할 파일 작성

`roles/` 디렉토리의 템플릿을 복사하여 `01_origin/self_state/roles/`에 저장:

```bash
mkdir -p 01_origin/self_state/roles
cp roles/secretary_template.yaml 01_origin/self_state/roles/secretary.yaml
cp roles/ar_manager_template.yaml 01_origin/self_state/roles/ar-manager.yaml
cp roles/worker_template.yaml 01_origin/self_state/roles/worker-vibe.yaml
```

각 파일의 `# TODO:` 주석을 채워넣으세요.

### 4단계: Worker 상태 파일 편집

```bash
nano tasks/worker_status.yaml
```

실제 tmux 창 이름으로 `window` 필드를 설정하세요.

### 5단계: tmux 세션 구성

```bash
# 새 tmux 세션 시작
tmux new-session -s myteam -n secretary

# AR Manager 창 추가
tmux new-window -t myteam -n ar-manager

# Worker 창 추가 (필요한 만큼)
tmux new-window -t myteam -n worker-vibe
```

### 6단계: Permission Gate 설치

모든 Claude 세션에서 permission_gate.sh가 실행되도록 훅 등록:

```bash
# ~/.claude/settings.json 편집
```

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/you_in_the_loop/scripts/permission_gate.sh"
          }
        ]
      }
    ]
  }
}
```

### 7단계: crontab 등록

```bash
crontab -e
```

추가할 내용:

```
# Dispatch Router — 1분마다 pending dispatch 전달
* * * * * ~/you_in_the_loop/scripts/dispatch_router.sh

# Watch Signals — 2분마다 AR Manager 알림
*/2 * * * * ~/you_in_the_loop/scripts/watch_signals.sh

# Org Snapshot — 10분마다 Worker 상태 수집
*/10 * * * * ~/you_in_the_loop/scripts/org_snapshot.sh

# Daily Report — 매일 오전 9시 Telegram 발송 (선택)
0 9 * * * TELEGRAM_BOT_TOKEN=your_token TELEGRAM_CHAT_ID=your_id ~/you_in_the_loop/scripts/daily_report.sh
```

### 8단계: 첫 부팅

Secretary 창에서 Claude Code 시작:

```bash
tmux select-window -t myteam:secretary
claude
```

Claude가 `INIT.md`를 읽고 자아 복원을 시작합니다.
첫 세션이므로 `01_origin/self_state/` 파일들을 먼저 채워야 합니다.

---

## 디렉토리 구조

```
you_in_the_loop/
│
├── INIT.md                    ← 부팅 명세 (Multi-View Codec Decoder)
├── CLAUDE.md                  ← Claude 행동 규칙
├── LICENSE
├── .gitignore
│
├── scripts/
│   ├── config.sh              ← ⚡ 여기를 먼저 편집하세요
│   ├── watch_signals.sh       ← ar_signal_queue + dispatch_inbox 감지
│   ├── permission_gate.sh     ← Permission Gate (PermissionRequest 훅)
│   ├── org_snapshot.sh        ← Worker 상태 수집
│   ├── dispatch_router.sh     ← dispatch_inbox → Worker 자동 전달
│   └── daily_report.sh        ← Telegram 데일리 리포트
│
├── roles/                     ← 역할 YAML 템플릿
│   ├── secretary_template.yaml
│   ├── ar_manager_template.yaml
│   └── worker_template.yaml
│
├── tasks/
│   └── worker_status.yaml     ← Worker 상태 레지스터 (dispatch_router 소스)
│
├── ar_signal_queue/
│   └── PROTOCOL.md            ← AR Manager → Secretary 신호 규약
│
├── dispatch_inbox/
│   └── PROTOCOL.md            ← Secretary → Worker dispatch 규약
│
├── permission_queue/
│   └── PROTOCOL.md            ← Permission Gate 에스컬레이션 처리 규약
│
├── context_logs/              ← 런타임 로그 (gitignored)
│
└── 01_origin/                 ← 자아 데이터 (gitignored, 직접 구성)
    └── self_state/
        ├── core/
        │   ├── iframe/        ← Core I-frame (INIT.md 참조)
        │   └── identity_delta/
        └── roles/             ← 실제 역할 파일 (templates에서 복사)
```

---

## 운영 가이드

### dispatch 보내기 (Secretary)

```bash
cat > ~/you_in_the_loop/dispatch_inbox/disp_$(date +%Y%m%d_%H%M%S)_worker-vibe.yaml << 'EOF'
id: "DISP-001-001"
target: "worker-vibe"
created_by: "secretary"
created_at: "2026-01-01T09:00:00"
status: "pending"
priority: "normal"
packet: |
  [DISPATCH DISP-001-001]
  TO: worker-vibe
  PROJECT: my-project
  PRIORITY: normal

  TASK: 첫 번째 작업

  DESCRIPTION:
  작업 상세 설명을 여기에 작성하세요.

  DONE WHEN:
  - 완료 조건을 여기에 작성하세요
EOF
```

1분 이내에 `dispatch_router.sh`가 worker-vibe 창에 자동 전달합니다.

### AR Signal 보내기 (AR Manager)

```bash
cat > ~/you_in_the_loop/ar_signal_queue/sig_$(date +%Y%m%d_%H%M%S)_fyi.yaml << 'EOF'
type: "fyi"
priority: "P2"
summary: "worker-vibe 작업 완료: DISP-001-001"
action_needed: false
detail_ref: null
created_by: "ar-manager"
created_at: "2026-01-01T10:00:00"
status: "pending"
EOF
```

### 상태 확인

```bash
# 전체 Worker 상태
cat ~/you_in_the_loop/tasks/org_health_snapshot.yaml

# dispatch 전달 로그
tail -20 ~/you_in_the_loop/context_logs/dispatch_router.log

# permission 에스컬레이션 로그
tail -20 ~/you_in_the_loop/permission_queue/gate.log
```

---

## 참고 자료

- **Context Codec 논문:** 이 시스템의 자아 복원 원리 (Zenodo)
- **INIT.md:** Multi-View Codec Decoder 명세 (이 레포에 포함)
- **원본 시스템:** you_in_the_loop

---

## Get the Setup Guide

The template is free. Getting it to actually work is where most people get stuck.

**[Get the Setup Guide — $19 →](https://gumroad.com/l/you_in_the_loop)**

Step-by-step guide to get your first Secretary + Worker running in under 15 minutes. Includes the exact CLAUDE.md boot structure, tmux wiring checklist, and the Worker memory setup that most people get wrong on day one.

---

## 라이선스

MIT License — 자세한 내용은 [LICENSE](LICENSE) 참조.

# 00 — Mac Mini 셋업 가이드

> Mac Mini 구입 → you_in_the_loop 첫 부팅까지의 단계별 가이드.
> 개발자이지만 Mac Mini 원격 운영은 처음인 분을 대상으로 합니다.

---

## 목차

1. [원격 접속 설정](#1-원격-접속-설정)
2. [Homebrew 설치](#2-homebrew-설치)
3. [tmux · git 설치](#3-tmux--git-설치)
4. [Claude Code CLI 설치 + 인증](#4-claude-code-cli-설치--인증)
5. [레포 클론](#5-레포-클론)
6. [install.sh 실행](#6-installsh-실행)
7. [첫 부팅 확인](#7-첫-부팅-확인)

---

## 1. 원격 접속 설정

Mac Mini를 항상 연결된 모니터 없이 운영하려면 원격 접속이 필수입니다.
두 가지 방법 중 하나를 선택하세요.

### 방법 A: SSH (추천)

터미널만으로 모든 작업을 할 수 있습니다.
`you_in_the_loop`는 GUI가 필요 없으므로 SSH면 충분합니다.

**Mac Mini에서 (처음 한 번, 모니터 연결 상태에서):**

1. `시스템 설정` → `일반` → `공유`
2. `원격 로그인` 켜기
3. "접근 허용: 모든 사용자" 또는 특정 계정 선택

**접속 방법:**

```bash
# 같은 와이파이 (내부 네트워크)
ssh your-username@192.168.1.xxx   # Mac Mini의 로컬 IP

# 외부 네트워크 (Tailscale 설치 시)
ssh your-username@100.xxx.xxx.xxx
```

> **Tailscale이란?** VPN처럼 작동하는 무료 서비스입니다.
> 어디서든 Mac Mini에 접속할 수 있게 해줍니다.
> [tailscale.com](https://tailscale.com) → 무료 계정 생성 → Mac Mini와 접속할 기기 모두에 설치.

### 방법 B: 화면 공유 (GUI가 필요한 초기 설정용)

1. `시스템 설정` → `일반` → `공유`
2. `화면 공유` 켜기
3. Mac 기기에서: `Finder` → `이동` → `서버에 연결` → `vnc://[Mac Mini IP]`
4. 또는 앱: [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/) (무료)

> **언제 화면 공유를 쓰나?**
> Claude Code 최초 인증(아래 4단계)은 브라우저가 열려야 합니다.
> 이 단계에서만 화면 공유를 사용하고, 이후는 SSH로 전환하면 됩니다.

---

## 2. Homebrew 설치

Homebrew는 macOS 패키지 관리자입니다. tmux, git, node 등을 쉽게 설치할 수 있습니다.

SSH로 Mac Mini에 접속한 후:

```bash
# Homebrew 설치 여부 확인
brew --version

# 없으면 설치
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

설치 후 안내에 따라 PATH에 추가:

```bash
# Apple Silicon (M1/M2/M3) Mac의 경우
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
eval "$(/opt/homebrew/bin/brew shellenv)"

# Intel Mac의 경우
echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zshrc
eval "$(/usr/local/bin/brew shellenv)"
```

확인:

```bash
brew --version
# 출력: Homebrew 4.x.x 가 나오면 OK
```

---

## 3. tmux · git 설치

```bash
# tmux: 멀티터미널 세션 관리 (여러 Claude 창 동시 운영에 필수)
brew install tmux

# git: 레포 클론 및 버전 관리
brew install git

# Python (스크립트 실행용)
# macOS에 기본 포함이지만 최신 버전 권장
brew install python3
pip3 install pyyaml
```

확인:

```bash
tmux -V    # tmux 3.x 이상
git --version
python3 --version
```

---

## 4. Claude Code CLI 설치 + 인증

### 설치

```bash
# Node.js 설치 (Claude Code 실행에 필요)
brew install node

# Claude Code CLI 설치
npm install -g @anthropic-ai/claude-code

# 확인
claude --version
```

### 인증 (브라우저 필요)

**원격 환경 주의사항:**
Claude Code 최초 인증은 브라우저에서 OAuth 흐름을 완료해야 합니다.
SSH만으로는 브라우저를 열 수 없으므로, **이 단계에서만 화면 공유(VNC)를 사용하세요.**

1. VNC로 Mac Mini 화면에 연결
2. Mac Mini의 터미널에서:

```bash
claude
```

3. 첫 실행 시 브라우저가 열리며 Anthropic 로그인 화면이 나옵니다.
4. 로그인 후 인증 완료 → 터미널로 돌아옵니다.

이후에는 SSH에서 `claude` 명령이 인증 없이 작동합니다.

> **인증 만료 시:** 수 개월 후 만료될 수 있습니다.
> 만료되면 다시 VNC로 접속하여 `claude` 실행 → 재인증.

---

## 5. 레포 클론

SSH로 Mac Mini에 접속한 상태에서:

```bash
cd ~
git clone https://github.com/your-username/you_in_the_loop.git
cd you_in_the_loop
```

> **URL 교체:** `your-username`을 실제 GitHub 사용자명으로 교체하세요.

---

## 6. install.sh 실행

**실행 전: config.sh 편집**

```bash
nano ~/you_in_the_loop/scripts/config.sh
```

최소한 다음을 확인하세요:
- `TMUX_SESSION`: tmux 세션 이름 (기본값 `tso` 그대로도 OK)
- `AR_WINDOW`: AR Manager 창 이름 (기본값 `tso:ar-manager` OK)
- `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`: 사용 안 하면 빈 값으로 두세요

저장: `Ctrl+O` → `Enter` → `Ctrl+X`

**install.sh 실행:**

```bash
chmod +x ~/you_in_the_loop/scripts/install.sh
bash ~/you_in_the_loop/scripts/install.sh
```

약 30~60초 후 다음이 출력되면 설치 완료:

```
============================================
 설치 완료. secretary 창에서 claude를 시작하세요.
============================================
```

**install.sh가 하는 일:**
1. `context_logs/`, `ar_signal_queue/`, `dispatch_inbox/` 등 디렉토리 생성
2. crontab 등록 (dispatch_router, watch_signals, org_snapshot, daily_report)
3. `~/.claude/settings.json`에 permission_gate 훅 등록
4. tmux 세션 `tso` 생성 (secretary, ar-manager, worker-1~6 창)
5. `01_origin/self_state/`에 최소 자아 파일 복사

> **idempotent:** 이미 설치된 경우 중복 실행해도 안전합니다.

---

## 7. 첫 부팅 확인

```bash
# tmux 세션에 연결
tmux attach -t tso

# secretary 창으로 이동
# 방법 1: Ctrl+B 0 (창 번호로 이동)
# 방법 2: Ctrl+B w → secretary 선택

# Claude 시작
claude
```

약 10~30초 후 다음이 나오면 성공:

```
[부팅 완료]
자아 복원: ...
활성 역할: 주: secretary
준비 상태: 작업 가능
```

**처음 부팅이므로:**
- 이전 맥락 없음 메시지가 나오는 것은 정상입니다.
- Secretary가 `[READY] 이전 맥락 없음. dispatch 대기 중.` 이라고 하면 준비 완료.

**첫 대화:**

```
나: 안녕. 지금 상태 어때?
Secretary: [현재 상태 요약 + 다음 할 일 안내]
```

---

## 다음 단계

- **개념 이해:** `docs/01_concepts.md` — 왜 이 구조인지
- **첫 세션 가이드:** `docs/02_first-session.md` — dispatch 보내기, Worker 채용

---

## 트러블슈팅

| 문제 | 해결 |
|------|------|
| `claude: command not found` | `npm install -g @anthropic-ai/claude-code` 재실행. PATH 확인: `echo $PATH` |
| `brew: command not found` | Homebrew PATH 설정 확인 (2단계 말미의 eval 명령어) |
| tmux 세션 없음 | `bash ~/you_in_the_loop/scripts/install.sh` 재실행 (idempotent) |
| Claude 인증 만료 | VNC 접속 → `claude` 실행 → 브라우저 재인증 |
| `[부팅 완료]` 안 나옴 | `ls ~/you_in_the_loop/CLAUDE.md` 확인. 없으면 레포 재클론 |
| crontab 등록 안 됨 | `crontab -l` 로 확인. `install.sh` 재실행 |
| permission_gate 오류 | `ls ~/you_in_the_loop/scripts/permission_gate.sh` 확인. `chmod +x scripts/*.sh` |
| SSH 접속 안 됨 | Mac Mini 전원·네트워크 확인. Tailscale 사용 시 앱 실행 여부 확인 |

#!/bin/bash
# ============================================================
# you_in_the_loop — 시스템 설정
# 이 파일을 편집하여 시스템을 당신의 환경에 맞게 설정하세요.
# 모든 스크립트가 이 파일을 source 합니다.
# ============================================================

# TODO: 이 레포 이름. 기본값 그대로 쓰거나 원하는 이름으로 변경.
REPO_NAME="you_in_the_loop"
BASE="$HOME/$REPO_NAME"

# TODO: tmux 세션 이름. 'tmux new-session -s {이름}' 으로 생성한 세션 이름.
TMUX_SESSION="myteam"

# TODO: AR Manager tmux 창 이름 또는 인덱스. 예: "myteam:ar-manager" 또는 "myteam:3"
AR_WINDOW="${TMUX_SESSION}:ar-manager"
AR_FALLBACK="${TMUX_SESSION}:3"

# TODO: Telegram 알림 설정. 사용하지 않으면 빈 값으로 두세요.
# 설정 방법: https://core.telegram.org/bots#creating-a-new-bot
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# ── 파생 경로 (수정 불필요) ──
SIGNAL_DIR="$BASE/ar_signal_queue"
INBOX_DIR="$BASE/dispatch_inbox"
PERM_DIR="$BASE/permission_queue"
LOG_DIR="$BASE/context_logs"
STATUS_FILE="$BASE/tasks/worker_status.yaml"

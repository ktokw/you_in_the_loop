# Dispatch Inbox — 파일 기반 dispatch 라우팅 프로토콜

**목적:** Secretary의 tmux send-keys 직접 전달을 파일 기반으로 전환.
`dispatch_router.sh`가 1분마다 폴링하여 Worker에게 자동 전달.

---

## 파일 흐름

```
Secretary / TSO
    │ disp_*.yaml 파일 작성 (status: pending)
    ▼
dispatch_inbox/
    │ dispatch_router.sh (*/1 crontab) 폴링
    ▼
Worker tmux 창 (tmux paste-buffer)
    │ status → delivered
    ▼
Worker 작업 착수 → ar_signal_queue/ fyi 또는 직접 보고
```

---

## 파일 형식

파일명: `disp_{YYYYMMDD_HHMMSS}_{target}.yaml`

```yaml
id: "DISP-001-001"               # 고유 ID
target: "worker-vibe"             # tasks/worker_status.yaml의 name 필드와 일치
created_by: "secretary"
created_at: "2026-01-01T09:00:00"
status: "pending"                 # pending → delivered → done
priority: "urgent | normal | low"

packet: |
  [DISPATCH DISP-001-001]
  TO: worker-vibe
  PROJECT: {프로젝트명}
  PRIORITY: normal

  TASK: {작업 제목}

  DESCRIPTION:
  {작업 상세 설명}

  DONE WHEN:
  - {완료 조건 1}
  - {완료 조건 2}
```

---

## 상태 전이

```
pending → delivered → done
           (router)   (Worker 완료 후 AR Manager 수동 갱신)
```

---

## 주의사항

1. `target`은 `tasks/worker_status.yaml`의 `name` 필드와 정확히 일치해야 함
2. Worker 창이 없거나 tmux 세션이 없으면 SKIP 처리 (로그 확인 후 재시도)
3. 즉시 전달 필요 시: `bash ~/you_in_the_loop/scripts/dispatch_router.sh` 직접 실행

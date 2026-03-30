# Permission Queue — 에스컬레이션 처리 규약

**목적:** `permission_gate.sh`가 차단한 Worker 요청을 AR Manager가 처리하는 프로토콜.

---

## 파일 흐름

```
Worker (Claude 세션)
    │ permission_gate.sh → 에스컬레이션 판단
    ▼
permission_queue/{req_id}.json  (status: pending)
    │ AR Manager 확인
    ▼
처리 결정 (승인 / 거부 / TSO 에스컬레이션)
    │
    ▼
Worker에게 결과 전달 → status: resolved
```

---

## 에스컬레이션 요청 파일 형식

파일명: `{req_id}.json`  (예: `req_1711688400123.json`)

```json
{
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf dist/" },
  "reason": "rm on potentially important file",
  "timestamp": "2026-01-01T09:00:00",
  "req_id": "req_1711688400123",
  "worker_id": "tso:worker-vibe",
  "status": "pending"
}
```

---

## AR Manager 처리 절차

1. `permission_queue/*.json` 파일 확인 (gate.log 또는 watch_signals.sh 알림)
2. `worker_id` 확인 → 어느 Worker의 요청인지 파악
3. 판단:
   - **승인**: Worker 창에 "진행해도 됩니다" 전달 → status: resolved
   - **거부**: Worker 창에 "이 작업은 금지됩니다" + 대안 제시 → status: resolved
   - **TSO 에스컬레이션**: ar_signal_queue/에 escalation 작성 → Secretary 보고
4. 파일 status를 `resolved`로 업데이트

---

## 처리 완료 표시

```bash
# status 업데이트 (python)
python3 -c "
import json
with open('permission_queue/{req_id}.json') as f:
    d = json.load(f)
d['status'] = 'resolved'
d['resolved_by'] = 'ar-manager'
d['resolved_at'] = '$(date -Iseconds)'
d['decision'] = 'approved'  # 또는 'denied'
with open('permission_queue/{req_id}.json', 'w') as f:
    json.dump(d, f, indent=2)
"
```

---

## TSO 에스컬레이션 기준

AR Manager가 직접 처리하지 않고 TSO까지 올려야 하는 경우:
- 실매매 / 결제 관련 API 호출
- 외부 서비스 공개 (publish, deploy to production)
- 중요 파일의 비가역적 삭제
- 보안 자격증명 접근

---

## 감사 로그

모든 gate 결정은 `permission_queue/gate.log`에 자동 기록됩니다.

```
[timestamp] [worker:tso:worker-vibe] [task:DISP-001] [Bash] ESCALATE | rm on important file
[timestamp] [worker:tso:worker-vibe] [task:DISP-001] [Read] ALLOW | read-only tool
```

# AR Signal Queue — 파일 기반 신호 규약

**목적:** AR Manager 운영 교신이 Secretary 창에 쌓이지 않도록 파일 기반 신호 체계 도입

---

## 신호 흐름

```
스크립트/훅 (자동 처리)
      ↓ 이상 징후
AR Manager (판단·실행)
      ↓ YOU에게 가야 할 것만
ar_signal_queue/ 파일
      ↓
Secretary (수신·필터링·YOU 보고)
```

---

## 신호 파일 형식

파일명: `sig_{YYYYMMDD_HHMMSS}_{type}.yaml`

```yaml
type: "escalation" | "fyi" | "dispatch_req"
priority: "P0" | "P1" | "P2"
summary: "한 줄 요약"
action_needed: true | false
detail_ref: "세부 내용 파일 경로 또는 null"
created_by: "ar-manager"
created_at: "ISO8601"
status: "pending" | "received" | "resolved"
```

---

## 신호 타입별 처리

| type | 의미 | Secretary 행동 | YOU 보고 여부 |
|------|------|---------------|-------------|
| `escalation` | YOU 판단 필요 | YOU에게 즉시 전달 | 항상 |
| `fyi` | 정보성 (YOU 액션 불필요) | 맥락으로 흡수, 필요시만 보고 | 선택적 |
| `dispatch_req` | Secretary 전략 판단 요청 | 검토 후 승인/수정/거부 → AR Manager에 회신 | 선택적 |

---

## escalation 트리거 (AR Manager 판단 기준)

- 비용 발생 가능 액션 (유료 API, Stripe 등)
- 보안 위험 (외부 노출, 권한 상승, 돌이킬 수 없는 작업)
- 전략 방향 결정 필요 (채용/해고, 새 프로젝트 승인)
- Worker 소진 징후 (불만 악화, 장기 블로킹)
- 시스템 전체 영향 있는 변경

---

## Worker 간 직접 통신 금지

Worker가 다른 Worker 또는 AR Manager에게 완료를 알릴 때:
- **금지:** tmux send-keys로 다른 창에 직접 전송
- **허용:** `ar_signal_queue/sig_{timestamp}_fyi.yaml` 파일 작성

AR Manager가 신호 파일을 감지하여 후속 처리한다.

---

## 처리 완료 표시

`status: resolved`로 업데이트하거나 파일명에 `_resolved` 추가.
처리된 파일은 7일 후 정리 (자동화 또는 수동).

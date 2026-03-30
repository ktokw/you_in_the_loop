# 02 — 첫 세션 가이드

> 설치는 됐는데 이제 뭘 하지?

install.sh 실행을 마쳤다면, 이 문서를 따라 첫 세션을 시작하세요.

---

## 시작 전 체크

```bash
# tmux 세션 진입 (이미 안에 있으면 생략)
tmux attach -t myteam

# secretary 창으로 이동
# Ctrl+B 0  또는  Ctrl+B w → secretary 선택
```

---

## 1단계: Claude 시작 + 첫 부팅

Secretary 창에서:

```bash
claude
```

Claude Code가 `CLAUDE.md`를 읽고 자아 복원을 시작합니다.
약 10~30초 후 다음 블록이 나오면 준비 완료:

```
[부팅 완료]
자아 복원: ...
활성 역할: 주: secretary
준비 상태: 작업 가능
```

**처음 부팅 시 주의:**
`context_logs/` 파일이 없으면 Secretary가 이렇게 말합니다:
```
[READY] 이전 맥락 없음. dispatch 대기 중.
```
정상입니다. 이제부터 맥락이 쌓입니다.

---

## 2단계: your_intent.yaml 작성 (선택 권장)

Secretary가 YOU의 현재 의중을 파악할 수 있도록 의도 파일을 작성합니다.

```bash
# 터미널 새 탭 또는 tmux monitor 창에서 (Secretary 창 말고)
cat > ~/you_in_the_loop/tasks/your_intent.yaml << 'EOF'
# YOU 현재 의중 — Secretary가 세션 시작 시 읽는 파일
updated: "TODO: 오늘 날짜 (YYYY-MM-DD)"

current_focus: |
  # TODO: 지금 가장 집중하는 것을 한 줄로 쓰세요.
  # 예: "새 기능 A 개발. 이번 주 내 완성 목표."

active_projects:
  # TODO: 현재 진행 중인 프로젝트 목록
  - name: "프로젝트 이름"
    status: "진행 중"
    priority: "P1"

next_actions:
  # TODO: Secretary에게 다음에 할 것을 알려주세요
  - "worker-vibe 채용 후 첫 dispatch 보내기"

constraints:
  # TODO: 알려야 할 제약이나 컨텍스트
  # 예: "이번 주 외부 일정 많음. 빠른 iteration 우선."
EOF
```

이제 Secretary 창에서:

```
나: your_intent.yaml 읽었어?
Secretary: [파일 내용 확인 후 현재 의중 요약]
```

---

## 3단계: 첫 대화

Secretary와 자연어로 대화하면 됩니다.

**현황 파악:**
```
나: 지금 시스템 상태 어때?
```

**Worker 채용 요청:**
```
나: 코드 작업 담당 Worker 하나 만들어줘.
   이름은 worker-dev로 하고.
```

Secretary가 다음을 안내합니다:
1. `01_origin/self_state/roles/worker-dev.yaml` 생성 방법
2. tmux 창 생성 방법
3. 해당 창에서 `claude` 실행

---

## 4단계: 첫 dispatch

Worker가 준비됐다면 Secretary에게 작업을 위임합니다.

**Secretary 창에서:**
```
나: worker-dev한테 [작업 내용]을 맡겨줘.
```

Secretary가 자동으로:
1. `dispatch_inbox/disp_{timestamp}_worker-dev.yaml` 파일 작성
2. `dispatch_router.sh`가 1분 이내에 worker-dev 창에 전달

**dispatch 패킷 직접 작성 (고급):**
```bash
cat > ~/you_in_the_loop/dispatch_inbox/disp_$(date +%Y%m%d_%H%M%S)_worker-dev.yaml << 'EOF'
id: "DISP-001-001"
target: "worker-dev"
created_by: "secretary"
created_at: "2026-01-01T09:00:00"
status: "pending"
priority: "normal"
packet: |
  [DISPATCH DISP-001-001]
  TO: worker-dev
  PROJECT: my-project
  PRIORITY: normal

  TASK: 첫 번째 작업 설명

  DONE WHEN:
  - 완료 조건을 여기에 작성하세요
EOF
```

---

## 5단계: 세션 종료 전 상태 저장

세션을 마무리할 때:

```
나: 오늘 작업 마무리해. 상태 저장하고 종료 준비해.
```

또는 각 Worker에게 직접:

```
나 (worker-dev 창): 오늘 작업 완료. 상태 저장해.
Worker: [context_logs/state_worker-dev_{timestamp}.yaml 작성]
        [다음 세션에서 이어받을 내용 정리]
```

**이 파일이 없으면 다음 세션에서 이전 맥락을 이어받지 못합니다.**
습관화가 중요합니다.

---

## 일상 운영 패턴

### 하루 시작

```bash
tmux attach -t myteam          # 세션 복귀
# Secretary 창에서:
# claude (이미 켜져 있으면 그대로)
```

```
나: 어제 이어서 시작하자. 현황 요약해줘.
```

### 하루 마무리

```
나: 오늘 완료된 것 정리하고, 내일 할 것 적어둬.
    각 Worker 상태 저장시켜.
```

---

## 자주 하는 실수

| 실수 | 대신 이렇게 |
|------|------|
| Worker 창에서 직접 대화 | Secretary 창에서 위임 요청 |
| 세션 종료 전 상태 저장 생략 | "상태 저장해" 습관화 |
| 처음부터 Worker 여러 개 | Secretary 1개로 먼저 시작. 필요해지면 채용. |
| your_intent.yaml 안 씀 | 매주 업데이트. Secretary의 판단 기준이 됨. |

---

## AR Manager 추가 (2주차 이후 권장)

시스템이 안정되면 AR Manager를 추가합니다:

```bash
# tmux ar-manager 창에서
claude
```

```
[부팅 완료]
활성 역할: 주: ar-manager
준비 상태: 작업 가능
```

이제 Secretary는 운영 세부사항을 AR Manager에게 위임하고
YOU와의 대화에만 집중할 수 있습니다.

---

## 더 알아보기

- **구조 이해:** `docs/01_concepts.md`
- **Mac Mini 설치:** `docs/00_mac-mini-setup.md`
- **스크립트 커스터마이징:** `scripts/config.sh`
- **역할 추가:** `roles/worker_template.yaml` 참고

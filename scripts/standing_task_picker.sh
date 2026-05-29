#!/usr/bin/env bash
# standing_task_picker.sh — cooldown 경과한 standing task 자동 출력
# IMP-S-005: 매번 YAML 읽고 수동 계산하는 오버헤드 제거
#
# 사용법: bash scripts/standing_task_picker.sh worker-engineer
# 출력: cooldown 경과한 항목 목록 (없으면 "없음")

set -uo pipefail

TSO_DIR="$HOME/you_in_the_loop"
ROLE="${1:-}"

if [ -z "$ROLE" ]; then
    echo "Usage: bash scripts/standing_task_picker.sh {role}" >&2
    echo "  예: bash scripts/standing_task_picker.sh worker-engineer" >&2
    exit 1
fi

STANDING_FILE="$TSO_DIR/tasks/standing_tasks/${ROLE}.yaml"
if [ ! -f "$STANDING_FILE" ]; then
    echo "ERROR: $STANDING_FILE 없음" >&2
    exit 1
fi

python3 << PYEOF
import re, os, glob, json
from datetime import datetime, timezone

TSO_DIR = os.path.expanduser("~/you_in_the_loop")
STANDING_FILE = "$STANDING_FILE"
ROLE = "$ROLE"

# standing_tasks YAML 파싱 (간이)
with open(STANDING_FILE) as f:
    content = f.read()

# 각 task 블록 파싱
tasks = []
blocks = re.split(r'\n- id:', content)  # DEF-20260410-25: 0-space (루트레벨 list)
for i, block in enumerate(blocks):
    if i == 0 and 'id:' not in block:
        continue
    if i > 0:
        block = '- id:' + block

    id_m = re.search(r'id:\s*(\S+)', block)
    task_m = re.search(r'task:\s*"(.+?)"', block)
    cooldown_m = re.search(r'cooldown:\s*(\d+)\s*([hdm])', block)
    priority_m = re.search(r'priority:\s*(\w+)', block)
    last_run_m = re.search(r"last_run:\s*['\"]?([^'\"\\n]+)['\"]?", block)

    if not id_m:
        continue

    task_id = id_m.group(1)
    # task 필드: 따옴표 있는 경우와 없는 경우 모두 처리
    if task_m:
        task_desc = task_m.group(1)
    else:
        task_plain = re.search(r'task:\s*(.+)', block)
        task_desc = task_plain.group(1).strip() if task_plain else ""
    priority = priority_m.group(1) if priority_m else "medium"

    UNIT_SEC = {"h": 3600, "d": 86400, "m": 60}
    cooldown_sec = 0
    if cooldown_m:
        val = int(cooldown_m.group(1))
        unit = cooldown_m.group(2)
        cooldown_sec = val * UNIT_SEC.get(unit, 3600)

    last_run = last_run_m.group(1).strip() if last_run_m else ""

    tasks.append({
        "id": task_id,
        "task": task_desc,
        "priority": priority,
        "cooldown_sec": cooldown_sec,
        "last_run": last_run,
    })

# worklog에서 각 task의 마지막 완료 시각 찾기
now = datetime.now(timezone.utc)
worklog_files = sorted(glob.glob(f"{TSO_DIR}/context_logs/worklog_*.jsonl"))

last_done = {}
for wf in worklog_files:
    try:
        with open(wf) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    if entry.get("event") == "disp_done":
                        disp = entry.get("disp", "")
                        ts_str = entry.get("ts", "")
                        if disp and ts_str:
                            last_done[disp] = ts_str
                except json.JSONDecodeError:
                    continue
    except Exception:
        continue

# cooldown 판정 — last_run (YAML) primary, worklog fallback (DEF-20260409-12)
available = []
for t in tasks:
    tid = t["id"]
    # primary: YAML last_run 필드, fallback: worklog disp_done
    last_ts = t.get("last_run", "") or last_done.get(tid, "")

    if not last_ts:
        # 한 번도 실행 안 됨 → 즉시 가능
        available.append((t, "한 번도 실행 안 됨"))
        continue

    try:
        # ISO 형식 파싱
        ts_clean = last_ts.replace("Z", "+00:00")
        if "+" not in ts_clean and "-" not in ts_clean[10:]:
            ts_clean += "+00:00"
        last_dt = datetime.fromisoformat(ts_clean)
        if last_dt.tzinfo is None:
            last_dt = last_dt.replace(tzinfo=timezone.utc)
        elapsed = (now - last_dt).total_seconds()

        if elapsed >= t["cooldown_sec"]:
            hours = int(elapsed / 3600)
            available.append((t, f"마지막 실행 {hours}시간 전"))
    except Exception:
        available.append((t, f"시각 파싱 실패 ({last_ts})"))

# 출력
if not available:
    print("착수 가능한 standing task 없음 (전부 cooldown 중)")
else:
    print(f"착수 가능: {len(available)}건")
    print()
    for t, reason in available:
        print(f"  [{t['priority'].upper():6s}] {t['id']}")
        print(f"          {t['task']}")
        print(f"          ({reason})")
        print()
PYEOF

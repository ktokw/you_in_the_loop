#!/usr/bin/env python3
"""
TSO Dashboard Server — FastAPI + vanilla HTML
DISP-ENG-DASHBOARD-MVP-001 | worker-engineer-finn

Usage:
  python3 scripts/dashboard_server.py
  # → http://localhost:8080
"""

import json
import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml
from fastapi import FastAPI
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel
from fastapi.staticfiles import StaticFiles

ROOT = Path("~/tso_in_the_loop").expanduser()
STATIC_DIR = ROOT / "static"

app = FastAPI(title="TSO Dashboard", docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


def safe_yaml_load(path: Path) -> dict | None:
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8", errors="ignore"))
    except Exception:
        return None


def safe_json_load(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="ignore"))
    except Exception:
        return None


# ─── API: Workers ───

def _stale_dispatch_workers(now: datetime) -> set[str]:
    """Return set of worker names that have an in_progress dispatch created >2h ago."""
    stale = set()
    cutoff = now - timedelta(hours=2)
    for dir_path in [ROOT / "dispatch_inbox", ROOT / "tasks/dispatches"]:
        if not dir_path.exists():
            continue
        for f in dir_path.glob("*.yaml"):
            data = safe_yaml_load(f)
            if not data or data.get("status") != "in_progress":
                continue
            created = data.get("created_at", "")
            try:
                dt = datetime.fromisoformat(str(created).replace("Z", "+00:00"))
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                if dt < cutoff:
                    target = str(data.get("target", ""))
                    stale.add(target)
            except Exception:
                pass
    return stale


def _health(ctx_pct, idle_min, blocked: bool, stale: bool) -> str:
    """
    green  = healthy
    yellow = ctx_pct < 50  OR  idle > 20 min
    red    = ctx_pct < 20  OR  permission_blocked  OR  stale in_progress dispatch
    """
    if (ctx_pct is not None and ctx_pct < 20) or blocked or stale:
        return "red"
    if (ctx_pct is not None and ctx_pct < 50) or (idle_min is not None and idle_min > 20):
        return "yellow"
    return "green"


@app.get("/api/workers")
def get_workers():
    data = safe_json_load(ROOT / "worker_status.json")
    if not data:
        return []
    workers = []
    now = datetime.now(timezone.utc)
    stale_workers = _stale_dispatch_workers(now)
    for name, info in data.items():
        idle_since = info.get("idle_since")
        idle_min = None
        if idle_since:
            try:
                idle_dt = datetime.fromisoformat(idle_since.replace("Z", "+00:00"))
                idle_min = int((now - idle_dt).total_seconds() / 60)
            except Exception:
                pass
        ctx_pct = info.get("ctx_pct")
        blocked = bool(info.get("permission_blocked", False))
        rate_limited = bool(info.get("rate_limited", False))
        stale = any(name in t for t in stale_workers)
        workers.append({
            "name": name,
            "display_name": info.get("name", name.split("-")[-1].capitalize()),
            "status": info.get("status", "unknown"),
            "ctx_pct": ctx_pct,
            "window": info.get("window", ""),
            "updated_at": info.get("updated_at", ""),
            "idle_min": idle_min,
            "last_completed": info.get("last_completed", ""),
            "note": info.get("note", ""),
            "rate_limited": rate_limited,
            "health": _health(ctx_pct, idle_min, blocked, stale),
        })
    workers.sort(key=lambda w: (
        0 if w["status"] == "working" else 1 if w["status"] in ("대기", "idle") else 2,
        w["name"],
    ))
    return workers


# ─── API: Dispatches ───

@app.get("/api/dispatches")
def get_dispatches(status: str = None, hours: int = 48):
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    dispatches = []

    for dir_path in [ROOT / "dispatch_inbox", ROOT / "tasks/dispatches"]:
        if not dir_path.exists():
            continue
        for f in dir_path.glob("*.yaml"):
            data = safe_yaml_load(f)
            if not data or not isinstance(data, dict):
                continue
            d_status = data.get("status", "unknown")
            if status and d_status != status:
                continue
            created = data.get("created_at", "")
            try:
                dt = datetime.fromisoformat(str(created).replace("Z", "+00:00"))
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                if dt < cutoff:
                    continue
            except Exception:
                pass
            dispatches.append({
                "id": data.get("id", f.stem),
                "title": data.get("title", ""),
                "target": data.get("target", ""),
                "priority": data.get("priority", ""),
                "status": d_status,
                "created_at": str(created),
            })

    dispatches.sort(key=lambda d: d["created_at"], reverse=True)
    return dispatches[:100]


# ─── API: Signals ───

@app.get("/api/signals")
def get_signals(limit: int = 20):
    sig_dir = ROOT / "ar_signal_queue"
    if not sig_dir.exists():
        return []
    signals = []
    files = sorted(sig_dir.glob("*.yaml"), key=lambda f: f.stat().st_mtime, reverse=True)
    for f in files[:limit * 2]:
        data = safe_yaml_load(f)
        if not data or not isinstance(data, dict):
            continue
        signals.append({
            "id": data.get("id", f.stem),
            "type": data.get("type", "unknown"),
            "from": data.get("from", ""),
            "to": data.get("to", ""),
            "subject": data.get("subject", data.get("summary", "")),
            "status": data.get("status", ""),
            "priority": data.get("priority", ""),
            "created_at": str(data.get("created_at", "")),
        })
        if len(signals) >= limit:
            break
    return signals


# ─── API: Commits ───

@app.get("/api/commits")
def get_commits(n: int = 20):
    try:
        result = subprocess.run(
            ["git", "log", f"--oneline", f"-{n}", "--format=%h|%ai|%s"],
            capture_output=True, text=True, cwd=str(ROOT), timeout=5,
        )
        commits = []
        for line in result.stdout.strip().split("\n"):
            if not line:
                continue
            parts = line.split("|", 2)
            if len(parts) == 3:
                commits.append({
                    "hash": parts[0],
                    "date": parts[1][:16],
                    "message": parts[2],
                })
        return commits
    except Exception:
        return []


# ─── API: Alerts ───

@app.get("/api/alerts")
def get_alerts():
    alerts = {"stale": 0, "idle": 0, "low_ctx": 0, "compact_loop": 0, "items": []}
    sig_dir = ROOT / "ar_signal_queue"
    if not sig_dir.exists():
        return alerts

    for f in sig_dir.glob("*.yaml"):
        data = safe_yaml_load(f)
        if not data or not isinstance(data, dict):
            continue
        anomaly_type = data.get("anomaly_type", "")
        if data.get("type") == "anomaly_alert" or "ANOMALY" in str(data.get("subject", "")):
            if "STALE" in anomaly_type or "STALE" in str(data.get("subject", "")):
                alerts["stale"] += 1
            elif "IDLE" in anomaly_type or "IDLE" in str(data.get("subject", "")):
                alerts["idle"] += 1
            elif "LOW_CTX" in anomaly_type or "LOW_CTX" in str(data.get("subject", "")):
                alerts["low_ctx"] += 1
            elif "COMPACT" in anomaly_type or "COMPACT" in str(data.get("subject", "")):
                alerts["compact_loop"] += 1
            alerts["items"].append({
                "type": anomaly_type,
                "subject": data.get("subject", ""),
                "created_at": str(data.get("created_at", "")),
            })

    alerts["items"] = alerts["items"][-10:]
    return alerts


# ─── API: Worklog ───

@app.get("/api/worklog")
def get_worklog(limit: int = 50):
    log_dir = ROOT / "context_logs"
    if not log_dir.exists():
        return []
    entries = []
    files = sorted(log_dir.glob("worklog_*.jsonl"), key=lambda f: f.name, reverse=True)
    for f in files[:5]:
        try:
            lines = f.read_text(encoding="utf-8", errors="ignore").strip().split("\n")
            for line in reversed(lines):
                if not line.strip():
                    continue
                try:
                    entry = json.loads(line)
                    entries.append(entry)
                except json.JSONDecodeError:
                    pass
                if len(entries) >= limit:
                    break
        except Exception:
            pass
        if len(entries) >= limit:
            break
    return entries[:limit]


# ═══════════════════════════════════════════════════════════════
# Infrastructure APIs (Engineering Tabs)
# ═══════════════════════════════════════════════════════════════

# ─── API: tmux ───

@app.get("/api/infra/tmux")
def get_tmux():
    try:
        result = subprocess.run(
            ["tmux", "list-windows", "-t", "tso", "-F",
             "#{window_index}|#{window_name}|#{window_panes}|#{window_active}|#{pane_current_command}"],
            capture_output=True, text=True, timeout=5,
        )
        windows = []
        for line in result.stdout.strip().split("\n"):
            if not line:
                continue
            parts = line.split("|", 4)
            if len(parts) >= 4:
                windows.append({
                    "index": parts[0],
                    "name": parts[1],
                    "panes": parts[2],
                    "active": parts[3] == "1",
                    "command": parts[4] if len(parts) > 4 else "",
                })
        return windows
    except Exception:
        return []


# ─── API: Cron ───

@app.get("/api/infra/cron")
def get_cron():
    try:
        result = subprocess.run(
            ["crontab", "-l"], capture_output=True, text=True, timeout=5,
        )
        entries = []
        comment = ""
        for line in result.stdout.strip().split("\n"):
            line = line.strip()
            if not line:
                comment = ""
                continue
            if line.startswith("#"):
                comment = line.lstrip("# ")
                continue
            parts = line.split(None, 5)
            if len(parts) >= 6:
                entries.append({
                    "schedule": " ".join(parts[:5]),
                    "command": parts[5],
                    "description": comment,
                })
                comment = ""
        return entries
    except Exception:
        return []


# ─── API: Hooks ───

@app.get("/api/infra/hooks")
def get_hooks():
    settings_path = ROOT / ".claude" / "settings.local.json"
    data = safe_json_load(settings_path)
    if not data or "hooks" not in data:
        return []
    hooks = []
    for event, hook_list in data.get("hooks", {}).items():
        for entry in hook_list:
            matcher = entry.get("matcher", "")
            for h in entry.get("hooks", []):
                cmd = h.get("command", "")
                # Extract script name from command
                script = cmd.split("/")[-1].split(" ")[0] if "/" in cmd else cmd[:60]
                hooks.append({
                    "event": event,
                    "matcher": matcher,
                    "type": h.get("type", ""),
                    "script": script,
                    "command": cmd,
                })
    return hooks


# ─── API: Scripts ───

@app.get("/api/infra/scripts")
def get_scripts():
    scripts_dir = ROOT / "scripts"
    if not scripts_dir.exists():
        return []
    items = []
    for f in sorted(scripts_dir.iterdir()):
        if f.is_file() and f.suffix in (".sh", ".py"):
            first_line = ""
            try:
                with open(f, "r", encoding="utf-8", errors="ignore") as fh:
                    for line in fh:
                        line = line.strip()
                        if line.startswith("#!"):
                            continue
                        if line.startswith("#") or line.startswith('"""') or line.startswith("'''"):
                            first_line = line.strip("#\"' ")
                            break
                        if line:
                            first_line = line[:80]
                            break
            except Exception:
                pass
            stat = f.stat()
            items.append({
                "name": f.name,
                "size": stat.st_size,
                "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%m-%d %H:%M"),
                "description": first_line[:100],
            })
    return items


# ─── API: Rules ───

@app.get("/api/infra/rules")
def get_rules():
    items = []
    for dir_name, label in [
        (ROOT / ".claude" / "rules", "rules"),
        (ROOT / ".claude" / "agents", "agents"),
    ]:
        if not dir_name.exists():
            continue
        for f in sorted(dir_name.glob("*.md")):
            title = ""
            try:
                for line in f.read_text(encoding="utf-8", errors="ignore").split("\n"):
                    line = line.strip()
                    if line.startswith("#"):
                        title = line.lstrip("# ")
                        break
                    if line:
                        title = line[:80]
                        break
            except Exception:
                pass
            items.append({
                "category": label,
                "name": f.name,
                "title": title,
                "size": f.stat().st_size,
            })
    return items


# ─── API: Protocols ───

@app.get("/api/infra/protocols")
def get_protocols():
    items = []
    proto_dir = ROOT / "01_origin" / "protocols"
    if not proto_dir.exists():
        proto_dir = ROOT
    for search_dir, pattern in [
        (ROOT / "01_origin" / "protocols", "*.yaml"),
        (ROOT / "01_origin" / "protocols", "*.md"),
    ]:
        if not search_dir.exists():
            continue
        for f in sorted(search_dir.glob(pattern)):
            data = safe_yaml_load(f) if f.suffix in (".yaml", ".yml") else None
            title = ""
            version = ""
            if data and isinstance(data, dict):
                title = data.get("title", data.get("name", ""))
                version = str(data.get("version", ""))
            if not title:
                try:
                    for line in f.read_text(encoding="utf-8", errors="ignore").split("\n"):
                        line = line.strip()
                        if line.startswith("#"):
                            title = line.lstrip("# ")
                            break
                        if line and not line.startswith("---"):
                            title = line[:80]
                            break
                except Exception:
                    pass
            items.append({
                "name": f.name,
                "title": title,
                "version": version,
                "modified": datetime.fromtimestamp(f.stat().st_mtime).strftime("%m-%d %H:%M"),
            })
    # Also scan dispatch_protocol and backlog files
    for extra in [
        ROOT / "dispatch_inbox" / "PROTOCOL.md",
        ROOT / "tasks" / "infra" / "autonomous_improvement" / "change_log.yaml",
        ROOT / "tasks" / "infra" / "autonomous_improvement" / "deficiency_log.yaml",
    ]:
        if extra.exists():
            title = ""
            try:
                for line in extra.read_text(encoding="utf-8", errors="ignore").split("\n"):
                    line = line.strip()
                    if line.startswith("#"):
                        title = line.lstrip("# ")
                        break
            except Exception:
                pass
            items.append({
                "name": str(extra.relative_to(ROOT)),
                "title": title,
                "version": "",
                "modified": datetime.fromtimestamp(extra.stat().st_mtime).strftime("%m-%d %H:%M"),
            })
    return items


# ─── API: History ───

@app.get("/api/infra/history")
def get_history(tab: str = "scripts", date: str = ""):
    path_map = {
        "tmux": "",
        "cron": "",
        "hooks": ".claude/settings.local.json",
        "scripts": "scripts/",
        "rules": ".claude/rules/ .claude/agents/",
        "protocols": "01_origin/protocols/",
    }
    target = path_map.get(tab, "")
    if not target or not date:
        return []
    try:
        from datetime import date as _date, timedelta as _td
        since = date
        # DEF-20260413-32: 월말/연말 경계 처리 — 수동 +1 → datetime.date 산술로 교체
        # 이전: until_day = int(until_parts[2]) + 1 → "2026-04-31", "2026-12-32" 같은 잘못된 날짜 생성
        until = str(_date.fromisoformat(date) + _td(days=1))
        cmd = [
            "git", "log", f"--since={since}", f"--until={until}",
            "--format=%h|%ai|%s", "--diff-filter=ACDMR", "--name-only", "--",
        ] + target.split()
        result = subprocess.run(
            cmd, capture_output=True, text=True, cwd=str(ROOT), timeout=10,
        )
        entries = []
        current = None
        for line in result.stdout.strip().split("\n"):
            if not line:
                if current:
                    entries.append(current)
                    current = None
                continue
            if "|" in line and line[0] != " ":
                parts = line.split("|", 2)
                if len(parts) == 3:
                    if current:
                        entries.append(current)
                    current = {
                        "hash": parts[0],
                        "date": parts[1][:16],
                        "message": parts[2],
                        "files": [],
                    }
            elif current:
                current["files"].append(line.strip())
        if current:
            entries.append(current)
        return entries
    except Exception:
        return []


# ═══════════════════════════════════════════════════════════════
# Projects API
# ═══════════════════════════════════════════════════════════════


@app.get("/api/projects")
def get_projects():
    """Aggregate dispatches by project field."""
    projects = {}  # project_name -> {total, sent, in_progress, done, dispatched, workers, recent}

    for dir_path in [ROOT / "dispatch_inbox", ROOT / "tasks/dispatches"]:
        if not dir_path.exists():
            continue
        for f in dir_path.glob("*.yaml"):
            data = safe_yaml_load(f)
            if not data or not isinstance(data, dict):
                continue
            proj = str(data.get("project", "")).strip().strip('"').strip("'")
            if not proj:
                proj = "untagged"
            # Normalize: take first part before " / "
            proj_key = proj.split(" / ")[0].strip()
            if proj_key not in projects:
                projects[proj_key] = {
                    "name": proj_key,
                    "total": 0, "sent": 0, "in_progress": 0,
                    "done": 0, "dispatched": 0, "other": 0,
                    "workers": set(),
                    "recent": [],
                }
            p = projects[proj_key]
            p["total"] += 1
            status = data.get("status", "unknown")
            if status in ("sent", "in_progress", "done", "dispatched"):
                p[status] = p.get(status, 0) + 1
            else:
                p["other"] += 1
            target = data.get("target", "")
            if target:
                p["workers"].add(target.split("-")[-1])
            created = str(data.get("created_at", ""))
            p["recent"].append({
                "id": data.get("id", f.stem),
                "title": data.get("title", ""),
                "status": status,
                "target": target,
                "created_at": created,
            })

    result = []
    for proj_key, p in projects.items():
        p["workers"] = sorted(p["workers"])
        p["recent"] = sorted(p["recent"], key=lambda d: d["created_at"], reverse=True)[:5]
        active = p["sent"] + p["in_progress"] + p["dispatched"]
        p["active"] = active
        result.append(p)

    result.sort(key=lambda p: (p["active"], p["total"]), reverse=True)
    return result


# ═══════════════════════════════════════════════════════════════
# Flow APIs (Mermaid Diagrams)
# ═══════════════════════════════════════════════════════════════


@app.get("/api/flow/org")
def flow_org():
    """Organization chart — dynamic node colors from worker_status.json."""
    data = safe_json_load(ROOT / "worker_status.json") or {}
    lines = [
        "graph TD",
        '  TSO["🧑 TSO"]',
        '  Marcus["📋 Marcus<br/>AR Manager"]',
        "  TSO --> Marcus",
        '  TSO -.->|"직접 관할"| Eli["✍️ Eli<br/>Writer"]',
    ]
    worker_map = {
        "secretary-morgan": ("Morgan", "Secretary", "📌"),
        "worker-vibe-reef": ("Reef", "Vibe", "🎨"),
        "worker-paper-elliot": ("Elliot", "Paper", "📝"),
        "worker-qa-vera": ("Vera", "QA", "🔍"),
        "worker-architect-luca": ("Luca", "Architect", "🏗️"),
        "worker-engineer-kai": ("Kai", "Engineer", "⚙️"),
        "worker-engineer-finn": ("Finn", "Engineer", "⚙️"),
        "worker-engineer-leo": ("Leo", "Engineer", "⚙️"),
        "worker-growth-ivy": ("Ivy", "Growth", "📈"),
        "worker-sentinel-felix": ("Felix", "Sentinel", "🛡️"),
    }
    for key, (name, role, icon) in worker_map.items():
        info = data.get(key, {})
        status = info.get("status", "unknown")
        ctx = info.get("ctx_pct", "?")
        node_id = name
        lines.append(f'  {node_id}["{icon} {name}<br/>{role} | ctx {ctx}%"]')
        lines.append(f"  Marcus --> {node_id}")
    # Style classes
    lines.append("")
    lines.append("  classDef working fill:#238636,stroke:#3fb950,color:#fff")
    lines.append("  classDef idle fill:#9e6a03,stroke:#d29922,color:#fff")
    lines.append("  classDef unknown fill:#30363d,stroke:#8b949e,color:#e6edf3")
    for key, (name, _, _) in worker_map.items():
        info = data.get(key, {})
        status = info.get("status", "unknown")
        css_class = "working" if status == "working" else "idle" if status in ("대기", "idle") else "unknown"
        lines.append(f"  class {name} {css_class}")
    # Eli status
    eli_info = data.get("worker-writer-eli", {})
    eli_class = "working" if eli_info.get("status") == "working" else "idle"
    lines.append(f"  class Eli {eli_class}")
    lines.append("  class TSO working")
    lines.append("  class Marcus working")
    return {"mermaid": "\n".join(lines)}


@app.get("/api/flow/dispatch")
def flow_dispatch():
    """Dispatch lifecycle flow — highlights active dispatches."""
    # Count active dispatches by status
    status_counts = {"sent": 0, "in_progress": 0, "done": 0}
    for f in (ROOT / "dispatch_inbox").glob("*.yaml"):
        d = safe_yaml_load(f)
        if d and isinstance(d, dict):
            s = d.get("status", "")
            if s in status_counts:
                status_counts[s] += 1

    lines = [
        "graph LR",
        '  TSO["🧑 TSO<br/>지시/승인"]',
        '  Marcus["📋 Marcus<br/>판단/발령"]',
        f'  Sent[\"📨 sent<br/>{status_counts["sent"]}건\"]',
        f'  InProgress[\"🔧 in_progress<br/>{status_counts["in_progress"]}건\"]',
        f'  Done[\"✅ done<br/>{status_counts["done"]}건\"]',
        '  FYI["📩 FYI 신호"]',
        "",
        "  TSO -->|지시| Marcus",
        "  Marcus -->|dispatch 발령| Sent",
        "  Sent -->|Worker 착수| InProgress",
        "  InProgress -->|완료| Done",
        "  Done -->|fyi| FYI",
        "  FYI -->|보고| Marcus",
        "  Marcus -.->|에스컬레이션| TSO",
        "",
        "  classDef active fill:#238636,stroke:#3fb950,color:#fff",
        "  classDef waiting fill:#1f6feb,stroke:#58a6ff,color:#fff",
        "  classDef completed fill:#30363d,stroke:#8b949e,color:#e6edf3",
    ]
    if status_counts["sent"] > 0:
        lines.append("  class Sent waiting")
    if status_counts["in_progress"] > 0:
        lines.append("  class InProgress active")
    return {"mermaid": "\n".join(lines)}


@app.get("/api/flow/data")
def flow_data():
    """Data flow diagram — file-system communication structure."""
    lines = [
        "graph TD",
        '  subgraph "📁 File System Communication"',
        '    DI["dispatch_inbox/<br/>*.yaml"]',
        '    ASQ["ar_signal_queue/<br/>fyi / alert / anomaly"]',
        '    WS["worker_status.json"]',
        '    CL["context_logs/<br/>state / worklog"]',
        '    TD["tso_decision_queue.yaml"]',
        "  end",
        "",
        # DEF-20260413-35: 스테일 cron 항목 제거 — dispatch_router.sh·marcus_cron.sh는
        # EVENT_REPLACED로 crontab에서 비활성화됨. event_daemon.sh(launchd)로 대체.
        # 실제 가동 중인 cron 작업으로 업데이트.
        '  subgraph "⚙️ Cron / Daemon"',
        '    ED["event_daemon.sh<br/>(launchd)"]',
        '    WW["worker_watchdog.sh<br/>매 5분"]',
        '    SK["session_keepalive.sh<br/>매 5분"]',
        '    OS["org_snapshot.sh<br/>매 10분"]',
        '    CT["collect_token_usage.py<br/>매 30분"]',
        '    AD["archive_dispatches.sh<br/>매일 00:00"]',
        '    SG["state_gc.sh<br/>매일 04:00"]',
        '    RP["daily_report.sh<br/>매일 09:00"]',
        "  end",
        "",
        '  subgraph "🪝 Hooks"',
        '    HA["Hook A: Stop 자동저장"]',
        '    HB["Hook B: PostCompact"]',
        '    HF["Hook F: Signal 중복방지"]',
        "  end",
        "",
        '  subgraph "📊 Dashboard"',
        '    DASH["dashboard_server.py<br/>:8080"]',
        "  end",
        "",
        "  ED -->|dispatch 스캔| DI",
        "  ED -->|dispatch 전달| Worker",
        "  WW -->|읽기| WS",
        "  WW -->|alert 생성| ASQ",
        "  SK -->|세션 유지| WS",
        "  OS -->|스냅샷 저장| CL",
        "  CT -->|토큰 기록| CL",
        "  AD -->|dispatch 아카이브| DI",
        "  SG -->|state 정리| CL",
        "  RP -->|리포트 발신| ASQ",
        "  HA -->|state 저장| CL",
        "  HB -->|resume flag| CL",
        "  HF -->|중복 체크| ASQ",
        "",
        "  DASH -->|읽기| WS",
        "  DASH -->|읽기| DI",
        "  DASH -->|읽기| ASQ",
        "  DASH -->|읽기| CL",
        "",
        '  Worker["🔧 Workers"] -->|fyi/done 발신| ASQ',
        "  Worker -->|상태 갱신| WS",
        "  Worker -->|state 저장| CL",
        "",
        "  classDef storage fill:#1f6feb,stroke:#58a6ff,color:#fff",
        "  classDef process fill:#238636,stroke:#3fb950,color:#fff",
        "  classDef hook fill:#8957e5,stroke:#bc8cff,color:#fff",
        "  classDef dash fill:#9e6a03,stroke:#d29922,color:#fff",
        "  class DI,ASQ,WS,CL,TD storage",
        "  class ED,WW,SK,OS,CT,AD,SG,RP process",
        "  class HA,HB,HF hook",
        "  class DASH dash",
    ]
    return {"mermaid": "\n".join(lines)}


@app.get("/api/flow/events")
def flow_events():
    """Event pipeline — fswatch-based event-driven design (Luca)."""
    lines = [
        "graph LR",
        '  subgraph "이벤트 소스"',
        '    S1["ar_signal_queue/<br/>파일 생성"]',
        '    S2["dispatch_inbox/<br/>파일 수정"]',
        '    S3["worker_status.json<br/>상태 변경"]',
        '    S4["tso_decisions/<br/>결정 생성"]',
        "  end",
        "",
        '  FSW["👁️ fswatch<br/>kqueue 감지"]',
        '  AR["action_router.sh<br/>이벤트 분류"]',
        "",
        '  subgraph "행동"',
        '    A1["DONE signal<br/>→ 후속 dispatch"]',
        '    A2["BLOCKED<br/>→ 에스컬레이션"]',
        '    A3["TSO 결정<br/>→ Marcus 전파"]',
        '    A4["FYI<br/>→ 로그 기록"]',
        '    A5["dispatch 변경<br/>→ Worker 알림"]',
        "  end",
        "",
        "  S1 --> FSW",
        "  S2 --> FSW",
        "  S3 --> FSW",
        "  S4 --> FSW",
        "  FSW --> AR",
        "  AR --> A1",
        "  AR --> A2",
        "  AR --> A3",
        "  AR --> A4",
        "  AR --> A5",
        "",
        '  subgraph "전환 현황"',
        '    DONE["✅ EVENT 전환 대상: 4개<br/>dispatch_router, watch_signals,<br/>marcus_cron, watchdog 일부"]',
        '    KEEP["📌 CRON 유지: 3개<br/>org_snapshot, archive,<br/>daily_report"]',
        "  end",
        "",
        "  classDef source fill:#1f6feb,stroke:#58a6ff,color:#fff",
        "  classDef engine fill:#238636,stroke:#3fb950,color:#fff",
        "  classDef action fill:#9e6a03,stroke:#d29922,color:#fff",
        "  classDef status fill:#30363d,stroke:#8b949e,color:#e6edf3",
        "  class S1,S2,S3,S4 source",
        "  class FSW,AR engine",
        "  class A1,A2,A3,A4,A5 action",
        "  class DONE,KEEP status",
    ]
    return {"mermaid": "\n".join(lines)}


# ═══════════════════════════════════════════════════════════════
# Action APIs (TSO 직접 조작)
# ═══════════════════════════════════════════════════════════════


class WorkerMessage(BaseModel):
    message: str


class RejectBody(BaseModel):
    reason: str = ""


class PermissionResolve(BaseModel):
    decision: str  # "allow" or "deny"
    reason: str = ""


@app.post("/api/worker/{name}/message")
def send_worker_message(name: str, body: WorkerMessage):
    """Send a message to a Worker via tmux send-keys."""
    # Find window name from worker_status.json
    data = safe_json_load(ROOT / "worker_status.json") or {}
    window = None
    for key, info in data.items():
        worker_short = key.split("-")[-1]
        if worker_short == name or key == name or info.get("name", "") == name:
            window = info.get("window", "")
            break
    if not window:
        return {"ok": False, "error": f"Worker '{name}' not found"}
    try:
        # Escape single quotes in the message
        safe_msg = body.message.replace("'", "'\\''")
        subprocess.run(
            ["tmux", "send-keys", "-t", window, safe_msg, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        return {"ok": True, "window": window, "message": body.message}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/dispatch/{disp_id}/approve")
def approve_dispatch(disp_id: str):
    """Approve a dispatched dispatch → status: sent."""
    for dir_path in [ROOT / "dispatch_inbox", ROOT / "tasks/dispatches"]:
        if not dir_path.exists():
            continue
        for f in dir_path.glob("*.yaml"):
            data = safe_yaml_load(f)
            if not data or data.get("id") != disp_id:
                continue
            text = f.read_text(encoding="utf-8")
            if "status: dispatched" in text:
                text = text.replace("status: dispatched", "status: sent\ntso: approved", 1)
                # DEF-20260413-33: atomic write — 직접 write_text → tmp+replace
                tmp = f.with_suffix(".tmp")
                tmp.write_text(text, encoding="utf-8")
                tmp.replace(f)
                return {"ok": True, "id": disp_id, "new_status": "sent"}
            return {"ok": False, "error": f"Status is not 'dispatched': {data.get('status')}"}
    return {"ok": False, "error": f"Dispatch '{disp_id}' not found"}


@app.post("/api/dispatch/{disp_id}/reject")
def reject_dispatch(disp_id: str, body: RejectBody):
    """Reject a dispatched dispatch → status: rejected."""
    for dir_path in [ROOT / "dispatch_inbox", ROOT / "tasks/dispatches"]:
        if not dir_path.exists():
            continue
        for f in dir_path.glob("*.yaml"):
            data = safe_yaml_load(f)
            if not data or data.get("id") != disp_id:
                continue
            text = f.read_text(encoding="utf-8")
            if "status: dispatched" in text:
                # DEF-20260414-15: yaml.dump으로 reason 안전 직렬화 — 큰따옴표 포함 시 YAML 깨짐 방지
                reason_line = ("\nrejected_reason: " + yaml.dump(body.reason).strip()) if body.reason else ""
                text = text.replace(
                    "status: dispatched",
                    f"status: rejected{reason_line}", 1,
                )
                # DEF-20260413-33: atomic write — 직접 write_text → tmp+replace
                tmp = f.with_suffix(".tmp")
                tmp.write_text(text, encoding="utf-8")
                tmp.replace(f)
                return {"ok": True, "id": disp_id, "new_status": "rejected"}
            return {"ok": False, "error": f"Status is not 'dispatched': {data.get('status')}"}
    return {"ok": False, "error": f"Dispatch '{disp_id}' not found"}


@app.get("/api/permissions")
def get_permissions():
    """List pending permission requests."""
    pq_dir = ROOT / "permission_queue"
    if not pq_dir.exists():
        return []
    items = []
    for f in sorted(pq_dir.glob("req_*.json"), key=lambda x: x.stat().st_mtime, reverse=True):
        if "resolved" in f.name:
            continue
        data = safe_json_load(f)
        if not data:
            continue
        items.append({
            "req_id": data.get("req_id", f.stem),
            "worker": data.get("worker_id", ""),
            "tool": data.get("tool_name", ""),
            "reason": data.get("reason", ""),
            "command": data.get("tool_input", {}).get("command", "")[:200] if isinstance(data.get("tool_input"), dict) else "",
            "timestamp": data.get("timestamp", ""),
            "status": data.get("status", "pending"),
        })
    return items


@app.post("/api/permission/{req_id}/resolve")
def resolve_permission(req_id: str, body: PermissionResolve):
    """Resolve a pending permission request."""
    pq_dir = ROOT / "permission_queue"
    req_file = pq_dir / f"{req_id}.json"
    if not req_file.exists():
        return {"ok": False, "error": f"Request '{req_id}' not found"}
    data = safe_json_load(req_file)
    if not data:
        return {"ok": False, "error": "Failed to read request"}
    decision = body.decision.upper()
    data["status"] = f"resolved_{decision}"
    data["resolved_at"] = datetime.now(timezone.utc).isoformat()
    data["resolved_reason"] = body.reason
    # Rename file to indicate resolved (atomic: write tmp → replace → unlink original)
    resolved_file = pq_dir / f"{req_id}_resolved_{decision}.json"
    tmp_resolved = resolved_file.with_suffix(".tmp")
    tmp_resolved.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp_resolved.replace(resolved_file)
    req_file.unlink(missing_ok=True)
    return {"ok": True, "req_id": req_id, "decision": decision}


# ─── API: Token Usage ───

@app.get("/api/tokens")
def get_tokens():
    """daily_token_log.jsonl에서 오늘 Worker별 최신 토큰 집계 반환."""
    log_path = ROOT / "context_logs" / "daily_token_log.jsonl"
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    # worker별 최신 레코드만 유지 (same date)
    latest: dict[str, dict] = {}
    if log_path.exists():
        try:
            for line in log_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("date") != today:
                    continue
                worker = rec.get("worker", "unknown")
                # 같은 날짜면 나중 레코드가 더 최신 (ts 기준)
                if worker not in latest or rec.get("ts", "") > latest[worker].get("ts", ""):
                    latest[worker] = rec
        except Exception:
            pass

    daily_limit = int(os.environ.get("TSO_TOKEN_DAILY_LIMIT", "2000000"))
    result = []
    for worker, rec in sorted(latest.items()):
        total_raw = rec.get("daily_total_raw", 0)
        pct = round(total_raw / daily_limit * 100, 1) if daily_limit > 0 else 0
        result.append({
            "worker": worker,
            "date": today,
            "input_tokens": rec.get("input_tokens", 0),
            "output_tokens": rec.get("output_tokens", 0),
            "cache_read_tokens": rec.get("cache_read_tokens", 0),
            "cache_create_tokens": rec.get("cache_create_tokens", 0),
            "daily_total_raw": total_raw,
            "daily_limit": daily_limit,
            "pct": pct,
            "alert": pct >= 80,
        })
    return {"date": today, "daily_limit": daily_limit, "workers": result}


# ─── HTML ───

@app.get("/")
def index():
    html_path = STATIC_DIR / "dashboard.html"
    if html_path.exists():
        return HTMLResponse(html_path.read_text(encoding="utf-8"))
    return HTMLResponse("<h1>dashboard.html not found</h1>", status_code=404)


if __name__ == "__main__":
    import uvicorn
    print(f"TSO Dashboard: http://localhost:8080")
    print(f"⚠️  LAN/Tailscale 전용 — 공용 네트워크 노출 금지")
    # DISP-ENG-DASHBOARD-BIND-001: 0.0.0.0으로 변경 (IPv4 all-interfaces, LAN/Tailscale 접근용)
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="warning")

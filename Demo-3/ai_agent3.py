#!/usr/bin/env python3
"""
AI AGENT — Demo-3 Realistic Stack (FIXED)
DEFCON Coimbatore 2026 · Venugopal Parameswara

Reads REAL events from guardian3.sh JSONL log.
Serves live state to dashboard3.html on port 7880.
Polls real Docker stats for live CPU/MEM metrics.
"""

import json, time, threading, subprocess, http.server, os, re
from collections import deque
from datetime import datetime, timezone, timedelta

PORT      = 7880
LOG_FILE  = "/tmp/demo3_guardian.jsonl"
DEMO3_DIR = "/Users/kuttanadan/Documents/defcon-demo/Demo-3"
IST       = timezone(timedelta(hours=5, minutes=30))

def ts():
    return datetime.now(IST).strftime("%Y-%m-%d %H:%M:%S IST")

def ts_ms():
    return int(time.time() * 1000)

# ── Tier state ─────────────────────────────────────────────────
class TierState:
    def __init__(self, name, port, target_ms, color):
        self.name       = name
        self.port       = port
        self.target_ms  = target_ms
        self.color      = color
        self.status     = "HEALTHY"
        self.health_pct = 100
        self.mttr_ms    = None              # most-recent attack
        self.mttr_hist  = deque(maxlen=20)  # rolling window of MTTRs (one per attack)
        self.count      = 0
        self.ai_action  = None
        self.metrics    = {}
        self.metrics_h  = deque(maxlen=60)

    def avg_mttr_ms(self):
        return int(round(sum(self.mttr_hist) / len(self.mttr_hist))) if self.mttr_hist else None

WEB = TierState("WEB", 9091,  700,   "green")
APP = TierState("APP", 3001,  5000,  "blue")
DB  = TierState("DB",  5432,  25000, "purple")
tiers = [WEB, APP, DB]

agent_state = {
    "incidents":  0,
    "saved_ms":   0,
    "confidence": 97,
    "ai_log":     deque(maxlen=50),
}

waf_state = {
    "active":   False,
    "total":    0,
    "blocked":  0,
    "passed":   0,
    "status":   "OPERATIONAL",
    "attacker": "---.---.---.---",
}
waf_events = deque(maxlen=100)

# ── Helpers ────────────────────────────────────────────────────
def run(cmd, timeout=4):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""

def docker_running(name):
    out = run(["docker", "ps", "-q", "--filter", f"name=^/{name}$",
               "--filter", "status=running"])
    return bool(out)

def docker_stats(name):
    out = run(["docker", "stats", "--no-stream", "--format",
               "{{.CPUPerc}},{{.MemPerc}}", name])
    try:
        parts = out.split(",")
        return round(float(parts[0].replace("%","")), 1), \
               round(float(parts[1].replace("%","")), 1)
    except Exception:
        return 0.0, 0.0

def http_check(port, path="/health"):
    out = run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
               "--connect-timeout", "1", "--max-time", "2",
               f"http://localhost:{port}{path}"])
    return out.strip()

def pg_query(container, sql):
    return run(["docker", "exec", container,
                "psql", "-U", "phoenix", "-d", "phoenix",
                "-t", "-c", sql], timeout=5)

# ── Metrics polling ────────────────────────────────────────────
def poll_metrics():
    while True:
        t = ts_ms()
        try:
            # WEB
            web_up = docker_running("demo3-web")
            cpu, mem = docker_stats("demo3-web") if web_up else (0.0, 0.0)
            code = http_check(WEB.port) if web_up else "000"
            if web_up and code == "200":
                if WEB.status not in ("DEGRADED","FAILED","RECOVERING"):
                    WEB.status = "HEALTHY"
                WEB.health_pct = 100
            elif web_up:
                WEB.health_pct = 50
            else:
                WEB.health_pct = 0
            WEB.metrics = {"cpu": cpu, "mem": mem,
                           "error_rate": 0.0 if code=="200" else 100.0,
                           "latency_ms": 0}
            WEB.metrics_h.appendleft({"ts_ms": t, **WEB.metrics})

            # APP
            app_up = docker_running("demo3-app")
            cpu, mem = docker_stats("demo3-app") if app_up else (0.0, 0.0)
            code = http_check(APP.port) if app_up else "000"
            if app_up and code == "200":
                if APP.status not in ("DEGRADED","FAILED","RECOVERING"):
                    APP.status = "HEALTHY"
                APP.health_pct = 100
            else:
                APP.health_pct = 0
            # Get transaction count
            txn = 0
            try:
                import urllib.request
                resp = urllib.request.urlopen(
                    f"http://localhost:{APP.port}/status", timeout=2)
                d = json.loads(resp.read())
                txn = d.get("transactions", 0)
            except Exception:
                pass
            APP.metrics = {"cpu": cpu, "mem": mem,
                           "transactions": txn,
                           "error_rate": 0.0 if code=="200" else 100.0}
            APP.metrics_h.appendleft({"ts_ms": t, **APP.metrics})

            # DB
            db_up  = docker_running("demo3-db-pri")
            rep_up = docker_running("demo3-db-rep")
            cpu, mem = docker_stats("demo3-db-pri") if db_up else (0.0, 0.0)
            repl_lag = 0
            if db_up:
                raw = pg_query("demo3-db-pri",
                    "SELECT COALESCE(MAX(sent_lsn - replay_lsn),0) "
                    "FROM pg_stat_replication;")
                try:
                    repl_lag = int(raw.split('\n')[0].strip() or 0)
                except Exception:
                    repl_lag = 0
            if db_up:
                if DB.status not in ("DEGRADED","FAILED","RECOVERING"):
                    DB.status = "HEALTHY"
                DB.health_pct = 100
            else:
                DB.health_pct = 0
            DB.metrics = {"cpu": cpu, "mem": mem,
                          "repl_lag_ms": round(repl_lag/1000, 1),
                          "replica_up": rep_up}
            DB.metrics_h.appendleft({"ts_ms": t, **DB.metrics})

        except Exception as e:
            pass

        # Update confidence
        healthy = sum(1 for t_obj in tiers if t_obj.status == "HEALTHY")
        agent_state["confidence"] = [0, 72, 88, 97][healthy]

        time.sleep(2)

# ── Log reader ─────────────────────────────────────────────────
last_line_count = 0

def process_new_events():
    global last_line_count
    if not os.path.exists(LOG_FILE):
        return
    try:
        with open(LOG_FILE, "r") as f:
            lines = f.readlines()
    except Exception:
        return

    if len(lines) == last_line_count:
        return

    new_lines = lines[last_line_count:]
    last_line_count = len(lines)

    for line in new_lines:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue

        tier   = ev.get("tier", "")
        event  = ev.get("event", "")
        detail = ev.get("detail", "")
        mttr   = ev.get("mttr_ms")

        # Add to AI log
        agent_state["ai_log"].appendleft(ev)

        # ── WEB tier ──────────────────────────────────────────
        if tier == "WEB":
            if event == "DRIFT_DETECTED":
                WEB.status     = "FAILED"
                WEB.health_pct = 0
                WEB.ai_action  = "Drift detected — immutable respawn initiated"
            elif event == "RESPAWN_START":
                WEB.status     = "RECOVERING"
                WEB.health_pct = 30
                WEB.ai_action  = "Killing poisoned container → spawning golden image"
            elif event == "RESPAWN_SUCCESS":
                WEB.status     = "RESTORED"
                WEB.health_pct = 100
                WEB.ai_action  = None
                if mttr is not None:
                    WEB.mttr_ms = int(mttr)
                    WEB.mttr_hist.append(int(mttr))
                    WEB.count  += 1
                    agent_state["incidents"] += 1
                    agent_state["saved_ms"]  += int(mttr)

        # ── APP tier ──────────────────────────────────────────
        elif tier == "APP":
            if event == "HEALTH_FAIL":
                APP.status     = "FAILED"
                APP.health_pct = 0
                APP.ai_action  = "Health check failed — restarting app container"
            elif event == "RESTART_START":
                APP.status     = "RECOVERING"
                APP.health_pct = 20
                APP.ai_action  = "Container restarting — DB state preserved in PostgreSQL"
            elif event == "RESTART_SUCCESS":
                APP.status     = "RESTORED"
                APP.health_pct = 100
                APP.ai_action  = None
                if mttr is not None:
                    APP.mttr_ms = int(mttr)
                    APP.mttr_hist.append(int(mttr))
                    APP.count  += 1
                    agent_state["incidents"] += 1
                    agent_state["saved_ms"]  += int(mttr)

        # ── DB tier ───────────────────────────────────────────
        elif tier == "DB":
            if event == "MASS_WRITE_DETECTED":
                DB.status     = "FAILED"
                DB.health_pct = 20
                DB.ai_action  = "Ransomware write pattern detected — fencing replica"
            elif event == "REPLICATION_LAG":
                DB.status     = "DEGRADED"
                DB.health_pct = 60
                DB.ai_action  = "Replication lag spike — monitoring propagation"
            elif event == "REPLICA_FENCED":
                DB.status     = "RECOVERING"
                DB.health_pct = 50
                DB.ai_action  = "Replica fenced at clean LSN — PITR in progress"
            elif event == "FAILOVER_SUCCESS":
                DB.status     = "RESTORED"
                DB.health_pct = 100
                DB.ai_action  = None
                if mttr is not None:
                    DB.mttr_ms = int(mttr)
                    DB.mttr_hist.append(int(mttr))
                    DB.count  += 1
                    agent_state["incidents"] += 1
                    agent_state["saved_ms"]  += int(mttr)
            elif event == "REPLICA_RESUMED":
                # Fence-and-resume cycle completed — flip DB back to HEALTHY
                DB.status     = "RESTORED"
                DB.health_pct = 100
                DB.ai_action  = None
                if mttr is not None:
                    DB.mttr_ms = int(mttr)
                    DB.mttr_hist.append(int(mttr))
                    DB.count  += 1
                    agent_state["incidents"] += 1
                    agent_state["saved_ms"]  += int(mttr)

        # ── WAF tier ──────────────────────────────────────────
        elif tier == "WAF":
            if event == "ATTACK_START":
                waf_state.update({
                    "active": True, "status": "UNDER_ATTACK",
                    "total": 0, "blocked": 0, "passed": 0,
                })
                # Extract attacker IP from detail
                m = re.search(r'source[:\s]+(\d+\.\d+\.\d+\.\d+)', detail)
                if m:
                    waf_state["attacker"] = m.group(1)
                waf_events.clear()

            elif event in ("REQUEST_BLOCKED", "REQUEST_PASSED"):
                waf_state["total"] += 1
                if event == "REQUEST_BLOCKED":
                    waf_state["blocked"] += 1
                    waf_state["status"]   = "PROTECTED"
                else:
                    waf_state["passed"]  += 1
                    waf_state["status"]   = "UNDER_ATTACK"
                waf_events.appendleft(ev)

            elif event == "ATTACK_COMPLETE":
                waf_state["active"] = False
                waf_state["status"] = "PROTECTED"

            elif event == "AI_SUMMARY":
                waf_state["active"] = False
                waf_state["status"] = "OPERATIONAL"

        # ── GUARDIAN tier ─────────────────────────────────────
        elif tier == "GUARDIAN":
            if event == "CONTAINER_UP":
                for t_obj in tiers:
                    if t_obj.name.lower() in detail.lower():
                        t_obj.status     = "HEALTHY"
                        t_obj.health_pct = 100

def log_watcher():
    while True:
        process_new_events()
        time.sleep(0.4)

# ── State builder ──────────────────────────────────────────────
def build_state():
    def tier_dict(t):
        return {
            "name":              t.name,
            "status":            t.status,
            "health_pct":        t.health_pct,
            "mttr_ms":           t.mttr_ms,           # most-recent attack
            "avg_mttr_ms":       t.avg_mttr_ms(),     # average across all attacks on this tier
            "mttr_history":      list(t.mttr_hist),
            "respawn_count":     t.count,
            "bleed_per_min":     5000,
            "recovery_target_ms": t.target_ms,
            "ai_action":         t.ai_action,
            "metrics":           t.metrics,
            "metrics_history":   list(t.metrics_h)[:20],
            "events":            [],
        }

    saved_usd = (agent_state["saved_ms"] / 60000) * 5000

    # ── R-value rollups ────────────────────────────────────────
    # 1. avg per attack across the whole stack (sum of all MTTRs / total attacks)
    all_mttrs = [m for t in tiers for m in t.mttr_hist]
    avg_per_attack_ms = (
        int(round(sum(all_mttrs) / len(all_mttrs))) if all_mttrs else None
    )
    # 2. combined-stack MTTR — what a full cascade costs if every tier fell once
    #    using each tier's own avg as the representative recovery time
    combined_parts = [t.avg_mttr_ms() for t in tiers if t.avg_mttr_ms() is not None]
    combined_mttr_ms = sum(combined_parts) if combined_parts else None

    return {
        "tiers": [tier_dict(t) for t in tiers],
        "agent": {
            "total_incidents": agent_state["incidents"],
            "total_saved_ms":  agent_state["saved_ms"],
            "total_saved_usd": round(saved_usd, 2),
            "confidence":      agent_state["confidence"],
            "current_action":  None,
            "session_start":   0,
            "ai_log":          list(agent_state["ai_log"])[:20],
        },
        "rollup": {
            "avg_mttr_per_attack_ms": avg_per_attack_ms,  # R = avg per attack
            "combined_mttr_ms":       combined_mttr_ms,   # full-stack cascade
            "total_attacks":          len(all_mttrs),
        },
        "scenario": {"active": any(
            t.status in ("FAILED","RECOVERING","DEGRADED") for t in tiers
        )},
        "waf":        dict(waf_state),
        "waf_events": list(waf_events)[:20],
        "ts":         ts(),
    }

# ── HTTP server ────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        from urllib.parse import urlparse
        path = urlparse(self.path).path

        if path == "/state":
            body = json.dumps(build_state()).encode()
            self._respond(200, "application/json", body,
                          extra=[("Access-Control-Allow-Origin","*"),
                                 ("Cache-Control","no-cache")])

        elif path in ("/", "/dashboard"):
            dash = os.path.join(DEMO3_DIR, "dashboard3.html")
            if os.path.exists(dash):
                with open(dash, "rb") as f: body = f.read()
                self._respond(200, "text/html; charset=utf-8", body)
            else:
                self._respond(404, "text/plain", b"dashboard3.html not found")

        elif path == "/log":
            body = b""
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, "rb") as f: body = f.read()
            self._respond(200, "application/x-ndjson", body,
                          extra=[("Access-Control-Allow-Origin","*")])

        elif path.startswith("/trigger/"):
            target = path.split("/", 2)[2].strip().lower()
            allowed = {"web", "app", "db", "waf"}
            if target not in allowed:
                self._respond(400, "application/json",
                              json.dumps({"ok": False,
                                          "error": f"unknown target: {target}"}).encode(),
                              extra=[("Access-Control-Allow-Origin","*")])
                return
            script = os.path.join(DEMO3_DIR, f"attack3_{target}.sh")
            if not os.path.isfile(script):
                self._respond(500, "application/json",
                              json.dumps({"ok": False,
                                          "error": f"missing script: {script}"}).encode(),
                              extra=[("Access-Control-Allow-Origin","*")])
                return
            try:
                # fire-and-forget — attack scripts log their own events to JSONL
                subprocess.Popen(
                    ["bash", script],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    cwd=DEMO3_DIR,
                    start_new_session=True,
                )
                self._respond(202, "application/json",
                              json.dumps({"ok": True, "triggered": target}).encode(),
                              extra=[("Access-Control-Allow-Origin","*")])
            except Exception as e:
                self._respond(500, "application/json",
                              json.dumps({"ok": False, "error": str(e)}).encode(),
                              extra=[("Access-Control-Allow-Origin","*")])
        else:
            self._respond(404, "text/plain", b"not found")

    def _respond(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # silent

# ── Main ───────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n  AI Agent — Demo-3 Realistic Stack (v2)")
    print(f"  ─────────────────────────────────────────────")
    print(f"  Dashboard:  http://localhost:{PORT}")
    print(f"  State API:  http://localhost:{PORT}/state")
    print(f"  Log source: {LOG_FILE}")
    print(f"  ─────────────────────────────────────────────")
    print(f"\n  Reads REAL events from guardian3.sh")
    print(f"  Demo-2 on port 9090 — untouched\n")

    threading.Thread(target=poll_metrics, daemon=True).start()
    threading.Thread(target=log_watcher,  daemon=True).start()

    server = http.server.HTTPServer(("", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Agent stopped.")

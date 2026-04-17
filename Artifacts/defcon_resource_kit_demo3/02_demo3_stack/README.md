# Demo-3 Stack — Source Pointers
## Three-tier realistic deployment for the DEFCON Coimbatore 2026 talk

> The live source lives at `/Users/kuttanadan/Documents/defcon-demo/Demo-3/`. This folder is the audience-facing reference to what's in that stack — not a second copy.

---

## Stack Overview

Five real Docker containers on an isolated `demo3-net` bridge network. Ports are deliberately separated from Demo-2's 9090/7878 — no collision possible.

| Container | Image | Port | Base | Role |
|---|---|---|---|---|
| `demo3-waf` | `demo3-waf:golden` | 8090 | `owasp/modsecurity-crs:nginx-alpine` | Reverse proxy + ModSecurity + OWASP CRS |
| `demo3-web` | `demo3-web:golden` | 9091 | `nginx:alpine` | Immutable web tier — static HTML |
| `demo3-app` | `demo3-app:golden` | 3001 | `python:3.11-alpine` | Flask API, stateful, talks Postgres |
| `demo3-db-pri` | `demo3-db-primary:golden` | 5432 | `postgres:15-alpine` | PostgreSQL primary, WAL streaming |
| `demo3-db-rep` | `demo3-db-replica:golden` | 5433 | `postgres:15-alpine` | PostgreSQL streaming replica |

---

## Source Layout (lives under `Demo-3/`)

```
Demo-3/
|-- setup_and_run3.sh          Master control (setup/start/stop/attack/check/reset)
|-- docker-compose3.yml        All 5 containers + volumes + network
|-- ai_agent3.py               AI agent — reads JSONL, serves dashboard + /trigger
|-- dashboard3.html            Live B-V-R dashboard (polls /state every 800ms)
|
|-- guardian/
|   └-- guardian3.sh           Bash poll loop — writes /tmp/demo3_guardian.jsonl
|
|-- web/
|   |-- Dockerfile             nginx:alpine + curl + html + healthcheck
|   |-- nginx.conf             /health endpoint + static serving
|   └-- html/index.html        Phoenix UI — baked into image at build
|
|-- app/
|   |-- Dockerfile             python:3.11-alpine + flask + psycopg2
|   |-- app.py                 Flask API (/health /status /transaction /session)
|   └-- requirements.txt       flask==3.0.3, psycopg2-binary==2.9.9
|
|-- db/
|   |-- Dockerfile.primary     postgres:15-alpine + init scripts
|   |-- Dockerfile.replica     postgres:15-alpine + pg_basebackup
|   |-- init-primary.sh        Creates schema, seeds data, replicator user
|   |-- setup-replica.sh       pg_basebackup + streaming replication config
|   |-- postgresql.conf        wal_level=replica, max_wal_senders=3
|   └-- pg_hba.conf            Allows replication from 0.0.0.0/0
|
|-- waf/
|   |-- Dockerfile             owasp/modsecurity-crs:nginx-alpine
|   └-- nginx-waf.conf         Proxy to demo3-web, /health bypass, modsecurity on
|
|-- attack3_web.sh             Web tier wipeout (T1485)
|-- attack3_app.sh             App tier cascade (memory + kill)
|-- attack3_db.sh              DB ransomware simulation (T1486)
└-- attack3_waf.sh             Real curl SQLi/XSS/traversal campaign
```

---

## Lifecycle Commands

```bash
cd /Users/kuttanadan/Documents/defcon-demo/Demo-3

./setup_and_run3.sh setup      # Build all images (run once, ~10-15 min first time)
./setup_and_run3.sh start      # Start stack + guardian + AI agent + open dashboard
./setup_and_run3.sh check      # Pre-stage health check (all 5 containers healthy?)
./setup_and_run3.sh status     # Full system snapshot
./setup_and_run3.sh stop       # Stop everything cleanly
./setup_and_run3.sh reset      # Nuclear reset (Demo-2 untouched)

./setup_and_run3.sh attack web    # Wipe /usr/share/nginx/html/*
./setup_and_run3.sh attack app    # Create sessions + memory pressure + docker kill
./setup_and_run3.sh attack db     # Seed 500 rows + 5 waves of mass UPDATE
./setup_and_run3.sh attack waf    # 15 real curl requests through ModSecurity
```

The dashboard also exposes `GET /trigger/{web|app|db|waf}` — the four buttons on screen `subprocess.Popen` the matching script and return 202.

---

## Data Flow

```
Attacker -> :8090 demo3-waf (ModSecurity) -> :9091 demo3-web -> :3001 demo3-app -> :5432 demo3-db-pri -> :5433 demo3-db-rep
                                                                                                                   ^
                                                                                                                   | WAL streaming (replica)
guardian3.sh (host, 1s poll) --> /tmp/demo3_guardian.jsonl --> ai_agent3.py (:7880) --> dashboard3.html (:7880 /)
```

The JSONL log is the only state exchanged between guardian and the AI agent. Every detection, decision, and recovery event is one line of structured JSON with `ts`, `tier`, `event`, `detail`, `mttr_ms`. Grep it, pipe it, replay it — it's deliberately boring.

---

## How To Verify Each Claim

The audience should be able to verify everything from a clean terminal. These are the checks the talk walks through live:

```bash
# 1. All 5 containers healthy?
docker ps --filter "name=demo3-" --format "table {{.Names}}\t{{.Status}}"

# 2. WAF is really ModSecurity (not a mock)?
curl -v "http://localhost:8090/?x='%20OR%201=1--"    # expect HTTP 403
docker exec demo3-waf tail -5 /var/log/modsec/audit.log

# 3. Postgres replication is really streaming?
docker exec demo3-db-pri psql -U phoenix -d phoenix -c \
  "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
# expect: state=streaming, sent_lsn=replay_lsn, lag=0

# 4. Guardian is really producing JSONL?
tail -n 20 /tmp/demo3_guardian.jsonl

# 5. AI agent /state endpoint actually returns the dashboard data?
curl -s http://localhost:7880/state | python3 -m json.tool | head -40

# 6. Trigger endpoint works?
curl -s http://localhost:7880/trigger/web
# → 202 {"ok":true,"triggered":"web"}
```

No screenshots. No mock JSON. No "trust us." Every number on the dashboard comes from one of these six commands.

---

*DEFCON Coimbatore 2026 · Demo-3 Realistic Stack*

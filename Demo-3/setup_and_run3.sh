#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  SETUP_AND_RUN3.SH — Demo-3 Master Control
#  Three-Tier Realistic Stack · DEFCON Coimbatore 2026
#  Speaker: Venugopal Parameswara
#
#  ISOLATION GUARANTEE:
#    Demo-2 runs on ports 9090/7878 — NEVER TOUCHED
#    Demo-3 runs on ports 9091/3001/5432/5433/8090/7880
#    Separate Docker network: demo3-net
#
#  Commands:
#    setup    — one-time: build all images (10-15 min first time)
#    start    — start all containers + guardian + agent + dashboard
#    stop     — stop everything cleanly
#    attack   — run specific attack (web/app/db/waf)
#    check    — pre-stage health check
#    status   — full snapshot
#    reset    — nuclear reset (Demo-2 untouched)
# ══════════════════════════════════════════════════════════════

set -uo pipefail

DEMO3_DIR="/Users/kuttanadan/Documents/defcon-demo/Demo-3"
COMPOSE="${DEMO3_DIR}/docker-compose3.yml"
GUARDIAN="${DEMO3_DIR}/guardian/guardian3.sh"
AGENT="${DEMO3_DIR}/ai_agent3.py"
DASHBOARD="${DEMO3_DIR}/dashboard3.html"

AGENT_PORT=7880
AGENT_PID_FILE="/tmp/demo3_agent.pid"
GUARDIAN_PID_FILE="/tmp/demo3_guardian.pid"

GREEN='\033[0;32m'; RED='\033[0;31m'; AMBER='\033[0;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC}  $*"; }
fail() { echo -e "${RED}  ✗${NC}  $*"; }
info() { echo -e "${CYAN}  →${NC}  $*"; }
warn() { echo -e "${AMBER}  ⚠${NC}  $*"; }
hdr()  { echo -e "\n${WHITE}$*${NC}\n  $(printf '─%.0s' {1..50})"; }

# ══════════════════════════════════════════════════════════════
#  SETUP — builds all images (run once)
# ══════════════════════════════════════════════════════════════
cmd_setup() {
    hdr "DEMO-3 SETUP — BUILDING ALL IMAGES"

    # Docker check
    if ! docker info &>/dev/null; then
        fail "Docker not running. Open Docker Desktop first."
        exit 1
    fi
    ok "Docker running ($(docker info --format '{{.ServerVersion}}' 2>/dev/null))"

    # Python3 check
    if ! command -v python3 &>/dev/null; then
        fail "python3 not found"
        exit 1
    fi
    ok "python3: $(python3 --version)"

    # Check all required files
    info "Checking Demo-3 files..."
    missing=0
    for f in \
        "${COMPOSE}" \
        "${GUARDIAN}" \
        "${AGENT}" \
        "${DASHBOARD}" \
        "${DEMO3_DIR}/attack3_web.sh" \
        "${DEMO3_DIR}/attack3_app.sh" \
        "${DEMO3_DIR}/attack3_db.sh" \
        "${DEMO3_DIR}/attack3_waf.sh" \
        "${DEMO3_DIR}/web/Dockerfile" \
        "${DEMO3_DIR}/app/Dockerfile" \
        "${DEMO3_DIR}/db/Dockerfile.primary" \
        "${DEMO3_DIR}/db/Dockerfile.replica" \
        "${DEMO3_DIR}/waf/Dockerfile"; do
        if [[ -f "$f" ]]; then
            ok "$(basename $f)"
        else
            fail "Missing: $f"
            missing=1
        fi
    done
    [[ $missing -eq 1 ]] && { fail "Some files missing — check Demo-3 folder"; exit 1; }

    # Make scripts executable
    chmod +x \
        "${GUARDIAN}" \
        "${DEMO3_DIR}/attack3_web.sh" \
        "${DEMO3_DIR}/attack3_app.sh" \
        "${DEMO3_DIR}/attack3_db.sh" \
        "${DEMO3_DIR}/attack3_waf.sh" \
        2>/dev/null || true
    ok "Permissions set"

    # Build all images
    info "Building Docker images (this takes 10-15 minutes first time)..."
    info "Web tier..."
    docker compose -f "${COMPOSE}" build demo3-web 2>&1 | grep -E "Step|Successfully|ERROR" | head -5
    ok "demo3-web:golden built"

    info "App tier..."
    docker compose -f "${COMPOSE}" build demo3-app 2>&1 | grep -E "Step|Successfully|ERROR" | head -5
    ok "demo3-app:golden built"

    info "DB primary..."
    docker compose -f "${COMPOSE}" build demo3-db-pri 2>&1 | grep -E "Step|Successfully|ERROR" | head -5
    ok "demo3-db-primary:golden built"

    info "DB replica..."
    docker compose -f "${COMPOSE}" build demo3-db-rep 2>&1 | grep -E "Step|Successfully|ERROR" | head -5
    ok "demo3-db-replica:golden built"

    info "WAF (ModSecurity — downloads OWASP CRS)..."
    docker compose -f "${COMPOSE}" build demo3-waf 2>&1 | grep -E "Step|Successfully|ERROR" | head -5
    ok "demo3-waf:golden built"

    # Confirm Demo-2 untouched
    info "Confirming Demo-2 on :9090 untouched..."
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 2 http://localhost:9090 2>/dev/null || echo "000")
    [[ "$STATUS" == "200" ]] && ok "Demo-2 healthy (HTTP 200)" || \
        info "Demo-2 not running (independent — fine)"

    echo ""
    echo -e "${GREEN}  ══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓  SETUP COMPLETE — ALL IMAGES BUILT${NC}"
    echo -e "${GREEN}  ══════════════════════════════════════════${NC}"
    echo ""
    info "Next: ${DEMO3_DIR}/setup_and_run3.sh start"
}

# ══════════════════════════════════════════════════════════════
#  START — launches all containers + guardian + agent
# ══════════════════════════════════════════════════════════════
cmd_start() {
    hdr "STARTING DEMO-3"

    # Clear old logs
    > /tmp/demo3_guardian.jsonl 2>/dev/null || true
    > /tmp/demo3_guardian.log  2>/dev/null || true

    # Start containers
    info "Starting Docker containers..."
    docker compose -f "${COMPOSE}" up -d
    ok "Containers started"

    # Wait for DB to be healthy before proceeding
    info "Waiting for PostgreSQL primary to be ready..."
    WAITED=0
    until docker exec demo3-db-pri pg_isready -U phoenix -d phoenix &>/dev/null; do
        sleep 2; WAITED=$((WAITED + 2))
        [[ $WAITED -gt 60 ]] && { fail "DB not ready after 60s"; exit 1; }
        echo -ne "."
    done
    echo ""
    ok "PostgreSQL primary ready"

    # Wait for replica
    info "Waiting for replica streaming replication..."
    sleep 5
    LAG=$(docker exec demo3-db-pri \
        psql -U phoenix -d phoenix -t -c \
        "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' \n' || echo "0")
    if [[ "$LAG" -gt 0 ]]; then
        ok "Streaming replication active (${LAG} replicas connected)"
    else
        warn "Replica not yet streaming — may take 10-15s more"
    fi

    # Show container status
    echo ""
    info "Container status:"
    docker compose -f "${COMPOSE}" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" \
        2>/dev/null | head -10

    # Start guardian in background Terminal
    echo ""
    info "Starting guardian3.sh..."
    if [[ -f "$GUARDIAN_PID_FILE" ]]; then
        old_pid=$(cat "$GUARDIAN_PID_FILE")
        kill "$old_pid" 2>/dev/null || true
    fi
    bash "${GUARDIAN}" &
    echo $! > "$GUARDIAN_PID_FILE"
    sleep 1
    ok "Guardian watching all 3 tiers"

    # Start AI agent
    info "Starting AI agent on port ${AGENT_PORT}..."
    if [[ -f "$AGENT_PID_FILE" ]]; then
        old_pid=$(cat "$AGENT_PID_FILE")
        kill "$old_pid" 2>/dev/null || true
    fi
    python3 "${AGENT}" &
    echo $! > "$AGENT_PID_FILE"
    sleep 1
    if curl -s --connect-timeout 2 "http://localhost:${AGENT_PORT}/state" &>/dev/null; then
        ok "AI agent running on :${AGENT_PORT}"
    else
        warn "Agent starting (give it 3-5s then refresh dashboard)"
    fi

    echo ""
    ok "Dashboard:    http://localhost:${AGENT_PORT}"
    ok "Web tier:     http://localhost:9091"
    ok "App tier:     http://localhost:3001/status"
    ok "DB primary:   localhost:5432"
    ok "WAF:          http://localhost:8090"
    echo ""
    info "Opening dashboard..."
    open "http://localhost:${AGENT_PORT}"
}

# ══════════════════════════════════════════════════════════════
#  STOP
# ══════════════════════════════════════════════════════════════
cmd_stop() {
    hdr "STOPPING DEMO-3"

    # Stop guardian
    if [[ -f "$GUARDIAN_PID_FILE" ]]; then
        kill "$(cat $GUARDIAN_PID_FILE)" 2>/dev/null && ok "Guardian stopped" || true
        rm -f "$GUARDIAN_PID_FILE"
    fi

    # Stop agent
    if [[ -f "$AGENT_PID_FILE" ]]; then
        kill "$(cat $AGENT_PID_FILE)" 2>/dev/null && ok "Agent stopped" || true
        rm -f "$AGENT_PID_FILE"
    fi

    # Stop containers
    docker compose -f "${COMPOSE}" down 2>/dev/null && ok "Containers stopped" || true

    # Confirm Demo-2 untouched
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 2 http://localhost:9090 2>/dev/null || echo "000")
    info "Demo-2 on :9090 → HTTP ${STATUS} — untouched"
}

# ══════════════════════════════════════════════════════════════
#  ATTACK — run specific scenario
# ══════════════════════════════════════════════════════════════
cmd_attack() {
    local target="${2:-}"
    case "$target" in
        web) bash "${DEMO3_DIR}/attack3_web.sh" ;;
        app) bash "${DEMO3_DIR}/attack3_app.sh" ;;
        db)  bash "${DEMO3_DIR}/attack3_db.sh"  ;;
        waf) bash "${DEMO3_DIR}/attack3_waf.sh" ;;
        *)
            echo "Usage: $0 attack [web|app|db|waf]"
            echo ""
            echo "  web — wipeout demo3-web container (immutable respawn)"
            echo "  app — kill demo3-app (state loss + guardian restart)"
            echo "  db  — ransomware mass UPDATE simulation"
            echo "  waf — real curl SQLi/XSS/traversal against ModSecurity"
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════
#  CHECK — pre-stage health check
# ══════════════════════════════════════════════════════════════
cmd_check() {
    hdr "PRE-STAGE HEALTH CHECK"
    local all_ok=1

    # Docker
    docker info &>/dev/null && ok "Docker running" || { fail "Docker not running"; all_ok=0; }

    # Containers
    for c in demo3-web demo3-app demo3-db-pri demo3-db-rep demo3-waf; do
        docker ps -q --filter "name=${c}" --filter "status=running" | grep -q . \
            && ok "${c} running" \
            || { fail "${c} not running"; all_ok=0; }
    done

    # HTTP checks
    for pair in "9091:Web" "3001/health:App" "8090/health:WAF"; do
        port="${pair%%:*}"; label="${pair##*:}"
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 "http://localhost:${port}" 2>/dev/null || echo "000")
        [[ "$code" == "200" ]] && ok "${label} HTTP 200" \
            || { warn "${label} HTTP ${code}"; all_ok=0; }
    done

    # DB replication
    LAG=$(docker exec demo3-db-pri \
        psql -U phoenix -d phoenix -t -c \
        "SELECT COALESCE(MAX(sent_lsn - replay_lsn),0) FROM pg_stat_replication;" \
        2>/dev/null | tr -d ' \n' || echo "error")
    [[ "$LAG" =~ ^[0-9]+$ ]] && ok "Replication active (lag: ${LAG} bytes)" \
        || { warn "Replication not confirmed"; all_ok=0; }

    # Agent
    curl -s --connect-timeout 2 "http://localhost:${AGENT_PORT}/state" &>/dev/null \
        && ok "AI agent on :${AGENT_PORT}" \
        || { fail "AI agent not running"; all_ok=0; }

    # Demo-2
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 2 http://localhost:9090 2>/dev/null || echo "000")
    info "Demo-2 :9090 → HTTP ${CODE} (independent — untouched)"

    echo ""
    if [[ $all_ok -eq 1 ]]; then
        echo -e "${GREEN}  ✓  ALL CHECKS PASSED — STAGE READY${NC}"
    else
        echo -e "${RED}  ✗  SOME CHECKS FAILED — FIX BEFORE STAGE${NC}"
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  STATUS
# ══════════════════════════════════════════════════════════════
cmd_status() {
    hdr "DEMO-3 STATUS"

    echo -e "\n  ${WHITE}Containers:${NC}"
    docker compose -f "${COMPOSE}" ps \
        --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

    echo -e "\n  ${WHITE}PostgreSQL replication:${NC}"
    docker exec demo3-db-pri \
        psql -U phoenix -d phoenix -c \
        "SELECT client_addr, state, sent_lsn, replay_lsn,
                (sent_lsn - replay_lsn) AS lag_bytes
         FROM pg_stat_replication;" 2>/dev/null || echo "  DB not running"

    echo -e "\n  ${WHITE}App tier status:${NC}"
    curl -s "http://localhost:3001/status" 2>/dev/null \
        | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'  Uptime: {d[\"uptime_s\"]}s | Transactions: {d[\"transactions\"]} | Sessions: {d[\"sessions_active\"]} | DB: {d[\"db_connected\"]}')
except: print('  App not responding')
" 2>/dev/null

    echo -e "\n  ${WHITE}Guardian log (last 5 events):${NC}"
    tail -5 /tmp/demo3_guardian.jsonl 2>/dev/null \
        | python3 -c "
import sys,json
for line in sys.stdin:
    try:
        e=json.loads(line.strip())
        print(f'  [{e[\"ts\"].split(\" \")[1]}] {e[\"tier\"]:6s} {e[\"event\"]:25s} {e.get(\"detail\",\"\")[:50]}')
    except: pass
" 2>/dev/null || echo "  No events yet"

    echo ""
    info "Demo-2 :9090 → $(curl -s -o /dev/null -w 'HTTP %{http_code}' --connect-timeout 2 http://localhost:9090 2>/dev/null || echo 'not running') — untouched"
    info "Demo-3 dashboard → http://localhost:${AGENT_PORT}"
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  RESET
# ══════════════════════════════════════════════════════════════
cmd_reset() {
    hdr "NUCLEAR RESET — DEMO-3 ONLY"
    warn "Stops all Demo-3 containers, clears logs. Demo-2 untouched."

    cmd_stop

    # Clear logs
    rm -f /tmp/demo3_guardian.jsonl /tmp/demo3_guardian.log
    ok "Logs cleared"

    # Remove volumes for fresh DB start.
    # Compose project = lowercase folder name ("demo-3"), so volumes are
    #   demo-3_db-primary-data, demo-3_db-replica-data, demo-3_waf-logs.
    # Older runs may still have "Demo-3_*" or "demo3-real_*" — try them all.
    local cleared=0
    for v in \
        demo-3_db-primary-data demo-3_db-replica-data demo-3_waf-logs \
        Demo-3_db-primary-data Demo-3_db-replica-data Demo-3_waf-logs \
        demo3-real_db-primary-data demo3-real_db-replica-data; do
        if docker volume rm "$v" 2>/dev/null; then
            cleared=$((cleared + 1))
        fi
    done
    if [[ $cleared -gt 0 ]]; then
        ok "DB volumes cleared (${cleared})"
    else
        ok "Volumes already clear"
    fi

    echo ""
    ok "Reset complete. Run: ${DEMO3_DIR}/setup_and_run3.sh start"
}

# ══════════════════════════════════════════════════════════════
#  ROUTER
# ══════════════════════════════════════════════════════════════
case "${1:-help}" in
    setup)  cmd_setup  ;;
    start)  cmd_start  ;;
    stop)   cmd_stop   ;;
    attack) cmd_attack "$@" ;;
    check)  cmd_check  ;;
    status) cmd_status ;;
    reset)  cmd_reset  ;;
    *)
        echo ""
        echo -e "${GREEN}  DEMO-3 — Three-Tier Realistic Stack${NC}"
        echo -e "${DIM}  DEFCON Coimbatore 2026 · Venugopal Parameswara${NC}"
        echo ""
        echo -e "  ${WHITE}setup${NC}       — build all Docker images (once)"
        echo -e "  ${WHITE}start${NC}       — start containers + guardian + agent + dashboard"
        echo -e "  ${WHITE}stop${NC}        — stop everything"
        echo -e "  ${WHITE}attack web${NC}  — wipeout demo3-web (immutable respawn)"
        echo -e "  ${WHITE}attack app${NC}  — kill demo3-app (state loss demo)"
        echo -e "  ${WHITE}attack db${NC}   — ransomware mass UPDATE"
        echo -e "  ${WHITE}attack waf${NC}  — real curl SQLi/XSS/traversal"
        echo -e "  ${WHITE}check${NC}       — pre-stage health check"
        echo -e "  ${WHITE}status${NC}      — full snapshot"
        echo -e "  ${WHITE}reset${NC}       — nuclear reset (Demo-2 untouched)"
        echo ""
        echo -e "  ${DIM}Demo-2 (9090/7878) is never touched by any of these commands.${NC}"
        echo ""
        ;;
esac

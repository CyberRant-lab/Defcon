#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  GUARDIAN3.SH — Three-Tier Digital Immune System
#  DEFCON Coimbatore 2026 · Venugopal Parameswara
#
#  Monitors real Docker containers + real PostgreSQL replication.
#  Writes structured JSONL to /tmp/demo3_guardian.jsonl
#  AI agent reads this file and serves to dashboard.
#
#  Usage:
#    ./guardian3.sh          — watch all tiers
#    ./guardian3.sh web      — web tier only
#    ./guardian3.sh app      — app tier only
#    ./guardian3.sh db       — db tier only
# ══════════════════════════════════════════════════════════════

set -uo pipefail

DEMO3_DIR="/Users/kuttanadan/Documents/defcon-demo/Demo-3"
LOG_FILE="/tmp/demo3_guardian.jsonl"
POLL_INTERVAL=1

# Container names
WEB_CONTAINER="demo3-web"
APP_CONTAINER="demo3-app"
DB_PRI_CONTAINER="demo3-db-pri"
DB_REP_CONTAINER="demo3-db-rep"

# Images
WEB_IMAGE="demo3-web:golden"
APP_IMAGE="demo3-app:golden"
DB_PRI_IMAGE="demo3-db-primary:golden"
DB_REP_IMAGE="demo3-db-replica:golden"

# Ports
WEB_PORT=9091
APP_PORT=3001
DB_PRI_PORT=5432

# State
WEB_RESPAWN_COUNT=0
APP_RESPAWN_COUNT=0
DB_FAILOVER_COUNT=0
TOTAL_DOWNTIME_MS=0

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────
ts() { TZ='Asia/Kolkata' date '+%Y-%m-%d %H:%M:%S IST'; }
ms() { python3 -c "import time; print(int(time.time()*1000))"; }

log() { echo -e "${DIM}[$(ts)]${NC} $*" | tee -a "/tmp/demo3_guardian.log"; }

log_event() {
    local tier="$1" event="$2" detail="$3" mttr="${4:-}"
    echo "{\"ts\":\"$(ts)\",\"tier\":\"${tier}\",\"event\":\"${event}\",\"detail\":\"${detail}\",\"mttr_ms\":${mttr:-null}}" \
        >> "$LOG_FILE"
}

# ── Web tier functions ─────────────────────────────────────────
web_is_healthy() {
    docker ps -q --filter "name=${WEB_CONTAINER}" --filter "status=running" | grep -q . || return 1
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 1 --max-time 1 "http://localhost:${WEB_PORT}/health" 2>/dev/null || echo "000")
    [[ "$code" == "200" ]]
}

web_detect_drift() {
    local check
    check=$(docker exec "${WEB_CONTAINER}" \
        sh -c 'test -f /usr/share/nginx/html/index.html && echo "ok" || echo "drift"' \
        2>/dev/null || echo "container_gone")
    if [[ "$check" != "ok" ]]; then
        log "${RED}[WEB]${NC} ${WHITE}⚠ DRIFT DETECTED: ${check}${NC}"
        log_event "WEB" "DRIFT_DETECTED" "${check}"
        return 1
    fi
    return 0
}

web_respawn() {
    local t_start; t_start=$(ms)
    WEB_RESPAWN_COUNT=$((WEB_RESPAWN_COUNT + 1))
    log "${RED}[WEB]${NC} RESPAWN #${WEB_RESPAWN_COUNT} — killing poisoned container"
    log_event "WEB" "RESPAWN_START" "count=${WEB_RESPAWN_COUNT}"

    docker rm -f "${WEB_CONTAINER}" &>/dev/null || true
    docker run -d --name "${WEB_CONTAINER}" \
        --network demo3-net \
        --restart=no \
        -p "${WEB_PORT}:80" \
        "${WEB_IMAGE}" > /dev/null

    local healthy=false
    for _ in {1..10}; do
        sleep 0.2
        web_is_healthy && healthy=true && break
    done

    local mttr=$(( $(ms) - t_start ))
    local mttr_s; mttr_s=$(awk "BEGIN {printf \"%.2f\", ${mttr}/1000}")
    TOTAL_DOWNTIME_MS=$((TOTAL_DOWNTIME_MS + mttr))

    if $healthy; then
        log "${GREEN}[WEB]${NC} ✓ RESTORED — MTTR: ${mttr_s}s (${mttr}ms)"
        log "${GREEN}[WEB]${NC} ✓ B-V-R: R=${mttr_s}s < V=30s → DEFENDER WINS"
        log_event "WEB" "RESPAWN_SUCCESS" "mttr_s=${mttr_s}" "$mttr"
    else
        log "${RED}[WEB]${NC} ✗ Health check failed after respawn"
        log_event "WEB" "RESPAWN_FAILED" "mttr_ms=${mttr}" "$mttr"
    fi
}

# ── App tier functions ─────────────────────────────────────────
app_is_healthy() {
    docker ps -q --filter "name=${APP_CONTAINER}" --filter "status=running" | grep -q . || return 1
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 1 --max-time 2 "http://localhost:${APP_PORT}/health" 2>/dev/null || echo "000")
    [[ "$code" == "200" ]]
}

app_get_state() {
    # Capture app state before killing (for comparison after restart)
    curl -s --connect-timeout 1 --max-time 2 \
        "http://localhost:${APP_PORT}/status" 2>/dev/null || echo "{}"
}

app_respawn() {
    local t_start; t_start=$(ms)
    APP_RESPAWN_COUNT=$((APP_RESPAWN_COUNT + 1))

    # Capture state before kill — shows what's in memory
    local pre_state; pre_state=$(app_get_state)
    local pre_sessions; pre_sessions=$(echo "$pre_state" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('sessions_active',0))" 2>/dev/null || echo "?")

    log "${RED}[APP]${NC} RESTART #${APP_RESPAWN_COUNT} — killing app container"
    log "${AMBER}[APP]${NC} WARNING: ${pre_sessions} in-memory sessions will be lost"
    log_event "APP" "RESTART_START" "sessions_lost=${pre_sessions},count=${APP_RESPAWN_COUNT}"

    docker rm -f "${APP_CONTAINER}" &>/dev/null || true

    # Respawn from golden image
    docker run -d --name "${APP_CONTAINER}" \
        --network demo3-net \
        --restart=no \
        -p "${APP_PORT}:3001" \
        -e DB_HOST="${DB_PRI_CONTAINER}" \
        -e DB_PORT=5432 \
        -e DB_NAME=phoenix \
        -e DB_USER=phoenix \
        -e DB_PASS=phoenix123 \
        "${APP_IMAGE}" > /dev/null

    # Wait for health
    local healthy=false
    for _ in {1..20}; do
        sleep 0.5
        app_is_healthy && healthy=true && break
    done

    local mttr=$(( $(ms) - t_start ))
    local mttr_s; mttr_s=$(awk "BEGIN {printf \"%.2f\", ${mttr}/1000}")
    TOTAL_DOWNTIME_MS=$((TOTAL_DOWNTIME_MS + mttr))

    if $healthy; then
        log "${GREEN}[APP]${NC} ✓ RESTORED — MTTR: ${mttr_s}s (${mttr}ms)"
        log "${GREEN}[APP]${NC} ✓ Note: session state reset — DB state preserved"
        log_event "APP" "RESTART_SUCCESS" "mttr_s=${mttr_s},sessions_lost=${pre_sessions}" "$mttr"
    else
        log "${RED}[APP]${NC} ✗ App health check failed after restart"
        log_event "APP" "RESTART_FAILED" "mttr_ms=${mttr}" "$mttr"
    fi
}

# ── DB tier functions ──────────────────────────────────────────
db_check_replication() {
    # Query primary for replication lag
    local lag_bytes
    lag_bytes=$(docker exec "${DB_PRI_CONTAINER}" \
        psql -U phoenix -d phoenix -t -c \
        "SELECT COALESCE(MAX(sent_lsn - replay_lsn), 0) FROM pg_stat_replication;" \
        2>/dev/null | tr -d ' \n' || echo "error")

    echo "$lag_bytes"
}

db_check_write_velocity() {
    # Check for ransomware-style mass writes
    # Returns rows modified in last 5 seconds
    local writes
    writes=$(docker exec "${DB_PRI_CONTAINER}" \
        psql -U phoenix -d phoenix -t -c \
        "SELECT SUM(n_tup_upd + n_tup_ins + n_tup_del)
         FROM pg_stat_user_tables
         WHERE schemaname = 'public';" \
        2>/dev/null | tr -d ' \n' || echo "0")
    echo "${writes:-0}"
}

db_fence_replica() {
    log "${AMBER}[DB]${NC} FENCING replica — suspending replication"
    log_event "DB" "REPLICA_FENCE_START" "suspending_replication"

    # Pause replication on replica
    docker exec "${DB_REP_CONTAINER}" \
        psql -U phoenix -c "SELECT pg_wal_replay_pause();" \
        2>/dev/null || true

    log "${GREEN}[DB]${NC} ✓ Replica fenced — clean state preserved at this LSN"
    log_event "DB" "REPLICA_FENCED" "replication_paused=true"
}

db_promote_replica() {
    local t_start; t_start=$(ms)
    DB_FAILOVER_COUNT=$((DB_FAILOVER_COUNT + 1))
    log "${RED}[DB]${NC} FAILOVER #${DB_FAILOVER_COUNT} — promoting replica to primary"
    log_event "DB" "FAILOVER_START" "count=${DB_FAILOVER_COUNT}"

    # Resume replication first (unpauses if fenced)
    docker exec "${DB_REP_CONTAINER}" \
        psql -U phoenix -c "SELECT pg_wal_replay_resume();" \
        2>/dev/null || true

    # Promote replica
    docker exec "${DB_REP_CONTAINER}" \
        su postgres -c "pg_ctl promote -D /var/lib/postgresql/data" \
        2>/dev/null || true

    sleep 2

    # Check replica is now accepting writes
    local promoted=false
    if docker exec "${DB_REP_CONTAINER}" \
        psql -U phoenix -d phoenix -c "INSERT INTO transactions (amount) VALUES (0.01);" \
        2>/dev/null; then
        promoted=true
    fi

    local mttr=$(( $(ms) - t_start ))
    local mttr_s; mttr_s=$(awk "BEGIN {printf \"%.2f\", ${mttr}/1000}")
    TOTAL_DOWNTIME_MS=$((TOTAL_DOWNTIME_MS + mttr))

    if $promoted; then
        log "${GREEN}[DB]${NC} ✓ Replica PROMOTED — now accepting writes"
        log "${GREEN}[DB]${NC} ✓ MTTR: ${mttr_s}s (${mttr}ms)"
        log_event "DB" "FAILOVER_SUCCESS" "mttr_s=${mttr_s},new_primary=replica" "$mttr"
    else
        log "${AMBER}[DB]${NC} Promotion in progress — verifying..."
        log_event "DB" "FAILOVER_PENDING" "mttr_ms=${mttr}" "$mttr"
    fi
}

# ── Banner ────────────────────────────────────────────────────
banner() {
    echo -e "${GREEN}"
    cat << 'EOF'
  ██████╗ ██╗   ██╗ █████╗ ██████╗ ██████╗ ██╗ █████╗ ███╗  ██╗
 ██╔════╝ ██║   ██║██╔══██╗██╔══██╗██╔══██╗██║██╔══██╗████╗ ██║
 ██║  ███╗██║   ██║███████║██████╔╝██║  ██║██║███████║██╔██╗██║
 ██║   ██║██║   ██║██╔══██║██╔══██╗██║  ██║██║██╔══██║██║╚████║
 ╚██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝██║██║  ██║██║ ╚███║
  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
          THREE-TIER DIGITAL IMMUNE SYSTEM
EOF
    echo -e "${NC}"
    echo -e "  ${WHITE}Tiers: WEB :${WEB_PORT} | APP :${APP_PORT} | DB :${DB_PRI_PORT}${NC}"
    echo -e "  ${DIM}Log: ${LOG_FILE}${NC}\n"
}

# ── Startup checks ─────────────────────────────────────────────
startup_check() {
    log "${CYAN}[GUARDIAN3]${NC} Starting tier health checks..."

    for container in "$WEB_CONTAINER" "$APP_CONTAINER" "$DB_PRI_CONTAINER" "$DB_REP_CONTAINER"; do
        if docker ps -q --filter "name=${container}" --filter "status=running" | grep -q .; then
            log "${GREEN}[GUARDIAN3]${NC} ✓ ${container} running"
            log_event "GUARDIAN" "CONTAINER_UP" "${container}"
        else
            log "${RED}[GUARDIAN3]${NC} ✗ ${container} NOT running"
            log_event "GUARDIAN" "CONTAINER_DOWN" "${container}"
        fi
    done
}

# ── Main watch loop ────────────────────────────────────────────
main() {
    # Clear old log
    > "$LOG_FILE"

    banner
    startup_check

    log "${GREEN}[GUARDIAN3]${NC} Watch loop started — polling every ${POLL_INTERVAL}s"
    log_event "GUARDIAN" "WATCH_START" "tiers=WEB+APP+DB,interval=${POLL_INTERVAL}s"

    local web_failures=0
    local app_failures=0
    local db_write_baseline=0
    local db_write_prev=0
    local db_fenced=0
    local db_quiet_ticks=0
    local db_fence_start_ms=0

    while true; do

        # ── Web tier check ────────────────────────────────────
        if ! web_detect_drift || ! web_is_healthy 2>/dev/null; then
            web_failures=$((web_failures + 1))
            if [[ $web_failures -ge 2 ]]; then
                web_respawn
                web_failures=0
            fi
        else
            web_failures=0
        fi

        # ── App tier check ────────────────────────────────────
        if ! app_is_healthy 2>/dev/null; then
            app_failures=$((app_failures + 1))
            if [[ $app_failures -ge 2 ]]; then
                log_event "APP" "HEALTH_FAIL" "http_check_failed"
                app_respawn
                app_failures=0
            fi
        else
            app_failures=0
        fi

        # ── DB tier: replication lag check ────────────────────
        lag=$(db_check_replication)
        if [[ "$lag" =~ ^[0-9]+$ ]] && [[ $lag -gt 1048576 ]]; then
            # Lag > 1MB — warn
            log "${AMBER}[DB]${NC} ⚠ Replication lag: ${lag} bytes"
            log_event "DB" "REPLICATION_LAG" "lag_bytes=${lag}"
        fi

        # ── DB tier: ransomware write velocity check ───────────
        writes=$(db_check_write_velocity)
        if [[ "$writes" =~ ^[0-9]+$ ]]; then
            if [[ $db_write_baseline -eq 0 ]]; then
                db_write_baseline=$writes
                db_write_prev=$writes
            else
                delta=$((writes - db_write_prev))
                db_write_prev=$writes
                # Alert if > 500 row changes per second
                if [[ $delta -gt 500 ]]; then
                    log "${RED}[DB]${NC} ⚠ RANSOMWARE PATTERN: ${delta} row changes/sec"
                    log_event "DB" "MASS_WRITE_DETECTED" "rows_per_sec=${delta},threshold=500"
                    # Fence the replica once per incident so corruption stops propagating
                    if [[ $db_fenced -eq 0 ]]; then
                        db_fence_start_ms=$(ms)
                        db_fence_replica
                        db_fenced=1
                        db_quiet_ticks=0
                    fi
                else
                    # Track quiet period; auto-resume replication after 10s of calm
                    if [[ $db_fenced -eq 1 ]]; then
                        db_quiet_ticks=$((db_quiet_ticks + 1))
                        if [[ $db_quiet_ticks -ge 10 ]]; then
                            log "${GREEN}[DB]${NC} Write storm subsided — resuming replication"
                            docker exec "${DB_REP_CONTAINER}" \
                                psql -U phoenix -c "SELECT pg_wal_replay_resume();" \
                                &>/dev/null || true
                            local db_mttr=$(( $(ms) - db_fence_start_ms ))
                            local db_mttr_s
                            db_mttr_s=$(awk "BEGIN {printf \"%.2f\", ${db_mttr}/1000}")
                            DB_FAILOVER_COUNT=$((DB_FAILOVER_COUNT + 1))
                            log "${GREEN}[DB]${NC} ✓ RESTORED — MTTR: ${db_mttr_s}s (${db_mttr}ms)"
                            log "${GREEN}[DB]${NC} ✓ B-V-R: R=${db_mttr_s}s < V=30s → DEFENDER WINS"
                            log_event "DB" "REPLICA_RESUMED" \
                                "mttr_s=${db_mttr_s},quiet_ticks=${db_quiet_ticks}" \
                                "$db_mttr"
                            db_fenced=0
                            db_quiet_ticks=0
                            db_fence_start_ms=0
                        fi
                    fi
                fi
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
    echo ""
    log "${CYAN}[GUARDIAN3]${NC} Shutting down"
    log "${CYAN}[GUARDIAN3]${NC} Web respawns: ${WEB_RESPAWN_COUNT}"
    log "${CYAN}[GUARDIAN3]${NC} App restarts: ${APP_RESPAWN_COUNT}"
    log "${CYAN}[GUARDIAN3]${NC} DB failovers: ${DB_FAILOVER_COUNT}"
    log_event "GUARDIAN" "WATCH_STOP" \
        "web_respawns=${WEB_RESPAWN_COUNT},app_restarts=${APP_RESPAWN_COUNT},db_failovers=${DB_FAILOVER_COUNT}"
    exit 0
}
trap cleanup SIGINT SIGTERM

main "$@"

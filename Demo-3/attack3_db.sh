#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  ATTACK3_DB.SH — Real ransomware simulation on PostgreSQL
#  Runs mass UPDATEs to simulate encrypted-for-impact (T1486)
#  Guardian detects write velocity spike and fences replica
# ══════════════════════════════════════════════════════════════

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'
WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

DB_CONTAINER="demo3-db-pri"
DB_REP_CONTAINER="demo3-db-rep"
DB_USER="phoenix"
DB_NAME="phoenix"

ts() { TZ='Asia/Kolkata' date '+%H:%M:%S IST'; }

psql_pri() { docker exec "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "$1" 2>/dev/null; }
psql_rep() { docker exec "${DB_REP_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "$1" 2>/dev/null; }

echo -e "${RED}"
cat << 'EOF'
 ██████╗  █████╗ ███╗  ██╗███████╗ ██████╗ ███╗  ███╗
 ██╔══██╗██╔══██╗████╗ ██║██╔════╝██╔═══██╗████╗████║
 ██████╔╝███████║██╔██╗██║███████╗██║   ██║██╔████╔██║
 ██╔══██╗██╔══██║██║╚████║╚════██║██║   ██║██║╚██╔╝██║
 ██║  ██║██║  ██║██║ ╚███║███████║╚██████╔╝██║ ╚═╝ ██║
 ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚══╝╚══════╝ ╚═════╝ ╚═╝     ╚═╝
         DB RANSOMWARE SIMULATION — T1486
EOF
echo -e "${NC}"

# Check target
if ! docker ps -q --filter "name=${DB_CONTAINER}" --filter "status=running" | grep -q .; then
    echo -e "${RED}[ATTACK]${NC} demo3-db-pri not running"
    exit 1
fi

# Phase 1 — baseline
echo -e "${RED}[ATTACK $(ts)]${NC} Phase 1: Establishing baseline"
BASELINE=$(psql_pri "SELECT COUNT(*) FROM transactions;" | tr -d ' \n')
REP_LAG=$(psql_pri "SELECT COALESCE(MAX(sent_lsn - replay_lsn),0) FROM pg_stat_replication;" | tr -d ' \n')
echo -e "${DIM}  → Transactions in DB: ${BASELINE}${NC}"
echo -e "${DIM}  → Replication lag (baseline): ${REP_LAG:-0} bytes${NC}"

# Phase 2 — insert bulk data to attack
echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Phase 2: Seeding attack surface"
psql_pri "
INSERT INTO transactions (amount)
SELECT random() * 1000
FROM generate_series(1, 500);
" > /dev/null
echo -e "${DIM}  → 500 rows inserted — attack surface ready${NC}"

# Phase 3 — ransomware simulation: mass UPDATE (encrypts data in place)
echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Phase 3: RANSOMWARE PAYLOAD — mass encrypting rows"
echo -e "${RED}  → Simulating: UPDATE all rows with encrypted garbage${NC}"
echo -e "${RED}  → Write velocity will spike — guardian should detect${NC}"
echo ""

WAVE=0
while [[ $WAVE -lt 5 ]]; do
    WAVE=$((WAVE + 1))
    ROWS=$(psql_pri "
    UPDATE transactions
    SET amount = amount * -1,
        created_at = NOW()
    WHERE id IN (
        SELECT id FROM transactions
        ORDER BY RANDOM()
        LIMIT 200
    );
    SELECT COUNT(*) FROM transactions;
    " | tr -d ' \n')

    LAG=$(psql_pri "SELECT COALESCE(MAX(sent_lsn - replay_lsn),0) FROM pg_stat_replication;" | tr -d ' \n')
    echo -e "${RED}[ATTACK $(ts)]${NC} Wave ${WAVE}: 200 rows encrypted — repl lag: ${LAG:-0} bytes"
    sleep 0.8
done

# Phase 4 — check replication propagation
echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Phase 4: Checking replication blast radius"
sleep 1
FINAL_LAG=$(psql_pri "SELECT COALESCE(MAX(sent_lsn - replay_lsn),0) FROM pg_stat_replication;" | tr -d ' \n')
REP_ROWS=$(psql_rep "SELECT COUNT(*) FROM transactions WHERE amount < 0;" 2>/dev/null | tr -d ' \n' || echo "?")

echo -e "${RED}  → Replication lag: ${FINAL_LAG:-0} bytes${NC}"
if [[ "${REP_ROWS}" =~ ^[0-9]+$ ]] && [[ "${REP_ROWS}" -gt 0 ]]; then
    echo -e "${RED}  → ${REP_ROWS} corrupted rows propagated to replica ⚠${NC}"
    echo -e "${RED}  → Replica is NOT a clean recovery point${NC}"
else
    echo -e "${GREEN}  → Replica fenced before corruption propagated ✓${NC}"
fi

echo ""
echo -e "${RED}  ╔══════════════════════════════════════════════════╗${NC}"
echo -e "${RED}  ║  RANSOMWARE COMPLETE — GUARDIAN3 SHOULD DETECT   ║${NC}"
echo -e "${RED}  ║  Check: write velocity > 500 rows/sec triggered   ║${NC}"
echo -e "${RED}  ╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}  Guardian detects via: pg_stat_user_tables write delta${NC}"
echo -e "${DIM}  Recovery: fence replica → PITR → promote clean replica${NC}"
echo -e "${DIM}  Dashboard: http://localhost:7880${NC}"

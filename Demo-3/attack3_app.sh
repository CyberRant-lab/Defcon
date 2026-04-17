#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  ATTACK3_APP.SH — App tier cascade simulation
#  Creates memory pressure + kills container to show:
#    1. State loss (in-memory sessions gone)
#    2. DB state preserved (transactions survive)
#    3. Guardian detects and restarts
# ══════════════════════════════════════════════════════════════

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'
WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

CONTAINER="demo3-app"
PORT=3001

ts() { TZ='Asia/Kolkata' date '+%H:%M:%S IST'; }

echo -e "${AMBER}"
cat << 'EOF'
  ██████╗ █████╗ ███████╗ ██████╗ █████╗ ██████╗ ███████╗
 ██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗██╔════╝
 ██║     ███████║███████╗██║     ███████║██║  ██║█████╗
 ██║     ██╔══██║╚════██║██║     ██╔══██║██║  ██║██╔══╝
 ╚██████╗██║  ██║███████║╚██████╗██║  ██║██████╔╝███████╗
  ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚═════╝ ╚══════╝
         APP TIER CASCADE — demo3-app
EOF
echo -e "${NC}"

if ! docker ps -q --filter "name=${CONTAINER}" --filter "status=running" | grep -q .; then
    echo -e "${AMBER}[ATTACK]${NC} demo3-app not running"
    exit 1
fi

# Phase 1 — capture current state
echo -e "${AMBER}[ATTACK $(ts)]${NC} Phase 1: Capturing app state before attack"
STATE=$(curl -s --connect-timeout 2 "http://localhost:${PORT}/status" 2>/dev/null)
SESSIONS=$(echo "$STATE" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('sessions_active',0))" 2>/dev/null || echo "?")
TXN=$(echo "$STATE" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('transactions',0))" 2>/dev/null || echo "?")
echo -e "${DIM}  → In-memory sessions: ${SESSIONS}${NC}"
echo -e "${DIM}  → DB transactions: ${TXN} (these survive — stored in PostgreSQL)${NC}"

# Phase 2 — create some sessions to show loss
echo ""
echo -e "${AMBER}[ATTACK $(ts)]${NC} Phase 2: Creating sessions (will be lost on kill)"
for i in 1 2 3; do
    curl -s -X POST "http://localhost:${PORT}/session" \
        -H "Content-Type: application/json" \
        -d "{\"user\":\"victim_${i}\",\"data\":\"sensitive_${i}\"}" > /dev/null 2>&1 || true
    echo -e "${DIM}  → Session victim_${i} created in memory${NC}"
    sleep 0.3
done

# Phase 3 — inject memory pressure
echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Phase 3: Injecting memory pressure"
docker exec "${CONTAINER}" sh -c \
    'python3 -c "x=[bytearray(1024*1024) for _ in range(50)]" &' 2>/dev/null || true
echo -e "${RED}  → 50MB memory spike injected${NC}"
sleep 1

# Phase 4 — kill the container
echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Phase 4: Killing app container"
docker kill "${CONTAINER}" 2>/dev/null || docker rm -f "${CONTAINER}" 2>/dev/null || true
echo -e "${RED}  → demo3-app KILLED — in-memory state LOST${NC}"

# Phase 5 — verify impact
sleep 0.5
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 1 --max-time 1 "http://localhost:${PORT}/health" 2>/dev/null || echo "000")
echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Phase 5: Impact verification"
echo -e "${RED}  → /health: HTTP ${HTTP} — APP TIER DOWN ⚠${NC}"
echo -e "${RED}  → ${SESSIONS} sessions LOST (were in memory only)${NC}"
echo -e "${GREEN}  → ${TXN} transactions SAFE (stored in PostgreSQL)${NC}"
echo -e "${DIM}  → This proves: stateless = respawnable, stateful = needs DB${NC}"

echo ""
echo -e "${AMBER}  ╔══════════════════════════════════════════════════╗${NC}"
echo -e "${AMBER}  ║  APP TIER DOWN — GUARDIAN3 DETECTING + RESTARTING ║${NC}"
echo -e "${AMBER}  ╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}  Watch guardian3.sh terminal for restart sequence${NC}"
echo -e "${DIM}  After restart: sessions=0, transactions=${TXN} (DB preserved)${NC}"

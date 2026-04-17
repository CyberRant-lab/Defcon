#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  ATTACK3_WEB.SH — Real wipeout attack on demo3-web container
#  Mirrors Demo-2 attack.sh exactly — same technique, new target
# ══════════════════════════════════════════════════════════════

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'
WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

CONTAINER="demo3-web"
PORT=9091

ts() { TZ='Asia/Kolkata' date '+%H:%M:%S IST'; }

echo -e "${RED}"
cat << 'EOF'
 █████╗ ████████╗████████╗ █████╗  ██████╗██╗  ██╗
██╔══██╗╚══██╔══╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝
███████║   ██║      ██║   ███████║██║     █████╔╝
██╔══██║   ██║      ██║   ██╔══██║██║     ██╔═██╗
██║  ██║   ██║      ██║   ██║  ██║╚██████╗██║  ██╗
╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝
         WEB TIER WIPEOUT — demo3-web
EOF
echo -e "${NC}"

# Check target
if ! docker ps -q --filter "name=${CONTAINER}" --filter "status=running" | grep -q .; then
    echo -e "${AMBER}[ATTACK]${NC} demo3-web not running. Start with: setup_and_run3.sh start"
    exit 1
fi

echo -e "${DIM}Target: ${CONTAINER} on localhost:${PORT}${NC}\n"

echo -e "${RED}[ATTACK $(ts)]${NC} Stage 1: Reconnaissance"
sleep 0.4
docker exec "${CONTAINER}" sh -c 'ls /usr/share/nginx/html/' 2>/dev/null \
    && echo -e "${DIM}  → Found web root${NC}"

echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Stage 2: Privilege check"
sleep 0.3
echo -e "${DIM}  → Running as: $(docker exec ${CONTAINER} whoami 2>/dev/null)${NC}"

echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Stage 3: Payload — wiping application files"
sleep 0.3
docker exec "${CONTAINER}" sh -c 'rm -rf /usr/share/nginx/html/*' 2>/dev/null || true
echo -e "${RED}  → All HTML files deleted${NC}"

echo ""
echo -e "${RED}[ATTACK $(ts)]${NC} Stage 4: Verifying impact"
sleep 0.5
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 2 --max-time 2 "http://localhost:${PORT}" 2>/dev/null || echo "000")

if [[ "$HTTP" == "403" || "$HTTP" == "404" || "$HTTP" == "000" ]]; then
    echo -e "${RED}  → HTTP ${HTTP} — WEB TIER IS DOWN ⚠${NC}"
    echo -e "${RED}  → Business bleeding: \$5,000/minute${NC}"
    echo -e "${RED}  → [DEMO] Wait 3 seconds — then watch guardian3.sh respond${NC}"
else
    echo -e "${AMBER}  → HTTP ${HTTP} — guardian may have already fired${NC}"
fi

echo ""
echo -e "${RED}  ╔══════════════════════════════════════╗${NC}"
echo -e "${RED}  ║  ATTACK COMPLETE — WATCH GUARDIAN3   ║${NC}"
echo -e "${RED}  ╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}  Browser: http://localhost:${PORT}${NC}"
echo -e "${DIM}  Dashboard: http://localhost:7880${NC}"

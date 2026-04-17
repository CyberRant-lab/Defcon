#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  stop_demo3.command — One-click clean teardown of Demo-3
#
#  Stops:
#    • host processes: guardian3.sh, ai_agent3.py
#    • the 5 demo3-* containers (via docker compose down)
#  Leaves untouched:
#    • Demo-2 on ports 9090/7878
#    • any other Docker container on the host (ciso-*, phoenix_app, etc.)
#    • DB volumes (so transaction history survives)
#
#  DEFCON Coimbatore 2026
# ══════════════════════════════════════════════════════════════

set -uo pipefail

DEMO3_DIR="/Users/kuttanadan/Documents/defcon-demo/Demo-3"
SETUP_SCRIPT="${DEMO3_DIR}/setup_and_run3.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; AMBER='\033[0;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
ok()    { echo -e "${GREEN}  ✓${NC}  $*"; }
fail()  { echo -e "${RED}  ✗${NC}  $*"; }
info()  { echo -e "${CYAN}  →${NC}  $*"; }
warn()  { echo -e "${AMBER}  ⚠${NC}  $*"; }
hdr()   { echo -e "\n${WHITE}$*${NC}\n  $(printf '─%.0s' {1..58})"; }

clear
echo -e "${AMBER}"
cat << 'BANNER'
  ╔════════════════════════════════════════════════════════════╗
  ║       STOPPING DEMO-3 · LEAVING OTHER WORKLOADS UP        ║
  ╚════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

if ! docker info &>/dev/null; then
    warn "Docker isn't running — nothing to stop."
    read -n 1 -s -r -p "Press any key to close..."
    exit 0
fi

hdr "Containers running BEFORE stop"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

# Hand off to the canonical stop path
hdr "Stopping Demo-3"
if [[ -x "$SETUP_SCRIPT" ]]; then
    "$SETUP_SCRIPT" stop
else
    warn "setup_and_run3.sh missing/not-executable — falling back to manual cleanup"
    for pidf in /tmp/demo3_guardian.pid /tmp/demo3_agent.pid; do
        [[ -f "$pidf" ]] && kill "$(cat "$pidf")" 2>/dev/null && rm -f "$pidf"
    done
    docker rm -f demo3-web demo3-app demo3-db-pri demo3-db-rep demo3-waf 2>/dev/null || true
fi

# Belt & braces — make sure nothing demo3 is still running
remaining=$(docker ps --filter "name=demo3-" -q | wc -l | tr -d ' ')
if [[ "$remaining" -gt 0 ]]; then
    warn "Some demo3 containers persisted — forcing removal"
    docker ps --filter "name=demo3-" -q | xargs docker rm -f 2>/dev/null || true
fi

# Reap host processes
pgrep -f "guardian3.sh" | xargs -I {} kill {} 2>/dev/null || true
pgrep -f "ai_agent3.py" | xargs -I {} kill {} 2>/dev/null || true
ok "Host processes clean"

hdr "Containers running AFTER stop"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

echo ""
echo -e "${GREEN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║   DEMO-3 STOPPED — OTHER CONTAINERS UNTOUCHED     ║${NC}"
echo -e "${GREEN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}DB volumes preserved — relaunch will resume with same data.${NC}"
echo -e "  ${DIM}For a full wipe (volumes + logs):${NC}"
echo -e "  ${WHITE}  ${SETUP_SCRIPT} reset${NC}"
echo ""
read -n 1 -s -r -p "  Press any key to close this window..."
echo ""

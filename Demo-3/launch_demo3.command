#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  launch_demo3.command — One-click Demo-3 launcher (macOS)
#
#  Double-click from Finder / Desktop → opens Terminal, runs this.
#
#  Behaviour:
#    1. Confirms Docker Desktop is running (prompts to open if not)
#    2. Checks the 6 ports Demo-3 needs against running processes
#       — if a NON-demo3 container is holding a port, ASKS first
#       — if a stale demo3-* container is holding a port, removes it
#    3. Kills any orphaned guardian/agent host processes from prior runs
#    4. Calls setup_and_run3.sh start (which compose-up's all 5 containers
#       + launches guardian + AI agent)
#    5. Waits for the dashboard to respond, then opens it in the browser
#    6. Keeps the Terminal window open so the operator can see status
#
#  Other Docker containers running on the host are NEVER stopped without
#  explicit operator confirmation. Demo-3 runs on its own demo3-net.
#
#  DEFCON Coimbatore 2026 · Venugopal Parameswara
# ══════════════════════════════════════════════════════════════

set -uo pipefail

DEMO3_DIR="/Users/kuttanadan/Documents/defcon-demo/Demo-3"
SETUP_SCRIPT="${DEMO3_DIR}/setup_and_run3.sh"
DASHBOARD_URL="http://localhost:7880"

# Ports the stack binds. label : port
PORTS=(
    "WAF:8090"
    "WEB:9091"
    "APP:3001"
    "DB-PRI:5432"
    "DB-REP:5433"
    "AGENT:7880"
)
DEMO3_CONTAINERS=(demo3-web demo3-app demo3-db-pri demo3-db-rep demo3-waf)

# ── Colours ────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; AMBER='\033[0;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

ok()    { echo -e "${GREEN}  ✓${NC}  $*"; }
fail()  { echo -e "${RED}  ✗${NC}  $*"; }
info()  { echo -e "${CYAN}  →${NC}  $*"; }
warn()  { echo -e "${AMBER}  ⚠${NC}  $*"; }
hdr()   { echo -e "\n${WHITE}$*${NC}\n  $(printf '─%.0s' {1..58})"; }

# ── Banner ─────────────────────────────────────────────────────
clear
echo -e "${GREEN}"
cat << 'BANNER'
  ╔════════════════════════════════════════════════════════════╗
  ║          DEMO-3 ONE-CLICK LAUNCHER · DEFCON 2026          ║
  ║       Three-Tier B-V-R Resilience · Graceful Fail         ║
  ╚════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Step 1 — Docker Desktop running? ───────────────────────────
hdr "STEP 1 · Docker Desktop"
if ! docker info &>/dev/null; then
    warn "Docker Desktop is not running."
    info "Attempting to open Docker Desktop..."
    open -a "Docker" 2>/dev/null || true
    info "Waiting up to 60s for Docker to come online..."
    waited=0
    until docker info &>/dev/null; do
        sleep 2; waited=$((waited + 2))
        if (( waited >= 60 )); then
            fail "Docker did not start in 60s. Please open Docker Desktop manually and rerun."
            echo ""
            read -n 1 -s -r -p "Press any key to close this window..."
            exit 1
        fi
        printf "."
    done
    echo ""
fi
ok "Docker $(docker info --format '{{.ServerVersion}}' 2>/dev/null) running"

# ── Step 2 — Port conflict scan ────────────────────────────────
hdr "STEP 2 · Port conflict scan"
conflicts=()
stale_demo3=()

for entry in "${PORTS[@]}"; do
    label="${entry%%:*}"
    port="${entry##*:}"

    # Anything listening on this port?
    pid_line=$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2; exit}')
    if [[ -z "$pid_line" ]]; then
        # Port free at host level — but might still be claimed by a stopped container with a port-mapping
        # so check Docker too
        owner=$(docker ps -a --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | head -1)
        if [[ -n "$owner" ]] && [[ " ${DEMO3_CONTAINERS[*]} " == *" ${owner} "* ]]; then
            stale_demo3+=("${owner}")
        fi
        ok "${label} :${port} free"
        continue
    fi

    # Something is listening — find out what
    proc=$(echo "$pid_line" | awk '{print $1}')
    pid=$(echo  "$pid_line" | awk '{print $2}')

    # Is it a docker-proxy fronting one of our containers?
    docker_owner=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
                   | grep -E ":${port}->" | awk '{print $1}' | head -1)

    if [[ -n "$docker_owner" ]]; then
        if [[ " ${DEMO3_CONTAINERS[*]} " == *" ${docker_owner} "* ]]; then
            warn "${label} :${port} held by stale demo3 container ${docker_owner} — will recycle"
            stale_demo3+=("${docker_owner}")
        else
            warn "${label} :${port} held by FOREIGN docker container '${docker_owner}'"
            conflicts+=("${port}|${label}|docker:${docker_owner}")
        fi
    else
        # Is it actually our own host process from a previous run?
        cmdline=$(ps -o command= -p "${pid}" 2>/dev/null)
        if [[ "$cmdline" == *"ai_agent3.py"* ]] || [[ "$cmdline" == *"guardian3.sh"* ]]; then
            warn "${label} :${port} held by stale demo3 host process (pid ${pid}) — will recycle"
            kill "${pid}" 2>/dev/null || true
            ok "   killed pid ${pid}"
        else
            warn "${label} :${port} held by host process ${proc} (pid ${pid})"
            conflicts+=("${port}|${label}|host:${proc}(pid ${pid})")
        fi
    fi
done

# Recycle our own stale containers without asking
if (( ${#stale_demo3[@]} > 0 )); then
    info "Removing stale demo3 containers..."
    for c in $(echo "${stale_demo3[@]}" | tr ' ' '\n' | sort -u); do
        docker rm -f "$c" >/dev/null 2>&1 && ok "   removed ${c}" || true
    done
fi

# Hard stop on foreign conflicts — operator must decide
if (( ${#conflicts[@]} > 0 )); then
    echo ""
    fail "Port conflicts with non-demo3 processes detected:"
    for c in "${conflicts[@]}"; do
        IFS='|' read -r port label owner <<< "$c"
        echo -e "    ${RED}→${NC}  ${label} :${port} ← ${owner}"
    done
    echo ""
    warn "Demo-3 will NOT touch other workloads automatically."
    echo -e "  Choose:"
    echo -e "    ${WHITE}[s]${NC} stop the foreign container(s) (only docker, not host procs)"
    echo -e "    ${WHITE}[c]${NC} continue anyway and let docker compose fail (for inspection)"
    echo -e "    ${WHITE}[q]${NC} quit (default)"
    read -n 1 -s -r -p "  Your choice [s/c/q]: " ans
    echo ""
    case "${ans:-q}" in
        s|S)
            for c in "${conflicts[@]}"; do
                IFS='|' read -r _ _ owner <<< "$c"
                if [[ "$owner" == docker:* ]]; then
                    name="${owner#docker:}"
                    info "Stopping ${name}..."
                    docker stop "$name" >/dev/null 2>&1 && ok "   stopped ${name}" || warn "   failed to stop ${name}"
                else
                    warn "Cannot stop host process ${owner} automatically — please handle it yourself."
                fi
            done
            ;;
        c|C)
            warn "Continuing despite conflicts — expect failures."
            ;;
        *)
            info "Aborting."
            echo ""
            read -n 1 -s -r -p "Press any key to close this window..."
            exit 0
            ;;
    esac
fi

# ── Step 3 — Reap orphan host processes (guardian / agent) ─────
hdr "STEP 3 · Cleaning up prior demo3 processes"
for pidf in /tmp/demo3_guardian.pid /tmp/demo3_agent.pid; do
    if [[ -f "$pidf" ]]; then
        oldpid=$(cat "$pidf")
        if kill -0 "$oldpid" 2>/dev/null; then
            kill "$oldpid" 2>/dev/null && ok "killed pid ${oldpid} ($(basename "$pidf"))" || true
        fi
        rm -f "$pidf"
    fi
done
# Also catch any stragglers by command name
pgrep -f "guardian3.sh"        | xargs -I {} kill {} 2>/dev/null || true
pgrep -f "ai_agent3.py"        | xargs -I {} kill {} 2>/dev/null || true
ok "Host processes clean"

# ── Step 4 — Hand off to setup_and_run3.sh start ──────────────
hdr "STEP 4 · Starting Demo-3 stack"
if [[ ! -x "$SETUP_SCRIPT" ]]; then
    chmod +x "$SETUP_SCRIPT" 2>/dev/null || true
fi
"$SETUP_SCRIPT" start
launch_rc=$?
if (( launch_rc != 0 )); then
    fail "setup_and_run3.sh start exited with ${launch_rc}"
    echo ""
    read -n 1 -s -r -p "Press any key to close this window..."
    exit $launch_rc
fi

# ── Step 5 — Wait for dashboard, then open browser ─────────────
hdr "STEP 5 · Waiting for dashboard"
waited=0
until curl -s --max-time 1 "${DASHBOARD_URL}/state" &>/dev/null; do
    sleep 1; waited=$((waited + 1))
    if (( waited >= 30 )); then
        warn "Dashboard didn't respond after 30s — open ${DASHBOARD_URL} manually."
        break
    fi
    printf "."
done
echo ""
ok "Dashboard alive at ${DASHBOARD_URL}"
open "${DASHBOARD_URL}" 2>/dev/null || true

# ── Step 6 — Final status ─────────────────────────────────────
hdr "STEP 6 · Stack status"
docker ps --filter "name=demo3-" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

echo ""
echo -e "${GREEN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║  DEMO-3 LAUNCHED — DASHBOARD OPENED IN BROWSER    ║${NC}"
echo -e "${GREEN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${WHITE}Dashboard:${NC} ${DASHBOARD_URL}"
echo -e "  ${WHITE}Stop:${NC}      double-click ${DIM}stop_demo3.command${NC} on Desktop"
echo -e "  ${DIM}(Demo-2 on :9090 — never touched by this launcher.)${NC}"
echo ""
read -n 1 -s -r -p "  Press any key to close this Terminal window..."
echo ""

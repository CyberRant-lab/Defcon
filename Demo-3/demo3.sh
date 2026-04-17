#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  DEMO-3 CONTROL SCRIPT — AI Resilience Agent
#  Three-Tier B-V-R Demo · DEFCON Coimbatore 2026
#  Runs completely isolated from Demo-2 (port 9090)
#
#  Usage:
#    start    — start the AI agent + open dashboard
#    stop     — stop the agent
#    status   — check everything
#    open     — open dashboard in browser
# ══════════════════════════════════════════════════════════════

DEMO3_DIR="/Users/kuttanadan/Documents/defcon-demo/Demo-3"
AGENT="${DEMO3_DIR}/ai_agent.py"
DASHBOARD="${DEMO3_DIR}/dashboard3.html"
AGENT_PORT=7880
PID_FILE="/tmp/demo3_agent.pid"

GREEN='\033[0;32m'; RED='\033[0;31m'; AMBER='\033[0;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC}  $*"; }
fail() { echo -e "${RED}  ✗${NC}  $*"; }
info() { echo -e "${CYAN}  →${NC}  $*"; }
hdr()  { echo -e "\n${WHITE}$*${NC}\n  $(printf '─%.0s' {1..45})"; }

cmd_start() {
  hdr "DEMO-3 — AI RESILIENCE AGENT"

  # Check port free
  if lsof -i :${AGENT_PORT} &>/dev/null; then
    ok "Agent already running on :${AGENT_PORT}"
  else
    info "Starting AI agent on port ${AGENT_PORT}..."
    python3 "${AGENT}" &
    echo $! > "${PID_FILE}"
    sleep 1
    if lsof -i :${AGENT_PORT} &>/dev/null; then
      ok "AI agent running on :${AGENT_PORT}"
    else
      fail "Agent failed to start — check python3 is available"
      exit 1
    fi
  fi

  # Confirm Demo-2 untouched
  info "Confirming Demo-2 is unaffected..."
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 2 http://localhost:9090 2>/dev/null || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    ok "Demo-2 healthy on :9090 — untouched ✓"
  else
    info "Demo-2 not running (that's fine — they're independent)"
  fi

  echo ""
  ok "Dashboard: http://localhost:${AGENT_PORT}"
  info "Opening browser..."
  open "http://localhost:${AGENT_PORT}"
}

cmd_stop() {
  hdr "STOPPING DEMO-3"
  if [[ -f "${PID_FILE}" ]]; then
    PID=$(cat "${PID_FILE}")
    kill "${PID}" 2>/dev/null && ok "Agent stopped (PID ${PID})" || info "Already stopped"
    rm -f "${PID_FILE}"
  else
    # Fallback: kill by port
    PID=$(lsof -ti :${AGENT_PORT} 2>/dev/null)
    if [[ -n "$PID" ]]; then
      kill "$PID" && ok "Agent stopped"
    else
      info "Agent was not running"
    fi
  fi
  rm -f /tmp/demo3_agent.jsonl
  ok "Log cleared"
}

cmd_status() {
  hdr "DEMO-3 STATUS"

  if lsof -i :${AGENT_PORT} &>/dev/null; then
    ok "AI agent running on :${AGENT_PORT}"
    RESP=$(curl -s "http://localhost:${AGENT_PORT}/state" 2>/dev/null)
    if [[ -n "$RESP" ]]; then
      INCIDENTS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['agent']['total_incidents'])" 2>/dev/null)
      ok "Agent responsive — ${INCIDENTS} incidents handled this session"
    fi
  else
    fail "AI agent not running"
    info "Start with: ${DEMO3_DIR}/demo3.sh start"
  fi

  echo ""
  info "Demo-2 (port 9090):"
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://localhost:9090 2>/dev/null || echo "000")
  echo "  HTTP ${STATUS} — $([ "$STATUS" == "200" ] && echo "healthy" || echo "not running")"

  echo ""
  info "Port map:"
  echo "  :9090  Demo-2 (existing — untouched)"
  echo "  :${AGENT_PORT}  Demo-3 AI agent + dashboard"
}

cmd_open() {
  open "http://localhost:${AGENT_PORT}"
  ok "Opened http://localhost:${AGENT_PORT}"
}

case "${1:-start}" in
  start)  cmd_start  ;;
  stop)   cmd_stop   ;;
  status) cmd_status ;;
  open)   cmd_open   ;;
  *)
    echo "Usage: ${DEMO3_DIR}/demo3.sh [start|stop|status|open]"
    ;;
esac

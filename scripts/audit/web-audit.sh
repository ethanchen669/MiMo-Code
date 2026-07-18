#!/usr/bin/env bash
# web-audit.sh — Standardized web security audit pipeline
# Usage: web-audit.sh <url> [--full|--quick|--skip-llm] [--output <dir>]
set -euo pipefail

# === arg parsing ===
URL=""
MODE="full"
OUTPUT_DIR=""

for arg in "$@"; do
  case "$arg" in
    --full|--quick|--skip-llm) MODE="${arg#--}" ;;
    --output=*) OUTPUT_DIR="${arg#*=}" ;;
    --output) shift; OUTPUT_DIR="$1" ;;
    -h|--help) echo "Usage: $0 <url> [--full|--quick|--skip-llm]"; exit 0 ;;
    *) URL="$arg" ;;
  esac
done

[[ -n "$URL" ]] || { echo "Error: URL required"; exit 1; }

# === setup ===
DOMAIN=$(echo "$URL" | sed 's|https\?://||' | cut -d/ -f1)
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="web-audit-${DOMAIN}-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"/{raw,findings,llm}

# ================================================================
# Phase1: Automated Reconnaissance
# ================================================================
echo "[1/4] Reconnaissance: fetching $URL ..."

# HTTP headers
curl -sI -L --max-time 15 "$URL" > "$OUTPUT_DIR/raw/headers.txt" 2>/dev/null || echo "TIMEOUT" > "$OUTPUT_DIR/raw/headers.txt"

# HTML body
curl -s -L --max-time 15 "$URL" > "$OUTPUT_DIR/raw/body.html" 2>/dev/null || echo "" > "$OUTPUT_DIR/raw/body.html"

# robots.txt
curl -s --max-time 10 "$URL/robots.txt" > "$OUTPUT_DIR/raw/robots.txt" 2>/dev/null || true

# DNS records
echo "{}" > "$OUTPUT_DIR/raw/dns.json"
for rtype in A AAAA CNAME MX TXT; do
  dig +short "$DOMAIN" "$rtype" 2>/dev/null | head -5 >> "$OUTPUT_DIR/raw/dns.txt" 2>/dev/null || true
done

# SSL certificate
openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null | \
  openssl x509 -noout -dates -subject -issuer 2>/dev/null > "$OUTPUT_DIR/raw/ssl.txt" || true

# JS scripts
python3 -c "
import re,sys
try:
    html = open('$OUTPUT_DIR/raw/body.html').read()
    scripts = re.findall(r'<script[^>]*src=[\"\\']([^\"\\']+)[\"\\']', html, re.I)
    domains = set()
    for s in scripts:
        if '://' in s: domains.add(s.split('/')[2])
        elif s.startswith('//'): domains.add(s.split('/')[2])
    print('\\n'.join(sorted(scripts)))
    print('\\n--- DOMAINS ---')
    print('\\n'.join(sorted(domains)))
except: pass
" > "$OUTPUT_DIR/raw/scripts.txt" 2>/dev/null

echo "  ✓ headers: $(wc -l < "$OUTPUT_DIR/raw/headers.txt" | tr -d ' ') lines"
echo "  ✓ html: $(wc -c < "$OUTPUT_DIR/raw/body.html" | tr -d ' ') bytes"

# ================================================================
# Phase2: Automated Checks
# ================================================================
echo "[2/4] Automated checks ..."

python3 << PYEOF > "$OUTPUT_DIR/findings/auto-findings.json"
import json, re, subprocess, os

outdir = "$OUTPUT_DIR"
findings = {"critical": [], "high": [], "medium": [], "low": [], "info": []}
headers_raw = open(f"{outdir}/raw/headers.txt").read()
body = open(f"{outdir}/raw/body.html").read()

# Parse headers
headers = {}
for line in headers_raw.split('\\n'):
    if ':' in line:
        k, v = line.split(':', 1)
        headers[k.strip().lower()] = v.strip()

# --- Security Headers ---
SECURITY_HEADERS = {
    'content-security-policy': ('CSP missing', 'high'),
    'strict-transport-security': ('HSTS missing', 'high'),
    'x-frame-options': ('Clickjacking protection missing', 'medium'),
    'x-content-type-options': ('MIME sniffing not disabled', 'low'),
    'referrer-policy': ('Referrer policy missing', 'low'),
    'permissions-policy': ('Permissions policy missing', 'low'),
}
for hdr, (desc, sev) in SECURITY_HEADERS.items():
    if hdr not in headers:
        findings[sev].append({'check': f'Missing header: {hdr}', 'detail': desc})

# --- CORS ---
origin = headers.get('access-control-allow-origin', '')
if origin == '*':
    findings['high'].append({'check': 'Permissive CORS', 'detail': 'Access-Control-Allow-Origin:* — any site can read responses'})
elif origin:
    findings['medium'].append({'check': 'CORS reflects Origin', 'detail': f'Access-Control-Allow-Origin:{origin}'})
if headers.get('access-control-allow-credentials', '').lower() == 'true':
    findings['critical'].append({'check': 'CORS with credentials', 'detail': 'Access-Control-Allow-Credentials:true combined with permissive CORS'})

# --- Cookie analysis ---
for line in headers_raw.split('\\n'):
    if line.lower().startswith('set-cookie:'):
        cookie = line.split(':',1)[1].strip()
        flags = []
        if 'httponly' not in cookie.lower(): flags.append('no HttpOnly')
        if 'secure' not in cookie.lower(): flags.append('no Secure')
        if 'samesite=' not in cookie.lower(): flags.append('no SameSite')
        if flags:
            findings['medium'].append({'check': 'Cookie security', 'detail': f'{cookie[:60]}... missing:{flags}'})

# --- SSL grade ---
ssl_raw = open(f"{outdir}/raw/ssl.txt").read()
if 'notAfter' in ssl_raw:
    expiry = re.search(r'notAfter=(.+)', ssl_raw)
    if expiry:
        findings['info'].append({'check': 'SSL certificate expiry', 'detail': expiry.group(1)})
else:
    findings['high'].append({'check': 'SSL certificate check failed', 'detail': 'Could not retrieve certificate'})

# --- Subdomain discovery via DNS ---
subdomains = set()
for line in open(f"{outdir}/raw/dns.txt"):
    line = line.strip()
    if line and line.endswith('.' + outdir.split('web-audit-')[1].split('-')[0] if 'web-audit-' in outdir else ''):
        subdomains.add(line)
if subdomains:
    findings['info'].append({'check': 'DNS subdomains found', 'detail': str(len(subdomains)) + ' subdomain records, check for takeover risks'})

# --- Server header ---
server = headers.get('server', '')
if server:
    findings['info'].append({'check': 'Server header exposed', 'detail': f'Server:{server}'})

print(json.dumps(findings, indent=2, ensure_ascii=False))
PYEOF

echo "  ✓ automated checks complete"
python3 -c "import json; f=json.load(open('$OUTPUT_DIR/findings/auto-findings.json')); total=sum(len(v) for v in f.values()); print(f'  total findings: {total}')"

# ================================================================
# Phase3: LLM Analysis
# ================================================================
if [[ "$MODE" == "skip-llm" ]]; then
  echo "[3/4] LLM analysis: SKIPPED (--skip-llm)"
else
  echo "[3/4] LLM analysis: dispatching security-reviewer ..."
  echo "  (Phase3a: infrastructure audit)"
  echo "  (Phase3b: client-side threat audit)"
  echo ""
  echo "  To run LLM analysis, dispatch via MiMo Code:"
  echo ""
  echo "  # Infrastructure audit"
  echo "  actor run security-reviewer \"Audit <URL>\" <prompt>"
  echo ""
  echo "  # Client threat audit"
  echo "  actor run security-reviewer \"Client threats at <URL>\" <prompt>"
  echo ""
  echo "  Or run: $0 $URL --skip-llm  for script-only results"
  echo ""
  echo "  LLM analysis will be saved to:"
  echo "    $OUTPUT_DIR/llm/infra-audit.md"
  echo "    $OUTPUT_DIR/llm/client-threats.md"
fi

# ================================================================
# Phase4: Report Generation
# ================================================================
echo "[4/4] Generating report ..."

REPORT="$OUTPUT_DIR/report.md"

cat > "$REPORT" << REPORTEOF
# Web Security Audit — $URL
**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Methodology:** Automated Phase1-2 + LLM Phase3

---

## Phase1-2: Automated Findings

$(python3 -c "
import json
f = json.load(open('$OUTPUT_DIR/findings/auto-findings.json'))
for sev in ['critical','high','medium','low','info']:
    items = f.get(sev, [])
    if items:
        print(f'### {sev.upper()} ({len(items)})')
        for item in items:
            print(f'- {item[\"detail\"]}')
        print()
")

## Phase3: LLM Analysis

$([[ -f "$OUTPUT_DIR/llm/infra-audit.md" ]] && cat "$OUTPUT_DIR/llm/infra-audit.md" || echo "(not run — use --full mode for LLM analysis)")

---

## Raw Data
- Headers: \`$OUTPUT_DIR/raw/headers.txt\`
- HTML: \`$OUTPUT_DIR/raw/body.html\`
- DNS: \`$OUTPUT_DIR/raw/dns.txt\`
- SSL: \`$OUTPUT_DIR/raw/ssl.txt\`
- Scripts: \`$OUTPUT_DIR/raw/scripts.txt\`
REPORTEOF

echo "  ✓ report: $REPORT"
echo ""
echo "=== Audit Complete ==="
echo "  URL: $URL"
echo "  Report: $REPORT"
echo "  Raw data: $OUTPUT_DIR/raw/"

cat "$REPORT"

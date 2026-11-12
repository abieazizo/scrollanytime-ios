#!/usr/bin/env bash
# PHASE LAUNCH 1.2 — is our email actually going to arrive?
#
# Checks SPF, DKIM and DMARC for the domain we send sign-in codes FROM. If these are wrong the app
# does not break in any visible way — codes just quietly land in spam, and every new user silently
# fails to sign in. That is the worst class of bug there is, so it gets its own script.
#
#   ./ship/email-check.sh                          # checks the live sending domain
#   ./ship/email-check.sh scrollanytime.com        # check a specific domain
#
# Uses dig when available and falls back to Cloudflare DNS-over-HTTPS, so it runs identically on
# macOS, Linux, and a Windows Git Bash shell where dig does not exist.
set -uo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  # The domain in EMAIL_FROM is the one that has to pass — not necessarily the site's domain.
  DOMAIN=$(grep -o '"EMAIL_FROM":[^,]*' worker/wrangler.jsonc 2>/dev/null | grep -o '@[^">]*' | tr -d '@' | head -1)
  DOMAIN="${DOMAIN:-scrollanytime.com}"
fi

# Resend publishes DKIM under this selector.
DKIM_SELECTOR="${DKIM_SELECTOR:-resend._domainkey}"

pass=0; fail=0; warn=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; warn=$((warn+1)); }

PY=$(command -v python3 || command -v python || true)

# One lookup of any type. dig when present, Cloudflare DNS-over-HTTPS otherwise.
# Prints one record per line, unquoted, ANSWER SECTION ONLY — a NODATA reply carries the zone's SOA
# in the Authority section, and reading that as an answer reports "MX records present" for a domain
# that has none, which is exactly the false pass this script exists to prevent.
resolve() {
  local name="$1" type="$2" tnum
  if command -v dig >/dev/null 2>&1; then
    dig +short "$type" "$name" 2>/dev/null | sed 's/^"//; s/"$//; s/" "//g'
    return
  fi
  case "$type" in
    TXT) tnum=16 ;;
    MX) tnum=15 ;;
    CNAME) tnum=5 ;;
    A) tnum=1 ;;
    AAAA) tnum=28 ;;
    *) tnum="$type" ;;
  esac
  local json
  json=$(curl -sS -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${name}&type=${type}" 2>/dev/null)
  [ -z "$json" ] && return
  if [ -n "$PY" ]; then
    printf '%s' "$json" | "$PY" -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for a in d.get('Answer', []):
    if a.get('type') != $tnum:   # skip CNAMEs returned alongside the record we asked for
        continue
    v = a.get('data', '').strip()
    if v.startswith('\"') and v.endswith('\"'):
        v = v[1:-1]
    v = v.replace('\\\\\"', '').replace('\" \"', '')
    print(v)
"
  else
    # No python either: fall back to a crude grep. Better than nothing, and only reachable on a
    # machine that has neither dig nor python, which is not any machine we ship from.
    printf '%s' "$json" | grep -o '"data":"[^"]*"' | sed 's/"data":"//; s/"$//'
  fi
}

txt()   { resolve "$1" TXT; }
cname() { resolve "$1" CNAME; }
mx()    { resolve "$1" MX; }

echo
echo "── email deliverability: ${DOMAIN} ──"
command -v dig >/dev/null 2>&1 && echo "   (resolver: dig)" || echo "   (resolver: Cloudflare DNS-over-HTTPS — dig not installed)"
echo

echo "SPF — may this server send as ${DOMAIN}?"
# Resend does NOT put SPF on the root. It signs the envelope-from as send.<domain> and publishes
# SPF there, so checking only the apex reports a failure for a perfectly healthy setup. Check both.
SPF_ROOT=$(txt "$DOMAIN" | grep -i 'v=spf1' | head -1)
SPF_SEND=$(txt "send.${DOMAIN}" | grep -i 'v=spf1' | head -1)
SPF="${SPF_SEND:-$SPF_ROOT}"
SPF_AT="send.${DOMAIN}"; [ -z "$SPF_SEND" ] && SPF_AT="$DOMAIN"
if [ -z "$SPF" ]; then
  bad "no SPF record on ${DOMAIN} or send.${DOMAIN}. Receivers have nothing saying we may send."
else
  echo "     [$SPF_AT] $SPF"
  echo "$SPF" | grep -qi 'amazonses\|resend\|include:' && ok "SPF present with a sender include" || note "SPF present but includes no sender — check it covers Resend"
  echo "$SPF" | grep -qi '~all\|-all' && ok "SPF ends in ~all or -all" || note "SPF does not end in ~all/-all (a bare +all trusts everyone)"
fi
BOUNCE=$(mx "send.${DOMAIN}")
if [ -n "$BOUNCE" ]; then
  ok "bounce handling: $(echo "$BOUNCE" | head -1)"
else
  note "no MX on send.${DOMAIN} — Resend cannot collect bounces, which hurts sender reputation over time"
fi
echo

echo "DKIM — is our mail cryptographically signed? (${DKIM_SELECTOR}.${DOMAIN})"
DKIM=$(txt "${DKIM_SELECTOR}.${DOMAIN}")
if [ -z "$DKIM" ]; then
  bad "no DKIM record at ${DKIM_SELECTOR}.${DOMAIN}. Gmail treats unsigned bulk mail as suspicious."
else
  echo "     ${DKIM:0:80}..."
  echo "$DKIM" | grep -qi 'p=' && ok "DKIM public key published" || bad "DKIM record exists but carries no p= key"
fi
echo

echo "DMARC — what should a receiver do when SPF/DKIM fail? (_dmarc.${DOMAIN})"
DMARC=$(txt "_dmarc.${DOMAIN}" | grep -i 'v=DMARC1' | head -1)
if [ -z "$DMARC" ]; then
  bad "no DMARC record. Gmail and Yahoo have required one for bulk senders since Feb 2024."
else
  echo "     $DMARC"
  ok "DMARC published"
  echo "$DMARC" | grep -qi 'p=none' && note "policy is p=none (monitor only) — fine to launch with, tighten to quarantine later"
fi
echo

echo "MX — can ${DOMAIN} RECEIVE mail? (hello@ is in the app, the listing, and Apple's contact path)"
MXR=$(mx "$DOMAIN")
if [ -z "$MXR" ]; then
  bad "no MX records — mail to hello@${DOMAIN} BOUNCES. See SETUP-DOMAIN.md part 1."
else
  echo "$MXR" | sed 's/^/     /'
  echo "$MXR" | grep -qi 'mx.cloudflare.net' && ok "Cloudflare Email Routing is receiving" || ok "MX records present"
fi
echo

echo "── summary ──"
printf '  %d passed, %d failed, %d to look at\n\n' "$pass" "$fail" "$warn"
if [ "$fail" -gt 0 ]; then
  echo "  Fix the failures before launch. In Resend: Domains → Add domain → ${DOMAIN},"
  echo "  then paste the records it shows into Cloudflare DNS for that zone."
  echo
  exit 1
fi
exit 0

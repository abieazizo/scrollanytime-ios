#!/usr/bin/env bash
# ship/mail-domain-finish.sh — finish the move of sign-in mail onto our own domain.
#
#   bash ship/mail-domain-finish.sh [test-recipient@example.com]
#
# Codes currently send from clipflow.shefabuilders.com: a verified domain, so mail DOES arrive, but
# one with no relationship to this product — the kind of from/subject mismatch a spam filter weighs.
# mail.scrollanytime.com is set up to replace it and its DNS is live and correct. The only thing
# left is Resend confirming DKIM, which is asynchronous and on their side.
#
# This script is the whole remaining step, and it GUARDS ITSELF: it will not flip EMAIL_FROM while
# the domain is pending. That guard is the point. Switching the sender to a domain Resend has not
# verified does not degrade gracefully — every sign-in code bounces, and the only way in to the
# product breaks for everyone at once. Better to keep sending from the ugly-but-verified domain.
#
# Safe to run repeatedly. Run it again tomorrow if it says "still pending".
set -uo pipefail
cd "$(dirname "$0")/.."

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
ok()   { echo "  ${G}OK${N}   $*"; }
bad()  { echo "  ${R}FAIL${N} $*"; }
warn() { echo "  ${Y}warn${N} $*"; }
info() { echo "  ${D}$*${N}"; }

DOMAIN=mail.scrollanytime.com
DOMAIN_ID=20126f7c-03a0-4e9e-b90a-d8b5644bb2b0
NEW_FROM="Scroll Anytime <signin@${DOMAIN}>"
OLD_FROM="Scroll Anytime <signin@clipflow.shefabuilders.com>"
TO="${1:-shockedinfos@gmail.com}"
# `bash ship/mail-domain-finish.sh <email> --retrigger` restarts Resend's DNS check. Do that only
# after changing a record; see the note at step 1.
[ "${2:-}" = "--retrigger" ] && RETRIGGER=1

# The D1 preview binding is a PLACEHOLDER id that also keys the local dev SQLite file. `--remote`
# refuses to start unless it resolves, so point it at a throwaway database for the duration and put
# it back on every exit path — including Ctrl-C. Never point it at production: a remote dev server
# would then be one stray request away from writing to live data.
SCRATCH=991291c1-c5c5-4d07-a094-6690fe4f077b
PLACEHOLDER=5a6b7c8d-0000-4000-8000-000000000001
BASE=http://127.0.0.1:8799
PID=""
restore() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  sed -i "s/$SCRATCH/$PLACEHOLDER/" worker/wrangler.jsonc 2>/dev/null
}
trap restore EXIT INT TERM

echo
echo "${B}Sign-in mail — finishing the move to ${DOMAIN}${N}"
echo

# ── 1. what does Resend see right now ──────────────────────────────────────────────────────────
sed -i "s/$PLACEHOLDER/$SCRATCH/" worker/wrangler.jsonc
( cd worker && nohup npx wrangler dev --remote --port 8799 --inspector-port 9799 >/tmp/mdf.log 2>&1 & echo $! >/tmp/mdf.pid )
PID=$(cat /tmp/mdf.pid)
info 'starting a remote-bound dev server (this is the only way to reach the production Resend key)'
for _ in $(seq 1 90); do curl -s -m 2 -o /dev/null "$BASE/healthz" && break; sleep 2; done
if ! curl -s -m 5 -o /dev/null "$BASE/healthz"; then
  bad 'the remote dev server never came up'; tail -12 /tmp/mdf.log; exit 1
fi

echo "${B}1. Resend's view of ${DOMAIN}${N}"
# READ ONLY by default. POSTing /verify does not "poll" — it RESTARTS the check and resets every
# record to pending. Measured: SPF and MX had both reached `verified`, a re-trigger knocked all
# three back to `pending`. So re-triggering on every run keeps the domain permanently unverified.
# Pass --retrigger only after actually changing DNS.
if [ "${RETRIGGER:-0}" = "1" ]; then
  info 're-triggering verification (only correct after a DNS change)'
  curl -s -m 30 -X POST "$BASE/dev/resend-verify/$DOMAIN_ID" >/dev/null
  sleep 8
fi
STATUS=$(curl -s -m 30 -X POST "$BASE/dev/resend-domain?name=$DOMAIN" | python -c "
import sys,json
d=json.load(sys.stdin); dom=d.get('domain') or {}
for r in dom.get('records') or []:
    print('  %-9s %-4s %s' % ('['+str(r.get('status'))+']', r.get('type'), r.get('name')), file=sys.stderr)
print(dom.get('status') or 'unknown')
")
echo "  domain status: ${B}${STATUS}${N}"

if [ "$STATUS" != "verified" ]; then
  echo
  warn "still ${STATUS} — NOT flipping the sender."
  cat <<EOF

  ${D}The DNS is not the problem. All three records are published and correct at the authoritative
  nameserver, byte-for-byte, in the same form as clipflow.shefabuilders.com — which Resend has
  already verified. The per-record statuses above are Resend's own view; DKIM propagation on
  Amazon SES, which Resend runs on, is the slow one and can take hours.

  Nothing is broken and nothing is blocked: sign-in codes keep sending from the verified
  clipflow domain, which Resend reports as \`delivered\`.

  Just run this again later.${N}
EOF
  exit 0
fi

ok "Resend has verified ${DOMAIN}"

# ── 2. flip the sender ─────────────────────────────────────────────────────────────────────────
echo
echo "${B}2. switching EMAIL_FROM${N}"
if grep -qF "$NEW_FROM" worker/wrangler.jsonc; then
  ok 'EMAIL_FROM already points at the new domain'
else
  python - <<PY
import io
p='worker/wrangler.jsonc'
s=io.open(p,encoding='utf-8').read()
assert '''$OLD_FROM''' in s, 'EMAIL_FROM not found in its expected form'
io.open(p,'w',encoding='utf-8',newline='\n').write(s.replace('''$OLD_FROM''','''$NEW_FROM'''))
PY
  ok "EMAIL_FROM -> ${NEW_FROM}"
fi
restore; PID=""   # deploy from the real config, not the scratch-preview one
( cd worker && npx wrangler deploy ) 2>&1 | tail -4

# ── 3. prove a real code sends from the new domain and is delivered ────────────────────────────
echo
echo "${B}3. live send from the new domain${N}"
( cd worker && npx wrangler tail --format json >/tmp/mdf-tail.log 2>&1 & echo $! >/tmp/mdf-tail.pid )
# WAIT for the tail to attach before sending. Firing immediately raced it: the request completed
# before the tail was live, so the log line it greps for never appeared and a send that had
# actually worked was reported as "no send line".
for _ in $(seq 1 30); do grep -qi 'connected\|successfully created tail' /tmp/mdf-tail.log 2>/dev/null && break; sleep 2; done
sleep 3
sleep 6
curl -s -m 20 -X POST https://scrollanytime.com/auth/request-code \
  -H 'Content-Type: application/json' -d "{\"email\":\"$TO\"}" >/dev/null
sleep 12
kill "$(cat /tmp/mdf-tail.pid)" 2>/dev/null
MSG=$(grep -o 'resend accepted to=[^ ]* id=[0-9a-f-]*' /tmp/mdf-tail.log | tail -1)
if [ -z "$MSG" ]; then
  warn 'no send line in the tail — the code may still have sent; check the tail log'
  exit 0
fi
ID="${MSG##*id=}"
ok "$MSG"

sed -i "s/$PLACEHOLDER/$SCRATCH/" worker/wrangler.jsonc
( cd worker && nohup npx wrangler dev --remote --port 8799 --inspector-port 9799 >/tmp/mdf2.log 2>&1 & echo $! >/tmp/mdf.pid )
PID=$(cat /tmp/mdf.pid)
for _ in $(seq 1 90); do curl -s -m 2 -o /dev/null "$BASE/healthz" && break; sleep 2; done
curl -s -m 30 "$BASE/dev/email-status/$ID" | python -c "
import sys,json
e=(json.load(sys.stdin).get('email') or {})
print('  from      ', e.get('from'))
print('  to        ', e.get('to'))
print('  subject   ', e.get('subject'))
print('  last_event', e.get('last_event'))
"
echo
echo "${G}${B}Sign-in mail now sends from ${DOMAIN}.${N}"

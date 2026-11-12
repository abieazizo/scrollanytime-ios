#!/usr/bin/env bash
# ship/retag-library.sh — re-derive every ready clip's auto topic tags against PRODUCTION.
#
# Needed once after the taxonomy gained per-holiday topics (rosh-hashanah, yom-kippur, sukkot,
# chanukah, tu-bishvat, purim, pesach, lag-baomer, shavuot, tisha-bav): the library was tagged
# under the old one, and the calendar can only time what is tagged. Idempotent — safe to re-run
# after any keyword change. Admin-set tags survive (retagClipTopics only replaces 'auto').
#
# HOW IT REACHES PRODUCTION. /dev/retag-all is DEV_MODE + local-host gated, so it runs through
# `wrangler dev --remote` with the D1 *preview* binding pointed at the production database — the
# same precedented path the first real backup took (SHIP.md 1.1). wrangler.jsonc is restored on
# EVERY exit path: the placeholder preview id also keys the local dev SQLite file.
set -u
cd "$(dirname "$0")/../worker"
PROD=787e3b5c-ca67-4035-97ae-ed373ad6f51e
PLACEHOLDER=5a6b7c8d-0000-4000-8000-000000000001
B=http://127.0.0.1:8799
PID=""
G='\033[32m'; R='\033[31m'; N='\033[0m'
restore() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  sed -i "s/\"preview_database_id\": \"$PROD\"/\"preview_database_id\": \"$PLACEHOLDER\"/" wrangler.jsonc
  grep -q "$PLACEHOLDER" wrangler.jsonc && echo "  wrangler.jsonc restored" || echo -e "  ${R}WARNING: wrangler.jsonc NOT restored — fix preview_database_id by hand${N}"
}
trap restore EXIT

echo; echo "Retagging the production library"
sed -i "s/\"preview_database_id\": \"$PLACEHOLDER\"/\"preview_database_id\": \"$PROD\"/" wrangler.jsonc
grep -q "\"preview_database_id\": \"$PROD\"" wrangler.jsonc || { echo -e "  ${R}could not point the preview at production${N}"; exit 1; }
echo "  preview D1 -> production (temporarily)"

nohup npx wrangler dev --remote --port 8799 --inspector-port 9799 > /tmp/retag.log 2>&1 &
PID=$!
for i in $(seq 1 90); do curl -s -m 2 -o /dev/null "$B/healthz" && break; sleep 2; done
curl -s -m 5 -o /dev/null "$B/healthz" || { echo -e "  ${R}remote dev server never came up${N}"; tail -8 /tmp/retag.log; exit 1; }
echo "  remote dev server up"

# sanity: this MUST be the production library, not the dev seed
READY=$(curl -s -m 20 "$B/dev/state" | python -c "import sys,json;print(json.load(sys.stdin).get('ready',0))")
echo "  ready clips visible: $READY"
[ "$READY" -gt 500 ] || { echo -e "  ${R}that is not production (expected 800+) — aborting${N}"; exit 1; }

OFFSET=0; TOTAL=0
while :; do
  OUT=$(curl -s -m 170 -X POST "$B/dev/retag-all?offset=$OFFSET&limit=100")
  N=$(echo "$OUT" | python -c "import sys,json;d=json.load(sys.stdin);print(d.get('retagged',0))" 2>/dev/null || echo 0)
  NEXT=$(echo "$OUT" | python -c "import sys,json;d=json.load(sys.stdin);print(d.get('next') if d.get('next') is not None else '')" 2>/dev/null)
  TOTAL=$((TOTAL + N))
  echo "  retagged $N (offset $OFFSET) — running total $TOTAL"
  [ -z "$NEXT" ] && { LAST="$OUT"; break; }
  OFFSET=$NEXT
done
echo
echo "  topic counts after retag:"
echo "$LAST" | python -c "
import sys,json
for r in json.load(sys.stdin).get('counts',[]): print('    %-16s %s' % (r['topic'], r['n']))
"
echo -e "\n${G}RETAG: $TOTAL clips${N}"

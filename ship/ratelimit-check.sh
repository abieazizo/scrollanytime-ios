#!/usr/bin/env bash
# PHASE LAUNCH 1.5 — do the rate limits actually limit?
#
# Run this after ANY change to the Workers plan or the ratelimits config. As of 2026-09-02 layer 1
# (Cloudflare's rate-limiting binding) is present at runtime but does NOT enforce on this account's
# deployed Worker, so layer 2 (the in-process limiter) is what is holding the line. This script
# tells you which layers are live rather than letting you assume.
#
#   ./ship/ratelimit-check.sh [origin]
set -uo pipefail
ORIGIN="${1:-https://scrollanytime.com}"

echo
echo "── rate limits: ${ORIGIN} ──"
echo

echo "LAYER 1 — Cloudflare rate-limiting binding (RL_SELFTEST, ceiling 5 per 60s)"
tripped=""
for i in $(seq 1 8); do
  body=$(curl -s "${ORIGIN}/health/ratelimit")
  allowed=$(printf '%s' "$body" | grep -o '"allowed":[a-z]*' | cut -d: -f2)
  present=$(printf '%s' "$body" | grep -o '"binding_present":[a-z]*' | cut -d: -f2)
  printf '  call %d: allowed=%s\n' "$i" "$allowed"
  [ "$allowed" = "false" ] && [ -z "$tripped" ] && tripped=$i
done
echo
if [ "${present:-false}" != "true" ]; then
  printf '  \033[31m✗\033[0m the binding is not present at runtime at all — check wrangler.jsonc "ratelimits"\n'
elif [ -n "$tripped" ]; then
  printf '  \033[32m✓\033[0m LAYER 1 IS ENFORCING (first refusal at call %s). The real ceilings now bind:\n' "$tripped"
  printf '      /feed   60/min per token, 900/min per IP\n'
  printf '      /clips/ 180/min per token, 3000/min per IP\n'
  printf '      /auth/  120/min per IP\n'
else
  printf '  \033[33m!\033[0m LAYER 1 IS NOT ENFORCING — 8 calls all allowed against a ceiling of 5.\n'
  printf '      The binding exists but does nothing. Leading hypothesis: it needs the Workers Paid\n'
  printf '      plan (SETUP-DOMAIN.md part 2). Re-run this the moment that plan is enabled.\n'
      printf '      Layer 3 (the Durable Object) is what protects these routes meanwhile.\n'
fi
echo

echo "LAYER 3 — Durable Object limiter (lib/rateLimiterDO.ts) — THE control"
echo "  Bursting 500 requests at /feed with one token (ceiling 60/min per token)…"
TOK=$(curl -s -X POST "${ORIGIN}/auth/guest" -H 'Content-Type: application/json' -d '{}' |
  grep -o '"token":"[^"]*"' | cut -d'"' -f4)
if [ -z "$TOK" ]; then
  printf '  \033[31m✗\033[0m could not mint a guest token — cannot test\n'
  exit 1
fi
seq 1 500 | xargs -P 25 -I{} curl -s -o /dev/null -w "%{http_code}\n" "${ORIGIN}/feed" \
  -H "Authorization: Bearer $TOK" > /tmp/rlcheck.$$ 2>/dev/null
n429=$(grep -c '^429$' /tmp/rlcheck.$$ || true)
n200=$(grep -c '^200$' /tmp/rlcheck.$$ || true)
rm -f /tmp/rlcheck.$$
printf '  200: %s    429: %s\n' "$n200" "$n429"
if [ "${n429:-0}" -gt 0 ]; then
  printf '  \033[32m✓\033[0m ENFORCING — %s allowed against a ceiling of 60, %s refused\n' "$n200" "$n429"
else
  printf '  \033[31m✗\033[0m 500 requests from one token, zero refusals. These routes are UNPROTECTED.\n'
  exit 1
fi
echo

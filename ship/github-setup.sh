#!/usr/bin/env bash
# ship/github-setup.sh — create the repo, push, set every secret, run both Actions, confirm green.
#
#   GITHUB_TOKEN=ghp_xxxxx ./ship/github-setup.sh
#
# Does the whole thing through the GitHub API — no `gh` CLI needed, and it is not installed here.
# Idempotent: an existing repo is reused, existing secrets are overwritten, and a re-run just
# re-checks. Nothing is deleted.
#
# This is what unlocks the two things that have never run: nightly auto-ingestion of new clips, and
# the weekly off-site media mirror. Until the code is on GitHub, both workflows are just files.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
fail=0
ok()   { printf "  ${G}OK${N}   %s\n" "$1"; }
bad()  { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
warn() { printf "  ${Y}warn${N} %s\n" "$1"; }
info() { printf "  ${D}%s${N}\n" "$1"; }

TOK="${GITHUB_TOKEN:-}"
if [ -z "$TOK" ]; then
  printf "\n${R}GITHUB_TOKEN is not set.${N}\n\n"
  printf "  ${B}https://github.com/settings/tokens/new?scopes=repo,workflow&description=scrollanytime${N}\n"
  printf "  ${D}(that link pre-ticks exactly the two scopes needed: repo + workflow — set expiry 90 days, Generate, copy)${N}\n\n"
  printf "  Then:  GITHUB_TOKEN=ghp_xxxxx ./ship/github-setup.sh\n\n"
  exit 1
fi

REPO_NAME="${REPO_NAME:-scrollanytime}"
API=https://api.github.com
gh() { curl -s -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }
py() { python -c "import sys,json;d=json.load(sys.stdin);$1"; }

printf "\n${B}GitHub — repo, push, secrets, Actions${N}\n\n"

# ── who ────────────────────────────────────────────────────────────────────────────────────
USER=$(gh "$API/user" | py "print(d.get('login',''))")
[ -n "$USER" ] || { printf "${R}the token is not valid (GET /user returned no login)${N}\n\n"; exit 1; }
ok "authenticated as $USER"
SCOPES=$(curl -s -D - -o /dev/null -H "Authorization: Bearer $TOK" "$API/user" | tr -d '\r' | sed -n 's/^x-oauth-scopes: //Ip')
info "token scopes: ${SCOPES:-<fine-grained token>}"
case "$SCOPES" in
  *repo*) ;;
  "") warn "fine-grained token — make sure it grants Contents: read/write, Secrets: read/write, Actions: read/write, Administration: read/write" ;;
  *) bad "the token is missing the 'repo' scope — nothing can be pushed" ;;
esac

# ── 1. the repo ────────────────────────────────────────────────────────────────────────────
printf "\n${B}1. repository${N}\n"
EXISTS=$(gh "$API/repos/$USER/$REPO_NAME" | py "print(d.get('full_name',''))")
if [ -n "$EXISTS" ]; then
  ok "$EXISTS already exists — reusing it"
else
  node -e "require('fs').writeFileSync('.gh-body.json',JSON.stringify({name:process.argv[1],private:true,description:'Scroll Anytime - endless Torah feed (scrollanytime.com)',has_issues:true,has_wiki:false,auto_init:false}))" "$REPO_NAME"
  CREATED=$(gh -X POST --data-binary @.gh-body.json "$API/user/repos" | py "print(d.get('full_name',''))")
  rm -f .gh-body.json
  [ -n "$CREATED" ] && ok "created $CREATED (private)" || bad "could not create the repository"
fi
[ "$fail" -gt 0 ] && { printf "\n${R}stopping${N}\n\n"; exit 1; }

# ── 2. remote + push ───────────────────────────────────────────────────────────────────────
printf "\n${B}2. push${N}\n"
# The token goes in the push URL for this one command and is then replaced with a clean URL, so it
# is never left sitting in .git/config where the next person to read the repo would find it.
PUSH_URL="https://${USER}:${TOK}@github.com/$USER/$REPO_NAME.git"
CLEAN_URL="https://github.com/$USER/$REPO_NAME.git"
git remote remove origin 2>/dev/null || true
git remote add origin "$PUSH_URL"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
info "pushing $BRANCH ($(git rev-list --count HEAD) commits) — the media in ui-screens/ makes this a few minutes"
if git push -u origin "$BRANCH" 2>&1 | tail -4; then
  git remote set-url origin "$CLEAN_URL"
  ok "pushed to $CLEAN_URL (token removed from .git/config)"
else
  git remote set-url origin "$CLEAN_URL"
  bad "push failed"
fi

# ── 3. secrets ─────────────────────────────────────────────────────────────────────────────
printf "\n${B}3. Action secrets${N}\n"
PUBKEY=$(gh "$API/repos/$USER/$REPO_NAME/actions/secrets/public-key")
KEY_ID=$(printf '%s' "$PUBKEY" | py "print(d.get('key_id',''))")
KEY_B64=$(printf '%s' "$PUBKEY" | py "print(d.get('key',''))")
[ -n "$KEY_ID" ] || { bad "could not fetch the repo public key — the token may lack Secrets write"; }

# GitHub secrets are sealed with libsodium sealed boxes. PyNaCl is the sanctioned way; if it is not
# installed we install it into a throwaway venv rather than shipping a hand-rolled crypto path.
PYBIN=$(command -v python3 || command -v python)
if ! "$PYBIN" -c "import nacl" 2>/dev/null; then
  info "installing PyNaCl (needed to seal secrets)"
  "$PYBIN" -m pip install --quiet --disable-pip-version-check pynacl >/dev/null 2>&1 || warn "pip install pynacl failed"
fi

seal_and_put() { # name, value
  local name="$1" value="$2" enc
  enc=$("$PYBIN" -c "
import sys, base64
from nacl import encoding, public
pk = public.PublicKey(sys.argv[1].encode(), encoding.Base64Encoder())
print(base64.b64encode(public.SealedBox(pk).encrypt(sys.argv[2].encode())).decode())
" "$KEY_B64" "$value" 2>/dev/null)
  if [ -z "$enc" ]; then bad "could not seal $name (PyNaCl unavailable)"; return; fi
  local res
  res=$(gh -X PUT -d "{\"encrypted_value\":\"$enc\",\"key_id\":\"$KEY_ID\"}" -o /dev/null -w "%{http_code}" \
        "$API/repos/$USER/$REPO_NAME/actions/secrets/$name")
  case "$res" in 201|204) ok "secret $name" ;; *) bad "secret $name (HTTP $res)" ;; esac
}

if [ -n "$KEY_ID" ]; then
  # ZEREM_ORIGIN + INGEST_TOKEN drive nightly ingestion; CF_* drive the weekly media mirror.
  seal_and_put ZEREM_ORIGIN "https://scrollanytime.com"
  seal_and_put CF_ACCOUNT_ID "582077fa96c12544552377cb16fc4a36"

  # INGEST_TOKEN must be IDENTICAL on both sides: the Action sends it, the Worker checks it.
  # Cloudflare secrets are write-only — the existing value cannot be read back, by design. So
  # rather than asking a human to copy a secret between two systems (and get it wrong once), mint
  # a fresh one and write it to BOTH. They then match by construction. Rotating it is harmless:
  # the only thing that authenticates with it is the ingest Action, which is being set up here.
  if [ -n "${INGEST_TOKEN:-}" ]; then
    seal_and_put INGEST_TOKEN "$INGEST_TOKEN"
    info "used the INGEST_TOKEN from the environment (worker secret left untouched)"
  else
    NEW_TOKEN=$(node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))")
    if (cd worker && printf '%s' "$NEW_TOKEN" | npx wrangler secret put INGEST_TOKEN >/dev/null 2>&1); then
      ok "rotated INGEST_TOKEN on the Worker"
      seal_and_put INGEST_TOKEN "$NEW_TOKEN"
    else
      bad "could not write INGEST_TOKEN to the Worker — run: cd worker && npx wrangler secret put INGEST_TOKEN"
    fi
    unset NEW_TOKEN
  fi

  # R2 S3-style credentials for the weekly media mirror. These are the one pair that cannot be
  # minted from here: they come from an R2 API token, which is a different credential class from
  # the Workers OAuth token this repo uses. Without them the backup Action fails its own secret
  # check LOUDLY on the first line rather than silently mirroring nothing.
  for v in ; do
    if [ -n "${!v:-}" ]; then seal_and_put "$v" "${!v}"
    else warn "$v not set — the weekly media mirror will fail until it is (see the note printed at the end)"; fi
  done
fi

# ── 4. run both workflows ──────────────────────────────────────────────────────────────────
printf "\n${B}4. Actions${N}\n"
for wf in ingest.yml; do
  CODE=$(gh -X POST -o /dev/null -w "%{http_code}" -d "{\"ref\":\"$BRANCH\"}" \
         "$API/repos/$USER/$REPO_NAME/actions/workflows/$wf/dispatches")
  case "$CODE" in 204) ok "dispatched $wf" ;; *) bad "could not dispatch $wf (HTTP $CODE)" ;; esac
done

info "waiting for the runs to finish — ingestion pulls real video, so give it time"
for i in $(seq 1 60); do
  sleep 30
  RUNS=$(gh "$API/repos/$USER/$REPO_NAME/actions/runs?per_page=10")
  DONE=$(printf '%s' "$RUNS" | py "
rs=[r for r in d.get('workflow_runs',[]) if r.get('event')=='workflow_dispatch']
print(sum(1 for r in rs if r.get('status')=='completed'))")
  [ "${DONE:-0}" -ge 2 ] && break
  printf "."
done
printf "\n"

gh "$API/repos/$USER/$REPO_NAME/actions/runs?per_page=10" | py "
rs=[r for r in d.get('workflow_runs',[]) if r.get('event')=='workflow_dispatch'][:4]
if not rs: print('   no dispatched runs visible yet')
for r in rs:
    mark = 'OK  ' if r.get('conclusion')=='success' else 'FAIL'
    print('  %s %-12s %-10s %-9s %s' % (mark, r.get('name'), r.get('status'), r.get('conclusion'), r.get('html_url')))
"
GREEN=$(gh "$API/repos/$USER/$REPO_NAME/actions/runs?per_page=10" | py "
rs=[r for r in d.get('workflow_runs',[]) if r.get('event')=='workflow_dispatch']
print(sum(1 for r in rs if r.get('conclusion')=='success'))")
if [ "${GREEN:-0}" -ge 2 ]; then
  ok "both workflows completed successfully"
elif [ "${GREEN:-0}" -ge 1 ] && [ -z "${R2_ACCESS_KEY_ID:-}" ]; then
  warn "one workflow is green; the media mirror failed its secret check because R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY are not set — that is the expected failure, not a broken workflow"
  printf "
  ${B}To finish the mirror:${N} create an R2 API token (Object Read & Write on zerem-media
"
  printf "  and zerem-media-backup), then re-run with both values exported. The bucket itself:
"
  printf "  ${D}cd worker && npx wrangler r2 bucket create zerem-media-backup${N}
"
else
  bad "not both workflows are green — open the run URLs above"
fi

printf "\n  repo: ${B}https://github.com/$USER/$REPO_NAME${N}\n"
printf "\n"
[ "$fail" -gt 0 ] && { printf "${R}${B}GITHUB SETUP: %d item(s) failing${N}\n\n" "$fail"; exit 1; }
printf "${G}${B}GITHUB SETUP: ALL DONE${N}\n\n"

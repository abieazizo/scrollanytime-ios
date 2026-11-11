#!/usr/bin/env bash
#
#  ship/mac-run.sh — the ONE script.
#
#  Everything about this build was decided, configured and verified before the Mac was ever opened.
#  This script compiles, uploads and (when the hold is released) submits. It configures nothing,
#  takes no screenshots, and asks no questions.
#
#      ./ship/mac-run.sh
#
#  RESUMABLE. Each stage writes a marker into ship/.state/ when it completes, and a re-run skips
#  what is already done. If the machine sleeps, the build times out, or you close the lid halfway
#  through, run it again — it picks up where it stopped. Nothing here is destructive.
#
#      ./ship/mac-run.sh --restage 2     start again from stage 2
#      ./ship/mac-run.sh --status        show what is done and stop
#
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
STATE="$ROOT/ship/.state"
mkdir -p "$STATE"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'

banner() {
  printf "\n${C}${B}"
  printf '━%.0s' $(seq 1 72); printf "\n  STAGE %s — %s\n" "$1" "$2"
  printf '━%.0s' $(seq 1 72); printf "${N}\n\n"
}
ok()   { printf "  ${G}OK${N}   %s\n" "$1"; }
bad()  { printf "  ${R}FAIL${N} %s\n" "$1"; }
warn() { printf "  ${Y}warn${N} %s\n" "$1"; }
info() { printf "  ${D}%s${N}\n" "$1"; }
die()  { printf "\n${R}${B}STOPPED.${N} %s\n\n" "$1"; exit 1; }

done_marker() { [ -f "$STATE/stage$1.done" ]; }
mark_done()   { date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STATE/stage$1.done"; }

# ── flags ──────────────────────────────────────────────────────────────────────────────────
for a in "$@"; do
  case "$a" in
    --status)
      printf "\n${B}mac-run stages${N}\n"
      for i in 0 1 2 3 4; do
        if done_marker "$i"; then printf "  ${G}done${N}  stage %s   ${D}%s${N}\n" "$i" "$(cat "$STATE/stage$i.done")"
        else printf "  ${Y}todo${N}  stage %s\n" "$i"; fi
      done
      printf "\n"; exit 0 ;;
    --restage)
      shift 2>/dev/null || true ;;
  esac
done
if [ "${1:-}" = "--restage" ] && [ -n "${2:-}" ]; then
  for i in $(seq "$2" 4); do rm -f "$STATE/stage$i.done"; done
  info "cleared stage markers from $2 onward"
fi

printf "\n${B}Scroll Anytime — Mac run${N}\n"
info "resumable: re-run this after any interruption; finished stages are skipped"
info "ship/TROUBLESHOOT.md has the fix for anything that stops here"

# ═══════════════════════════════════════════════════════════════════════════════════════════
banner 0 "PREFLIGHT — is this Mac ready?"
# ═══════════════════════════════════════════════════════════════════════════════════════════
if done_marker 0; then
  ok "already passed (re-checking the cheap things anyway)"
fi

pf_fail=0
pf() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; pf_fail=$((pf_fail+1)); FIXES+=("$3"); fi; }
FIXES=()

[ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS (this is $(uname -s)). Everything else in the repo runs anywhere."

pf "macOS $(sw_vers -productVersion 2>/dev/null)" "true" ""
pf "Xcode installed" '[ -d "$(xcode-select -p 2>/dev/null)" ] && xcode-select -p 2>/dev/null | grep -q Xcode.app' \
   "Install Xcode from the App Store, open it once, then run:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
pf "command line tools" 'xcrun --find xcodebuild' \
   "xcode-select --install"
pf "Xcode licence accepted" 'xcodebuild -checkFirstLaunchStatus' \
   "sudo xcodebuild -license accept  &&  sudo xcodebuild -runFirstLaunch"
pf "a signing team is visible to Xcode" 'security find-identity -v -p codesigning | grep -q "Apple Development\|Apple Distribution"' \
   "Open Xcode → Settings → Accounts → + → Apple ID, sign in, and approve the prompt on your phone. See MAC-DAY.md step 2."
pf "git" 'command -v git' "xcode-select --install"
pf "node >= 20" '[ "$(node -v 2>/dev/null | sed "s/v\([0-9]*\).*/\1/")" -ge 20 ]' \
   "brew install node"

# fastlane: install it rather than complaining about it
if command -v fastlane >/dev/null 2>&1; then
  ok "fastlane $(fastlane --version 2>/dev/null | grep -o '[0-9.]*' | head -1)"
else
  warn "fastlane missing — installing it now (this can take a few minutes)"
  if command -v brew >/dev/null 2>&1; then
    brew install fastlane >/dev/null 2>&1 && ok "fastlane installed" || { bad "fastlane install failed"; pf_fail=$((pf_fail+1)); FIXES+=("brew install fastlane"); }
  else
    bad "neither fastlane nor Homebrew is present"; pf_fail=$((pf_fail+1))
    FIXES+=('Install Homebrew: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"  then: brew install fastlane')
  fi
fi

# disk
FREE_GB=$(df -g "$ROOT" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${FREE_GB:-}" ] && [ "$FREE_GB" -ge 20 ]; then ok "${FREE_GB}GB free"
else bad "only ${FREE_GB:-?}GB free — an archive needs about 20GB"; pf_fail=$((pf_fail+1)); FIXES+=("Free up disk space, then re-run."); fi

# The Apple sitting: three values and a file. Without them nothing can be uploaded.
MISSING_KEY=0
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
  if [ -z "${!v:-}" ]; then bad "$v is not set"; MISSING_KEY=1; else ok "$v set"; fi
done
if [ "$MISSING_KEY" -eq 0 ] && [ ! -r "${ASC_KEY_PATH:-}" ]; then
  bad "ASC_KEY_PATH points at a file that is not readable: $ASC_KEY_PATH"; MISSING_KEY=1
elif [ "$MISSING_KEY" -eq 0 ]; then
  head -1 "$ASC_KEY_PATH" | grep -q "BEGIN PRIVATE KEY" && ok "the .p8 key file looks right" || { bad "$ASC_KEY_PATH does not look like a .p8 private key"; MISSING_KEY=1; }
fi

if [ "$MISSING_KEY" -eq 1 ]; then
  printf "\n${Y}${B}THE APPLE SITTING HAS NOT BEEN DONE.${N}\n\n"
  printf "  Nothing can be uploaded without an App Store Connect API key. It takes about\n"
  printf "  ten minutes and you only ever do it once.\n\n"
  printf "  ${B}Open Claude Code in this folder and say:  \"run the Apple sitting\"${N}\n\n"
  printf "  It walks you through it and tells you exactly what to tap. The steps are also\n"
  printf "  written out in SETUP-APPLE.md if you would rather read them.\n\n"
  printf "  When it is finished you will have three values. Put them in your shell and\n"
  printf "  re-run this script:\n\n"
  printf "    export ASC_KEY_ID=XXXXXXXXXX\n"
  printf "    export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\n"
  printf "    export ASC_KEY_PATH=~/Documents/AuthKey_XXXXXXXXXX.p8\n\n"
  exit 1
fi

if [ "$pf_fail" -gt 0 ]; then
  printf "\n${R}${B}PREFLIGHT FAILED — %d thing(s) to fix:${N}\n\n" "$pf_fail"
  for f in "${FIXES[@]}"; do [ -n "$f" ] && printf "  • %s\n" "$f"; done
  printf "\n  Fix those, then run this script again. Everything before this point is skipped.\n\n"
  exit 1
fi
mark_done 0
printf "\n${G}${B}preflight clean${N}\n"

# ═══════════════════════════════════════════════════════════════════════════════════════════
banner 1 "CODE — is this the build that is live?"
# ═══════════════════════════════════════════════════════════════════════════════════════════
if done_marker 1; then ok "already done — skipping"; else

if git remote >/dev/null 2>&1 && [ -n "$(git remote)" ]; then
  info "pulling..."
  git pull --ff-only >/dev/null 2>&1 && ok "up to date with the remote" || warn "git pull did not fast-forward — building the commit that is checked out"
else
  warn "no git remote configured — building the commit that is checked out"
fi

HEAD_SHA="$(git rev-parse HEAD)"
ok "HEAD ${HEAD_SHA:0:12}"

# The shell is a wrapper around the LIVE site. Building it against a production origin running
# different code than this checkout would ship a binary whose behaviour nobody has verified.
LIVE_SHA="$(curl -fsS --max-time 20 https://scrollanytime.com/version 2>/dev/null | sed -n 's/.*"sha":"\([^"]*\)".*/\1/p')"
if [ -z "$LIVE_SHA" ]; then
  die "could not reach https://scrollanytime.com/version — check the connection and re-run."
fi
if [ "${LIVE_SHA:0:12}" != "${HEAD_SHA:0:12}" ]; then
  printf "\n"
  bad "production is running ${LIVE_SHA:0:12}, this checkout is ${HEAD_SHA:0:12}"
  printf "\n  The iOS app is a wrapper around the live site, so a mismatch means the binary you are\n"
  printf "  about to build has never been tested against the code it will actually load.\n\n"
  printf "  From the machine that deploys:  npm run deploy\n"
  printf "  Then run this script again.\n\n"
  exit 1
fi
ok "production /version matches HEAD — the site the app wraps is this code"

# the shell's own whitelist, re-checked on the machine that is about to compile it
bash ship/ios-lint.sh || die "the iOS shell failed its own lint. Fix the failures above; do not build."

mark_done 1
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════
banner 2 "BUILD — archive and export the IPA"
# ═══════════════════════════════════════════════════════════════════════════════════════════
ARCHIVE="$ROOT/ship/build/ScrollAnytime.xcarchive"
EXPORT_DIR="$ROOT/ship/build/export"
IPA="$EXPORT_DIR/Scroll Anytime.ipa"

if done_marker 2 && [ -f "$IPA" ]; then ok "already built — skipping ($(du -h "$IPA" | cut -f1))"; else
mkdir -p "$ROOT/ship/build"

TEAM_ID="${APPLE_TEAM_ID:-}"
if [ -z "$TEAM_ID" ]; then
  TEAM_ID="$(security find-identity -v -p codesigning | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' | head -1)"
fi
[ -n "$TEAM_ID" ] && ok "team $TEAM_ID" || warn "could not detect a team id — Xcode will pick one automatically"

cat > "$ROOT/ship/build/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
$( [ -n "$TEAM_ID" ] && printf '  <key>teamID</key><string>%s</string>\n' "$TEAM_ID" )
</dict>
</plist>
PLIST

info "archiving — this is the slow part, several minutes. You can walk away."
set -o pipefail
xcodebuild archive \
  -project "$ROOT/ship/ios/pwa-shell.xcodeproj" \
  -scheme pwa-shell \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
  CODE_SIGN_STYLE=Automatic \
  2>&1 | tee "$ROOT/ship/build/archive.log" | grep -E "error:|warning: .*(sign|provision)|BUILD |ARCHIVE " || true

if [ ! -d "$ARCHIVE" ]; then
  printf "\n"
  bad "the archive was not produced"
  if grep -qi "code sign\|provisioning\|no profiles\|team" "$ROOT/ship/build/archive.log" 2>/dev/null; then
    printf "\n${Y}${B}This is a signing problem, and it is a one-time fix:${N}\n\n"
    printf "  1. Open ${B}ship/ios/pwa-shell.xcodeproj${N} in Xcode\n"
    printf "  2. Click the ${B}pwa-shell${N} target in the left sidebar\n"
    printf "  3. Go to the ${B}Signing & Capabilities${N} tab\n"
    printf "  4. Tick ${B}Automatically manage signing${N}\n"
    printf "  5. Choose your name in the ${B}Team${N} dropdown\n"
    printf "  6. Close Xcode and run this script again — it resumes right here\n\n"
  else
    printf "\n  Full log: ship/build/archive.log\n"
    printf "  Common causes and fixes: ship/TROUBLESHOOT.md\n\n"
  fi
  exit 1
fi
ok "archive built"

info "exporting the App Store IPA..."
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/ship/build/ExportOptions.plist" \
  -allowProvisioningUpdates \
  2>&1 | tee "$ROOT/ship/build/export.log" | grep -E "error:|EXPORT " || true

IPA="$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -1)"
[ -n "$IPA" ] && [ -f "$IPA" ] || { bad "no IPA was exported — see ship/build/export.log"; exit 1; }
ok "IPA exported ($(du -h "$IPA" | cut -f1))"

# the built product's plist, not the source one — this is what Apple actually receives
BUILT_PLIST="$ARCHIVE/Products/Applications/$(basename "$IPA" .ipa).app/Info.plist"
[ -f "$BUILT_PLIST" ] || BUILT_PLIST="$(find "$ARCHIVE/Products/Applications" -name Info.plist -maxdepth 2 | head -1)"
if [ -n "$BUILT_PLIST" ] && [ -f "$BUILT_PLIST" ]; then
  node "$ROOT/ship/verify-plist.mjs" "$BUILT_PLIST" || die "the BUILT Info.plist failed the capability whitelist. Do not upload this binary."
  ok "built Info.plist passes the capability whitelist"
else
  warn "could not locate the built Info.plist to verify — check ship/build/archive.log"
fi

mark_done 2
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════
banner 3 "UPLOAD — the binary, then all the metadata"
# ═══════════════════════════════════════════════════════════════════════════════════════════
if done_marker 3; then ok "already uploaded — skipping"; else

IPA="$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -1)"
[ -f "$IPA" ] || die "no IPA found. Re-run with: ./ship/mac-run.sh --restage 2"

info "uploading the binary — several minutes, and it is silent for most of them"
xcrun altool --upload-app \
  --type ios \
  --file "$IPA" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" \
  2>&1 | tee "$ROOT/ship/build/upload.log" | tail -20

if grep -qi "error\|failed" "$ROOT/ship/build/upload.log" && ! grep -qi "No errors uploading" "$ROOT/ship/build/upload.log"; then
  bad "the upload reported an error — see ship/build/upload.log"
  printf "\n  ITMS error codes and their fixes: ship/TROUBLESHOOT.md\n\n"
  exit 1
fi
ok "binary uploaded — Apple takes 10-30 minutes to finish processing it"

info "regenerating metadata from store/*.md so it cannot be stale..."
node "$ROOT/ship/gen-metadata.mjs" || die "metadata generation failed — see the errors above"

info "pushing metadata, screenshots and review notes..."
export FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 SPACESHIP_SKIP_2FA_UPGRADE=1

# The API key file fastlane wants. Built HERE from the environment, never committed — it contains
# the private key, and a key in git is a key that has to be revoked.
python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" > "$ROOT/ship/.state/asc_key.json" <<'PYKEY'
import json, sys
kid, iss, path = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"key_id": kid, "issuer_id": iss, "key": open(path).read(), "in_house": False}, sys.stdout)
PYKEY
chmod 600 "$ROOT/ship/.state/asc_key.json"
ok "App Store Connect API key assembled (not committed)"
(cd "$ROOT/ship/fastlane" 2>/dev/null || cd "$ROOT/ship") && \
fastlane deliver \
  --api_key_path "$ROOT/ship/.state/asc_key.json" \
  --app_identifier com.scrollanytime.app \
  --skip_binary_upload true \
  --skip_app_version_update false \
  --force true \
  --overwrite_screenshots true \
  --screenshots_path "$ROOT/store/screenshots" \
  --metadata_path "$ROOT/ship/metadata" \
  2>&1 | tee "$ROOT/ship/build/deliver.log" | tail -25 || warn "deliver reported problems — see ship/build/deliver.log"

printf "\n${Y}${B}THINGS THE API CANNOT SET — do these by hand, once, in App Store Connect:${N}\n\n"
printf "  1. ${B}App Privacy${N} → Get Started → answer from store/PRIVACY_NUTRITION.md:\n"
printf "       Email address  → collected, LINKED to the user, App Functionality, NOT used for tracking\n"
printf "       Name           → collected, linked, App Functionality  (only if Apple/Google sign-in is live)\n"
printf "       Usage Data     → collected, NOT linked, App Functionality, NOT used for tracking\n"
printf "       Everything else→ Not Collected\n"
printf "       \"Do you use data for tracking?\" → ${B}No${N}\n"
printf "  2. ${B}Age Rating${N} → answer No to every question → 4+\n"
printf "  3. ${B}Content Rights${N} → \"Does your app contain third-party content?\" → Yes, and confirm\n"
printf "       you have the rights (see the licensed-content paragraph in store/APP_REVIEW_NOTES.md)\n"
printf "  4. ${B}Pricing${N} → Free, all territories\n"
printf "  5. ${B}Version Release${N} → \"Manually release this version\"\n\n"

mark_done 3
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════
banner 4 "THE HOLD — has the phone test been done?"
# ═══════════════════════════════════════════════════════════════════════════════════════════
if done_marker 4; then
  ok "already submitted"
  grep -n "Waiting for Review" "$ROOT/SHIP.md" | tail -1
  exit 0
fi

# The marker must be its own LINE, at the start of a line, and not inside a table cell or a
# sentence about the marker. Writing the gate up in SHIP.md put the literal phrase into SHIP.md and
# opened the gate — caught before any Mac ever ran this. A line-anchored match with nothing before
# it cannot be satisfied by prose that merely mentions it.
if ! grep -Eq '^OWNER-DEVICE-TEST: COMPLETE, TRIAGED[[:space:]]*$' "$ROOT/SHIP.md"; then
  printf "${Y}${B}STOPPING HERE. This is the one deliberate gate.${N}\n\n"
  printf "  The build is uploaded and the whole listing is in place. Nothing is submitted yet,\n"
  printf "  and nothing will be until you have used the app on your own phone.\n\n"
  printf "  ${B}Run your phone test${N} — OWNER-DEVICE-TEST.md, about 30 minutes on scrollanytime.com\n"
  printf "  ${B}Paste your notes into Claude Code.${N} Every note becomes a fix.\n"
  printf "  ${B}Then re-run me.${N}  ./ship/mac-run.sh\n\n"
  printf "  ${D}(The gate is one line in SHIP.md: \"OWNER-DEVICE-TEST: COMPLETE, TRIAGED\".${N}\n"
  printf "  ${D} It is added once your notes are triaged to zero open items — not before.)${N}\n\n"
  exit 0
fi

ok "OWNER-DEVICE-TEST is complete and triaged — releasing the hold"
info "submitting for review..."

fastlane deliver submit_for_review \
  --api_key_path "$ROOT/ship/.state/asc_key.json" \
  --app_identifier com.scrollanytime.app \
  --skip_binary_upload true --skip_screenshots true --skip_metadata true \
  --submission_information '{"add_id_info_uses_idfa": false, "export_compliance_uses_encryption": false, "content_rights_contains_third_party_content": true, "content_rights_has_rights": true}' \
  2>&1 | tee "$ROOT/ship/build/submit.log" | tail -20

info "waiting for App Store Connect to report the status (this can take a few minutes)..."
STATUS=""
for i in $(seq 1 40); do
  STATUS="$(fastlane run app_store_build_number app_identifier:com.scrollanytime.app 2>/dev/null | grep -io "waiting for review\|in review\|pending developer release" | head -1)"
  [ -n "$STATUS" ] && break
  sleep 30
done

ASC_URL="https://appstoreconnect.apple.com/apps"
{
  printf "\n## SUBMITTED — %s\n\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf -- "- commit: %s\n" "$(git rev-parse HEAD)"
  printf -- "- status: %s\n" "${STATUS:-submitted (status not yet reported)}"
  printf -- "- App Store Connect: %s\n" "$ASC_URL"
  printf -- "- build: 1.0.0 (1)\n"
} >> "$ROOT/SHIP.md"

mark_done 4
printf "\n${G}${B}SUBMITTED.${N}\n\n"
printf "  status: ${B}%s${N}\n" "${STATUS:-submitted — status not yet reported by Apple}"
printf "  %s\n\n" "$ASC_URL"
printf "  Apple usually replies in 1-3 days. Approval → tap Release. Rejection → paste the\n"
printf "  guideline number into Claude Code; store/RESOLUTION_CENTER_REPLIES.md answers it.\n\n"

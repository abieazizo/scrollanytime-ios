#!/usr/bin/env bash
# THE "STILL SIGNED IN" GATE FOR THE SHELL (the owner's P0, 2026-10-22: "people are signed out every day … a
# wrapper test on the simulator … a release cannot pass if 'still signed in tomorrow' fails"). The XCUITest
# ship/ios/pwa-shellUITests/SaveToPhotosUITests.swift SessionPersistUITests drives the REAL shell on the iOS
# Simulator against the live site: the page holds a session the Keychain keeps; the app is relaunched with its
# whole web data store wiped (storage and cookies) and must come back as the same person, from the Keychain.
#
# Run by the Fastfile's `signing` lane after the Save to Photos gate (it reuses that build when it is there),
# so a failure stops the release before a certificate, an archive or an upload.
#
#   UDID=<booted simulator> bash ship/ios/uitest-session.sh      (no UDID: boots an iPhone itself)
# Exit 0 only when the test passes. Results: $OUT (session.xcresult, session.log, session-summary.json).
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="${OUT:-ship/build/uitest}"
mkdir -p "$OUT"
APP_ID=com.scrollanytime.app
DD="$OUT/dd"

if [ -z "${UDID:-}" ]; then
  UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
want = '${UITEST_DEVICE:-iPhone 16 Pro}'
d = json.load(sys.stdin)['devices']
cand = [x for k, v in d.items() if 'iOS' in k for x in v]
exact = [x for x in cand if x['name'] == want]
pick = exact or sorted([x for x in cand if x['name'].startswith('iPhone 1')], key=lambda x: x['name'])
print(pick[-1]['udid'] if pick else '')")
  [ -n "$UDID" ] || { echo "::error::no iPhone simulator available"; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
fi
echo "── still-signed-in gate on $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"

# the Save to Photos gate's build when this job already made it; else the same build, for the Simulator
XCTESTRUN="$(ls "$DD"/Build/Products/*.xctestrun 2>/dev/null | head -1)"
if [ -z "$XCTESTRUN" ]; then
  set -o pipefail
  if ! xcodebuild build-for-testing \
      -project ship/ios/pwa-shell.xcodeproj -scheme pwa-shell -configuration Release \
      -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath "$DD" \
      CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
      DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" > "$OUT/session-build.log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$OUT/session-build.log" | head -40
    tail -20 "$OUT/session-build.log"
    echo "::error::the app or its XCUITest does not build"
    exit 1
  fi
  XCTESTRUN="$(ls "$DD"/Build/Products/*.xctestrun | head -1)"
fi
APP="$(find "$DD/Build/Products" -maxdepth 2 -name '*.app' ! -name '*Runner.app' | head -1)"
RUNNER="$(find "$DD/Build/Products" -maxdepth 2 -name '*Runner.app' | head -1)"
xcrun simctl install "$UDID" "$APP"
xcrun simctl install "$UDID" "$RUNNER"
xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
# a fresh Simulator's first network request can stall: warm the route the app takes
curl -fsS --max-time 20 -o /dev/null "https://scrollanytime.com/version" || true

started=$(date +%s)
xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
  -only-testing:"pwa-shellUITests/SessionPersistUITests/testSessionSurvivesAWipedWebStore" \
  -resultBundlePath "$OUT/session.xcresult" > "$OUT/session.log" 2>&1
code=$?
grep -E "SA-UITEST|error: |Test Case .* (passed|failed)|XCTAssert|Executed" "$OUT/session.log" | sed 's/^/   /' | head -40
xcrun simctl io "$UDID" screenshot "$OUT/session-end.png" >/dev/null 2>&1 || true
# the shell's own account: what it saved, and the wipe (UITestHooks logs through SA-PHOTOS)
xcrun simctl spawn "$UDID" log show --last "$(( $(date +%s) - started + 30 ))s" --style compact \
  --predicate 'eventMessage CONTAINS "SA-PHOTOS"' 2>/dev/null | grep -E "session|wiped" | sed 's/^/   app: /' | tail -12 || true
verdict=FAIL
if [ "$code" -eq 0 ] && grep -q "Test Case .* passed" "$OUT/session.log"; then verdict=PASS; fi
python3 - "$OUT/session-summary.json" "$verdict" <<'PY'
import json, sys, datetime
json.dump({'at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'still-signed-in-after-a-wiped-web-store': sys.argv[2]}, open(sys.argv[1], 'w'), indent=1)
PY
echo "── still-signed-in gate: $verdict ($(( $(date +%s) - started )) s)"
[ "$verdict" = PASS ] || exit 1

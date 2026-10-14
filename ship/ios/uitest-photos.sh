#!/usr/bin/env bash
# THE SAVE-TO-PHOTOS GATE (the owner's spec of 2026-10-14, Part 4: "the test must pass before anything is
# uploaded"). The XCUITest ship/ios/pwa-shellUITests/SaveToPhotosUITests.swift drives the REAL shell on the
# iOS Simulator against the live site — More → "Save to Photos" on a feed clip — and reads the photo library
# afterwards. Three paths, each with the app's Photos permission set first:
#
#   first-time   never asked (simctl privacy reset)  → iOS asks, the test allows → one new video, the file's length
#   granted      granted (simctl privacy grant)      → no prompt → one new video, the file's length
#   denied       denied (simctl privacy revoke)      → no prompt, no video → the Settings sheet → Settings opens
#
# Run by the Fastfile's `signing` lane — the first lane release-ios.yml runs, so a failure stops the run
# before a certificate is minted, an archive made or anything uploaded — and by ship/demo/drive.sh under
# the marker ship/demo/walk-photos (a mirror branch: nothing signed, nothing uploaded).
#
#   UDID=<booted simulator> bash ship/ios/uitest-photos.sh      (no UDID: boots an iPhone itself)
# Exit 0 only when all three paths pass. Results: $OUT (summary.json, one .xcresult and log per path).
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="${OUT:-ship/build/uitest}"
mkdir -p "$OUT"
APP_ID=com.scrollanytime.app
RUNNER_ID=com.scrollanytime.app.uitests.xctrunner
DD="$OUT/dd"

# ── the simulator ─────────────────────────────────────────────────────────────────────────────
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
echo "── Save to Photos gate on $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"

# ── build the app and the test, for the Simulator ─────────────────────────────────────────────
# Release, as shipped; ad-hoc signed ("-"): a Simulator needs no certificate, and an unsigned bundle has
# no resource seal for SpringBoard (demo-video.yml, run #5)
set -o pipefail
if ! xcodebuild build-for-testing \
    -project ship/ios/pwa-shell.xcodeproj -scheme pwa-shell -configuration Release \
    -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath "$DD" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" > "$OUT/build.log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$OUT/build.log" | head -40
  tail -20 "$OUT/build.log"
  echo "::error::the app or its XCUITest does not build"
  exit 1
fi
grep -E "warning: .*(SaveToPhotos|UITests)" "$OUT/build.log" | sort -u | head -20 || true
XCTESTRUN="$(ls "$DD"/Build/Products/*.xctestrun | head -1)"
APP="$(find "$DD/Build/Products" -maxdepth 2 -name '*.app' ! -name '*Runner.app' | head -1)"
RUNNER="$(find "$DD/Build/Products" -maxdepth 2 -name '*Runner.app' | head -1)"
echo "   built: $(basename "$APP"), $(basename "$RUNNER"), $(basename "$XCTESTRUN")"
# installed up front, so the permissions below have an app to belong to
xcrun simctl install "$UDID" "$APP"
xcrun simctl install "$UDID" "$RUNNER"
# the test reads the library to prove the video arrived: the runner may read Photos, the app only adds
xcrun simctl privacy "$UDID" grant photos "$RUNNER_ID" || echo "::warning::could not grant the runner Photos access"

# a fresh Simulator's first network request can stall: warm the route the app takes
curl -fsS --max-time 20 -o /dev/null "https://scrollanytime.com/version" || true

# macOS's /bin/bash is 3.2: no associative arrays — one variable a path
R_FIRST=FAIL; R_GRANTED=FAIL; R_DENIED=FAIL
run_path() { # name, permission, test method
  local name="$1" permission="$2" method="$3"
  xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
  case "$permission" in
    reset)
      xcrun simctl privacy "$UDID" reset photos-add "$APP_ID" || true
      xcrun simctl privacy "$UDID" reset photos "$APP_ID" || true ;;
    grant)
      xcrun simctl privacy "$UDID" grant photos-add "$APP_ID" ;;
    revoke)
      xcrun simctl privacy "$UDID" revoke photos-add "$APP_ID" || true
      xcrun simctl privacy "$UDID" revoke photos "$APP_ID" || true ;;
  esac
  echo "── $name ($permission) → $method"
  local started; started=$(date +%s)
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
    -only-testing:"pwa-shellUITests/SaveToPhotosUITests/$method" \
    -resultBundlePath "$OUT/$name.xcresult" > "$OUT/$name.log" 2>&1
  local code=$?
  # (never touch a running app's privacy: iOS kills an app whose permission changes — run 38620120841 ran
  # zero tests while a loop re-granted the runner. xcodebuild's reinstall forgets the grant made above, so
  # the test reads the library from the Simulator's data folder when PhotoKit says "not determined")
  grep -E "SA-UITEST|error: |Test Case .* (passed|failed)|XCTAssert|Executed" "$OUT/$name.log" | sed 's/^/   /' | head -40
  xcrun simctl io "$UDID" screenshot "$OUT/$name-end.png" >/dev/null 2>&1 || true
  # the test's own screenshots (XCTAttachment), named by what they show
  if xcrun xcresulttool export attachments --path "$OUT/$name.xcresult" --output-path "$OUT/att-$name" >/dev/null 2>&1; then
    python3 - "$OUT/att-$name" "$OUT" "$name" <<'PY' || true
import json, os, shutil, sys
src, out, name = sys.argv[1:4]
try:
    manifest = json.load(open(os.path.join(src, 'manifest.json')))
except Exception:
    manifest = []
for test in manifest:
    for a in test.get('attachments', []):
        f = a.get('exportedFileName')
        label = (a.get('suggestedHumanReadableName') or f or 'shot').split('_0_')[0].replace(' ', '-')
        if f and os.path.exists(os.path.join(src, f)):
            shutil.copy(os.path.join(src, f), os.path.join(out, f'{name}-{label}.png'))
PY
  fi
  # the shell's own account of the save (SaveToPhotos.swift logs SA-PHOTOS)
  xcrun simctl spawn "$UDID" log show --last "$(( $(date +%s) - started + 30 ))s" --style compact \
    --predicate 'eventMessage CONTAINS "SA-PHOTOS"' 2>/dev/null | grep "SA-PHOTOS" | grep -v "log run noninteractively" | sed 's/^/   app: /' | tail -12 || true
  local verdict=FAIL
  if [ "$code" -eq 0 ] && grep -q "Test Case .* passed" "$OUT/$name.log"; then verdict=PASS; fi
  case "$name" in first-time) R_FIRST=$verdict ;; granted) R_GRANTED=$verdict ;; denied) R_DENIED=$verdict ;; esac
  echo "   $name: $verdict ($(( $(date +%s) - started )) s)"
}

run_path first-time reset testFirstTimePermission
run_path granted grant testAlreadyGranted
run_path denied revoke testDenied

python3 - "$OUT/summary.json" "$R_FIRST" "$R_GRANTED" "$R_DENIED" <<'PY'
import json, sys, datetime
out, a, b, c = sys.argv[1:5]
json.dump({'at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'first-time': a, 'granted': b, 'denied': c}, open(out, 'w'), indent=1)
PY
echo "── Save to Photos gate: first-time $R_FIRST · granted $R_GRANTED · denied $R_DENIED"
[ "$R_FIRST" = PASS ] && [ "$R_GRANTED" = PASS ] && [ "$R_DENIED" = PASS ] || exit 1

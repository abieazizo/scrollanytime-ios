# THE SIGN-IN WALK (2026-10-10) — sourced by drive.sh when the marker ship/demo/walk-signin exists.
#
# What "Continue with Google" and "Sign in with Apple" actually do in the REAL shell binary on iOS
# (the Simulator: no physical device is attached to this pipeline). Run once per build:
#   signin_walk now      the shell in this tree — Google in the system sign-in sheet (gauth)
#   signin_walk before   ship/ios-before, when present — the 1.0.2 shell: Google INSIDE the app's
#                        web view, the build the owner's report is about
# Nothing here signs in. The walk stops at Google's first page, reads what it says (Vision OCR on
# the screenshot — that page lives in another process the accessibility dump does not reach),
# backs out the way a person would, and checks the app answers again: the buttons are there and
# no spinner is left behind. Every step is a screenshot under shots/ and its words under ocr/ (and
# ax/ocr-*.json, which the workflow uploads); the summary lines go to signin-<label>.txt.
#
# The web page's buttons are found by their WORDS on the screenshot (ocr.swift --find): idb's
# accessibility dump does not reach into the web view (run 38106224254, 2026-10-11: "Continue
# with Google" was on screen and named nowhere in the dump).
#
# Uses drive.sh's helpers: shot, axdump, swipe, lum, W, H, MID_X, MID_Y, UDID, OUT.

mkdir -p "$OUT/ocr" "$OUT/ax"
# compiled once: `swift file.swift` recompiles on every call, and run 38107613573 spent its whole
# budget doing that thirty times
OCR="$OUT/ocr-bin"
swiftc -O ship/demo/ocr.swift -o "$OCR" 2>>"$OUT/ocr/errors.log" || OCR=""
ocrrun() { if [ -n "$OCR" ]; then "$OCR" "$@"; else swift ship/demo/ocr.swift "$@"; fi; }
# the words, as text and as JSON beside the accessibility dumps (the workflow uploads ax/*.json)
ocr() {
  ocrrun "$OUT/shots/$1.png" > "$OUT/ocr/$1.txt" 2>>"$OUT/ocr/errors.log" || true
  python3 -c "import json,sys; print(json.dumps({'shot': sys.argv[2], 'lines': open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()}))" \
    "$OUT/ocr/$1.txt" "$1" > "$OUT/ax/ocr-$1.json" 2>/dev/null || true
}

# tap_text "<words>" [--exact] : find the words on a fresh screenshot and tap their centre
tap_text() {
  local want="$1" mode="${2:-}" i at
  for i in 1 2 3 4 5 6; do
    xcrun simctl io "$UDID" screenshot "$OUT/.find.png" >/dev/null 2>&1 || true
    if at=$(ocrrun "$OUT/.find.png" --find "$want" $mode 2>>"$OUT/ocr/errors.log"); then
      read -r fx fy <<<"$at"
      local x y
      x=$(python3 -c "print(int($fx * $W))"); y=$(python3 -c "print(int($fy * $H))")
      echo "  tap_text '$want' -> $x $y (of ${W}x${H})"
      idb ui tap --udid "$UDID" "$x" "$y"
      return 0
    fi
    sleep 1.5
  done
  echo "  tap_text '$want' NOT FOUND on screen after 6 tries"
  return 1
}

# say which of the phrases that matter are on the screen
read_screen() {
  local name="$1" label="$2"
  ocr "$name"
  python3 - "$OUT/ocr/$name.txt" "$label" "$name" <<'PY' | tee -a "$OUT/signin-$2.txt"
import sys
path, label, name = sys.argv[1:4]
text = open(path, encoding='utf-8', errors='replace').read()
low = text.lower()
phrases = {
  "google's sign-in page": ('sign in' in low and ('google' in low or 'email or phone' in low)) or 'choose an account' in low,
  'to continue to scroll anytime': 'continue to' in low and 'scroll' in low,
  'DISALLOWED_USERAGENT / 403': 'disallowed_useragent' in low or 'error 403' in low,
  'access blocked': 'access blocked' in low,
  'browser or app may not be secure': 'may not be secure' in low,
  'system consent alert (wants to use … to sign in)': 'wants to use' in low,
  'onboarding hero (endless torah)': 'endless torah' in low,
  'continue with google button': 'continue with google' in low,
  'sign in with apple button': 'sign in with apple' in low,
  'apple account prompt': 'apple account' in low or 'apple id' in low,
  'no connection / offline page': 'connection' in low and ('needs' in low or 'offline' in low or 'retry' in low),
}
hits = [k for k, v in phrases.items() if v]
first = ' / '.join(l.strip() for l in text.splitlines() if l.strip())[:260]
print(f'[{label}] {name}: {", ".join(hits) or "none of the known phrases"}')
print(f'[{label}] {name} text: {first}')
PY
}
relaunch() {
  xcrun simctl terminate "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl launch "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  sleep 14
}
say() { echo "[$1] $2" | tee -a "$OUT/signin-$1.txt"; }

signin_walk() {
  local L="$1"
  echo "── sign-in walk: $L ──" | tee -a "$OUT/signin-$L.txt"
  sleep 3
  shot "$L-10-welcome"; read_screen "$L-10-welcome" "$L"

  # ── Google ──
  if ! tap_text "continue with google"; then
    say "$L" "the welcome card shows no Continue with Google (see $L-10-welcome)"
  else
    sleep 3
    shot "$L-11-after-google-tap"; read_screen "$L-11-after-google-tap" "$L"
    # the native sheet first asks "“Scroll Anytime” Wants to Use “google.com” to Sign In"
    if grep -qi "wants to use" "$OUT/ocr/$L-11-after-google-tap.txt" 2>/dev/null; then
      if tap_text "continue" --exact; then say "$L" "the system consent alert answered: Continue"; fi
    fi
    sleep 10
    shot "$L-12-google-page"; read_screen "$L-12-google-page" "$L"
    say "$L" "screen luminance on Google's page: $(lum "$OUT/shots/$L-12-google-page.png") (Google's page is white, > 150)"
    sleep 8
    shot "$L-12b-google-page-later"; read_screen "$L-12b-google-page-later" "$L"

    # ── back out the way a person would ──
    if [ "$L" = "now" ]; then
      # iOS 26's sheet closes with an X at its top-left, not a "Cancel" (run 38107613573)
      if ! tap_text "cancel" --exact; then
        say "$L" "the sheet has no Cancel word: its X (top-left) is tapped"
        idb ui tap --udid "$UDID" "$(python3 -c "print(int(0.097 * $W))")" "$(python3 -c "print(int(0.1125 * $H))")"
      fi
    else
      # 1.0.2: Google is a page in the app's own web view; the person's way back is the edge swipe
      swipe 2 "$MID_Y" $((W * 4 / 5)) "$MID_Y" 0.25 1.0
    fi
    sleep 1.2; shot "$L-13a-backing-out-1s"
    sleep 3;   shot "$L-13-after-back"; read_screen "$L-13-after-back" "$L"
    sleep 6;   shot "$L-13c-after-back-10s"; read_screen "$L-13c-after-back-10s" "$L"
    # no spinner left behind: the Google button answers again
    if tap_text "continue with google"; then
      sleep 4; shot "$L-14-google-again"; read_screen "$L-14-google-again" "$L"
      if [ "$L" = "now" ]; then
        # the consent alert again (its Cancel is a word), or the sheet (its X)
        if grep -qi "wants to use" "$OUT/ocr/$L-14-google-again.txt" 2>/dev/null; then tap_text "cancel" --exact || true
        else idb ui tap --udid "$UDID" "$(python3 -c "print(int(0.097 * $W))")" "$(python3 -c "print(int(0.1125 * $H))")"; fi
        sleep 4
      else
        swipe 2 "$MID_Y" $((W * 4 / 5)) "$MID_Y" 0.25 1.0; sleep 5
      fi
      shot "$L-15-after-second-back"; read_screen "$L-15-after-second-back" "$L"
    else
      say "$L" "after backing out, Continue with Google is NOT on screen (see $L-13-after-back)"
    fi
  fi

  # ── Apple ── (the system sheet; the Simulator has no Apple Account, so it asks for one — dismiss it)
  relaunch
  shot "$L-20-welcome-again"; read_screen "$L-20-welcome-again" "$L"
  if tap_text "sign in with apple"; then
    sleep 5
    shot "$L-21-apple-sheet"; read_screen "$L-21-apple-sheet" "$L"
    tap_text "cancel" --exact || tap_text "close" --exact || tap_text "not now" --exact || tap_text "ok" --exact || say "$L" "nothing to dismiss the Apple sheet with"
    sleep 4
    shot "$L-22-after-apple"; read_screen "$L-22-after-apple" "$L"
  else
    say "$L" "the welcome card shows no Sign in with Apple"
  fi
}

# build ship/ios-before (when the tree carries it) with the newest installed Xcode that still
# compiles it — run 38106224254's default, Xcode 26.6, refuses the 1.0.2 sources — and put it in
# place of the app
install_before() {
  [ -d ship/ios-before ] || return 1
  echo "── building the before shell (ship/ios-before) ──"
  local xc app built="" tries=0
  for xc in $(ls -d /Applications/Xcode*.app 2>/dev/null | sort -rV); do
    tries=$((tries + 1)); [ "$tries" -gt 3 ] && break
    echo "  trying $xc"
    if DEVELOPER_DIR="$xc/Contents/Developer" xcodebuild build \
      -project ship/ios-before/pwa-shell.xcodeproj -scheme pwa-shell -configuration Release \
      -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath "ship/build/sim-before" \
      CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
      DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" > "$OUT/before-build.log" 2>&1; then
      built="$xc"; echo "  built with $xc"; break
    fi
    echo "  failed with $xc:"; grep -E "error:" "$OUT/before-build.log" | sed 's/^/    /' | sort -u | head -8
    rm -rf ship/build/sim-before
  done
  [ -n "$built" ] || return 1
  app="$(find ship/build/sim-before/Build/Products -maxdepth 2 -name '*.app' | head -1)"
  [ -n "$app" ] || return 1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist" 2>/dev/null | sed 's/^/  before shell version: /'
  xcrun simctl terminate "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$app"
  xcrun simctl launch "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  sleep 16
}

# THE REPORT BRIDGE'S SELF-TEST (2026-10-10): launched with -saSelfTest, the shell reads its own
# __saShell fields, asks `snap` for a picture through the page, keeps the JPEG in its tmp folder and
# logs "SA-SELFTEST …" (NotifyBridge.swift ReportBridge.runSelfTest); then a shake, which the shell
# emits and the page hears. The walk pulls the picture and the lines.
selftest_walk() {
  echo "── report bridge self-test ──" | tee -a "$OUT/signin-selftest.txt"
  xcrun simctl terminate "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl launch "$UDID" com.scrollanytime.app -saSelfTest >/dev/null 2>&1 || true
  sleep 26
  shot "selftest-10-launched"
  # the Simulator's own shake (Device → Shake) is this Darwin notification
  xcrun simctl notify_post "$UDID" com.apple.UIKit.SimulatorShake || true
  sleep 4
  shot "selftest-11-after-shake"
  local c
  c=$(xcrun simctl get_app_container "$UDID" com.scrollanytime.app data 2>/dev/null || true)
  if [ -n "$c" ] && [ -f "$c/tmp/sa-selftest-snap.jpg" ]; then
    sips -s format png "$c/tmp/sa-selftest-snap.jpg" --out "$OUT/shots/selftest-12-the-snapshot-the-shell-took.png" >/dev/null 2>&1 || true
    echo "[selftest] the snapshot: $(sips -g pixelWidth -g pixelHeight "$c/tmp/sa-selftest-snap.jpg" 2>/dev/null | tail -2 | tr -s ' ' | tr '\n' ' ')" | tee -a "$OUT/signin-selftest.txt"
  else
    echo "[selftest] no snapshot file in the app's tmp folder" | tee -a "$OUT/signin-selftest.txt"
  fi
  xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'eventMessage CONTAINS "SA-SELFTEST"' 2>/dev/null     | grep "SA-SELFTEST" | sed 's/^.*SA-SELFTEST/[selftest] SA-SELFTEST/' | tee -a "$OUT/signin-selftest.txt"
  python3 -c "import json,sys; print(json.dumps({'lines': open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()}))" "$OUT/signin-selftest.txt" > "$OUT/ax/selftest.json" 2>/dev/null || true
}


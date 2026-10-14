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

# SHORT RECORDINGS OF THE MOMENTS THAT MATTER (calibrate mode only — the workflow's own recording is
# off then): run 38110569242's full-length recording was 3.2 GB, too big to take home. Each segment
# is recorded here, shrunk on the runner (390 wide, 15 fps) and kept under crash/, which the
# workflow uploads whatever it holds.
SEG_PID=""
seg_start() {
  [ "${MODE:-}" = "calibrate" ] || return 0
  mkdir -p "$OUT/crash"
  xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT/.seg-$1.mov" >/dev/null 2>&1 &
  SEG_PID=$!
  sleep 3
}
seg_stop() {
  [ -n "$SEG_PID" ] || return 0
  sleep 1
  kill -INT "$SEG_PID" 2>/dev/null || true
  wait "$SEG_PID" 2>/dev/null || true
  SEG_PID=""
  # the runner has ffprobe but no ffmpeg (run 38113306596); macOS's own avconvert re-encodes to H.264
  if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -v error -y -i "$OUT/.seg-$1.mov" -vf "scale=390:-2,fps=15" -c:v libx264 -crf 30 -preset veryfast -pix_fmt yuv420p -an "$OUT/crash/recording-$1.mp4"; then
    :
  elif avconvert --preset PresetMediumQuality --source "$OUT/.seg-$1.mov" --output "$OUT/crash/recording-$1.mp4" --replace >/dev/null 2>&1; then
    :
  else
    # nothing to shrink it with: keep it as it was recorded
    mv "$OUT/.seg-$1.mov" "$OUT/crash/recording-$1.mov"
  fi
  for f in "$OUT/crash/recording-$1".*; do [ -f "$f" ] && echo "  recording kept: crash/$(basename "$f") ($(du -h "$f" | cut -f1))"; done
  rm -f "$OUT/.seg-$1.mov"
}

signin_walk() {
  local L="$1"
  echo "── sign-in walk: $L ──" | tee -a "$OUT/signin-$L.txt"
  sleep 3
  shot "$L-10-welcome"; read_screen "$L-10-welcome" "$L"

  # ── Google ──
  seg_start "$L-google"
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

  seg_stop "$L-google"
  # ── Apple ── (the system sheet; the Simulator has no Apple Account, so it asks for one — dismiss it)
  relaunch
  seg_start "$L-apple"
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
  seg_stop "$L-apple"
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
  seg_start "selftest-shake"
  shot "selftest-10-launched"
  # the Simulator's own shake (Device → Shake) is this Darwin notification
  xcrun simctl notify_post "$UDID" com.apple.UIKit.SimulatorShake || true
  sleep 4
  shot "selftest-11-after-shake"
  seg_stop "selftest-shake"
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


# THE DEVICE AND STATE MATRIX (the owner's spec of 2026-10-10, Part 2.3), as far as the Simulator
# goes: cold, warm and resumed launches; Dynamic Type at the largest accessibility size; Reduce
# Motion; the light appearance; and every other iOS runtime the runner carries. The Simulator has no
# Low Power Mode and no VoiceOver — the matrix says so rather than pretending. Each state: the app
# relaunched under it, screenshots, and the screen's words (OCR) in signin-matrix.txt.
matrix_shot() {
  local name="$1"
  shot "$name"
  ocr "$name"
  python3 - "$OUT/ocr/$name.txt" "$name" <<'PY' | tee -a "$OUT/signin-matrix.txt"
import sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
low = text.lower()
seen = [k for k, v in {
  'welcome card': 'endless torah' in low,
  'Sign in with Apple': 'sign in with apple' in low,
  'Continue with Google': 'continue with google' in low,
  'Continue with email': 'continue with email' in low,
  'offline page': 'connection' in low and ('needs' in low or 'retry' in low),
}.items() if v]
print(f"[matrix] {sys.argv[2]}: {', '.join(seen) or 'none of the welcome card'} | " + ' / '.join(l.strip() for l in text.splitlines() if l.strip())[:160])
PY
}
relaunch_quiet() {
  xcrun simctl terminate "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl launch "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
}

matrix_walk() {
  echo "── device and state matrix ──" | tee -a "$OUT/signin-matrix.txt"
  # cold: from nothing, three moments of the launch
  relaunch_quiet
  sleep 2; matrix_shot "matrix-01-cold-2s"
  sleep 4; matrix_shot "matrix-02-cold-6s"
  sleep 8; matrix_shot "matrix-03-cold-14s"
  # warm: to the Home Screen and straight back
  idb ui button --udid "$UDID" HOME || true
  sleep 5
  xcrun simctl launch "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  sleep 3; matrix_shot "matrix-04-warm"
  # resumed: a minute in the background
  idb ui button --udid "$UDID" HOME || true
  sleep 60
  xcrun simctl launch "$UDID" com.scrollanytime.app >/dev/null 2>&1 || true
  sleep 4; matrix_shot "matrix-05-resumed-after-60s"
  # Dynamic Type, the largest accessibility size
  xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large || true
  relaunch_quiet; sleep 14; matrix_shot "matrix-06-dynamic-type-xxxl"
  xcrun simctl ui "$UDID" content_size large || true
  # Reduce Motion (the launch film's reduced cut)
  xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true || true
  relaunch_quiet; sleep 3; matrix_shot "matrix-07-reduce-motion-3s"
  sleep 9; matrix_shot "matrix-08-reduce-motion-12s"
  xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility ReduceMotionEnabled -bool false || true
  # the light appearance (the app is dark by design; nothing may turn white)
  xcrun simctl ui "$UDID" appearance light || true
  relaunch_quiet; sleep 14; matrix_shot "matrix-09-light-appearance"
  xcrun simctl ui "$UDID" appearance dark || true
  echo "[matrix] Low Power Mode: the Simulator has none — not run" | tee -a "$OUT/signin-matrix.txt"
  echo "[matrix] VoiceOver: the Simulator has none — not run" | tee -a "$OUT/signin-matrix.txt"
  # every other iPhone runtime this runner carries: the same build, a new device
  local app booted_rt rt dev
  app="$(find ship/build/sim/Build/Products -maxdepth 2 -name '*.app' | head -1)"
  booted_rt=$(xcrun simctl list devices booted -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((k for k,v in d.items() if v), ''))")
  for rt in $(xcrun simctl list runtimes -j | python3 -c "
import json,sys
for r in json.load(sys.stdin)['runtimes']:
    if r.get('isAvailable') and r.get('platform','iOS')=='iOS' and r['identifier'] != sys.argv[1]: print(r['identifier'])" "$booted_rt" | sort -rV | head -2); do
    dev=$(xcrun simctl create "matrix-$(basename "$rt")" "com.apple.CoreSimulator.SimDeviceType.iPhone-15" "$rt" 2>/dev/null || true)
    [ -n "$dev" ] || { echo "[matrix] $rt: could not create an iPhone 15 on it" | tee -a "$OUT/signin-matrix.txt"; continue; }
    xcrun simctl boot "$dev" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$dev" -b >/dev/null 2>&1 || true
    if xcrun simctl install "$dev" "$app" 2>/dev/null; then
      xcrun simctl launch "$dev" com.scrollanytime.app >/dev/null 2>&1 || true
      sleep 20
      xcrun simctl io "$dev" screenshot "$OUT/shots/matrix-10-$(basename "$rt").png" >/dev/null 2>&1 || true
      ocr "matrix-10-$(basename "$rt")"
      echo "[matrix] $(basename "$rt"): $(tr '\n' ' ' < "$OUT/ocr/matrix-10-$(basename "$rt").txt" | cut -c1-160)" | tee -a "$OUT/signin-matrix.txt"
    else
      echo "[matrix] $rt: the build would not install" | tee -a "$OUT/signin-matrix.txt"
    fi
    xcrun simctl shutdown "$dev" >/dev/null 2>&1 || true
  done
  python3 -c "import json,sys; print(json.dumps({'lines': open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()}))" "$OUT/signin-matrix.txt" > "$OUT/ax/matrix.json" 2>/dev/null || true
}

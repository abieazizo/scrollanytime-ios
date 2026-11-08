#!/usr/bin/env bash
# THE ONBOARDING AUDIT (the owner, 2026-11-08) — CAPTURE ONLY. On a mirror branch, never main.
#
# The REAL shell, built by this workflow from the App Store 1.1.6 (40) tree (mirror main 72a2f7d), on a NEWLY
# CREATED Simulator per device (cleared storage, no account, notifications never asked), against the live site.
# Every touch is a real idb touch. NOTHING HERE SIGNS IN, NOTHING IS TYPED, NO FORM IS SENT:
#   first-open  Home Screen → tap the icon → launch → splash → welcome (held) → Sign in with Apple (the system
#               sheet, dismissed) → Continue with Google (the consent alert, Google's first page, cancelled) →
#               Terms → back → Privacy Policy → back → Continue with email (the email step; nothing typed)
#   relaunch    quit, back to the Home Screen, tap the icon again
# Each leg is one recording. Everything lands under crash/ (the workflow uploads it whatever it holds):
#   <dev>-<leg>.mp4 (re-encoded, every frame kept at its own time) · <dev>-<leg>-raw.* (when small)
#   <dev>-<leg>-events.jsonl (the epoch of every step) · <dev>-<leg>-frames.csv · shots/ · ocr/ · audit-log.txt
set -uo pipefail

OUT="${OUT:-ship/build/demo}"
CAP="$OUT/crash"
mkdir -p "$OUT/shots" "$OUT/ax" "$CAP/shots" "$CAP/ocr" "$CAP/ax"
LOG="$CAP/audit-log.txt"
exec > >(tee -a "$LOG") 2>&1
BUNDLE=com.scrollanytime.app
APP="$(find ship/build/sim/Build/Products -maxdepth 2 -name '*.app' | head -1)"
T_START=$(date +%s)
BUDGET_S="${AUDIT_BUDGET_S:-2100}"   # the job has 45 min; ~3 go before this script, ~2 after it
DEVICES_LIST="${AUDIT_DEVICES:-iPhone 15 Pro|iPhone SE (3rd generation)}"

echo "── THE ONBOARDING AUDIT ── $(date -u +%FT%TZ)"
echo "app: $APP"
[ -n "$APP" ] || { echo "!! no .app was built"; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$APP/Info.plist" 2>/dev/null | tr '\n' ' '; echo
echo "mirror commit: $(git rev-parse HEAD 2>/dev/null)"
echo "live site: $(curl -s -m 15 https://scrollanytime.com/version)"
sw_vers | tr '\n' ' '; echo; xcodebuild -version | head -2 | tr '\n' ' '; echo

# ffmpeg for the end (the runner may not carry it): installed while the walk runs
FFMPEG="$(command -v ffmpeg || true)"
BREW_PID=""
if [ -z "$FFMPEG" ]; then
  ( HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1 brew install ffmpeg > "$CAP/brew-ffmpeg.log" 2>&1; echo "brew exit $?" >> "$CAP/brew-ffmpeg.log" ) &
  BREW_PID=$!
fi

OCRW="$OUT/ocrw-bin"
swiftc -O ship/demo/ocrw.swift -o "$OCRW" > "$CAP/ocrw-build.log" 2>&1 || { echo "!! ocrw did not compile:"; cat "$CAP/ocrw-build.log"; exit 1; }

# the workflow's own device is not used: every device here is created new
[ -n "${UDID:-}" ] && xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
pkill -f idb_companion >/dev/null 2>&1 || true
# the software keyboard, as on a phone (a Mac keyboard "connected" hides it)
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false || true

RT=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin)['runtimes'] if r.get('isAvailable') and r.get('platform','iOS')=='iOS']
rs.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
print(rs[-1]['identifier'] if rs else '')")
echo "runtime: $RT"
devtype() { xcrun simctl list devicetypes -j | python3 -c "
import json,sys
w=sys.argv[1]
print(next((d['identifier'] for d in json.load(sys.stdin)['devicetypes'] if d['name']==w), ''))" "$1"; }

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────
ts() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
EVENTS=/dev/null
ev() {
  local t; t=$(ts)
  python3 -c 'import json,sys; print(json.dumps({"t": float(sys.argv[1]), "ev": sys.argv[2]}))' "$t" "$1" >> "$EVENTS"
  echo "  [$t] $1"
}
screen_points() {
  xcrun simctl io "$U" screenshot "$OUT/.probe.png" >/dev/null 2>&1
  read -r PW PH SCALE <<<"$(python3 -c "
import struct,sys
w,h=struct.unpack('>II',open(sys.argv[1],'rb').read()[16:24]); print(w,h,3 if w>=1100 else 2)" "$OUT/.probe.png")"
  W=$((PW / SCALE)); H=$((PH / SCALE))
  echo "screen ${W}x${H} points (scale ${SCALE}, raster ${PW}x${PH})"
}
# a lossless screenshot of the moment (its words are read at the END: Vision on a busy runner would slow the app)
shot() {
  local f="$CAP/shots/$DEV-$1.png"
  xcrun simctl io "$U" screenshot "$f" >/dev/null 2>&1 || true
  ev "shot $1"
}
axdump() { idb ui describe-all --udid "$U" > "$CAP/ax/$DEV-$1.json" 2>/dev/null || true; }
tapxy() {
  idb ui tap --udid "$U" "$1" "$2" 2>>"$CAP/idb-errors.log" || idb ui tap "$1" "$2" 2>>"$CAP/idb-errors.log"
}
# find_word "<words>" : the centre of those words on a fresh screenshot, in POINTS — exit 3 when absent
find_word() {
  xcrun simctl io "$U" screenshot "$OUT/.find.png" >/dev/null 2>&1 || return 2
  local at fx fy
  at=$("$OCRW" "$OUT/.find.png" --word "$1" --fast 2>>"$CAP/ocr-errors.log") ||     at=$("$OCRW" "$OUT/.find.png" --word "$1" 2>>"$CAP/ocr-errors.log") || return 3
  read -r fx fy <<<"$at"
  python3 -c "print(int($fx*$W), int($fy*$H))"
}
# line_box "<exact line>" : "x0 y0 x1 y1" in POINTS
line_box() {
  xcrun simctl io "$U" screenshot "$OUT/.find.png" >/dev/null 2>&1 || return 2
  local at
  at=$("$OCRW" "$OUT/.find.png" --line "$1" --fast 2>>"$CAP/ocr-errors.log") ||     at=$("$OCRW" "$OUT/.find.png" --line "$1" 2>>"$CAP/ocr-errors.log") || return 3
  python3 -c "
import sys
x0,y0,x1,y1=map(float,sys.argv[1].split()); W,H=int(sys.argv[2]),int(sys.argv[3])
print(int(x0*W), int(y0*H), int(x1*W), int(y1*H))" "$at" "$W" "$H"
}
wait_word() {  # $1 words, $2 seconds → "x y"
  local end=$(( $(date +%s) + ${2:-20} )) at
  while [ "$(date +%s)" -lt "$end" ]; do
    if at=$(find_word "$1"); then echo "$at"; return 0; fi
    sleep 0.6
  done
  return 1
}
tap_word() {  # $1 words, $2 seconds to wait for them
  local at
  at=$(wait_word "$1" "${2:-12}") || { ev "!! '$1' is not on screen"; return 1; }
  ev "tap '$1' at $at"
  tapxy $at
}
on_welcome() { find_word "Continue with email" >/dev/null; }
back_to_welcome() {  # after a sheet or a page: wait for the welcome's own words
  local at
  if at=$(wait_word "Continue with email" "${1:-8}"); then ev "the welcome is back"; return 0; fi
  ev "!! the welcome did not come back"; return 1
}
# the legal page's chevron: a 38 pt button 6 pt above the page title, its left edge the title's left edge
legal_back() {
  local box x0 y0 x1 y1
  if box=$(line_box "$1"); then
    read -r x0 y0 x1 y1 <<<"$box"
    ev "legal back: title '$1' box $box → tap $((x0 + 19)) $((y0 - 30))"
    tapxy $((x0 + 19)) $((y0 - 30))
  else
    ev "!! title '$1' not found; tapping the top-left chevron spot"
    tapxy 30 $((SAT + 26))
  fi
}

REC_PID=""; REC_RAW=""; RAWS=()
rec_start() {
  REC_RAW="$OUT/.rec-$DEV-$1.mp4"; local err="$OUT/.rec-$DEV-$1.log"
  xcrun simctl io "$U" recordVideo --codec h264 --force "$REC_RAW" > "$err" 2>&1 &
  REC_PID=$!
  local i
  for i in $(seq 1 120); do grep -qi "recording started" "$err" 2>/dev/null && break; sleep 0.25; done
  ev "recording started: $(tr '\n' ' ' < "$err" | cut -c1-140)"
  sleep 2
}
rec_stop() {
  sleep 1
  kill -INT "$REC_PID" 2>/dev/null || true
  local i
  for i in $(seq 1 120); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 0.5; done
  ev "recording stopped"
  ls -la "$REC_RAW" || true
  ffprobe -v error -select_streams v:0 -show_entries frame=pts_time,pkt_dts_time,best_effort_timestamp_time \
    -of csv=p=0 "$REC_RAW" > "$CAP/$DEV-$1-frames.csv" 2>/dev/null || true
  echo "  frames: $(wc -l < "$CAP/$DEV-$1-frames.csv" | tr -d ' ')  duration: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$REC_RAW" 2>/dev/null)"
  RAWS+=("$REC_RAW|$DEV-$1")
}

find_icon() {  # the Home Screen, walked page by page until Springboard names our icon → "x y"
  local page c
  idb ui button --udid "$U" HOME >/dev/null 2>&1 || true; sleep 1.5
  idb ui button --udid "$U" HOME >/dev/null 2>&1 || true; sleep 1.5
  for page in 0 1 2 3; do
    if c=$(idb ui describe-all --udid "$U" 2>/dev/null | python3 ship/demo/find-icon-ax.py "Scroll Anytime" 2>>"$CAP/find-icon.log"); then
      echo "$c"; return 0
    fi
    if c=$(find_word "Scroll Anytime"); then   # the label under the icon; the icon is ~38 pt above it
      read -r cx cy <<<"$c"; echo "$cx $((cy - 38))"; return 0
    fi
    idb ui swipe --udid "$U" $((W * 4 / 5)) $((H / 2)) $((W / 5)) $((H / 2)) --duration 0.25 >/dev/null 2>&1 || true
    sleep 1.8
  done
  return 1
}
launch_from_icon() {
  if [ -n "$ICON" ]; then
    ev "tap the Scroll Anytime icon at $ICON"
    tapxy $ICON
  else
    ev "!! no icon found: simctl launch"
    xcrun simctl launch "$U" "$BUNDLE" >/dev/null 2>&1 || true
  fi
}

# ── one device ───────────────────────────────────────────────────────────────────────────────────────────────
run_device() {  # $1 device name
  local name="$1" dt slug
  slug=$(echo "$name" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/-$//')
  DEV="$slug"
  echo; echo "══ $name ($slug) ══ $(date -u +%T)Z"
  dt=$(devtype "$name")
  [ -n "$dt" ] || { echo "!! no device type named '$name' on this runner"; xcrun simctl list devicetypes | grep -i iphone; return 1; }
  U=$(xcrun simctl create "audit $name" "$dt" "$RT") || { echo "!! could not create $name on $RT"; return 1; }
  echo "created $U ($dt on $RT)"
  xcrun simctl boot "$U" || return 1
  xcrun simctl bootstatus "$U" -b >/dev/null 2>&1 || true
  xcrun simctl install "$U" "$APP" || { echo "!! install failed"; return 1; }
  pkill -f idb_companion >/dev/null 2>&1 || true; sleep 1
  idb_companion --udid "$U" > "$CAP/idb-companion-$slug.log" 2>&1 &
  local COMP=$!
  sleep 5
  idb connect localhost 10882 >/dev/null 2>&1 || true
  idb list-targets 2>&1 | head -5
  screen_points
  case "$name" in *SE*) SAT=20 ;; *) SAT=59 ;; esac
  # the network, off camera (a just-booted Simulator can sit without DNS), then Safari goes and first-boot settles
  xcrun simctl openurl "$U" "https://scrollanytime.com/health" >/dev/null 2>&1 || true
  sleep 8
  xcrun simctl terminate "$U" com.apple.mobilesafari >/dev/null 2>&1 || true
  sleep 12
  xcrun simctl spawn "$U" defaults read com.apple.UIKit 2>/dev/null | head -3 || true
  ICON=""
  ICON=$(find_icon) || ICON=""
  echo "icon: ${ICON:-not found}"

  # ── leg 1: the first open ──
  EVENTS="$CAP/$slug-first-open-events.jsonl"; : > "$EVENTS"
  ev "leg first-open on $name ($U), screen ${W}x${H}"
  rec_start first-open
  shot 00-home-screen
  sleep 1.5
  launch_from_icon
  local t0; t0=$(date +%s)
  # every half second for the first 6 s: the launch itself, lossless
  local k; for k in 1 2 3 4 5 6 7 8 9 10; do sleep 0.25; shot "01-launch-$(printf %02d "$k")"; done
  if wait_word "Continue with email" 45 >/dev/null; then ev "welcome on screen ($(( $(date +%s) - t0 )) s after the tap)"; else ev "!! no welcome within 45 s"; fi
  shot 10-welcome
  axdump 10-welcome
  sleep 8                                  # held: whatever the welcome does on its own
  shot 11-welcome-held

  # Sign in with Apple — the system sheet (the Simulator has no Apple Account); dismissed
  if tap_word "Sign in with Apple" 6; then
    sleep 1.2; shot 20-apple-tap
    sleep 2.5; shot 21-apple-sheet; axdump 21-apple-sheet
    sleep 2
    local w done=""
    for w in "Cancel" "Close" "Not Now" "OK"; do
      if at=$(find_word "$w"); then ev "dismiss the Apple sheet: '$w' at $at"; tapxy $at; done=1; break; fi
    done
    if [ -z "$done" ]; then
      for w in "Cancel" "Close"; do
        if c=$(python3 ship/demo/find-element.py "$w" < "$CAP/ax/$DEV-21-apple-sheet.json" 2>/dev/null); then ev "dismiss the Apple sheet by name '$w' at $c"; tapxy $c; done=1; break; fi
      done
    fi
    [ -n "$done" ] || { ev "nothing to dismiss the Apple sheet with: swiped down"; idb ui swipe --udid "$U" $((W / 2)) $((H * 30 / 100)) $((W / 2)) $((H * 95 / 100)) --duration 0.3 || true; }
    sleep 1.5; shot 22-apple-after
    back_to_welcome 8 || { sleep 2; shot 23-apple-after-later; }
  fi

  # Continue with Google — the consent alert, Google's first page, cancelled
  if tap_word "Continue with Google" 8; then
    sleep 1.2; shot 30-google-tap
    sleep 1.5; shot 31-google-alert
    if find_word "wants to use" >/dev/null; then
      sleep 1.5
      local box
      if box=$(line_box "Continue"); then
        read -r x0 y0 x1 y1 <<<"$box"; ev "the consent alert: Continue at $(((x0 + x1) / 2)) $(((y0 + y1) / 2))"; tapxy $(((x0 + x1) / 2)) $(((y0 + y1) / 2))
      else ev "!! the alert's Continue not found"; fi
      sleep 2; shot 32-google-sheet-opening
      sleep 4; shot 33-google-page
      sleep 3; shot 34-google-page-later; axdump 34-google-page
    else
      ev "no consent alert after the Google tap"
      sleep 4; shot 33-google-page
    fi
    local tries=0
    while ! on_welcome && [ $tries -lt 4 ]; do
      tries=$((tries + 1))
      if box=$(line_box "Cancel"); then
        read -r x0 y0 x1 y1 <<<"$box"; ev "Google sheet: Cancel at $(((x0 + x1) / 2)) $(((y0 + y1) / 2))"; tapxy $(((x0 + x1) / 2)) $(((y0 + y1) / 2))
      elif c=$(idb ui describe-all --udid "$U" 2>/dev/null | python3 ship/demo/find-element.py "Close" 2>/dev/null) || \
           c=$(idb ui describe-all --udid "$U" 2>/dev/null | python3 ship/demo/find-element.py "Cancel" 2>/dev/null); then
        ev "Google sheet: closed by name at $c"; tapxy $c
      elif [ $tries -le 2 ]; then
        # iOS 26's sheet closes with an X at its top-left (walk-signin.sh, run 38107613573)
        ev "Google sheet: the X at the top-left"; tapxy "$(python3 -c "print(int(0.097 * $W))")" "$(python3 -c "print(int((0.1125 if $H > 700 else 0.075) * $H))")"
      else
        ev "Google sheet: swiped down"; idb ui swipe --udid "$U" $((W / 2)) $((H * 12 / 100)) $((W / 2)) $((H * 95 / 100)) --duration 0.3 || true
      fi
      sleep 2.5
    done
    shot 35-google-after
    back_to_welcome 6 || true
    sleep 2; shot 36-google-after-later
  fi

  # Terms, then back; Privacy Policy, then back
  if tap_word "Terms" 6; then
    sleep 1; shot 40-terms; sleep 2; shot 41-terms-settled
    legal_back "Terms of Use"; sleep 1.2; shot 42-terms-back
    back_to_welcome 6 || true
  fi
  sleep 1.5
  if tap_word "Privacy Policy" 6; then
    sleep 1; shot 43-privacy; sleep 2; shot 44-privacy-settled
    legal_back "Privacy Policy"; sleep 1.2; shot 45-privacy-back
    back_to_welcome 6 || true
  fi
  sleep 2

  # Continue with email — the email step; nothing typed
  if tap_word "Continue with email" 6; then
    sleep 0.6; shot 50-email-tap
    sleep 1.4; shot 51-email-step
    sleep 2.5; shot 52-email-keyboard
    sleep 3; shot 53-email-held
  fi
  rec_stop first-open

  # ── leg 2: the relaunch (the same install, quit and opened again) ──
  EVENTS="$CAP/$slug-relaunch-events.jsonl"; : > "$EVENTS"
  ev "leg relaunch on $name"
  xcrun simctl terminate "$U" "$BUNDLE" >/dev/null 2>&1 || true
  ev "app terminated"
  sleep 2
  ICON=$(find_icon) || ICON=""
  rec_start relaunch
  shot 60-home-screen-again
  sleep 1.5
  launch_from_icon
  for k in 1 2 3 4 5 6 7 8; do sleep 0.25; shot "61-relaunch-$(printf %02d "$k")"; done
  local seen=""
  for k in $(seq 1 60); do
    if find_word "Continue with email" >/dev/null; then seen=welcome; break; fi
    if find_word "Email me a sign-in link" >/dev/null; then seen=email-step; break; fi
    sleep 0.4
  done
  ev "relaunch landed on: ${seen:-neither the welcome nor the email step}"
  shot 70-relaunch-landed
  sleep 6; shot 71-relaunch-held
  rec_stop relaunch

  kill "$COMP" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$U" >/dev/null 2>&1 || true
  echo "══ $name done ══ $(( $(date +%s) - T_START )) s into the walk"
}

IFS='|' read -r -a DEVS <<<"$DEVICES_LIST"
for d in "${DEVS[@]}"; do
  el=$(( $(date +%s) - T_START ))
  if [ $el -gt $((BUDGET_S - 480)) ]; then echo "!! $d NOT RUN: ${el}s of ${BUDGET_S}s used"; continue; fi
  run_device "$d" || echo "!! $d failed (see above)"
done

# ── the recordings: every frame kept at its own display time ─────────────────────────────────────────────────
if [ -n "$BREW_PID" ]; then wait "$BREW_PID" 2>/dev/null || true; tail -3 "$CAP/brew-ffmpeg.log"; fi
FFMPEG="$(command -v ffmpeg || true)"
echo; echo "ffmpeg: ${FFMPEG:-none}"
for item in ${RAWS[@]+"${RAWS[@]}"}; do
  raw="${item%%|*}"; name="${item##*|}"
  [ -s "$raw" ] || { echo "!! $name: no recording"; continue; }
  size=$(stat -f %z "$raw")
  if [ -n "$FFMPEG" ]; then
    # a remux to Matroska keeps display time (the Simulator mp4's decoded stamps are DTS-based after a seek)
    ffmpeg -v error -y -i "$raw" -c copy "$OUT/.tmp-$name.mkv" && \
    ffmpeg -v error -y -i "$OUT/.tmp-$name.mkv" -map 0:v:0 -c:v libx264 -preset veryfast -crf 14 -pix_fmt yuv420p -fps_mode passthrough "$CAP/$name.mp4" && \
      echo "$name: $(du -h "$CAP/$name.mp4" | cut -f1) encoded (raw $((size / 1048576)) MB)"
    [ "$size" -lt 262144000 ] && cp "$OUT/.tmp-$name.mkv" "$CAP/$name-raw.mkv"
  else
    cp "$raw" "$CAP/$name-raw.mp4"; echo "$name: raw kept ($((size / 1048576)) MB)"
  fi
done
# every lossless shot's words, now that nothing is being measured
for f in "$CAP"/shots/*.png; do [ -f "$f" ] && "$OCRW" "$f" > "$CAP/ocr/$(basename "$f" .png).json" 2>/dev/null; done
echo "ocr: $(ls "$CAP"/ocr/*.json 2>/dev/null | wc -l | tr -d ' ') shots read"
ls -la "$CAP" | head -60
echo "── the audit walk finished in $(( $(date +%s) - T_START )) s ──"
exit 0

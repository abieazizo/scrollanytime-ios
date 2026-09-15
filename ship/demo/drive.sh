#!/usr/bin/env bash
# Drive the REAL Scroll Anytime binary on iOS in the Simulator and record it, so App Review's
# item 1 (a video of the app in use, starting at launch) can be answered without a physical
# device in the room. Every touch here is a real touch delivered to the app by idb -- nothing is
# simulated in a browser and nothing is composited afterwards.
#
#   MODE=calibrate  walk the flow, screenshot every step, record nothing   (coordinate discovery)
#   MODE=record     same walk with the video running                        (the deliverable)
set -euo pipefail

UDID="${UDID:?boot a simulator first}"
BUNDLE=com.scrollanytime.app
OUT="${OUT:-ship/build/demo}"
mkdir -p "$OUT/shots"

# Screen size in POINTS. The screenshot is the only thing on the runner that knows for certain,
# so read the PNG header and divide by the device scale.
xcrun simctl io "$UDID" screenshot "$OUT/.probe.png" >/dev/null 2>&1
read -r PW PH SCALE <<<"$(python3 -c "
import struct, sys
w, h = struct.unpack('>II', open(sys.argv[1],'rb').read()[16:24])
print(w, h, 3 if w >= 1100 else 2)" "$OUT/.probe.png")"
W=$((PW / SCALE)); H=$((PH / SCALE))
echo "screen ${W}x${H} points (scale ${SCALE}, raster ${PW}x${PH})"

# Fractions measured off the live app at iPhone width (scripts/_demo_coords.mjs). The bottom nav
# sits 42pt above the web viewport's bottom edge and the shell's viewport runs under the home
# indicator, so NAV_UP carries that inset and is tunable from the workflow.
NAV_UP="${NAV_UP:-76}"
NAVY=$((H - NAV_UP))
fx() { python3 -c "print(int($1 * $W))"; }
fy() { python3 -c "print(int($1 * $H))"; }
FEED_X=$(fx 0.2505); TORAH_X=$(fx 0.4123); RABBIS_X=$(fx 0.5856); PROFILE_X=$(fx 0.7401)
RAIL_X=$(fx 0.9008); SAVE_Y=$(fy 0.5668)
MID_X=$((W / 2)); MID_Y=$((H / 2))
echo "nav y=$NAVY  tabs: feed=$FEED_X torah=$TORAH_X rabbis=$RABBIS_X profile=$PROFILE_X"


# -- naming things instead of pointing at them --------------------------------------------------
AX="$OUT/ax"; mkdir -p "$AX"
axdump() { idb ui describe-all --udid "$UDID" > "$AX/$1.json" 2>/dev/null || true; }

# tap_named <label> [--contains] : poll for a control BY NAME, tap it, and say whether it landed.
# Every coordinate in this driver that was measured off a screenshot has at some point landed on
# the wrong thing: on a different device, or one second too early. Names do not move.
tap_named() {
  want="$1"; shift
  mode="${1:-}"
  for t in 1 2 3 4 5 6 7 8; do
    if c=$(idb ui describe-all --udid "$UDID" 2>/dev/null | python3 ship/demo/find-element.py "$want" $mode 2>>"$OUT/ax.log"); then
      echo "  tap_named '$want' -> $c"
      idb ui tap --udid "$UDID" $c
      return 0
    fi
    sleep 1.5
  done
  echo "  tap_named '$want' NOT FOUND after 12s"
  return 1
}

shot()  { xcrun simctl io "$UDID" screenshot "$OUT/shots/$1.png" >/dev/null 2>&1 || true; echo "  . shot $1"; }
tap()   { idb ui tap --udid "$UDID" "$1" "$2"; sleep "${3:-1.2}"; }
swipe() { idb ui swipe --udid "$UDID" "$1" "$2" "$3" "$4" --duration "${5:-0.16}"; sleep "${6:-2.2}"; }

idb ui button --udid "$UDID" HOME || true
sleep 2
idb ui button --udid "$UDID" HOME || true   # a second press leaves page 1, wherever we were
sleep 2

# Apple asked for the launch itself, so find our icon on the Home Screen and tap it like a person.
# A freshly installed app is not on page 1 of a clean Simulator, so walk the pages. The template is
# the icon iOS rasterised into the bundle, which is exactly what Springboard draws.
FOUND=""
for page in 0 1 2 3; do
  shot "00-home-p$page"
  # Ask Springboard what the icons ARE, rather than guessing from pixels.
  if COORD=$(idb ui describe-all --udid "$UDID" 2>/dev/null | python3 ship/demo/find-icon-ax.py "Scroll Anytime" 2>>"$OUT/find-icon.log"); then
    echo "  icon found by name on page $page at $COORD"
    cp "$OUT/shots/00-home-p$page.png" "$OUT/shots/00-home.png"
    FOUND="$COORD"
    break
  fi
  echo "  not on page $page"
  swipe $((W * 4 / 5)) $((H / 2)) $((W / 5)) $((H / 2)) 0.25 1.8
done

if [ -n "$FOUND" ]; then
  tap $FOUND 8
else
  echo "  !! icon not located on any page - falling back to simctl launch (see $OUT/find-icon.log)"
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  sleep 8
fi

# Did OUR app actually come to the front? An earlier run tapped Wallet and cheerfully walked the
# whole flow inside it, so this is not optional. Poll rather than check once: a cold launch on a
# just-booted Simulator is not instant, and a system alert left on screen can delay it further.
# iOS 26 simulators no longer label the process "UIKitApplication:<bundle>" in launchctl — match the
# bundle id anywhere, and accept a running process reported by simctl as well (2026-09-14 the walk
# declared a launched app "not up" three times and bailed with the recording already rolling).
front() {
  xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE" && return 0
  xcrun simctl spawn "$UDID" launchctl print system 2>/dev/null | grep -q "$BUNDLE" && return 0
  pgrep -f "$BUNDLE" >/dev/null 2>&1 && return 0
  return 1
}
for attempt in 1 2 3; do
  for t in 1 2 3 4 5 6; do front && break; sleep 3; done
  if front; then echo "  $BUNDLE is running"; break; fi
  echo "  !! $BUNDLE not up (attempt $attempt) - launching it directly"
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
done
front || { echo "::error::could not get $BUNDLE to the front"; shot 01-FAILED; exit 1; }

shot 01-launched
sleep 5

# Did the first navigation fail? With no connection the shell shows its bundled offline page
# ("needs a connection for your first open" + Retry) — the right thing for a user, the wrong thing
# for a walk that then taps its way through a page with nothing on it (run #5, 2026-09-14). Web
# content is invisible to idb's accessibility dump, so read the screen: 13 s after the tap the app
# is on the hero (bright) or the feed; anything still this dark is the offline page or a stuck
# splash. Say so loudly and press Retry ONCE, where the offline page puts it.
# Luminance the way the recording is read: ffprobe's signalstats YAVG (limited range — pure black
# is 16, the #0B0B0F ground ≈ 26, the bundled offline page ≈ 30, the film's held frames ≤ 35, the
# hero ≥ 75). The first version used cv2 and printed 0 for everything.
lum() {
  ffprobe -v error -f lavfi -i "movie=$1,signalstats" -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 2>/dev/null \
    | head -1 | cut -d. -f1 | grep -E '^[0-9]+$' || echo 99
}
shot 01b-settled
L=$(lum "$OUT/shots/01b-settled.png")
echo "  screen luminance after launch: Y=$L (ground 26, offline page 30, hero 75+)"
if [ "$L" -lt 40 ]; then
  echo "::warning::the first launch is still dark ${L}/255 after 13 s — the offline fallback (no network?) or a stuck splash; tapping Retry"
  idb ui tap --udid "$UDID" "$MID_X" "$(fy 0.618)"
  sleep 12
  shot 01c-after-retry
  echo "  luminance after Retry: $(lum "$OUT/shots/01c-after-retry.png")"
fi

# A fresh install opens on the landing card, which is exactly what a reviewer sees. Take the
# no-account path on camera: it is the app's own demonstration of "no account is required".
CONTINUE_Y="${CONTINUE_Y:-$(fy 0.903)}"
axdump 01-landing
# The previous run tapped this a second too early and then spent the whole walk on the
# landing card. Wait for the control to exist rather than for a stopwatch.
if ! tap_named "continue without an account" --contains; then
  echo "  falling back to the measured coordinate"
  idb ui tap --udid "$UDID" "$MID_X" "$CONTINUE_Y"
fi
sleep 6
shot 02-entered
axdump 02-feed
sleep 5
shot 03-feed

# One tap turns the sound on. It also pauses, because that is what a tap on a video does here,
# so tap again to resume -- the previous run left the clip frozen behind a play triangle for the
# rest of the walk.
tap "$MID_X" "$MID_Y" 2.0
shot 04-sound-on
tap "$MID_X" "$MID_Y" 2.5
shot 04b-playing

for i in 1 2 3; do
  swipe "$MID_X" $((H * 3 / 4)) "$MID_X" $((H / 4)) 0.16 3.5
  shot "05-swipe-$i"
done
swipe "$MID_X" $((H / 4)) "$MID_X" $((H * 3 / 4)) 0.16 3.5
shot 06-swipe-back

# Save with the rail button, not a double-tap. Two `idb ui tap` invocations cannot land inside the
# double-tap window -- each one costs its own process start -- so the previous run's "save" was read
# as two ordinary taps and My Torah came up empty.
SAVE_Y=$(fy 0.642)
tap_named "save" || tap "$RAIL_X" "$SAVE_Y" 0.1
sleep 3
shot 07-saved

# SHARING (2026-09-15): the rail's WhatsApp, Download and More. A simulator has no WhatsApp, so the
# shell's fallback is what gets recorded: the tap leaves for wa.me in Safari. Then back into the
# app for the one-time download card, the ring (the clip's watermarked file is usually still
# rendering on the day of the walk: "Preparing"), and the More sheet.
axdump 07b-rail
tap_named "whatsapp" --contains || tap "$RAIL_X" "$(fy 0.70)" 0.1
sleep 4
shot 07b-whatsapp
xcrun simctl terminate "$UDID" com.apple.mobilesafari >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 6
tap_named "download" || tap "$RAIL_X" "$(fy 0.77)" 0.1
sleep 2
shot 07c-download-card
axdump 07c-download-card
tap_named "got it" --contains || tap "$MID_X" "$(fy 0.58)" 0.1
sleep 3
shot 07d-download-ring
tap_named "more options" --contains || tap "$RAIL_X" "$(fy 0.84)" 0.1
sleep 2.5
shot 07e-more
axdump 07e-more
tap "$MID_X" "$(fy 0.10)" 1.5

tap_named "my torah" --contains || tap "$TORAH_X" "$NAVY" 0.1
sleep 4
shot 08-my-torah
tap_named "rabbis" || tap "$RABBIS_X" "$NAVY" 0.1
sleep 4
shot 09-rabbis
axdump 09-rabbis

RABBI_X=$(fx 0.26); FOLLOW_Y=$(fy 0.61); CARD_Y=$(fy 0.43)
tap "$RABBI_X" "$FOLLOW_Y" 3.0
shot 10-followed
# Following offers an account, which is worth showing and then declining: the app keeps working.
tap "$MID_X" $(fy 0.10) 2.5
shot 10b-declined
tap "$RABBI_X" "$CARD_Y" 4.0
shot 11-rabbi-open

tap_named "profile" || tap "$PROFILE_X" "$NAVY" 0.1
sleep 4
shot 12-profile
axdump 12-profile
# Scroll Profile so the next pass knows where Delete account sits -- Apple asked to see it.
swipe "$MID_X" $((H * 3 / 4)) "$MID_X" $((H / 4)) 0.30 2.5
shot 13-profile-scrolled
swipe "$MID_X" $((H * 3 / 4)) "$MID_X" $((H / 4)) 0.30 2.5
shot 14-profile-bottom
echo "walk finished"

# ── the returning launch ───────────────────────────────────────────────────────────────────────
# The first launch above is the full film; every launch after it is the 1.5 s cut. Record that too:
# quit the app, wait a beat, open it again from the icon (or directly), and shoot it landing.
echo "  - returning launch"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
shot 20-quit
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 0.6; shot 21-returning-0600ms
sleep 0.6; shot 22-returning-1200ms
sleep 0.8; shot 23-returning-2000ms
sleep 1.5; shot 24-returning-landed


# ── Continue with Google ───────────────────────────────────────────────────────────────────────
# The one sign-in that navigates the web view off our origin. With app-bound domains it FAILED
# silently in every build before 27 (the navigation to accounts.google.com was refused and the
# shell showed its "no connection" glyph). Prove the page is reached: tap the button on the hero,
# wait, and read the screen — Google's sign-in page is white (Y > 150); ours never is.
echo "  - continue with Google"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 12
shot 30-hero-again
idb ui tap --udid "$UDID" "$MID_X" "$(fy 0.796)"
sleep 8
shot 31-google
G=$(lum "$OUT/shots/31-google.png")
echo "  luminance after Continue with Google: Y=$G (Google's page is white, > 150)"
if [ "$G" -gt 150 ]; then echo "  Google sign-in page reached inside the app"; else echo "::warning::Continue with Google did not reach Google's page (Y=$G) — see 31-google.png"; fi
axdump 31-google

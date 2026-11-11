#!/usr/bin/env bash
# THE FIRST OPEN, MEASURED (incident 2026-11-02) — run by drive.sh when the marker ship/demo/walk-firstopen exists
# (pushed ONLY to a mirror branch, never main). The REAL shell built from this tree, on iOS in the Simulator, each
# launch on a freshly ERASED device (shutdown → erase → boot → install), against the live site:
#
#   A   fresh install → the feed's first video frame, launched with -saUITest (the suites' storage flags skip the
#       onboarding), the runner's whole network shaped to the perf harness's `lte` profile (dummynet)
#   B   the same WITHOUT -saUITest: fresh install → the onboarding's first screen (its welcome), same shaping
#   C1  no shaping; every packet on the runner's network interface BLOCKED from just before launch until 3 s after:
#       the shell must never show its bundled "needs a connection" page after the release, and the app must be
#       on screen within ~10 s of it
#   C30 the same with the block held for 30 s: does the offline page appear, and does the app come in by itself.
#       pf drops packets BELOW the path NWPathMonitor sees, so the runner's interface (and the Simulator's path)
#       stays "satisfied": by the shell's rule (f9f54c88) that is "a path and still no answer" — quiet retries and,
#       from the third failure, the shell's own "Still connecting…" line under the launch art, not the offline
#       page. The walk records which of the two (or neither) is on screen in every frame, and where.
#   C1old the C1 condition on the shell from BEFORE the fix (ship/demo/firstopen-oldshell.patch applied, rebuilt
#       incrementally) — the control that says the C condition is one the old shell walls on
#
# Times are from the instant before `simctl launch` (ship/demo/firstopen-capture.py). The app also reports its own
# hand-off as `[boot] ready {ms,dest}` (ms since its navigation start) to /log/boot; this walk prints each launch's
# UTC instant so those rows can be matched afterwards (production D1 error_logs, ua LIKE '%SASimulator%').
#
# THE SHAPING: scripts/perf/throttle-proxy.mjs PROFILES.lte = { downKbps: 5000, upKbps: 1000, rttMs: 80 } — here
# dnctl pipe 1 (in) = bw 5000Kbit/s delay 40 ms, pipe 2 (out) = bw 1000Kbit/s delay 40 ms (RTT/2 each way, as the
# proxy does), applied by pf `dummynet in|out quick on <the default route's interface> all`.
# THE BLOCK: new TCP connections are answered with a reset, UDP with ICMP unreachable (so a request fails at
# once, the way a dead cellular hand-off does), everything else is dropped — established connections (the
# runner's own) stall instead of being reset.
# Both are undone after every leg and on exit (pf back to /etc/pf.conf, the enable token released, dnctl flushed).
#
# Evidence: crash/firstopen-log.txt (this log), crash/firstopen-summary.txt, ax/firstopen-<leg>.json (every frame's
# luminance and words), shots/firstopen-<leg>-*.png, crash/firstopen-<leg>-frames.tgz (every frame, 240 px).
set -uo pipefail

UDID="${UDID:?boot a simulator first}"
OUT="${OUT:-ship/build/demo}"
BUNDLE=com.scrollanytime.app
FO="$OUT/firstopen"
mkdir -p "$FO" "$OUT/shots" "$OUT/ax" "$OUT/crash"
LOG="$OUT/crash/firstopen-log.txt"
SUMMARY="$OUT/crash/firstopen-summary.txt"
exec > >(tee -a "$LOG") 2>&1
T_START=$(date +%s)
BUDGET_S="${FIRSTOPEN_BUDGET_S:-1680}"   # the job has 45 min; ~9 go before the walk, ~3 after it
LEGS="$(sed -n 's/^legs:[[:space:]]*//p' ship/demo/walk-firstopen | head -1)"
LEGS="${LEGS:-A1 B1 C1 A2 B2 C30 A3 B3 C1old}"
SETTLE="$(sed -n 's/^settle:[[:space:]]*//p' ship/demo/walk-firstopen | head -1)"; SETTLE="${SETTLE:-2}"
# the clock for A and B: `clock: record` = simctl's screen recording (exact frame times, but on a 3-cpu runner it
# saturated the machine: run 41451702694, simctl launch took 8.1 s to return); anything else = screenshots + the app's own row
CLOCK="$(sed -n 's/^clock:[[:space:]]*//p' ship/demo/walk-firstopen | head -1)"; REC_FLAG=""; [ "$CLOCK" = "record" ] && REC_FLAG="--record"
echo "── THE FIRST OPEN, MEASURED ── $(date -u +%FT%TZ)  legs: $LEGS"
echo "  tree: $(git rev-parse --short=12 HEAD 2>/dev/null) ($(git log -1 --format=%s 2>/dev/null | cut -c1-90))"
echo "  live site: $(curl -s -m 10 https://scrollanytime.com/version)"
echo "  runner: $(sw_vers -productVersion) $(uname -m), $(sysctl -n hw.ncpu) cpus; $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"

# idb is not needed here, and its companion holds the device across erases
pkill -f idb_companion >/dev/null 2>&1 || true

# ── the app ────────────────────────────────────────────────────────────────────────────────────────────────────
APP_BUILT="$(find ship/build/sim/Build/Products -maxdepth 2 -name '*.app' | head -1)"
[ -n "$APP_BUILT" ] || { echo "::error::no .app built"; exit 1; }
APP_NEW="$FO/app-new/$(basename "$APP_BUILT")"
mkdir -p "$FO/app-new"; cp -R "$APP_BUILT" "$FO/app-new/"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_NEW/Info.plist")"
echo "  shell: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_NEW/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_NEW/Info.plist")); the fix's path monitor in the binary: $(grep -c 'com.scrollanytime.firstopen' "$APP_NEW/$EXE" 2>/dev/null) (1 = the new shell)"
APP_OLD=""

# ── OCR (compiled once) ────────────────────────────────────────────────────────────────────────────────────────
OCR="$FO/ocr-bin"
swiftc -O ship/demo/ocr.swift -o "$OCR" 2>"$FO/ocr-build.txt" || { echo "::warning::ocr.swift did not compile: $(tail -3 "$FO/ocr-build.txt")"; OCR=""; }
python3 -c 'import cv2, numpy; print("  cv2", cv2.__version__)' || { python3 -m pip install --break-system-packages opencv-python-headless >/dev/null 2>&1 || python3 -m pip install opencv-python-headless >/dev/null 2>&1; }

# ── the network ────────────────────────────────────────────────────────────────────────────────────────────────
IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
IF="${IF:-en0}"
echo "  default route's interface: $IF ($(ifconfig "$IF" 2>/dev/null | awk '/inet /{print $2}' | head -1))"
PF_TOKEN=""
PF_WAS="$(sudo pfctl -s info 2>/dev/null | awk '/^Status:/{print $2}')"
PFCONF="$FO/pf.conf"
{ cat /etc/pf.conf; echo 'dummynet-anchor "firstopen"'; echo 'anchor "firstopen"'; } > "$PFCONF"
net_clear() {
  sudo pfctl -a firstopen -F all >/dev/null 2>&1 || true
  printf '' | sudo pfctl -a firstopen -f - >/dev/null 2>&1 || true
  sudo dnctl -q flush >/dev/null 2>&1 || true
}
net_restore() {
  net_clear
  sudo pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  [ -n "$PF_TOKEN" ] && sudo pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
  PF_TOKEN=""
  echo "  network restored (pf $(sudo pfctl -s info 2>/dev/null | awk '/^Status:/{print $2}'), was $PF_WAS before the walk; dummynet: $(sudo dnctl list 2>/dev/null | wc -l | tr -d ' ') lines)"
}
trap 'net_restore' EXIT
sudo pfctl -f "$PFCONF" 2>&1 | grep -v -i "ALTQ\|No ALTQ\|flushing of rules\|present in the main ruleset" | sed 's/^/  pfctl: /' || true
PF_TOKEN="$(sudo pfctl -E 2>&1 | awk '/Token/{print $NF}')"
echo "  pf enabled (token ${PF_TOKEN:-none}); status now $(sudo pfctl -s info 2>/dev/null | awk '/^Status:/{print $2}')"
SHAPE_DOWN="5000Kbit/s"; SHAPE_UP="1000Kbit/s"; SHAPE_DELAY=40
net_lte() {
  net_clear
  sudo dnctl pipe 1 config bw "$SHAPE_DOWN" delay "$SHAPE_DELAY"
  sudo dnctl pipe 2 config bw "$SHAPE_UP" delay "$SHAPE_DELAY"
  printf 'dummynet in quick on %s all pipe 1\ndummynet out quick on %s all pipe 2\n' "$IF" "$IF" | sudo pfctl -a firstopen -f - 2>&1 | grep -v -i altq || true
}
BLOCK_RULES="$FO/block.rules"
printf 'block return out quick on %s proto tcp from any to any flags S/SA\nblock return out quick on %s proto udp from any to any\nblock drop quick on %s all\n' "$IF" "$IF" "$IF" > "$BLOCK_RULES"
net_block() { net_clear; sudo pfctl -a firstopen -f "$BLOCK_RULES" 2>&1 | grep -v -i altq || true; }
RELEASE_CMD="sudo pfctl -a firstopen -F rules"
probe() {  # what the runner's own network does right now
  local c
  c=$(curl -s -m 12 -o /dev/null -w 'connect %{time_connect}s, first byte %{time_starttransfer}s, 2 MB in %{time_total}s = %{speed_download} B/s' 'https://speed.cloudflare.com/__down?bytes=2000000' 2>&1) || c="FAILED ($c)"
  echo "    down: $c"
  head -c 500000 /dev/urandom > "$FO/.up.bin"
  c=$(curl -s -m 12 -o /dev/null -w '500 KB up in %{time_total}s = %{speed_upload} B/s' --data-binary @"$FO/.up.bin" 'https://speed.cloudflare.com/__up' 2>&1) || c="FAILED ($c)"
  echo "    up:   $c"
  echo "    ping: $(ping -c 4 -q 1.1.1.1 2>&1 | tail -1)"
}
echo "── the network, measured from the runner ──"
echo "  unshaped:"; probe
net_lte
echo "  shaped (lte): dnctl pipe 1 config bw $SHAPE_DOWN delay $SHAPE_DELAY (in) · pipe 2 config bw $SHAPE_UP delay $SHAPE_DELAY (out) on $IF"
sudo dnctl list 2>&1 | sed 's/^/    dnctl: /' | head -12
sudo pfctl -a firstopen -s dummynet 2>&1 | sed 's/^/    pf dummynet: /' | head -4
probe
net_block
echo "  blocked: $(sudo pfctl -a firstopen -s rules 2>&1 | tr '\n' ';')"
echo "    scrollanytime.com while blocked: $(curl -s -m 8 -o /dev/null -w '%{http_code} after %{time_total}s' https://scrollanytime.com/health 2>&1; echo " (exit $?)")"
eval "$RELEASE_CMD" >/dev/null 2>&1
echo "    after release: $(curl -s -m 8 -o /dev/null -w '%{http_code} after %{time_total}s' https://scrollanytime.com/health)"
net_clear

# ── one leg ────────────────────────────────────────────────────────────────────────────────────────────────────
fresh_device() {  # $1 = the app to install
  local t0=$SECONDS
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl erase "$UDID" || return 1
  xcrun simctl boot "$UDID" || return 1
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || return 1
  local t1=$SECONDS
  xcrun simctl install "$UDID" "$1" || return 1
  echo "  device erased + booted in $((t1 - t0)) s, installed in $((SECONDS - t1)) s"
  # the Simulator's own network after a cold boot (run #5, 2026-09-14: a just-booted device sat without DNS) —
  # Safari loads /health off camera, read back by OCR; then Safari goes and the host's DNS cache is emptied
  xcrun simctl openurl "$UDID" "https://scrollanytime.com/health" >/dev/null 2>&1 || true
  local i ok=""
  for i in 1 2 3 4 5 6 7 8; do
    sleep 1.5
    xcrun simctl io "$UDID" screenshot --type=jpeg "$FO/.warm.jpg" >/dev/null 2>&1 || continue
    if [ -n "$OCR" ] && "$OCR" "$FO/.warm.jpg" 2>/dev/null | grep -qi 'scrollanytime\|"ok"\|ok":true\|true'; then ok=1; break; fi
  done
  echo "  the Simulator's network: $([ -n "$ok" ] && echo "Safari loaded /health after $(python3 -c "print($i*1.5)") s" || echo "Safari did NOT show /health in 12 s")"
  xcrun simctl terminate "$UDID" com.apple.mobilesafari >/dev/null 2>&1 || true
  sleep "$SETTLE"   # first-boot work (the erased device indexes, sets up, posts its banners) settles first
}

RESULTS="$FO/results.jsonl"
: > "$RESULTS"
run_leg() {  # $1 leg name
  local leg="$1" kind args="" mode window release="" nopath="" app="$APP_NEW" dir="$FO/$1"
  kind="${leg%%[0-9]*}"
  case "$leg" in
    A*) args="-saUITest"; mode=feed; window=20 ;;
    B*) mode=welcome; window=20 ;;
    C1old) mode=wall; window=26; release=3 ;;
    C30) mode=wall; window=56; release=30 ;;
    C*) mode=wall; window=26; release=3 ;;
    # NO PATH AT ALL: the interface itself down for 30 s (NWPathMonitor then reports no path — the one case the
    # offline page is for), then up. Its own run: the runner is unreachable meanwhile (a root timer brings the
    # interface back even if this script dies).
    N*) mode=wall; window=60; release="${leg#N}"; release="${release:-30}"; nopath=1 ;;
    *) echo "  unknown leg $leg"; return 1 ;;
  esac
  if [ "$leg" = "C1old" ]; then
    [ -n "$APP_OLD" ] || build_old || { echo "  !! the old shell did not build — C1old NOT RUN"; echo "{\"leg\":\"$leg\",\"ran\":false,\"why\":\"old shell build failed\"}" >> "$RESULTS"; return 1; }
    app="$APP_OLD"
  fi
  echo; echo "══ leg $leg ($(basename "$app") from $(dirname "$app" | xargs basename); args '${args}'; mode $mode; window ${window}s${release:+; network blocked until ${release}s}) ══ $(date -u +%T)Z"
  fresh_device "$app" || { echo "  !! fresh device failed"; echo "{\"leg\":\"$leg\",\"ran\":false,\"why\":\"fresh device failed\"}" >> "$RESULTS"; return 1; }
  mkdir -p "$dir"
  if [ -n "$nopath" ]; then
    curl -s -m 8 -o /dev/null https://scrollanytime.com/health || true
    sudo nohup sh -c "sleep $((release + 25)); ifconfig $IF up" >/dev/null 2>&1 &
    sudo ifconfig "$IF" down
    echo "  $IF down: $(ifconfig "$IF" | head -1)"
    python3 ship/demo/firstopen-capture.py capture --udid "$UDID" --label "$leg" --dir "$dir" --window "$window" --launch-args="$args" --release-at "$release" --release-cmd "sudo ifconfig $IF up"
    sudo ifconfig "$IF" up
    local w
    for w in $(seq 1 45); do curl -s -m 3 -o /dev/null https://scrollanytime.com/health && break; [ "$w" = 20 ] && sudo ipconfig set "$IF" DHCP; sleep 2; done
    echo "  $IF back: $(ifconfig "$IF" | awk '/inet /{print $2}' | head -1); the network answered after ~$((w * 2)) s"
  elif [ -n "$release" ]; then
    curl -s -m 8 -o /dev/null https://scrollanytime.com/health || true   # the name is in the host's cache
    net_block
    echo "  blocked: $(sudo pfctl -a firstopen -s rules 2>/dev/null | wc -l | tr -d ' ') rules on $IF"
    python3 ship/demo/firstopen-capture.py capture --udid "$UDID" --label "$leg" --dir "$dir" --window "$window" --launch-args="$args" --release-at "$release" --release-cmd "$RELEASE_CMD"
  else
    sudo dscacheutil -flushcache >/dev/null 2>&1 || true; sudo killall -HUP mDNSResponder >/dev/null 2>&1 || true
    net_lte
    echo "  shaped: $(sudo dnctl list 2>/dev/null | grep -E '^0000[12]:' | tr -s ' ' | tr '\n' ';')"
    python3 ship/demo/firstopen-capture.py capture --udid "$UDID" --label "$leg" --dir "$dir" --window "$window" --launch-args="$args" $REC_FLAG
  fi
  net_clear
  echo "  network cleared: $(sudo pfctl -a firstopen -s rules 2>/dev/null | wc -l | tr -d ' ') filter rules, $(sudo dnctl list 2>/dev/null | wc -l | tr -d ' ') dnctl lines"
  python3 ship/demo/firstopen-capture.py analyze --dir "$dir" --mode "$mode" --ocr "$OCR" > "$dir/verdict.json" 2>"$dir/analyze-errors.txt" || echo "  !! analysis failed: $(tail -3 "$dir/analyze-errors.txt")"
  cat "$dir/verdict.json" | sed 's/^/  /'
  echo "  timeline:"; sed 's/^/    /' "$dir/timeline.txt" 2>/dev/null | head -120
  python3 - "$dir" "$leg" "$OUT" <<'PY' >> "$RESULTS"
import json, os, shutil, sys
d, leg, out = sys.argv[1:4]
a = json.load(open(os.path.join(d, 'analysis.json')))
v = a['verdict']
import cv2
def keep(frame, what):
    if not frame: return None
    dst = os.path.join(out, 'shots', f'firstopen-{leg}-{what}.png')
    img = cv2.imread(os.path.join(d, 'frames', frame))
    if img is not None: cv2.imwrite(dst, img)
    return os.path.basename(dst)
shots = {}
for key in ('first_frame', 'first_wall', 'first_welcome', 'first_lit'):
    if v.get(key): shots[key] = keep(v[key]['frame'], key.replace('_', '-'))
if a['frames']: shots['last'] = keep(a['frames'][-1]['file'], 'last')
json.dump({k: a[k] for k in a if k != 'frames'} | {'frames': [{x: f.get(x) for x in ('i', 'began_ms', 'returned_ms', 'lum', 'lit_frac', 'lit', 'wall', 'welcome', 'still_connecting', 'text')} for f in a['frames']]},
          open(os.path.join(out, 'ax', f'firstopen-{leg}.json'), 'w'))
print(json.dumps({'leg': leg, 'ran': True, 'launch_utc': a['launch_utc'], 'launch_args': a['launch_args'], 'verdict': v, 'shots': shots}))
PY
  tar -czf "$OUT/crash/firstopen-$leg-frames.tgz" -C "$dir" thumbs ocr capture.json analysis.json timeline.txt 2>/dev/null || true
  rm -rf "$dir/frames" "$dir/small"
  # the app's own words on this launch (its NSLog/WebKit lines), before the next erase takes them
  xcrun simctl spawn "$UDID" log show --last 2m --style compact --predicate 'processImagePath CONTAINS "pwa-shell" OR eventMessage CONTAINS "com.scrollanytime.app"' > "$OUT/crash/firstopen-$leg-app-log.txt" 2>&1 || true
}

build_old() {
  echo; echo "── building the shell from BEFORE the fix (control) ──"
  git apply ship/demo/firstopen-oldshell.patch || { echo "  the patch does not apply"; return 1; }
  local t0=$SECONDS
  set -o pipefail
  xcodebuild build -project ship/ios/pwa-shell.xcodeproj -scheme pwa-shell -configuration Release -sdk iphonesimulator \
    -destination "id=$UDID" -derivedDataPath ship/build/sim \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" > "$FO/old-build.txt" 2>&1
  local rc=$?
  git apply -R ship/demo/firstopen-oldshell.patch || true
  [ $rc -eq 0 ] || { grep -E "error:" "$FO/old-build.txt" | sort -u | head -8; return 1; }
  mkdir -p "$FO/app-old"; cp -R "$(find ship/build/sim/Build/Products -maxdepth 2 -name '*.app' | head -1)" "$FO/app-old/"
  APP_OLD="$FO/app-old/$(basename "$APP_BUILT")"
  echo "  built in $((SECONDS - t0)) s; the fix's path monitor in the old binary: $(grep -c 'com.scrollanytime.firstopen' "$APP_OLD/$EXE" 2>/dev/null) (0 = the old shell)"
}

LAST_LEG_S=0
for leg in $LEGS; do
  el=$(( $(date +%s) - T_START ))
  need=150; [ "$leg" = "C30" ] && need=190; case "$leg" in N*) need=260 ;; esac; [ "$leg" = "C1old" ] && need=260
  # a slow runner's legs take what the last one took (run 41451702694: ~7 min each on a 3-cpu runner, and the job's
  # 45-minute limit cancelled the walk before its summary)
  [ "$LAST_LEG_S" -gt "$need" ] && need=$((LAST_LEG_S + 30))
  if [ $((el + need)) -gt "$BUDGET_S" ]; then
    echo; echo "══ leg $leg NOT RUN: ${el}s of the walk's ${BUDGET_S}s budget used, it needs ~${need}s ══"
    echo "{\"leg\":\"$leg\",\"ran\":false,\"why\":\"time budget (${el}s used of ${BUDGET_S}s)\"}" >> "$RESULTS"
    continue
  fi
  t_leg=$(date +%s)
  run_leg "$leg" || true
  LAST_LEG_S=$(( $(date +%s) - t_leg ))
done
net_restore
trap - EXIT

# ── the summary ────────────────────────────────────────────────────────────────────────────────────────────────
python3 - "$RESULTS" <<'PY' | tee "$SUMMARY"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print('THE FIRST OPEN, MEASURED — per leg (times in ms after `simctl launch` was called; "seen by" = the screenshot that shows it returned)')
for r in rows:
    leg = r['leg']
    if not r.get('ran'):
        print(f'{leg:6} NOT RUN — {r.get("why")}'); continue
    v = r['verdict']; ff = v.get('first_frame')
    if leg.startswith('A'):
        if ff: print(f'{leg:6} launch {r["launch_utc"]}  feed first frame seen by {ff["seen_by_ms"]} ms (not before {ff["not_before_ms"]} ms)  {"PASS" if ff["seen_by_ms"] < 4000 else "FAIL"} (< 4000)  lum {ff["lum"]} | {ff["text"][:80]}')
        else: print(f'{leg:6} launch {r["launch_utc"]}  feed NOT reached in the window  FAIL  (welcome seen: {v.get("welcome_seen")})')
    elif leg.startswith('B'):
        if ff: print(f'{leg:6} launch {r["launch_utc"]}  welcome seen by {ff["seen_by_ms"]} ms (not before {ff["not_before_ms"]} ms)  {"PASS" if ff["seen_by_ms"] < 4000 else "OVER 4000"}  | {ff["text"][:80]}')
        else: print(f'{leg:6} launch {r["launch_utc"]}  welcome NOT reached in the window  FAIL')
    if leg[0] in 'AB':
        vid = v.get('video') or {}
        lv = vid.get('launch_visible') or {}; fd = vid.get('first_dark') or {}; fl = vid.get('first_lit') or {}
        print(f'{"":6} clock: {"recording (" + str(vid.get("frames")) + " frames, " + str(vid.get("source")) + " timestamps)" if vid else "screenshots"}; launch visible at {lv.get("ms")} ms, '
              f'dark launch still from {fd.get("ms")} ms, first lit frame {fl.get("ms")} ms (prev frame {fl.get("prev_frame_ms")} ms, lum {fl.get("lum")}); '
              f'final screen: {((v.get("final_screenshot") or {}).get("text") or "")[:70]}')
    else:
        rel = v.get('released_ms'); fw = v.get('first_welcome'); wa = v.get('welcome_after_release_ms')
        walls = v.get('wall_frames') or []; after = v.get('wall_after_release') or []
        print(f'{leg:6} launch {r["launch_utc"]}  released at {rel} ms; offline page seen in {len(walls)} frames (first {walls[0] if walls else "-"}), after the release in {len(after)}; '
              f'welcome seen by {fw["seen_by_ms"] if fw else "NEVER"} ms ({wa} ms after the release); last frame: {"WALL" if (v.get("last_frame") or {}).get("wall") else "welcome" if (v.get("last_frame") or {}).get("welcome") else "other"}')
        sc = v.get('still_connecting_frames') or []
        print(f'{"":6} "Still connecting…" on screen in {len(sc)} frames' + (f': first {sc[0][0]}-{sc[0][1]} ms at {sc[0][2]}, last {sc[-1][0]}-{sc[-1][1]} ms' if sc else ''))
PY
echo "first-open walk finished in $(( $(date +%s) - T_START )) s"
exit 0

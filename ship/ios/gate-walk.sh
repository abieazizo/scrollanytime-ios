#!/usr/bin/env bash
# THE RELEASE GATE'S WALK (the owner, 2026-11-02: "NOTHING DEPLOYS WITHOUT PASSING IT … One scripted real-user walk,
# on the iOS simulator with the real wrapper and a cleared install, on a throttled 4G profile, against the canary
# build"). Run by ship/demo/drive.sh when the marker ship/demo/walk-gate exists (a mirror branch only; nothing is
# signed or uploaded). The marker names the run:
#
#   run:      <gate run stamp>               version:  <Cloudflare Worker version id to pin, or empty = what is live>
#   sha:      <the commit that version must report at /version>
#   email:    gate+<id>@scrollanytime.com     code:     <its six digits, read from the lane by scripts/gate/run.mjs>
#
# THE PIN: every request the Simulator makes goes through mitmproxy on this runner, which adds
# `Cloudflare-Workers-Version-Overrides: zerem="<version>"` to each one to scrollanytime.com — the page, its
# scripts, the API, the media AND the service worker's own requests (a header set by a test harness never reaches
# those). The proxy's CA is trusted by the Simulator only. THE NETWORK: the perf harness's `lte` profile on the
# runner's interface (dummynet: 5000 kbit/s down, 1000 up, 40 ms each way), so the proxy's upstream is throttled.
#
# THE LEGS, each an XCUITest method (ship/ios/pwa-shellUITests/GateWalkUITests.swift) with the device set up first:
#   new       keychain reset, app deleted and installed: the first open, Google/Apple, email + the onboarding, the
#             three tips, 60 clips, the counting clip and the ask, Save / Save to Photos / WhatsApp / My Torah, the
#             four navigation sequences, Parsha, the rail's labels (memory sampled throughout)
#   relaunch  the app relaunched: still signed in, no tip again
#   reinstall app deleted and installed, the Keychain kept: a fresh install reaches the feed signed in
#   later     the runner's clock 48 hours ahead: still signed in
#   wiped     the whole web data store wiped at launch: still signed in
#   xxxl      Dynamic Type at its largest: no label clipped on Feed, My Torah, Rabbis, Profile
#   notch     (the owner, 2026-11-04) on a fresh iPhone 15 Pro and a fresh iPhone SE Simulator: the Rabbis tab scrolled
#             to the bottom, the search bar's top edge at or below the status bar and never moved, a screenshot each
#
# Output (the workflow uploads crash/*, shots/*.png, ax/*.json): crash/gate-checks.jsonl (one {name,pass,detail}
# a check), crash/gate-events.jsonl (everything the shell and the page reported, the shell's clock),
# crash/gate-memory.tsv, crash/gate-marks.tsv (the test's own moments), crash/gate-log.txt, shots/gate-*.png.
set -uo pipefail
cd "$(dirname "$0")/../.."
UDID="${UDID:?boot a simulator first}"
OUT="${OUT:-ship/build/demo}"
G="$OUT/gate"
mkdir -p "$G" "$OUT/shots" "$OUT/ax" "$OUT/crash"
LOG="$OUT/crash/gate-log.txt"
exec > >(tee -a "$LOG") 2>&1
MARK=ship/demo/walk-gate
val() { sed -n "s/^$1:[[:space:]]*//p" "$MARK" | head -1 | tr -d '\r'; }
RUN="$(val run)"; VERSION="$(val version)"; SHA="$(val sha)"; EMAIL="$(val email)"; CODE="$(val code)"
# notch FIRST (2026-11-06): the new leg takes ~18 min on this VM and the notch leg, last, had 12 s left (202611060011)
LEGS="$(val legs)"; LEGS="${LEGS:-new relaunch reinstall later wiped tour xxxl notch}"
APP_ID=com.scrollanytime.app
GATE_DIR=/tmp/sa-gate
CHECKS="$OUT/crash/gate-checks.jsonl"; : > "$CHECKS"
MARKS="$OUT/crash/gate-marks.tsv"; : > "$MARKS"
# the budget runs on the monotonic clock: the 48-hour leg moves the wall clock
mono() { python3 -c 'import time; print(int(time.monotonic()))'; }
T_START=$(mono)
BUDGET_S="${GATE_BUDGET_S:-1980}"   # the job has 45 minutes; ~8 go before this script and ~3 after it
# THE BUDGET IS THE JOB'S (deploy15, 2026-11-06): the runner's setup took 9 to 15 minutes before this script (deploy10's
# 14.7), so a fixed 33 minutes ran past the job's 45 and deploy15's record was never uploaded. The job's own age is the
# runner's worker process's: what is left of the 45 minutes, less 6 for the steps after this one, is the budget.
JOB_PID="$(pgrep -f 'Runner.Worker' | head -1)"
JOB_AGE="$( [ -n "$JOB_PID" ] && ps -o etime= -p "$JOB_PID" 2>/dev/null | python3 -c '
import sys
t = sys.stdin.read().strip()
if not t: sys.exit(0)
d = 0
if "-" in t: d, t = t.split("-"); d = int(d)
p = [int(x) for x in t.split(":")]
while len(p) < 3: p.insert(0, 0)
print(d * 86400 + p[0] * 3600 + p[1] * 60 + p[2])' 2>/dev/null)"
# A SECOND READING OF THE JOB'S AGE (2026-11-11, mirror run 42945824747: the walk ran six minutes past the budget this
# age gave it and the job's limit took the record). The checkout's own birth (.git, made in the job's first steps) is the
# other clock: the OLDER of the two is the job's age, and both are printed so the next overrun can be read.
GIT_AGE="$(python3 -c '
import os, time
a = int(time.time() - os.stat(".git").st_birthtime)
print(a if 0 < a < 2700 else "")' 2>/dev/null)"
echo "  the job's age: the runner's worker ${JOB_AGE:-unread} s, the checkout ${GIT_AGE:-unread} s"
if [ -n "$GIT_AGE" ] && { [ -z "$JOB_AGE" ] || [ "$GIT_AGE" -gt "$JOB_AGE" ]; }; then JOB_AGE="$GIT_AGE"; fi
if [ -z "${GATE_BUDGET_S:-}" ] && [ -n "$JOB_AGE" ]; then
  BUDGET_S=$(( 2700 - JOB_AGE - 360 ))
  echo "  the job is $(( JOB_AGE / 60 )) min $(( JOB_AGE % 60 )) s old: the walk's budget is $(( BUDGET_S / 60 )) min"
else
  echo "  the job's age could not be read: the walk's budget is the fixed $(( BUDGET_S / 60 )) min"
fi
# THE WALK ENDS ITSELF IN TIME TO UPLOAD (2026-11-11, mirror run 42945824747, gate run 202611110223-7e3c6b): the walk
# step was still running 37 minutes in, past its own budget, when the job's 45-minute limit stopped it: no upload step
# ran, no record came back, and a build whose every other check had passed was refused on a walk nobody saw. Only the
# leg's xcodebuild had a bound (run_for); a simctl, xcresulttool or sntp call that hangs on a bad VM had none. This
# watchdog counts the same monotonic budget: once it is spent it ends whatever of those is still running, every 10 s,
# until the script reaches its end (cleanup ends the watchdog), so the record is uploaded and an unfinished leg is a
# FAIL row ("leg … ran"), never a silence.
(
  while [ $(( $(mono) - T_START )) -lt $(( BUDGET_S + 30 )) ]; do sleep 15 >/dev/null 2>&1; done
  echo "::warning::the walk's budget is spent ($(( BUDGET_S / 60 )) min): ending what is still running so the record is uploaded"
  SIG=TERM
  while :; do
    pkill "-$SIG" -x xcodebuild >/dev/null 2>&1
    pkill "-$SIG" -x xcresulttool >/dev/null 2>&1
    pkill "-$SIG" -f 'simctl (io|install|uninstall|keychain|privacy|terminate|bootstatus|boot|shutdown|delete|create|ui) ' >/dev/null 2>&1
    sudo pkill "-$SIG" -x sntp >/dev/null 2>&1
    sudo pkill "-$SIG" -x systemsetup >/dev/null 2>&1
    SIG=KILL
    sleep 10 >/dev/null 2>&1
  done
) &
DOG_PID=$!
check() { # name, 1|0, detail
  python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"pass":sys.argv[2]=="1","detail":sys.argv[3][:1500]}))' "$1" "$2" "${3:-}" >> "$CHECKS"
  echo "  CHECK $([ "$2" = 1 ] && echo PASS || echo FAIL)  $1  ${3:-}"
}
echo "── THE RELEASE GATE'S WALK ── run ${RUN:-?} · $(date -u +%FT%TZ)"
echo "  tree: $(git rev-parse --short=12 HEAD 2>/dev/null) · version ${VERSION:-(live)} · sha ${SHA:-?} · legs: $LEGS"
echo "  runner: $(sw_vers -productVersion) $(uname -m), $(sysctl -n hw.ncpu) cpus; $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"
pkill -f idb_companion >/dev/null 2>&1 || true

# ── the build: the real shell (Release, ad-hoc) and its XCUITest, on the derived data the workflow already filled ─
DD=ship/build/sim
set -o pipefail
if ! xcodebuild build-for-testing \
    -project ship/ios/pwa-shell.xcodeproj -scheme pwa-shell -configuration Release \
    -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath "$DD" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" > "$G/build.log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$G/build.log" | head -40
  tail -20 "$G/build.log"
  check "the walk builds" 0 "xcodebuild build-for-testing failed: $(grep -m1 'error:' "$G/build.log")"
  exit 1
fi
set +o pipefail
XCTESTRUN="$(ls "$DD"/Build/Products/*.xctestrun | head -1)"
APP="$(find "$DD/Build/Products" -maxdepth 2 -name '*.app' ! -name '*Runner.app' | head -1)"
RUNNER="$(find "$DD/Build/Products" -maxdepth 2 -name '*Runner.app' | head -1)"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
echo "  built $(basename "$APP") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")), executable $EXE"

# ── the pin ─────────────────────────────────────────────────────────────────────────────────────────────────────
PROXY_PID=""; PROXY_ON=0
SERVICES="$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')"
proxy_off() {
  [ "$PROXY_ON" = 1 ] || return 0
  while IFS= read -r svc; do [ -n "$svc" ] && { sudo networksetup -setwebproxystate "$svc" off; sudo networksetup -setsecurewebproxystate "$svc" off; } >/dev/null 2>&1; done <<< "$SERVICES"
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" >/dev/null 2>&1
  PROXY_ON=0
}
if [ -n "$VERSION" ]; then
  echo "── the pin: every request → zerem version $VERSION ──"
  python3 -m pip install --quiet --break-system-packages mitmproxy >/dev/null 2>&1 || python3 -m pip install --quiet mitmproxy >/dev/null 2>&1
  cat > "$G/pin.py" <<'PY'
import os
V = os.environ["GATE_VERSION"]
N = {"pinned": 0}
def request(flow):
    h = flow.request.pretty_host
    if h == "scrollanytime.com" or h.endswith(".scrollanytime.com"):
        flow.request.headers["Cloudflare-Workers-Version-Overrides"] = f'zerem="{V}"'
        N["pinned"] += 1
        if N["pinned"] % 25 == 1:
            open(os.environ["GATE_PIN_COUNT"], "w").write(str(N["pinned"]))
# THE PROXY'S OWN VIDEO TIMES (deploy17, 2026-11-07): 47 of the sixty were left with no byte buffered in 5 s while the
# shaped path measured 3-4 Mbit/s before the walk. Every video request's time through the proxy and its size, so a
# walk says whether the bytes came late to the proxy, from the proxy, or never
# …AND THE HLS ONES (deploy21, 2026-11-08): the feed plays HLS, so the record held six MP4 lines of a walk that left 72
# clips with no byte; every playlist and segment is timed now, and the gate reads the upstream first byte to tell a
# stalled VM from a build (run.mjs mediaUnfit)
def response(flow):
    # EVERY REQUEST, NOT ONLY MEDIA (deploy22, 2026-11-08): the welcome came 11.6 s after the document where the same
    # app code read 2.6-6.6 s, and nothing said which request the onboarding's first screen waited for (its hero, a
    # font, the boot). The judge reads media from this file by path (run.mjs mediaStalls).
    if True:
        try:
            ms = (flow.response.timestamp_end - flow.request.timestamp_start) * 1000
            first = ((flow.response.timestamp_start or flow.request.timestamp_start) - flow.request.timestamp_start) * 1000
            with open(os.environ["GATE_PIN_COUNT"] + ".video.tsv", "a") as f:
                f.write(f"{int(flow.request.timestamp_start * 1000)}\t{flow.response.status_code}\t{int(first)}\t{int(ms)}\t{len(flow.response.raw_content or b'')}\t{flow.request.path[:120]}\n")
        except Exception:
            pass
def done():
    open(os.environ["GATE_PIN_COUNT"], "w").write(str(N["pinned"]))
PY
  GATE_VERSION="$VERSION" GATE_PIN_COUNT="$G/pinned.txt" mitmdump -q --listen-host 127.0.0.1 --listen-port 8080 -s "$G/pin.py" \
    --set stream_large_bodies=256k --set block_global=false > "$G/mitm.log" 2>&1 &
  PROXY_PID=$!
  # THE PROXY FIRST ON THE CPU (deploy17, 2026-11-07): every byte the Simulator plays passes through this one Python
  # process, which decrypts and re-encrypts it on the same 2-core VM as the Simulator, WebKit and the test runner.
  # Starved, it delivered nothing for seconds (deploy12's first document took 33.6 s through it; deploy17's sixty
  # left 47 clips with no byte buffered in 5 s, on a path that measured 3-4 Mbit/s before the walk began). The proxy
  # is the harness, not the app: it runs at the highest priority, so what the walk times is the build.
  sudo renice -n -20 -p "$PROXY_PID" >/dev/null 2>&1 && echo "  the proxy (pid $PROXY_PID) runs at priority -20" || echo "::warning::the proxy's priority could not be raised"
  for i in $(seq 40); do [ -f ~/.mitmproxy/mitmproxy-ca-cert.pem ] && nc -z 127.0.0.1 8080 2>/dev/null && break; sleep 0.5; done
  xcrun simctl keychain "$UDID" add-root-cert ~/.mitmproxy/mitmproxy-ca-cert.pem || echo "::warning::the proxy's CA could not be added to the Simulator"
  while IFS= read -r svc; do [ -n "$svc" ] && { sudo networksetup -setwebproxy "$svc" 127.0.0.1 8080; sudo networksetup -setsecurewebproxy "$svc" 127.0.0.1 8080; } >/dev/null 2>&1; done <<< "$SERVICES"
  PROXY_ON=1
  GOT="$(curl -s -m 20 -x http://127.0.0.1:8080 --cacert ~/.mitmproxy/mitmproxy-ca-cert.pem https://scrollanytime.com/version)"
  echo "  /version through the pin: $GOT"
  case "$GOT" in *"\"sha\":\"$SHA"*) check "the walk is pinned to build ${SHA:0:8}" 1 "version $VERSION answers $SHA through the proxy";;
    *) check "the walk is pinned to build ${SHA:0:8}" 0 "through the proxy /version said: ${GOT:0:200}";; esac
else
  GOT="$(curl -s -m 20 https://scrollanytime.com/version)"
  echo "  no pin: the walk is on what is live: $GOT"
  case "$GOT" in *"\"sha\":\"$SHA"*) check "the walk is on build ${SHA:0:8}" 1 "live answers $SHA";;
    *) check "the walk is on build ${SHA:0:8}" 0 "live /version said: ${GOT:0:200}";; esac
fi

# ── the runner's own link first (2026-11-06): a VM whose upstream cannot carry 5 Mbit/s cannot walk lte ──────────
# deploy3's walk (run 202611052220) measured 956 kbit/s THROUGH a 5000 kbit/s pipe: the runner's link, not the shaping —
# and every timed check downstream failed with it (the first screen 51 s, the feed 79 s). A reading like that convicts
# nothing: it is written to crash/gate-unfit.txt and the walk stops here; scripts/gate/run.mjs reads the file and
# dispatches the walk again on another VM. Three samples, the best one counts (one slow TCP start is not a slow link).
RAW_BEST=0
for i in 1 2 3; do
  RAW="$(curl -s -m 20 -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=2000000' 2>/dev/null || echo 0)"
  RAW_K="$(python3 -c "print(round(float('${RAW:-0}')*8/1000))")"
  [ "$RAW_K" -gt "$RAW_BEST" ] && RAW_BEST="$RAW_K"
done
echo "  the runner's own link: $RAW_BEST kbit/s down (best of 3 × 2 MB)"
if [ "$RAW_BEST" -lt 8000 ]; then
  echo "the runner's link is $RAW_BEST kbit/s down: it cannot carry the lte profile (5000 kbit/s). Unfit: the gate re-dispatches the walk." | tee "$OUT/crash/gate-unfit.txt"
  check "the runner's link can carry lte" 0 "$RAW_BEST kbit/s down unshaped (lte needs 5000; the walk was not run on this VM)"
  exit 0
fi
check "the runner's link can carry lte" 1 "$RAW_BEST kbit/s down unshaped"

# ── the network: lte, as the perf harness shapes it ─────────────────────────────────────────────────────────────
IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"; IF="${IF:-en0}"
PF_TOKEN=""
{ cat /etc/pf.conf; echo 'dummynet-anchor "gate"'; echo 'anchor "gate"'; } > "$G/pf.conf"
net_restore() {
  sudo pfctl -a gate -F all >/dev/null 2>&1 || true
  sudo dnctl -q flush >/dev/null 2>&1 || true
  sudo pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  [ -n "$PF_TOKEN" ] && sudo pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
  PF_TOKEN=""
}
CLOCK_MOVED=0
clock_restore() {
  [ "$CLOCK_MOVED" = 1 ] || return 0
  sudo sntp -sS time.apple.com >/dev/null 2>&1 || sudo sntp -sS pool.ntp.org >/dev/null 2>&1 || true
  sudo systemsetup -setusingnetworktime on >/dev/null 2>&1 || true
  CLOCK_MOVED=0; CLOCK_SHIFT=0
  echo "  clock restored: $(date -u +%FT%TZ)"
}
cleanup() {
  [ -n "${FIT_PID:-}" ] && kill "$FIT_PID" >/dev/null 2>&1   # the new leg's fit watch, if the script ends under it
  clock_restore
  net_restore
  proxy_off
  xcrun simctl ui "$UDID" content_size large >/dev/null 2>&1 || true
  kill "$DOG_PID" >/dev/null 2>&1 || true   # the budget watchdog, last: it covers the restores above too
}
trap cleanup EXIT
sudo pfctl -f "$G/pf.conf" >/dev/null 2>&1 || true
PF_TOKEN="$(sudo pfctl -E 2>&1 | awk '/Token/{print $NF}')"
sudo dnctl pipe 1 config bw 5000Kbit/s delay 40
sudo dnctl pipe 2 config bw 1000Kbit/s delay 40
# NO HTTP/3 (2026-11-04): network.framework makes QUIC connections AROUND a configured HTTP proxy — the 11-03 walk's
# log: "Connected Path: satisfied … proxy", then QUIC straight to Cloudflare's address, 6 MB of video in one of them,
# not one connection to :8080. With UDP 443 dropped every request falls back to TCP, which takes the proxy (the pin).
printf 'dummynet in quick on %s all pipe 1\ndummynet out quick on %s all pipe 2\n%s\n' "$IF" "$IF" \
  "$([ "$PROXY_ON" = 1 ] && echo 'block drop out quick proto udp from any to any port 443')" | sudo pfctl -a gate -f - 2>&1 | grep -v -i altq || true
# THE SHAPED LINK, THREE TRIES; ONE THAT CARRIES NOTHING IS AN UNFIT VM (2026-11-11, run 202611110534-9a5160). That run's
# VM read 0 kbit/s here in its one try (its raw link 186811), and then nothing of the sign-in worked on it: iOS never
# asked for Google's hand-off in 60 s, and the app's email step said "Could not send the email" (the app's fallback line,
# shown only for an answer that is not the Worker's JSON). The four VMs of run 202611102249-09c747 read 3913 to 4088 here
# and did both; the same pinned build signed in by email on the 9a5160 tour's runner. One try only wrote a FAIL row and
# walked on. Now: best of three, each try's HTTP status and curl exit in the log; a best of 0 is written to
# crash/gate-unfit.txt and the walk stops (run.mjs walks it again on another VM, up to its MAX_VMS). A reading that is not 0
# and outside 3000 to 5600 stays the FAIL row it was.
SHAPED_BEST=0; SHAPED_TRIES=""
for i in 1 2 3; do
  R="$(curl -s -m 15 -o /dev/null -w '%{speed_download} %{http_code}' 'https://speed.cloudflare.com/__down?bytes=1000000' 2>/dev/null)"; RC=$?
  S_K="$(python3 -c "
import sys
p = (sys.argv[1].split() + ['0', '000'])[:2]
try: print(round(float(p[0]) * 8 / 1000) if p[1] == '200' else 0)
except Exception: print(0)" "$R" 2>/dev/null)"
  S_K="${S_K:-0}"
  SHAPED_TRIES="$SHAPED_TRIES${SHAPED_TRIES:+, }$S_K kbit/s (HTTP ${R##* }, curl exit $RC)"
  [ "$S_K" -gt "$SHAPED_BEST" ] && SHAPED_BEST="$S_K"
done
echo "  shaped on $IF: 1 MB down at $SHAPED_BEST kbit/s (best of 3: $SHAPED_TRIES)"
if [ "$SHAPED_BEST" -eq 0 ]; then
  echo "the shaped link carried nothing in three tries ($SHAPED_TRIES) through the 5000 kbit/s pipe, on a runner whose own link read $RAW_BEST kbit/s. Unfit: the gate re-dispatches the walk." | tee "$OUT/crash/gate-unfit.txt"
  check "the walk runs on throttled 4G" 0 "the shaped link measured 0 kbit/s down in three tries (lte is 5000; the walk was not run on this VM)"
  exit 0
fi
if [ "$SHAPED_BEST" -ge 3000 ] && [ "$SHAPED_BEST" -le 5600 ]; then
  check "the walk runs on throttled 4G" 1 "dummynet lte (5000/1000 kbit/s, 80 ms): measured $SHAPED_BEST kbit/s down (best of 3)"
else
  check "the walk runs on throttled 4G" 0 "the shaped link measured $SHAPED_BEST kbit/s down (lte is 5000; tries: $SHAPED_TRIES)"
fi

# ── the walk's own path (deploy12, 11-06): shaped AND through the pinning proxy, to scrollanytime.com ─────────────
# The two readings above go to speed.cloudflare.com around the proxy. deploy12's VM passed both, and then the shell's
# first document took 33.6 s through the proxy (live's controls: 1.6–9.1 s) and no clip buffered a byte in 5 s. Here the
# page and its biggest script come the way the Simulator gets them, best of 3: a page over 8 s, or the script under
# 1000 kbit/s, is a VM that cannot judge timings — unfit, walked again elsewhere (scripts/gate/run.mjs also reads the
# first document's time from the record afterwards, over 20 s = unfit).
if [ "$PROXY_ON" = 1 ]; then
  PX=(-x http://127.0.0.1:8080 --cacert ~/.mitmproxy/mitmproxy-ca-cert.pem)
  DOC_BEST=999; JS_BEST=0; JS=""
  for i in 1 2 3; do
    T="$(curl -s -m 30 "${PX[@]}" -o "$G/doc.html" -w '%{time_total}' 'https://scrollanytime.com/?app=ios' 2>/dev/null || echo 999)"
    DOC_BEST="$(python3 -c "import sys; print(min(float(sys.argv[1]), float(sys.argv[2] or 999)))" "$DOC_BEST" "$T")"
    [ -z "$JS" ] && JS="$(grep -oE '/assets/[^"]+\.js' "$G/doc.html" 2>/dev/null | head -1)"
    if [ -n "$JS" ]; then
      S="$(curl -s -m 30 "${PX[@]}" -H 'cache-control: no-cache' -o /dev/null -w '%{speed_download}' "https://scrollanytime.com$JS?fit=$i" 2>/dev/null || echo 0)"
      K="$(python3 -c "print(round(float('${S:-0}')*8/1000))")"
      [ "$K" -gt "$JS_BEST" ] && JS_BEST="$K"
    fi
  done
  echo "  the walk's path (shaped, through the pin): the page in ${DOC_BEST} s, its script ${JS:-?} at $JS_BEST kbit/s (best of 3)"
  if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > 8 or int(sys.argv[2]) < 1000 else 1)" "$DOC_BEST" "$JS_BEST"; then
    echo "the walk's own path is too slow to judge timings: the page in ${DOC_BEST} s, the script at $JS_BEST kbit/s through the proxy. Unfit: the gate re-dispatches the walk." | tee "$OUT/crash/gate-unfit.txt"
    check "the walk's path can carry lte" 0 "the page in ${DOC_BEST} s, the script at $JS_BEST kbit/s (shaped, through the pin; the walk was not run on this VM)"
    exit 0
  fi
  check "the walk's path can carry lte" 1 "the page in ${DOC_BEST} s, the script ${JS:-?} at $JS_BEST kbit/s (shaped, through the pin, best of 3)"
  # THE API THROUGH THE PIN, BEFORE THE WALK LEANS ON IT (2026-11-11, run 202611110534-9a5160): the page and its script
  # came through that VM's pin and then the email step's request did not come back as the Worker's answer. An EMPTY
  # sign-in request is answered by any build's validator with a 400 in JSON (nothing is sent, nothing is counted, no row
  # is written). Three tries; an answer that is JSON is the Worker's, whatever its status, and the walk goes on. No JSON
  # in three tries is a path that does not carry the app's requests on this VM: unfit, walked again elsewhere.
  API_OK=0; API_TRIES=""
  for i in 1 2 3; do
    A="$(curl -s -m 20 "${PX[@]}" -X POST -H 'content-type: application/json' -d '{}' -o "$G/api-probe.txt" -w '%{http_code} %{content_type}' 'https://scrollanytime.com/auth/request-code' 2>/dev/null)"; ARC=$?
    API_TRIES="$API_TRIES${API_TRIES:+; }HTTP ${A:-none} (curl exit $ARC): $(head -c 120 "$G/api-probe.txt" 2>/dev/null | tr '\n' ' ')"
    case "$A" in *application/json*) grep -q '"error"' "$G/api-probe.txt" 2>/dev/null && { API_OK=1; break; } ;; esac
    sleep 2
  done
  echo "  the app's API (shaped, through the pin): $API_TRIES"
  if [ "$API_OK" != 1 ]; then
    echo "the app's API did not answer through the pin in three tries ($API_TRIES). Unfit: the gate re-dispatches the walk." | tee "$OUT/crash/gate-unfit.txt"
    check "the walk's path carries the app's requests" 0 "no answer from the Worker to an empty sign-in request in three tries (the walk was not run on this VM)"
    exit 0
  fi
  check "the walk's path carries the app's requests" 1 "an empty sign-in request was answered by the Worker in JSON (shaped, through the pin)"
fi

# ── memory, sampled the whole walk: the app and its web content process (phys_footprint, MB) ───────────────────
MEM="$OUT/crash/gate-memory.tsv"; : > "$MEM"
cat > "$G/mem.py" <<'PY'
# every 2 s: epoch ms, the app's pid, its footprint, its web content process's footprint (MB), the content pids
import re, subprocess, sys, time
app_pat, out = sys.argv[1], sys.argv[2]
def pids(pat):
    r = subprocess.run(['pgrep', '-f', pat], capture_output=True, text=True)
    return [p for p in r.stdout.split() if p.isdigit()]
def mb(pid):
    r = subprocess.run(['footprint', '-p', pid], capture_output=True, text=True)
    m = re.search(r'[Ff]ootprint:\s*([\d.]+)\s*([KMG])B', r.stdout)
    if m:
        v = float(m.group(1))
        return v / 1024 if m.group(2) == 'K' else v * 1024 if m.group(2) == 'G' else v
    r = subprocess.run(['ps', '-o', 'rss=', '-p', pid], capture_output=True, text=True)
    return float(r.stdout.strip() or 0) / 1024
while True:
    a = pids(app_pat)
    w = pids('CoreSimulator.*com.apple.WebKit.WebContent')
    am = mb(a[0]) if a else 0
    wm = max([mb(p) for p in w] or [0])
    with open(out, 'a') as f:
        f.write(f"{int(time.time()*1000)}\t{a[0] if a else ''}\t{am:.1f}\t{wm:.1f}\t{','.join(w)}\n")
    time.sleep(2)
PY
python3 "$G/mem.py" "$(basename "$APP")/$EXE" "$MEM" &
MEM_PID=$!

# ── THE RUNNER'S CPU IS READ IN THE WALK'S FIRST MINUTE, NOT AFTER IT (2026-11-11, gate run 202611110738-cff008) ──
# scripts/gate/run.mjs holds three lines for the new leg's VM: the shell's first document over 20 s after launch, the
# app's script over 1.5 s after its document, the test runner over 20 s to start the app. It read them from the record
# AFTER the whole walk: that run's three runners read 2.63 s, 3.11 s and 21.5 s, each walked 25 to 37 minutes first, and
# the gate spent 97 minutes on walks it then threw away (five of the seven main-walk runners of 11-10/11 were unfit by
# these lines; every one of the readings was in the record 6 to 15 s after launch, the runner's start by the welcome).
# This watch reads the same three from the host record and the leg's own log while the leg runs, with the same numbers
# and the same sentences, only on readings that EXIST (a document that never came is not judged here, as it is not
# there). On the first one over its line it writes crash/gate-unfit.txt and ends the leg's xcodebuild; the walk stops,
# the record goes up, and run.mjs dispatches the next runner. run.mjs still reads the three afterwards, unchanged.
cat > "$G/fit.py" <<'PY'
import json, re, subprocess, sys, time
events, log, out = sys.argv[1:4]
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')   # the sentences carry an en dash; a C locale must not stop the watch
except Exception:
    pass
def readings():
    ev = []
    try:
        with open(events, errors='ignore') as f:
            for line in f:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if isinstance(e, dict) and isinstance(e.get('t'), (int, float)):
                    ev.append(e)
    except OSError:
        pass
    launch = next((e for e in ev if e.get('ev') == 'launch'), None)
    doc = next((e for e in ev if e.get('ev') == 'doc' and e['t'] > launch['t']), None) if launch else None
    build = next((e for e in ev if e.get('ev') == 'build' and e['t'] > doc['t']), None) if doc else None
    start = None
    try:
        with open(log, errors='ignore') as f:
            for line in f:
                if 'SA-GATE-CHECK' in line:
                    m = re.search(r'test runner took (\d+) ms', line)
                    if m:
                        start = int(m.group(1))
                        break
    except OSError:
        pass
    return (doc['t'] - launch['t'] if doc else None, build['t'] - doc['t'] if build else None, start)
while True:
    doc, js, start = readings()
    why = None
    if doc is not None and doc > 20000:
        why = f"the shell's first document came {doc / 1000:.1f} s after launch through the proxy (live's controls 1.6–9.1 s; over 20 s the VM cannot judge timings). Unfit: the gate re-dispatches the walk."
    elif js is not None and js > 1500:
        why = f"the app's script started {js / 1000:.2f} s after its document (live's controls 0.41–0.58 s; over 1.5 s the VM's CPU cannot judge timings). Unfit: the gate re-dispatches the walk."
    elif start is not None and start > 20000:
        why = f"the test runner took {start / 1000:.1f} s to start the app on the fresh install (live's controls 3.0–12.2 s; over 20 s the VM cannot judge timings). Unfit: the gate re-dispatches the walk."
    if why:
        with open(out, 'w', encoding='utf-8') as f:
            f.write(why)
        print(f"  the fit watch: {why}", flush=True)
        for sig in ('-TERM', '-KILL'):
            try:
                subprocess.run(['pkill', sig, '-x', 'xcodebuild'], capture_output=True)
            except Exception:
                pass
            time.sleep(10)
        sys.exit(0)
    if doc is not None and js is not None and start is not None:
        print(f"  the fit watch: the runner can judge timings (first document {doc} ms after launch, script {js} ms after it, test runner start {start} ms)", flush=True)
        sys.exit(0)
    time.sleep(1)
PY
FIT_PID=""

# ── one leg ────────────────────────────────────────────────────────────────────────────────────────────────────
CLOCK_SHIFT=0   # while the clock is moved 48 hours ahead, the budget still counts real time
# macOS has no `timeout`: perl's alarm ends the command after N seconds (SIGALRM), exactly as timeout would
run_for() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
leg() { # name, test method, extra launch flags for the test (TEST_RUNNER_GATE_FLAGS)
  local name="$1" method="$2" flags="${3:-}"
  local left=$(( BUDGET_S - ($(mono) - T_START) ))
  if [ "$left" -lt 120 ]; then check "leg $name ran" 0 "not run: the job's time ran out (${left}s left)"; return; fi
  echo "── leg $name → $method ($(( left / 60 )) min left)"
  printf '%s\tleg-start\t%s\n' "$(python3 -c 'import time; print(int(time.time()*1000))')" "$name" >> "$MARKS"
  local started; started=$(date +%s)
  if [ "$name" = new ]; then
    python3 "$G/fit.py" "$GATE_DIR/events.jsonl" "$G/$name.log" "$OUT/crash/gate-unfit.txt" &
    FIT_PID=$!
  fi
  TEST_RUNNER_GATE_EMAIL="$EMAIL" TEST_RUNNER_GATE_CODE="$CODE" TEST_RUNNER_GATE_DIR="$GATE_DIR" TEST_RUNNER_GATE_FLAGS="$flags" \
  TEST_RUNNER_GATE_LEG="$name" TEST_RUNNER_GATE_SHA="$SHA" TEST_RUNNER_GATE_PROXY="$([ "$PROXY_ON" = 1 ] && echo 127.0.0.1:8080)" \
  TEST_RUNNER_GATE_SAMPLE_DWELL_S="${GATE_SAMPLE_DWELL_S:-20}" \
    run_for "$(( left - 45 ))" xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=${LEG_UDID:-$UDID}" \
    ${LEG_UDID2:+-destination "id=$LEG_UDID2"} ${LEG_UDID2:+-maximum-concurrent-test-simulator-destinations 2} \
    -only-testing:"pwa-shellUITests/GateWalkUITests/$method" \
    -resultBundlePath "$G/$name.xcresult" > "$G/$name.log" 2>&1
  local code=$?
  if [ -n "$FIT_PID" ]; then kill "$FIT_PID" >/dev/null 2>&1; wait "$FIT_PID" 2>/dev/null; FIT_PID=""; fi
  # the test's checks and moments, as it printed them
  grep -o 'SA-GATE-CHECK .*' "$G/$name.log" | sed 's/^SA-GATE-CHECK //' >> "$CHECKS"
  grep -o 'SA-GATE-MARK .*' "$G/$name.log" | sed 's/^SA-GATE-MARK //' >> "$MARKS"
  grep -E "SA-GATE-CHECK|error: |Test Case .* (passed|failed)|Executed" "$G/$name.log" | sed 's/^/   /' | cut -c1-300 | head -80
  # the fit watch ended this leg: one row that says so, no attachments from a walk nobody will judge
  if [ "$name" = new ] && [ -f "$OUT/crash/gate-unfit.txt" ]; then
    check "leg $name ran" 0 "ended early on an unfit runner: $(cut -c1-300 "$OUT/crash/gate-unfit.txt")"
    echo "   leg $name: ended after $(( $(date +%s) - started )) s (exit $code)"
    return
  fi
  if ! grep -q "Test Case .* \(passed\|failed\)" "$G/$name.log"; then
    check "leg $name ran" 0 "the XCUITest did not finish (exit $code): $(grep -m1 -E 'error:|Terminating|crash' "$G/$name.log" | cut -c1-200)"
  fi
  # bounded since 2026-11-11 (see the budget watchdog above): a hung Simulator call ate the rest of the walk
  run_for 60 xcrun simctl io "${LEG_UDID:-$UDID}" screenshot "$OUT/shots/gate-$name-end.png" >/dev/null 2>&1 || true
  if run_for 240 xcrun xcresulttool export attachments --path "$G/$name.xcresult" --output-path "$G/att-$name" >/dev/null 2>&1; then
    python3 - "$G/att-$name" "$OUT/shots" "$name" <<'PY' || true
import json, os, shutil, sys
src, out, name = sys.argv[1:4]
try:
    manifest = json.load(open(os.path.join(src, 'manifest.json')))
except Exception:
    manifest = []
n = 0
for test in manifest:
    for a in test.get('attachments', []):
        f = a.get('exportedFileName')
        label = (a.get('suggestedHumanReadableName') or f or 'shot').split('_0_')[0].replace(' ', '-').replace('/', '-')
        if f and os.path.exists(os.path.join(src, f)) and f.lower().endswith('.png'):
            n += 1
            shutil.copy(os.path.join(src, f), os.path.join(out, f'gate-{name}-{n:02d}-{label}.png'))
print(f'   {n} screenshots from {name}')
PY
  fi
  echo "   leg $name: exit $code in $(( $(date +%s) - started )) s"
}

reinstall() { # keep|reset — the Keychain
  xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1 || true
  [ "$1" = reset ] && xcrun simctl keychain "$UDID" reset >/dev/null 2>&1
  # the pin's CA goes with a keychain reset: put it back
  [ "$1" = reset ] && [ "$PROXY_ON" = 1 ] && xcrun simctl keychain "$UDID" add-root-cert ~/.mitmproxy/mitmproxy-ca-cert.pem >/dev/null 2>&1
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl install "$UDID" "$RUNNER" >/dev/null 2>&1 || true
  xcrun simctl privacy "$UDID" grant photos-add "$APP_ID" >/dev/null 2>&1 || true
}

# THE NOTCH LEG's devices: a fresh Simulator of each on the runner's own runtime, the pin's CA trusted, the app installed
notch_device() { # display name, device type id(s) to try: prints the new UDID
  local name="$1"; shift
  local rt t u
  rt="$(xcrun simctl list devices -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
print(next((k for k,v in d.items() for x in v if x['udid']=='$UDID'), ''))")"
  for t in "$@"; do
    u="$(xcrun simctl create "gate-notch-$name" "$t" "$rt" 2>/dev/null)" && [ -n "$u" ] && { echo "$u"; return 0; }
  done
  return 1
}
# ONE PHONE AT A TIME, ON ITS OWN WALK (2026-11-06). Both phones in one concurrent xcodebuild (7bc1169a) never produced a
# reading: on deploy7's VM the test exited 0 in 102 s with nothing reported, on deploy8's the two boots took 20 minutes and
# the test ran out its alarm. The notch leg now has a walk of its own (scripts/gate/run.mjs WALK_GROUPS), so the phones go
# in turn, as on 11-05 when the 15 Pro passed: create, boot, install, test, delete — each inside the walk's budget.
notch_phone() { # display name, device type id(s)
  local name="$1"; shift
  local u left=$(( BUDGET_S - ($(mono) - T_START) ))
  if [ "$left" -lt 420 ]; then echo "  $name: not run, ${left}s left"; return; fi
  if ! u="$(notch_device "$name" "$@")"; then echo "  $name: the runner could not create the Simulator ($*)"; return; fi
  echo "  $name Simulator $u"
  xcrun simctl boot "$u" >/dev/null 2>&1 || true
  run_for 300 xcrun simctl bootstatus "$u" -b >/dev/null 2>&1 || echo "  $name: bootstatus did not answer in 300 s"
  [ "$PROXY_ON" = 1 ] && xcrun simctl keychain "$u" add-root-cert ~/.mitmproxy/mitmproxy-ca-cert.pem >/dev/null 2>&1
  xcrun simctl install "$u" "$APP"
  xcrun simctl install "$u" "$RUNNER" >/dev/null 2>&1 || true
  LEG_UDID="$u" leg "notch-$(echo "$name" | tr ' ' '-')" testRabbisHeaderNotch
  xcrun simctl io "$u" screenshot "$OUT/shots/gate-notch-$(echo "$name" | tr ' ' '-')-end.png" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
  xcrun simctl delete "$u" >/dev/null 2>&1 || true
}
notch_legs() {
  local n
  notch_phone "iPhone 15 Pro" com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro
  notch_phone "iPhone SE" com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation com.apple.CoreSimulator.SimDeviceType.iPhone-SE--2nd-generation-
  # a phone whose test never reported is a FAIL, never a silence
  for n in "iPhone 15 Pro" "iPhone SE"; do
    grep -q "\"$n: the Rabbis search bar stays below the status bar\"" "$CHECKS" \
      || check "$n: the Rabbis search bar stays below the status bar" 0 "no reading: the $n test did not report (see crash/notch-*.log)"
    grep -q "\"$n: the Rabbis search bar never moves on scroll\"" "$CHECKS" \
      || check "$n: the Rabbis search bar never moves on scroll" 0 "no reading: the $n test did not report (see crash/notch-*.log)"
  done
}

rm -rf "$GATE_DIR"; mkdir -p "$GATE_DIR"
for L in $LEGS; do
  # an unfit runner walks no further (the fit watch above): what it recorded still goes up below
  if [ -f "$OUT/crash/gate-unfit.txt" ]; then echo "  the runner is unfit: the legs from $L on are not walked on it"; break; fi
  case "$L" in
    new) reinstall reset; leg new testNewPerson ;;
    relaunch) leg relaunch testRelaunch ;;
    reinstall) reinstall keep; leg reinstall testFreshInstallReturning ;;
    later)
      sudo systemsetup -setusingnetworktime off >/dev/null 2>&1 || true
      AHEAD="$(python3 -c 'import time; print(time.strftime("%m%d%H%M%Y.%S", time.gmtime(time.time() + 48*3600)))')"
      if sudo date -u "$AHEAD" >/dev/null 2>&1; then
        CLOCK_MOVED=1; CLOCK_SHIFT=172800; echo "  the clock moved 48 hours ahead: $(date -u +%FT%TZ)"
        printf '%s\tclock\t+48h\n' "$(python3 -c 'import time; print(int(time.time()*1000))')" >> "$MARKS"
        leg later testAfter48Hours
        clock_restore
      else check "still signed in 48 hours later" 0 "the runner's clock could not be moved (sudo date refused)"; fi ;;
    wiped) leg wiped testStorageWiped "-saUITestWipeWebData" ;;
    # the signed-in tour (its own runner since deploy16): the same account by its email code on this runner's install
    tour)
      xcrun simctl privacy "$UDID" grant photos-add "$APP_ID" >/dev/null 2>&1 || true
      leg tour testSignedInTour ;;
    xxxl)
      xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large >/dev/null 2>&1 \
        && leg xxxl testDynamicTypeXXXL \
        || check "Dynamic Type xxxLarge clips no label" 0 "simctl could not set the content size"
      xcrun simctl ui "$UDID" content_size large >/dev/null 2>&1 || true ;;
    # THE SHABBAT LOCK'S SIMULATOR TEST (2026-11-07): thirty moments set in the app, the screen only on Shabbat
    lock) leg lock testShabbatLock ;;
    notch)
      # the walk's own phone rests meanwhile: two booted Simulators on a free runner starve each other
      xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
      notch_legs
      xcrun simctl boot "$UDID" >/dev/null 2>&1 || true ;;
  esac
done
kill "$MEM_PID" >/dev/null 2>&1 || true
cp "$GATE_DIR/events.jsonl" "$OUT/crash/gate-events.jsonl" 2>/dev/null || echo "::warning::no events were recorded at $GATE_DIR"
cp "$GATE_DIR/state.json" "$OUT/crash/gate-state.json" 2>/dev/null || true
[ -f "$G/pinned.txt" ] && echo "  requests pinned by the proxy: $(cat "$G/pinned.txt")" && cp "$G/pinned.txt" "$OUT/crash/gate-pinned.txt"
[ -f "$G/pinned.txt.video.tsv" ] && cp "$G/pinned.txt.video.tsv" "$OUT/crash/gate-video.tsv" && echo "  video requests through the proxy: $(wc -l < "$G/pinned.txt.video.tsv")"
cp "$G"/*.log "$OUT/crash/" 2>/dev/null || true
ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i -E "pwa-shell|$EXE|WebContent" | sed 's/^/  crash report: /' || true
cp ~/Library/Logs/DiagnosticReports/*.ips "$OUT/crash/" 2>/dev/null || true
N=$(wc -l < "$CHECKS" | tr -d ' '); F=$(grep -c '"pass": false' "$CHECKS" || true)
echo "── the walk: $N checks, $F failed ($(( ($(mono) - T_START) / 60 )) min) ──"
exit 0

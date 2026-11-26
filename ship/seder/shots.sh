#!/usr/bin/env bash
# Pictures from an iPhone simulator on the build machine: the countdown (drawn by the same view
# the Lock Screen uses), the app itself, and, if the simulator allows it, the real Lock Screen.
# They leave the machine as ship/build/shots.zip.log (the workflow only keeps .ipa and .log files).
set -uo pipefail
cd "$(dirname "$0")/../ios"
out="$(cd ../build && pwd)/shots"
mkdir -p "$out"

dev="$(xcrun simctl list devices available | grep -E 'iPhone 1[5-9]( Pro)? \(' | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
[ -n "$dev" ] || dev="$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
echo "simulator $dev: $(xcrun simctl list devices available | grep "$dev")"

xcodebuild build -project pwa-shell.xcodeproj -scheme pwa-shell -configuration Debug \
  -destination "platform=iOS Simulator,id=$dev" -derivedDataPath ../build/dd-sim \
  CODE_SIGNING_ALLOWED=NO > ../build/sim.log 2>&1 || { grep -E "error:" ../build/sim.log | sort -u | head -40; tail -30 ../build/sim.log; exit 1; }
app="$(find ../build/dd-sim/Build/Products -name 'Seder.app' -maxdepth 3 | head -1)"
echo "built $app"

xcrun simctl boot "$dev" || true
xcrun simctl bootstatus "$dev" -b
xcrun simctl status_bar "$dev" override --time "12:21" --batteryState charged --batteryLevel 100 --cellularBars 4 || true
xcrun simctl install "$dev" "$app"

# 1. The countdown view.
xcrun simctl launch "$dev" com.abieazizo.seder -sederDemo 1
sleep 6
xcrun simctl io "$dev" screenshot "$out/1-countdown.png"
xcrun simctl terminate "$dev" com.abieazizo.seder || true

# 2. The app itself: the live site inside the shell.
xcrun simctl launch "$dev" com.abieazizo.seder
sleep 14
xcrun simctl io "$dev" screenshot "$out/2-app.png"

# 3. A real countdown on the real Lock Screen, if this simulator will do it.
xcrun simctl terminate "$dev" com.abieazizo.seder || true
xcrun simctl launch "$dev" com.abieazizo.seder -sederDemo 1 -sederDemoLive 1
sleep 9
xcrun simctl spawn "$dev" log show --last 1m --predicate 'process == "Seder"' 2>/dev/null | grep -iE "seder\]|activit" | tail -15 || true
open -a Simulator --args -CurrentDeviceUDID "$dev" || true
sleep 8
osascript -e 'tell application "Simulator" to activate' -e 'delay 1' -e 'tell application "System Events" to keystroke "l" using command down' 2>&1 || echo "could not press the lock key"
sleep 5
xcrun simctl io "$dev" screenshot "$out/3-lock.png"
osascript -e 'tell application "System Events" to keystroke "h" using {command down, shift down}' 2>&1 || true
sleep 3
xcrun simctl io "$dev" screenshot "$out/4-after-wake.png"

cd "$out/.." && zip -qr shots.zip.log shots && ls -la shots shots.zip.log

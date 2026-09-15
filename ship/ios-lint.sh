#!/usr/bin/env bash
# ship/ios-lint.sh — re-verify the iOS shell against the PART 3.3 whitelist. Fails loudly.
#
# This runs on THIS machine (no Xcode needed) and again on the Mac inside mac-run.sh before the
# archive. It exists because the PWABuilder template ships with camera, microphone and location
# usage strings, two background modes and a push entitlement — every one of which is a rejection,
# and every one of which would come straight back if anyone ever re-pulled the template.
#
#   ./ship/ios-lint.sh
set -uo pipefail
cd "$(dirname "$0")/.."

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
fail=0
ok()   { printf "  ${G}OK${N}   %s\n" "$1"; }
bad()  { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
warn() { printf "  ${Y}warn${N} %s\n" "$1"; }

PLIST=ship/ios/pwa-shell/Info.plist
ENT=ship/ios/pwa-shell/Entitlements/Entitlements.plist
PBX=ship/ios/pwa-shell.xcodeproj/project.pbxproj
SETTINGS=ship/ios/pwa-shell/Settings.swift
WEBVIEW=ship/ios/pwa-shell/WebView.swift
VC=ship/ios/pwa-shell/ViewController.swift

printf "\n${B}iOS shell lint${N}\n\n"

for f in "$PLIST" "$ENT" "$PBX" "$SETTINGS" "$WEBVIEW" "$VC"; do
  [ -f "$f" ] || { bad "missing: $f"; }
done
[ "$fail" -gt 0 ] && { printf "\n${R}${B}the shell is not present — nothing else can be checked${N}\n\n"; exit 1; }

# ── 1. banned keys: anything the app does not use ──────────────────────────────────────────
printf "${B}capability whitelist${N}\n"
BANNED_PLIST=(
  UIBackgroundModes
  BGTaskSchedulerPermittedIdentifiers
  NSCameraUsageDescription
  NSMicrophoneUsageDescription
  NSPhotoLibraryUsageDescription
  NSPhotoLibraryAddUsageDescription
  NSLocationWhenInUseUsageDescription
  NSLocationAlwaysAndWhenInUseUsageDescription
  NSLocationAlwaysUsageDescription
  NSContactsUsageDescription
  NSCalendarsUsageDescription
  NSRemindersUsageDescription
  NSBluetoothAlwaysUsageDescription
  NSFaceIDUsageDescription
  NSMotionUsageDescription
  NSSpeechRecognitionUsageDescription
  NSHealthShareUsageDescription
  NSAppTransportSecurity
)
for k in "${BANNED_PLIST[@]}"; do
  if grep -q "<key>$k</key>" "$PLIST"; then
    bad "Info.plist declares $k — the app does not use it (2.5.4 / 5.1.1)"
  fi
done
[ "$fail" -eq 0 ] && ok "Info.plist declares none of the ${#BANNED_PLIST[@]} banned keys"

BANNED_ENT=(
  aps-environment
  com.apple.security.device.camera
  com.apple.security.device.audio-input
  com.apple.security.personal-information.location
  com.apple.security.print
  com.apple.security.app-sandbox
  com.apple.security.files.user-selected.read-write
  com.apple.developer.healthkit
  com.apple.developer.siri
)
entfail=0
for k in "${BANNED_ENT[@]}"; do
  if grep -q "<key>$k</key>" "$ENT"; then
    bad "entitlements declare $k — the app does not use it"
    entfail=1
  fi
done
[ "$entfail" -eq 0 ] && ok "entitlements declare none of the ${#BANNED_ENT[@]} banned keys"

# ── 2. required keys ───────────────────────────────────────────────────────────────────────
printf "\n${B}required${N}\n"
req_str() { # key, expected substring, why
  if grep -A1 "<key>$1</key>" "$PLIST" | grep -q "$2"; then ok "$1 = $2"
  else bad "$1 must be $2 — $3"; fi
}
grep -q "<key>ITSAppUsesNonExemptEncryption</key>" "$PLIST" && grep -A1 "<key>ITSAppUsesNonExemptEncryption</key>" "$PLIST" | grep -q "<false/>" \
  && ok "ITSAppUsesNonExemptEncryption = false" \
  || bad "ITSAppUsesNonExemptEncryption must be present and false, or every upload asks about encryption"

grep -q "<key>CFBundleIconName</key>" "$PLIST" \
  && ok "CFBundleIconName present (ITMS-90713)" \
  || bad "CFBundleIconName missing — the upload is rejected with ITMS-90713"

if grep -A3 "<key>UIDeviceFamily</key>" "$PLIST" | grep -q "<integer>2</integer>"; then
  bad "UIDeviceFamily includes iPad (2) — this build is iPhone-only"
else
  ok "UIDeviceFamily is iPhone-only"
fi

if grep -A3 "<key>WKAppBoundDomains</key>" "$PLIST" | grep -q "scrollanytime.com"; then
  ok "WKAppBoundDomains contains scrollanytime.com (service worker + offline)"
else
  bad "WKAppBoundDomains must contain scrollanytime.com — without it there is no service worker in WKWebView, so offline mode silently does not work"
fi

grep -q "applinks:scrollanytime.com" "$ENT" \
  && ok "associated domains: applinks:scrollanytime.com" \
  || warn "no associated-domains entitlement — shared /c/ and /r/ links will open Safari, not the app"

# ── 3. project settings ────────────────────────────────────────────────────────────────────
printf "\n${B}project${N}\n"
pbx() { grep -c "$1" "$PBX" 2>/dev/null || echo 0; }
[ "$(pbx 'PRODUCT_BUNDLE_IDENTIFIER = "com.scrollanytime.app"')" -ge 1 ] \
  && ok "bundle id com.scrollanytime.app" || bad "bundle id is not com.scrollanytime.app"
# any x.y.z: the version climbs with every App Store update (1.0.0 shipped; 1.0.1 is the first update)
[ "$(grep -cE 'MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;' "$PBX")" -ge 1 ] \
  && ok "marketing version $(grep -oE 'MARKETING_VERSION = [0-9.]+' "$PBX" | head -1 | cut -d' ' -f3)" || bad "MARKETING_VERSION is not a valid x.y.z"
[ "$(pbx 'CURRENT_PROJECT_VERSION = 1')" -ge 1 ] \
  && ok "build 1" || bad "CURRENT_PROJECT_VERSION is not 1"
[ "$(pbx 'TARGETED_DEVICE_FAMILY = "1"')" -ge 1 ] \
  && ok "TARGETED_DEVICE_FAMILY = 1 (iPhone)" || bad "TARGETED_DEVICE_FAMILY must be \"1\""
[ "$(pbx 'IPHONEOS_DEPLOYMENT_TARGET = 17.0')" -ge 1 ] \
  && ok "deployment target iOS 17.0" || warn "deployment target is not 17.0 — check it is two majors back from the current SDK"

# no template placeholders may survive anywhere
if grep -rq "{{PWABuilder" ship/ios --include=*.swift --include=*.plist --include=*.storyboard --include=*.pbxproj 2>/dev/null; then
  bad "unfilled {{PWABuilder...}} placeholders remain:"
  grep -rn "{{PWABuilder" ship/ios --include=*.swift --include=*.plist --include=*.storyboard --include=*.pbxproj 2>/dev/null | sed 's/^/         /'
else
  ok "no template placeholders remain"
fi

# ── 4. shell behaviour ─────────────────────────────────────────────────────────────────────
printf "\n${B}shell behaviour${N}\n"
grep -q 'rootUrl = URL(string: "https://scrollanytime.com/?app=ios")' "$SETTINGS" \
  && ok "rootUrl carries ?app=ios (hides Sponsor, external links and push UI)" \
  || bad "rootUrl must be https://scrollanytime.com/?app=ios — without it the reviewer sees the Sponsor tab and external links"
grep -q 'let pullToRefresh = false' "$SETTINGS" && ok "pull-to-refresh off" || bad "pullToRefresh must be false"
# fullscreen, NOT standalone: standalone placed the web view below the status bar on a white
# container — a white band across the top of every screen of a dark app (2026-09-11)
grep -q 'let displayMode = "fullscreen"' "$SETTINGS" && ok "fullscreen display (web view under the status bar)" || bad "displayMode must be fullscreen — standalone leaves a white band above the web view"
grep -q 'statusBarTheme = "light"' "$SETTINGS" && ok "light status bar on the dark ground" || bad "statusBarTheme must be light"
grep -q 'config.allowsInlineMediaPlayback = true' "$WEBVIEW" && ok "allowsInlineMediaPlayback" || bad "allowsInlineMediaPlayback must be true"
grep -q 'config.mediaTypesRequiringUserActionForPlayback = \[\]' "$WEBVIEW" \
  && ok "mediaTypesRequiringUserActionForPlayback = [] (the feed autoplays)" \
  || bad "mediaTypesRequiringUserActionForPlayback must be [] or the app opens on a frozen poster"
# check the ASSIGNMENT, not any mention: the comment above that line explains why the suffix
# was removed and naturally contains the word
if grep "webView.customUserAgent" "$WEBVIEW" | grep -q "PWAShell"; then
  bad "the user agent still ends in PWAShell — it must be a plain Mobile Safari UA"
else
  ok "user agent is a plain Mobile Safari UA"
fi
grep -q 'offlineFallbackHTML' "$VC" \
  && ok "offline fallback wired to initial-navigation failure (3.1)" \
  || bad "ViewController does not load the offline fallback — an airplane-mode first launch will white-screen"

# the embedded copy must match its source
# compare the GENERATED region before and after regeneration — a hand edit elsewhere in
# Settings.swift (the display mode, say) is not drift
before=$(sed -n '/GENERATED: offline fallback/,$p' "$SETTINGS" | md5sum)
if node ship/gen-offline-swift.mjs >/dev/null 2>&1; then
  after=$(sed -n '/GENERATED: offline fallback/,$p' "$SETTINGS" | md5sum)
  if [ "$before" = "$after" ]; then
    ok "embedded offline page matches ship/ios/offline.html"
  else
    bad "the embedded offline page has drifted from ship/ios/offline.html — it has just been regenerated; review and commit"
  fi
else
  warn "could not regenerate the embedded offline page (node missing?)"
fi

# ── 4b. script message handlers ────────────────────────────────────────────────────────────
# WKUserContentController throws NSInvalidArgumentException on a duplicate handler name — an
# app that registers one twice crashes in viewDidLoad, before its first frame (build 23, 2026-09-14,
# caught by the Simulator recording, never shipped).
printf "
${B}script message handlers${N}
"
DUPS=$(grep -o 'userContentController.add(WKSMH, name: "[^"]*")' ship/ios/pwa-shell/WebView.swift | sort | uniq -d)
[ -z "$DUPS" ] && ok "no duplicate script message handler names" || bad "duplicate script message handler registration: $DUPS"
# the handoff: the page posts "painted" at frame zero, the shell lifts the loading view on it
grep -q 'userContentController.add(WKSMH, name: "sa")' "$WEBVIEW" && grep -q 'message.name == "sa"' "$VC" \
  && ok "\"sa\" handler registered and handled (the loading view lifts at the page's first paint)" \
  || bad "the \"sa\" script message handler must be registered in WebView.swift and handled in ViewController.swift"
# the web app is not part of the public build mirror, so this half of the contract is checked
# only where the app exists (here); the live page is what the shell actually talks to
if [ -f app/src/splash/splash.html ]; then
  grep -q "messageHandlers.sa" app/src/splash/splash.html \
    && ok "the splash markup posts \"painted\" to the shell" \
    || bad "app/src/splash/splash.html no longer posts \"painted\" — the shell would lift its loading view only at load"
else
  warn "app/src/splash/splash.html not present (build mirror) — the page side of the handoff is checked in the main repository"
fi
grep -q 'webviewView.insertSubview(PWAShell.webView, belowSubview: loadingView)' "$VC" \
  && ok "web view sits directly under the loading view (never hidden, so the page renders and can post)" \
  || bad "the web view must be inserted directly below loadingView — build 25 put it under a wrapper that never lifted"

# ── 4c. the loading view's layout ──────────────────────────────────────────────────────────
# Build 24 (2026-09-14): the loading view sat in an unconstrained wrapper that collapsed to 0x0,
# and the closed scroll sat half off-screen at the top-left. Build 25 pinned the wrapper but the
# web view went under it. Now: the loading view is a DIRECT child of the webview view, pinned to
# it, and nothing sits between it and the web view.
MS=ship/ios/pwa-shell/Base.lproj/Main.storyboard
for c in lv-fill-top lv-fill-bottom lv-fill-lead lv-fill-trail; do
  grep -q "id=\"$c\"" "$MS" || bad "Main.storyboard: the loading view is not pinned ($c missing) — it would collapse to 0x0"
done
if grep -q 'firstItem="DIO-mU-n27" firstAttribute="top" secondItem="PHY-vp-dMl"' "$MS"; then
  ok "loading view pinned directly to the webview view"
else
  bad "the loading view must be pinned to the webview view itself (PHY-vp-dMl), not to a wrapper"
fi
grep -q 'p0s-Fg-eGP' "$MS" && bad "the \"Splash Background\" wrapper is back — anything between the loading view and the web view hides the page"
grep -q 'id="lv-ico-cy"' "$MS" && grep -q 'multiplier="0.4" id="lv-spc-h"' "$MS" \
  && ok "loading view: closed scroll centred at 40% of the safe area (same still as the launch screen)" \
  || bad "loading view no longer places the closed scroll at 40% of the safe area"

# ── 5. launch screen ───────────────────────────────────────────────────────────────────────
printf "\n${B}launch screen (3.7)${N}\n"
LS=ship/ios/pwa-shell/Base.lproj/LaunchScreen.storyboard
if grep -q 'systemColor="systemBackgroundColor"' "$LS"; then
  bad "launch screen uses systemBackgroundColor — that is WHITE in light mode and flashes before the app's dark first paint"
else
  ok "launch screen does not use a system background colour"
fi
grep -q 'red="0.043137254901960784"' "$LS" && ok "launch ground is #0B0B0F" || bad "launch ground is not #0B0B0F"
[ -f ship/ios/pwa-shell/Assets.xcassets/LaunchIcon.imageset/launch-icon@3x.png ] \
  && ok "launch icon asset present (@1x/@2x/@3x)" \
  || bad "launch icon asset missing — run: python app/scripts/gen-splash-assets.py"

# ── 6. icon ────────────────────────────────────────────────────────────────────────────────
printf "\n${B}icon${N}\n"
ICON=ship/ios/pwa-shell/Assets.xcassets/AppIcon.appiconset/1024.png
if [ -f "$ICON" ]; then
  ALPHA=$(node -e "const b=require('fs').readFileSync('$ICON');console.log(b.readUInt32BE(16)+'x'+b.readUInt32BE(20)+':'+b[25])" 2>/dev/null)
  case "$ALPHA" in
    1024x1024:2|1024x1024:0) ok "AppIcon 1024 is 1024x1024 with NO alpha channel" ;;
    *:6|*:4) bad "AppIcon 1024 HAS an alpha channel ($ALPHA) — App Store Connect rejects it outright" ;;
    *) warn "could not read the icon header ($ALPHA)" ;;
  esac
else
  bad "AppIcon 1024 missing — run: node ship/gen-ios-assets.mjs"
fi

printf "\n"
if [ "$fail" -gt 0 ]; then
  printf "${R}${B}iOS LINT: %d FAILURE(S) — DO NOT BUILD${N}\n\n" "$fail"
  exit 1
fi
printf "${G}${B}iOS LINT: CLEAN${N}\n\n"

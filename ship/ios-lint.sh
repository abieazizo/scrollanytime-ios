#!/usr/bin/env bash
# Runs first on the build machine (the workflow calls it "lint").
# Makes the Xcode project from project.yml and proves the app compiles, with every error in the log.
set -euo pipefail
cd "$(dirname "$0")/ios"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate
ls

mkdir -p ../build
set +e
xcodebuild build \
  -project pwa-shell.xcodeproj \
  -scheme pwa-shell \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ../build/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  > ../build/compile.log 2>&1
code=$?
set -e
grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" ../build/compile.log | sort -u | head -80 || true
if [ "$code" -ne 0 ]; then
  echo "---- last lines ----"
  tail -60 ../build/compile.log
  exit "$code"
fi
echo "Seder compiles"

# Pictures of the countdown, drawn by the same code the Lock Screen uses.
if [ -x ../seder/shots.sh ]; then bash ../seder/shots.sh || echo "shots failed (not fatal)"; fi

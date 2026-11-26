#!/usr/bin/env bash
# Archives Seder, signed for the owner's iPhone, and packs it as ship/build/Seder.ipa.
set -euo pipefail
bn="${1:-1}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/ship/ios"
[ -d pwa-shell.xcodeproj ] || xcodegen generate
mkdir -p ../build
set +e
xcodebuild archive \
  -project pwa-shell.xcodeproj \
  -scheme pwa-shell \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ../build/Seder.xcarchive \
  -derivedDataPath ../build/dd-signed \
  CURRENT_PROJECT_VERSION="$bn" \
  OTHER_CODE_SIGN_FLAGS="--keychain $HOME/Library/Keychains/build.keychain-db" \
  > ../build/archive.log 2>&1
code=$?
set -e
grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" ../build/archive.log | sort -u | head -60 || true
if [ "$code" -ne 0 ]; then tail -80 ../build/archive.log; exit "$code"; fi

cd ../build
rm -rf Payload Seder.ipa
mkdir Payload
cp -R Seder.xcarchive/Products/Applications/Seder.app Payload/
codesign -dv --entitlements - Payload/Seder.app 2>&1 | grep -E "Identifier|TeamIdentifier|aps-environment|application-identifier" || true
zip -qry Seder.ipa Payload
rm -rf Payload
ls -la Seder.ipa

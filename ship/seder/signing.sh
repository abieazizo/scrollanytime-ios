#!/usr/bin/env bash
# Opens ship/seder/signing.enc (the signing certificate, its key and the two profiles, locked with a
# key made from the App Store Connect key this machine already holds) and installs them.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
ruby "$here/open.rb" "$here/signing.enc" "$work"

keychain="$HOME/Library/Keychains/build.keychain-db"
security import "$work/key.pem" -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security -A
security import "$work/cert.cer" -k "$keychain" -T /usr/bin/codesign -A
# The certificate that vouches for ours, in case this machine does not have it.
curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$work/wwdr.cer" && security import "$work/wwdr.cer" -k "$keychain" -A || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$keychain" >/dev/null 2>&1 || true

for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$dir"
  for p in "$work"/*.mobileprovision; do
    uuid="$(security cms -D -i "$p" 2>/dev/null | plutil -extract UUID raw -o - -)"
    cp "$p" "$dir/$uuid.mobileprovision"
    echo "profile $(basename "$p") -> $uuid"
  done
done
rm -rf "$work"
security find-identity -v -p codesigning "$keychain" | grep -q "Apple Development" || { echo "no Apple Development identity in the keychain"; exit 1; }
echo "signing is ready"

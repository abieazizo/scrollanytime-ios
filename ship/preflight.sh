#!/usr/bin/env bash
# ship/preflight.sh — PHASE LAUNCH, PART 6 STEP 0: is this Mac ready to ship Scroll Anytime?
#
# Run this FIRST, on the owner's Mac, before anything else in PART 6. It changes nothing on the
# machine — it only looks. Every line comes back green (ready) or red (not ready). If anything is
# red, the exact command that fixes it is printed at the bottom and the script exits non-zero, so
# the rest of the pipeline refuses to run on a half-set-up machine.
#
#   ./ship/preflight.sh
#
# It never asks a question and never waits for input, so another script can call it safely.
# It never installs anything and never uses sudo — the fixes are printed for a human to run.
set -uo pipefail

# ── output ──────────────────────────────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR-}" ] || [ "${TERM-}" = "dumb" ]; then
  RED=""; GRN=""; YEL=""; DIM=""; BLD=""; RST=""
else
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'
fi

FAILED=0
WARNED=0
FIX_NAME=()
FIX_CMD=()

addfix() { FIX_NAME[${#FIX_NAME[@]}]="$1"; FIX_CMD[${#FIX_CMD[@]}]="$2"; }

ok()   { printf "  ${GRN}●${RST} %-26s ${DIM}%s${RST}\n" "$1" "$2"; }
warn() { printf "  ${YEL}●${RST} %-26s %s\n" "$1" "$2"; WARNED=$((WARNED + 1)); }
bad()  { printf "  ${RED}●${RST} %-26s %s\n" "$1" "$2"; FAILED=$((FAILED + 1)); addfix "$1" "$3"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

printf "\n${BLD}Scroll Anytime — Mac preflight${RST}  ${DIM}(PART 6 STEP 0)${RST}\n"
printf "${DIM}repo: %s${RST}\n\n" "$ROOT"

# ── 1. the machine itself ───────────────────────────────────────────────────────────────────────
printf "${BLD}THE MACHINE${RST}\n"

IS_MAC=0
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
if [ "$UNAME_S" = "Darwin" ]; then
  IS_MAC=1
  ok "macOS" "$(sw_vers -productVersion 2>/dev/null || echo '?') on $(uname -m)"
else
  bad "macOS" "this machine is ${UNAME_S}, not macOS" \
    "There is no fix on this machine. Xcode, xcodebuild and the iOS simulator are macOS-only.
    Copy this repository to the owner's Mac and run ./ship/preflight.sh there."
fi

# ── 2. Xcode ────────────────────────────────────────────────────────────────────────────────────
printf "\n${BLD}XCODE${RST}\n"

XPATH=""
if [ "$IS_MAC" = "1" ]; then
  XPATH="$(xcode-select -p 2>/dev/null)"
fi

if [ "$IS_MAC" != "1" ]; then
  bad "Xcode" "cannot be checked — not macOS" \
    "Run this on the Mac."
elif [ -z "$XPATH" ]; then
  bad "Xcode" "not installed (xcode-select -p found nothing)" \
    "Install Xcode from the App Store — see SETUP-APPLE.md PART 1. It is a very large download.
    Then open Xcode once, accept the licence, and let it install its extra components."
elif [ "${XPATH%CommandLineTools}" != "$XPATH" ]; then
  bad "Xcode" "only the command line tools are selected ($XPATH)" \
    "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    (If /Applications/Xcode.app does not exist, install Xcode first — SETUP-APPLE.md PART 1.)"
else
  XVER="$(xcodebuild -version 2>/dev/null | head -1)"
  if [ -z "$XVER" ]; then
    bad "Xcode" "installed at $XPATH but xcodebuild will not run" \
      "sudo xcodebuild -license accept
    Then open Xcode once from Applications and let it finish installing its components."
  else
    ok "Xcode" "$XVER"
  fi
fi

# command line tools — xcrun must be able to find the compiler and xcodebuild
if [ "$IS_MAC" = "1" ] && xcrun --find clang >/dev/null 2>&1 && xcrun --find xcodebuild >/dev/null 2>&1; then
  ok "command line tools" "xcrun resolves clang and xcodebuild"
elif [ "$IS_MAC" = "1" ]; then
  bad "command line tools" "xcrun cannot find clang / xcodebuild" \
    "xcode-select --install
    (A window opens; click Install and wait. If it says they are already installed, run
     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer instead.)"
else
  bad "command line tools" "cannot be checked — not macOS" "Run this on the Mac."
fi

# iOS SDK — the deployment target rule in ship/ios/README.md depends on this number
if [ "$IS_MAC" = "1" ]; then
  SDKVER="$(xcodebuild -showsdks 2>/dev/null | grep -o 'iphoneos[0-9.]*' | tail -1 | sed 's/iphoneos//')"
  if [ -n "$SDKVER" ]; then
    ok "iOS SDK" "iphoneos${SDKVER}  (deployment target: see ship/ios/README.md)"
  else
    warn "iOS SDK" "could not read an iOS SDK from xcodebuild -showsdks — open Xcode once"
  fi
fi

# ── 3. a signed-in Apple team ───────────────────────────────────────────────────────────────────
printf "\n${BLD}APPLE ACCOUNT${RST}\n"

if [ "$IS_MAC" = "1" ] && [ -d "$HOME/Library/Developer/Xcode" ]; then
  ok "Xcode has been opened" "$HOME/Library/Developer/Xcode exists"
elif [ "$IS_MAC" = "1" ]; then
  bad "Xcode has been opened" "$HOME/Library/Developer/Xcode is missing" \
    "Open Xcode once from Applications, accept the licence, then quit it. See SETUP-APPLE.md PART 1."
fi

if [ "$IS_MAC" = "1" ]; then
  IDENTS="$(security find-identity -v -p codesigning 2>/dev/null | grep -c -E 'Apple (Development|Distribution)|iPhone (Developer|Distribution)')"
  IDENTS="${IDENTS//[!0-9]/}"
  if [ "${IDENTS:-0}" -gt 0 ]; then
    ok "signing identity" "${IDENTS} Apple signing certificate(s) in the keychain"
  else
    bad "signing identity" "no Apple signing certificate in this Mac's keychain" \
      "Open Xcode → Settings… → Accounts → + → Apple ID, and sign in with the Apple ID that has the
    Developer Program membership. Then select your team and click 'Manage Certificates…' → + →
    'Apple Distribution'. Full walkthrough: SETUP-APPLE.md PART 1."
  fi
fi

# If the iOS project already exists, ask xcodebuild which team it is actually configured with.
PROJ="$(find "$ROOT/ship/ios" -maxdepth 3 \( -name '*.xcworkspace' -o -name '*.xcodeproj' \) 2>/dev/null | head -1)"
if [ "$IS_MAC" = "1" ] && [ -n "$PROJ" ]; then
  case "$PROJ" in
    *.xcworkspace) SETTINGS="$(xcrun xcodebuild -showBuildSettings -workspace "$PROJ" -scheme "$(basename "${PROJ%.*}")" 2>/dev/null)" ;;
    *)             SETTINGS="$(xcrun xcodebuild -showBuildSettings -project "$PROJ" 2>/dev/null)" ;;
  esac
  TEAM="$(printf '%s' "$SETTINGS" | grep -E '^ *DEVELOPMENT_TEAM = ' | head -1 | sed 's/.*= *//')"
  BID="$(printf '%s' "$SETTINGS" | grep -E '^ *PRODUCT_BUNDLE_IDENTIFIER = ' | head -1 | sed 's/.*= *//')"
  if [ -n "$TEAM" ]; then
    ok "project team" "DEVELOPMENT_TEAM = $TEAM  ($(basename "$PROJ"))"
  else
    warn "project team" "$(basename "$PROJ") has no DEVELOPMENT_TEAM set — set it in Signing & Capabilities"
  fi
  if [ "$BID" = "com.scrollanytime.app" ]; then
    ok "project bundle id" "com.scrollanytime.app"
  elif [ -n "$BID" ]; then
    bad "project bundle id" "$BID (must be com.scrollanytime.app)" \
      "Open the project in Xcode → target → Signing & Capabilities → Bundle Identifier →
    type exactly: com.scrollanytime.app"
  fi
else
  printf "  ${DIM}·${RST} %-26s ${DIM}%s${RST}\n" "iOS project" "not generated yet — see ship/ios/README.md (STEP 1)"
fi

# ── 4. tools ────────────────────────────────────────────────────────────────────────────────────
printf "\n${BLD}TOOLS${RST}\n"

BREW_OK=0
if command -v brew >/dev/null 2>&1; then
  BREW_OK=1
  ok "Homebrew" "$(brew --version 2>/dev/null | head -1)"
else
  warn "Homebrew" "not installed — the fixes below that start with 'brew' need it first"
fi

if command -v fastlane >/dev/null 2>&1; then
  ok "fastlane" "$(fastlane --version 2>/dev/null | grep -i -m1 'fastlane [0-9]' | tr -d '\r')"
else
  if [ "$BREW_OK" = "1" ]; then
    bad "fastlane" "not on PATH" "brew install fastlane"
  else
    bad "fastlane" "not on PATH" \
      "First install Homebrew (this one asks for your Mac password):
      /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/brew/HEAD/install.sh)\"
    Then:
      brew install fastlane"
  fi
fi

if command -v git >/dev/null 2>&1; then
  ok "git" "$(git --version 2>/dev/null)"
else
  bad "git" "not on PATH" \
    "xcode-select --install
    (git ships with Apple's command line tools. If that says they are already installed, use:
     brew install git)"
fi

if command -v node >/dev/null 2>&1; then
  NODE_RAW="$(node -v 2>/dev/null)"
  NODE_MAJ="$(printf '%s' "$NODE_RAW" | sed 's/^v//' | cut -d. -f1)"
  NODE_MAJ="${NODE_MAJ//[!0-9]/}"
  if [ -n "$NODE_MAJ" ] && [ "$NODE_MAJ" -ge 20 ]; then
    ok "node" "$NODE_RAW (needs 20 or newer)"
  else
    bad "node" "$NODE_RAW is too old — this repo needs node 20 or newer" \
      "brew install node
    Then check with: node -v"
  fi
else
  bad "node" "not on PATH" \
    "brew install node
    Then check with: node -v"
fi

if command -v magick >/dev/null 2>&1; then
  IMVER="$(magick -version 2>/dev/null | head -1 | cut -c1-60)"
  ok "ImageMagick" "${IMVER:-magick at $(command -v magick)}"
elif command -v convert >/dev/null 2>&1; then
  IMVER="$(convert -version 2>/dev/null | head -1 | cut -c1-60)"
  ok "ImageMagick" "${IMVER:-convert at $(command -v convert)}"
else
  bad "ImageMagick" "neither 'magick' nor 'convert' is on PATH" \
    "brew install imagemagick
    (It is used to flatten the 1024x1024 store icon — an icon with an alpha channel is rejected —
     and to check screenshot pixel sizes before upload.)"
fi

# ── 5. App Store Connect API key ────────────────────────────────────────────────────────────────
printf "\n${BLD}APP STORE CONNECT KEY${RST}  ${DIM}(SETUP-APPLE.md PART 2)${RST}\n"

ENV_FIX="Add these three lines to ~/.zshrc (change the values to yours), then open a NEW Terminal:
      export ASC_KEY_ID=ABC1234XYZ
      export ASC_ISSUER_ID=69a6de70-1234-47e3-e053-5b8c7c11a4d1
      export ASC_KEY_PATH=\"\$HOME/Documents/AuthKey_ABC1234XYZ.p8\"
    The KEY ID and ISSUER ID are the two codes you wrote down in SETUP-APPLE.md PART 2 step 11.
    Check afterwards with:  echo \$ASC_KEY_ID \$ASC_ISSUER_ID \$ASC_KEY_PATH"

# The same three exports fix all three rows, so the long fix is only spelled out once.
# (envfix runs in a subshell, so the caller — not envfix — sets the flag afterwards.)
ENV_FIX_SHOWN=0
ENV_FIX_AGAIN="Same fix as above: all three come from the same three export lines in ~/.zshrc."
envfix() {
  if [ "$ENV_FIX_SHOWN" = "0" ]; then printf '%s' "$ENV_FIX"; else printf '%s' "$ENV_FIX_AGAIN"; fi
}

if [ -n "${ASC_KEY_ID-}" ]; then
  case "$ASC_KEY_ID" in
    [A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9])
      ok "ASC_KEY_ID" "$ASC_KEY_ID" ;;
    *)
      warn "ASC_KEY_ID" "set to '$ASC_KEY_ID' — Apple key IDs are 10 characters, check for a typo" ;;
  esac
else
  bad "ASC_KEY_ID" "not set" "$(envfix)"; ENV_FIX_SHOWN=1
fi

if [ -n "${ASC_ISSUER_ID-}" ]; then
  case "$ASC_ISSUER_ID" in
    ????????-????-????-????-????????????) ok "ASC_ISSUER_ID" "$ASC_ISSUER_ID" ;;
    *) warn "ASC_ISSUER_ID" "set to '$ASC_ISSUER_ID' — the issuer ID normally looks like a long id with dashes" ;;
  esac
else
  bad "ASC_ISSUER_ID" "not set" "$(envfix)"; ENV_FIX_SHOWN=1
fi

KP="${ASC_KEY_PATH-}"
KP="${KP/#\~/$HOME}"
if [ -z "$KP" ]; then
  bad "ASC_KEY_PATH" "not set" "$(envfix)"; ENV_FIX_SHOWN=1
elif [ ! -f "$KP" ]; then
  bad "ASC_KEY_PATH" "no file at $KP" \
    "Find the .p8 file you downloaded in SETUP-APPLE.md PART 2 (it is called something like
    AuthKey_ABC1234XYZ.p8), move it to ~/Documents, and point ASC_KEY_PATH at it:
      export ASC_KEY_PATH=\"\$HOME/Documents/AuthKey_ABC1234XYZ.p8\"
    Apple lets you download that file ONCE. If it is genuinely lost, go to
    appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API,
    revoke the old key and generate a new one (App Manager access), then update ASC_KEY_ID too."
elif [ ! -r "$KP" ]; then
  bad "ASC_KEY_PATH" "the file at $KP cannot be read" \
    "chmod 600 \"$KP\""
else
  KPSIZE="$(wc -c < "$KP" 2>/dev/null | tr -d ' ')"
  if head -1 "$KP" 2>/dev/null | grep -q 'BEGIN PRIVATE KEY'; then
    ok "ASC_KEY_PATH" "$KP (${KPSIZE} bytes, looks like a valid .p8)"
  else
    bad "ASC_KEY_PATH" "$KP does not look like an Apple .p8 key" \
      "The file must start with the line: -----BEGIN PRIVATE KEY-----
    You may have pointed at the wrong file, or the download was interrupted. Re-download or
    re-generate the key — SETUP-APPLE.md PART 2."
  fi
  # A mismatched filename is not fatal, but it is the most common wrong-file mistake.
  if [ -n "${ASC_KEY_ID-}" ]; then
    case "$(basename "$KP")" in
      *"$ASC_KEY_ID"*) : ;;
      *) warn "key id vs filename" "$(basename "$KP") does not contain $ASC_KEY_ID — make sure these are the same key" ;;
    esac
  fi
fi

# ── summary ─────────────────────────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAILED" -eq 0 ] && [ "$WARNED" -eq 0 ]; then
  printf "${GRN}${BLD}READY.${RST} Everything this Mac needs is here. Continue with ship/ios/README.md (STEP 1).\n\n"
  exit 0
fi

if [ "$FAILED" -eq 0 ]; then
  printf "${GRN}${BLD}READY${RST} — with %d warning(s) above. Read them, then continue with ship/ios/README.md (STEP 1).\n\n" "$WARNED"
  exit 0
fi

printf "${RED}${BLD}NOT READY${RST} — %d thing(s) to fix" "$FAILED"
if [ "$WARNED" -gt 0 ]; then printf ", plus %d warning(s) above" "$WARNED"; fi
printf ".\n\n${BLD}FIX EACH ONE, THEN RUN ./ship/preflight.sh AGAIN${RST}\n"

i=0
while [ "$i" -lt "${#FIX_NAME[@]}" ]; do
  printf "\n${RED}%d) %s${RST}\n    %s\n" "$((i + 1))" "${FIX_NAME[$i]}" "${FIX_CMD[$i]}"
  i=$((i + 1))
done

printf "\n${DIM}Do not start STEP 1 until this script prints READY. A red line here becomes a failed\n"
printf "archive, a failed upload, or a rejected build later, and it is much harder to read then.${RST}\n\n"
exit 1

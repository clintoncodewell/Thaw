#!/usr/bin/env bash
# Build this fork on Clinton's Mac.
#
# Upstream hardcodes DEVELOPMENT_TEAM=456BPWQ6U5 (the maintainer's), which we
# can't sign with. Overriding on the xcodebuild command line instead of editing
# project.pbxproj keeps the daily upstream merge conflict-free.
#
# Signs ad-hoc by default so this works over ssh from the VM: the login keychain
# is unreachable from a non-GUI session ("User interaction is not allowed"), so
# real identity signing fails with errSecInternalComponent. Pass --signed once
# the keychain is reachable (see FORK.md) to get a stable signature that TCC
# remembers between builds.
#
# Usage (on the Mac, from the repo root):
#   ./build-local.sh              # Debug build, compile check only
#   ./build-local.sh Release      # Release build
#   ./build-local.sh Release --install   # ...and replace /Applications/Thaw.app
#   ./build-local.sh Release --install --signed
#
# From the VM:  tomac --sync && ssh mac 'cd ~/dev/thaw && ./build-local.sh Release --install'
set -euo pipefail

CONFIG=${1:-Debug}
TEAM=36H9FH5KZM   # clinton c — from "Apple Development: clinton.cunningham@gmail.com"

cd "$(dirname "$0")"

if [[ " ${*} " == *" --signed "* ]]; then
  SIGN_ARGS=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic)
else
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO)
fi

xcodebuild \
  -project Thaw.xcodeproj \
  -scheme Thaw \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  "${SIGN_ARGS[@]}" \
  build

APP="build/Build/Products/$CONFIG/Thaw.app"

if [[ " ${*} " != *" --signed "* ]]; then
  # Xcode leaves the prebuilt Sparkle.framework signed with upstream's Team ID
  # while our binary is ad-hoc (no team). dyld refuses to load a framework whose
  # Team ID differs from the loading process, so the app aborts at launch with
  # "Library not loaded: @rpath/Sparkle.framework". Re-sign every nested bundle
  # ad-hoc, deepest first, so the whole tree agrees on "no team".
  find "$APP/Contents" -depth \
    \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.dylib" \) \
    -print0 | xargs -0 -I{} codesign --force --sign - --timestamp=none {} >/dev/null 2>&1
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
  codesign --verify --strict "$APP" && echo "re-signed ad-hoc (whole tree)"
fi

echo "built: $APP"

if [[ "${2:-}" == "--install" ]]; then
  pkill -f '/Applications/Thaw.app' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Thaw.app
  ditto "$APP" /Applications/Thaw.app   # ditto, not cp — preserves the signature
  open /Applications/Thaw.app
  echo "installed + launched /Applications/Thaw.app"
fi

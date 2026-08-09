#!/usr/bin/env bash
# Build this fork on Clinton's Mac.
#
# Upstream hardcodes DEVELOPMENT_TEAM=456BPWQ6U5 (the maintainer's), which we
# can't sign with. Overriding on the xcodebuild command line instead of editing
# project.pbxproj keeps the daily upstream merge conflict-free.
#
# Signs with the real identity by default. An ad-hoc signature invalidates every
# TCC grant Thaw holds the moment it is installed — the System Settings checkbox
# stays ticked while macOS denies the app, and unticking it cannot fix that (see
# FORK.md "Signing"). So an accidental ad-hoc build is worse than no build, and
# this refuses to produce one over ssh rather than failing quietly.
#
# Signing from a non-GUI ssh session needs the dedicated keychain created by
# ./setup-signing-keychain.sh — the login keychain is unreachable there
# ("User interaction is not allowed" / errSecInternalComponent).
#
# Usage (on the Mac, from the repo root):
#   ./build-local.sh              # Debug build, compile check only
#   ./build-local.sh Release      # Release build
#   ./build-local.sh Release --install   # ...and replace /Applications/Thaw.app
#   ./build-local.sh Release --adhoc     # unsigned, breaks TCC grants on install
#
# From the VM:  tomac --sync && ssh mac 'cd ~/dev/thaw && ./build-local.sh Release --install'
set -euo pipefail

TEAM=36H9FH5KZM   # clinton c — from "Apple Development: clinton.cunningham@gmail.com"

cd "$(dirname "$0")"

CONFIG=Debug
INSTALL=0
ADHOC=0
for arg in "$@"; do
  case "$arg" in
    Debug|Release) CONFIG=$arg ;;
    --install)     INSTALL=1 ;;
    --adhoc)       ADHOC=1 ;;
    --signed)      ;;   # signing is the default now; accepted so old callers still work
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SIGNING_KEYCHAIN="$HOME/Library/Keychains/thaw-signing.keychain-db"
SIGNING_PW="$HOME/.config/signing/thaw-keychain.pw"

if [ "$ADHOC" = 1 ]; then
  SIGNED=0
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO)
else
  SIGNED=1
  SIGN_ARGS=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic)
  if [ -r "$SIGNING_KEYCHAIN" ] && [ -r "$SIGNING_PW" ]; then
    # A stale password or a re-created keychain must land on the same "cannot
    # sign here" path. Left bare, set -e would abort with security's own wording,
    # which upstream-sync.sh reads as a failed verify and blames on the merge.
    security unlock-keychain -p "$(cat "$SIGNING_PW")" "$SIGNING_KEYCHAIN" 2>/dev/null || {
      echo "No signing certificate: could not unlock $SIGNING_KEYCHAIN" >&2
      echo "Re-run ./setup-signing-keychain.sh in a Terminal on the Mac (see FORK.md)." >&2
      exit 75
    }
  elif ! security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    # No dedicated keychain and no reachable login keychain, so signing cannot
    # work. ponytail: fail loud, and exit 75 — upstream-sync.sh reads that as
    # "couldn't verify here, retry tomorrow" rather than blaming the merge, so
    # the nightly defers instead of installing over the signed app. (mac-build.sh
    # also greps the message below and maps it to 75; either route agrees.)
    echo "No signing certificate reachable from this session." >&2
    echo "Run ./setup-signing-keychain.sh in a Terminal on the Mac (see FORK.md)." >&2
    exit 75
  fi
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

if [ "$SIGNED" = 0 ]; then
  # Xcode leaves the prebuilt Sparkle.framework signed with upstream's Team ID
  # while our binary is ad-hoc (no team). dyld refuses to load a framework whose
  # Team ID differs from the loading process, so the app aborts at launch with
  # "Library not loaded: @rpath/Sparkle.framework".
  #
  # Re-sign ONLY the frameworks. Do not touch MenuBarItemService.xpc: Xcode
  # already signed it ad-hoc with its generated .xcent, and a blanket
  # `codesign --force --sign -` silently DROPS entitlements. Without them the
  # service launches but every XPC request dies with "Underlying connection
  # interrupted", sourcePID comes back nil for every item, and the layout editor
  # reports every item as immovable.
  find "$APP/Contents" -depth -name "*.framework" -print0 |
    xargs -0 -I{} codesign --force --sign - --timestamp=none {} >/dev/null 2>&1

  # Changing nested code invalidates the outer seal, so re-sign the app — but
  # carry its own entitlements back over rather than dropping them.
  ENTS=$(mktemp -t thaw-ents).plist
  if codesign -d --entitlements "$ENTS" --xml "$APP" 2>/dev/null && [ -s "$ENTS" ]; then
    codesign --force --sign - --timestamp=none --entitlements "$ENTS" "$APP" >/dev/null 2>&1
  else
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
  fi
  rm -f "$ENTS"
  codesign --verify --strict "$APP" && echo "re-signed frameworks ad-hoc (entitlements preserved)"
fi

echo "built: $APP"

if [ "$INSTALL" = 1 ]; then
  codesign --verify --strict "$APP" ||
    { echo "built app fails codesign — not installing" >&2; exit 1; }

  if [ "$SIGNED" = 1 ]; then
    # Capture, don't pipe into `grep -q`: grep exits on first match, codesign
    # takes SIGPIPE, and pipefail then reports a successful match as a failure.
    SIGINFO=$(codesign -dvvv "$APP" 2>&1)
    case "$SIGINFO" in
      *"TeamIdentifier=$TEAM"*) ;;
      *) echo "built app is not signed with team $TEAM — refusing to install" >&2; exit 1 ;;
    esac

    # The signature is the whole point, so check the thing that actually matters:
    # does this bundle still satisfy the requirement macOS recorded when the
    # Accessibility grant was made? Skipped silently when the TCC database isn't
    # readable (needs Full Disk Access) or no grant exists yet.
    REQ=$(mktemp -t thaw-req)
    if sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
         "select hex(csreq) from access where service='kTCCServiceAccessibility' and client='com.stonerl.Thaw';" \
         2>/dev/null | xxd -r -p > "$REQ" && [ -s "$REQ" ]; then
      codesign --verify -R "$REQ" "$APP" 2>/dev/null || {
        echo "this build does not satisfy the Accessibility grant macOS has stored;" >&2
        echo "installing it would silently revoke Thaw's permissions — aborting" >&2
        rm -f "$REQ"; exit 1; }
    fi
    rm -f "$REQ"
  fi

  pkill -f '/Applications/Thaw.app' 2>/dev/null || true
  sleep 1
  # Stage first — never delete the working app before its replacement is on disk.
  rm -rf /Applications/.Thaw.incoming.app
  ditto "$APP" /Applications/.Thaw.incoming.app   # ditto, not cp — preserves the signature
  rm -rf /Applications/Thaw.app
  mv /Applications/.Thaw.incoming.app /Applications/Thaw.app
  open /Applications/Thaw.app
  echo "installed + launched /Applications/Thaw.app"
fi

#!/usr/bin/env bash
# One-time setup. Run ON THE MAC, in a Terminal you opened yourself:
#
#   cd ~/dev/thaw && ./setup-signing-keychain.sh
#
# Copies the Apple Development signing identity into a dedicated keychain whose
# password is stored on disk, so `build-local.sh` can sign from a non-GUI ssh
# session. Without it only a GUI session can sign, the nightly upstream-sync
# build cannot sign at all, and an ad-hoc build installed in its place silently
# kills every TCC grant Thaw holds — System Settings keeps showing the checkbox
# ticked while macOS denies the app. See FORK.md "Signing".
#
# Undo:  security delete-keychain ~/Library/Keychains/thaw-signing.keychain-db
#        rm -f ~/.config/signing/thaw-keychain.pw
set -euo pipefail

IDENTITY="Apple Development: clinton.cunningham@gmail.com (HJH7DK6VNJ)"
KC="$HOME/Library/Keychains/thaw-signing.keychain-db"
PWFILE="$HOME/.config/signing/thaw-keychain.pw"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

# Test the capability rather than guessing from $SSH_CONNECTION — a Terminal
# launched by `open` from an ssh session inherits that variable while still
# being a perfectly good GUI session.
if ! security show-keychain-info "$LOGIN" >/dev/null 2>&1; then
  echo "This session cannot read the login keychain, which is where the identity starts." >&2
  echo "Open Terminal yourself on the Mac (Spotlight -> Terminal), then run this again." >&2
  exit 1
fi

if [ -e "$KC" ]; then
  echo "$KC already exists." >&2
  echo "Delete it first if you want to redo this: security delete-keychain \"$KC\"" >&2
  exit 1
fi

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

TMPD=$(mktemp -d -t thaw-signing)
P12="$TMPD/identities.p12"

# Anything that fails partway leaves no keychain behind: a half-built one would
# block every rerun on the "already exists" check above.
KC_CREATED=0
DONE=0
cleanup() {
  rm -rf "$TMPD"
  if [ "$KC_CREATED" = 1 ] && [ "$DONE" = 0 ]; then
    security delete-keychain "$KC" 2>/dev/null || true   # also drops it from the search list
    rm -f "$PWFILE"
    echo "setup failed — removed the partial keychain, safe to run again" >&2
  fi
}
trap cleanup EXIT

umask 077
mkdir -p "$(dirname "$PWFILE")"
KCPW=$(openssl rand -base64 24)

echo "==> Exporting signing identities from the login keychain."
echo "    macOS will ask for your login password, and may ask you to allow"
echo "    access once per key. There is no way to export a single identity, so"
echo "    everything comes across and the extras are deleted again below."
security export -k "$LOGIN" -t identities -f pkcs12 -P "$KCPW" -o "$P12"

echo "==> Creating $KC"
security create-keychain -p "$KCPW" "$KC"
KC_CREATED=1
# Store the password immediately. A crash that skips the EXIT trap would
# otherwise leave a keychain whose password nobody knows, and the "already
# exists" guard above would then refuse every rerun.
printf '%s' "$KCPW" > "$PWFILE"
chmod 600 "$PWFILE"
security set-keychain-settings "$KC"          # no idle timeout, no lock on sleep
security unlock-keychain -p "$KCPW" "$KC"

# No -A. That would let every binary on the machine sign with these keys; the
# two tools named here are all that is needed, and this keychain sits unlocked
# with its password on disk.
echo "==> Importing the identities"
security import "$P12" -k "$KC" -P "$KCPW" -T /usr/bin/codesign -T /usr/bin/security

# The ACL alone is not enough: without a partition list naming codesign, a
# non-GUI session still gets errSecInternalComponent. This is the step the
# Keychain Access "Allow all applications" checkbox does not do.
echo "==> Setting the partition list"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null

echo "==> Dropping identities this build does not need"
while IFS= read -r line; do
  hash=$(printf '%s' "$line" | awk '{print $2}')
  name=${line#*\"}
  name=${name%\"*}
  [ -n "$hash" ] || continue
  [ "$name" = "$IDENTITY" ] && continue
  security delete-identity -Z "$hash" "$KC" >/dev/null 2>&1 || true
  echo "    removed $name"
done < <(security find-identity -v -p codesigning "$KC" | grep -E '^ *[0-9]+\)' || true)

# Add to the user search list so xcodebuild's automatic signing finds it, while
# keeping the keychains already there. `-s` replaces the whole list, and an
# array keeps paths containing spaces intact.
echo "==> Adding to the keychain search list"
search=()
while IFS= read -r line; do
  line=${line#*\"}
  line=${line%\"*}
  [ -n "$line" ] || continue
  [ "$line" = "$KC" ] && continue
  search+=("$line")
done < <(security list-keychains -d user)
# `-s` replaces the whole list. If the parse came back empty, writing it anyway
# would drop login.keychain-db for every app on the Mac — wifi, Safari, Xcode.
[ ${#search[@]} -gt 0 ] || {
  echo "could not read the existing keychain search list — refusing to replace it" >&2
  exit 1
}
security list-keychains -d user -s "$KC" "${search[@]}"

# Prove the whole chain works — certificate, private key, ACL, partition list —
# rather than reporting success because no command happened to fail.
echo "==> Test signature"
probe="$TMPD/probe"
cp /bin/echo "$probe"
codesign --force --sign "$IDENTITY" --keychain "$KC" "$probe" >/dev/null 2>&1 || {
  echo "FAILED: could not sign with \"$IDENTITY\" from $KC" >&2
  exit 1
}
# Capture rather than piping into `grep -q`: grep exits on first match, codesign
# takes SIGPIPE, and pipefail then reports a successful match as a failure.
PROBEINFO=$(codesign -dvvv "$probe" 2>&1)
case "$PROBEINFO" in
  *"Authority=$IDENTITY"*) ;;
  *) echo "FAILED: test signature is not from the expected identity" >&2; exit 1 ;;
esac

DONE=1
echo
security find-identity -v -p codesigning "$KC"
echo
echo "Password stored at $PWFILE (mode 600)."
echo "Done. Signed builds now work over ssh from the VM."

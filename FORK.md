# Fork notes

`clintoncodewell/Thaw`, forked from [`stonerl/Thaw`](https://github.com/stonerl/Thaw) (itself the
maintained fork of the abandoned `jordanbaird/Ice`). GPL-3.0. Default branch is `development`,
not `main`.

Why this fork exists: Ice died on 2025-09-20 and never survived macOS 26 Tahoe's menu bar rewrite.
Thaw is alive, so we track it and keep our tweaks on top rather than maintaining a menu bar
manager from scratch — there is no public API for this, it's all screen capture plus synthesised
⌘-drag events, and it breaks on every macOS release.

## Staying current

`~/operations/scripts/upstream-sync.sh` on the VM merges upstream daily at 03:05 AEST (17:05
UTC), with a catch-up pass at 07:35 AEST:

    config: /home/azureuser/operations/scripts/upstream-sync.conf
    log:    /home/azureuser/operations/logs/upstream-sync.log

Clean merge pushes straight to `development`. Conflict against our tweaks aborts the merge and
opens a PR instead, so nothing is ever lost silently. A dirty working tree makes it skip.

Thaw's config line also **deploys**: `mac-build.sh` verifies the merge builds, and on a clean
push `mac-install.sh Thaw` replaces `/Applications/Thaw.app` and restarts it. An upstream merge
therefore reaches your Mac the same night, which is why the signing rules below are load-bearing
rather than a nicety.

The log is capped at 5000 lines, so a run from a few days ago has already scrolled out of it.
`git reflog` is the reliable record of what merged and when.

## Building

The VM is Linux; the build happens on the Mac (`ssh mac`, projects land in `~/dev/<name>`).

    tomac --build                                              # quick compile check
    tomac --sync && ssh mac 'cd ~/dev/thaw && ./build-local.sh Release --install'

`build-local.sh` exists because upstream hardcodes its own `DEVELOPMENT_TEAM` in
`project.pbxproj`. Overriding on the xcodebuild command line rather than editing that file keeps
the daily merge conflict-free — don't "fix" it by editing the pbxproj.

## Signing

Builds are signed by default, from anywhere, including over ssh from the VM.

That works because of a dedicated keychain, `~/Library/Keychains/thaw-signing.keychain-db`,
holding a copy of the "Apple Development: clinton.cunningham@gmail.com" identity (team
`36H9FH5KZM`) with its password at `~/.config/signing/thaw-keychain.pw`. Created once by
`./setup-signing-keychain.sh`, which must be run in a Terminal **you opened yourself** on the
Mac. Re-run it after a machine rebuild or a certificate renewal.

The login keychain cannot be used from a non-GUI session at all: codesign returns
`errSecInternalComponent` on any binary and `security show-keychain-info` returns "User
interaction is not allowed". Setting the key's ACL to "Allow all applications" in Keychain
Access does **not** help — it applies only inside the GUI session, and it does not set the
partition list, which is the part codesign actually needs.

If signing is unavailable, `build-local.sh` exits 75 instead of quietly producing an ad-hoc
build, so `upstream-sync.sh` defers to the next run rather than blaming the merge. `--install`
additionally refuses to replace `/Applications/Thaw.app` unless the new bundle is signed with
team `36H9FH5KZM` *and* still satisfies the requirement TCC has stored, and it stages the copy
before swapping so a failure never leaves you with no app. `--adhoc` forces an unsigned build if
you ever need one.

Signing is load-bearing because TCC keys a permission grant to the **code signature**, not the
bundle ID, and stores the requirement it saw when the grant was made:

    identifier "com.stonerl.Thaw" and anchor apple generic and
    certificate leaf[subject.CN] = "Apple Development: ... (HJH7DK6VNJ)"

Install an ad-hoc build over a signed one and every grant silently stops working while System
Settings still shows the checkbox ticked. Unticking and reticking does nothing: the checkbox
only flips `auth_value`, it never rewrites the stored requirement. Test the app against the
requirement TCC actually holds:

    sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
      "select hex(csreq) from access where service='kTCCServiceAccessibility' \
       and client='com.stonerl.Thaw';" | xxd -r -p > /tmp/req.bin
    codesign --verify -R /tmp/req.bin /Applications/Thaw.app

To rescue an ad-hoc build without rebuilding signed — good until the next build, since ad-hoc
pins a cdhash that changes every time:

    tccutil reset Accessibility com.stonerl.Thaw
    tccutil reset ScreenCapture com.stonerl.Thaw

## Permissions

Thaw needs Accessibility, and Screen Recording to draw the hidden items. Approving those prompts
needs a human at the Mac and usually a relaunch to take effect; it cannot be done over ssh.
Keychain Access, if you need it, is at
`/System/Library/CoreServices/Applications/Keychain Access.app` on macOS 26 — no longer Utilities.

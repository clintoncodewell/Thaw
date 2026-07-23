# Fork notes

`clintoncodewell/Thaw`, forked from [`stonerl/Thaw`](https://github.com/stonerl/Thaw) (itself the
maintained fork of the abandoned `jordanbaird/Ice`). GPL-3.0. Default branch is `development`,
not `main`.

Why this fork exists: Ice died on 2025-09-20 and never survived macOS 26 Tahoe's menu bar rewrite.
Thaw is alive, so we track it and keep our tweaks on top rather than maintaining a menu bar
manager from scratch — there is no public API for this, it's all screen capture plus synthesised
⌘-drag events, and it breaks on every macOS release.

## Staying current

Cron on the VM merges upstream daily at 19:50 UTC (05:50 AEST):

    /home/azureuser/operations/scripts/thaw-upstream-sync.sh
    log: /home/azureuser/operations/logs/thaw-sync.log

Clean merge pushes straight to `development`. Conflict against our tweaks aborts the merge and
opens a PR instead, so nothing is ever lost silently. A dirty working tree makes it skip.

## Building

The VM is Linux; the build happens on the Mac (`ssh mac`, projects land in `~/dev/<name>`).

    tomac --build                                              # quick compile check
    tomac --sync && ssh mac 'cd ~/dev/thaw && ./build-local.sh Release --install'

`build-local.sh` exists because upstream hardcodes its own `DEVELOPMENT_TEAM` in
`project.pbxproj`. Overriding on the xcodebuild command line rather than editing that file keeps
the daily merge conflict-free — don't "fix" it by editing the pbxproj.

## Signing

`build-local.sh` signs ad-hoc by default. Signing with the real "Apple Development:
clinton.cunningham@gmail.com" identity (team `36H9FH5KZM`) fails over ssh with
`errSecInternalComponent`, because the login keychain refuses a non-GUI session
("User interaction is not allowed"). Nothing to do with the certificate — it's valid.

To enable `--signed` builds, one-time at the Mac: Keychain Access → login → Keys → the private
key under "Apple Development: clinton.cunningham@gmail.com" → Get Info → Access Control → "Allow
all applications to access this item". After that `./build-local.sh Release --install --signed`
works from the VM.

Worth doing because TCC is keyed to the code signature: an ad-hoc signature changes on every
build, so macOS re-prompts for Accessibility each time you install a fresh ad-hoc build. A stable
Developer ID signature is remembered.

## Permissions

Thaw needs Accessibility, and Screen Recording to draw the hidden items. Approving those prompts
needs a human at the Mac and usually a relaunch to take effect; it cannot be done over ssh.

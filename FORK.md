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

Always build with `--signed`, and run that build **in a GUI session on the Mac** — open
Terminal there:

    cd ~/dev/thaw && ./build-local.sh Release --install --signed

It cannot be done over ssh from the VM. A non-GUI session can't reach the login keychain at
all, so codesign returns `errSecInternalComponent` on any binary, not just this project, and
`security show-keychain-info` returns "User interaction is not allowed". Setting the private
key's ACL to "Allow all applications" does **not** fix it — that only applies inside the GUI
session. Nothing to do with the certificate ("Apple Development: clinton.cunningham@gmail.com",
team `36H9FH5KZM`), it's valid. Unattended VM builds would need a dedicated signing keychain
with a known password plus `security set-key-partition-list -k`.

`--signed` matters because TCC keys a permission grant to the **code signature**, not the bundle
ID, and stores the requirement it saw when the grant was made:

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

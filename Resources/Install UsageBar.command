#!/bin/bash
# UsageBar installer.  Copies UsageBar.app to /Applications, strips the
# macOS download-quarantine flag so the ad-hoc signature is accepted,
# and launches the app.  This exists because UsageBar isn't (yet)
# signed with a paid Apple Developer ID — without stripping quarantine
# macOS 15+ refuses to open ad-hoc-signed apps that came from the
# internet ("UsageBar is damaged").
#
# Run once, delete the folder after.  Nothing here needs sudo.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$DIR/UsageBar.app"
APP_DEST="/Applications/UsageBar.app"

fail() {
    osascript -e "display alert \"UsageBar installer\" message \"$1\" as critical"
    exit 1
}

[[ -d "$APP_SRC" ]] || fail "Can't find UsageBar.app next to this installer.  Make sure both are in the same folder and try again."

# Confirm with the user.
osascript <<'AS'
tell application "System Events"
    activate
    display dialog "Install UsageBar into your Applications folder?

This copies UsageBar.app to /Applications and strips macOS's download-quarantine flag so it can launch — required for apps that aren't signed with a paid Apple Developer certificate.

Nothing here needs an admin password." with title "UsageBar Installer" buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with icon note
end tell
AS

# Quit any running instance so we can replace the bundle.
pkill -f "$APP_DEST/Contents/MacOS/UsageBar" 2>/dev/null || true
sleep 0.3

rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

# The whole reason this script exists.
xattr -cr "$APP_DEST"

open "$APP_DEST"

osascript -e 'display dialog "UsageBar is installed and running — look for its icon in your menu bar." with title "Done" buttons {"OK"} default button "OK" with icon note'

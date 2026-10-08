#!/bin/bash
# Checks the installer without launching the app or reading user configuration.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: bash Tests/check-release-dmg.sh <image.dmg> <version>" >&2
    exit 1
fi
hdiutil verify "$1"
work=$(mktemp -d)
volume="$work/volume"
mkdir -p "$volume"
mounted=0
trap 'if [[ "$mounted" == 1 ]]; then diskutil eject "$volume" || true; fi; rm -rf "$work"' EXIT
diskutil image attach --readOnly --nobrowse --mountPoint "$volume" "$1"
mounted=1
app="$volume/PiSwitch.app"
plist="$app/Contents/Info.plist"
test "$(readlink "$volume/Applications")" = /Applications
test -x "$app/Contents/MacOS/PiSwitch"
plutil -lint "$plist"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconFile' "$plist")" = AppIcon
test -s "$app/Contents/Resources/AppIcon.icns"
test "$(head -c 4 "$app/Contents/Resources/AppIcon.icns")" = icns
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$2"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" = io.github.xichun123.PiSwitch
test "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$plist")" = "$(xcrun vtool -show-build "$app/Contents/MacOS/PiSwitch" | awk '/minos/ {print $2; exit}')"
codesign --verify --strict --verbose=2 "$app"
echo 'PASS: DMG integrity, application icon, version, deployment target, signature, and Applications link'

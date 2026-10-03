#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-}
version=${version#v}
if [[ $# != 1 || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: bash scripts/package-release.sh <version, e.g. 0.1.0>" >&2
    exit 1
fi
arch=$(uname -m)
out="$PWD/.build/release-v$version"
dmg="$out/PiSwitch-v$version-macos-$arch.dmg"
if [[ -e "$dmg" ]]; then
    echo "Refusing to overwrite $dmg" >&2
    exit 1
fi
swift build -c release --arch "$arch"
bin=$(swift build -c release --arch "$arch" --show-bin-path)
min_os=$(xcrun vtool -show-build "$bin/PiSwitch" | awk '/minos/ {print $2; exit}')
[[ "$min_os" =~ ^[0-9]+(\.[0-9]+)*$ ]]
mkdir -p "$out"
staging=$(mktemp -d "$out/staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/PiSwitch.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/PiSwitch" "$app/Contents/MacOS/PiSwitch"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PiSwitch</string>
<key>CFBundleDisplayName</key><string>PiSwitch</string>
<key>CFBundleIdentifier</key><string>io.github.xichun123.PiSwitch</string>
<key>CFBundleExecutable</key><string>PiSwitch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>$min_os</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# ponytail: ad-hoc only; add Developer ID signing and notarization when credentials are available.
codesign --force --sign - "$app"
ln -s /Applications "$staging/Applications"
diskutil image create from --format UDZO --volumeName PiSwitch "$staging" "$dmg"
bash Tests/check-release-dmg.sh "$dmg" "$version"
shasum -a 256 "$dmg"

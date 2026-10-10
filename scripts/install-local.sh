#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app=/Applications/PiSwitch.app
process='^/Applications/PiSwitch\.app/Contents/MacOS/PiSwitch([[:space:]]|$)'
if [[ ! -d "$app" || -L "$app" || ! -w /Applications ]]; then
    echo "需要已有的 $app，且 /Applications 可写。" >&2
    exit 1
fi

swift build -c release
bin=$(swift build -c release --show-bin-path)
staging=$(mktemp -d /Applications/.PiSwitch-install.XXXXXX)
trap 'rm -rf "$staging"' EXIT
next="$staging/PiSwitch.app"
# shortcut: reuse installed bundle metadata; use a shared packager for first installs or metadata changes.
ditto "$app" "$next"
cp "$bin/PiSwitch" "$next/Contents/MacOS/PiSwitch"
cp Resources/AppIcon.icns "$next/Contents/Resources/AppIcon.icns"
[[ -x "$next/Contents/MacOS/PiSwitch" ]]
codesign --force --sign - "$next"

if pgrep -f "$process" >/dev/null; then
    echo "正在退出 PiSwitch；如有未保存修改，请在软件中处理。"
    if ! osascript -e 'with timeout of 15 seconds' -e 'tell application "/Applications/PiSwitch.app" to quit' -e 'end timeout'; then
        echo "退出未完成，未替换安装；处理未保存修改后重试。" >&2
        exit 1
    fi
    for _ in {1..50}; do
        if ! pgrep -f "$process" >/dev/null; then break; fi
        sleep 0.2
    done
fi
if pgrep -f "$process" >/dev/null; then
    echo "PiSwitch 仍在运行，未替换安装；请退出后重试。" >&2
    exit 1
fi

backup_dir=$(mktemp -d "$PWD/.build/install-local.XXXXXX")
backup="$backup_dir/PiSwitch.previous.app"
mv "$app" "$backup"
echo "旧安装备份：$backup"
if ! mv "$next" "$app"; then
    echo "安装失败，正在恢复旧安装；若恢复失败，旧包仍在上述备份路径。" >&2
    mv "$backup" "$app"
    open "$app"
    exit 1
fi
open "$app"
echo "已安装并重新打开 PiSwitch。"

#!/bin/bash
# Isolated Skills preview; requires existing System Events accessibility permission.
set -euo pipefail
swift build
bin=$(swift build --show-bin-path)
tmp=$(mktemp -d)
pid=""
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos27.0" -I "$bin" -I .build/checkouts/Yams/Sources/CYaml/include \
    Tests/SkillsUICheck.swift Sources/PiSwitch/App/SkillsModel.swift Sources/PiSwitch/App/AppModel.swift \
    Sources/PiSwitch/App/WindowCloseGuard.swift Sources/PiSwitch/Views/*.swift \
    "$bin/PiSwitchCore.o" "$bin/Yams.o" "$bin/CYaml.o" -o "$tmp/SkillsUICheck"
"$tmp/SkillsUICheck" "$tmp" > "$tmp/log" 2>&1 &
pid=$!
if ! osascript - "$pid" <<'APPLESCRIPT'
on clickNamed(p, labelText)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if (name of node is labelText or description of node is labelText) and role of node is in {"AXButton", "AXRadioButton"} then
                click node
                delay 0.3
                return
            end if
        end repeat
        error "Missing button: " & labelText
    end tell
end clickNamed
on countCheckboxes(p)
    tell application "System Events"
        set countFound to 0
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXCheckBox" then set countFound to countFound + 1
        end repeat
        return countFound
    end tell
end countCheckboxes
on run argv
    set pid to item 1 of argv as integer
    tell application "System Events"
        repeat 100 times
            if exists (first process whose unix id is pid) then
                set p to first process whose unix id is pid
                if exists window 1 of p then exit repeat
            end if
            delay 0.1
        end repeat
    end tell
    clickNamed(p, "Skills")
    if countCheckboxes(p) is less than 2 then error "Skills unavailable after model config failure"
    clickNamed(p, "全局")
    if countCheckboxes(p) is less than 4 then error "Missing global switches"
    clickNamed(p, "项目")
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        set clickedAdd to false
        repeat with node in nodes
            if role of node is "AXButton" and exists attribute "AXIdentifier" of node then
                if value of attribute "AXIdentifier" of node is "skills-add" then
                    click node
                    set clickedAdd to true
                    exit repeat
                end if
            end if
        end repeat
        if not clickedAdd then error "Missing add button"
        delay 0.3
        if not (exists sheet 1 of window 1 of p) then error "Missing add sheet"
        set fields to 0
        set nodes to entire contents of sheet 1 of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextField" then set fields to fields + 1
        end repeat
        if fields is not 1 then error "Missing repository address field"
    end tell
    return "PASS: independent Skills tab after model load failure, selection, global/project views, repository sheet"
end run
APPLESCRIPT
then
    cat "$tmp/log"
    exit 1
fi
cat "$tmp/log"

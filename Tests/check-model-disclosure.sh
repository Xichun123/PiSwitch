#!/bin/bash
# Run from the project root; requires macOS System Events accessibility permission.
# Uses only two fictional models, never the user's configuration.
set -euo pipefail
swift build
tmp=$(mktemp -d)
pid=""
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
python3 - "$tmp/Check.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/PiSwitch/Views/ProviderEditorView.swift').read_text()
model = source[source.index('private struct ModelSection'):source.rindex('#endif')]
Path(sys.argv[1]).write_text('''import SwiftUI
import AppKit
import PiSwitchCore
struct ProviderEditorView { static let apiPresets = ["openai-responses", "anthropic-messages"] }
''' + model + '''
struct Fixture: View {
    @State var models = [ModelDraft(json: ["id": .string("alpha"), "input": .array([.string("text"), .string("image")])]), ModelDraft(json: ["id": .string("beta")])]
    var body: some View {
        Form {
            ForEach($models) { $model in
                ModelSection(model: $model, providerAPI: "openai-responses", providerBaseURL: "https://proxy.example/v1") {
                    models.removeAll { $0.id == model.id }
                }
            }
        }.formStyle(.grouped).frame(width: 850, height: 850)
    }
}
@main struct Check {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 850), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ModelDisclosureCheck"
        window.contentView = NSHostingView(rootView: Fixture())
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
''')
PY
bin=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$bin" -I .build/checkouts/Yams/Sources/CYaml/include \
    "$tmp/Check.swift" "$bin/PiSwitchCore.o" "$bin/Yams.o" "$bin/CYaml.o" -o "$tmp/ModelDisclosureCheck"
"$tmp/ModelDisclosureCheck" > "$tmp/log" 2>&1 &
pid=$!
osascript - "$pid" <<'APPLESCRIPT'
on checkState(pid, expectedFields, expectedCollapsed, expectedExpanded)
    tell application "System Events"
        set p to first process whose unix id is pid
        set fields to 0
        set collapsed to 0
        set expandedCount to 0
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextField" then set fields to fields + 1
            if role of node is "AXButton" then
                if value of node is "已折叠" then set collapsed to collapsed + 1
                if value of node is "已展开" then set expandedCount to expandedCount + 1
            end if
        end repeat
        if {fields, collapsed, expandedCount} is not {expectedFields, expectedCollapsed, expectedExpanded} then error "Unexpected fields/collapsed/expanded counts: " & fields & "/" & collapsed & "/" & expandedCount
    end tell
end checkState

on toggleFirst(pid, state)
    tell application "System Events"
        set p to first process whose unix id is pid
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXButton" and value of node is state then
                click node
                delay 0.3
                return
            end if
        end repeat
        error "Missing model toggle"
    end tell
end toggleFirst

on checkInput(pid, textValue, imageValue)
    tell application "System Events"
        set p to first process whose unix id is pid
        set nodes to entire contents of window 1 of p
        set found to 0
        repeat with node in nodes
            if role of node is "AXCheckBox" then
                if value of attribute "AXIdentifier" of node is "model-input-text" then
                    if value of node is not textValue then error "Unexpected text selection: actual=" & value of node & ", expected=" & textValue
                    set found to found + 1
                else if value of attribute "AXIdentifier" of node is "model-input-image" then
                    if value of node is not imageValue then error "Unexpected image selection: actual=" & value of node & ", expected=" & imageValue
                    set found to found + 1
                end if
            end if
        end repeat
        if found is not 2 then error "Missing input checkboxes"
    end tell
end checkInput

on checkUserAgent(pid, expectedEnabled, expectedText)
    tell application "System Events"
        set p to first process whose unix id is pid
        set foundToggle to false
        set foundField to false
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXCheckBox" then
                if value of attribute "AXIdentifier" of node is "model-user-agent-enabled" then
                    if value of node is not expectedEnabled then error "Unexpected UA switch state"
                    set foundToggle to true
                end if
            else if role of node is "AXTextField" then
                if name of node is "User-Agent" then
                    if value of node is not expectedText then error "Unexpected UA text: " & value of node
                    set foundField to true
                end if
            end if
        end repeat
        if not foundToggle then error "Missing UA switch"
        if foundField is not (expectedEnabled is 1) then error "Unexpected UA field visibility"
    end tell
end checkUserAgent

on toggleUserAgent(pid)
    tell application "System Events"
        set p to first process whose unix id is pid
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXCheckBox" then
                if value of attribute "AXIdentifier" of node is "model-user-agent-enabled" then
                    click node
                    delay 0.3
                    return
                end if
            end if
        end repeat
        error "Missing UA switch"
    end tell
end toggleUserAgent

on run argv
    set pid to item 1 of argv as integer
    tell application "System Events"
        repeat 50 times
            if exists (first process whose unix id is pid) then
                set p to first process whose unix id is pid
                if exists window 1 of p then exit repeat
            end if
            delay 0.1
        end repeat
    end tell
    checkState(pid, 0, 2, 0)
    toggleFirst(pid, "已折叠")
    checkState(pid, 9, 1, 1)
    checkInput(pid, 1, 1)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXCheckBox" then
                if value of attribute "AXIdentifier" of node is "model-input-text" then
                    click node
                    exit repeat
                end if
            end if
        end repeat
    end tell
    delay 0.3
    checkInput(pid, 0, 1)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextField" and name of node is "名称" then
                set frontmost of p to true
                click node
                delay 0.2
                set focused of node to true
                keystroke "a" using command down
                keystroke "Edited"
                key code 48
                delay 0.3
            end if
        end repeat
    end tell
    toggleFirst(pid, "已展开")
    checkState(pid, 0, 2, 0)
    toggleFirst(pid, "已折叠")
    checkState(pid, 9, 1, 1)
    checkInput(pid, 0, 1)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextField" and name of node is "名称" then
                if value of node is not "Edited" then error "Collapsed model lost its edit: " & value of node
            end if
        end repeat
    end tell
    checkUserAgent(pid, 0, "")
    toggleUserAgent(pid)
    checkState(pid, 10, 1, 1)
    checkUserAgent(pid, 1, "claude-cli/2.1.295 (external, cli)")
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextField" then
                if name of node is "User-Agent" then
                    set frontmost of p to true
                    click node
                    delay 0.2
                    set focused of node to true
                    set value of node to "Custom/2.0"
                    key code 48
                    delay 0.3
                    exit repeat
                end if
            end if
        end repeat
    end tell
    toggleFirst(pid, "已展开")
    checkState(pid, 0, 2, 0)
    toggleFirst(pid, "已折叠")
    checkState(pid, 10, 1, 1)
    checkUserAgent(pid, 1, "Custom/2.0")
    toggleUserAgent(pid)
    checkState(pid, 9, 1, 1)
    checkUserAgent(pid, 0, "")
    toggleUserAgent(pid)
    checkUserAgent(pid, 1, "Custom/2.0")
    return "PASS: default collapse, input checkboxes, UA switch/default/edit, and retained edits"
end run
APPLESCRIPT

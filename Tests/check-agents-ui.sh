#!/bin/bash
# Uses fictional configuration and an isolated library; needs existing accessibility permission.
set -euo pipefail
swift build
bin=$(swift build --show-bin-path)
tmp=$(mktemp -d)
pid=""
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos27.0" -I "$bin" -I .build/checkouts/Yams/Sources/CYaml/include \
    Tests/AgentsUICheck.swift Sources/PiSwitch/App/AgentsModel.swift Sources/PiSwitch/App/SkillsModel.swift Sources/PiSwitch/App/AppModel.swift \
    Sources/PiSwitch/App/WindowCloseGuard.swift Sources/PiSwitch/Views/*.swift \
    "$bin/PiSwitchCore.o" "$bin/Yams.o" "$bin/CYaml.o" -o "$tmp/AgentsUICheck"
"$tmp/AgentsUICheck" "$tmp" > "$tmp/log" 2>&1 &
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
        error "Missing control: " & labelText
    end tell
end clickNamed
on clickIdentifier(p, identifierText)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXButton" and exists attribute "AXIdentifier" of node then
                if value of attribute "AXIdentifier" of node is identifierText then
                    click node
                    delay 0.3
                    return
                end if
            end if
        end repeat
        error "Missing button identifier: " & identifierText
    end tell
end clickIdentifier
on findIdentifier(p, identifierText)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if exists attribute "AXIdentifier" of node then
                if value of attribute "AXIdentifier" of node is identifierText then return true
            end if
        end repeat
        return false
    end tell
end findIdentifier
on checkAgentsLayout(p)
    set tabBottom to missing value
    set reloadY to missing value
    set sidebarY to missing value
    set reloadTipFound to false
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if (name of node is "AGENTS" or description of node is "AGENTS") and role of node is in {"AXButton", "AXRadioButton"} then
                set tabPosition to position of node
                set tabSize to size of node
                set tabBottom to (item 2 of tabPosition) + (item 2 of tabSize)
            end if
            if exists attribute "AXIdentifier" of node then
                if value of attribute "AXIdentifier" of node is "agents-reload" then
                    set reloadPosition to position of node
                    set reloadY to item 2 of reloadPosition
                end if
                if value of attribute "AXIdentifier" of node is "agents-new" then
                    set sidebarPosition to position of node
                    set sidebarY to item 2 of sidebarPosition
                end if
            end if
            if role of node is "AXStaticText" then
                set textValue to value of node
                if textValue is "实际指令变化后执行 /reload。" then set reloadTipFound to true
                if textValue contains "磁盘状态不代表" or textValue contains "首版不自动跟随" then error "Removed AGENTS footer text is still visible"
            end if
        end repeat
    end tell
    if tabBottom is missing value or reloadY is missing value or sidebarY is missing value then error "Missing AGENTS layout controls"
    set headerGap to reloadY - tabBottom
    if headerGap < 0 or headerGap > 48 then error "Excessive blank space above AGENTS header: " & headerGap
    set sidebarGap to sidebarY - reloadY
    if sidebarGap < 0 or sidebarGap > 110 then error "Excessive blank space above AGENTS split content: " & sidebarGap
    if not reloadTipFound then error "Missing retained /reload tip"
    log "AGENTS header gap: " & headerGap & " points, sidebar offset: " & sidebarGap & " points"
end checkAgentsLayout
on checkGlobalList(p, selectVersion)
    tell application "System Events"
        set firstCard to missing value
        set cardCount to 0
        set viewportHeight to missing value
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if exists attribute "AXIdentifier" of node then
                set identifierText to value of attribute "AXIdentifier" of node
                if identifierText is "agents-list" then
                    set scrollArea to node
                    repeat 5 times
                        if role of scrollArea is "AXScrollArea" then exit repeat
                        set scrollArea to value of attribute "AXParent" of scrollArea
                    end repeat
                    set viewportSize to size of scrollArea
                    set viewportHeight to item 2 of viewportSize
                end if
                if role of node is "AXButton" and identifierText starts with "agents-entry-" then
                    set cardCount to cardCount + 1
                    if firstCard is missing value then set firstCard to node
                end if
            end if
        end repeat
        if viewportHeight is missing value or viewportHeight < 96 then error "Collapsed AGENTS card viewport"
        if cardCount < 2 or cardCount > 3 then error "Expected accessible global version cards, got " & cardCount
        log "AGENTS card viewport: " & viewportHeight & " points, cards: " & cardCount
        if selectVersion then
            click firstCard
            delay 0.5
        end if
    end tell
end checkGlobalList
on enterSearch(p, queryText)
    if queryText is "" then
        clickIdentifier(p, "management-search-clear")
        return
    end if
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextField" then
                if exists attribute "AXIdentifier" of node then
                    if value of attribute "AXIdentifier" of node is "agents-search" then
                        set frontmost of p to true
                        set value of attribute "AXFocused" of node to true
                        keystroke "a" using command down
                        keystroke queryText
                        key code 36 -- Commit marked text before checking the filtered view.
                        delay 0.3
                        return
                    end if
                end if
            end if
        end repeat
        error "Missing AGENTS search field"
    end tell
end enterSearch
on editDraft(p, draftText)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextArea" then
                set frontmost of p to true
                set value of attribute "AXFocused" of node to true
                set value of node to draftText
                delay 0.3
                return
            end if
        end repeat
        error "Missing editable AGENTS text area"
    end tell
end editDraft
on checkDraft(p, expectedText)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextArea" then
                set actualText to value of node
                if actualText is not expectedText then error "Search or section cancellation changed the draft: " & actualText
                return
            end if
        end repeat
        error "Search removed the AGENTS editor"
    end tell
end checkDraft
on run argv
    set pid to item 1 of argv as integer
    tell application "System Events"
        repeat 200 times
            if exists (first process whose unix id is pid) then
                set p to first process whose unix id is pid
                if exists window 1 of p then
                    if name of window 1 of p is "AgentsUICheck" then exit repeat
                end if
            end if
            delay 0.1
        end repeat
    end tell
    if findIdentifier(p, "agents-editor") then error "Expected no version selected on initial load"
    tell application "System Events" to set position of window 1 of p to {100, 40}
    repeat with windowSize in {{1100, 800}, {1040, 700}, {820, 600}}
        tell application "System Events" to set size of window 1 of p to contents of windowSize
        delay 0.3
        tell application "System Events" to set actualWindowSize to size of window 1 of p
        set requestedSize to contents of windowSize
        if actualWindowSize is not requestedSize then error "AGENTS window size mismatch: " & (item 1 of actualWindowSize) & " x " & (item 2 of actualWindowSize)
        checkAgentsLayout(p)
        checkGlobalList(p, false)
    end repeat
    checkGlobalList(p, true)
    tell application "System Events" to set size of window 1 of p to {820, 600}
    delay 0.3
    tell application "System Events" to set selectedWindowSize to size of window 1 of p
    if selectedWindowSize is not {820, 600} then error "Selected editor window: " & (item 1 of selectedWindowSize) & " x " & (item 2 of selectedWindowSize)
    if not findIdentifier(p, "agents-editor") then error "Visible version row did not open the AGENTS editor"
    if not findIdentifier(p, "agents-apply") then error "Missing explicit global apply control"
    editDraft(p, "ui draft preserved")
    enterSearch(p, "no matching version")
    checkDraft(p, "ui draft preserved")
    enterSearch(p, "")
    checkDraft(p, "ui draft preserved")
    clickIdentifier(p, "agents-section-templates")
    clickNamed(p, "取消")
    checkDraft(p, "ui draft preserved")
    clickIdentifier(p, "agents-save")
    delay 0.5
    clickIdentifier(p, "agents-section-templates")
    clickIdentifier(p, "agents-section-projects")
    if not findIdentifier(p, "agents-add-project") then
        tell application "System Events"
            set nodes to entire contents of window 1 of p
        repeat with node in nodes
                if role of node is in {"AXButton", "AXRadioButton"} then log {role of node, name of node, description of node}
            end repeat
        end tell
        error "Missing project picker"
    end if
    clickNamed(p, "模型")
    if findIdentifier(p, "agents-editor") then error "AGENTS editor leaked into model page"
    clickNamed(p, "AGENTS")
    clickIdentifier(p, "agents-section-global")
    if not findIdentifier(p, "agents-import-global") then error "Missing initial import"
    return "PASS: compact AGENTS header, visible unselected version cards, card selection, search preserves draft, section cancel protection, independent AGENTS tab after model failure, explicit save/apply, project picker, scoped editor"
end run
APPLESCRIPT
then
    cat "$tmp/log"
    exit 1
fi
cat "$tmp/log"
grep -q '^PASS: isolated AGENTS' "$tmp/log"

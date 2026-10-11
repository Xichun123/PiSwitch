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
    Sources/PiSwitch/App/WindowCloseGuard.swift Sources/PiSwitch/App/AgentsModel.swift Sources/PiSwitch/Views/*.swift \
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
            if role of node is in {"AXCheckBox", "AXSwitch"} then set countFound to countFound + 1
        end repeat
        return countFound
    end tell
end countCheckboxes
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
on searchSkills(p, queryText)
    if queryText is "" then
        clickIdentifier(p, "management-search-clear")
        return
    end if
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXTextField" then
                set frontmost of p to true
                set value of attribute "AXFocused" of node to true
                keystroke "a" using command down
                keystroke queryText
                key code 36 -- Commit marked text when the current input method uses composition.
                delay 0.3
                return
            end if
        end repeat
        error "Missing Skills search field"
    end tell
end searchSkills
on checkSelected(p, expectedCount)
    tell application "System Events"
        set countFound to 0
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if role of node is "AXCheckBox" and value of node is 1 then set countFound to countFound + 1
        end repeat
        if countFound is not expectedCount then error "Unexpected selected cards: " & countFound
    end tell
end checkSelected
on cardHeights(p)
    tell application "System Events"
        set heights to {}
        set seen to {}
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            try
                if role of node is in {"AXGroup", "AXUnknown"} and exists attribute "AXIdentifier" of node then
                    set identifierText to value of attribute "AXIdentifier" of node
                    if identifierText starts with "skill-card-" and identifierText is not in seen then
                        set dimensions to size of node
                        set end of heights to item 2 of dimensions
                        set end of seen to identifierText
                    end if
                end if
            on error errorMessage number errorNumber
                -- Selectable text may expose an unresolvable duplicate AX child; both cards are still required below.
                if errorNumber is not -1728 then error errorMessage number errorNumber
            end try
        end repeat
        if (count of heights) is not 2 then error "Expected two measurable skill cards"
        return heights
    end tell
end cardHeights
on toggleDetails(p)
    tell application "System Events"
        set nodes to entire contents of window 1 of p
        repeat with node in nodes
            if exists attribute "AXIdentifier" of node then
                set identifierText to value of attribute "AXIdentifier" of node
                if identifierText starts with "skill-details-" then
                    set availableActions to actions of node
                    repeat with controlAction in availableActions
                        if name of controlAction is "AXPress" then
                            perform action "AXPress" of node
                            delay 0.3
                            return
                        end if
                    end repeat
                end if
            end if
        end repeat
        error "Missing skill details disclosure action"
    end tell
end toggleDetails
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
    tell application "System Events" to set position of window 1 of p to {100, 40}
    repeat with windowSize in {{1080, 740}, {820, 600}}
        tell application "System Events" to set size of window 1 of p to contents of windowSize
        delay 0.3
        tell application "System Events" to set actualWindowSize to size of window 1 of p
        set requestedSize to contents of windowSize
        if actualWindowSize is not requestedSize then error "Skills enlarged the requested window"
        if countCheckboxes(p) is not 2 then error "Cards missing after resize"
        set collapsedHeights to cardHeights(p)
        if (item 1 of collapsedHeights) is not (item 2 of collapsedHeights) then error "Long and short descriptions changed collapsed card height"
        if item 1 of windowSize is 1080 then
            toggleDetails(p)
            set expandedHeights to cardHeights(p)
            if (item 1 of expandedHeights) <= (item 1 of collapsedHeights) then error "Details did not expand the long description"
            toggleDetails(p)
            if cardHeights(p) is not collapsedHeights then error "Collapsing details did not restore card heights"
        end if
    end repeat
    clickIdentifier(p, "skills-select-all")
    checkSelected(p, 2)
    searchSkills(p, "working")
    if countCheckboxes(p) is not 1 then error "Search did not narrow card results"
    checkSelected(p, 0)
    clickIdentifier(p, "skills-select-all")
    checkSelected(p, 1)
    clickIdentifier(p, "skills-filter-global")
    if countCheckboxes(p) is not 0 then error "Unenabled skill leaked through global filter"
    searchSkills(p, "")
    clickIdentifier(p, "skills-filter-all")
    if countCheckboxes(p) is not 2 then error "Clear search did not restore cards"
    checkSelected(p, 0)
    clickIdentifier(p, "skills-scope-global")
    if countCheckboxes(p) is less than 4 then error "Missing global switches"
    clickIdentifier(p, "skills-scope-project")
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
    return "PASS: independent Skills tab after model load failure, adaptive cards, equal two-line summaries, full-description expand/collapse, search, filter, visible-only selection reset, global/project views, repository sheet"
end run
APPLESCRIPT
then
    cat "$tmp/log"
    exit 1
fi
cat "$tmp/log"

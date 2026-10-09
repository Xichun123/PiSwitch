#!/bin/bash
# Run from the project root; requires macOS accessibility permission.
# Compiles the real views and uses only temporary, fictional model/Skills data.
set -euo pipefail
swift build
work=$(mktemp -d)
pid=""
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
bin=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$bin" -I .build/checkouts/Yams/Sources/CYaml/include \
    Sources/PiSwitch/App/AppModel.swift Sources/PiSwitch/App/SkillsModel.swift \
    Sources/PiSwitch/App/WindowCloseGuard.swift Sources/PiSwitch/Views/*.swift \
    Tests/SidebarUICheck.swift "$bin/PiSwitchCore.o" "$bin/Yams.o" "$bin/CYaml.o" -o "$work/SidebarUICheck"
for scenario in clean dirty clean; do
    PISWITCH_UI_TEST_ROOT="$work/data" "$work/SidebarUICheck" "--$scenario" > "$work/log" 2>&1 &
    pid=$!
    sleep 2
    "$work/SidebarUICheck" --probe "$pid"
    result=0
    wait "$pid" || result=$?
    pid=""
    cat "$work/log"
    grep -q 'RESULT: column_changes=12, overflow_samples=0, collapsed_minimum=true, draft_and_file_unchanged=true' "$work/log"
    [[ "$result" == 0 ]]
    rm -rf "$work/data"
done

#!/bin/bash
#
# Logic checks for the parts of the client that are pure Swift: the ported
# stats/outline arithmetic and the demo backend's HAL contract.
#
# These compile the app's own sources directly with swiftc — there is no Xcode
# test target, so nothing here touches project.pbxproj. Anything needing UIKit
# or a running app is out of scope; use scripts/demo.sh for that.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripty"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

SHARED=(
    "$SRC/HAL/HALLink.swift"
    "$SRC/HAL/HALCollection.swift"
    "$SRC/HAL/Rel.swift"
)

status=0

echo "== ScriptStats / ScriptOutline =="
swiftc -o "$BUILD/stats" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/ScriptStats.swift" \
    "$SRC/Models/ScriptOutline.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/ScriptStats/main.swift"
"$BUILD/stats" || status=1

echo
echo "== Screenplay pagination =="
swiftc -o "$BUILD/pagination" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/ScreenplayLayout.swift" \
    "$SRC/Models/PageSetup.swift" \
    "$SRC/Models/ScriptPagination.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Pagination/main.swift"
"$BUILD/pagination" || status=1

echo
echo "== Presentation settings =="
swiftc -o "$BUILD/presentation" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/PageSetup.swift" \
    "$SRC/Models/ScreenplayLayout.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/PresentationSettings/main.swift"
"$BUILD/presentation" || status=1

echo
echo "== Script autocomplete =="
swiftc -o "$BUILD/autocomplete" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/Person.swift" \
    "$SRC/Models/ScriptAutocomplete.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Autocomplete/main.swift"
"$BUILD/autocomplete" || status=1

echo
echo "== Fountain paste parsing =="
swiftc -o "$BUILD/fountain" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/FountainDetect.swift" \
    "$SRC/Models/FountainScript.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/FountainScript/main.swift"
"$BUILD/fountain" || status=1

echo
echo "== Demo backend API contract =="
swiftc -o "$BUILD/api" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/APIContract/main.swift"
"$BUILD/api" || status=1

echo
if [ "$status" -eq 0 ]; then
    echo "All logic checks passed."
else
    echo "Logic checks FAILED."
fi
exit "$status"

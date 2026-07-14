#!/bin/bash
#
# One-shot shortcut: build Scripty and launch it in an iPad simulator
# straight into the offline demo (sample screenplay, no account, no backend).
#
#   ./scripts/demo.sh                     # newest-runtime iPad simulator
#   SCRIPTY_DEMO_SIM="iPhone 17" ./scripts/demo.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="scripty.scripty"

# Resolve a simulator UDID (names repeat across runtimes, UDIDs don't):
# prefer $SCRIPTY_DEMO_SIM by name, else an iPad, else any iPhone — always
# from the newest installed iOS runtime.
UDID=$(xcrun simctl list -j devices available | /usr/bin/python3 -c '
import json, os, sys

data = json.load(sys.stdin)
wanted = os.environ.get("SCRIPTY_DEMO_SIM", "")
runtimes = sorted(
    (rt for rt in data["devices"] if "iOS" in rt),
    key=lambda rt: [int(part) for part in rt.rsplit("-", 2)[-2:]],
    reverse=True)

def pick(match):
    for runtime in runtimes:
        for device in data["devices"][runtime]:
            if match(device["name"]):
                return device
    return None

device = None
if wanted:
    device = pick(lambda name: name == wanted)
    if device is None:
        sys.exit(f"No available simulator named {wanted!r}")
device = device or pick(lambda name: name.startswith("iPad")) \
                or pick(lambda name: name.startswith("iPhone"))
if device is None:
    sys.exit("No available iOS simulator found. Install one via Xcode > Settings > Components.")
print(device["udid"], device["name"], sep="\t")
' | head -1)
SIM_ID="${UDID%%$'\t'*}"
SIM_NAME="${UDID##*$'\t'}"
echo "Using simulator: $SIM_NAME ($SIM_ID)"

DESTINATION="platform=iOS Simulator,id=$SIM_ID"

echo "Building scripty…"
xcodebuild -project scripty.xcodeproj -scheme scripty \
    -destination "$DESTINATION" -configuration Debug -quiet build

APP_PATH=$(xcodebuild -project scripty.xcodeproj -scheme scripty \
    -destination "$DESTINATION" -configuration Debug -showBuildSettings 2>/dev/null |
    awk -F' = ' '/TARGET_BUILD_DIR/ { dir=$2 } /WRAPPER_NAME/ { app=$2 } END { print dir "/" app }')

xcrun simctl boot "$SIM_ID" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$SIM_ID" "$APP_PATH"
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" -scripty.demo YES

echo "Scripty demo launched on $SIM_NAME."

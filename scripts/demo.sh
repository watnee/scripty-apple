#!/bin/bash
#
# One-shot shortcut: build Scripty and launch it in a simulator straight into
# the offline demo (sample screenplay, no account, no backend).
#
#   ./scripts/demo.sh                       # a simulator already up, else an iPad
#   ./scripts/demo.sh --device "iPhone 17"  # pick a simulator by name
#   ./scripts/demo.sh --ipad                # insist on an iPad
#   ./scripts/demo.sh --iphone              # insist on an iPhone
#   ./scripts/demo.sh --no-build            # relaunch what is already installed
#   ./scripts/demo.sh --reset               # discard edits made in a past demo
#
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="scripty.xcodeproj"
SCHEME="scripty"
DEVICE="${SCRIPTY_DEMO_SIM:-}"
CLASS=""         # "", "iPad" or "iPhone"
BUILD=1
RESET=0

usage() {
    sed -n '3,11p' "$0" | cut -c3-
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE="${2:-}"; [ -n "$DEVICE" ] || usage 1; shift 2 ;;
        --ipad) CLASS=iPad; shift ;;
        --iphone) CLASS=iPhone; shift ;;
        --no-build) BUILD=0; shift ;;
        --reset) RESET=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! xcrun -f xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode, then point the tools at it:" >&2
    echo "  sudo xcode-select --switch /Applications/Xcode.app" >&2
    exit 1
fi

# Resolve a simulator UDID (names repeat across runtimes, UDIDs don't). One
# that is already booted wins: booting a second device costs more than the
# whole build on an older Mac, and the one on screen is the one you meant.
# Only when nothing is up does this fall back to an iPad, then an iPhone,
# from the newest installed runtime. Name a device to stay off a simulator
# another session is driving.
SIMULATOR=$(xcrun simctl list -j devices available |
    SCRIPTY_DEMO_SIM="$DEVICE" SCRIPTY_DEMO_CLASS="$CLASS" /usr/bin/python3 -c '
import json, os, sys

data = json.load(sys.stdin)
wanted = os.environ.get("SCRIPTY_DEMO_SIM", "")
klass = os.environ.get("SCRIPTY_DEMO_CLASS", "")
runtimes = sorted(
    (rt for rt in data["devices"] if "iOS" in rt),
    key=lambda rt: [int(part) for part in rt.rsplit("-", 2)[-2:]],
    reverse=True)

def pick(match, booted_only=False):
    for runtime in runtimes:
        for device in data["devices"][runtime]:
            if device["state"] != "Booted" and booted_only:
                continue
            if match(device["name"]):
                return device
    return None

device = None
if wanted:
    # Several runtimes carry a device of the same name, so let a booted one
    # answer to it first — that is the one already on screen.
    device = pick(lambda name: name == wanted, True) or pick(lambda name: name == wanted)
    if device is None:
        sys.exit(f"No available simulator named {wanted!r}. "
                 "List them with: xcrun simctl list devices available")

for booted_only in (True, False):
    for prefix in [klass] if klass else ["iPad", "iPhone"]:
        device = device or pick(lambda name: name.startswith(prefix), booted_only)
if device is None:
    sys.exit("No available iOS simulator found. Install one via Xcode > Settings > Components.")
print(device["udid"], device["state"], device["name"], sep="\t")
')
IFS=$'\t' read -r SIM_ID SIM_STATE SIM_NAME <<<"$SIMULATOR"
DESTINATION="platform=iOS Simulator,id=$SIM_ID"

# Boot beside the build rather than after it. `simctl install` still fails on
# a device that is mid-boot, so the wait stays — it just happens during the
# compile instead of being added to it (-b boots it first if needed).
boot() {
    xcrun simctl bootstatus "$SIM_ID" -b >/dev/null
    # Naming the device only takes when Simulator is not already running; when
    # it is, this brings its window forward the way it always did.
    if pgrep -qx Simulator; then
        open -a Simulator
    else
        open -a Simulator --args -CurrentDeviceUDID "$SIM_ID"
    fi
}
if [ "$SIM_STATE" = Booted ]; then
    echo "Simulator: $SIM_NAME ($SIM_ID) — already up"
else
    echo "Simulator: $SIM_NAME ($SIM_ID) — booting while it builds"
fi
boot & BOOT_PID=$!
trap 'kill "$BOOT_PID" 2>/dev/null || true' EXIT

# Ask the build system for the bundle id and the .app path rather than
# hardcoding them, so renaming the target can't silently break the shortcut.
# Asking costs a few seconds and the answer only moves when the project file
# does, so keep it under that file's fingerprint and ask again when it changes.
CACHE="$HOME/Library/Caches/scripty-demo"
KEY=$({ printf '%s\n%s\n' "$PWD" "$SCHEME"; cat "$PROJECT/project.pbxproj"; } |
    shasum -a 256 | cut -c1-32)
SETTINGS_CACHE="$CACHE/$KEY"

read_settings() {
    SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$DESTINATION" -configuration Debug -showBuildSettings 2>/dev/null |
        awk -F' = ' '
            !id  && /PRODUCT_BUNDLE_IDENTIFIER/ { id = $2 }
            !dir && /TARGET_BUILD_DIR/          { dir = $2 }
            !app && /WRAPPER_NAME/              { app = $2 }
            END { print id; print dir "/" app }')
    BUNDLE_ID=$(sed -n 1p <<<"$SETTINGS")
    APP_PATH=$(sed -n 2p <<<"$SETTINGS")
    if [ -z "$BUNDLE_ID" ] || [ "$APP_PATH" = "/" ]; then
        echo "Could not read build settings for scheme '$SCHEME'." >&2
        exit 1
    fi
    mkdir -p "$CACHE"
    printf '%s\n%s\n' "$BUNDLE_ID" "$APP_PATH" >"$SETTINGS_CACHE"
}

if [ -r "$SETTINGS_CACHE" ]; then
    BUNDLE_ID=$(sed -n 1p "$SETTINGS_CACHE")
    APP_PATH=$(sed -n 2p "$SETTINGS_CACHE")
else
    read_settings
fi

if [ "$BUILD" -eq 1 ]; then
    echo "Building $SCHEME…"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$DESTINATION" -configuration Debug -quiet build
fi

# A remembered path with nothing at it is a stale answer, not a failed build:
# ask again, and believe the new answer if it points somewhere else.
[ -d "$APP_PATH" ] || read_settings
if [ ! -d "$APP_PATH" ]; then
    if [ "$BUILD" -eq 0 ]; then
        echo "Nothing built yet at $APP_PATH — run once without --no-build." >&2
    else
        echo "The build left nothing at $APP_PATH." >&2
    fi
    exit 1
fi

if ! wait "$BOOT_PID"; then
    echo "$SIM_NAME never finished booting. Quit the Simulator and try again." >&2
    exit 1
fi

xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [ "$RESET" -eq 1 ]; then
    # Demo data lives in memory, so uninstalling clears everything it kept.
    xcrun simctl uninstall "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

xcrun simctl install "$SIM_ID" "$APP_PATH"
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" -scripty.demo YES >/dev/null

echo "Scripty demo running on $SIM_NAME — sample screenplay, no account needed."

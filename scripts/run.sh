#!/bin/bash
#
# Run Scripty without deciding how first. If an unlocked iPhone or iPad is
# plugged in and this Mac can sign, it goes there; otherwise it opens the
# offline demo in a simulator. Both paths are scripts/install.sh and
# scripts/demo.sh — this only picks between them.
#
#   ./scripts/run.sh                          # whatever is available
#   ./scripts/run.sh --simulator              # ignore any plugged-in device
#   ./scripts/run.sh --device                 # insist on the real device
#   ./scripts/run.sh --device "Clint iPhone"  # pick one by name
#   ./scripts/run.sh -- --reset               # pass the rest to the script it picks
#
set -euo pipefail
cd "$(dirname "$0")/.."

WANT=""          # "", "simulator", or "device"
DEVICE_NAME=""
EXTRA=()

usage() {
    sed -n '3,12p' "$0" | cut -c3-
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --simulator|--sim) WANT=simulator; shift ;;
        --device)
            WANT=device
            # The name is optional here, unlike install.sh: a bare --device
            # just means "the one that is plugged in".
            case "${2:-}" in
                ""|-*) shift ;;
                *) DEVICE_NAME="$2"; shift 2 ;;
            esac ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! xcrun -f xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode from the App Store, then point the" >&2
    echo "command-line tools at it:" >&2
    echo "  sudo xcode-select --switch /Applications/Xcode.app" >&2
    exit 1
fi

# The Command Line Tools package has xcodebuild but no simulators and no
# device support, so every path below would fail later with a stranger error.
DEVELOPER_DIR_PATH=$(xcode-select -p 2>/dev/null || true)
case "$DEVELOPER_DIR_PATH" in
    */CommandLineTools*)
        echo "xcode-select points at the Command Line Tools, which cannot build apps." >&2
        echo "Install Xcode, then:  sudo xcode-select --switch /Applications/Xcode.app" >&2
        exit 1 ;;
esac

run() {
    echo "→ $*"
    exec "$@"
}

if [ "$WANT" = simulator ]; then
    run ./scripts/demo.sh ${EXTRA[@]+"${EXTRA[@]}"}
fi

# Is a device actually usable right now? Being paired is not enough — a phone
# left at home is still paired — so ask for one that is connected too.
DEVICES_JSON=$(mktemp -t scripty-run-devices)
trap 'rm -f "$DEVICES_JSON"' EXIT
CONNECTED=""
if xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1; then
    CONNECTED=$(/usr/bin/python3 -c '
import json, sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
usable = [d["deviceProperties"]["name"] for d in devices
          if d["hardwareProperties"]["platform"] in ("iOS", "iPadOS")
          and d["connectionProperties"]["pairingState"] == "paired"
          and d["connectionProperties"]["tunnelState"] != "unavailable"]
print("\n".join(usable))
' "$DEVICES_JSON" 2>/dev/null || true)
fi

# Signing is the other half of "usable". install.sh explains a missing
# certificate well, so only look here to decide whether to fall back.
HAS_TEAM=0
if [ -n "${SCRIPTY_TEAM_ID:-}" ] ||
    security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Develop"; then
    HAS_TEAM=1
fi

if [ "$WANT" = device ]; then
    ARGS=()
    [ -n "$DEVICE_NAME" ] && ARGS=(--device "$DEVICE_NAME")
    run ./scripts/install.sh "${ARGS[@]+"${ARGS[@]}"}" ${EXTRA[@]+"${EXTRA[@]}"}
fi

if [ -z "$CONNECTED" ]; then
    echo "No iPhone or iPad connected — opening the offline demo in a simulator."
    echo "(Plug a device in over USB, unlock it, tap Trust, and rerun to use that instead.)"
    run ./scripts/demo.sh ${EXTRA[@]+"${EXTRA[@]}"}
fi

if [ "$HAS_TEAM" -eq 0 ]; then
    echo "$(head -1 <<<"$CONNECTED") is connected, but a real device only runs signed"
    echo "apps and there is no Apple development certificate in your keychain. Add your"
    echo "Apple ID under Xcode > Settings > Accounts — a free one is enough — and rerun."
    echo
    echo "Opening the offline demo in a simulator meanwhile."
    run ./scripts/demo.sh ${EXTRA[@]+"${EXTRA[@]}"}
fi

ARGS=()
if [ -n "$DEVICE_NAME" ]; then
    ARGS=(--device "$DEVICE_NAME")
elif [ "$(wc -l <<<"$CONNECTED")" -gt 1 ]; then
    # install.sh refuses to guess between several, and it is right to.
    echo "Several devices are connected:"
    sed 's/^/  /' <<<"$CONNECTED"
    echo "Pick one:  ./scripts/run.sh --device \"$(head -1 <<<"$CONNECTED")\"" >&2
    exit 1
fi

echo "$(head -1 <<<"$CONNECTED") is connected — installing there."
run ./scripts/install.sh "${ARGS[@]+"${ARGS[@]}"}" ${EXTRA[@]+"${EXTRA[@]}"}

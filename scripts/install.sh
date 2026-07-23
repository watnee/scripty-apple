#!/bin/bash
#
# Build Scripty and install it on a real iPhone or iPad plugged into this Mac.
# Unlike scripts/demo.sh (simulator, no signing), this needs a signing team —
# any free Apple ID team will do. It waits for the device, asks when it has to
# choose, and picks its own bundle id when the default is taken, so the usual
# answer is to run it with nothing after it.
#
#   ./scripts/install.sh                             # the connected device
#   ./scripts/install.sh --device "Clint iPhone"     # pick a device by name
#   ./scripts/install.sh --list                      # show paired devices
#   ./scripts/install.sh --team ABCDE12345           # signing team, else auto
#   ./scripts/install.sh --bundle-id com.you.scripty # if the default is taken
#   ./scripts/install.sh --demo                      # start in the offline demo
#   ./scripts/install.sh --no-launch                 # install without launching
#   ./scripts/install.sh --forget                    # drop the remembered answers
#
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="scripty.xcodeproj"
SCHEME="scripty"
DEVICE="${SCRIPTY_DEVICE:-}"
TEAM="${SCRIPTY_TEAM_ID:-}"
BUNDLE_OVERRIDE="${SCRIPTY_BUNDLE_ID:-}"
LAUNCH=1
DEMO=0

# The team and the bundle id are true for this Mac rather than for this run,
# and a free Apple ID expires the app after seven days, so the second run is
# never far away. Ask once, keep the answer here.
CONF=".scripty-install"

usage() {
    sed -n '3,17p' "$0" | cut -c3-
    exit "${1:-0}"
}

remembered() {
    [ -f "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | tail -1
    return 0
}

remember() {
    local rest
    rest=$(grep -v "^$1=" "$CONF" 2>/dev/null || true)
    printf '%s\n%s=%s\n' "$rest" "$1" "$2" | sed '/^$/d' >"$CONF"
}

# Waiting and asking only help someone who is standing there. A script or a CI
# job wants the error now.
interactive() { [ -t 0 ] && [ -t 1 ]; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE="${2:-}"; [ -n "$DEVICE" ] || usage 1; shift 2 ;;
        --team) TEAM="${2:-}"; [ -n "$TEAM" ] || usage 1; shift 2 ;;
        --bundle-id) BUNDLE_OVERRIDE="${2:-}"; [ -n "$BUNDLE_OVERRIDE" ] || usage 1; shift 2 ;;
        --demo) DEMO=1; shift ;;
        --no-launch) LAUNCH=0; shift ;;
        --forget) rm -f "$CONF"; echo "Forgot the remembered team and bundle id."; exit 0 ;;
        --list) exec xcrun devicectl list devices ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[ -n "$TEAM" ] || TEAM=$(remembered TEAM)
[ -n "$BUNDLE_OVERRIDE" ] || BUNDLE_OVERRIDE=$(remembered BUNDLE_ID)

if ! xcrun -f xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode, then point the tools at it:" >&2
    echo "  sudo xcode-select --switch /Applications/Xcode.app" >&2
    exit 1
fi

# Ask for a number rather than making someone rerun the whole command with a
# flag they now know the value of.
choose() {
    local prompt="$1" reply i=1
    shift
    echo "$prompt" >&2
    for option in "$@"; do
        echo "  $i) $option" >&2
        i=$((i + 1))
    done
    while :; do
        printf '  Which one? [1] ' >&2
        read -r reply || return 1
        [ -n "$reply" ] || reply=1
        case "$reply" in
            *[!0-9]*|'') ;;
            *) if [ "$reply" -ge 1 ] && [ "$reply" -le $# ]; then
                   eval "printf '%s\n' \"\${$reply}\""
                   return 0
               fi ;;
        esac
        echo "  Pick a number between 1 and $#." >&2
    done
}

# Pick a device. devicectl mixes a human table into --json-output when that is
# a pipe, so write the JSON to a real file and read it back.
DEVICES_JSON=$(mktemp -t scripty-devices)
trap 'rm -f "$DEVICES_JSON"' EXIT

# Prints a status word and then, tab-separated, whatever that status needs: the
# chosen device for "ok", the names to choose between for "many", one name for
# the rest. Deciding what to do about it is bash's job below, because most of
# these are things that stop being true while the script is running.
survey() {
    xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
    SCRIPTY_DEVICE="$DEVICE" /usr/bin/python3 -c '
import json, os, sys

try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
wanted = os.environ.get("SCRIPTY_DEVICE", "")

def name(device):
    return device["deviceProperties"]["name"]

def say(status, *rest):
    print("\t".join((status,) + rest))
    raise SystemExit

devices = [d for d in devices
           if d["hardwareProperties"]["platform"] in ("iOS", "iPadOS")
           and d["connectionProperties"]["pairingState"] == "paired"]
if wanted:
    named = [d for d in devices
             if wanted in (name(d), d["identifier"], d["hardwareProperties"]["udid"])]
    if not named:
        say("unnamed", wanted)
    devices = named
if not devices:
    say("none")

# A paired device that is not reachable right now would fail deep inside
# xcodebuild with an unhelpful message. A phone left at home is paired too.
live = [d for d in devices if d["connectionProperties"]["tunnelState"] != "unavailable"]
if not live:
    say("asleep", ", ".join(name(d) for d in devices))
if len(live) > 1 and not wanted:
    say("many", *(name(d) for d in live))

device = live[0]
if device["deviceProperties"].get("developerModeStatus") == "disabled":
    say("devmode", name(device))
# The marketing name ("iPhone 15 Pro Max", "iPad Pro 13-inch") confirms which
# thing this is landing on when the device name is something generic.
say("ok", device["identifier"], device["hardwareProperties"]["udid"], name(device),
    device["hardwareProperties"].get("marketingName", ""))
' "$DEVICES_JSON"
}

# Plugging a phone in, unlocking it and turning Developer Mode on all happen
# while the script is running, so say what is missing once and keep looking.
SAID=""
if interactive; then THEN=" — waiting…"; else THEN=", then rerun."; fi
nudge() {
    local key="$1"
    shift
    [ "$SAID" = "$key" ] && return 0
    SAID="$key"
    printf '%s\n' "$@" >&2
}

DEADLINE=$((SECONDS + 180))
while :; do
    IFS=$'\t' read -r -a FOUND <<<"$(survey)"
    case "${FOUND[0]}" in
        ok)
            DEVICE_ID="${FOUND[1]}"; DEVICE_UDID="${FOUND[2]}"; DEVICE_NAME="${FOUND[3]}"
            DEVICE_MODEL="${FOUND[4]:-}"
            break ;;
        many)
            if interactive; then
                DEVICE=$(choose "Several devices are connected:" "${FOUND[@]:1}") || exit 1
                SAID=""
                continue
            fi
            echo "Several devices are connected ($(printf '%s\n' "${FOUND[@]:1}" |
                paste -sd, - | sed 's/,/, /g'))." >&2
            echo "Choose one with: --device NAME" >&2
            exit 1 ;;
        none)
            nudge none "No iPhone or iPad is paired with this Mac. Plug one in over USB," \
                "unlock it, and tap Trust$THEN" ;;
        asleep)
            # Paired already, so the cable is optional: a device set up for
            # "Connect via network" in Xcode comes back over Wi-Fi on its own.
            nudge asleep "${FOUND[1]} is paired but not reachable right now." \
                "Connect it — a cable, or Wi-Fi if it's set up for that — and unlock it$THEN" ;;
        devmode)
            nudge devmode "Developer Mode is off on ${FOUND[1]}. Turn it on in Settings >" \
                "Privacy & Security > Developer Mode and restart the device$THEN" ;;
        unnamed)
            echo "No paired device named '${FOUND[1]}'." >&2
            echo "List them with: ./scripts/install.sh --list" >&2
            exit 1 ;;
    esac
    if ! interactive; then
        exit 1
    fi
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        echo "Nothing turned up in three minutes. Rerun when the device is ready." >&2
        exit 1
    fi
    sleep 3
done
if [ -n "$DEVICE_MODEL" ] && [ "$DEVICE_MODEL" != "$DEVICE_NAME" ]; then
    echo "Device: $DEVICE_NAME ($DEVICE_MODEL)"
else
    echo "Device: $DEVICE_NAME"
fi

# Signing on a device is not optional. One team in the keychain is the common
# case, so find it rather than making everyone look up their team id.
if [ -z "$TEAM" ]; then
    TEAM=$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/^ *[0-9]*) [0-9A-Fa-f]* "\(Apple Develop[^"]*\)"$/\1/p' |
        while IFS= read -r identity; do
            security find-certificate -c "$identity" -p 2>/dev/null |
                openssl x509 -noout -subject 2>/dev/null |
                tr ',' '\n' | sed -n 's/.*OU *= *\([A-Z0-9]\{6,\}\).*/\1/p' | head -1
        done | sort -u)
fi
set -- $TEAM
case "$#" in
    0) echo "No Apple development certificate in your keychain. Open Xcode > Settings" >&2
       echo "> Accounts, add your Apple ID, and let it create one — a free account is" >&2
       echo "enough. Then rerun, or pass the team id with --team." >&2
       exit 1 ;;
    1) TEAM="$1" ;;
    *) if interactive; then
           TEAM=$(choose "Several signing teams are in your keychain:" "$@") || exit 1
       else
           echo "Several signing teams found: $*" >&2
           echo "Pick one with: --team TEAMID" >&2
           exit 1
       fi ;;
esac
echo "Team: $TEAM"
if [ "$TEAM" != "$(remembered TEAM)" ]; then
    remember TEAM "$TEAM"
fi

DESTINATION="platform=iOS,id=$DEVICE_UDID"

# Ask the build system for the bundle id and the .app path rather than
# hardcoding them, so renaming the target can't silently break the shortcut.
# Both move when the bundle id does, so this is read again after that changes.
settle() {
    OVERRIDES=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$TEAM")
    [ -n "$BUNDLE_OVERRIDE" ] && OVERRIDES+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_OVERRIDE")
    local settings
    settings=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$DESTINATION" -configuration Debug "${OVERRIDES[@]}" \
        -showBuildSettings 2>/dev/null |
        awk -F' = ' '
            !id  && /PRODUCT_BUNDLE_IDENTIFIER/ { id = $2 }
            !dir && /TARGET_BUILD_DIR/          { dir = $2 }
            !app && /WRAPPER_NAME/              { app = $2 }
            END { print id; print dir "/" app }')
    BUNDLE_ID=$(sed -n 1p <<<"$settings")
    APP_PATH=$(sed -n 2p <<<"$settings")
    if [ -z "$BUNDLE_ID" ] || [ "$APP_PATH" = "/" ]; then
        echo "Could not read build settings for scheme '$SCHEME'." >&2
        exit 1
    fi
}
settle

BUILD_LOG=$(mktemp -t scripty-build)
trap 'rm -f "$DEVICES_JSON" "$BUILD_LOG"' EXIT

build() {
    echo "Building $SCHEME for $DEVICE_NAME…"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$DESTINATION" -configuration Debug "${OVERRIDES[@]}" \
        -quiet build 2>&1 | tee "$BUILD_LOG"
}

if ! build; then
    # The default bundle id is registered to this project's team, so everyone
    # else meets this on their first run. A team id is unique and already
    # theirs, which makes it the one name the script can pick without asking.
    if [ -z "$BUNDLE_OVERRIDE" ] &&
        grep -qEi 'bundle identifier|no profiles for|is not available' "$BUILD_LOG"; then
        BUNDLE_OVERRIDE="com.$(tr '[:upper:]' '[:lower:]' <<<"$TEAM").scripty"
        echo
        echo "'$BUNDLE_ID' belongs to another team, so this build takes an identifier"
        echo "of its own: $BUNDLE_OVERRIDE"
        settle
        build || exit 1
    else
        exit 1
    fi
fi
if [ -n "$BUNDLE_OVERRIDE" ] && [ "$BUNDLE_OVERRIDE" != "$(remembered BUNDLE_ID)" ]; then
    remember BUNDLE_ID "$BUNDLE_OVERRIDE"
fi

echo "Installing…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null

launch() {
    # `--` keeps devicectl from reading the leading-dash demo flag as its own.
    local args=()
    [ "$DEMO" -eq 1 ] && args=(-- -scripty.demo YES)
    xcrun devicectl device process launch --device "$DEVICE_ID" \
        --terminate-existing "$BUNDLE_ID" "${args[@]+"${args[@]}"}" >/dev/null 2>&1
}

if [ "$LAUNCH" -eq 1 ] && ! launch; then
    # A free Apple ID signs with a certificate the device does not trust until
    # someone taps it through — and that tapping happens now, so keep trying.
    echo >&2
    echo "Installed, but the app will not start until $DEVICE_NAME trusts the" >&2
    echo "certificate that signed it: Settings > General > VPN & Device Management" >&2
    echo "> tap your Apple ID > Trust." >&2
    STARTED=0
    if interactive; then
        echo "Waiting for that…" >&2
        for _ in $(seq 24); do
            sleep 5
            if launch; then STARTED=1; break; fi
        done
    fi
    if [ "$STARTED" -eq 0 ]; then
        echo "Then open Scripty from the Home Screen." >&2
        exit 1
    fi
fi

echo "Scripty is installed on $DEVICE_NAME."

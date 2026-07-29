#!/bin/bash
#
# Build Scripty and install it on the iPhones and iPads connected to this Mac.
# Unlike scripts/demo.sh (simulator, no signing), this needs a signing team —
# any free Apple ID team will do. It waits for a device, builds once and installs
# on everything it was pointed at, and picks its own bundle id when the default
# is taken, so the usual answer is to run it with nothing after it.
#
#   ./scripts/install.sh                             # the connected device, asking if several
#   ./scripts/install.sh --all                       # every connected device, no question
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
ALL=0
LAUNCH=1
DEMO=0

# The team and the bundle id are true for this Mac rather than for this run, and
# a signature expires — after seven days on a free Apple ID, a year on a paid
# one — so the second run is never far away. Ask once, keep the answer here.
CONF=".scripty-install"

usage() {
    sed -n '3,18p' "$0" | cut -c3-
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

# Default no, unlike the confirmations in get.sh: the only thing this asks is
# whether to delete a copy of the app someone has been using.
confirm() {
    local reply
    interactive || return 1
    printf '%s [y/N] ' "$1"
    read -r reply || return 1
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# "iPhone and iPad", "iPhone, iPad and iPod" — for the lines that name what just
# happened, which read badly as a bare comma-separated list.
join_names() {
    case "$#" in
        1) printf '%s' "$1" ;;
        2) printf '%s and %s' "$1" "$2" ;;
        *) printf '%s, ' "$1"; shift; join_names "$@" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --all) ALL=1; shift ;;
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

# A signature expires, and a device copy then quietly stops opening — the most
# confusing thing about this whole path, because nothing changed and the app just
# won't start. The last run wrote down the date its profile ran out, so if that
# day has passed, say so up front: "it broke on its own" reads as "rerunning
# renews it", which is the whole reason to run this again.
LAST_EXPIRY=$(remembered EXPIRES)
case "$LAST_EXPIRY" in
    ''|*[!0-9]*) ;;
    *)
        if interactive && [ "$(date +%s)" -ge "$LAST_EXPIRY" ]; then
            echo "The copy installed from here stopped being signed on"
            echo "$(date -j -r "$LAST_EXPIRY" '+%-d %B %Y') — so if Scripty had stopped opening, this renews it."
            echo
        fi ;;
esac

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

# Pick the devices. devicectl mixes a human table into --json-output when that is
# a pipe, so write the JSON to a real file and read it back.
DEVICES_JSON=$(mktemp -t scripty-devices)
BUILD_LOG=$(mktemp -t scripty-build)
PROFILE_PLIST=$(mktemp -t scripty-profile)
trap 'rm -f "$DEVICES_JSON" "$BUILD_LOG" "$PROFILE_PLIST"' EXIT

# Prints a status word and then, tab-separated, whatever that status needs: the
# names to choose between for "many", one name for the rest. "ok" is the status
# word alone, followed by a line per chosen device. Deciding what to do about it
# is bash's job below, because most of these are things that stop being true
# while the script is running.
survey() {
    xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
    SCRIPTY_DEVICE="$DEVICE" SCRIPTY_ALL="$ALL" /usr/bin/python3 -c '
import json, os, sys

try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
wanted = os.environ.get("SCRIPTY_DEVICE", "")
every = os.environ.get("SCRIPTY_ALL") == "1"

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
if len(live) > 1 and not wanted and not every:
    say("many", *(name(d) for d in live))

# Developer Mode is per device, and the install stops at the first one that has
# it off — pointless to build for two when one of them cannot receive it.
off = [d for d in live if d["deviceProperties"].get("developerModeStatus") == "disabled"]
if off:
    say("devmode", name(off[0]))

print("ok")
for device in live:
    # The marketing name ("iPhone 15 Pro Max", "iPad Pro 13-inch") confirms which
    # thing this is landing on when the device name is something generic.
    print(device["identifier"], device["hardwareProperties"]["udid"], name(device),
          device["hardwareProperties"].get("marketingName", ""), sep="\t")
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

DEVICES=()
DEADLINE=$((SECONDS + 180))
while :; do
    SURVEYED=$(survey)
    IFS=$'\t' read -r -a FOUND <<<"$(sed -n 1p <<<"$SURVEYED")"
    case "${FOUND[0]}" in
        ok)
            while IFS= read -r record; do
                [ -n "$record" ] && DEVICES+=("$record")
            done < <(sed 1d <<<"$SURVEYED")
            break ;;
        many)
            # Two devices on the desk is the ordinary case for anyone with a
            # phone and a tablet, and doing both is what they came for, so that
            # is the answer Return gives.
            if interactive; then
                EVERY="All $(( ${#FOUND[@]} - 1 )) of them"
                CHOSEN=$(choose "Several devices are connected:" "$EVERY" "${FOUND[@]:1}") || exit 1
                if [ "$CHOSEN" = "$EVERY" ]; then ALL=1; else DEVICE="$CHOSEN"; fi
                SAID=""
                continue
            fi
            echo "Several devices are connected ($(printf '%s\n' "${FOUND[@]:1}" |
                paste -sd, - | sed 's/,/, /g'))." >&2
            echo "Install on all of them with: --all" >&2
            echo "Or pick one with: --device NAME" >&2
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

# Fields of a device record, by position, for the reads below.
record_of() { IFS=$'\t' read -r DEVICE_ID DEVICE_UDID DEVICE_NAME DEVICE_MODEL <<<"$1"; }

described() {
    if [ -n "$DEVICE_MODEL" ] && [ "$DEVICE_MODEL" != "$DEVICE_NAME" ]; then
        printf '%s (%s)' "$DEVICE_NAME" "$DEVICE_MODEL"
    else
        printf '%s' "$DEVICE_NAME"
    fi
}

if [ "${#DEVICES[@]}" -gt 1 ]; then
    echo "Devices:"
    for RECORD in "${DEVICES[@]}"; do
        record_of "$RECORD"
        echo "  $(described)"
    done
else
    record_of "${DEVICES[0]}"
    echo "Device: $(described)"
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

# Every build out of this project calls itself version 1.0 (1), so installing
# over the top hands iOS a copy it cannot tell from the one already there. The
# app survives that — its binary is replaced and relaunched — but the widget
# extensions do not: their plug-ins are registered once, keyed by that version,
# and a reinstall that looks unchanged never re-registers them. A widget added
# since the last install is then simply absent from the widget gallery, with
# nothing wrong in the build to find. Stamp each run with the time instead, to
# the second because two installs a minute apart is what debugging a widget
# looks like. It reaches all four targets: a build setting given on the command
# line applies project-wide, and CFBundleVersion is generated from this one.
BUILD_NUMBER=$(date -u +%Y%m%d%H%M%S)

# Ask the build system for the bundle id and the .app path rather than
# hardcoding them, so renaming the target can't silently break the shortcut.
# Both move when the bundle id does, so this is read again after that changes.
# This needs the destination as much as the build does, so it fails for the same
# reasons — it reports rather than exits, and every caller handles it like a
# build that didn't work out.
settle() {
    # The device-registration flag covers a phone this Apple ID has never seen:
    # without it the build stops at "isn't registered in your developer account"
    # even though -allowProvisioningUpdates sounds like it should cover that.
    OVERRIDES=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
        "DEVELOPMENT_TEAM=$TEAM" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
    [ -n "$BUNDLE_OVERRIDE" ] && OVERRIDES+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_OVERRIDE")
    local settings status=0
    # Keep the stderr instead of dropping it, in the same file the build writes:
    # a device Xcode can't reach and a scheme that is genuinely broken both end
    # up here with nothing on stdout, and the reason xcodebuild gives is the only
    # thing that tells them apart.
    settings=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$DESTINATION" -configuration Debug "${OVERRIDES[@]}" \
        -showBuildSettings 2>"$BUILD_LOG" |
        awk -F' = ' '
            # Whole-name matches only: DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER
            # sorts before PRODUCT_BUNDLE_IDENTIFIER and its value is "NO".
            !id  && $1 ~ /^ *PRODUCT_BUNDLE_IDENTIFIER$/ { id = $2 }
            !dir && $1 ~ /^ *TARGET_BUILD_DIR$/          { dir = $2 }
            !app && $1 ~ /^ *WRAPPER_NAME$/              { app = $2 }
            END { print id; print dir "/" app }') || status=$?
    BUNDLE_ID=$(sed -n 1p <<<"$settings")
    APP_PATH=$(sed -n 2p <<<"$settings")
    [ "$status" -eq 0 ] && [ -n "$BUNDLE_ID" ] && [ "$APP_PATH" != "/" ]
}

# What settle ran into, when it wasn't the locked screen locked_out recognises.
# Without xcodebuild's own words there is nothing here to act on: the exit code
# alone is the silence this used to fail with.
say_unreadable() {
    echo "Could not read build settings for scheme '$SCHEME' with $BUILD_FOR as the" >&2
    echo "destination. xcodebuild said:" >&2
    sed -n '1,20p' "$BUILD_LOG" >&2
}

build() {
    echo "Building $SCHEME for $BUILD_FOR…"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$DESTINATION" -configuration Debug "${OVERRIDES[@]}" \
        -quiet build 2>&1 | tee "$BUILD_LOG"
}

# One build serves every device the profile Xcode just issued covers, which is
# every device already registered to the team — so the second device usually
# costs nothing. One it has never seen is the exception: that device has to be
# the destination once for it to be registered and written into the profile.
covers() {
    local udid="$1" profile="$APP_PATH/embedded.mobileprovision"
    [ -f "$profile" ] || return 0
    security cms -D -i "$profile" >"$PROFILE_PLIST" 2>/dev/null || return 0
    grep -q "<string>$udid</string>" "$PROFILE_PLIST"
}

# How long this copy will keep opening. A free Apple ID's profile lasts seven
# days and a paid one's a year, and rather than guess which this is — the wrong
# guess is what makes the app's silent death a mystery — read the date out of
# the profile that just got built.
expires_at() {
    local profile="$APP_PATH/embedded.mobileprovision" raw
    [ -f "$profile" ] || return 1
    security cms -D -i "$profile" >"$PROFILE_PLIST" 2>/dev/null || return 1
    raw=$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null) || return 1
    [ -n "$raw" ] || return 1
    date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$raw" +%s 2>/dev/null
}

# A locked device can still be installed on, but xcodebuild will not build
# against one, or even describe the build: it waits for a destination that never
# becomes ready and then reports a timeout, with the reason a line further down.
# A device that hasn't been unlocked since it was plugged in words that reason as
# a disk image it could not mount, which is the same screen and the same answer.
locked_out() {
    grep -qE 'may need to be unlocked|Timed out waiting for all destinations|developer disk image could not be mounted' "$BUILD_LOG"
}

# The build needs one device to aim at, and every device the profile covers can
# receive what comes out — so a locked screen is a reason to aim somewhere else
# rather than a reason to stop. Reading the settings hits that screen before the
# build does, so both take this route and only the last device gives up.
BUILT=0
LAST=$(( ${#DEVICES[@]} - 1 ))
for INDEX in $(seq 0 "$LAST"); do
    record_of "${DEVICES[$INDEX]}"
    BUILD_FOR="$DEVICE_NAME"
    DESTINATION="platform=iOS,id=$DEVICE_UDID"
    SETTLED=1
    if settle; then
        if build; then BUILT=1; break; fi

        # The default bundle id is registered to this project's team, so everyone
        # else meets this on their first run. A team id is unique and already
        # theirs, which makes it the one name the script can pick without asking.
        if [ -z "$BUNDLE_OVERRIDE" ] &&
            grep -qEi 'bundle identifier|no profiles for|is not available' "$BUILD_LOG"; then
            BUNDLE_OVERRIDE="com.$(tr '[:upper:]' '[:lower:]' <<<"$TEAM").scripty"
            echo
            echo "'$BUNDLE_ID' belongs to another team, so this build takes an identifier"
            echo "of its own: $BUNDLE_OVERRIDE"
            if settle && build; then BUILT=1; break; fi
        fi
    else
        SETTLED=0
        if ! locked_out; then
            echo >&2
            say_unreadable
        fi
    fi

    if locked_out; then
        echo
        if [ "$INDEX" -lt "$LAST" ]; then
            record_of "${DEVICES[$(( INDEX + 1 ))]}"
            echo "$BUILD_FOR is locked, so Xcode can't build against it — building against"
            echo "$DEVICE_NAME instead. The copy it makes installs on both."
            continue
        fi
        echo "$BUILD_FOR is locked. Installing works either way, but Xcode has to reach" >&2
        echo "the device to build at all$THEN" >&2
        # Waiting is the whole of the workaround: `xcrun devicectl device install
        # app` against a locked device fails the same way it does here
        # (kAMDMobileImageMounterDeviceLocked), so there is nothing to route
        # round — same shape as keep_trying below, on the build not the launch.
        if interactive; then
            for _ in $(seq 12); do
                sleep 5
                if settle && build; then BUILT=1; break 2; fi
            done
        fi
    elif [ "$SETTLED" -eq 0 ] && [ "$INDEX" -lt "$LAST" ]; then
        # Whatever xcodebuild couldn't do, it couldn't do with this device as the
        # destination — worth asking the next one before calling the run over.
        record_of "${DEVICES[$(( INDEX + 1 ))]}"
        echo "Building against $DEVICE_NAME instead." >&2
        continue
    fi
    exit 1
done
[ "$BUILT" -eq 1 ] || exit 1
if [ -n "$BUNDLE_OVERRIDE" ] && [ "$BUNDLE_OVERRIDE" != "$(remembered BUNDLE_ID)" ]; then
    remember BUNDLE_ID "$BUNDLE_OVERRIDE"
fi

# devicectl says "the app is already installed by another team" in entitlement
# language, and no flag talks it round: the old copy has to go first. That takes
# the app's local data and sign-in with it, so it is a question, never a step.
install_app() {
    local out
    echo "Installing on $DEVICE_NAME…"
    if out=$(xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1); then
        return 0
    fi
    if grep -q "MismatchedApplicationIdentifierEntitlement" <<<"$out"; then
        echo >&2
        echo "$DEVICE_NAME already has a Scripty signed by a different team, and iOS will" >&2
        echo "not upgrade across teams. The old copy has to be removed first — and its" >&2
        echo "notes, drafts and sign-in go with it." >&2
        if confirm "Remove the old Scripty from $DEVICE_NAME and install this one?"; then
            ./scripts/uninstall.sh --device "$DEVICE_NAME" --bundle-id "$BUNDLE_ID" || true
            if xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
                >/dev/null 2>&1; then
                return 0
            fi
        else
            echo "Left it alone. When you want to go ahead:" >&2
            echo "  ./scripts/uninstall.sh --device \"$DEVICE_NAME\" && ./scripts/install.sh" >&2
        fi
    else
        printf '%s\n' "$out" >&2
    fi
    return 1
}

# The launch is where a good install still looks like a failure, and the two
# common reasons want opposite things from you: an untrusted certificate needs
# tapping through in Settings, a locked device needs nothing but your thumb.
# They arrive as the same non-zero exit, so read the message.
LAUNCH_ERROR=""
launch_app() {
    local args=()
    # `--` keeps devicectl from reading the leading-dash demo flag as its own.
    [ "$DEMO" -eq 1 ] && args=(-- -scripty.demo YES)
    LAUNCH_ERROR=$(xcrun devicectl device process launch --device "$DEVICE_ID" \
        --terminate-existing "$BUNDLE_ID" "${args[@]+"${args[@]}"}" 2>&1)
}

keep_trying() {
    local _
    interactive || return 1
    for _ in $(seq 24); do
        sleep 5
        if launch_app; then return 0; fi
    done
    return 1
}

start_app() {
    launch_app && return 0
    case "$LAUNCH_ERROR" in
        *nlock*)
            # Installed fine; iOS just will not open anything on a locked screen.
            echo >&2
            echo "Installed. $DEVICE_NAME is locked, so it can't open Scripty yet —" >&2
            echo "unlock it and it starts." >&2
            keep_trying && return 0
            echo "Or open Scripty from the Home Screen." >&2
            return 1 ;;
        *"explicitly trusted"*|*"invalid code signature"*|*"inadequate entitlements"*)
            # A free Apple ID signs with a certificate the device does not trust
            # until someone taps it through — and that tapping happens now.
            echo >&2
            echo "Installed, but the app will not start until $DEVICE_NAME trusts the" >&2
            echo "certificate that signed it: Settings > General > VPN & Device Management" >&2
            echo "> tap your Apple ID > Trust." >&2
            interactive && echo "Waiting for that…" >&2
            keep_trying && return 0
            echo "Then open Scripty from the Home Screen." >&2
            return 1 ;;
        *)
            echo >&2
            echo "Installed on $DEVICE_NAME, but it would not start:" >&2
            printf '%s\n' "$LAUNCH_ERROR" >&2
            return 1 ;;
    esac
}

INSTALLED_ON=()
FAILED=0
for RECORD in "${DEVICES[@]}"; do
    record_of "$RECORD"
    if ! covers "$DEVICE_UDID"; then
        echo "$DEVICE_NAME is new to team $TEAM, so it needs a build of its own to be"
        echo "registered…"
        BUILD_FOR="$DEVICE_NAME"
        DESTINATION="platform=iOS,id=$DEVICE_UDID"
        if ! settle; then
            if locked_out; then
                echo "$DEVICE_NAME is locked, so Xcode can't build against it. Unlock it and" >&2
                echo "rerun to get it registered." >&2
            else
                say_unreadable
            fi
            FAILED=1; continue
        fi
        build || { FAILED=1; continue; }
    fi
    install_app || { FAILED=1; continue; }
    INSTALLED_ON+=("$DEVICE_NAME")
    # Installing is what this script promises; opening the app is the courtesy
    # at the end of it. A device that is merely locked has nothing wrong with
    # it, so a launch that didn't happen explains itself above and leaves the
    # run a success — otherwise the double-click window would contradict the
    # line right before it.
    if [ "$LAUNCH" -eq 1 ]; then
        start_app || true
    fi
done

if [ "${#INSTALLED_ON[@]}" -eq 0 ]; then
    exit 1
fi

# The signature lands with the app, whether or not the launches above succeeded,
# so write down when it runs out. The next run reads this to know a copy has
# expired, which is the only visible symptom: an app that stops opening.
EXPIRES=$(expires_at || true)
remember INSTALLED "$(date +%s)"
[ -n "$EXPIRES" ] && remember EXPIRES "$EXPIRES"

echo
echo "Scripty is installed on $(join_names "${INSTALLED_ON[@]}")."
if [ -n "$EXPIRES" ]; then
    LASTS=$(( (EXPIRES - $(date +%s)) / 86400 ))
    echo "It stays signed until $(date -j -r "$EXPIRES" '+%-d %B %Y') — $LASTS days — and rerunning this renews it."
else
    echo "Rerun this to renew the signature when the app stops opening."
fi
exit "$FAILED"

#!/bin/bash
#
# Get Scripty running on a Mac that has nothing yet. Checks Xcode, clones the
# repository if this isn't already one, and hands over to scripts/run.sh, which
# picks between a plugged-in device and the offline demo.
#
#   curl -fsSL https://raw.githubusercontent.com/watnee/scripty-apple/main/scripts/get.sh | bash
#   ./scripts/get.sh                     # from inside a clone: check, then run
#   ./scripts/get.sh --dir ~/code/scripty  # clone somewhere other than ~/scripty-apple
#   ./scripts/get.sh --no-run            # set everything up, don't launch
#   ./scripts/get.sh -- --simulator      # pass the rest to run.sh
#
set -euo pipefail

REPO="https://github.com/watnee/scripty-apple.git"
DIR="${SCRIPTY_DIR:-$HOME/scripty-apple}"
RUN=1
EXTRA=()

usage() {
    # Piped from curl there is no file to read the header out of, and the one
    # flag that matters through a pipe is in the header's first line anyway.
    if [ -f "$0" ]; then
        sed -n '3,11p' "$0" | cut -c3-
    else
        echo "Usage: curl -fsSL .../scripts/get.sh | bash -s -- [--dir PATH] [--no-run]"
    fi
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="${2:-}"; [ -n "$DIR" ] || usage 1; shift 2 ;;
        --no-run) RUN=0; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# Piped from curl, stdin is the script itself, so questions have to go to the
# terminal directly. No terminal at all means nobody is there to answer.
interactive() { [ -t 1 ] && [ -r /dev/tty ]; }

# Default yes: everything this asks is something the person running it already
# said yes to by running it.
confirm() {
    local reply
    interactive || return 1
    printf '%s [Y/n] ' "$1"
    read -r reply </dev/tty || return 1
    case "$reply" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Scripty is an iOS app, so building it needs a Mac with Xcode." >&2
    exit 1
fi

# Xcode is the one prerequisite this script cannot install: it is a 15 GB App
# Store download that wants an Apple ID. Everything after it, it can handle.
XCODE_APP="/Applications/Xcode.app"
DEVELOPER_DIR_PATH=$(xcode-select -p 2>/dev/null || true)
case "$DEVELOPER_DIR_PATH" in
    ""|*/CommandLineTools*)
        # The Command Line Tools package has xcodebuild but no simulators and no
        # device support, which is the confusing half of this: the tools look
        # installed and then every build fails.
        if [ ! -d "$XCODE_APP" ]; then
            echo "Xcode isn't installed. It's a free App Store download (about 15 GB);"
            echo "Scripty needs it to build an app at all."
            if confirm "Open the App Store at Xcode?"; then
                open "macappstore://apps.apple.com/app/id497799835" || true
            fi
            echo "Install it, then rerun this."
            exit 1
        fi
        echo "Xcode is installed but the command-line tools point somewhere else,"
        echo "so builds would fail. Pointing them at Xcode needs your password."
        if confirm "Run: sudo xcode-select --switch $XCODE_APP/Contents/Developer ?"; then
            sudo xcode-select --switch "$XCODE_APP/Contents/Developer"
        else
            echo "Run this yourself and rerun:" >&2
            echo "  sudo xcode-select --switch $XCODE_APP/Contents/Developer" >&2
            exit 1
        fi ;;
esac

# A freshly installed Xcode has not agreed to its licence or laid down its
# platform support, and says so from inside an otherwise ordinary build.
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    echo "Xcode still needs its first-launch setup — the licence and its platform"
    echo "components. That needs your password."
    if confirm "Run: sudo xcodebuild -runFirstLaunch ?"; then
        sudo xcodebuild -license accept
        sudo xcodebuild -runFirstLaunch
    else
        echo "Run those yourself and rerun this:" >&2
        echo "  sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch" >&2
        exit 1
    fi
fi

# Already inside a clone? Then there is nothing to fetch. When this arrives
# through a pipe there is no file to look next to, and BASH_SOURCE is empty.
HERE=""
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
    CANDIDATE=$(cd "$(dirname "$SELF")/.." && pwd)
    if [ -f "$CANDIDATE/scripty.xcodeproj/project.pbxproj" ]; then
        HERE="$CANDIDATE"
        DIR="$HERE"
    fi
fi

if [ -f "$DIR/scripty.xcodeproj/project.pbxproj" ]; then
    if [ "$HERE" != "$DIR" ]; then
        echo "Scripty is already at $DIR — updating it."
        # A clone someone has been editing is theirs; say so rather than
        # standing on their work.
        git -C "$DIR" pull --ff-only ||
            echo "Couldn't fast-forward $DIR, so using it as it is."
    fi
elif [ -e "$DIR" ]; then
    echo "$DIR already exists and isn't a Scripty checkout." >&2
    echo "Clone somewhere else with: --dir PATH" >&2
    exit 1
else
    echo "Cloning Scripty into $DIR…"
    git clone "$REPO" "$DIR"
fi

cd "$DIR"

if [ "$RUN" -eq 0 ]; then
    echo "Ready. Start it with:  cd \"$DIR\" && ./scripts/run.sh"
    exit 0
fi

exec ./scripts/run.sh ${EXTRA[@]+"${EXTRA[@]}"}

#!/bin/bash
#
# Build a Scripty someone else can install, without plugging their device into
# this Mac. Unlike scripts/install.sh (one tethered device) this makes a signed
# .ipa, and by default sends it to TestFlight.
#
#   ./scripts/share.sh                               # build and upload to TestFlight
#   ./scripts/share.sh --no-upload                   # build the .ipa, don't send it
#   ./scripts/share.sh --ad-hoc                      # .ipa for devices already registered
#   ./scripts/share.sh --key ~/AuthKey_A1B2C3D4E5.p8 # App Store Connect key, else found
#   ./scripts/share.sh --issuer UUID                 # its issuer id
#   ./scripts/share.sh --team ABCDE12345             # signing team, else auto
#   ./scripts/share.sh --bundle-id com.you.scripty   # if the default is taken
#   ./scripts/share.sh --build 42                    # build number, else a timestamp
#   ./scripts/share.sh --out DIR                     # where the .ipa lands
#
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="scripty.xcodeproj"
SCHEME="scripty"
TEAM="${SCRIPTY_TEAM_ID:-}"
BUNDLE_OVERRIDE="${SCRIPTY_BUNDLE_ID:-}"
KEY="${SCRIPTY_ASC_KEY:-}"
ISSUER="${SCRIPTY_ASC_ISSUER:-}"
OUT="build/share"
BUILD_NUMBER=""
UPLOAD=1
ADHOC=0

usage() {
    sed -n '3,15p' "$0" | cut -c3-
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="${2:-}"; [ -n "$TEAM" ] || usage 1; shift 2 ;;
        --bundle-id) BUNDLE_OVERRIDE="${2:-}"; [ -n "$BUNDLE_OVERRIDE" ] || usage 1; shift 2 ;;
        --key) KEY="${2:-}"; [ -n "$KEY" ] || usage 1; shift 2 ;;
        --issuer) ISSUER="${2:-}"; [ -n "$ISSUER" ] || usage 1; shift 2 ;;
        --build) BUILD_NUMBER="${2:-}"; [ -n "$BUILD_NUMBER" ] || usage 1; shift 2 ;;
        --out) OUT="${2:-}"; [ -n "$OUT" ] || usage 1; shift 2 ;;
        --ad-hoc) ADHOC=1; UPLOAD=0; shift ;;
        --no-upload) UPLOAD=0; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! xcrun -f xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode, then point the tools at it:" >&2
    echo "  sudo xcode-select --switch /Applications/Xcode.app" >&2
    exit 1
fi

# Both TestFlight and ad-hoc need a distribution certificate, which only the
# paid Developer Program issues — the free Apple ID that install.sh gets by with
# cannot sign a build for anyone else's device.
if [ -z "$TEAM" ]; then
    TEAM=$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/^ *[0-9]*) [0-9A-Fa-f]* "\(Apple Distribution[^"]*\)"$/\1/p' |
        while IFS= read -r identity; do
            security find-certificate -c "$identity" -p 2>/dev/null |
                openssl x509 -noout -subject 2>/dev/null |
                tr ',' '\n' | sed -n 's/.*OU *= *\([A-Z0-9]\{6,\}\).*/\1/p' | head -1
        done | sort -u)
fi
set -- $TEAM
case "$#" in
    0) echo "No Apple Distribution certificate in your keychain. Sharing a build needs" >&2
       echo "the paid Apple Developer Program (\$99/year); a free Apple ID can only" >&2
       echo "install onto devices plugged into this Mac — see ./scripts/install.sh." >&2
       echo "With a membership: Xcode > Settings > Accounts > Manage Certificates > +" >&2
       echo "> Apple Distribution. Then rerun, or pass the team id with --team." >&2
       exit 1 ;;
    1) ;;
    *) echo "Several distribution teams found: $(tr '\n' ' ' <<<"$TEAM")" >&2
       echo "Pick one with: --team TEAMID" >&2
       exit 1 ;;
esac
echo "Team: $TEAM"

# App Store Connect keys are p8 files Apple names AuthKey_<KEYID>.p8, and the
# tools look for them in these directories, so accept one from any of them
# rather than making everyone pass --key every time.
if [ "$UPLOAD" -eq 1 ] && [ -z "$KEY" ]; then
    KEY=$(ls -1 ./private_keys/AuthKey_*.p8 "$HOME"/private_keys/AuthKey_*.p8 \
        "$HOME"/.private_keys/AuthKey_*.p8 \
        "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -2 || true)
    if [ "$(wc -l <<<"$KEY")" -gt 1 ]; then
        echo "Several App Store Connect keys found. Pick one with: --key PATH" >&2
        exit 1
    fi
fi

if [ "$UPLOAD" -eq 1 ]; then
    if [ -z "$KEY" ] || [ -z "$ISSUER" ]; then
        echo "Uploading to TestFlight needs an App Store Connect API key. In App Store" >&2
        echo "Connect > Users and Access > Integrations > App Store Connect API, create" >&2
        echo "a key with the App Manager role, download the .p8 (once only), and copy the" >&2
        echo "issuer id shown on that page. Then:" >&2
        echo "  ./scripts/share.sh --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --issuer ISSUER-UUID" >&2
        echo "Or build the .ipa without sending it: ./scripts/share.sh --no-upload" >&2
        exit 1
    fi
    [ -f "$KEY" ] || { echo "No such key file: $KEY" >&2; exit 1; }
    KEY=$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")
    KEY_ID=$(sed -n 's/^AuthKey_\(.*\)\.p8$/\1/p' <<<"$(basename "$KEY")")
    if [ -z "$KEY_ID" ]; then
        echo "Expected the key to be named AuthKey_<KEYID>.p8, the way Apple ships it," >&2
        echo "since that filename is where the key id comes from. Got: $(basename "$KEY")" >&2
        exit 1
    fi
    AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID"
          -authenticationKeyIssuerID "$ISSUER")
else
    AUTH=()
fi

# TestFlight rejects a build number it has already seen, and nobody wants to
# remember which one they used last, so default to something always increasing.
[ -n "$BUILD_NUMBER" ] || BUILD_NUMBER=$(date -u +%Y%m%d%H%M)

if [ "$ADHOC" -eq 1 ]; then
    METHOD="release-testing"
else
    METHOD="app-store-connect"
fi

WORK=$(mktemp -d -t scripty-share)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
ARCHIVE="$OUT/$SCHEME.xcarchive"

OVERRIDES=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$TEAM"
           "CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
[ -n "$BUNDLE_OVERRIDE" ] && OVERRIDES+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_OVERRIDE")

echo "Archiving $SCHEME (build $BUILD_NUMBER)…"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    "${OVERRIDES[@]}" "${AUTH[@]+"${AUTH[@]}"}" -quiet archive; then
    echo >&2
    echo "Archive failed. If the error mentions the bundle identifier, it is already" >&2
    echo "registered to another team — pick your own, for example:" >&2
    echo "  ./scripts/share.sh --bundle-id com.yourname.scripty" >&2
    exit 1
fi

# manageAppVersionAndBuildNumber off: the build number above is the one we want
# uploaded, not whatever App Store Connect would substitute for it.
cat >"$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$METHOD</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "Exporting…"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates \
    "${AUTH[@]+"${AUTH[@]}"}" -quiet; then
    echo >&2
    if [ "$ADHOC" -eq 1 ]; then
        echo "Export failed. An ad-hoc build only covers devices already registered to" >&2
        echo "team $TEAM — add their UDIDs at developer.apple.com > Devices, then rerun." >&2
    else
        echo "Export failed. Check that an app record for this bundle id exists in App" >&2
        echo "Store Connect; TestFlight builds need one before they can be exported." >&2
    fi
    exit 1
fi

IPA=$(ls -1t "$OUT"/*.ipa 2>/dev/null | head -1 || true)
[ -n "$IPA" ] || { echo "Export produced no .ipa in $OUT." >&2; exit 1; }

if [ "$UPLOAD" -eq 1 ]; then
    echo "Uploading to App Store Connect…"
    # altool finds the key by id, only in its own search paths, so hand it a
    # directory it looks in rather than moving the user's file around.
    mkdir -p "$WORK/private_keys"
    cp "$KEY" "$WORK/private_keys/"
    if ! (cd "$WORK" && xcrun altool --upload-app -f "$IPA" -t ios \
            --apiKey "$KEY_ID" --apiIssuer "$ISSUER"); then
        echo >&2
        echo "Upload failed, but $IPA is built — rerun to try again," >&2
        echo "or upload that file with Transporter from the Mac App Store." >&2
        exit 1
    fi
    echo
    echo "Uploaded build $BUILD_NUMBER. App Store Connect takes a few minutes to process"
    echo "it; then add people under TestFlight and they get an email invite. They install"
    echo "Apple's TestFlight app — no Mac, no Xcode, no cable."
elif [ "$ADHOC" -eq 1 ]; then
    echo
    echo "Built $IPA"
    echo "It installs on the devices registered to team $TEAM — send them the file and"
    echo "have them drag it onto their device in the Finder, or use Apple Configurator."
else
    echo
    echo "Built $IPA"
    echo "Upload it later with: ./scripts/share.sh (or Transporter from the Mac App Store)."
fi

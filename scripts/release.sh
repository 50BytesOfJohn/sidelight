#!/bin/bash
# Builds a signed, notarized Sidelight DMG and the Sparkle appcast that announces it.
#
# Usage: scripts/release.sh VERSION [release-notes.md]
#
# Writes build/release/Sidelight-VERSION.dmg, its .sha256 and appcast.xml. Attach all three to the GitHub release
# tagged vVERSION. The app reads its feed from releases/latest/download/appcast.xml, so publishing the release is what
# ships the update. The release notes (Markdown) are shown in the app's update window.
#
# Needs:
# - A "Developer ID Application" signing identity in the keychain.
# - Notarization credentials: an App Store Connect API key in NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER, or else
#   a notarytool keychain profile named $NOTARY_PROFILE (default: sidelight).
# - The Sparkle EdDSA private key that matches SUPublicEDKey in Info.plist: SPARKLE_PRIVATE_KEY, or else the
#   "sidelight" account in the login keychain.
# docs/RELEASING.md explains how to set these up.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh VERSION [release-notes.md]}
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: version must be a numeric version such as 0.1.0" >&2
    exit 1
fi
NOTES=${2:-}
REPO_URL=https://github.com/50BytesOfJohn/sidelight
OUT=build/release
APP=build/Sidelight.app
DMG="$OUT/Sidelight-$VERSION.dmg"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [[ -n "$NOTES" && ! -f "$NOTES" ]]; then
    echo "error: release notes file does not exist: $NOTES" >&2
    exit 1
fi
if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
    echo "error: release builds require full Git history (git fetch --unshallow)" >&2
    exit 1
fi

IDENTITY=$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ && !found { print $2; found=1 }')
if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application identity in the keychain" >&2
    exit 1
fi

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
else
    NOTARY=(--keychain-profile "${NOTARY_PROFILE:-sidelight}")
fi

# Fail before building if Apple has rejected the credentials or needs a new agreement accepted.
xcrun notarytool history "${NOTARY[@]}" --output-format json > /dev/null

# Uploads $1 to Apple's notary service, waits for the verdict and prints the log if it's rejected.
notarize() {
    local result id status
    echo "Notarizing $1…"
    result=$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 20m --output-format json)
    id=$(plutil -extract id raw -o - - <<<"$result")
    status=$(plutil -extract status raw -o - - <<<"$result")
    if [[ "$status" != Accepted ]]; then
        echo "error: notarization of $1: $status" >&2
        xcrun notarytool log "$id" "${NOTARY[@]}" >&2
        exit 1
    fi
}

rm -rf "$OUT"
mkdir -p "$OUT"

SIGN_IDENTITY="$IDENTITY" VERSION="$VERSION" scripts/build-app.sh release
BIN_PATH=$(swift build --configuration release --show-bin-path)
if [[ -d "$BIN_PATH/Sidelight.dSYM" ]]; then
    ditto "$BIN_PATH/Sidelight.dSYM" "$OUT/Sidelight.dSYM"
else
    dsymutil "$BIN_PATH/Sidelight" -o "$OUT/Sidelight.dSYM"
fi

# The app itself is notarized and stapled too, so its first launch passes Gatekeeper even offline.
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip"
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Sidelight.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname Sidelight -srcfolder "$STAGING" -format ULFO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

spctl --assess --type execute "$APP"
spctl --assess --type open --context context:primary-signature "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")

# generate_appcast picks up release notes named like the archive, and only reads archives from its directory.
APPCAST_SOURCE="$OUT/appcast"
mkdir "$APPCAST_SOURCE"
ln "$DMG" "$APPCAST_SOURCE/"
if [[ -n "$NOTES" ]]; then
    cp "$NOTES" "$APPCAST_SOURCE/Sidelight-$VERSION.md"
fi
APPCAST_OPTIONS=(
    --download-url-prefix "$REPO_URL/releases/download/v$VERSION/"
    --full-release-notes-url "$REPO_URL/releases/tag/v$VERSION"
    --link "$REPO_URL"
    --embed-release-notes
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${APPCAST_OPTIONS[@]}" "$APPCAST_SOURCE" <<<"$SPARKLE_PRIVATE_KEY"
else
    "$SPARKLE_BIN/generate_appcast" --account sidelight "${APPCAST_OPTIONS[@]}" "$APPCAST_SOURCE"
fi
mv "$APPCAST_SOURCE/appcast.xml" "$OUT/appcast.xml"
# Check what installed apps will receive, including a cryptographic verification of the DMG signature.
python3 scripts/verify-appcast.py "$APP/Contents/Info.plist" "$DMG" "$OUT/appcast.xml" "$VERSION" "$REPO_URL"
rm -rf "$APPCAST_SOURCE"

echo "Released Sidelight $VERSION:"
ls -1 "$OUT"

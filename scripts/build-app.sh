#!/bin/bash
# Builds Sidelight.app from the Swift package and code-signs it.
#
# Usage: [VERSION=1.2.3] scripts/build-app.sh [release|debug]
#
# VERSION overrides CFBundleShortVersionString from Resources/Info.plist (the release workflow sets it from the tag).
#
# Signing identity: $SIGN_IDENTITY if set, else the first "Developer ID Application" or "Apple Development"
# identity in the keychain, else ad-hoc. Signing with the same identity every time keeps the Accessibility and
# Calendar permissions macOS granted to previous builds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=${1:-release}
APP=build/Sidelight.app

# On the macOS 26 SDK, SwiftUI's macro plugin (SwiftUIMacros) ships only with Xcode, not the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build --configuration "$CONFIGURATION" --product Sidelight
BINARY="$(swift build --configuration "$CONFIGURATION" --show-bin-path)/Sidelight"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Sidelight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Bundle everything else in Resources/ (e.g. wallpaper.jpg, the default image-style background).
find Resources -maxdepth 1 -type f ! -name Info.plist -exec cp {} "$APP/Contents/Resources/" \;

# Build number = commit count, so every commit produces a monotonically increasing CFBundleVersion.
if BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null); then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development)' | head -1 | awk '{print $2}' || true)}
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
    echo "warning: no signing identity found; ad-hoc signed (permissions reset on every build)" >&2
fi

codesign --verify --strict "$APP"
echo "Built $APP ($CONFIGURATION)"

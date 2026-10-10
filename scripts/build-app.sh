#!/bin/bash
# Builds Sidelight.app from the Swift package, embeds Sparkle.framework and code-signs it all.
#
# Usage: [VERSION=1.2.3] scripts/build-app.sh [release|debug]
#
# VERSION overrides CFBundleShortVersionString from Resources/Info.plist (scripts/release.sh sets it from the tag).
#
# Signing identity: $SIGN_IDENTITY if set, else the first "Developer ID Application" or "Apple Development"
# identity in the keychain, else ad-hoc. Signing with the same identity every time keeps the Accessibility and
# Calendar permissions macOS granted to previous builds. Developer ID signatures get a secure timestamp, which
# notarization requires.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=${1:-release}
APP=build/Sidelight.app
if [[ "$CONFIGURATION" != release && "$CONFIGURATION" != debug ]]; then
    echo "error: configuration must be release or debug" >&2
    exit 1
fi
if [[ -n "${VERSION:-}" && ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: VERSION must be a numeric version such as 0.1.0" >&2
    exit 1
fi

# On the macOS 26 SDK, SwiftUI's macro plugin (SwiftUIMacros) ships only with Xcode, not the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build --configuration "$CONFIGURATION" --product Sidelight -Xswiftc -warnings-as-errors
BIN_PATH=$(swift build --configuration "$CONFIGURATION" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH/Sidelight" "$APP/Contents/MacOS/Sidelight"
# Xcode's build system may already ad-hoc sign the executable. We replace that signature after packaging.
codesign --remove-signature "$APP/Contents/MacOS/Sidelight"
# SwiftPM links frameworks next to the binary (@loader_path); in the bundle they live in Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Sidelight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Bundle everything else in Resources/ (e.g. wallpaper.jpg, the default image-style background).
find Resources -maxdepth 1 -type f ! -name Info.plist ! -name '*.entitlements' -exec cp {} "$APP/Contents/Resources/" \;
# The app icon: Icon Composer's AppIcon.icon (from design/logo/generate.py), compiled into Assets.car and
# AppIcon.icns. Info.plist names it already, so actool's partial plist is discarded.
ICON_PLIST=$(mktemp)
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --output-partial-info-plist "$ICON_PLIST" --platform macosx --minimum-deployment-target 26.0 \
    --output-format human-readable-text --warnings --notices
rm -f "$ICON_PLIST"
# SwiftPM's compiled asset catalog, kept in the app's Resources directory.
RESOURCE_BUNDLE="$APP/Contents/Resources/Sidelight_Sidelight.bundle"
ditto "$BIN_PATH/Sidelight_Sidelight.bundle" "$RESOURCE_BUNDLE"
# SwiftBuild emits a macOS bundle and compiled catalog. Older SwiftPM engines copy bare resources instead;
# AppKit needs bundle metadata as well as Assets.car to load named images from those resources.
ASSET_OUTPUT="$RESOURCE_BUNDLE/Contents/Resources"
if [[ ! -d "$RESOURCE_BUNDLE/Contents" ]]; then
    mkdir -p "$ASSET_OUTPUT"
    cat > "$RESOURCE_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>app.getsidelight.Sidelight.ProviderLogos</string>
    <key>CFBundleName</key><string>Sidelight_Sidelight</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
fi
if [[ ! -f "$ASSET_OUTPUT/Assets.car" ]]; then
    xcrun actool Sources/Sidelight/Widgets/AIUsage/ProviderLogos.xcassets \
        --compile "$ASSET_OUTPUT" --platform macosx --minimum-deployment-target 26.0 \
        --output-format human-readable-text --warnings --notices
    rm -rf "$RESOURCE_BUNDLE/ProviderLogos.xcassets" "$ASSET_OUTPUT/ProviderLogos.xcassets"
fi

# ditto keeps the framework's symlinks. Headers are build-time only; the XPC services only serve sandboxed apps.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_PATH/Sparkle.framework" "$SPARKLE"
for item in XPCServices Headers PrivateHeaders Modules; do rm -rf "${SPARKLE:?}/$item" "$SPARKLE/Versions/B/$item"; done

# Count main's history rather than commits merged from side branches. CI releases only tags on main.
if BUILD_NUMBER=$(git rev-list --first-parent --count HEAD 2>/dev/null); then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development)' | head -1 | awk '{print $2}' || true)}
if [[ -z "$IDENTITY" ]]; then
    # No hardened runtime: its library validation would refuse to load an ad-hoc signed Sparkle.framework.
    SIGN_OPTIONS=(--sign -)
    echo "warning: no signing identity found; ad-hoc signed (permissions reset on every build)" >&2
elif security find-identity -v -p codesigning | grep -F "$IDENTITY" | grep -q '"Developer ID Application'; then
    SIGN_OPTIONS=(--sign "$IDENTITY" --options runtime --timestamp)
else
    SIGN_OPTIONS=(--sign "$IDENTITY" --options runtime --timestamp=none)
fi

# Inside out, without --deep: Sparkle's helpers, then the framework, then the app with its entitlements.
sign() { codesign --force "${SIGN_OPTIONS[@]}" "$@"; }
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements Resources/Sidelight.entitlements "$APP"

codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIGURATION)"

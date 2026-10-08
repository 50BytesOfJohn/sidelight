#!/bin/bash
# Build SidePanel.app from SwiftPM (no Xcode needed) and sign it.
set -euo pipefail
cd "$(dirname "$0")"
# macOS 26 SDK: SwiftUI @State etc. are macros whose plugin (SwiftUIMacros) ships only with Xcode, not the CLT.
if [ -d /Applications/Xcode.app/Contents/Developer ] && [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
LOG=$(mktemp)
if ! swift build -c release >"$LOG" 2>&1; then grep -E "error" "$LOG" | head -20; echo "BUILD FAILED"; exit 1; fi
grep -E "warning:" "$LOG" | grep -v "search path" | head -5 || true
BIN=$(swift build -c release --show-bin-path)/SidePanel
test -x "$BIN"
APP=build/SidePanel.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SidePanel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/widget.html "$APP/Contents/Resources/"
ID=$(security find-identity -v -p codesigning | grep -E '"(Apple Development|Developer ID Application)' | head -1 | awk '{print $2}')
if [ -n "$ID" ]; then codesign --force --sign "$ID" --timestamp=none "$APP"; else codesign --force --sign - "$APP"; echo "ad-hoc signed"; fi
codesign -dv "$APP" 2>&1 | grep -E "Authority=|Identifier=|TeamIdentifier" || true
echo "built $APP"

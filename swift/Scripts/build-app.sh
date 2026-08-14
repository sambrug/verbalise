#!/bin/bash
#
# Build OpenWhisperSwift.app: compile, assemble the bundle, sign it sandboxed.
#
# This does by hand what `xcodebuild` would do from an .xcodeproj. There is no
# Xcode on this machine (Command Line Tools only), and none of the three steps
# needs it -- swiftc, the bundle layout, and codesign are all CLT tools.
#
# Signing uses the same local "Open Whisper Dev" identity as the Python app
# (scripts/create-signing-cert.sh) so that TCC grants -- Input Monitoring and
# PostEvent, which are the expensive ones for the user to re-grant -- survive
# rebuilds instead of being voided by a fresh ad-hoc signature each time.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(cd .. && pwd)"

CONFIG="${CONFIG:-release}"
APP_NAME="OpenWhisperSwift"
BUNDLE="build/${APP_NAME}.app"
IDENTITY="${SIGN_IDENTITY:-Open Whisper Dev}"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "error: signing identity '$IDENTITY' not found." >&2
    echo "Run ${REPO_ROOT}/scripts/create-signing-cert.sh first." >&2
    exit 1
fi

echo "==> Compiling ($CONFIG)..."
swift build -c "$CONFIG" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)"

echo "==> Assembling $BUNDLE..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

if [ -f "$REPO_ROOT/assets/AppIcon.icns" ]; then
    cp "$REPO_ROOT/assets/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# The pill's icons. Loaded by path at runtime rather than compiled in, exactly
# as the Python overlay did, so the SVGs stay the single source for both apps.
if [ -d "$REPO_ROOT/SVG icons for menu bar" ]; then
    cp -R "$REPO_ROOT/SVG icons for menu bar" "$BUNDLE/Contents/Resources/"
else
    echo "    warning: pill icons not found — falling back to SF Symbols" >&2
fi

# The bundled speech model, if it has been staged. Absent in a normal
# development build, which falls back to downloading on demand rather than
# making every rebuild copy a gigabyte around. Run Scripts/fetch-default-model.sh
# before a release or App Store archive.
if [ -d "Resources/Models" ] && [ -n "$(ls -A Resources/Models 2>/dev/null)" ]; then
    echo "    including bundled model ($(du -sh Resources/Models | cut -f1))"
    cp -R "Resources/Models" "$BUNDLE/Contents/Resources/Models"
else
    echo "    no bundled model staged — the app will download on first use"
fi

echo "==> Signing as '$IDENTITY' (sandboxed)..."
codesign --force \
    --sign "$IDENTITY" \
    --entitlements Resources/${APP_NAME}.entitlements \
    --timestamp=none \
    "$BUNDLE"

codesign --verify --verbose=2 "$BUNDLE"

echo
echo "==> Entitlements actually applied:"
codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null \
    | plutil -convert xml1 -o - - \
    | grep -E "app-sandbox|audio-input|network.client" || true

echo
echo "Built $BUNDLE"
echo "Run it with:  open $(pwd)/$BUNDLE"

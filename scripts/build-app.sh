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
REPO_ROOT="$(pwd)"

CONFIG="${CONFIG:-release}"
APP_NAME="OpenWhisperSwift"
BUNDLE="build/${APP_NAME}.app"
IDENTITY="${SIGN_IDENTITY:-Open Whisper Dev}"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "error: signing identity '$IDENTITY' not found." >&2
    echo "Run 'make signing-cert' first." >&2
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

cp "Resources/PrivacyInfo.xcprivacy" "$BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"

# The app icon.
#
# Resources/AppIcon.icon is an Icon Composer bundle -- layered SVGs, a gradient
# and a translucency setting, which macOS 26 renders as a Liquid Glass icon.
# It is not a file that can be copied: actool compiles it, and usefully emits
# both an Assets.car for macOS 26 and a plain .icns for 14 and 15, so one
# source covers the whole deployment range.
#
# actool ships with Xcode. Without Xcode the build still works and falls back
# to the flat icon the Python app uses, so Command Line Tools remain enough to
# build a running app.
if [ -d "Resources/AppIcon.icon" ] && xcrun --find actool >/dev/null 2>&1; then
    ICON_WORK="$(mktemp -d)"
    # Both paths absolute. actool resolves relative paths against something
    # other than the working directory -- the output landed a level up and the
    # input could not be found at all.
    xcrun actool "$(pwd)/Resources/AppIcon.icon" \
        --compile "$(pwd)/$BUNDLE/Contents/Resources" \
        --app-icon AppIcon \
        --output-partial-info-plist "$ICON_WORK/icon.plist" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --errors --warnings >/dev/null

    # actool reports the keys it wants rather than assuming them; merging what
    # it says beats hardcoding CFBundleIconName and finding out later that the
    # set changed.
    /usr/libexec/PlistBuddy -c "Merge $ICON_WORK/icon.plist" "$BUNDLE/Contents/Info.plist"
    rm -rf "$ICON_WORK"
    echo "    icon: compiled AppIcon.icon (Liquid Glass + .icns fallback)"
elif [ -f "Resources/AppIcon-fallback.icns" ]; then
    # Same artwork, flat. actool emits this alongside the Assets.car, and the
    # copy is committed so a machine without Xcode still ships the current
    # icon rather than whatever the Python app happens to be using.
    #
    # Regenerate it after changing AppIcon.icon:
    #   ./Scripts/build-app.sh && cp \
    #     build/OpenWhisperSwift.app/Contents/Resources/AppIcon.icns \
    #     Resources/AppIcon-fallback.icns
    cp "Resources/AppIcon-fallback.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true
    echo "    icon: AppIcon-fallback.icns (no actool, so no Liquid Glass icon)"
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

#!/usr/bin/env bash
#
# Builds assets/AppIcon.icns from a single square PNG.
#
#   ./scripts/make-icon.sh path/to/icon.png
#
# macOS wants an icon at ten sizes, from 16pt up to 512pt@2x. Handing it one
# large PNG and letting the system scale gives you a blurry menu bar and a soft
# Dock icon, so each size is rendered separately here.
#
# sips and iconutil both ship with macOS. No dependencies.

set -euo pipefail

SOURCE="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$REPO_ROOT/assets/AppIcon.icns"

if [ -z "$SOURCE" ]; then
    echo "usage: $0 path/to/icon.png" >&2
    exit 1
fi

if [ ! -f "$SOURCE" ]; then
    echo "error: $SOURCE not found" >&2
    exit 1
fi

# 1024 is the largest size macOS asks for, and the one App Store Connect wants.
# Anything smaller gets upscaled somewhere and looks it.
WIDTH=$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')
HEIGHT=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')

if [ "$WIDTH" != "$HEIGHT" ]; then
    echo "error: icon must be square, got ${WIDTH}x${HEIGHT}" >&2
    exit 1
fi

if [ "$WIDTH" -lt 1024 ]; then
    echo "warning: source is ${WIDTH}px; 1024 or larger is wanted for the" >&2
    echo "         Dock at 2x and for App Store Connect." >&2
fi

WORK="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

# Name and size pairs are fixed by iconutil -- it reads the filenames.
render() {
    sips -z "$2" "$2" "$SOURCE" --out "$WORK/$1" >/dev/null
}

render icon_16x16.png        16
render icon_16x16@2x.png     32
render icon_32x32.png        32
render icon_32x32@2x.png     64
render icon_128x128.png     128
render icon_128x128@2x.png  256
render icon_256x256.png     256
render icon_256x256@2x.png  512
render icon_512x512.png     512
render icon_512x512@2x.png 1024

iconutil --convert icns "$WORK" --output "$OUTPUT"

echo "Wrote $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo
echo "Both apps use this file. To see it:"
echo "    make swift-app && open swift/build/OpenWhisperSwift.app"
echo
echo "Finder caches icons aggressively. If the old one persists:"
echo "    touch swift/build/OpenWhisperSwift.app && killall Dock"

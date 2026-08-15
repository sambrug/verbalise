#!/bin/bash
#
# Download the bundled speech model into Resources/Models so build-app.sh can
# copy it into the .app (plan §4).
#
# The app ships with exactly one model — the "balanced" tier — so a fresh
# install can dictate immediately instead of waiting on a download. The other
# two tiers download on demand the first time they are selected, which is why
# only one is fetched here: bundling all three would triple the package for
# models most users will never pick.
#
# The download itself goes through the app's own code path (--warm-model) so
# this script cannot drift from what the app does at runtime. That also means
# it exercises the sandboxed download, not a separate curl.
#
# Not run automatically. Development builds skip it and fall back to
# downloading on demand, which keeps the edit-build-run loop fast; release and
# App Store archives should run it first.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Verbalise.app"
BINARY="$APP/Contents/MacOS/Verbalise"
DEST="Resources/Models"
CONTAINER="$HOME/Library/Containers/com.sambruggen.verbalise/Data/Library/Application Support/Models/models/argmaxinc/whisperkit-coreml"

if [ ! -x "$BINARY" ]; then
    echo "error: $BINARY not found. Run ./Scripts/build-app.sh first." >&2
    exit 1
fi

# Roughly 1GB, and a full disk mid-download leaves a partial model behind.
AVAILABLE_GB=$(df -g . | awk 'NR==2 {print $4}')
if [ "${AVAILABLE_GB:-0}" -lt 5 ]; then
    echo "error: only ${AVAILABLE_GB}GB free; need at least 5GB headroom." >&2
    exit 1
fi

echo "==> Downloading the bundled model via the app's own path..."
"$BINARY" --warm-model

VARIANT=$("$BINARY" --print-bundled-variant)
SOURCE="$CONTAINER/$VARIANT"

if [ ! -d "$SOURCE" ]; then
    echo "error: expected $SOURCE after the download, but it is missing." >&2
    exit 1
fi

echo "==> Staging into $DEST/$VARIANT..."
rm -rf "${DEST:?}/$VARIANT"
mkdir -p "$DEST"
cp -R "$SOURCE" "$DEST/$VARIANT"

echo
echo "Staged $(du -sh "$DEST/$VARIANT" | cut -f1) into $DEST/$VARIANT"
echo "Re-run ./Scripts/build-app.sh to fold it into the bundle."

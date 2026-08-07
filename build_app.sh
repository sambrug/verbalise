#!/usr/bin/env bash
#
# Build a self-contained Open Whisper.app bundle.
#
# What this script does, in order:
#   1. Compile the Swift overlay binary (Apple Silicon only — see plan).
#   2. Run py2app to produce dist/Open Whisper.app with Python and every
#      requirement vendored inside Contents/Resources/.
#   3. Restore the overlay binary's executable bit (py2app's resource copy
#      sometimes drops it).
#   4. Print bundle size + first-launch instructions.
#
# Run with: ./build_app.sh
#
# Pre-requirements: setup.sh must have been run at least once so .venv
# exists with all deps. py2app itself is auto-installed if missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python3"
DIST_APP="$SCRIPT_DIR/dist/Open Whisper.app"

if [ ! -x "$VENV_PYTHON" ]; then
    echo "Error: $VENV_PYTHON not found. Run ./setup.sh first." >&2
    exit 1
fi

# Ensure py2app is installed in the build venv. We invoke pip via
# `python -m pip` rather than the venv's pip wrapper script — that
# wrapper has the venv-creation-time absolute python path baked into
# its shebang, which breaks if the project was ever renamed or moved.
if ! "$VENV_PYTHON" -c "import py2app" 2>/dev/null; then
    echo "==> Installing py2app (build-only dependency)..."
    "$VENV_PYTHON" -m pip install --quiet py2app
fi

echo "==> Compiling overlay (Swift, arm64)..."
# Target macOS 13: the overlay uses TimelineView (12+) and glassEffect (26+,
# soft-falls-back via #available). 13 is also what setup.sh targets, so the
# source-run and bundled builds stay in sync.
#
# Remove the existing binary first so the linker can write a fresh one
# even when the previous build is still running (e.g. user has Open
# Whisper open in the menu bar). `rm` only unlinks the directory entry;
# the running process keeps its open fd until it exits.
rm -f "$SCRIPT_DIR/overlay"
swiftc "$SCRIPT_DIR/overlay.swift" \
    -o "$SCRIPT_DIR/overlay" \
    -parse-as-library \
    -framework SwiftUI -framework AppKit \
    -O \
    -target arm64-apple-macosx13.0

echo "==> Cleaning previous build output..."
# py2app ad-hoc-signs the bundled Python framework, which leaves
# CodeResources / Python binaries with no write permission. `rm -rf`
# bails on those — restore writability before cleaning.
chmod -R u+w "$SCRIPT_DIR/build" "$SCRIPT_DIR/dist" 2>/dev/null || true
rm -rf "$SCRIPT_DIR/build" "$SCRIPT_DIR/dist"

# Workaround: `mlx` is shipped as a PEP 420 namespace package — no
# `__init__.py`. py2app's `collect_packagedirs` calls `imp.find_module()`
# which requires an `__init__.py`, so it errors out with "No module named
# 'mlx'". Drop a one-byte stub in to satisfy the collector. Empty
# __init__.py is functionally equivalent to a namespace package for our
# usage (import mlx; import mlx.core both still work). Idempotent —
# harmless if it already exists.
MLX_INIT="$SCRIPT_DIR/.venv/lib/python3.13/site-packages/mlx/__init__.py"
if [ ! -f "$MLX_INIT" ]; then
    echo "==> Writing mlx/__init__.py shim (py2app namespace-package workaround)..."
    : > "$MLX_INIT"
fi

echo "==> Running py2app (this can take a few minutes)..."
cd "$SCRIPT_DIR"
"$VENV_PYTHON" setup.py py2app

echo "==> Post-processing bundle..."
chmod +x "$DIST_APP/Contents/Resources/overlay"

# Sign with the machine's stable local identity when it exists, so TCC
# permissions (Accessibility etc.) survive reinstalls. Created by
# scripts/create-signing-cert.sh (make signing-cert) — once per machine.
SIGN_IDENTITY="Open Whisper Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> Signing bundle as '$SIGN_IDENTITY'..."
    codesign --force --deep --sign "$SIGN_IDENTITY" "$DIST_APP"
else
    echo "⚠️  No '$SIGN_IDENTITY' signing identity found — bundle stays ad-hoc"
    echo "   signed, so Accessibility must be re-granted after every install."
    echo "   Fix once per machine with:  make signing-cert"
fi

# Print summary
echo
echo "================================================================"
echo "Build complete:  $DIST_APP"
echo "Bundle size:     $(du -sh "$DIST_APP" | cut -f1)"
echo
echo "To test it:"
echo "  1. Quit any running menubar.py / Open Whisper instance."
echo "  2. Move the bundle somewhere outside the source repo:"
echo "       cp -R \"$DIST_APP\" /tmp/"
echo "  3. Right-click /tmp/Open\\ Whisper.app → Open (first time only,"
echo "     to bypass the Gatekeeper warning for unsigned apps)."
echo "  4. Grant microphone permission when prompted."
echo "  5. Manually add the app to System Settings >"
echo "     Privacy & Security > Accessibility."
echo "================================================================"

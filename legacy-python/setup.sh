#!/bin/bash
# Dev setup: create the venv, install dependencies, compile the overlay.
# To build the distributable app afterwards, run: make app
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "🔧 Setting up Open Whisper..."
echo ""

# Create virtual environment if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

# Activate and install
echo "📦 Installing dependencies..."
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$SCRIPT_DIR/requirements.txt"

# Build the overlay pill if swiftc is available
if command -v swiftc &> /dev/null; then
    echo "🔨 Building overlay..."
    swiftc "$SCRIPT_DIR/overlay.swift" -o "$SCRIPT_DIR/overlay" \
        -parse-as-library -framework SwiftUI -framework AppKit -O \
        -target arm64-apple-macosx13.0 \
        && echo "   Overlay built." \
        || echo "⚠️  Overlay build failed — overlay feature will be disabled."
else
    echo "⚠️  swiftc not found (xcode-select --install) — overlay won't be available."
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "Run from source:   $VENV_DIR/bin/python3 $SCRIPT_DIR/menubar.py"
echo "Build the app:     make app && make install"
echo ""

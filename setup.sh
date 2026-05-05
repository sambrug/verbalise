#!/bin/bash
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

# Build Swift components if swiftc is available
if command -v swiftc &> /dev/null; then
    echo "🔨 Building overlay..."
    swiftc "$SCRIPT_DIR/overlay.swift" -o "$SCRIPT_DIR/overlay" \
        -parse-as-library -framework SwiftUI -framework AppKit -O \
        -target arm64-apple-macosx13.0 \
        && echo "   Overlay built." \
        || echo "⚠️  Overlay build failed — overlay feature will be disabled."

    echo "🔨 Building app bundle..."
    APP_DIR="$SCRIPT_DIR/Open Whisper.app"
    mkdir -p "$APP_DIR/Contents/MacOS"
    mkdir -p "$APP_DIR/Contents/Resources"

    swiftc "$SCRIPT_DIR/launcher.swift" -o "$APP_DIR/Contents/MacOS/launcher" \
        -O -target arm64-apple-macosx13.0 \
        && echo "   Launcher built." \
        || echo "⚠️  Launcher build failed — .app bundle won't work."

    # Create Info.plist
    cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Open Whisper</string>
    <key>CFBundleIdentifier</key>
    <string>com.sambruggen.open-whisper</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>NSMicrophoneUsageDescription</key>
    <string>Open Whisper needs microphone access to transcribe your speech.</string>
</dict>
</plist>
PLIST

    # Generate app icon if create_icon.py exists and icon is missing
    if [ -f "$SCRIPT_DIR/create_icon.py" ] && [ ! -f "$APP_DIR/Contents/Resources/AppIcon.icns" ]; then
        echo "🎨 Generating app icon..."
        "$VENV_DIR/bin/python3" "$SCRIPT_DIR/create_icon.py" 2>/dev/null \
            && echo "   Icon generated." \
            || echo "⚠️  Icon generation failed — app will use default icon."
    fi

    echo "   App bundle ready."
else
    echo "⚠️  swiftc not found — overlay and .app bundle won't be available."
fi

# Create config.yaml from example if it doesn't exist
if [ ! -f "$SCRIPT_DIR/config.yaml" ]; then
    echo "📝 Creating config.yaml from example..."
    cp "$SCRIPT_DIR/config.example.yaml" "$SCRIPT_DIR/config.yaml"
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "To run the menu bar app:"
echo "  $VENV_DIR/bin/python3 $SCRIPT_DIR/menubar.py"
echo ""
echo "Or double-click: Open Whisper.app"
echo ""

# Check for Ollama
if ! command -v ollama &> /dev/null; then
    echo "⚠️  Ollama not installed — text cleanup won't work."
    echo "   Download from: https://ollama.com"
    echo "   Then run: ollama pull qwen2.5:1.5b"
    echo ""
fi

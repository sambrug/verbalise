#!/bin/bash
# Add Open Whisper.app as a macOS Login Item.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/Open Whisper.app"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found: $APP_PATH"
    exit 1
fi

osascript -e "
tell application \"System Events\"
    try
        delete login item \"OpenWhisper\"
    end try
    try
        delete login item \"HomeWhisper\"
    end try
    make login item at end with properties {path:\"$APP_PATH\", name:\"OpenWhisper\", hidden:true}
end tell
"

echo "Added to Login Items. Open Whisper will start automatically on login."
echo "To remove: System Settings > General > Login Items > remove OpenWhisper"

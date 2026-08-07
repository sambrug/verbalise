#!/bin/bash
# Register the installed Open Whisper.app as a macOS Login Item.
# Looks in /Applications first, then ~/Applications.

APP_PATH="/Applications/Open Whisper.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH="$HOME/Applications/Open Whisper.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "App not found in /Applications or ~/Applications."
    echo "Build and install it first:  make app && make install"
    exit 1
fi

osascript -e "
tell application \"System Events\"
    try
        delete login item \"OpenWhisper\"
    end try
    try
        delete login item \"Open Whisper\"
    end try
    make login item at end with properties {path:\"$APP_PATH\", name:\"Open Whisper\", hidden:true}
end tell
"

echo "Added to Login Items: $APP_PATH"
echo "To remove: System Settings > General > Login Items"

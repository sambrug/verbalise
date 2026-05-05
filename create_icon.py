#!/usr/bin/env python3
"""
Generate the Open Whisper app icon and install it into the .app bundle.

Converts open_whisper_icon.png into a macOS .icns file at all required sizes.

Usage:
    python3 create_icon.py

Requires Pillow:
    pip install pillow
"""
import shutil
import subprocess
import tempfile
from pathlib import Path
from PIL import Image

PROJECT_DIR = Path(__file__).parent
APP_BUNDLE  = PROJECT_DIR / "Open Whisper.app"
RESOURCES   = APP_BUNDLE / "Contents" / "Resources"
ICNS_NAME   = "AppIcon.icns"
SOURCE_ICON = PROJECT_DIR / "open_whisper_icon.png"

ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def build_icns(source: Path, tmp_dir: Path) -> Path:
    iconset = tmp_dir / "AppIcon.iconset"
    iconset.mkdir()

    img = Image.open(source).convert("RGBA")

    for sz in ICON_SIZES:
        resized = img.resize((sz, sz), Image.LANCZOS)
        resized.save(iconset / f"icon_{sz}x{sz}.png")
        if sz <= 512:
            resized_2x = img.resize((sz * 2, sz * 2), Image.LANCZOS)
            resized_2x.save(iconset / f"icon_{sz}x{sz}@2x.png")

    icns_path = tmp_dir / ICNS_NAME
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
        check=True,
    )
    return icns_path


def main():
    if not SOURCE_ICON.exists():
        print(f"Icon source not found: {SOURCE_ICON}")
        print("Place open_whisper_icon.png in the project directory.")
        return

    print("Building Open Whisper icon...")
    RESOURCES.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        print("  Resizing icon for all sizes...")
        icns_path = build_icns(SOURCE_ICON, tmp_dir)
        dest = RESOURCES / ICNS_NAME
        shutil.copy(icns_path, dest)
        print(f"  Installed: {dest}")

    # Tell macOS to refresh the icon cache
    subprocess.run(["touch", str(APP_BUNDLE / "Contents" / "Info.plist")], check=False)

    print("Done. Restart Open Whisper to see the new icon.")
    print("If the Dock still shows the old icon, run: killall Dock")


if __name__ == "__main__":
    main()

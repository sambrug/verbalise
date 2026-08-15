#!/usr/bin/env python3
"""
Regenerate the Open Whisper app icon (assets/AppIcon.icns).

Converts assets/open_whisper_icon.png into a macOS .icns file at all
required sizes. Dev-only tool — the .icns is committed, so this only
needs re-running when the source PNG changes.

Usage:
    python3 create_icon.py

Requires Pillow (not in requirements.txt):
    pip install pillow
"""
import shutil
import subprocess
import tempfile
from pathlib import Path
from PIL import Image

PROJECT_DIR = Path(__file__).parent
ASSETS_DIR  = PROJECT_DIR / "assets"
ICNS_NAME   = "AppIcon.icns"
SOURCE_ICON = ASSETS_DIR / "open_whisper_icon.png"

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
        print("Place open_whisper_icon.png in the assets directory.")
        return

    print("Building Open Whisper icon...")
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        print("  Resizing icon for all sizes...")
        icns_path = build_icns(SOURCE_ICON, tmp_dir)
        dest = ASSETS_DIR / ICNS_NAME
        shutil.copy(icns_path, dest)
        print(f"  Written: {dest}")

    print("Done. Rebuild the app (make app) to pick up the new icon.")


if __name__ == "__main__":
    main()

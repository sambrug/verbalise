"""py2app build configuration.

Run via:

    .venv/bin/python3 setup.py py2app           # release build (full bundle)
    .venv/bin/python3 setup.py py2app -A        # alias mode (fast, points at source)

The build_app.sh / Makefile wrappers handle Swift compilation + py2app in one
go; this file is the py2app config they invoke. The output appears at
`dist/Open Whisper.app`.

Why some non-obvious choices:

  - `argv_emulation` is False because we're a menu-bar accessory app, not a
    document-handling app — argv_emulation forwards Apple Events as argv,
    which we don't need.
  - `LSUIElement = True` keeps the app out of the Dock and Cmd+Tab.
  - `mlx`, `mlx_whisper`, and `sounddevice` are listed in `packages` so
    py2app's modulegraph traversal picks them up. mlx in particular bundles
    Metal shader binaries and helper dylibs that py2app can miss when only
    listed in `includes`.
  - `daemon.py` is a script-resource (not a separate py2app entry point)
    because the menu bar spawns it as a subprocess via the bundled Python.
  - The Swift `overlay` binary is included as a data resource. Its
    executable bit is restored by build_app.sh after the bundle is built
    (py2app's resource copy doesn't preserve it on every macOS).
"""
import sys

# py2app's modulegraph uses recursive AST traversal, which on Python 3.13
# regularly blows past the default recursion limit (1000) when walking
# big native packages like numpy / mlx. Raise it before py2app starts.
sys.setrecursionlimit(10_000)

from setuptools import setup
from pathlib import Path

PROJECT_DIR = Path(__file__).parent

APP = ['menubar.py']

# Files that must end up inside Contents/Resources/.
DATA_FILES = [
    'daemon.py',
    'paths.py',
    'config.example.yaml',
    'overlay',                       # compiled by build_app.sh before py2app runs
    'SVG icons for menu bar',
]

PLIST = {
    'CFBundleName':           'Open Whisper',
    'CFBundleIdentifier':     'com.sambruggen.open-whisper',
    'CFBundleVersion':        '1.0',
    'CFBundleShortVersionString': '1.0',
    'CFBundleIconFile':       'AppIcon',  # AppIcon.icns under Contents/Resources/
    'LSUIElement':            True,        # menu bar accessory; no Dock icon
    'LSArchitecturePriority': ['arm64'],
    'LSMinimumSystemVersion': '13.0',
    'NSMicrophoneUsageDescription':
        'Open Whisper needs microphone access to transcribe your speech.',
    # macOS sets these env vars before exec'ing the bundled Python.
    # Without them, py2app's Python defaults to ASCII for sys.stdout /
    # sys.stderr because LANG / LC_ALL aren't inherited inside an .app
    # bundle. PYTHONUTF8=1 puts Python in UTF-8 mode (PEP 540) — all I/O
    # streams, default file encoding, and child processes use UTF-8.
    # PYTHONIOENCODING is a redundant safety net for older Python that
    # ignores PYTHONUTF8. Together they prevent encode/decode crashes
    # whenever em-dashes / sparkles / non-ASCII text appear in logs.
    'LSEnvironment': {
        'PYTHONUTF8': '1',
        'PYTHONIOENCODING': 'utf-8',
    },
    # The accessibility prompt is triggered by pynput on first key listen;
    # there's no Info.plist key for it, but the user must add the .app to
    # System Settings > Privacy & Security > Accessibility.
}

OPTIONS = {
    'argv_emulation': False,
    'iconfile': str(PROJECT_DIR / 'assets' / 'AppIcon.icns'),
    'plist': PLIST,
    # Force py2app to vendor these top-level packages whole, including
    # native dylibs / Metal shaders that the modulegraph traversal might
    # otherwise skip. Listing a package here also keeps it unpacked under
    # Contents/Resources/ instead of zipped into python313.zip — that
    # matters for any package whose code does file-relative dylib lookup
    # (sounddevice → libportaudio.dylib via _sounddevice_data).
    'packages': [
        'mlx',
        'mlx_whisper',
        'numpy',
        'sounddevice',
        '_sounddevice_data',  # holds libportaudio.dylib; must stay on disk
        'pynput',
        'rumps',
        'objc',
        'AppKit',
        'Foundation',
        'certifi',
        'yaml',
    ],
    # Single-file modules from this project that py2app should pick up
    # alongside menubar.py.
    'includes': [
        'daemon',
        'paths',
    ],
    # Compress the Python stdlib into site-packages.zip — keeps the bundle
    # tidy. Set False during debugging if needed.
    'optimize': 0,
    # py2app sometimes complains about pyobjc subpackages it can't trace;
    # this short-circuits the warning for ones we know are safe.
    'excludes': [
        'tkinter',
        'PyQt5', 'PyQt6', 'PySide2', 'PySide6',
        'pytest', 'sphinx',
    ],
}

setup(
    app=APP,
    name='Open Whisper',
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)

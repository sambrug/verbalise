"""Filesystem paths for Open Whisper.

A single source of truth for where the app reads and writes things at
runtime. Keeping these in one place lets the same code work in two modes:

  - **Source mode**  (`python3 menubar.py` from the repo) — used during
    development. State files used to live next to the source; we now keep
    them in `~/Library/...` so the same code path also works for a
    distributed `.app`.
  - **Bundled mode** (a `.app` dropped in `/Applications` or anywhere
    else) — bundled resources live in `Contents/Resources/`, runtime
    state lives in `~/Library/...`.

Three helpers:

  - `state_dir()` — read/write user state. Config, transcript history,
    API-usage ledger, lock file. Lives in `~/Library/Application Support/
    Open Whisper/`. Created on first call.
  - `log_dir()` — daemon log + rotated backup. `~/Library/Logs/Open
    Whisper/`. Created on first call.
  - `bundle_resources_dir()` — read-only bundled resources: the overlay
    binary, SVG icons, `daemon.py`, `config.example.yaml`. In a bundled
    `.app` this returns `…/Contents/Resources/`. In source mode it
    returns the project directory.
"""
from __future__ import annotations

import sys
from pathlib import Path

APP_NAME = 'Open Whisper'


def state_dir() -> Path:
    """Return the user's Application Support directory for this app.

    Lazily creates the directory on first call. Use this for anything
    the app reads or writes at runtime that the *user* should be able
    to inspect, edit, or back up — config.yaml, transcript history,
    api-usage.json, the single-instance lock file.
    """
    path = Path.home() / 'Library' / 'Application Support' / APP_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def log_dir() -> Path:
    """Return the user's Logs directory for this app.

    Lazily creates the directory on first call. Used for `daemon.log`
    and its rotated backup.
    """
    path = Path.home() / 'Library' / 'Logs' / APP_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def bundle_resources_dir() -> Path:
    """Return the directory containing bundled app resources.

    When running inside a `.app` bundle, this is `…/Contents/Resources/`
    — the read-only payload py2app produced. When running from source
    (`python3 menubar.py` from the repo), this is the project directory.

    Detection strategy: walk up from `sys.executable` looking for a
    `.app` parent. This is reliable in both modes because:

      - In source mode, no parent of the system / venv Python ends in
        `.app`, so we fall through to the project dir.
      - In bundled mode, `sys.executable` lives at
        `…/Open Whisper.app/Contents/MacOS/python` (py2app's layout),
        so the `.app` parent is found two levels up.
    """
    exe = Path(sys.executable).resolve()
    for parent in exe.parents:
        if parent.suffix == '.app':
            return parent / 'Contents' / 'Resources'
    # Source mode — paths.py lives at the project root next to menubar.py
    # / daemon.py, so the project dir is just our own parent.
    return Path(__file__).resolve().parent

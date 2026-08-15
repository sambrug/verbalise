# Open Whisper (Python) — deprecated

This is the original Python implementation of the app, kept for reference.
It was superseded in August 2026 by the native Swift app (now **Verbalise**),
which lives at the repository root. Nothing outside this directory depends on
anything in it, and nothing in here is maintained.

Everything the Python app needs is self-contained here: the daemon, the rumps
menu bar app, the SwiftUI overlay, its build scripts, its icon assets, and its
test suite.

## Building it anyway

```sh
./setup.sh                    # install Python deps + build the overlay
.venv/bin/python3 menubar.py  # run from source
make app && make install      # build dist/Open Whisper.app and install it
make test                     # the recording-lifecycle recovery tests
```

Two things to know if you resurrect it:

- It signs with its own "Open Whisper Dev" identity
  (`scripts/create-signing-cert.sh`), separate from the Verbalise one.
- It installs as `/Applications/Open Whisper.app` with bundle ID
  `com.sambruggen.open-whisper` — it can coexist with Verbalise, but both
  listen for a trigger key, so don't run the two at once.

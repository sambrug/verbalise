# Open Whisper (Python) — deprecated. See README.md in this directory.
#
# These are the Python app's original build targets, moved here with it.
# Run them from this directory.

.PHONY: help test signing-cert dev-setup overlay app app-dev app-clean install icon

help:
	@echo "Open Whisper (Python, deprecated) — make targets:"
	@echo ""
	@echo "  make test         Run the recording-lifecycle recovery tests"
	@echo "  make signing-cert Create the per-machine code-signing certificate (once)"
	@echo "  make dev-setup    Install Python deps + build overlay (source-run mode)"
	@echo "  make overlay      Recompile the Swift overlay binary only"
	@echo "  make app          Build a self-contained dist/Open\\ Whisper.app (release)"
	@echo "  make app-dev      Build dist/Open\\ Whisper.app in alias mode (fast iteration)"
	@echo "  make app-clean    Wipe build/, dist/, *.egg-info/"
	@echo "  make install      Copy dist/Open\\ Whisper.app to /Applications/"
	@echo ""
	@echo "  make icon PNG=x.png  Rebuild assets/AppIcon.icns from a square PNG"
	@echo ""

test:
	.venv/bin/python3 tests/test_recovery.py

signing-cert:
	./scripts/create-signing-cert.sh

dev-setup:
	./setup.sh

overlay:
	swiftc overlay.swift -o overlay -parse-as-library \
		-framework SwiftUI -framework AppKit -O \
		-target arm64-apple-macosx13.0

app:
	./build_app.sh

app-dev:
	@echo "Building in alias mode (changes to .py files take effect without rebuild)..."
	rm -rf build dist
	.venv/bin/python3 setup.py py2app -A

app-clean:
	rm -rf build dist *.egg-info

install:
	@# Don't depend on `app` — that would mean `sudo make install` runs the
	@# whole build as root, leaving root-owned build/ and dist/ that the
	@# user can't clean up later. Run `make app` first (as your user),
	@# then `sudo make install` to copy the result.
	@if [ ! -d "dist/Open Whisper.app" ]; then \
		echo "Error: dist/Open Whisper.app not found. Run 'make app' first." >&2; \
		exit 1; \
	fi
	@echo "==> Installing to /Applications/ ..."
	@if [ "$$(id -u)" -ne 0 ]; then \
		sudo rm -rf "/Applications/Open Whisper.app" && \
		sudo cp -R "dist/Open Whisper.app" "/Applications/"; \
	else \
		rm -rf "/Applications/Open Whisper.app" && \
		cp -R "dist/Open Whisper.app" "/Applications/"; \
	fi
	@echo "    Done. Right-click /Applications/Open\\ Whisper.app → Open the first time."

icon:
	@# Rebuilds assets/AppIcon.icns from a PNG:  make icon PNG=path/to/icon.png
	@if [ -z "$(PNG)" ]; then \
		echo "usage: make icon PNG=path/to/icon.png" >&2; exit 1; \
	fi
	./scripts/make-icon.sh "$(PNG)"

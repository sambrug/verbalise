# Open Whisper — convenience build targets.
#
# These wrap the existing setup.sh / build_app.sh scripts so common
# operations are short to type. The scripts themselves stay the source
# of truth — run them directly if you want full output.

.PHONY: help app app-dev app-clean install dev-setup overlay test

help:
	@echo "Open Whisper — make targets:"
	@echo ""
	@echo "  make test         Run the recording-lifecycle recovery tests"
	@echo "  make dev-setup    Install Python deps + build overlay+launcher (source-run mode)"
	@echo "  make overlay      Recompile the Swift overlay binary only"
	@echo "  make app          Build a self-contained dist/Open\\ Whisper.app (release)"
	@echo "  make app-dev      Build dist/Open\\ Whisper.app in alias mode (fast iteration)"
	@echo "  make app-clean    Wipe build/, dist/, *.egg-info/"
	@echo "  make install      Copy dist/Open\\ Whisper.app to /Applications/"
	@echo ""

test:
	.venv/bin/python3 tests/test_recovery.py

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

install-user: app
	@# Per-user install — no sudo needed, lives under ~/Applications/.
	@echo "==> Installing to ~/Applications/ ..."
	@mkdir -p "$$HOME/Applications"
	rm -rf "$$HOME/Applications/Open Whisper.app"
	cp -R "dist/Open Whisper.app" "$$HOME/Applications/"
	@echo "    Done. Right-click ~/Applications/Open\\ Whisper.app → Open the first time."

# Open Whisper — convenience build targets.
#
# These wrap the existing setup.sh / build_app.sh scripts so common
# operations are short to type. The scripts themselves stay the source
# of truth — run them directly if you want full output.

.PHONY: help app app-dev app-clean install dev-setup overlay test signing-cert
.PHONY: swift-app swift-test swift-run swift-xcodeproj test-all

help:
	@echo "Open Whisper — make targets:"
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
	@echo "  Swift port (swift/ — coexists with the Python app):"
	@echo "  make swift-test      Run the Swift test suite"
	@echo "  make swift-app       Build + sign swift/build/OpenWhisperSwift.app"
	@echo "  make swift-run       Build and launch it"
	@echo "  make swift-xcodeproj Generate swift/OpenWhisperSwift.xcodeproj (needs xcodegen)"
	@echo "  make test-all        Run both the Python and Swift suites"
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

install-user: app
	@# Per-user install — no sudo needed, lives under ~/Applications/.
	@echo "==> Installing to ~/Applications/ ..."
	@mkdir -p "$$HOME/Applications"
	rm -rf "$$HOME/Applications/Open Whisper.app"
	cp -R "dist/Open Whisper.app" "$$HOME/Applications/"
	@echo "    Done. Right-click ~/Applications/Open\\ Whisper.app → Open the first time."

# --- Swift port -------------------------------------------------------------
#
# Added per swift_migration_plan.md §8. These wrap swift/Scripts/, which stay
# the source of truth. Nothing above this line is touched: the Python app's
# build and test path is unchanged, and `make test` still means the Python
# suite. `make test-all` runs both.

swift-test:
	./swift/Scripts/test.sh

swift-app:
	./swift/Scripts/build-app.sh

swift-run: swift-app
	open swift/build/OpenWhisperSwift.app

swift-xcodeproj:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install it with: brew install xcodegen" >&2; \
		exit 1; \
	}
	cd swift && xcodegen
	@echo "Generated swift/OpenWhisperSwift.xcodeproj (gitignored — regenerate, don't edit)."

test-all: test swift-test

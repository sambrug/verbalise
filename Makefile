# Open Whisper — convenience build targets.

.PHONY: help test app run install xcodeproj signing-cert

help:
	@echo "Open Whisper — make targets:"
	@echo ""
	@echo "  make test         Run the test suite"
	@echo "  make app          Build + sign build/OpenWhisperSwift.app"
	@echo "  make run          Build and launch it"
	@echo "  make install      Copy it to /Applications as the everyday app"
	@echo "  make xcodeproj    Generate OpenWhisperSwift.xcodeproj (needs xcodegen)"
	@echo "  make signing-cert Create the per-machine code-signing certificate (once)"
	@echo ""

test:
	./scripts/test.sh

app:
	./scripts/build-app.sh

run: app
	open build/OpenWhisperSwift.app

signing-cert:
	./scripts/create-signing-cert.sh

install: app
	@# TCC keys Input Monitoring and Accessibility to the bundle *path*, so
	@# an app moved from build/ to /Applications is a new app as far as
	@# macOS is concerned and both grants have to be given again.
	@echo "==> Installing to /Applications/Open Whisper.app ..."
	@rm -rf "/Applications/Open Whisper.app"
	@cp -R "build/OpenWhisperSwift.app" "/Applications/Open Whisper.app"
	@echo ""
	@echo "    Installed. Two things left, both of which need you:"
	@echo "      1. Open it, then grant Input Monitoring and Accessibility again."
	@echo "      2. Settings > General > Open at login, once it is working."

xcodeproj:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install it with: brew install xcodegen" >&2; \
		exit 1; \
	}
	xcodegen
	@echo "Generated OpenWhisperSwift.xcodeproj (gitignored — regenerate, don't edit)."

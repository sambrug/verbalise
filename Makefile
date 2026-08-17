# Verbalise — convenience build targets.

.PHONY: help test app run install xcodeproj signing-cert mas-build mas-archive

help:
	@echo "Verbalise — make targets:"
	@echo ""
	@echo "  make test         Run the test suite"
	@echo "  make app          Build + sign build/Verbalise.app"
	@echo "  make run          Build and launch it"
	@echo "  make install      Copy it to /Applications as the everyday app"
	@echo "  make xcodeproj    Generate Verbalise.xcodeproj (needs xcodegen)"
	@echo "  make signing-cert Create the per-machine code-signing certificate (once)"
	@echo "  make mas-build    Compile-check the App Store variant (fast, SwiftPM)"
	@echo "  make mas-archive  Xcode archive of the App Store variant for submission"
	@echo ""

test:
	./scripts/test.sh

app:
	./scripts/build-app.sh

run: app
	open build/Verbalise.app

signing-cert:
	./scripts/create-signing-cert.sh

install: app
	@# TCC keys Input Monitoring and Accessibility to the bundle *path*, so
	@# an app moved from build/ to /Applications is a new app as far as
	@# macOS is concerned and both grants have to be given again.
	@echo "==> Installing to /Applications/Verbalise.app ..."
	@rm -rf "/Applications/Verbalise.app"
	@cp -R "build/Verbalise.app" "/Applications/Verbalise.app"
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
	@echo "Generated Verbalise.xcodeproj (gitignored — regenerate, don't edit)."

# The store variant compiled the fast way: SwiftPM with the APPSTORE flag.
# Catches variant-only compile breaks without waiting for an Xcode build.
# It cannot produce a submittable app — that is mas-archive's job.
mas-build:
	swift build -Xswiftc -DAPPSTORE

# The submission path: an Xcode archive of the VerbaliseMAS target. Open the
# result in Xcode's Organizer (or drag it onto Xcode) to sign with the real
# distribution identity and upload to App Store Connect. Bump the version keys
# in Resources/Info-MAS.plist and project.yml before archiving.
mas-archive: xcodeproj
	xcodebuild -project Verbalise.xcodeproj -scheme VerbaliseMAS \
		-configuration Release \
		-archivePath build/Verbalise-MAS.xcarchive archive
	@echo ""
	@echo "Archive at build/Verbalise-MAS.xcarchive"
	@echo "Next: open it in Xcode's Organizer, then Distribute App > App Store Connect."

#!/bin/bash
#
# Run the Swift test suite.
#
# Swift Testing ships inside the Command Line Tools but sits outside the search
# path `swift test` uses by default, so a bare `swift test` fails with
# "no such module 'Testing'". Pointing the compiler and linker at the CLT
# Frameworks directory is all it takes. With a full Xcode install the directory
# is absent and the flags are skipped -- `swift test` finds Testing on its own.
#
# The cross-import overlay needs disabling as well. Testing.framework declares
# a Foundation overlay (Testing.swiftcrossimport/Foundation.swiftoverlay), so
# any file importing both Testing and Foundation makes the compiler demand
# module `_Testing_Foundation`. The CLT ships that framework's *binary* but not
# its .swiftmodule, so the import can never resolve and every such file fails
# to compile. Nothing in this suite uses the overlay's API -- it only adds
# Foundation conveniences on top of Testing -- so turning it off costs nothing.
#
# Both workarounds apply only when the Command Line Tools are the *active*
# toolchain. Xcode and the CLT coexist happily, so testing merely whether the
# CLT directory exists would keep forcing CLT frameworks onto an Xcode
# toolchain after `xcode-select -s` — mixing two toolchains' modules, which
# fails in more confusing ways than the problem being worked around. Ask
# xcode-select which one is actually in charge instead.
set -euo pipefail

cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
ACTIVE_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"

case "$ACTIVE_DEVELOPER_DIR" in
    */CommandLineTools*)
        if [ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
            echo "error: Swift Testing not found at $CLT_FRAMEWORKS" >&2
            echo "Install a newer Command Line Tools, or switch to Xcode with:" >&2
            echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
            exit 1
        fi
        exec swift test \
            -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
            -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
            -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" \
            -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
            "$@"
        ;;
    *)
        # Xcode is active: it ships a complete Swift Testing, overlay included.
        exec swift test "$@"
        ;;
esac

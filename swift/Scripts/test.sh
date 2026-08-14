#!/bin/bash
#
# Run the Swift test suite.
#
# Swift Testing ships inside the Command Line Tools but sits outside the search
# path `swift test` uses by default, so a bare `swift test` fails with
# "no such module 'Testing'". Pointing the compiler and linker at the CLT
# Frameworks directory is all it takes. With a full Xcode install the directory
# is absent and the flags are skipped -- `swift test` finds Testing on its own.
set -euo pipefail

cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

if [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
        -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
        "$@"
else
    exec swift test "$@"
fi

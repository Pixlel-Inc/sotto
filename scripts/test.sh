#!/bin/bash
# Runs the unit tests. With full Xcode, plain `swift test` works. With only the
# Command Line Tools, Swift Testing needs a few extra flags.
set -euo pipefail
cd "$(dirname "$0")/.."
if xcode-select -p | grep -q CommandLineTools; then
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
else
  swift test "$@"
fi

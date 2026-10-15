#!/bin/zsh
# Builds the engine with its tests, outside the app, and runs them.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/module-cache build/tests
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$PWD/build/module-cache" \
  native/Engine/*.swift tests/swift/*.swift -o build/tests/engine-tests
build/tests/engine-tests

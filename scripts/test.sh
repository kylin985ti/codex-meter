#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEST_DIR="$ROOT/build/tests"
mkdir -p "$TEST_DIR"

xcrun swiftc \
  -swift-version 5 \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/AppServerClient.swift" \
  "$ROOT/Sources/LocalTokenScanner.swift" \
  "$ROOT/Tests/LocalScannerTests.swift" \
  -o "$TEST_DIR/LocalScannerTests"

"$TEST_DIR/LocalScannerTests"

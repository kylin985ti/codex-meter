#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Codex Meter.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT"/Sources/*.swift \
  -o "$MACOS/CodexMeter"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
codesign --force --deep --sign - "$APP"
plutil -lint "$CONTENTS/Info.plist"

print -r -- "$APP"

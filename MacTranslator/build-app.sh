#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/dist/MacTranslator.app"
CONTENTS_DIR="$APP_DIR/Contents"
ARM_BUILD_DIR="$ROOT_DIR/.build-arm64"
INTEL_BUILD_DIR="$ROOT_DIR/.build-x86_64"

swift build \
  -c release \
  --package-path "$ROOT_DIR" \
  --scratch-path "$ARM_BUILD_DIR" \
  --triple arm64-apple-macosx14.0 \
  --product MacTranslator
swift build \
  -c release \
  --package-path "$ROOT_DIR" \
  --scratch-path "$INTEL_BUILD_DIR" \
  --triple x86_64-apple-macosx14.0 \
  --product MacTranslator

if [[ -d "$APP_DIR" ]]; then
  rm -R "$APP_DIR"
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
lipo -create \
  "$ARM_BUILD_DIR/arm64-apple-macosx/release/MacTranslator" \
  "$INTEL_BUILD_DIR/x86_64-apple-macosx/release/MacTranslator" \
  -output "$CONTENTS_DIR/MacOS/MacTranslator"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"

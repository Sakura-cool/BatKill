#!/bin/bash
# ────────────────────────────────────────────────────
# BatKill — Build Script
# Compiles the SwiftUI macOS app and bundles it as .app
# ────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="BatKill"
SRC_DIR="Sources"
RES_DIR="Resources"
BUILD_DIR=".build"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"

case "$ARCH" in
  arm64) TARGET="arm64-apple-macosx14.0" ;;
  *)     TARGET="x86_64-apple-macosx14.0" ;;
esac

echo "🚧 Building $APP_NAME for $ARCH …"

# ── Compile ──
mkdir -p "$BUILD_DIR"

SWIFT_FILES=$(find "$SRC_DIR" -name '*.swift' | sort)

swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET" \
  -parse-as-library \
  -O \
  -whole-module-optimization \
  -o "$BUILD_DIR/$APP_NAME" \
  $SWIFT_FILES \
  -framework SwiftUI \
  -framework AppKit \
  -framework IOKit \
  -framework UserNotifications \
  -framework ServiceManagement \
  -framework Combine

# ── Create .app bundle ──
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME"           "$APP_BUNDLE/Contents/MacOS/"
cp "$RES_DIR/Info.plist"            "$APP_BUNDLE/Contents/"

# Optional: copy icon if present
if [ -f "$RES_DIR/AppIcon.icns" ]; then
  cp "$RES_DIR/AppIcon.icns"        "$APP_BUNDLE/Contents/Resources/"
fi

echo ""
echo "✅ Done → $APP_BUNDLE"
echo "   Run:  open \"$APP_BUNDLE\""
echo "   Copy to Applications:  cp -R \"$APP_BUNDLE\" /Applications/"

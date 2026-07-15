#!/bin/bash
# ────────────────────────────────────────────────────
# BatKill — Build Script
# Compiles the SwiftUI macOS app and bundles it as .app
#
# Usage:
#   bash build.sh                  # Build for current architecture
#   bash build.sh --all            # Build for both arm64 + x86_64
#   bash build.sh --arch x86_64    # Cross-compile for specific arch
# ────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="BatKill"
SRC_DIR="Sources"
RES_DIR="Resources"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

# ── Parse arguments ──
BUILD_ALL=false
TARGET_ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) BUILD_ALL=true ;;
    --arch) TARGET_ARCH="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Determine architectures to build ──
NATIVE_ARCH="$(uname -m)"
if [ "$BUILD_ALL" = true ]; then
  ARCHES=("arm64" "x86_64")
elif [ -n "$TARGET_ARCH" ]; then
  ARCHES=("$TARGET_ARCH")
else
  ARCHES=("$NATIVE_ARCH")
fi

# ── Build function ──
build_arch() {
  local arch="$1"
  local target="${arch}-apple-macosx14.0"
  local build_dir=".build/${arch}"
  local app_bundle="${build_dir}/${APP_NAME}-${arch}.app"

  echo ""
  echo "🚧 Building ${APP_NAME} for ${arch} …"

  mkdir -p "$build_dir"

  SWIFT_FILES=$(find "$SRC_DIR" -name '*.swift' | sort)

  swiftc \
    -sdk "$SDK_PATH" \
    -target "$target" \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    -o "${build_dir}/${APP_NAME}" \
    $SWIFT_FILES \
    -framework SwiftUI \
    -framework AppKit \
    -framework IOKit \
    -framework UserNotifications \
    -framework ServiceManagement \
    -framework Combine

  # ── Create .app bundle ──
  rm -rf "$app_bundle"
  mkdir -p "${app_bundle}/Contents/MacOS"
  mkdir -p "${app_bundle}/Contents/Resources"

  cp "${build_dir}/${APP_NAME}"  "${app_bundle}/Contents/MacOS/"
  cp "${RES_DIR}/Info.plist"     "${app_bundle}/Contents/"

  if [ -f "${RES_DIR}/AppIcon.icns" ]; then
    cp "${RES_DIR}/AppIcon.icns" "${app_bundle}/Contents/Resources/"
  fi

  echo "  ✅ ${app_bundle}"
}

# ── Build all requested architectures ──
for arch in "${ARCHES[@]}"; do
  build_arch "$arch"
done

echo ""
echo "═══════════════════════════════════════════"
echo "  Done — built ${#ARCHES[@]} architecture(s)"
for arch in "${ARCHES[@]}"; do
  echo "  .build/${arch}/${APP_NAME}-${arch}.app"
done
echo "═══════════════════════════════════════════"
echo ""
echo "  Run:"
echo "    open \".build/${NATIVE_ARCH}/${APP_NAME}-${NATIVE_ARCH}.app\""
echo ""
echo "  Copy to Applications:"
echo "    cp -R \".build/${NATIVE_ARCH}/${APP_NAME}-${NATIVE_ARCH}.app\" /Applications/"
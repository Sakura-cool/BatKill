#!/bin/bash
# ────────────────────────────────────────────────────
# BatKill — Build Script
# Compiles the SwiftUI macOS app and bundles it as .app
#
# Usage:
#   bash build.sh                  # Build for both arm64 + x86_64
#   bash build.sh --arch x86_64    # Build for specific arch only
# ────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="BatKill"
SRC_DIR="Sources"
RES_DIR="Resources"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

# ── Parse arguments ──
BUILD_DMG=false
TARGET_ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) BUILD_DMG=true ;;
    --arch) TARGET_ARCH="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Determine architectures to build ──
NATIVE_ARCH="$(uname -m)"
if [ -n "$TARGET_ARCH" ]; then
  ARCHES=("$TARGET_ARCH")
else
  ARCHES=("arm64" "x86_64")
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

  EXTRA_FLAGS=""
  if [ "$arch" = "arm64" ]; then
    EXTRA_FLAGS="-Xfrontend -warn-long-function-bodies=1000 -Xfrontend -warn-long-expression-type-checking=1000"
  elif [ "$arch" = "x86_64" ]; then
    EXTRA_FLAGS="-Xllvm -x86-use-vzeroupper"
  fi

  swiftc \
    -sdk "$SDK_PATH" \
    -target "$target" \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    $EXTRA_FLAGS \
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
  chmod +x "${app_bundle}/Contents/MacOS/${APP_NAME}"
  cp "${RES_DIR}/Info.plist"     "${app_bundle}/Contents/"

  if [ -f "${RES_DIR}/AppIcon.icns" ]; then
    cp "${RES_DIR}/AppIcon.icns" "${app_bundle}/Contents/Resources/"
  fi

  # ── Ad-hoc code sign (required for SMAppService login item registration) ──
  codesign --force --deep --sign - "$app_bundle" 2>/dev/null

  echo "  ✅ ${app_bundle}"
}

# ── Build all requested architectures ──
for arch in "${ARCHES[@]}"; do
  build_arch "$arch"
done

# ── Package DMG for distribution ──
package_dmg() {
  local arch="$1"
  local app_bundle=".build/${arch}/${APP_NAME}-${arch}.app"
  local package_dir="${PACKAGE_DIR}/${arch}"
  local dmg_path="${package_dir}/${APP_NAME}-${arch}.dmg"
  local stage_dir="${PACKAGE_DIR}/dmg-staging-${arch}"

  if [ ! -d "$app_bundle" ]; then
    echo "  ⚠️  ${app_bundle} not found, skipping DMG"
    return
  fi

  echo ""
  echo "💿 Creating ${APP_NAME}-${arch}.dmg …"

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  mkdir -p "$package_dir"

  ditto "$app_bundle" "${stage_dir}/${APP_NAME}.app"
  ln -s /Applications "$stage_dir/Applications"

  rm -f "$dmg_path"
  hdiutil create \
    -fs HFS+ \
    -srcfolder "$stage_dir" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "${APP_NAME}" \
    "$dmg_path" > /dev/null

  rm -rf "$stage_dir"
  echo "  ✅ ${dmg_path}"

  # ── Also create .app.zip from the same build ──
  local zip_path="${package_dir}/${APP_NAME}-${arch}.app.zip"
  echo "  📦 Creating ${APP_NAME}-${arch}.app.zip …"
  rm -f "$zip_path"
  ditto -c -k --keepParent "$app_bundle" "$zip_path"
  echo "  ✅ ${zip_path}"
}

# ── Package DMG (only in --dmg mode) ──
if [ "$BUILD_DMG" = true ]; then
  PACKAGE_DIR=".package"
  # Clean package directory before packing
  rm -rf "$PACKAGE_DIR"
  for arch in "${ARCHES[@]}"; do
    package_dmg "$arch"
  done
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Done — built ${#ARCHES[@]} architecture(s)"
for arch in "${ARCHES[@]}"; do
  echo "  .build/${arch}/${APP_NAME}-${arch}.app"
  if [ "$BUILD_DMG" = true ]; then
    echo "  💿 .package/${arch}/${APP_NAME}-${arch}.dmg"
    echo "  📦 .package/${arch}/${APP_NAME}-${arch}.app.zip"
  fi
done
echo "═══════════════════════════════════════════"
echo ""
echo "  Run:"
echo "    open \".build/${NATIVE_ARCH}/${APP_NAME}-${NATIVE_ARCH}.app\""
echo ""
echo "  Copy to Applications:"
echo "    cp -R \".build/${NATIVE_ARCH}/${APP_NAME}-${NATIVE_ARCH}.app\" /Applications/"
if [ "$BUILD_DMG" = true ]; then
  echo ""
  echo "  Release DMG:"
  echo "    .package/${NATIVE_ARCH}/${APP_NAME}-${NATIVE_ARCH}.dmg"
fi
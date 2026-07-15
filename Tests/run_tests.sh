#!/bin/bash
# ────────────────────────────────────────────────────
# BatKill — Test Runner
# Compiles and runs unit tests for the BatKill project
# ────────────────────────────────────────────────────
set -euo pipefail

TEST_NAME="BatKillTests"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$TEST_DIR/../Sources"
BUILD_DIR="$TEST_DIR/.build"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"

case "$ARCH" in
  arm64) TARGET="arm64-apple-macosx14.0" ;;
  *)     TARGET="x86_64-apple-macosx14.0" ;;
esac

echo "🧪 Building BatKill Tests for $ARCH …"
echo ""

# ── Collect source files ──
# Main source files (needed for the types we're testing)
# Exclude entry-point files (entry point is TestMain.swift)
MAIN_SOURCES=$(find "$SRC_DIR" -name '*.swift' \
  | grep -v 'BatKillApp.swift' \
  | grep -v 'AppDelegate.swift' \
  | grep -v 'Main.swift' \
  | grep -v 'main.swift' \
  | sort)

# Test source files
TEST_SOURCES=$(find "$TEST_DIR/Sources" -name '*.swift' | sort)

# ── Compile ──
mkdir -p "$BUILD_DIR"

echo "📝 Compiling test sources..."
echo "   Main sources: $(echo "$MAIN_SOURCES" | wc -l | tr -d ' ') files"
echo "   Test sources: $(echo "$TEST_SOURCES" | wc -l | tr -d ' ') files"
echo ""

swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET" \
  -parse-as-library \
  -o "$BUILD_DIR/$TEST_NAME" \
  $MAIN_SOURCES \
  $TEST_SOURCES \
  -framework SwiftUI \
  -framework AppKit \
  -framework IOKit \
  -framework UserNotifications \
  -framework ServiceManagement \
  -framework Combine

# ── Run tests ──
echo ""
echo "🚀 Running tests..."
echo "───────────────────────────────────────────────────────"

"$BUILD_DIR/$TEST_NAME"

# ── Capture exit code ──
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
  echo "✅ All tests completed successfully!"
else
  echo "❌ Some tests failed (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE

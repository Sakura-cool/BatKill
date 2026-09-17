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

# ── SwiftLint 门禁（见 versions/v0.1.0/CHANGES.md CHANGE-002）──
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
if command -v swiftlint >/dev/null 2>&1; then
  echo "🔍 SwiftLint 检查中（--strict）…"
  if ! (cd "$PROJECT_ROOT" && swiftlint lint --strict --quiet --config .swiftlint.yml); then
    echo "❌ SwiftLint 未通过，测试中止。本地可先跑：swiftlint lint --fix"
    exit 1
  fi
  echo "✅ SwiftLint 通过"
  echo ""
else
  echo "⚠️  未检测到 swiftlint，跳过代码扫描（安装：brew install swiftlint）"
  echo ""
fi

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

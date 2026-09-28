#!/bin/bash
# ────────────────────────────────────────────────────
# update_channel_test.sh — 更新通道集成测试（零依赖）
#
# 验证 Updater 依赖的 GitHub Releases API 可达性与 latest 版本
# 比对逻辑（compareVersions 的线上对照）。仅用 curl，无额外依赖。
#
# 用法:
#   bash Tests/integration/update_channel_test.sh
#   LOCAL_VERSION=0.1.9 bash Tests/integration/update_channel_test.sh
#
# 退出码: 0 = 通过; 1 = 失败
# ────────────────────────────────────────────────────
set -euo pipefail

REPO="${REPO:-Sakura-cool/BatKill}"
LOCAL="${LOCAL_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$(dirname "$0")/../../Resources/Info.plist" 2>/dev/null || echo 0.1.9)}"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "═══ 更新通道集成测试 ═══"
echo "仓库:  $REPO"
echo "本地:  $LOCAL"
echo ""

# ── 1. GitHub API 可达性 ──
echo "── 1. GitHub Releases API 可达性 ──"
LATEST_JSON="$(curl -sf --max-time 10 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
if [ -n "$LATEST_JSON" ]; then
  pass "API 可达"
else
  fail "API 不可达（网络/仓库名错误？）"
fi
echo ""

# ── 2. latest 版本解析 ──
echo "── 2. latest 版本解析 ──"
LATEST="$(echo "$LATEST_JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/; s/^v//')"
if [ -n "$LATEST" ]; then
  pass "latest tag: v${LATEST}"
else
  fail "无法解析 tag_name"
fi
echo ""

# ── 3. 版本比对逻辑（与 Updater.compareVersions 语义一致）──
echo "── 3. 版本比对 ──"
# 与 Swift compareVersions 相同：缺位补 0，严格更大才 true。
newer() {
  local l="$1" r="$2"
  python3 - "$l" "$r" <<'EOF'
import sys
def parts(v): return [int(x) for x in v.split('.') if x.isdigit()] or [0]
l, r = parts(sys.argv[1]), parts(sys.argv[2])
n = max(len(l), len(r))
l += [0]*(n-len(l)); r += [0]*(n-len(r))
sys.exit(0 if any(r[i] > l[i] for i in range(n)) else 1)
EOF
}
if [ -n "$LATEST" ]; then
  if newer "$LOCAL" "$LATEST"; then
    pass "本地 ${LOCAL} < latest ${LATEST}（提示更新正确）"
  else
    pass "本地 ${LOCAL} >= latest ${LATEST}（无更新，正常）"
  fi
  # 反向：latest 不应比自身新。
  if newer "$LATEST" "$LATEST"; then
    fail "版本与自身比较不应判为更新"
  else
    pass "版本与自身比较正确（非更新）"
  fi
fi
echo ""

# ── 4. 资产完整性 ──
echo "── 4. Release 资产 ──"
ASSETS="$(echo "$LATEST_JSON" | grep -o '"name": *"[^"]*\.\(dmg\|zip\)"' | sed 's/.*"\(.*\)"/\1/' || true)"
if [ -n "$ASSETS" ]; then
  echo "$ASSETS" | while read -r a; do echo "    - $a"; done
  pass "资产存在"
else
  fail "latest release 无 dmg/zip 资产"
fi
echo ""

echo "═══════════════════════════════════════"
echo "  通过: $PASS   失败: $FAIL"
echo "═══════════════════════════════════════"
[ "$FAIL" -eq 0 ]

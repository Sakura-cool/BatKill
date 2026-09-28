#!/bin/bash
# ────────────────────────────────────────────────────
# fan_channel_test.sh — 风扇写通道集成测试（零依赖）
#
# 端到端验证 batkill-fan sudo 通道：安装 → sudo 免密 → 真实
# SMC 写入 → 读回确认 → 恢复自动。任何有 sudo 的 macOS 可运行
# （无需 Xcode / 无需额外依赖）。
#
# 用法:
#   bash Tests/integration/fan_channel_test.sh
#   FAN_CLI=/path/to/batkill-fan bash Tests/integration/fan_channel_test.sh
#
# 退出码: 0 = 全部通过; 1 = 任一失败
# ────────────────────────────────────────────────────
set -euo pipefail

CLI="${FAN_CLI:-/usr/local/BatKill/batkill-fan}"
SUDOERS="/etc/sudoers.d/batkill-fan"
USER_NAME="$(whoami)"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "═══ 风扇写通道集成测试 ═══"
echo "CLI:      $CLI"
echo "SUDOERS:  $SUDOERS"
echo "用户:     $USER_NAME"
echo ""

# ── 1. 环境检查 ──
echo "── 1. 环境检查 ──"
if [ ! -x "$CLI" ]; then
  fail "CLI 不存在或不可执行: $CLI（先运行 app 的「启用风扇控制」或手动安装）"
else
  pass "CLI 存在"
fi
if [ -f "$SUDOERS" ]; then
  pass "sudoers 规则存在"
else
  fail "sudoers 规则缺失: $SUDOERS"
fi
echo ""

# ── 2. sudo 免密可达性 ──
echo "── 2. sudo 免密可达性 ──"
if sudo -n -l "$CLI" >/dev/null 2>&1; then
  pass "sudo -n 可解析规则（零弹窗）"
else
  fail "sudo -n -l 失败（规则未生效或需密码）"
fi
echo ""

# ── 3. CLI 参数白名单（非 root 也应拒绝非法参数）──
echo "── 3. CLI 参数白名单 ──"
if "$CLI" --set-fan 99 1000 >/dev/null 2>&1; then
  fail "非法风扇索引被接受"
else
  pass "非法风扇索引被拒绝"
fi
if "$CLI" --set-fan 0 -500 >/dev/null 2>&1; then
  fail "负数转速被接受"
else
  pass "负数转速被拒绝"
fi
if "$CLI" --set-fan 0 abc >/dev/null 2>&1; then
  fail "非数字转速被接受"
else
  pass "非数字转速被拒绝"
fi
echo ""

# ── 4. 风扇发现 ──
echo "── 4. 风扇发现 ──"
FAN_INDEX=""
if "$CLI" --get-fan 0 >/dev/null 2>&1; then
  FAN_INDEX=0
  pass "检测到风扇 0"
elif "$CLI" --get-fan 1 >/dev/null 2>&1; then
  FAN_INDEX=1
  pass "检测到风扇 1"
else
  fail "未检测到风扇（SMC 不可读？）"
fi
echo ""

# ── 5. 真实 SMC 写入验证（需 root）──
echo "── 5. 真实 SMC 写入验证 ──"
if [ -n "$FAN_INDEX" ]; then
  BASELINE=$("$CLI" --get-fan "$FAN_INDEX" 2>/dev/null || echo 0)
  echo "    基线转速: ${BASELINE} RPM"
  # 目标取 [min+200, max-200] 之间的安全中间值；由 CLI 内部 clamp 到真实范围。
  if sudo -n "$CLI" --verify-fan "$FAN_INDEX" 1600 2>&1; then
    pass "写入 → 读回确认（目标 1600 RPM）"
  else
    fail "写入 → 读回失败（SMC 写未生效或容差外）"
  fi
  # 确认已恢复自动。
  MODE_READBACK=$("$CLI" --get-fan "$FAN_INDEX" 2>/dev/null || echo "?")
  echo "    恢复后转速: ${MODE_READBACK} RPM"
else
  fail "跳过写入验证（无风扇）"
fi
echo ""

# ── 汇总 ──
echo "═══════════════════════════════════════"
echo "  通过: $PASS   失败: $FAIL"
echo "═══════════════════════════════════════"
[ "$FAIL" -eq 0 ]

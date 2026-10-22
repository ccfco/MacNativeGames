#!/bin/bash
# Translate the shader variants an iPhone/iPad missed and push them back to it.
#
# The device records a request under Documents/shader-requests/ for every variant it lacked; this script pulls them,
# translates them on this Mac (totk_xlate + SPIRV-Cross), compiles iOS metallibs, and pushes one pack to
# Documents/shader-fill/. The game merges and warms the pack on its next start.
#
# Environment:
#   TOTK_TREE       prepared work tree (build/spirv-cross, prebuilt/macos-arm64/totk_xlate)
#   TOTK_IOS_DEVICE devicectl UDID of the device
#   TOTK_BUNDLE_ID  bundle id of the installed app
# Extra arguments go to fill_shaders.py (--no-push, --with-done, --requests ...).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
TOOL="$REPO/games/totk/ios/tools/fill_shaders.py"
TREE="${TOTK_TREE:?set TOTK_TREE to the prepared work tree}"
DEVICE="${TOTK_IOS_DEVICE:?set TOTK_IOS_DEVICE to the device UDID}"
BUNDLE="${TOTK_BUNDLE_ID:?set TOTK_BUNDLE_ID to the app bundle id}"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

step "1/4 检查环境"
[ -x "$TREE/build/spirv-cross/spirv-cross" ] || fail "缺少 $TREE/build/spirv-cross/spirv-cross；先构建一次"
[ -f "$TOOL" ] || fail "缺少 $TOOL"
command -v xcrun >/dev/null || fail "找不到 xcrun；请安装完整 Xcode"
command -v python3 >/dev/null || fail "找不到 python3"
printf '  仓库:   %s\n  工作树: %s\n' "$REPO" "$TREE"

step "2/4 检查 iPad"
if ! xcrun devicectl list devices 2>/dev/null | awk -v id="$DEVICE" '$0 ~ id && $0 !~ /unavailable/ { found = 1 } END { exit !found }'; then
    fail "iPad 未连接或不可用：$DEVICE"
fi
APPS=""
for attempt in 1 2 3; do
    if APPS="$(xcrun devicectl device info apps --device "$DEVICE" 2>&1)"; then break; fi
    [ "$attempt" -eq 3 ] && fail "无法读取 iPad 的 App 列表；请解锁 iPad、保持连接后重试"
    sleep 1
done
[ -n "$APPS" ] || fail "iPad 返回了空的 App 列表；请解锁 iPad 后重试"
if ! printf '%s\n' "$APPS" | grep -q "$BUNDLE"; then
    fail "iPad 上没有安装 $BUNDLE"
fi
printf '  设备在线，App 已安装\n  如果接下来的读取失败，请解锁 iPad 后重试\n'

step "3/4 拉取请求、翻译、编译并推送"
LOG="$(mktemp -t totk-fill)"
trap 'rm -f "$LOG"' EXIT
if ! python3 "$TOOL" --tree "$TREE" --device "$DEVICE" --bundle-id "$BUNDLE" "$@" 2>&1 | tee "$LOG"; then
    printf '\n补译没有完成。请确认 iPad 已解锁并保持连接，然后重试。\n' >&2
    exit 1
fi

step "4/4 完成"
if grep -q "no shader requests" "$LOG"; then
    printf '  iPad 上还没有新的缺失着色器请求；继续玩即可，以后再运行这个脚本。\n'
else
    printf '  请在 iPad 上完全退出游戏，再重新打开；启动时会合并并预热新的着色器。\n'
fi

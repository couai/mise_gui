#!/usr/bin/env bash
# 构建 macOS debug 版本应用，并打包成拖拽安装用的 DMG。
#
# 用法：
#   bash scripts/package_macos_debug_dmg.sh
#
# 参数说明：
#   这个脚本不接收位置参数。
#   这个脚本也不依赖自定义环境变量。
#
# 输出产物：
#   dist/macos/DevWorkbench-macOS-debug-drag-install-YYYY-MM-DD.dmg
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macos_package_common.sh"

FINAL_DMG="$DIST_DIR/${APP_NAME}-macOS-debug-drag-install-${DATE_STAMP}.dmg"
TMP_DIR="$(mktemp -d /tmp/mise-gui-dmg-debug.XXXXXX)"
STAGE_DIR="$TMP_DIR/stage"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 1
fi

ensure_dist_dir
mkdir -p "$STAGE_DIR"
rm -f "$FINAL_DMG"

generate_background
build_macos_debug
copy_debug_app_to_dir "$STAGE_DIR"

create-dmg \
  --volname "$APP_NAME Debug" \
  --volicon "$VOLUME_ICON_PATH" \
  --background "$BACKGROUND_PATH" \
  --window-pos 120 120 \
  --window-size 920 540 \
  --icon-size 128 \
  --text-size 15 \
  --icon "$APP_NAME.app" 190 300 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 700 300 \
  --format UDZO \
  --hdiutil-quiet \
  --hdiutil-retries 10 \
  "$FINAL_DMG" \
  "$STAGE_DIR"

echo "$FINAL_DMG"

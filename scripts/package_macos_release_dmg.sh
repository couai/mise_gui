#!/usr/bin/env bash
# 构建 macOS release 版应用，打包成拖拽安装用的 DMG，
# 并可选择是否对最终 DMG 做公证和 staple。
#
# 用法：
#   bash scripts/package_macos_release_dmg.sh
#   SKIP_NOTARIZATION=1 bash scripts/package_macos_release_dmg.sh
#   SIGNING_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#     NOTARY_PROFILE="your-notary-profile" \
#     bash scripts/package_macos_release_dmg.sh
#
# 参数说明：
#   不接收位置参数。
#
# 可用环境变量：
#   SKIP_NOTARIZATION
#     可选。传 `1` 时跳过 DMG 的公证和 staple；
#     其他值都会执行完整发布流程。默认值：0。
#   SIGNING_IDENTITY
#     可选。覆盖应用签名和 DMG 签名使用的 Developer ID Application 证书。
#     默认值：自动选择第一个可用证书。
#   NOTARY_PROFILE
#     可选。覆盖 `xcrun notarytool` 使用的钥匙串 profile 名称。
#     默认值：mise-gui-notary。
#
# 输出产物：
#   dist/macos/DevWorkbench-macOS-drag-install-YYYY-MM-DD.dmg
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macos_package_common.sh"

FINAL_DMG="$DIST_DIR/${APP_NAME}-macOS-drag-install-${DATE_STAMP}.dmg"
TMP_DIR="$(mktemp -d /tmp/mise-gui-dmg.XXXXXX)"
STAGE_DIR="$TMP_DIR/stage"
APP_PATH="$STAGE_DIR/$APP_NAME.app"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 1
fi

ensure_dist_dir
ensure_signing_identity
mkdir -p "$STAGE_DIR"
rm -f "$FINAL_DMG"

generate_background
build_macos_release

copy_release_app_to_dir "$STAGE_DIR"

sign_app "$APP_PATH"

create-dmg \
  --volname "$APP_NAME" \
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
  --codesign "$SIGNING_IDENTITY" \
  "$FINAL_DMG" \
  "$STAGE_DIR"

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  notarize_and_staple "$FINAL_DMG"
fi

echo "$FINAL_DMG"

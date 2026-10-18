#!/usr/bin/env bash
# 构建 macOS release 版 `.app`，完成签名、公证、staple 后，
# 把最终可分发的应用输出到 `dist/macos/`。
#
# 用法：
#   bash scripts/package_macos_release_app.sh
#   SKIP_NOTARIZATION=1 bash scripts/package_macos_release_app.sh
#   SIGNING_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#     NOTARY_PROFILE="your-notary-profile" \
#     bash scripts/package_macos_release_app.sh
#
# 参数说明：
#   不接收位置参数。
#
# 可用环境变量：
#   SKIP_NOTARIZATION
#     可选。传 `1` 时跳过公证和 staple；
#     其他值都会执行完整发布流程。默认值：0。
#   SIGNING_IDENTITY
#     可选。覆盖 codesign 使用的 Developer ID Application 证书。
#     默认值：自动选择第一个可用证书。
#   NOTARY_PROFILE
#     可选。覆盖 `xcrun notarytool` 使用的钥匙串 profile 名称。
#     默认值：mise-gui-notary。
#
# 输出产物：
#   dist/macos/DevWorkbench.app
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macos_package_common.sh"

FINAL_APP_DIR="$DIST_DIR/${APP_NAME}.app"
EXTERNAL_OUTPUT_DIR="/Users/likai/Documents/DevWorkbench Build"
EXTERNAL_APP_DIR="$EXTERNAL_OUTPUT_DIR/${APP_NAME}.app"
TMP_DIR="$(mktemp -d /tmp/mise-gui-app-release.XXXXXX)"
STAGE_DIR="$TMP_DIR/stage"
APP_PATH="$STAGE_DIR/$APP_NAME.app"
NOTARIZE_ZIP="$TMP_DIR/notarize/${APP_NAME}.zip"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ensure_dist_dir
ensure_signing_identity
mkdir -p "$STAGE_DIR"
mkdir -p "$(dirname "$NOTARIZE_ZIP")"
rm -rf "$FINAL_APP_DIR"

build_macos_release
copy_release_app_to_dir "$STAGE_DIR"
sign_app "$APP_PATH"

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  zip_app "$APP_PATH" "$NOTARIZE_ZIP"
  submit_for_notarization "$NOTARIZE_ZIP"
  staple_path "$APP_PATH"
fi

cp -R "$APP_PATH" "$FINAL_APP_DIR"

mkdir -p "$EXTERNAL_OUTPUT_DIR"
rm -rf "$EXTERNAL_APP_DIR"
cp -R "$APP_PATH" "$EXTERNAL_APP_DIR"

echo "$FINAL_APP_DIR"

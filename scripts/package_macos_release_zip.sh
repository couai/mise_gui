#!/usr/bin/env bash
# 构建 macOS release 版应用，并打包成可分发的 ZIP。
# 默认流程会先把 ZIP 提交公证，再对解压后的 `.app` 做 staple，
# 最后重新打成最终 ZIP。
#
# 用法：
#   bash scripts/package_macos_release_zip.sh
#   SKIP_NOTARIZATION=1 bash scripts/package_macos_release_zip.sh
#   SIGNING_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#     NOTARY_PROFILE="your-notary-profile" \
#     bash scripts/package_macos_release_zip.sh
#
# 参数说明：
#   不接收位置参数。
#
# 可用环境变量：
#   SKIP_NOTARIZATION
#     可选。传 `1` 时跳过公证和 staple；
#     其他值都会执行完整发布流程。默认值：0。
#   SKIP_CODESIGN
#     可选。传 `1` 时跳过 codesign、公证和 staple，适合 CI 里生成未签名测试包。
#     默认值：0。
#   SIGNING_IDENTITY
#     可选。覆盖应用签名使用的 Developer ID Application 证书。
#     默认值：自动选择第一个可用证书。
#   NOTARY_PROFILE
#     可选。覆盖 `xcrun notarytool` 使用的钥匙串 profile 名称。
#     默认值：mise-gui-notary。
#
# 输出产物：
#   dist/macos/DevWorkbench-macOS-release-YYYY-MM-DD.zip
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macos_package_common.sh"

FINAL_ZIP="$DIST_DIR/${APP_NAME}-macOS-release-${DATE_STAMP}.zip"
TMP_DIR="$(mktemp -d /tmp/mise-gui-zip-release.XXXXXX)"
STAGE_DIR="$TMP_DIR/stage"
APP_PATH="$STAGE_DIR/$APP_NAME.app"
NOTARIZE_ZIP="$TMP_DIR/notarize/${APP_NAME}.zip"
EXTRACT_DIR="$TMP_DIR/extracted"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
SKIP_CODESIGN="${SKIP_CODESIGN:-0}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ensure_dist_dir
if [[ "$SKIP_CODESIGN" != "1" ]]; then
  ensure_signing_identity
fi
mkdir -p "$STAGE_DIR"
mkdir -p "$(dirname "$NOTARIZE_ZIP")" "$EXTRACT_DIR"
rm -f "$FINAL_ZIP"

build_macos_release
copy_release_app_to_dir "$STAGE_DIR"
if [[ "$SKIP_CODESIGN" != "1" ]]; then
  sign_app "$APP_PATH"
fi

if [[ "$SKIP_CODESIGN" != "1" && "$SKIP_NOTARIZATION" != "1" ]]; then
  zip_app "$APP_PATH" "$NOTARIZE_ZIP"
  submit_for_notarization "$NOTARIZE_ZIP"

  ditto -x -k "$NOTARIZE_ZIP" "$EXTRACT_DIR"
  staple_path "$EXTRACT_DIR/$APP_NAME.app"
  APP_PATH="$EXTRACT_DIR/$APP_NAME.app"
fi

zip_app "$APP_PATH" "$FINAL_ZIP"

echo "$FINAL_ZIP"

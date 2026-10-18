#!/usr/bin/env bash
# macOS 打包脚本共用函数。
# 这个文件会被其他脚本 source 引入，不是给你单独直接执行的。
#
# 可用环境变量：
#   SIGNING_IDENTITY
#     可选。覆盖默认使用的 Developer ID Application 证书，
#     会用于 codesign 和 create-dmg。默认值：自动选择第一个可用证书。
#   NOTARY_PROFILE
#     可选。覆盖 `xcrun notarytool` 使用的钥匙串 profile 名称。
#     默认值：mise-gui-notary。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DevWorkbench"
DATE_STAMP="$(date +%F)"
DIST_DIR="$ROOT_DIR/dist/macos"
PACKAGING_DIR="$ROOT_DIR/packaging/macos"
BACKGROUND_PATH="$PACKAGING_DIR/dmg-background.png"
VOLUME_ICON_PATH="$PACKAGING_DIR/volume-icon.icns"
NOTARY_PROFILE="${NOTARY_PROFILE:-mise-gui-notary}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

ensure_dist_dir() {
  mkdir -p "$DIST_DIR" "$PACKAGING_DIR"
}

ensure_signing_identity() {
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ {print $2; exit}')"
  fi

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Developer ID Application signing identity found." >&2
    exit 1
  fi
}

generate_background() {
  python3 "$ROOT_DIR/scripts/generate_macos_dmg_background.py" >/dev/null
}

build_macos_release() {
  if [[ "${USE_MISE:-1}" != "0" ]] && command -v mise >/dev/null 2>&1; then
    mise exec -- flutter build macos --release
  else
    flutter build macos --release
  fi
}

build_macos_debug() {
  if [[ "${USE_MISE:-1}" != "0" ]] && command -v mise >/dev/null 2>&1; then
    mise exec -- flutter build macos --debug
  else
    flutter build macos --debug
  fi
}

copy_release_app_to_dir() {
  local target_dir="$1"
  cp -R "$ROOT_DIR/build/macos/Build/Products/Release/$APP_NAME.app" "$target_dir/"
}

copy_debug_app_to_dir() {
  local target_dir="$1"
  cp -R "$ROOT_DIR/build/macos/Build/Products/Debug/$APP_NAME.app" "$target_dir/"
}

zip_app() {
  local app_path="$1"
  local zip_path="$2"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
}

sign_app() {
  local app_path="$1"
  ensure_signing_identity
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$app_path"

  codesign --verify --deep --strict --verbose=2 "$app_path"
}

submit_for_notarization() {
  local target_path="$1"
  xcrun notarytool submit "$target_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
}

staple_path() {
  local target_path="$1"
  xcrun stapler staple "$target_path"
  xcrun stapler validate "$target_path"
}

notarize_and_staple() {
  local target_path="$1"
  submit_for_notarization "$target_path"
  staple_path "$target_path"
}

#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
mise exec -- flutter build macos --release

app_path="$project_dir/build/macos/Build/Products/Release/Mise GUI.app"
# Incremental Flutter builds can replace App.framework after its prior signature.
# Refresh the embedded framework first, then seal the local development app.
codesign --force --sign - "$app_path/Contents/Frameworks/App.framework"
codesign --force --sign - --entitlements "$project_dir/macos/Runner/Release.entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"

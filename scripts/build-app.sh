#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/dist/Cadenza.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Cadenza" "$app_path/Contents/MacOS/Cadenza"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/Cadenza.entitlements "$app_path"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$app_path" "$app_path"

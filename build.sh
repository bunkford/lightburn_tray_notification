#!/usr/bin/env bash
# build.sh — compile and package LightBurn Monitor as a macOS .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/LightBurnMonitor.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

echo "==> Compiling..."
cd "$SCRIPT_DIR"
nim c -d:ssl -d:release lightburn_tray_mac.nim

echo "==> Packaging $APP ..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp lightburn_tray_mac    "$MACOS/"
cp Info.plist            "$APP/Contents/"
[ -f complete.wav ] && cp complete.wav "$RESOURCES/"
[ -f lightburn_tray.json ] && cp lightburn_tray.json "$RESOURCES/"

echo "==> Done. Run with:"
echo "    open $APP"
echo "  or:"
echo "    '$MACOS/lightburn_tray_mac'"

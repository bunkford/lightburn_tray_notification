#!/usr/bin/env bash
# build.sh — compile and package LightBurn Monitor as a macOS .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/LightBurnMonitor.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

echo "==> Compiling..."
cd "$SCRIPT_DIR"

# macOS does not ship a usable OpenSSL for third-party use.
# Detect a Homebrew installation so SMTP/TLS works at runtime.
OPENSSL_DIR=""
if command -v brew &>/dev/null; then
  OPENSSL_DIR=$(brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null || true)
fi

if [ -n "$OPENSSL_DIR" ] && [ -d "$OPENSSL_DIR/lib" ]; then
  echo "  OpenSSL: $OPENSSL_DIR"
  nim c -d:ssl -d:release \
    --passL:"-L$OPENSSL_DIR/lib" \
    --passL:"-Wl,-rpath,$OPENSSL_DIR/lib" \
    lightburn_tray_mac.nim
else
  echo "  Warning: Homebrew OpenSSL not found — SMTP/TLS may fail at runtime."
  echo "           Fix: brew install openssl"
  nim c -d:ssl -d:release lightburn_tray_mac.nim
fi

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

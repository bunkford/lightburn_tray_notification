#!/usr/bin/env bash
# build.sh — compile and package LightBurn Monitor as a macOS .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/LightBurnMonitor.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

# ── Minimum deployment target ─────────────────────────────────────────────────
# UNNotificationPresentationOptionList (used for reliable notification delivery
# in always-foreground menu-bar apps) requires macOS 12.  Pinning the target
# here prevents "This app can't be opened on your version of macOS" errors when
# the build host (e.g. GitHub Actions) runs a newer OS than the end user.
export MACOSX_DEPLOYMENT_TARGET="12.0"
MIN_VER_FLAGS="--passC:-mmacosx-version-min=12.0 --passL:-mmacosx-version-min=12.0"

# ── App icon ──────────────────────────────────────────────────────────────────
echo "==> Generating app icon..."
python3 "$SCRIPT_DIR/make_icon.py"

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
  nim c -d:ssl -d:release --mm:orc $MIN_VER_FLAGS \
    --passL:"-L$OPENSSL_DIR/lib" \
    --passL:"-Wl,-rpath,$OPENSSL_DIR/lib" \
    lightburn_tray_mac.nim
else
  echo "  Warning: Homebrew OpenSSL not found — SMTP/TLS may fail at runtime."
  echo "           Fix: brew install openssl"
  nim c -d:ssl -d:release --mm:orc $MIN_VER_FLAGS lightburn_tray_mac.nim
fi

echo "==> Packaging $APP ..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp lightburn_tray_mac    "$MACOS/"
cp Info.plist            "$APP/Contents/"
[ -f AppIcon.icns ]        && cp AppIcon.icns        "$RESOURCES/"
[ -f complete.wav ]        && cp complete.wav         "$RESOURCES/"
[ -f lightburn_tray.json ] && cp lightburn_tray.json "$RESOURCES/"

# ── Ad-hoc code sign ──────────────────────────────────────────────────────────
# macOS Sequoia silently rejects UNUserNotificationCenter requests from unsigned
# apps even when the user has granted permission in System Settings.
# Ad-hoc signing (-s -) satisfies the OS without requiring an Apple Developer account.
echo "==> Signing (ad-hoc)..."
codesign --sign - --force --deep --preserve-metadata=entitlements "$APP"

echo "==> Done. Run with:"
echo "    open $APP"
echo "  or:"
echo "    '$MACOS/lightburn_tray_mac'"

# ── DMG packaging ─────────────────────────────────────────────────────────────
echo "==> Building DMG..."

VERSION=$(grep '^version' "$SCRIPT_DIR/lightburn_tray_notification.nimble" \
          | head -1 | sed 's/.*"\(.*\)".*/\1/')
DMG_NAME="LightBurnMonitor-${VERSION}.dmg"
DMG_TITLE="LightBurnMonitor"
STAGING="$SCRIPT_DIR/_dmg_staging"
TEMP_DMG="$SCRIPT_DIR/_temp.dmg"
FINAL_DMG="$SCRIPT_DIR/$DMG_NAME"

# Generate background image
python3 "$SCRIPT_DIR/make_dmg_bg.py"

# Build staging area
rm -rf "$STAGING"
mkdir -p "$STAGING/.background"
cp -r "$APP" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"
cp "$SCRIPT_DIR/dmg_background.png" "$STAGING/.background/bg.png"

# Copy volume icon (.VolumeIcon.icns must be at root of staging)
[ -f "$SCRIPT_DIR/AppIcon.icns" ] && cp "$SCRIPT_DIR/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

# Create a temporary read-write DMG large enough to hold the app
rm -f "$TEMP_DMG"
hdiutil create \
  -volname "$DMG_TITLE" \
  -srcfolder "$STAGING" \
  -ov -format UDRW \
  -size 80m \
  "$TEMP_DMG" >/dev/null

# Mount the writable image (suppress automount dialog)
MOUNT_OUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
DEVICE=$(echo "$MOUNT_OUT" | awk 'END{print $1}')
MOUNT_PT="/Volumes/$DMG_TITLE"

# Wait a moment for Finder to register the volume
sleep 1

# Customise the Finder window via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$DMG_TITLE"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 500}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set background picture of theViewOptions to file ".background:bg.png"
    -- Position the app icon on the left, Applications alias on the right
    set position of item "LightBurnMonitor.app" of container window to {140, 185}
    set position of item "Applications"         of container window to {400, 185}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# Mark the volume icon
SetFile -a C "$MOUNT_PT" 2>/dev/null || true

# Unmount
hdiutil detach "$DEVICE" -quiet

# Convert to compressed read-only DMG
rm -f "$FINAL_DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 \
  -o "$FINAL_DMG" >/dev/null

# Cleanup
rm -f "$TEMP_DMG"
rm -rf "$STAGING"

echo "==> DMG ready: $FINAL_DMG"

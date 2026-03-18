#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
APP_PATH="dist/OpenOats.app"
DMG_PATH="dist/OpenOats.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found at $APP_PATH"
  echo "Run ./scripts/build_swift_app.sh first"
  exit 1
fi

rm -f "$DMG_PATH"

# --- Create a styled DMG with "drag to Applications" layout ---
STAGING_DIR="dist/dmg_staging"
TEMP_DMG="dist/OpenOats_temp.dmg"

rm -rf "$STAGING_DIR" "$TEMP_DMG"
mkdir -p "$STAGING_DIR"

# Copy app and create Applications alias (Finder alias renders with proper icon, unlike symlinks)
cp -R "$APP_PATH" "$STAGING_DIR/"
osascript -e "tell application \"Finder\" to make alias file to POSIX file \"/Applications\" at POSIX file \"$(cd "$STAGING_DIR" && pwd)\""
# Finder creates "Applications alias" — rename to "Applications"
if [[ -e "$STAGING_DIR/Applications alias" ]]; then
  mv "$STAGING_DIR/Applications alias" "$STAGING_DIR/Applications"
elif [[ ! -e "$STAGING_DIR/Applications" ]]; then
  # Fallback to symlink if alias creation fails
  ln -s /Applications "$STAGING_DIR/Applications"
fi

# Create a temporary read-write DMG
hdiutil create -volname "OpenOats" -srcfolder "$STAGING_DIR" -ov -format UDRW "$TEMP_DMG"

# Mount it and configure the Finder window via AppleScript
MOUNT_OUTPUT=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/.*' | head -1)

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "OpenOats"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 640, 400}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 80
    set position of item "OpenOats.app" of container window to {120, 150}
    set position of item "Applications" of container window to {420, 150}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Ensure all writes are flushed, then detach
sync
hdiutil detach "$MOUNT_POINT" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH"

# Clean up
rm -rf "$STAGING_DIR" "$TEMP_DMG"

# Sign the DMG if a signing identity is available
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  fi
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "Signing DMG with: $CODESIGN_IDENTITY"
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

echo "DMG created: $DMG_PATH"

# Notarize DMG if credentials are available
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "Submitting DMG for notarization..."

  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

  xcrun stapler staple "$DMG_PATH"
  echo "DMG notarization complete"
fi

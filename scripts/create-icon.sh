#!/bin/bash
# Creates a placeholder app icon from the tray icon
# Replace build/icon.icns with a proper icon later

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

mkdir -p "$PROJECT_DIR/build"

# Create a simple iconset from the tray icon
# This is a placeholder - replace with a proper 1024x1024 icon for production
ICONSET="$PROJECT_DIR/build/icon.iconset"
mkdir -p "$ICONSET"

SOURCE="$PROJECT_DIR/src/main/assets/tray-icon.png"

# Scale up the 32x32 icon (will be blurry but works as placeholder)
sips -z 16 16 "$SOURCE" --out "$ICONSET/icon_16x16.png" 2>/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_16x16@2x.png" 2>/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_32x32.png" 2>/dev/null
sips -z 64 64 "$SOURCE" --out "$ICONSET/icon_32x32@2x.png" 2>/dev/null
sips -z 128 128 "$SOURCE" --out "$ICONSET/icon_128x128.png" 2>/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" 2>/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_256x256.png" 2>/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" 2>/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_512x512.png" 2>/dev/null
sips -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png" 2>/dev/null

# Convert iconset to icns
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/build/icon.icns"

# Cleanup
rm -rf "$ICONSET"

echo "Created placeholder icon at build/icon.icns"
echo "Note: Replace with a proper 1024x1024 icon for production"

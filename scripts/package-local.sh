#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== PC Panel Pro Local Packaging ==="
echo ""

cd "$PROJECT_DIR"

# Build everything
echo "Building Electron app..."
npm run build

# Build the audio driver
echo "Building audio driver..."
npm run build:driver

# Create app icon
echo "Creating app icon..."
npm run build:icon

# Rebuild native modules for Electron
echo "Rebuilding native modules..."
npm run rebuild

# Package the app
echo "Packaging..."
npx electron-builder --mac --dir

APP_PATH=$(ls -d release/mac*/PC\ Panel\ Pro.app 2>/dev/null | head -1)

echo ""
echo "=== Packaging Complete ==="
echo ""
echo "App location: $APP_PATH"
echo ""
echo "To test:"
echo "  open \"$APP_PATH\""
echo ""
echo "To create DMG for distribution:"
echo "  npm run dist"

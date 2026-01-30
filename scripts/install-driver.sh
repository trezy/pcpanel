#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DRIVER_DIR="$PROJECT_DIR/driver"
DRIVER_PATH="$DRIVER_DIR/build/PCPanelAudio.driver"

if [ ! -d "$DRIVER_PATH" ]; then
    echo "Error: Driver not built. Run 'npm run build:driver' first."
    exit 1
fi

echo "Installing PCPanelAudio driver..."
sudo cp -r "$DRIVER_PATH" /Library/Audio/Plug-Ins/HAL/
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod

echo "✓ Driver installed and coreaudiod restarted"

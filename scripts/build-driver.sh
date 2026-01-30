#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DRIVER_DIR="$PROJECT_DIR/driver"

# Check for libASPL
if [ ! -d "$PROJECT_DIR/libASPL" ]; then
    echo "Error: libASPL not found. Run 'npm run setup' first."
    exit 1
fi

echo "Building PCPanelAudio driver..."

mkdir -p "$DRIVER_DIR/build"
cd "$DRIVER_DIR/build"
cmake ..
make

echo ""
echo "✓ Driver built: $DRIVER_DIR/build/PCPanelAudio.driver"
echo ""
echo "To install (requires sudo):"
echo "  npm run install:driver"

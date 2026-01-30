#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

LIBASPL_DIR="$PROJECT_DIR/libASPL"
LIBASPL_REPO="https://github.com/gavv/libASPL.git"
LIBASPL_TAG="v3.1.0"  # Pin to specific version for reproducibility

echo "=== PC Panel Pro Setup ==="

# Check/fetch libASPL
if [ -d "$LIBASPL_DIR" ]; then
    echo "✓ libASPL already exists"
else
    echo "Fetching libASPL ($LIBASPL_TAG)..."
    git clone --depth 1 --branch "$LIBASPL_TAG" "$LIBASPL_REPO" "$LIBASPL_DIR"
    echo "✓ libASPL fetched"
fi

# Install npm dependencies
echo "Installing npm dependencies..."
cd "$PROJECT_DIR"
npm install

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Available commands:"
echo "  npm run build         - Build Electron app"
echo "  npm run build:native  - Build native addon"
echo "  npm run build:driver  - Build audio driver"
echo "  npm run start         - Run the app"

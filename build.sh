#!/usr/bin/env bash
# Build a QuotaBar.app bundle from the SwiftPM executable.
# Usage: ./build.sh [debug|release]  (default: release)

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="QuotaBar"
BUILD_DIR=".build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "!! binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "→ assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Brand SVGs → Contents/Resources/Icons/  (loaded by BrandIcon.swift)
mkdir -p "$APP_DIR/Contents/Resources/Icons"
cp Sources/QuotaBar/Resources/Icons/*.svg "$APP_DIR/Contents/Resources/Icons/" 2>/dev/null || true

echo "→ done: $APP_DIR"
echo "   run with:  open $APP_DIR"

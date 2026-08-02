#!/usr/bin/env bash
# Build a UsageBar.app bundle from the SwiftPM executable, and (for
# release builds) produce a shareable .zip you can send to friends for
# testing.
#
# Usage:
#   ./build.sh              # release + zip, native arch (fast, ~4s)
#   ./build.sh debug        # debug build, no zip — for local iteration
#   ./build.sh universal    # release + zip, arm64 + x86_64 — for wider testing
#
# Outputs (both live under .build/, which is gitignored):
#   .build/UsageBar.app                — the runnable app bundle
#   .build/UsageBar-<version>.zip      — shareable archive (release / universal)

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
APP_NAME="UsageBar"
BUILD_DIR=".build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

case "$MODE" in
    debug)
        CONFIG="debug"
        ARCH_FLAGS=()
        MAKE_ZIP=0
        ;;
    release)
        CONFIG="release"
        ARCH_FLAGS=()
        MAKE_ZIP=1
        ;;
    universal)
        # SwiftPM's multi-arch build (`--arch arm64 --arch x86_64`) uses
        # xcbuild, which only ships with the full Xcode.app — Command Line
        # Tools alone are not enough.  Fail fast with a clear message
        # instead of the cryptic 'xcbuild not found' error.
        DEV_DIR=$(xcode-select -p 2>/dev/null || echo "")
        if [[ "$DEV_DIR" != *"Xcode.app"* ]]; then
            cat >&2 <<EOF
universal builds require the full Xcode, not just Command Line Tools.

Currently: xcode-select -p = ${DEV_DIR:-(none)}

To fix:
  1. Install Xcode from the App Store (or https://developer.apple.com/xcode)
  2. sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

Then rerun:  ./build.sh universal

If you only need Apple Silicon (native, works on ~all recent Macs),
just run:    ./build.sh
EOF
            exit 1
        fi
        CONFIG="release"
        ARCH_FLAGS=(--arch arm64 --arch x86_64)
        MAKE_ZIP=1
        ;;
    *)
        echo "unknown mode: $MODE  (use: debug | release | universal)" >&2
        exit 1
        ;;
esac

echo "→ swift build -c $CONFIG ${ARCH_FLAGS[*]:-}"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/${APP_NAME}"
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
cp Sources/UsageBar/Resources/Icons/*.svg "$APP_DIR/Contents/Resources/Icons/" 2>/dev/null || true

# Ad-hoc sign — Gatekeeper still calls this "unidentified developer" on a
# friend's Mac (proper signing needs $99/yr Apple Developer Program), but
# ad-hoc signing at least lets Gatekeeper verify the bundle is intact and
# stops it from being flagged as damaged.
codesign --force --deep --sign - "$APP_DIR" > /dev/null 2>&1 || true

echo "→ built: $APP_DIR"

if [[ "$MAKE_ZIP" -eq 1 ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
        "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "dev")
    ZIP_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
    rm -f "$ZIP_PATH"
    # `ditto -c -k --keepParent` preserves the .app bundle structure and
    # extended attributes — a plain `zip` would corrupt the bundle.
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
    ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')

    echo "→ shareable: $ZIP_PATH  ($ZIP_SIZE)"
    echo
    echo "   To send to a friend:"
    echo "     1. Send them $ZIP_PATH"
    echo "     2. They unzip and drag UsageBar.app to /Applications"
    echo "     3. Right-click → Open the first time (unblocks Gatekeeper's"
    echo "        'unidentified developer' warning; subsequent launches are silent)"
fi

echo
echo "   Run locally:  open $APP_DIR"

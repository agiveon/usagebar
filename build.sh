#!/usr/bin/env bash
# Build a UsageBar.app bundle and (for release builds) a shareable .zip.
#
# Usage:
#   ./build.sh              # release + zip (fast, native arch)
#   ./build.sh run          # release + zip + open the app
#   ./build.sh debug        # debug build only (local iteration)
#   ./build.sh universal    # release + zip, arm64 + x86_64 (needs full Xcode)
#
# Outputs land in dist/ (which is gitignored):
#   dist/UsageBar.app                — the runnable app bundle
#   dist/UsageBar-<version>.zip      — send this to friends

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
APP_NAME="UsageBar"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"

RUN_AFTER=0

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
    run)
        CONFIG="release"
        ARCH_FLAGS=()
        MAKE_ZIP=1
        RUN_AFTER=1
        ;;
    universal)
        DEV_DIR=$(xcode-select -p 2>/dev/null || echo "")
        if [[ "$DEV_DIR" != *"Xcode.app"* ]]; then
            cat >&2 <<EOF
universal builds require the full Xcode, not just Command Line Tools.

Currently: xcode-select -p = ${DEV_DIR:-(none)}

To fix:
  1. Install Xcode from the App Store (or https://developer.apple.com/xcode)
  2. sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

Then rerun:  ./build.sh universal

If you only need Apple Silicon (works on ~all recent Macs), just run:
    ./build.sh
EOF
            exit 1
        fi
        CONFIG="release"
        ARCH_FLAGS=(--arch arm64 --arch x86_64)
        MAKE_ZIP=1
        ;;
    *)
        echo "unknown mode: $MODE  (use: debug | release | run | universal)" >&2
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

echo "→ assembling $APP_DIR"
mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Brand SVGs → Contents/Resources/Icons/  (loaded by BrandIcon.swift)
mkdir -p "$APP_DIR/Contents/Resources/Icons"
cp Sources/UsageBar/Resources/Icons/*.svg "$APP_DIR/Contents/Resources/Icons/" 2>/dev/null || true

# Ad-hoc sign — Gatekeeper still shows "unidentified developer" on a
# friend's Mac (proper signing needs $99/yr Apple Developer), but ad-hoc
# at least prevents the "app is damaged" verdict.
codesign --force --deep --sign - "$APP_DIR" > /dev/null 2>&1 || true

echo "→ built:  $APP_DIR"

if [[ "$MAKE_ZIP" -eq 1 ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
        "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "dev")
    ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.zip"
    rm -f "$ZIP_PATH"
    # `ditto -c -k --keepParent` preserves the .app bundle structure and
    # extended attributes; a plain `zip` would corrupt the bundle.
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
    ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
    echo "→ zipped: $ZIP_PATH  ($ZIP_SIZE)"
fi

if [[ "$RUN_AFTER" -eq 1 ]]; then
    # Fresh launch — kill any older instance first.
    pkill -f "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    open "$APP_DIR"
    echo "→ launched.  Look for the icon in your menu bar."
else
    echo
    echo "   Run it:    ./build.sh run       (build + launch in one shot)"
    if [[ "$MAKE_ZIP" -eq 1 ]]; then
        echo "   Send it:   $ZIP_PATH"
        echo "              Tell friends: right-click → Open the first time."
    fi
fi

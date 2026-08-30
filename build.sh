#!/usr/bin/env bash
# Build a UsageBar.app bundle and (for release builds) a shareable .zip.
#
# Usage:
#   ./build.sh              # release + zip; universal if Xcode installed
#   ./build.sh run          # same, then launch the freshly-built app
#   ./build.sh debug        # debug build only (local iteration)
#   ./build.sh native       # release + zip, native arch only (skip universal)
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

# Multi-arch (arm64 + x86_64) needs the full Xcode.app — xcbuild only
# ships there, not with Command Line Tools.  Detect once, use it to
# decide whether release/run mode goes universal by default.
DEV_DIR=$(xcode-select -p 2>/dev/null || echo "")
HAVE_FULL_XCODE=0
[[ "$DEV_DIR" == *"Xcode.app"* ]] && HAVE_FULL_XCODE=1

case "$MODE" in
    debug)
        # Fast local iteration: native arch, no zip, no signing.
        CONFIG="debug"
        ARCH_FLAGS=()
        MAKE_ZIP=0
        ;;
    release|run)
        # Distribution build.  Universal if we can — so the zip works on
        # every Mac shipped in the last decade — otherwise native, with
        # a friendly note about installing Xcode for universal.
        CONFIG="release"
        MAKE_ZIP=1
        if [[ "$HAVE_FULL_XCODE" -eq 1 ]]; then
            ARCH_FLAGS=(--arch arm64 --arch x86_64)
            echo "→ full Xcode detected — building universal (arm64 + x86_64)"
        else
            ARCH_FLAGS=()
            echo "→ Command Line Tools only — building native arch (Apple Silicon only)"
            echo "  To ship a zip that also runs on Intel Macs, install Xcode.app"
            echo "  from the App Store and run:"
            echo "    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
        fi
        [[ "$MODE" == "run" ]] && RUN_AFTER=1
        ;;
    native)
        # Escape hatch: force native even when Xcode is installed, for
        # faster local rebuild during heavy iteration.
        CONFIG="release"
        ARCH_FLAGS=()
        MAKE_ZIP=1
        echo "→ native-arch release (universal skipped by request)"
        ;;
    universal)
        # Explicit universal — errors out if Xcode isn't present rather
        # than silently falling back.
        if [[ "$HAVE_FULL_XCODE" -ne 1 ]]; then
            cat >&2 <<EOF
universal builds require the full Xcode, not just Command Line Tools.

Currently: xcode-select -p = ${DEV_DIR:-(none)}

To fix:
  1. Install Xcode from the App Store (or https://developer.apple.com/xcode)
  2. sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

Then rerun:  ./build.sh universal
EOF
            exit 1
        fi
        CONFIG="release"
        ARCH_FLAGS=(--arch arm64 --arch x86_64)
        MAKE_ZIP=1
        ;;
    *)
        echo "unknown mode: $MODE  (use: debug | release | run | native | universal)" >&2
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

    # Stage: UsageBar.app + Install UsageBar.command + READ ME FIRST.txt,
    # all at the root of the archive so opening it drops the user into a
    # folder where "double-click the installer" is the obvious action.
    STAGE_DIR="$DIST_DIR/stage-${APP_NAME}-${VERSION}"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$APP_DIR" "$STAGE_DIR/"
    cp "Resources/Install UsageBar.command" "$STAGE_DIR/"
    chmod +x "$STAGE_DIR/Install UsageBar.command"
    cp "Resources/READ ME FIRST.txt" "$STAGE_DIR/"

    ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.zip"
    rm -f "$ZIP_PATH"
    # `ditto -c -k` on a directory preserves .app bundle structure and
    # extended attributes; a plain `zip` would corrupt the bundle.
    # `--keepParent` wraps everything inside a "$APP_NAME-$VERSION" folder
    # so extraction produces one clearly-named folder, not loose files.
    ( cd "$DIST_DIR" && mv "$(basename "$STAGE_DIR")" "${APP_NAME}-${VERSION}" )
    ditto -c -k --keepParent "$DIST_DIR/${APP_NAME}-${VERSION}" "$ZIP_PATH"
    rm -rf "$DIST_DIR/${APP_NAME}-${VERSION}"

    ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
    echo "→ zipped: $ZIP_PATH  ($ZIP_SIZE) — includes installer + READ ME"
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

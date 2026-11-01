#!/bin/bash
# Renders the demo video off screen from the app's real views, with a scripted cursor and camera.
#   scripts/make-demo.sh OUTPUT.mp4 [--stills DIR] [--every N] [--only section,section]
# It needs no display and works with the screen locked. See Sources/Clipboard/Demo/DemoScript.swift for the sections.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUTPUT="$1"
shift
STILLS=""
EVERY=""
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stills) STILLS="$2"; shift 2 ;;
        --every) EVERY="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Optimized, but with the DEBUG code that holds the demo. A separate build folder keeps it out of normal builds.
SCRATCH=".build/demo"
swift build -c release -Xswiftc -DDEBUG --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release -Xswiftc -DDEBUG --scratch-path "$SCRATCH" --show-bin-path)"

APP="$SCRATCH/Clipboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipboard" "$BIN_DIR/clipboard-mcp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"; defaults delete com.bunniesinc.clipboard.uitest 2>/dev/null || true' EXIT
defaults delete com.bunniesinc.clipboard.uitest 2>/dev/null || true
defaults write com.bunniesinc.clipboard.uitest hasShownWelcome -bool true

env CLIPBOARD_DATA_DIR="$DATA" \
    CLIPBOARD_TEST_PASTEBOARD="com.bunniesinc.clipboard.demo" \
    CLIPBOARD_DEMO_ASSETS="$PWD/demo-assets" \
    CLIPBOARD_DEMO_OUTPUT="$OUTPUT" \
    CLIPBOARD_DEMO_STILLS="$STILLS" \
    CLIPBOARD_DEMO_STILL_EVERY="$EVERY" \
    ${ONLY:+CLIPBOARD_DEMO_ONLY="$ONLY"} \
    "$APP/Contents/MacOS/Clipboard"

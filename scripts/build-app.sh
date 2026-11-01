#!/bin/bash
# Builds build/Clipboard.app. Options:
#   --install  copy it to ~/Applications
#   --debug    debug build with the test channel from TestControl.swift
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG=release
INSTALL=false
for argument in "$@"; do
    case "$argument" in
        --debug) CONFIG=debug ;;
        --install) INSTALL=true ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done

swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Clipboard.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipboard" "$BIN_DIR/clipboard-mcp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# macOS keys the Accessibility permission to the signature's designated requirement. A self-signed certificate
# keeps that stable across rebuilds, so the permission survives them. Gremlin's installer leaves one in the login
# keychain, and CLIPBOARD_SIGN_IDENTITY picks another.
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
IDENTITY="${CLIPBOARD_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q '"Gremlin Code Signing"'; then
    IDENTITY="Gremlin Code Signing"
fi

# Sign the helper first: signing the outer bundle seals the helper's signature into it.
if [[ -n "$IDENTITY" ]]; then
    codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier com.bunniesinc.clipboard.mcp "$APP/Contents/MacOS/clipboard-mcp"
    codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier com.bunniesinc.clipboard "$APP"
else
    # With no certificate, naming only the identifier still survives rebuilds, but any ad-hoc app claiming it would inherit the permission.
    codesign --force --sign - --identifier com.bunniesinc.clipboard.mcp "$APP/Contents/MacOS/clipboard-mcp"
    codesign --force --sign - --identifier com.bunniesinc.clipboard --requirements '=designated => identifier "com.bunniesinc.clipboard"' "$APP"
fi

echo "Built $APP"

if [[ "$INSTALL" == true ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Clipboard.app"
    cp -R "$APP" "$HOME/Applications/Clipboard.app"
    echo "Installed $HOME/Applications/Clipboard.app"
fi

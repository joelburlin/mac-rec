#!/bin/bash
# Build the release binary and wrap it into Mac-Rec.app.
# The app is the menu-bar UI; the same binary inside it serves as CLI + daemon.
# Usage: ./make-app.sh [install-dir]   (default /Applications)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

DEST="${1:-/Applications}"
APP="$DEST/Mac-Rec.app"
BUNDLE_ID="dev.joelburlin.mac-rec"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/mac-rec "$APP/Contents/MacOS/mac-rec"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Prefer a real signing identity: its TCC grants survive rebuilds. With ad-hoc
# signing, TCC pins the exact binary hash, so every reinstall needs re-granting.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY (permissions survive rebuilds)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    # A fresh ad-hoc hash invalidates old grants — clear the stale TCC entries
    # so System Settings doesn't show a toggle that silently doesn't apply.
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "WARNING: ad-hoc signed — Screen Recording + Microphone must be re-granted"
    echo "         after every install. Create a self-signed code-signing cert"
    echo "         (Keychain Access → Certificate Assistant → Create a Certificate,"
    echo "         type: Code Signing) and rerun; this script will pick it up."
fi

# Refresh the CLI symlink to the same build.
ln -sf "$PWD/.build/release/mac-rec" /opt/homebrew/bin/mac-rec

# Stop any daemon owned by a previous identity so the next one runs under the
# app (that's what Screen Recording / Microphone permissions attach to).
"$PWD/.build/release/mac-rec" quit >/dev/null 2>&1 || true

echo "installed: $APP"
echo "launch:    open '$APP'   (menu-bar icon; grant Screen Recording + Microphone on first record)"

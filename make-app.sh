#!/bin/bash
# Build the release binary and wrap it into Mac-Rec.app.
# The app is the menu-bar UI; the same binary inside it serves as CLI + daemon.
# Usage: ./make-app.sh [install-dir]   (default /Applications)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

DEST="${1:-/Applications}"
APP="$DEST/Mac-Rec.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/mac-rec "$APP/Contents/MacOS/mac-rec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

# Refresh the CLI symlink to the same build.
ln -sf "$PWD/.build/release/mac-rec" /opt/homebrew/bin/mac-rec

# Stop any daemon owned by a previous identity so the next one runs under the
# app (that's what Screen Recording / Microphone permissions attach to).
"$PWD/.build/release/mac-rec" quit >/dev/null 2>&1 || true

echo "installed: $APP"
echo "launch:    open '$APP'   (menu-bar icon; grant Screen Recording + Microphone on first record)"

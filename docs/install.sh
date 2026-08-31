#!/bin/bash
# mac-rec installer — https://screenrecording.dev
#
#   curl -fsSL https://screenrecording.dev/install.sh | bash
#
# Downloads the latest release, installs it to /Applications, and removes the
# quarantine flag macOS puts on anything downloaded from the internet. That
# flag is why an unnotarized app is blocked; notarizing needs a paid Apple
# Developer ID, so this script does the same thing you would do by hand.
set -euo pipefail

REPO="joelburlin/mac-rec"
APP="/Applications/Mac-Rec.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; hdiutil detach "$TMP/mnt" -quiet 2>/dev/null || true' EXIT

echo "→ finding the latest release…"
DMG_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o 'https://[^"]*\.dmg' | head -1)"
[ -n "$DMG_URL" ] || { echo "✗ couldn't find a .dmg in the latest release"; exit 1; }

echo "→ downloading $(basename "$DMG_URL")"
curl -fL# -o "$TMP/mac-rec.dmg" "$DMG_URL"

echo "→ installing to $APP"
mkdir -p "$TMP/mnt"
hdiutil attach "$TMP/mac-rec.dmg" -nobrowse -quiet -mountpoint "$TMP/mnt"
if [ -d "$APP" ]; then
    pkill -f "Mac-Rec.app/Contents/MacOS/mac-rec" 2>/dev/null || true
    sleep 1
    rm -rf "$APP"
fi
cp -R "$TMP/mnt/Mac-Rec.app" /Applications/
hdiutil detach "$TMP/mnt" -quiet

# The whole point: clear the quarantine bit so macOS opens it normally.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Link the CLI so agents and scripts can drive it.
BIN=""
for d in /opt/homebrew/bin /usr/local/bin; do
    [ -d "$d" ] && [ -w "$d" ] && BIN="$d" && break
done
if [ -n "$BIN" ]; then
    ln -sf "$APP/Contents/MacOS/mac-rec" "$BIN/mac-rec"
    echo "→ CLI linked: $BIN/mac-rec"
else
    echo "→ CLI not linked (no writable bin dir). Use: $APP/Contents/MacOS/mac-rec"
fi

command -v ffmpeg >/dev/null || echo "! ffmpeg not found — needed to save recordings: brew install ffmpeg"

echo "→ launching"
open "$APP"
echo
echo "✓ installed $("$APP/Contents/MacOS/mac-rec" --version 2>/dev/null || echo "")"
echo "  Grant Screen Recording (and Microphone) on the first record."
echo "  Docs: https://screenrecording.dev"

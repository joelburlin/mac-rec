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

# Sign with a stable identity so TCC grants survive rebuilds. Preference:
# 1. the dedicated mac-rec signing keychain (./setup-signing.sh creates it)
# 2. any codesigning identity in the default keychains
# 3. ad-hoc (grants break on every install; TCC entries reset to avoid
#    dead toggles in System Settings)
SIGN_KC="$HOME/.config/mac-rec/signing.keychain-db"
if security find-identity -v -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "mac-rec-signing"; then
    security unlock-keychain -p "mac-rec-local-signing" "$SIGN_KC"
    # codesign only searches keychains on the search list; add ours once.
    if ! security list-keychains -d user | grep -q "mac-rec/signing.keychain"; then
        # shellcheck disable=SC2046
        security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$SIGN_KC"
    fi
    codesign --force --sign "mac-rec-signing" "$APP"
    echo "signed with mac-rec-signing (permissions survive rebuilds)"
elif IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"/ {print $2; exit}')" && [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY (permissions survive rebuilds)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "WARNING: ad-hoc signed — permissions must be re-granted after every"
    echo "         install. Run ./setup-signing.sh once to fix this for good."
fi

# Refresh the CLI symlink to the same build.
ln -sf "$PWD/.build/release/mac-rec" /opt/homebrew/bin/mac-rec

# Stop any daemon owned by a previous identity so the next one runs under the
# app (that's what Screen Recording / Microphone permissions attach to).
"$PWD/.build/release/mac-rec" quit >/dev/null 2>&1 || true

echo "installed: $APP"
echo "launch:    open '$APP'   (menu-bar icon; grant Screen Recording + Microphone on first record)"

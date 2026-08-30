#!/bin/bash
# Build a distributable Mac-Rec.dmg (universal binary, drag-to-Applications).
#
# The DMG is ad-hoc signed, NOT notarized: notarization needs a paid Apple
# Developer ID. Gatekeeper therefore quarantines it on download, and first
# launch requires right-click → Open (documented on the site and in the README).
# This script never touches an installed /Applications/Mac-Rec.app.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(awk -F'"' '/^let macRecVersion/ {print $2}' Sources/mac-rec/Support/Config.swift)"
DIST="dist"
APP="$DIST/Mac-Rec.app"
DMG="$DIST/Mac-Rec-$VERSION.dmg"

rm -rf "$DIST"; mkdir -p "$DIST/dmg"

# Universal so the download runs on both Apple silicon and Intel Macs.
echo "building universal binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/mac-rec"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/mac-rec"
sed "s|<string>0\.[0-9.]*</string>|<string>$VERSION</string>|" Resources/Info.plist \
    > "$APP/Contents/Info.plist"

# Ad-hoc: a self-signed local cert means nothing on someone else's Mac, and
# Apple silicon refuses to run a completely unsigned binary.
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP" && echo "signed (ad-hoc)"

cp -R "$APP" "$DIST/dmg/"
ln -s /Applications "$DIST/dmg/Applications"
cat > "$DIST/dmg/FIRST LAUNCH.txt" <<'TXT'
Mac-Rec is open source and unnotarized (no paid Apple Developer ID), so
macOS quarantines it on download.

To open it the first time:
  1. Drag Mac-Rec into Applications.
  2. RIGHT-CLICK Mac-Rec in Applications → Open → Open.

That right-click is required only once. If macOS still refuses, run:
  xattr -dr com.apple.quarantine /Applications/Mac-Rec.app

Then grant Screen Recording (and Microphone, for narration) in
System Settings → Privacy & Security. Details: https://github.com/joelburlin/mac-rec
TXT

hdiutil create -volname "Mac-Rec $VERSION" -srcfolder "$DIST/dmg" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/dmg"

echo "built: $DMG ($(du -h "$DMG" | cut -f1))"

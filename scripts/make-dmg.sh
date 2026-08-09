#!/bin/bash
set -euo pipefail

# Packages build/SwarmBar.app into a drag-to-Applications .dmg.
# Run scripts/build-app.sh first.
#
# Usage: scripts/make-dmg.sh [version]
#        (version defaults to the app's CFBundleShortVersionString)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SwarmBar"
APP_DIR="$ROOT/build/$APP_NAME.app"
VERSION="${1:-$(defaults read "$APP_DIR/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.1.0)}"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"

[ -d "$APP_DIR" ] || { echo "error: $APP_DIR not found, run scripts/build-app.sh first"; exit 1; }

echo "==> Staging DMG contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"

# Sign the disk image itself, not just the app inside it.
#
# An unsigned dmg still works, because the app it carries is notarized and
# stapled, and that is what Gatekeeper checks at first launch. But the dmg
# is the thing people download, and an unsigned one assesses as "rejected,
# source=no usable signature", which is indistinguishable from a real
# problem when someone checks. Signed and notarized it reads "accepted,
# source=Notarized Developer ID", so there is nothing to interpret.
#
# This invalidates any notarization ticket already stapled to the dmg, so
# it must happen before notarizing, never after.
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
echo "==> Signing the disk image"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"

echo "==> Done: $DMG"

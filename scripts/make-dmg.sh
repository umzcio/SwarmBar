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
#
# Sign with the same team project.yml signs the app with. The bare name
# "Developer ID Application" is ambiguous as soon as the keychain holds a
# second Developer ID certificate, and codesign then refuses to pick one, so
# the identity is chosen by team id. CODESIGN_IDENTITY still overrides.
TEAM="$(awk '/DEVELOPMENT_TEAM:/ { print $2; exit }' "$ROOT/project.yml")"
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -v team="($TEAM)\"" '/Developer ID Application/ && index($0, team) { print $2; exit }')}"
[ -n "$IDENTITY" ] || { echo "error: no Developer ID Application identity for team $TEAM"; exit 1; }
echo "==> Signing the disk image"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"

echo "==> Done: $DMG"

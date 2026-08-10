#!/bin/bash
set -euo pipefail

# End-to-end release: test -> build -> sign -> .dmg -> notarize -> staple.
# Produces build/SwarmBar-<version>.dmg ready to attach to a GitHub release.
#
# Prereqs:
#   - A "Developer ID Application" identity in the login keychain.
#   - scripts/.notary-config.local (see .notary-config.example).
#
# Usage: scripts/release.sh 0.1.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release.sh <version>  e.g. 0.1.0}"
APP_NAME="SwarmBar"
APP_DIR="$ROOT/build/$APP_NAME.app"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"

echo "==> [1/6] Run the test suite"
(cd "$ROOT" && xcodegen generate)
xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Debug \
    -destination 'platform=macOS' \
    test

echo "==> [2/6] Build + sign app"
bash "$ROOT/scripts/build-app.sh"

BUILT_VERSION="$(defaults read "$APP_DIR/Contents/Info" CFBundleShortVersionString)"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "error: built app is $BUILT_VERSION but release.sh was invoked for $VERSION." >&2
    echo "       Bump CFBundleShortVersionString in project.yml and commit first." >&2
    exit 1
fi

echo "==> [3/6] Package .dmg"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"

echo "==> [4/6] Notarize the .dmg (which notarizes the app inside it)"
bash "$ROOT/scripts/notarize.sh" "$DMG"

# Stapling the dmg does not staple the app inside it, so a user who copies
# SwarmBar.app out and later goes offline has no ticket to check. Staple the
# app, repackage, and notarize the new dmg, which is a different file.
echo "==> [5/6] Staple the app, repackage, notarize again"
xcrun stapler staple "$APP_DIR"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"
bash "$ROOT/scripts/notarize.sh" "$DMG"

echo "==> [6/6] Verifying the way Gatekeeper will"
# The real question is not "is it signed" but "would a first launch on
# someone else's Mac be allowed", and that is what spctl answers. Both
# artifacts are checked: the dmg is what gets downloaded, the app is what
# gets run, and they carry separate tickets.
spctl --assess --type execute --verbose=4 "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl --assess --type open --context context:primary-signature -v "$DMG"
xcrun stapler validate "$DMG"

echo "==> Generating the signed Sparkle appcast"
# generate_appcast reads the EdDSA private key from the login keychain,
# signs the dmg with it, and writes appcast.xml pointing at the GitHub
# release asset. Without this the app can see nothing: SUFeedURL is the
# appcast at the repo root, so a release that never reaches it is a
# release nobody is offered.
DIST="$ROOT/build/dist"
GEN="$(find "$ROOT/build" ~/Library/Developer/Xcode/DerivedData \
        -name generate_appcast -type f 2>/dev/null | head -1)"
[ -n "$GEN" ] || { echo "error: generate_appcast not found; build once so SPM fetches Sparkle"; exit 1; }
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$DMG" "$DIST/"
"$GEN" "$DIST" --download-url-prefix "https://github.com/umzcio/SwarmBar/releases/download/v$VERSION/"
cp "$DIST/appcast.xml" "$ROOT/appcast.xml"

echo
echo "  DMG    : $DMG"
echo "  appcast: $ROOT/appcast.xml"
echo
echo "  Next:"
echo "    1) gh release create v$VERSION \"$DMG\" --title \"SwarmBar $VERSION\" --notes \"...\""
echo "    2) git add appcast.xml && git commit -m \"appcast: $VERSION\" && git push"
echo "       The feed is read from main, so until it is pushed nobody is offered the update."

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

echo "==> [1/7] Run the test suite"
(cd "$ROOT" && xcodegen generate)
xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Debug \
    -destination 'platform=macOS' \
    test

echo "==> [2/7] Build + sign app"
bash "$ROOT/scripts/build-app.sh"

BUILT_VERSION="$(defaults read "$APP_DIR/Contents/Info" CFBundleShortVersionString)"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "error: built app is $BUILT_VERSION but release.sh was invoked for $VERSION." >&2
    echo "       Bump CFBundleShortVersionString in project.yml and commit first." >&2
    exit 1
fi

# The remote setup command downloads exactly this file for this version
# (releases/download/v<version>/swarmbar-helper.py) and refuses to run it
# unless its sha256 matches the helper bundled in the app. A release that
# does not carry the helper makes that URL a 404, and one that carries a
# different helper makes every setup command fail its check, so the asset
# is the bundled copy, byte for byte. Checked here, right after the
# build, so a mismatch fails before the long notarization wait. Stapling
# only touches the bundle's signature ticket, never Resources.
echo "==> [3/7] Stage the remote helper"
HELPER="$ROOT/build/swarmbar-helper.py"
cp "$ROOT/scripts/swarmbar-helper.py" "$HELPER"
if ! cmp -s "$HELPER" "$APP_DIR/Contents/Resources/swarmbar-helper.py"; then
    echo "error: scripts/swarmbar-helper.py differs from the copy inside $APP_NAME.app." >&2
    echo "       The app was built from a different helper than the one this release would ship." >&2
    exit 1
fi
HELPER_SHA="$(shasum -a 256 "$HELPER" | awk '{print $1}')"

echo "==> [4/7] Package .dmg"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"

echo "==> [5/7] Notarize the .dmg (which notarizes the app inside it)"
bash "$ROOT/scripts/notarize.sh" "$DMG"

# Stapling the dmg does not staple the app inside it, so a user who copies
# SwarmBar.app out and later goes offline has no ticket to check. Staple the
# app, repackage, and notarize the new dmg, which is a different file.
echo "==> [6/7] Staple the app, repackage, notarize again"
xcrun stapler staple "$APP_DIR"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"
bash "$ROOT/scripts/notarize.sh" "$DMG"

echo "==> [7/7] Verifying the way Gatekeeper will"
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
echo "  helper : $HELPER"
echo "  sha256 : $HELPER_SHA"
echo
echo "  Next:"
echo "    1) gh release create v$VERSION \"$DMG\" \"$HELPER\" --title \"SwarmBar $VERSION\" --notes \"...\""
echo "    2) git add appcast.xml && git commit -m \"appcast: $VERSION\" && git push"
echo "       The feed is read from main, so until it is pushed nobody is offered the update."

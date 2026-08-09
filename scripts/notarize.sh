#!/bin/bash
set -euo pipefail

# Notarizes a .dmg / .zip / .app with Apple using an App Store Connect API
# key, then staples the ticket. Credentials come from
# scripts/.notary-config.local (gitignored; see .notary-config.example).
#
# Usage: scripts/notarize.sh build/SwarmBar-0.1.0.dmg
#
# Prereq: a Release, hardened-runtime, Developer ID signed artifact, which
# scripts/build-app.sh produces and verifies.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="${1:?usage: notarize.sh <path-to-dmg-zip-or-app>}"
CONFIG="$ROOT/scripts/.notary-config.local"

[ -f "$CONFIG" ] || {
    echo "error: $CONFIG not found."
    echo "       Copy scripts/.notary-config.example to it and fill it in, or copy the"
    echo "       one from another project of yours that already notarizes."
    exit 1
}
# shellcheck disable=SC1090
source "$CONFIG"
KEY_PATH="${NOTARY_KEY/#\~/$HOME}"
[ -f "$KEY_PATH" ] || { echo "error: notary key not found at $KEY_PATH"; exit 1; }

echo "==> Submitting $(basename "$ARTIFACT") to Apple notary"
xcrun notarytool submit "$ARTIFACT" \
    --key "$KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait

echo "==> Stapling"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "==> Notarized + stapled: $ARTIFACT"

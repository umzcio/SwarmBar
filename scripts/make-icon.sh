#!/bin/bash
set -euo pipefail

# Regenerates SwarmBar/Resources/AppIcon.icns from assets/logo.svg.
#
# The .icns is committed because the build needs it, but it is generated,
# so this exists to keep it honest: change the logo, run this, commit both.
#
# Rendering from the SVG rather than scaling assets/logo.png matters at the
# top end. The png is 512, and an app icon needs 1024 for the @2x slot, so
# scaling it up would ship a soft icon at the one size people actually look
# at closely.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/assets/logo.svg"
OUT="$ROOT/SwarmBar/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SVG" ] || { echo "error: $SVG not found"; exit 1; }

echo "==> Rendering $SVG at 1024"
qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
MASTER="$WORK/$(basename "$SVG").png"
[ -f "$MASTER" ] || { echo "error: could not rasterize the svg"; exit 1; }

SIZE=$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/{print $2}')
[ "$SIZE" = "1024" ] || { echo "error: expected 1024px master, got $SIZE"; exit 1; }

echo "==> Building the iconset"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
# Every slot macOS asks for. Missing ones are not an error at build time,
# they just leave a blank icon in whichever context wanted that size.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    px="${spec%% *}"; name="${spec##* }"
    sips -z "$px" "$px" "$MASTER" --out "$SET/$name.png" >/dev/null 2>&1
done

echo "==> Packing $OUT"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"

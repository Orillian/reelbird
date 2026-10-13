#!/usr/bin/env bash
# Regenerates every raster brand asset from the SVG sources in brand/:
#   brand/AppIcon.icns            app icon (all sizes, 16 pt to 512 pt @2x), from brand/icon.svg
#   brand/icon-1024.png           icon preview (README, website)
#   brand/menubar*.png            menu bar template glyphs, 18 pt @1x and @2x
#   brand/web/*.png               favicon 32 px, icon 512 px, apple-touch-icon 180 px
# Needs only the Command Line Tools (swiftc, iconutil). No Xcode, no Homebrew.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reelbird-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

swiftc -O brand/tools/render-svg.swift -o "$WORK/render-svg"
render() { "$WORK/render-svg" "$@"; }

# App icon. iconutil wants exactly these names in a folder ending in .iconset.
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for pt in 16 32 128 256 512; do
  render brand/icon.svg "$ICONSET/icon_${pt}x${pt}.png" "$pt" "$pt"
  render brand/icon.svg "$ICONSET/icon_${pt}x${pt}@2x.png" "$((pt * 2))" "$((pt * 2))"
done
iconutil --convert icns "$ICONSET" --output brand/AppIcon.icns
render brand/icon.svg brand/icon-1024.png 1024 1024

# Menu bar glyphs: black with alpha; the app marks them as template images.
for name in menubar menubar-recording; do
  render "brand/$name.svg" "brand/$name.png" 18 18
  render "brand/$name.svg" "brand/$name@2x.png" 36 36
done

# Website icons.
render brand/web/favicon.svg brand/web/favicon-32.png 32 32
render brand/web/favicon.svg brand/web/icon-512.png 512 512
render brand/web/apple-touch-icon.svg brand/web/apple-touch-icon.png 180 180

echo "Wrote brand/AppIcon.icns, brand/icon-1024.png, brand/menubar*.png, brand/web/*.png"
echo "The banner, social card and OG image are HTML: see brand/tools/render-html.sh"

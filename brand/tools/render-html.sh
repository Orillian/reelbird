#!/usr/bin/env bash
# Renders a brand HTML page (banner, social card, OG image) to PNG with headless Chromium.
#   brand/tools/render-html.sh <page.html> <out.png> <width> <height> [query] [scale]
#   e.g. brand/tools/render-html.sh brand/src/banner.html brand/readme/banner-dark.png 1600 800 dark
# Needs Google Chrome or Chromium. Set CHROME=/path/to/binary to pick one. The pages load the site's
# fonts from site/src/assets/fonts, so run it from a checkout that has the site.
set -euo pipefail
page="$1"; out="$2"; w="$3"; h="$4"; query="${5:-}"; scale="${6:-1}"
if [ -z "${CHROME:-}" ]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium" "$(command -v chromium || true)" "$(command -v google-chrome || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
  done
fi
[ -n "${CHROME:-}" ] || { echo "render-html: no Chrome or Chromium found; set CHROME" >&2; exit 69; }
abs="$(cd "$(dirname "$page")" && pwd)/$(basename "$page")"
url="file://$abs${query:+?$query}"
headless=(--headless=new); case "$CHROME" in *headless-shell*) headless=();; esac
"$CHROME" ${headless[@]+"${headless[@]}"} --disable-gpu --hide-scrollbars --allow-file-access-from-files \
  --default-background-color=00000000 --force-device-scale-factor="$scale" \
  --window-size="$w,$h" --virtual-time-budget=4000 --screenshot="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")" "$url" >/dev/null 2>&1
echo "Wrote $out"

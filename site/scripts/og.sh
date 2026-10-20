#!/usr/bin/env bash
# Renders the per-page Open Graph images (1200×630) into public/og/ from the brand template
# (brand/src/og.html, which loads this site's fonts). Run it from a full repo checkout after
# changing a page title; the PNGs are committed, so the site build itself needs no browser.
#   site/scripts/og.sh            render every image
#   CHROME=/path/to/chrome site/scripts/og.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SITE="$(pwd)"
REPO="$(cd .. && pwd)"
RENDER="$REPO/brand/tools/render-html.sh"
TEMPLATE="$REPO/brand/src/og.html"
OUT="$SITE/public/og"
mkdir -p "$OUT"

# slug | title | section | art (perch, camera, link, headphones, sleeping, celebrating)
PAGES='home|Record. Get a link. Polish it later.||perch
download|Build Reelbird from source in a few minutes|Download|perch
features|Auto-zoom, instant links and clean audio|Features|camera
features-auto-zoom|Zooms that follow your clicks|Features|camera
features-share-links|Share links from a bucket you own|Features|link
features-audio-captions|Clear sound and on-device captions|Features|headphones
features-agents|Your coding agent can record the demo|Features|perch
docs|Install, share links, CLI and MCP|Docs|perch
docs-install|Install Reelbird from source|Docs|perch
docs-sharing|Share links from a bucket you own|Docs|link
docs-shortcuts|Keyboard shortcuts|Docs|perch
docs-cli|The reelbird command line tool|Docs|perch
docs-mcp|MCP server for Claude Code, Codex and Cursor|Docs|perch
docs-troubleshooting|Troubleshooting|Docs|sleeping
docs-format|The .reelbird project format|Docs|perch
docs-architecture|How Reelbird is built|Docs|perch
loom-alternative|A free, open-source Loom alternative for Mac|Compare|link
screen-studio-alternative|A free, open-source Screen Studio alternative|Compare|camera
compare|Mac screen recorders compared|Compare|perch
guide-internal-audio|Record your Mac screen with internal audio|Guide|headphones
faq|Questions, answered|FAQ|perch
support|Support Reelbird|Support|celebrating
pricing|Free, or $5 a month if we host your links|Pricing|link
privacy|No account needed, no telemetry|Privacy|sleeping
changelog|What changed in each release|Changelog|celebrating'

enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
start=$(date +%s)
while IFS='|' read -r slug title section art; do
  "$RENDER" "$TEMPLATE" "$OUT/$slug.png" 1200 630 "title=$(enc "$title")&section=$(enc "$section")&art=$art" >/dev/null
  if command -v pngquant >/dev/null; then pngquant --quality 80-95 --strip --force --skip-if-larger --output "$OUT/$slug.png" "$OUT/$slug.png" || true; fi
  echo "og/$slug.png"
done <<< "$PAGES"
echo "Rendered $(echo "$PAGES" | wc -l | tr -d ' ') images in $(( $(date +%s) - start ))s"

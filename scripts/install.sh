#!/usr/bin/env bash
# Builds a release Reelbird.app (scripts/build-app.sh) and copies it to /Applications.
# If a copy is already installed, it asks first, before the build starts.
#
# Usage:
#   scripts/install.sh          ask before replacing an existing copy, then build and install
#   scripts/install.sh --yes    replace an existing copy without asking
#
#   RB_SIGN_IDENTITY  codesigning identity, passed to build-app.sh (see scripts/dev-signing.sh)
#   RB_INSTALL_DIR    install folder (default /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (use --yes or --help)" >&2; exit 64 ;;
  esac
done

DEST_DIR="${RB_INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/Reelbird.app"
BUNDLE_ID="app.reelbird.Reelbird"

if [ ! -d "$DEST_DIR" ]; then
  echo "$DEST_DIR doesn't exist." >&2
  exit 1
fi
if [ ! -w "$DEST_DIR" ]; then
  echo "Can't write to $DEST_DIR. Run scripts/build-app.sh and copy build/Reelbird.app there yourself, or set RB_INSTALL_DIR (for example ~/Applications)." >&2
  exit 1
fi

if [ -e "$DEST" ] && [ "$ASSUME_YES" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "$DEST already exists. Run again with --yes to replace it." >&2
    exit 1
  fi
  read -r -p "Replace $DEST? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Left $DEST as it was."; exit 0 ;;
  esac
fi

RB_CONFIG=release scripts/build-app.sh

# Quit a running copy first, so the new one starts cleanly.
if pgrep -f "$DEST/Contents/MacOS/Reelbird" >/dev/null 2>&1; then
  echo "Quitting the running Reelbird..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$DEST/Contents/MacOS/Reelbird" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

# Copy next to the destination, then swap, so a failed copy never leaves a half-installed app.
STAGING="$DEST_DIR/.Reelbird.app.installing"
rm -rf "$STAGING"
ditto build/Reelbird.app "$STAGING"
rm -rf "$DEST"
mv "$STAGING" "$DEST"

echo "Installed $DEST"
echo "Open it with: open \"$DEST\""
if [ -z "${RB_SIGN_IDENTITY:-}" ]; then
  echo "This build is signed ad hoc, so macOS asks for Screen Recording again after each rebuild."
  echo "To keep the permission, run scripts/dev-signing.sh once (see the README)."
fi

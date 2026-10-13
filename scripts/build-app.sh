#!/usr/bin/env bash
# Builds build/Reelbird.app (release) with the `reelbird` CLI inside it.
#   RB_SIGN_IDENTITY  codesigning identity (default: a "Developer ID Application" identity if present,
#                     else "Reelbird Local Signing" if present, else "-" = ad-hoc).
#   RB_CONFIG         debug|release (default release)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
CONFIG="${RB_CONFIG:-release}"
# Default: an Apple Developer ID when the keychain has one, then the local identity from
# scripts/dev-signing.sh (both keep permissions across rebuilds), otherwise ad-hoc.
DEFAULT_IDENTITY="-"
security find-certificate -c "Reelbird Local Signing" >/dev/null 2>&1 && DEFAULT_IDENTITY="Reelbird Local Signing"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[ -n "$DEVID" ] && DEFAULT_IDENTITY="$DEVID"
IDENTITY="${RB_SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
# Notarization needs a secure timestamp; other identities skip the network round trip.
TIMESTAMP=(--timestamp=none)
case "$IDENTITY" in "Developer ID Application:"*) TIMESTAMP=(--timestamp) ;; esac
SCRATCH=()
[ -n "${RB_SCRATCH:-}" ] && SCRATCH=(--scratch-path "$RB_SCRATCH")
swift build -c "$CONFIG" ${SCRATCH[@]+"${SCRATCH[@]}"} --product ReelbirdApp
swift build -c "$CONFIG" ${SCRATCH[@]+"${SCRATCH[@]}"} --product reelbird
BIN="$(swift build -c "$CONFIG" ${SCRATCH[@]+"${SCRATCH[@]}"} --show-bin-path)"

APP=build/Reelbird.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/ReelbirdApp" "$APP/Contents/MacOS/Reelbird"
cp "$BIN/reelbird" "$APP/Contents/Helpers/reelbird"
cp packaging/Info.plist "$APP/Contents/Info.plist"
[ -f brand/AppIcon.icns ] && cp brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements packaging/Reelbird.entitlements --sign "$IDENTITY" "$APP/Contents/Helpers/reelbird"
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements packaging/Reelbird.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"

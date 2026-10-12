#!/usr/bin/env bash
# Builds build/Reelbird.app (release) with the `reelbird` CLI inside it.
#   RB_SIGN_IDENTITY  codesigning identity (default "-" = ad-hoc). See scripts/dev-signing.sh.
#   RB_CONFIG         debug|release (default release)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
CONFIG="${RB_CONFIG:-release}"
IDENTITY="${RB_SIGN_IDENTITY:--}"
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

codesign --force --options runtime --entitlements packaging/Reelbird.entitlements --sign "$IDENTITY" "$APP/Contents/Helpers/reelbird"
codesign --force --options runtime --entitlements packaging/Reelbird.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"

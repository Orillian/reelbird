#!/usr/bin/env bash
# Builds a release Reelbird.app and packs it for a download:
#   build/Reelbird-<version>.zip          the app, zipped with ditto (keeps the bundle intact)
#   build/Reelbird-<version>.zip.sha256   its SHA-256, in `shasum -a 256` format
#
# The app is signed ad hoc, not with a Developer ID, and isn't notarized. People who download it
# have to allow it once in System Settings → Privacy & Security ("Open Anyway").
#
#   RB_SIGN_IDENTITY  override the signing identity (default "-", ad hoc, so no local identity leaks in)
#   RB_SCRATCH        separate build directory, as for the other scripts
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=packaging/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CODE_VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ReelbirdCore/Settings.swift)"
if [ "$VERSION" != "$CODE_VERSION" ]; then
  echo "Version mismatch: $PLIST says $VERSION, ReelbirdInfo.version says $CODE_VERSION. Make them match first." >&2
  exit 1
fi

RB_CONFIG=release RB_SIGN_IDENTITY="${RB_SIGN_IDENTITY:--}" scripts/build-app.sh

APP=build/Reelbird.app
ZIP="build/Reelbird-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
# --keepParent puts Reelbird.app at the top of the archive; --norsrc and --noextattr keep
# Finder metadata and quarantine flags from the build machine out of it.
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$ZIP"
(cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '), $(lipo -archs "$APP/Contents/MacOS/Reelbird"))"
cat "$ZIP.sha256"

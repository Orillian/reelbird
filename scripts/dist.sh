#!/usr/bin/env bash
# Builds a release Reelbird.app and packs it for a download:
#   build/Reelbird-<version>.zip          the app, zipped with ditto (keeps the bundle intact)
#   build/Reelbird-<version>.zip.sha256   its SHA-256, in `shasum -a 256` format
#
# With a "Developer ID Application" identity in the keychain, the app is signed with it, notarized
# by Apple and stapled, so it opens with no warning. Without one, it's signed ad hoc and people who
# download it have to allow it once in System Settings → Privacy & Security ("Open Anyway").
#
#   RB_SIGN_IDENTITY    override the signing identity (default: the Developer ID if present, else
#                       "-", ad hoc, so the local development identity never leaks into a release)
#   RB_NOTARY_PROFILE   notarytool keychain profile (default "reelbird-notary"; create it once with
#                       `xcrun notarytool store-credentials reelbird-notary --key … --key-id … --issuer …`)
#   RB_NOTARIZE=0       sign with the Developer ID but skip notarization (for a quick local check)
#   RB_SCRATCH          separate build directory, as for the other scripts
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=packaging/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CODE_VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ReelbirdCore/Settings.swift)"
if [ "$VERSION" != "$CODE_VERSION" ]; then
  echo "Version mismatch: $PLIST says $VERSION, ReelbirdInfo.version says $CODE_VERSION. Make them match first." >&2
  exit 1
fi

DEVID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
IDENTITY="${RB_SIGN_IDENTITY:-${DEVID:--}}"
RB_CONFIG=release RB_SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh

APP=build/Reelbird.app
ZIP="build/Reelbird-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"

NOTARIZED=no
case "$IDENTITY" in "Developer ID Application:"*)
  if [ "${RB_NOTARIZE:-1}" != 0 ]; then
    PROFILE="${RB_NOTARY_PROFILE:-reelbird-notary}"
    # Apple notarizes a zip of the app; the ticket is then stapled to the app itself, so the
    # download opens offline too. The zip people download is made after stapling.
    UPLOAD="build/Reelbird-$VERSION-notarize.zip"
    ditto -c -k --keepParent --norsrc --noextattr "$APP" "$UPLOAD"
    echo "Submitting to Apple's notary service (usually a few minutes)…"
    OUT="$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait --output-format json)" || true
    rm -f "$UPLOAD"
    ID="$(printf '%s' "$OUT" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')"
    STATUS="$(printf '%s' "$OUT" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p')"
    if [ "$STATUS" != "Accepted" ]; then
      echo "Notarization failed (status: ${STATUS:-unknown}). Apple's log:" >&2
      [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
      [ -z "$ID" ] && printf '%s\n' "$OUT" >&2
      exit 1
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    NOTARIZED=yes
  fi
;; esac
# --keepParent puts Reelbird.app at the top of the archive; --norsrc and --noextattr keep
# Finder metadata and quarantine flags from the build machine out of it.
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$ZIP"
(cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '), $(lipo -archs "$APP/Contents/MacOS/Reelbird"), signed with: $IDENTITY, notarized: $NOTARIZED)"
cat "$ZIP.sha256"

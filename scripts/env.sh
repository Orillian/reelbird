#!/usr/bin/env bash
# Source this before running `swift build` / `swift test`:  source scripts/env.sh
#
# Some Command Line Tools installs ship a stale PackageDescription
# `*.private.swiftinterface` from an older release, which makes every
# Package.swift fail to link ("symbol(s) not found ... Package.__allocating_init").
# If that is detected, point SwiftPM at a cleaned copy of the manifest
# libraries in ~/Library/Caches. System files are never modified.

_rb_pm="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/pm"
if [ -d "$_rb_pm/ManifestAPI" ] && ls "$_rb_pm"/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface >/dev/null 2>&1; then
  _rb_cache="$HOME/Library/Caches/reelbird/swiftpm-libs"
  _rb_stamp="$(stat -f %m "$_rb_pm/ManifestAPI/libPackageDescription.dylib" 2>/dev/null)"
  if [ ! -f "$_rb_cache/.stamp" ] || [ "$(cat "$_rb_cache/.stamp")" != "$_rb_stamp" ]; then
    rm -rf "$_rb_cache" && mkdir -p "$_rb_cache"
    cp -R "$_rb_pm"/ManifestAPI "$_rb_pm"/PluginAPI "$_rb_cache"/ 2>/dev/null
    [ -d "$_rb_pm/llbuild" ] && cp -R "$_rb_pm/llbuild" "$_rb_cache"/
    find "$_rb_cache" -name '*.private.swiftinterface' -delete
    echo "$_rb_stamp" > "$_rb_cache/.stamp"
  fi
  export SWIFTPM_CUSTOM_LIBS_DIR="$_rb_cache"
fi
unset _rb_pm _rb_cache _rb_stamp

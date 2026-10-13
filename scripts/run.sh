#!/usr/bin/env bash
# Quits a running Reelbird, rebuilds build/Reelbird.app and opens it. For trying changes without installing.
#   scripts/run.sh            rebuild, then open
#   scripts/run.sh --no-build open the last build
set -euo pipefail
cd "$(dirname "$0")/.."
osascript -e 'tell application id "app.reelbird.Reelbird" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "Reelbird.app/Contents/MacOS/Reelbird" >/dev/null || break; sleep 0.5; done
[ "${1:-}" = "--no-build" ] || scripts/build-app.sh
open build/Reelbird.app

#!/usr/bin/env bash
# Runs the test suite. Extra arguments go to `swift test`, e.g. scripts/test.sh --filter ReelbirdShareTests
# Set RB_SCRATCH to use a separate build directory (parallel worktrees).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
PLUGINS="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host/plugins/testing"
ARGS=()
[ -d "$PLUGINS" ] && ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
[ -n "${RB_SCRATCH:-}" ] && ARGS+=(--scratch-path "$RB_SCRATCH")
exec swift test ${ARGS[@]+"${ARGS[@]}"} "$@"

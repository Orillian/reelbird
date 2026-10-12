#!/usr/bin/env bash
# Builds everything (debug). Extra arguments go to `swift build`, e.g. scripts/build.sh -c release
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
ARGS=()
[ -n "${RB_SCRATCH:-}" ] && ARGS+=(--scratch-path "$RB_SCRATCH")
exec swift build ${ARGS[@]+"${ARGS[@]}"} "$@"

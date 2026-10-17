#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
QUALITY_GATE="${SCRIPT_DIR}/quality-gate.sh"

check() {
  CHECK_ARGS=("$@")
}

harness() {
  :
}

APP_BINARY="/tmp/marquee-test-app"
LEGACY_CACHE_DIR="/tmp/marquee-test-legacy-cache"
CHECK_ARGS=()
eval "$(awk '/^run_catalog_suite\(\)/,/^}/' "${QUALITY_GATE}")"
run_catalog_suite

[ "${CHECK_ARGS[0]}" = "legacy import" ]
[ "${CHECK_ARGS[1]}" = "env" ]
[ "${CHECK_ARGS[2]}" = "MARQUEE_LEGACY_CACHE_DIR=${LEGACY_CACHE_DIR}" ]
[ "${CHECK_ARGS[3]}" = "${APP_BINARY}" ]
[ "${CHECK_ARGS[4]}" = "--verify-legacy-import" ]

echo "PASS: legacy-import quality-gate command shape"

#!/usr/bin/env bash

set -uo pipefail
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)"
PACKAGE_ROOT="${REPO_ROOT}"
BUILD_DIR="${REPO_ROOT}/build/toolchain-gate"

usage() {
  cat <<'USAGE'
Usage: ./scripts/quality-gate.sh --toolchain [--full | --suite NAME ...]
                                 [--save]

Runs the SwiftPM deterministic harness target with the Swift toolchain only.
This path does not invoke Xcode, xcodebuild, or the Marquee app bundle.

Modes:
  --full          Run every package-covered deterministic harness (default).
  --suite NAME    Run package-covered harnesses for a focused suite.
  --save          Keep the log under build/logs/.
  --list-suites   Print focused suite names.
USAGE
}

die() {
  echo "toolchain-quality-gate: $*" >&2
  exit 2
}

MODE="full"
SAVE=0
SELECTED_SUITES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --full) MODE="full"; shift ;;
    --suite) [ "$#" -ge 2 ] || die "--suite requires a name"; MODE="focused"; SELECTED_SUITES+=("$2"); shift 2 ;;
    --suite=*) MODE="focused"; SELECTED_SUITES+=("${1#--suite=}"); shift ;;
    --save) SAVE=1; shift ;;
    --list-suites) echo "search focus browse image catalog playback diagnostics"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v swift >/dev/null 2>&1 || die "swift is required"
[ -f "${PACKAGE_ROOT}/Package.swift" ] || die "missing Package.swift"

# macOS ships bash 3.2, which lacks associative arrays; map suites in a case.
suite_args_for() {
  case "$1" in
    browse) printf '%s' "--verify-browse-snapshots" ;;
    search) printf '%s' "--verify-search-input-buffer --verify-search-results-update-policy --verify-search-remote-keyboard --verify-search-field-responder-sync --verify-search-keyboard-event-routing --verify-search-session" ;;
    focus) printf '%s' "--verify-focus-engine --verify-detail-focus-engine --verify-hud-focus-policy --verify-profile-picker-focus-tree" ;;
    catalog) printf '%s' "--verify-transactions --verify-scanner --verify-projection --verify-enrichment --verify-enrichment-actor --verify-scan-request-gate --verify-volumes --verify-duration-probe --verify-filename-parser" ;;
    image) printf '%s' "--verify-image-pipeline" ;;
    playback) printf '%s' "--verify-playback-state --verify-subtitles" ;;
    diagnostics) printf '%s' "--verify-configuration --verify-diagnostics" ;;
    *) return 1 ;;
  esac
}

if [ "${#SELECTED_SUITES[@]}" -gt 0 ]; then
  for suite in "${SELECTED_SUITES[@]}"; do
    suite_args_for "${suite}" >/dev/null || die "unknown suite: ${suite}"
  done
fi

if [ "${MODE}" = "full" ]; then
  HARNESS_ARGS=(
    --verify-focus-engine
    --verify-detail-focus-engine
    --verify-hud-focus-policy
    --verify-profile-picker-focus-tree
    --verify-transactions
    --verify-scanner
    --verify-projection
    --verify-enrichment
    --verify-enrichment-actor
    --verify-scan-request-gate
    --verify-volumes
    --verify-duration-probe
    --verify-filename-parser
    --verify-search-input-buffer
    --verify-search-results-update-policy
    --verify-search-remote-keyboard
    --verify-search-field-responder-sync
    --verify-search-keyboard-event-routing
    --verify-search-session
    --verify-playback-state
    --verify-subtitles
    --verify-image-pipeline
    --verify-configuration
    --verify-diagnostics
    --verify-browse-snapshots
  )
else
  HARNESS_ARGS=()
  for suite in "${SELECTED_SUITES[@]}"; do
    suite_words="$(suite_args_for "${suite}")"
    [ -n "${suite_words}" ] || continue
    # shellcheck disable=SC2086
    set -- ${suite_words}
    HARNESS_ARGS+=("$@")
  done
  [ "${#HARNESS_ARGS[@]}" -gt 0 ] \
    || die "selected suites have no toolchain-covered harnesses"
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SCRATCH_ROOT="$(mktemp -d "${BUILD_DIR}/scratch.XXXXXX" 2>/dev/null)" \
  || { mkdir -p "${BUILD_DIR}"; SCRATCH_ROOT="$(mktemp -d "${BUILD_DIR}/scratch.XXXXXX")"; }
SIDECAR_ROOT="${SCRATCH_ROOT}/sidecar"
mkdir -p "${SIDECAR_ROOT}/verify-reports"
if [ "${SAVE}" -eq 1 ]; then
  LOG_FILE="${REPO_ROOT}/build/logs/toolchain-quality-gate-${RUN_ID}.log"
  mkdir -p "$(dirname "${LOG_FILE}")"
else
  LOG_FILE="${SCRATCH_ROOT}/quality-gate.log"
fi
exec 3>&1
cleanup() {
  rm -rf -- "${SCRATCH_ROOT}"
}
trap cleanup EXIT

run_count=0
failures=0
echo "Marquee toolchain quality gate: mode=${MODE}" | tee "${LOG_FILE}"
echo "Package: ${PACKAGE_ROOT}" | tee -a "${LOG_FILE}"
echo "Covered harnesses: ${#HARNESS_ARGS[@]}" | tee -a "${LOG_FILE}"

for argument in "${HARNESS_ARGS[@]}"; do
  run_count=$((run_count + 1))
  echo "===== ${argument} =====" | tee -a "${LOG_FILE}"
  if MARQUEE_SIDECAR_ROOT="${SIDECAR_ROOT}" \
     MARQUEE_VERIFY_REPORTS_DIR="${SIDECAR_ROOT}/verify-reports" \
     swift run --package-path "${PACKAGE_ROOT}" marquee-toolchain-gate "${argument}" \
     2>&1 | tee -a "${LOG_FILE}"; then
    echo "PASS: ${argument}" | tee -a "${LOG_FILE}"
  else
    failures=$((failures + 1))
    echo "FAIL: ${argument}" | tee -a "${LOG_FILE}"
  fi
done

echo "Excluded from toolchain path (app-bundle or release-only):" | tee -a "${LOG_FILE}"
cat <<'EXCLUDED' | tee -a "${LOG_FILE}"
  profile: the picker harness drives a real AppKit key window; needs a
    display session
  remote-input full matrix: animated AppKit scroll placement needs a display
    session; the pure policy subset runs as --verify-hud-focus-policy
  legacy-import: reads a real legacy library cache from Application Support,
    absent on a clean gate host
  audio: audio identity packs are app-bundle resources
  release-only: visual QA fixture, native visual/timing tours, and the
    synthetic playback matrix (app bundle/MPVKit playback runtime)
EXCLUDED

echo "summary=mode=${MODE} harnesses=${run_count} failures=${failures}" | tee -a "${LOG_FILE}"
echo "log=${LOG_FILE}" | tee -a "${LOG_FILE}"
[ "${failures}" -eq 0 ]

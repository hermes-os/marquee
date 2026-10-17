#!/usr/bin/env bash
#
# Record an os_signpost trace of the QA build for the perf hot paths
# (subsystem com.marquee.app, category perf):
#   profile-select, recompute-filtered, recompute-progress-rows,
#   search-publish, route-switch, route-appeared, detail-appeared,
#   playback-start.
#
# Usage:
#   ./scripts/perf-trace.sh                 # 45s interactive trace, drive the app by hand/R2
#   ./scripts/perf-trace.sh --timing-tour   # traces one --qa-timing-tour run end to end
#
# Open the result with: open <trace>  (Instruments -> os_signpost lane,
# filter subsystem com.marquee.app). Export intervals as CSV via
#   xcrun xctrace export --input <trace> --xpath '//trace-toc'

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="${REPO_ROOT}/build/qa/Marquee.app/Contents/MacOS/Marquee"
STAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_OUT="${TMPDIR:-/tmp}/marquee-perf-${STAMP}.trace"

if [ ! -x "${APP_BINARY}" ]; then
  echo "QA app not built. Run ./scripts/build-qa-app.sh --with-harnesses first." >&2
  exit 1
fi

if [ "${1:-}" = "--timing-tour" ]; then
  QA_DIR="${TMPDIR:-/tmp}/marquee-timing-tour-${STAMP}"
  xcrun xctrace record \
    --template 'Blank' \
    --instrument 'os_signpost' \
    --output "${TRACE_OUT}" \
    --launch -- "${APP_BINARY}" --qa-timing-tour --qa-output-dir "${QA_DIR}"
  echo "timing manifest: ${QA_DIR}/manifest.json"
else
  xcrun xctrace record \
    --template 'Blank' \
    --instrument 'os_signpost' \
    --time-limit 45s \
    --output "${TRACE_OUT}" \
    --launch -- "${APP_BINARY}"
fi

echo "trace: ${TRACE_OUT}"

#!/usr/bin/env bash

set -uo pipefail
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)"

if [ "${1:-}" = "--toolchain" ]; then
  shift
  exec "${SCRIPT_DIR}/toolchain-quality-gate.sh" "$@"
fi
PROJECT="${REPO_ROOT}/Marquee.xcodeproj"
SCHEME="Marquee"
DERIVED_DATA="${REPO_ROOT}/build/quality-gate/DerivedData"
RELEASE_DERIVED_DATA="${REPO_ROOT}/build/quality-gate/ReleaseDerivedData"
BINARY_CACHE="${REPO_ROOT}/build/quality-gate/app-binary.path"
FINGERPRINT_CACHE="${REPO_ROOT}/build/quality-gate/build-inputs.sha256"

# shellcheck source=lib/bundle-safety.sh
source "${SCRIPT_DIR}/lib/bundle-safety.sh"

usage() {
  cat <<'USAGE'
Usage: ./scripts/quality-gate.sh [--full | --release | --suite NAME ...]
                                 [--no-build] [--save]
       ./scripts/quality-gate.sh --toolchain [--full | --suite NAME ...]

Modes:
  --full          Build once and run every deterministic harness (default).
  --suite NAME    Build once and run a focused suite. May be repeated.
  --release       Run --full plus synthetic playback and native visual QA.
  --toolchain     Run the SwiftPM harness path without Xcode or xcodebuild.

Suites:
  search, focus, browse, profile, image, audio, catalog, playback, diagnostics

Options:
  --no-build      Reuse only an exact, fingerprint-matched cached Debug app.
  --save          Keep the log and release artifacts under build/logs/.
  --list-suites   Print focused suite names.
  -h, --help      Show this help.

Examples:
  ./scripts/quality-gate.sh --suite image --suite browse
  ./scripts/quality-gate.sh --suite audio --no-build --save
  ./scripts/quality-gate.sh --release --save
USAGE
}

die() {
  echo "quality-gate: $*" >&2
  exit 2
}

MODE="full"
MODE_SET=0
NO_BUILD=0
SAVE=0
SELECTED_SUITES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --full|--release)
      [ "${MODE_SET}" -eq 0 ] && [ "${#SELECTED_SUITES[@]}" -eq 0 ] \
        || die "choose only one of --full, --release, or --suite"
      MODE="${1#--}"
      MODE_SET=1
      shift
      ;;
    --suite)
      [ "${MODE_SET}" -eq 0 ] || die "--suite cannot be combined with --${MODE}"
      [ "$#" -ge 2 ] || die "--suite requires a name"
      MODE="focused"
      SELECTED_SUITES+=("$2")
      shift 2
      ;;
    --suite=*)
      [ "${MODE_SET}" -eq 0 ] || die "--suite cannot be combined with --${MODE}"
      MODE="focused"
      SELECTED_SUITES+=("${1#--suite=}")
      shift
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --save)
      SAVE=1
      shift
      ;;
    --list-suites)
      echo "search focus browse profile image audio catalog playback diagnostics"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [ "${MODE}" = "focused" ]; then
  [ "${#SELECTED_SUITES[@]}" -gt 0 ] || die "focused mode needs at least one suite"
  for suite in "${SELECTED_SUITES[@]}"; do
    case "${suite}" in
      search|focus|browse|profile|image|audio|catalog|playback|diagnostics) ;;
      *) die "unknown suite: ${suite}" ;;
    esac
  done
fi

[ -d "${PROJECT}" ] || die "missing Xcode project: ${PROJECT}"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"

mkdir -p "${REPO_ROOT}/build/tmp" "${REPO_ROOT}/build/quality-gate"
SCRATCH_ROOT="$(mktemp -d "${REPO_ROOT}/build/tmp/marquee-quality-gate.XXXXXX")" \
  || die "could not allocate scratch directory"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
OWNED_HELPER_PID_REGISTRY="${SCRATCH_ROOT}/owned-helper-pid-files"
: > "${OWNED_HELPER_PID_REGISTRY}"
OWNED_GUI_PID_REGISTRY="${SCRATCH_ROOT}/owned-gui-pids"
: > "${OWNED_GUI_PID_REGISTRY}"
ACTIVE_STEP_PGID=""

terminate_fixture_pid() {
  local pid="$1"
  local command
  local attempt=0
  case "${pid}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill -0 "${pid}" 2>/dev/null || return 0
  command="$(ps -o command= -p "${pid}" 2>/dev/null || true)"
  case "${command}" in
    *"${SCRATCH_ROOT}/playback-fixtures/"*) ;;
    *) return 0 ;;
  esac
  kill -TERM "${pid}" 2>/dev/null || true
  while [ "${attempt}" -lt 20 ]; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  kill -KILL "${pid}" 2>/dev/null || true
}

terminate_gui_pid() {
  local pid="$1"
  local attempt=0
  case "${pid}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill -0 "${pid}" 2>/dev/null || return 0
  kill -TERM "${pid}" 2>/dev/null || true
  while [ "${attempt}" -lt 20 ]; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  kill -KILL "${pid}" 2>/dev/null || true
}

terminate_active_step() {
  local signal="${1:-TERM}"
  local pgid="${ACTIVE_STEP_PGID:-}"
  local attempt=0
  case "${pgid}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill "-${signal}" -- "-${pgid}" 2>/dev/null || true
  while [ "${attempt}" -lt 20 ]; do
    kill -0 -- "-${pgid}" 2>/dev/null || break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 -- "-${pgid}" 2>/dev/null; then
    kill -KILL -- "-${pgid}" 2>/dev/null || true
  fi
  wait "${pgid}" 2>/dev/null || true
  ACTIVE_STEP_PGID=""
}

handle_signal() {
  local signal="$1"
  local status="$2"
  trap - HUP INT TERM
  terminate_active_step "${signal}"
  exit "${status}"
}

cleanup() {
  local pid_file
  local pid
  terminate_active_step TERM
  if [ -f "${OWNED_HELPER_PID_REGISTRY:-}" ]; then
    while IFS= read -r pid_file; do
      [ -s "${pid_file}" ] || continue
      pid="$(cat "${pid_file}" 2>/dev/null || true)"
      terminate_fixture_pid "${pid}"
    done < "${OWNED_HELPER_PID_REGISTRY}"
  fi
  if [ -f "${OWNED_GUI_PID_REGISTRY:-}" ]; then
    while IFS= read -r pid; do
      terminate_gui_pid "${pid}"
    done < "${OWNED_GUI_PID_REGISTRY}"
  fi
  case "${SCRATCH_ROOT:-}" in
    "${REPO_ROOT}/build/tmp/marquee-quality-gate."*)
      rm -rf -- "${SCRATCH_ROOT}"
      ;;
  esac
  if [ "${SAVE:-0}" -eq 0 ]; then
    case "${LOG_FILE:-}" in
      "${TEMP_ROOT}/marquee-quality-gate-"*.log)
        rm -f -- "${LOG_FILE}"
        ;;
    esac
  fi
  rm -f -- "${BINARY_CACHE}.tmp.$$" "${FINGERPRINT_CACHE}.tmp.$$"
}
trap cleanup EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
if [ "${SAVE}" -eq 1 ]; then
  ARTIFACT_ROOT="${REPO_ROOT}/build/logs/quality-gate-${RUN_ID}"
  mkdir -p "${ARTIFACT_ROOT}"
  LOG_FILE="${ARTIFACT_ROOT}/quality-gate.log"
else
  ARTIFACT_ROOT="${SCRATCH_ROOT}/artifacts"
  mkdir -p "${ARTIFACT_ROOT}"
  LOG_FILE="${TEMP_ROOT}/marquee-quality-gate-${RUN_ID}.log"
fi
: > "${LOG_FILE}"

SIDECAR_ROOT="${SCRATCH_ROOT}/sidecar"
export MARQUEE_SIDECAR_ROOT="${SIDECAR_ROOT}"
export MARQUEE_PLAYBACK_CACHE_DIR="${SIDECAR_ROOT}/playback-cache"
export MARQUEE_VERIFY_REPORTS_DIR="${SIDECAR_ROOT}/verify-reports"
mkdir -p "${MARQUEE_PLAYBACK_CACHE_DIR}" "${MARQUEE_VERIFY_REPORTS_DIR}"

STEP_COUNT=0
FAILURES=0
STARVED=0
STEP_NAMES=()
STEP_RESULTS=()
STEP_SECONDS=()

run_step() {
  local label="$1"
  shift
  local started="${SECONDS}"
  local statuses
  local command_status
  local tee_status
  local wrapper_status
  local status_file="${SCRATCH_ROOT}/step-${STEP_COUNT}.status"
  local elapsed
  local result

  echo "===== ${label} =====" | tee -a "${LOG_FILE}"
  rm -f -- "${status_file}"
  set -m
  (
    set +m
    "$@" 2>&1 | tee -a "${LOG_FILE}"
    statuses=("${PIPESTATUS[@]}")
    printf '%s %s\n' "${statuses[0]}" "${statuses[1]}" > "${status_file}"
  ) &
  ACTIVE_STEP_PGID=$!
  set +m
  if wait "${ACTIVE_STEP_PGID}"; then
    wrapper_status=0
  else
    wrapper_status=$?
  fi
  ACTIVE_STEP_PGID=""
  if ! read -r command_status tee_status < "${status_file}"; then
    command_status="${wrapper_status}"
    tee_status=0
  fi
  elapsed=$((SECONDS - started))
  result="PASS"
  if [ "${command_status}" -eq 137 ] || [ "${tee_status}" -eq 137 ]; then
    result="STARVED"
    STARVED=1
  elif [ "${command_status}" -ne 0 ] || [ "${tee_status}" -ne 0 ]; then
    result="FAIL"
  fi

  STEP_NAMES[${STEP_COUNT}]="${label}"
  STEP_RESULTS[${STEP_COUNT}]="${result}"
  STEP_SECONDS[${STEP_COUNT}]="${elapsed}"
  STEP_COUNT=$((STEP_COUNT + 1))
  echo "${result}: ${label} (${elapsed}s)" | tee -a "${LOG_FILE}"
  [ "${result}" = "PASS" ]
}

check() {
  if ! run_step "$@"; then
    FAILURES=$((FAILURES + 1))
    if [ "${STARVED}" -eq 1 ]; then
      print_summary
      exit 137
    fi
  fi
  return 0
}

print_summary() {
  local index=0
  local total=0
  echo | tee -a "${LOG_FILE}"
  echo "===== timing summary =====" | tee -a "${LOG_FILE}"
  while [ "${index}" -lt "${STEP_COUNT}" ]; do
    printf '%-7s %5ss  %s\n' \
      "${STEP_RESULTS[${index}]}" "${STEP_SECONDS[${index}]}" "${STEP_NAMES[${index}]}" \
      | tee -a "${LOG_FILE}"
    total=$((total + STEP_SECONDS[index]))
    index=$((index + 1))
  done
  echo "mode=${MODE} steps=${STEP_COUNT} failures=${FAILURES} elapsed=${total}s" \
    | tee -a "${LOG_FILE}"
  echo "log=${LOG_FILE}" | tee -a "${LOG_FILE}"
  if [ "${SAVE}" -eq 1 ]; then
    echo "saved=${ARTIFACT_ROOT}" | tee -a "${LOG_FILE}"
  fi
}

build_input_fingerprint() {
  local file
  local vendor="Vendor/MPVKit-local"
  [ -d "${REPO_ROOT}/${vendor}" ] || return 1
  (
    set -o pipefail
    cd "${REPO_ROOT}" || exit 1
    printf '%s\n' 'tracked-index' || exit 1
    git ls-files -s -- Marquee Marquee.xcodeproj || exit 1
    printf '%s\n' 'tracked-worktree' || exit 1
    git diff --no-ext-diff --binary -- Marquee Marquee.xcodeproj || exit 1
    printf '%s\n' 'untracked-worktree' || exit 1
    if ! git ls-files -z --others --exclude-standard -- Marquee Marquee.xcodeproj \
      | while IFS= read -r -d '' file; do
          case "${file}" in
            Secrets.plist|*/Secrets.plist) continue ;;
          esac
          shasum -a 256 "${file}" || exit 1
        done; then
      exit 1
    fi
    if ! find "${vendor}/Package.swift" "${vendor}/Sources" -type f -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          shasum -a 256 "${file}" || exit 1
        done; then
      exit 1
    fi
    # The generated framework payload is roughly 3 GB. Xcode owns compile
    # dependency tracking; the gate records stable file identity for exact
    # cached-binary invalidation without rereading that payload twice per
    # focused build. Size/timestamps catch in-place writes, while ctime/inode
    # also catch ordinary same-size replacement.
    if ! find "${vendor}/Frameworks" -type f \
      \( -path '*/macos-*/*' -o -name Info.plist \) \
      -exec stat -f 'framework %N size=%z mtime=%m ctime=%c inode=%i' {} + \
      | LC_ALL=C sort; then
      exit 1
    fi
    if ! find "${vendor}/Package.swift" "${vendor}/Sources" -type l -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          target="$(readlink "${file}")" || exit 1
          printf 'vendor-symlink %s -> %s\n' "${file}" "${target}" || exit 1
        done; then
      exit 1
    fi
    if ! find "${vendor}/Frameworks" -type l \
      \( -path '*/macos-*/*' -o -name Info.plist \) -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          target="$(readlink "${file}")" || exit 1
          printf 'symlink %s -> %s\n' "${file}" "${target}" || exit 1
        done; then
      exit 1
    fi
  ) | shasum -a 256 | awk '{print $1}'
}

cache_current_binary() {
  local expected_fingerprint="$1"
  local expected="${DERIVED_DATA}/Build/Products/Debug/Marquee.app/Contents/MacOS/Marquee"
  local current_fingerprint
  local binary_tmp="${BINARY_CACHE}.tmp.$$"
  local fingerprint_tmp="${FINGERPRINT_CACHE}.tmp.$$"
  [ -x "${expected}" ] || die "Debug app binary not found after build: ${expected}"
  current_fingerprint="$(build_input_fingerprint)" \
    || die "could not fingerprint build inputs after build"
  if [ -z "${expected_fingerprint}" ] \
    || [ "${expected_fingerprint}" != "${current_fingerprint}" ]; then
    rm -f -- "${BINARY_CACHE}" "${FINGERPRINT_CACHE}"
    die "build inputs changed during the Debug build; rerun the gate"
  fi
  APP_BINARY="${expected}"
  printf '%s\n' "${APP_BINARY}" > "${binary_tmp}"
  printf '%s\n' "${current_fingerprint}" > "${fingerprint_tmp}"
  mv -f -- "${binary_tmp}" "${BINARY_CACHE}"
  mv -f -- "${fingerprint_tmp}" "${FINGERPRINT_CACHE}"
}

load_cached_binary() {
  local cached_fingerprint
  local current_fingerprint
  [ -s "${BINARY_CACHE}" ] && [ -s "${FINGERPRINT_CACHE}" ] \
    || die "--no-build requires a prior successful quality-gate build"
  IFS= read -r APP_BINARY < "${BINARY_CACHE}"
  case "${APP_BINARY}" in
    "${DERIVED_DATA}/"*) ;;
    *) die "cached app binary escaped the gate DerivedData directory" ;;
  esac
  [ -x "${APP_BINARY}" ] || die "cached app binary is missing: ${APP_BINARY}"
  cached_fingerprint="$(tr -d '[:space:]' < "${FINGERPRINT_CACHE}")"
  current_fingerprint="$(build_input_fingerprint)" \
    || die "could not fingerprint current build inputs"
  [ -n "${cached_fingerprint}" ] && [ "${cached_fingerprint}" = "${current_fingerprint}" ] \
    || die "--no-build rejected a stale app; build inputs changed"
}

wants_suite() {
  local requested="$1"
  local suite
  if [ "${MODE}" = "full" ] || [ "${MODE}" = "release" ]; then
    return 0
  fi
  for suite in "${SELECTED_SUITES[@]}"; do
    [ "${suite}" = "${requested}" ] && return 0
  done
  return 1
}

harness() {
  local label="$1"
  shift
  check "${label}" "${APP_BINARY}" "$@"
}

run_search_suite() {
  harness "search input buffer" --verify-search-input-buffer
  harness "search results update policy" --verify-search-results-update-policy
  harness "search remote keyboard" --verify-search-remote-keyboard
  harness "search field responder sync" --verify-search-field-responder-sync
  harness "search keyboard event routing" --verify-search-keyboard-event-routing
  harness "search session" --verify-search-session
}

run_focus_suite() {
  harness "remote input" --verify-remote-input
  harness "focus engine" --verify-focus-engine
  harness "detail focus engine" --verify-detail-focus-engine
}

run_browse_suite() {
  harness "browse snapshots" --verify-browse-snapshots
  harness "visual QA fixture" --verify-visual-qa-fixture
}

run_profile_suite() {
  local output_directory="${ARTIFACT_ROOT}/profile-picker"
  local tour_sidecar="${SCRATCH_ROOT}/sidecar-profile-picker"
  local profile_picker_png="${output_directory}/profile-picker.png"
  local result_artifact="${output_directory}/profile-picker-result.txt"
  mkdir -p "${tour_sidecar}/playback-cache" "${tour_sidecar}/verify-reports" \
    "${output_directory}"
  check "profile picker" run_gui_app \
    "profile picker" --verify-profile-picker "${output_directory}" 120 \
    "${tour_sidecar}" "${profile_picker_png}"
  check "profile picker result artifact" verify_profile_result_artifact \
    "${result_artifact}"
}

run_image_suite() {
  harness "image pipeline" --verify-image-pipeline
}

curated_audio_candidates_present() {
  local sounds="${REPO_ROOT}/Marquee/Resources/Sounds"
  [ -e "${REPO_ROOT}/scripts/verify-audio-identity-packs.sh" ] \
    || [ -e "${sounds}/CuratedPacks.sha256" ] \
    || find "${sounds}" -mindepth 1 -maxdepth 1 -type d \
      -name 'CuratedPacks-*' -print -quit 2>/dev/null | grep -q .
}

run_audio_suite() {
  local verifier="${REPO_ROOT}/scripts/verify-audio-identity-packs.sh"
  local manifest="${REPO_ROOT}/Marquee/Resources/Sounds/CuratedPacks.sha256"
  if curated_audio_candidates_present; then
    check "audio identity pack verifier present" test -f "${verifier}"
    check "audio identity pack manifest present" test -f "${manifest}"
    if [ -f "${verifier}" ] && [ -f "${manifest}" ]; then
      check "audio identity pack assets" bash "${verifier}"
    fi
  else
    echo "SKIP: curated audio packs are not present on this revision" | tee -a "${LOG_FILE}"
  fi
  harness "audio identity" --verify-audio-identity
}

run_catalog_suite() {
  check "legacy import" env \
    MARQUEE_LEGACY_CACHE_DIR="${LEGACY_CACHE_DIR}" \
    "${APP_BINARY}" --verify-legacy-import
  harness "catalog transactions" --verify-transactions
  harness "volume registry" --verify-volumes
  harness "catalog scanner" --verify-scanner
  harness "catalog projection" --verify-projection
  harness "catalog enrichment" --verify-enrichment
  harness "catalog enrichment actor" --verify-enrichment-actor
  harness "duration probe" --verify-duration-probe
  harness "scan request gate" --verify-scan-request-gate
  harness "filename parser" --verify-filename-parser
}

prepare_legacy_import_fixture() {
  local source_dir="${REPO_ROOT}/scripts/fixtures/legacy-import"
  LEGACY_CACHE_DIR="${SCRATCH_ROOT}/legacy-import-cache"
  [ -d "${source_dir}" ] || die "missing legacy-import fixture directory"
  mkdir -p "${LEGACY_CACHE_DIR}" || die "could not create legacy-import fixture directory"
  for name in library-cache-movies.json library-cache-tv.json; do
    [ -s "${source_dir}/${name}" ] \
      || die "missing or empty legacy-import fixture: ${source_dir}/${name}"
    cp "${source_dir}/${name}" "${LEGACY_CACHE_DIR}/${name}" \
      || die "could not stage legacy-import fixture: ${name}"
    [ -s "${LEGACY_CACHE_DIR}/${name}" ] \
      || die "staged legacy-import fixture is empty: ${name}"
  done
}

run_playback_suite() {
  harness "playback state" --verify-playback-state
  harness "playback cache" --verify-playback-cache
  harness "subtitles" --verify-subtitles
}

run_diagnostics_suite() {
  harness "configuration" --verify-configuration
  harness "diagnostics" --verify-diagnostics
}

verify_tour_artifacts() {
  local directory="$1"
  [ -s "${directory}/manifest.json" ] || return 1
  find "${directory}" -type f -name '*.png' -size +0 -print -quit | grep -q .
}

verify_timing_artifacts() {
  local directory="$1"
  [ -s "${directory}/manifest.json" ]
}

verify_profile_result_artifact() {
  local artifact="$1"
  if [ ! -f "${artifact}" ]; then
    return 1
  fi
  if [ "$(<"${artifact}")" = $'schema=marquee-profile-picker-result-v1\noutcome=verified\npassed=9/9' ]; then
    return 0
  fi
  if grep -Fx 'outcome=failed' "${artifact}" >/dev/null; then
    local diagnostic
    diagnostic="$(sed -n 's/^message=//p' "${artifact}" | head -n 1)"
    if [ -n "${diagnostic}" ]; then
      echo "profile picker harness failure: ${diagnostic}" >&2
    else
      echo "profile picker harness failure artifact: ${artifact}" >&2
    fi
  fi
  return 1
}

gui_app_pids() {
  pgrep -f -- "${APP_BINARY}" 2>/dev/null || true
}

terminate_owned_gui_processes() {
  local existing_pids="$1"
  local pid
  while read -r pid; do
    case " ${existing_pids} " in
      *" ${pid} "*) ;;
      *) echo "${pid}" >> "${OWNED_GUI_PID_REGISTRY}"; terminate_gui_pid "${pid}" ;;
    esac
  done < <(gui_app_pids)
}

run_gui_app() {
  local label="$1"
  local launch_argument="$2"
  local output_directory="$3"
  local deadline_seconds="$4"
  local tour_sidecar="$5"
  local profile_picker_png="${6:-}"
  local app_bundle="${APP_BINARY%/Contents/MacOS/Marquee}"
  local open_pid
  local open_status
  local started
  local existing_pids

  [ -d "${app_bundle}" ] || {
    echo "${label}: app bundle missing: ${app_bundle}" >&2
    return 1
  }
  mkdir -p "${output_directory}"
  [ -z "${profile_picker_png}" ] || rm -f -- "${profile_picker_png}"
  existing_pids="$(gui_app_pids)"
  if [ -n "${profile_picker_png}" ]; then
    open --env "MARQUEE_VERIFY_PROFILE_PICKER_PNG=${profile_picker_png}" \
      -n -W "${app_bundle}" --args \
      "${launch_argument}" --qa-output-dir "${output_directory}" \
      --qa-search-query alien --qa-sidecar-root "${tour_sidecar}" &
  else
    open -n -W "${app_bundle}" --args \
      "${launch_argument}" --qa-output-dir "${output_directory}" \
      --qa-search-query alien --qa-sidecar-root "${tour_sidecar}" &
  fi
  open_pid=$!
  started="${SECONDS}"
  while kill -0 "${open_pid}" 2>/dev/null; do
    if [ $((SECONDS - started)) -ge "${deadline_seconds}" ]; then
      echo "${label}: timed out after ${deadline_seconds}s" >&2
      kill -TERM "${open_pid}" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        terminate_owned_gui_processes "${existing_pids}"
        sleep 0.1
      done
      wait "${open_pid}" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
  if wait "${open_pid}"; then
    open_status=0
  else
    open_status=$?
  fi
  terminate_owned_gui_processes "${existing_pids}"
  [ "${open_status}" -eq 0 ] || {
    echo "${label}: LaunchServices exited with status ${open_status}" >&2
    return 1
  }
}

run_visual_tour() {
  local label="$1"
  local launch_argument="$2"
  local output_directory="$3"
  local tour_sidecar="${SCRATCH_ROOT}/sidecar-${label// /-}"
  mkdir -p "${tour_sidecar}/playback-cache" "${tour_sidecar}/verify-reports" \
    "${output_directory}"
  check "${label}" run_gui_app \
    "${label}" "${launch_argument}" "${output_directory}" 240 "${tour_sidecar}"
  check "${label} artifacts" verify_tour_artifacts "${output_directory}"
}

run_timing_tour() {
  local output_directory="$1"
  local tour_sidecar="${SCRATCH_ROOT}/sidecar-native-timing-tour"
  mkdir -p "${tour_sidecar}/playback-cache" "${tour_sidecar}/verify-reports" \
    "${output_directory}"
  check "native timing tour" run_gui_app \
    "native timing tour" --qa-timing-tour "${output_directory}" 180 "${tour_sidecar}"
  check "native timing tour artifacts" verify_timing_artifacts "${output_directory}"
}

verify_release_audio_resources() {
  local app_sounds="${RELEASE_DERIVED_DATA}/Build/Products/Release/Marquee.app/Contents/Resources/Sounds"
  local source_sounds="${REPO_ROOT}/Marquee/Resources/Sounds"
  local manifest="${source_sounds}/CuratedPacks.sha256"
  local pack_directory
  local relative
  [ -f "${manifest}" ] || return 1
  [ -f "${app_sounds}/CuratedPacks.sha256" ] || return 1
  cmp "${manifest}" "${app_sounds}/CuratedPacks.sha256" >/dev/null || return 1
  pack_directory="$(awk 'NR == 1 {split($2, parts, "/"); print parts[1]}' "${manifest}")"
  [ -n "${pack_directory}" ] || return 1
  verify_curated_pack_root "${source_sounds}" "${pack_directory}" || return 1
  verify_curated_pack_root "${app_sounds}" "${pack_directory}" || return 1
  while read -r _ relative; do
    [ -n "${relative}" ] || return 1
    cmp "${source_sounds}/${relative}" "${app_sounds}/${relative}" >/dev/null || return 1
  done < "${manifest}"
}

verify_curated_pack_root() {
  local root="$1"
  local pack_directory="$2"
  local pack_path="${root}/${pack_directory}"
  local entries
  entries="$(find "${root}" -mindepth 1 -maxdepth 1 \
    -name 'CuratedPacks-*' -print | LC_ALL=C sort)"
  [ "${entries}" = "${pack_path}" ] || return 1
  [ -d "${pack_path}" ] && [ ! -L "${pack_path}" ] || return 1
  [ "$(find "${pack_path}" -mindepth 1 | wc -l | tr -d ' ')" = "15" ] || return 1
  [ "$(find "${pack_path}" -mindepth 1 -type f | wc -l | tr -d ' ')" = "15" ]
}

pid_is_active() {
  local pid="$1"
  local state
  kill -0 "${pid}" 2>/dev/null || return 1
  state="$(ps -o stat= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
  [ -n "${state}" ] && [[ "${state}" != Z* ]]
}

wait_for_pid_file_exit() {
  local pid_file="$1"
  local pid
  local attempt=0
  [ -s "${pid_file}" ] || return 1
  pid="$(cat "${pid_file}")"
  while [ "${attempt}" -lt 50 ]; do
    pid_is_active "${pid}" || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "helper still active: ${pid}" >&2
  terminate_fixture_pid "${pid}"
  return 1
}

verify_parent_death_cleanup() {
  local fixture="$1"
  local fake_ffmpeg="$2"
  local video_pid_file="$3"
  local audio_pid_file="$4"
  local status
  env \
    MARQUEE_FFMPEG_PATH="${fake_ffmpeg}" \
    MARQUEE_FAKE_EMBEDDED_VIDEO_PID_FILE="${video_pid_file}" \
    MARQUEE_FAKE_EMBEDDED_AUDIO_PID_FILE="${audio_pid_file}" \
    "${APP_BINARY}" --verify-player-runtime "${fixture}" \
      --verify-player-runtime-expect-backend ffmpeg-embedded \
      --verify-player-runtime-require-audio-helper \
      --verify-player-runtime-self-sigkill-after-load
  status=$?
  [ "${status}" -eq 137 ] || {
    echo "expected app self-SIGKILL status 137, got ${status}" >&2
    return 1
  }
  wait_for_pid_file_exit "${video_pid_file}" \
    && wait_for_pid_file_exit "${audio_pid_file}"
}

run_release_playback_matrix() {
  local fixture_root="${SCRATCH_ROOT}/playback-fixtures"
  local ffmpeg
  local ffprobe
  local mp4="${fixture_root}/sample.mp4"
  local webm="${fixture_root}/sample.webm"
  local hevc="${fixture_root}/sample-hevc.mp4"
  local helper_failure="${fixture_root}/helper-failure.webm"
  local failure_ffmpeg="${fixture_root}/fake-helper-failure.sh"
  local failure_pid="${fixture_root}/helper-failure.pid"
  local parent_death="${fixture_root}/parent-death.webm"
  local parent_ffmpeg="${fixture_root}/fake-parent-death.sh"
  local parent_video_pid="${fixture_root}/parent-video.pid"
  local parent_audio_pid="${fixture_root}/parent-audio.pid"

  printf '%s\n' \
    "${failure_pid}" \
    "${parent_video_pid}" \
    "${parent_audio_pid}" \
    >> "${OWNED_HELPER_PID_REGISTRY}"

  ffmpeg="$(command -v ffmpeg || true)"
  ffprobe="$(command -v ffprobe || true)"
  if [ -z "${ffmpeg}" ] || [ -z "${ffprobe}" ]; then
    check "release playback tools" false
    return
  fi
  mkdir -p "${fixture_root}"

  check "create AVFoundation fixture" "${ffmpeg}" -hide_banner -loglevel error -nostdin -y \
    -f lavfi -i testsrc=size=320x180:rate=24 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 3 -c:v mpeg4 -pix_fmt yuv420p -c:a aac -shortest "${mp4}"
  # 12s: the embedded controls scenario consumes ~5 media-seconds (clock,
  # pause/resume, 2x speed) and must never race the end of the fixture.
  check "create embedded bridge fixture" "${ffmpeg}" -hide_banner -loglevel error -nostdin -y \
    -f lavfi -i testsrc=size=320x180:rate=24 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 12 -c:v libvpx-vp9 -c:a libopus -shortest "${webm}"
  printf '1\n00:00:00,250 --> 00:00:01,750\nSynthetic subtitle\n' \
    > "${fixture_root}/sample.en.srt"
  check "create HEVC routing fixture" "${ffmpeg}" -hide_banner -loglevel error -nostdin -y \
    -f lavfi -i testsrc=size=320x180:rate=24 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 2 -c:v libx265 -x265-params log-level=error -c:a aac -shortest "${hevc}"

  [ -s "${mp4}" ] && harness "AVFoundation runtime load" \
    --verify-player-runtime "${mp4}" \
    --verify-player-runtime-expect-backend avfoundation \
    --verify-player-runtime-require-av-direct-surface \
    --verify-player-runtime-load-only
  [ -s "${webm}" ] && check "embedded bridge runtime load" env \
    MARQUEE_FFMPEG_PATH="${ffmpeg}" MARQUEE_FFPROBE_PATH="${ffprobe}" \
    "${APP_BINARY}" --verify-player-runtime "${webm}" \
    --verify-player-runtime-expect-backend ffmpeg-embedded \
    --verify-player-runtime-require-video-frame \
    --verify-player-runtime-require-audio-helper \
    --verify-player-runtime-require-sidecar-subtitle \
    --verify-player-runtime-require-stereo-downmix \
    --verify-player-runtime-load-only
  [ -s "${webm}" ] && check "embedded audio controls" env \
    MARQUEE_FFMPEG_PATH="${ffmpeg}" MARQUEE_FFPROBE_PATH="${ffprobe}" \
    "${APP_BINARY}" --verify-player-runtime "${webm}" \
    --verify-player-runtime-expect-backend ffmpeg-embedded \
    --verify-player-runtime-require-audio-helper \
    --verify-player-runtime-exercise-embedded-audio-controls
  local end_webm="${fixture_root}/sample-end.webm"
  check "create natural-end fixture" "${ffmpeg}" -hide_banner -loglevel error -nostdin -y \
    -f lavfi -i testsrc=size=320x180:rate=24 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 3 -c:v libvpx-vp9 -c:a libopus -shortest "${end_webm}"
  [ -s "${end_webm}" ] && check "embedded natural end" env \
    MARQUEE_FFMPEG_PATH="${ffmpeg}" MARQUEE_FFPROBE_PATH="${ffprobe}" \
    "${APP_BINARY}" --verify-player-runtime "${end_webm}" \
    --verify-player-runtime-expect-backend ffmpeg-embedded \
    --verify-player-runtime-play-to-end
  local silent_webm="${fixture_root}/sample-silent.webm"
  check "create silent fixture" "${ffmpeg}" -hide_banner -loglevel error -nostdin -y \
    -f lavfi -i testsrc=size=320x180:rate=24 \
    -t 3 -c:v libvpx-vp9 -an "${silent_webm}"
  [ -s "${silent_webm}" ] && check "embedded silent-source natural end" env \
    MARQUEE_FFMPEG_PATH="${ffmpeg}" MARQUEE_FFPROBE_PATH="${ffprobe}" \
    "${APP_BINARY}" --verify-player-runtime "${silent_webm}" \
    --verify-player-runtime-expect-backend ffmpeg-embedded \
    --verify-player-runtime-play-to-end
  [ -s "${hevc}" ] && check "HEVC embedded routing" env \
    MARQUEE_FFMPEG_PATH="${ffmpeg}" MARQUEE_FFPROBE_PATH="${ffprobe}" \
    "${APP_BINARY}" --verify-player-runtime "${hevc}" \
    --verify-player-runtime-expect-backend ffmpeg-embedded \
    --verify-player-runtime-require-video-frame \
    --verify-player-runtime-require-audio-helper \
    --verify-player-runtime-load-only

  if [ -s "${webm}" ]; then
    cp "${webm}" "${helper_failure}"
    cat > "${failure_ffmpeg}" <<'FAKE_FAILURE'
#!/usr/bin/env bash
args=" $* "
if [[ "${args}" == *" rawvideo "* && "${args}" == *" f32le "* ]]; then
  printf '%s\n' "$$" > "${MARQUEE_FAKE_EMBEDDED_VIDEO_PID_FILE}"
  sleep 0.25
  exit 64
fi
exit 65
FAKE_FAILURE
    chmod +x "${failure_ffmpeg}"
    check "embedded helper failure cleanup" env \
      MARQUEE_FFMPEG_PATH="${failure_ffmpeg}" \
      MARQUEE_FFPROBE_PATH="${ffprobe}" \
      MARQUEE_FAKE_EMBEDDED_VIDEO_PID_FILE="${failure_pid}" \
      MARQUEE_VERIFY_TERMINATED_PID_FILE="${failure_pid}" \
      "${APP_BINARY}" --verify-player-runtime "${helper_failure}" \
      --verify-player-runtime-expect-backend ffmpeg-embedded \
      --verify-player-runtime-expect-failure \
      --verify-player-runtime-expect-embedded-helper-cleanup

    cp "${webm}" "${parent_death}"
    cat > "${parent_ffmpeg}" <<'FAKE_PARENT_DEATH'
#!/usr/bin/env bash
args=" $* "
if [[ "${args}" == *" rawvideo "* && "${args}" == *" f32le "* ]]; then
  printf '%s\n' "$$" > "${MARQUEE_FAKE_EMBEDDED_VIDEO_PID_FILE}"
  printf '%s\n' "$$" > "${MARQUEE_FAKE_EMBEDDED_AUDIO_PID_FILE}"
  trap '' TERM INT
  while true; do sleep 1; done
fi
exit 65
FAKE_PARENT_DEATH
    chmod +x "${parent_ffmpeg}"
    check "embedded parent-death cleanup" verify_parent_death_cleanup \
      "${parent_death}" "${parent_ffmpeg}" \
      "${parent_video_pid}" "${parent_audio_pid}"
  fi
}

cd "${REPO_ROOT}" || die "could not enter repository"
echo "Marquee quality gate: mode=${MODE}" | tee -a "${LOG_FILE}"
echo "Scratch sidecar: ${SIDECAR_ROOT}" | tee -a "${LOG_FILE}"

if ! run_step "Xcode package manifest sandbox guard" bash \
  "${SCRIPT_DIR}/verify-xcode-package-manifest-sandbox.sh"; then
  FAILURES=$((FAILURES + 1))
  print_summary
  exit 1
fi

if [ "${NO_BUILD}" -eq 1 ]; then
  load_cached_binary
  echo "Using fingerprint-matched Debug app: ${APP_BINARY}" | tee -a "${LOG_FILE}"
else
  BUILD_FINGERPRINT_BEFORE="$(build_input_fingerprint)" \
    || die "could not fingerprint build inputs before build"
  rm -f -- "${BINARY_CACHE}" "${FINGERPRINT_CACHE}"
  if ! run_step "Xcode Debug build" env \
    SWIFT_USE_OLD_DRIVER="${SWIFT_USE_OLD_DRIVER:-1}" \
    xcodebuild -IDEPackageSupportDisableManifestSandbox=1 \
      -project "${PROJECT}" -scheme "${SCHEME}" \
      -configuration Debug -derivedDataPath "${DERIVED_DATA}" \
      -destination 'platform=macOS' -jobs 1 -quiet \
      COMPILER_INDEX_STORE_ENABLE=NO build; then
    FAILURES=$((FAILURES + 1))
    print_summary
    [ "${STARVED}" -eq 0 ] || exit 137
    exit 1
  fi
  cache_current_binary "${BUILD_FINGERPRINT_BEFORE}"
fi

if wants_suite catalog; then
  prepare_legacy_import_fixture
  check "legacy import command shape" bash \
    "${SCRIPT_DIR}/test-quality-gate-legacy-import.sh"
fi

wants_suite search && run_search_suite
wants_suite focus && run_focus_suite
wants_suite browse && run_browse_suite
wants_suite profile && run_profile_suite
wants_suite image && run_image_suite
wants_suite audio && run_audio_suite
wants_suite catalog && run_catalog_suite
wants_suite playback && run_playback_suite
wants_suite diagnostics && run_diagnostics_suite

if [ "${MODE}" = "release" ]; then
  # Measure the exact Debug candidate after deterministic harnesses have
  # settled, before a whole-module Release compile perturbs this Intel host.
  run_timing_tour "${ARTIFACT_ROOT}/native-timing"
  check "Xcode Release build" env \
    SWIFT_USE_OLD_DRIVER="${SWIFT_USE_OLD_DRIVER:-1}" \
    xcodebuild -IDEPackageSupportDisableManifestSandbox=1 \
      -project "${PROJECT}" -scheme "${SCHEME}" \
      -configuration Release -derivedDataPath "${RELEASE_DERIVED_DATA}" \
      -destination 'generic/platform=macOS' -jobs 1 -quiet \
      COMPILER_INDEX_STORE_ENABLE=NO build
  check "Release bundle excludes local Secrets.plist" \
    verify_app_excludes_local_secrets \
    "${RELEASE_DERIVED_DATA}/Build/Products/Release/Marquee.app"
  if curated_audio_candidates_present; then
    check "release audio identity pack verifier present" test -f \
      "${REPO_ROOT}/scripts/verify-audio-identity-packs.sh"
    check "release audio identity pack manifest present" test -f \
      "${REPO_ROOT}/Marquee/Resources/Sounds/CuratedPacks.sha256"
  fi
  if [ -f "${REPO_ROOT}/scripts/verify-audio-identity-packs.sh" ] \
      && [ -f "${REPO_ROOT}/Marquee/Resources/Sounds/CuratedPacks.sha256" ]; then
    check "audio identity pack regeneration" bash \
      "${REPO_ROOT}/scripts/verify-audio-identity-packs.sh" --release
    check "Release audio identity resources" verify_release_audio_resources
  fi
  run_visual_tour "search remote keyboard visual tour" \
    --qa-search-remote-keyboard-tour "${ARTIFACT_ROOT}/search-remote-keyboard"
  run_visual_tour "native visual tour" \
    --qa-visual-tour "${ARTIFACT_ROOT}/native-visual"
  run_release_playback_matrix
fi

print_summary
[ "${FAILURES}" -eq 0 ]

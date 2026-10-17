#!/usr/bin/env bash
# Xcode's package resolver requests a second manifest sandbox inside the
# worker's outer Seatbelt; this setting disables only that nested sandbox.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)"
SETTING="-IDEPackageSupportDisableManifestSandbox=1"
scripts="$(find "${REPO_ROOT}/scripts" -type f -name '*.sh' -print | LC_ALL=C sort)"
missing=0

while IFS= read -r script; do
  [ -n "${script}" ] || continue
  matches="$(grep -nE '^[[:space:]]*xcodebuild([[:space:]]|$)' "${script}" || true)"
  [ -n "${matches}" ] || continue
  while IFS= read -r match; do
    case "${match}" in
      *"${SETTING}"*) ;;
      *)
        printf 'FAIL: %s:%s is missing %s\n' \
          "${script}" "${match%%:*}" "${SETTING}"
        missing=1
        ;;
    esac
  done <<< "${matches}"
done <<< "${scripts}"

if [ "${missing}" -ne 0 ]; then
  exit 1
fi

printf 'PASS: every repository xcodebuild invocation disables only the nested package-manifest sandbox\n'

#!/usr/bin/env bash

# Shared fail-closed checks for app bundles assembled by QA and release flows.
verify_app_excludes_local_secrets() {
  local app="$1"
  local matches

  if [ ! -d "${app}" ]; then
    echo "FAIL: app bundle is unavailable for Secrets.plist verification" >&2
    return 1
  fi
  if ! matches="$(find "${app}" -name Secrets.plist -print -quit)"; then
    echo "FAIL: unable to verify that the app excludes Secrets.plist" >&2
    return 1
  fi
  if [ -n "${matches}" ]; then
    echo "FAIL: refusing to use an app containing Secrets.plist" >&2
    return 1
  fi
}

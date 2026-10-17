#!/usr/bin/env bash
# Marquee — full build diagnostics packet.
#
# Captures environment, project metadata, build settings, and a clean Debug
# build log into build/reports/. On failure, scrapes the log for the most
# common Xcode error/warning shapes into errors-summary.txt.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bash "$REPO_ROOT/scripts/verify-xcode-package-manifest-sandbox.sh"

REPORTS_DIR="$REPO_ROOT/build/reports"
mkdir -p "$REPORTS_DIR"

ENV_FILE="$REPORTS_DIR/environment.txt"
LIST_JSON="$REPORTS_DIR/xcode-list.json"
SETTINGS_TXT="$REPORTS_DIR/build-settings.txt"
SETTINGS_JSON="$REPORTS_DIR/build-settings.json"
ERRORS_FILE="$REPORTS_DIR/errors-summary.txt"
BUILD_LOG="$REPORTS_DIR/xcodebuild-debug.log"

# Always write a summary file even if we exit early.
trap 'write_errors_summary' EXIT

write_errors_summary() {
    if [ ! -f "$BUILD_LOG" ]; then
        {
            echo "(no xcodebuild-debug.log produced — diagnose-build.sh exited before build ran)"
        } > "$ERRORS_FILE"
        return
    fi
    {
        echo "# Marquee build error/warning summary"
        echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# source:    $BUILD_LOG"
        echo
        # Grep patterns requested in the diagnostics spec. -n keeps line numbers
        # so a reviewer can jump back into the full log. -a forces text mode
        # because xcodebuild logs can contain control bytes that fool grep.
        grep -anE \
            'error:|warning:|Undefined symbols|No such module|Command CompileSwift failed|PhaseScriptExecution failed|^ld:|^clang:|codesign|Libmpv|MPVKit|Secrets\.plist' \
            "$BUILD_LOG" \
            || echo "(no matching error/warning lines found)"
    } > "$ERRORS_FILE"
}

# ---------------------------------------------------------------------------
# 1. Environment snapshot
# ---------------------------------------------------------------------------
{
    echo "# Marquee build environment"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## git"
    git rev-parse HEAD 2>&1 || true
    echo "branch: $(git rev-parse --abbrev-ref HEAD 2>&1 || true)"
    echo
    git status --short 2>&1 || true
    echo
    echo "## host"
    sw_vers || true
    echo "arch: $(uname -m)"
    echo "host: $(uname -n)"
    echo
    echo "## xcode"
    xcodebuild -IDEPackageSupportDisableManifestSandbox=1 -version || true
    echo "xcode-select: $(xcode-select -p 2>&1 || true)"
    echo
    echo "## Vendor presence"
    if [ -d "$REPO_ROOT/Vendor/MPVKit-local" ]; then
        echo "Vendor/MPVKit-local: present"
    else
        echo "Vendor/MPVKit-local: MISSING"
    fi
    if [ -d "$REPO_ROOT/Vendor/MPVKit-local/Frameworks/Libmpv.xcframework/macos-arm64_x86_64" ]; then
        echo "Libmpv.xcframework macos slice: present"
    else
        echo "Libmpv.xcframework macos slice: MISSING"
    fi
} > "$ENV_FILE"

# ---------------------------------------------------------------------------
# 2. Project metadata
# ---------------------------------------------------------------------------
xcodebuild -IDEPackageSupportDisableManifestSandbox=1 -list -json -project Marquee.xcodeproj > "$LIST_JSON" 2>&1 || true

xcodebuild -IDEPackageSupportDisableManifestSandbox=1 -showBuildSettings \
    -project Marquee.xcodeproj \
    -scheme Marquee \
    > "$SETTINGS_TXT" 2>&1 || true

# -json only exists on newer xcodebuilds; tolerate failure.
if xcodebuild -IDEPackageSupportDisableManifestSandbox=1 -showBuildSettings -json \
        -project Marquee.xcodeproj \
        -scheme Marquee \
        > "$SETTINGS_JSON" 2>/dev/null; then
    :
else
    rm -f "$SETTINGS_JSON"
    echo "(xcodebuild -showBuildSettings -json not supported on this Xcode)" \
        > "$SETTINGS_JSON.unsupported.txt"
fi

# ---------------------------------------------------------------------------
# 3. Build (delegated to build-local.sh so a single command stays canonical)
# ---------------------------------------------------------------------------
echo "==> Running scripts/build-local.sh"
set +e
"$REPO_ROOT/scripts/build-local.sh"
BUILD_RC=$?
set -e

echo
echo "==> Diagnostic packet written to $REPORTS_DIR"
ls -1 "$REPORTS_DIR"

exit "$BUILD_RC"

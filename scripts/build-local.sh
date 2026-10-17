#!/usr/bin/env bash
# Marquee — local clean Debug build with logged output.
#
# Writes build/reports/xcodebuild-debug.log and prints PASS/FAIL.
# Designed to run headless without opening Xcode.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REPORTS_DIR="$REPO_ROOT/build/reports"
mkdir -p "$REPORTS_DIR"

LOG_FILE="$REPORTS_DIR/xcodebuild-debug.log"
: > "$LOG_FILE"

bash "$REPO_ROOT/scripts/verify-xcode-package-manifest-sandbox.sh"

echo "==> Marquee clean Debug build"
echo "    repo:   $REPO_ROOT"
echo "    log:    $LOG_FILE"
echo

set +e
# xcodebuild emits embedded \r for in-place progress, which makes downstream
# tools (grep, less, GitHub previews) see one mega-line. Normalize CRs to LFs
# so the log is line-oriented and greppable.
xcodebuild -IDEPackageSupportDisableManifestSandbox=1 \
    -project Marquee.xcodeproj \
    -scheme Marquee \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    clean build \
    2>&1 | tr '\r' '\n' | tee "$LOG_FILE"
# PIPESTATUS[0] is xcodebuild's real exit code despite the tee.
BUILD_RC=${PIPESTATUS[0]}
set -e

echo
if [ "$BUILD_RC" -eq 0 ]; then
    echo "==> PASS  (xcodebuild exit 0)"
else
    echo "==> FAIL  (xcodebuild exit $BUILD_RC)"
fi

exit "$BUILD_RC"

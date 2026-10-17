#!/usr/bin/env bash
# Marquee — build a Release .app and package it as a drag-to-Applications DMG.
#
# Usage:
#     ./scripts/release.sh [VERSION]
#
# VERSION defaults to 0.1.0. CURRENT_PROJECT_VERSION (build number) is set to
# the higher of the committed project setting and the git commit count, so clean
# native worktrees cannot accidentally emit a lower bundle build.
#
# Output:
#     dist/Marquee-<VERSION>.dmg
#     dist/Marquee.app                              # exported bundle (for install-local symlink convenience)
#     build/derived/                                # archive + DerivedData (gitignored)
#
# This script is the future-MAS / future-notarization entry point. It uses the
# same xcodebuild archive → -exportArchive pipeline that Developer ID and Mac
# App Store distribution use. To upgrade to notarized Developer ID later:
#     1. Get a "Developer ID Application" cert + Team ID from developer.apple.com
#     2. Edit scripts/exportOptions.plist (see comment in that file)
#     3. Add `xcrun notarytool submit` + `xcrun stapler staple` after the export
set -euo pipefail

VERSION="0.1.0"
VERSION_SET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish)
            echo "FAIL: binary publishing is disabled until dependencies are reproducibly built from retained source" >&2
            exit 64
            ;;
        -h|--help)
            echo "usage: ./scripts/release.sh [VERSION]"
            exit 0
            ;;
        -*)
            echo "FAIL: unknown option: $1" >&2
            exit 64
            ;;
        *)
            if [[ $VERSION_SET -eq 1 ]]; then
                echo "FAIL: unexpected argument: $1" >&2
                exit 64
            fi
            VERSION="$1"
            VERSION_SET=1
            shift
            ;;
    esac
done

SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$VERSION" =~ $SEMVER_PATTERN ]]; then
    echo "FAIL: version must be valid SemVer such as 2.1.0, 3.0.0-beta.1, or 3.0.0+build.4" >&2
    exit 64
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bash "$REPO_ROOT/scripts/verify-xcode-package-manifest-sandbox.sh"

# shellcheck source=lib/bundle-safety.sh
source "$REPO_ROOT/scripts/lib/bundle-safety.sh"

DERIVED_DIR="$REPO_ROOT/build/derived"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$DERIVED_DIR/Marquee.xcarchive"
EXPORT_DIR="$DERIVED_DIR/export"
EXPORT_OPTIONS="$REPO_ROOT/scripts/exportOptions.plist"
DMG_PATH="$DIST_DIR/Marquee-$VERSION.dmg"
DMG_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/marquee-dmg.XXXXXX")"
DMG_STAGING="$DMG_WORK_DIR/staging"
DMG_TEMP="$DMG_WORK_DIR/Marquee-$VERSION.dmg"

cleanup() {
    rm -rf "$DMG_WORK_DIR"
}
trap cleanup EXIT

GIT_BUILD_COUNT="$(git rev-list --count HEAD)"
PROJECT_BUILD_NUMBER="$(awk -F '= ' '/CURRENT_PROJECT_VERSION/ { value=$2; gsub(/[ ;]/, "", value); print value; exit }' Marquee.xcodeproj/project.pbxproj)"
BUILD_NUMBER="$GIT_BUILD_COUNT"
if [[ "$PROJECT_BUILD_NUMBER" =~ ^[0-9]+$ ]] && (( PROJECT_BUILD_NUMBER > GIT_BUILD_COUNT )); then
    BUILD_NUMBER="$PROJECT_BUILD_NUMBER"
fi

echo "==> Marquee release"
echo "    version:      $VERSION"
echo "    build number: $BUILD_NUMBER (git count $GIT_BUILD_COUNT, project $PROJECT_BUILD_NUMBER)"
echo

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$DERIVED_DIR" "$DIST_DIR"

echo "==> [preflight] Verify app icon source geometry"
python3 "$REPO_ROOT/scripts/verify_app_icon_geometry.py" --source-root "$REPO_ROOT"
echo

echo "==> [1/3] xcodebuild archive (Release)"
xcodebuild -IDEPackageSupportDisableManifestSandbox=1 \
    -project Marquee.xcodeproj \
    -scheme Marquee \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DIR" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    archive | tr '\r' '\n' | tail -20

echo
echo "==> [2/3] xcodebuild -exportArchive"
xcodebuild -IDEPackageSupportDisableManifestSandbox=1 \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" | tr '\r' '\n' | tail -10

EXPORTED_APP="$EXPORT_DIR/Marquee.app"
if [[ ! -d "$EXPORTED_APP" ]]; then
    echo "FAIL: Marquee.app not found at $EXPORTED_APP"
    exit 1
fi

echo
echo "==> [post-export] Verify compiled app icon geometry"
python3 "$REPO_ROOT/scripts/verify_app_icon_geometry.py" --source-root "$REPO_ROOT" --app "$EXPORTED_APP"
verify_app_excludes_local_secrets "$EXPORTED_APP"

# Mirror the bundle into dist/ so a follow-up install script (or a curious
# user) has a stable path that doesn't depend on the DerivedData layout.
rm -rf "$DIST_DIR/Marquee.app"
cp -R "$EXPORTED_APP" "$DIST_DIR/Marquee.app"

echo
echo "==> [3/3] Build DMG (drag-to-Applications layout)"
mkdir -p "$DMG_STAGING"
cp -R "$EXPORTED_APP" "$DMG_STAGING/Marquee.app"
ln -s /Applications "$DMG_STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "Marquee $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_TEMP" >/dev/null
cp "$DMG_TEMP" "$DMG_PATH"

DMG_SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
echo "    wrote: $DMG_PATH ($DMG_SIZE)"

echo
echo "PASS — $DMG_PATH"
echo "       To install: open $DMG_PATH, then drag Marquee to Applications"

#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/bundle-safety.sh
source "$ROOT/scripts/lib/bundle-safety.sh"

LAUNCH=0
WITH_HARNESSES=0
for arg in "$@"; do
  case "$arg" in
    --launch)
      LAUNCH=1
      ;;
    --with-harnesses)
      WITH_HARNESSES=1
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./scripts/build-qa-app.sh [--launch] [--with-harnesses]

Builds build/qa/Marquee.app from local source for macOS 12 QA.

Options:
  --launch          Launch the rebuilt QA app after signing.
  --with-harnesses  Include DEBUG verifier harnesses so launch args such as
                    --verify-remote-input exit with PASS/FAIL.
USAGE
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build/direct build/qa

# Xcode 14.2's swift-driver can hang behind Gatekeeper assessment on this
# macOS 12 host. The legacy driver still compiles the app and keeps QA builds
# repeatable until the host security-service issue is cleared.
export SWIFT_USE_OLD_DRIVER="${SWIFT_USE_OLD_DRIVER:-1}"

FWFLAGS=()
for dir in Vendor/MPVKit-local/Frameworks/*.xcframework/macos-arm64_x86_64; do
  [[ -d "$dir" ]] && FWFLAGS+=( -F "$ROOT/$dir" )
done

SOURCES=()
if [[ "$WITH_HARNESSES" == "1" ]]; then
  while IFS= read -r file; do
    SOURCES+=( "$file" )
  done < <(find Marquee -name "*.swift" -print | sort)
else
  while IFS= read -r file; do
    SOURCES+=( "$file" )
  done < <(find Marquee -name "*.swift" ! -name "Verify*Harness.swift" -print | sort)
fi

SWIFT_DEFINES=( -D DEBUG )
if [[ "$WITH_HARNESSES" != "1" ]]; then
  SWIFT_DEFINES+=( -D QA_NO_HARNESSES )
fi

xcrun --sdk macosx swiftc \
  "${SWIFT_DEFINES[@]}" \
  -target x86_64-apple-macosx12.0 \
  -sdk "$SDK" \
  -swift-version 5 \
  -Onone \
  -num-threads 4 \
  ${FWFLAGS[@]+"${FWFLAGS[@]}"} \
  -Xcc -I"$ROOT/Vendor/MPVKit-local/Sources/_FFmpeg/include" \
  -Xcc -I"$ROOT/Vendor/MPVKit-local/Sources/_MPVKit/include" \
  "${SOURCES[@]}" \
  -framework AVFoundation \
  -framework CoreAudio \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
  -framework AudioToolbox \
  -framework CoreVideo \
  -framework CoreFoundation \
  -framework CoreMedia \
  -framework Metal \
  -framework VideoToolbox \
  -framework Libmpv \
  -framework Libavcodec \
  -framework Libavdevice \
  -framework Libavfilter \
  -framework Libavformat \
  -framework Libavutil \
  -framework Libswresample \
  -framework Libswscale \
  -framework Libssl \
  -framework Libcrypto \
  -framework Libass \
  -framework Libfreetype \
  -framework Libfribidi \
  -framework Libharfbuzz \
  -L"$ROOT/Vendor/MPVKit-local/Frameworks/MoltenVK.xcframework/macos-arm64_x86_64" \
  -lMoltenVK \
  -framework Libshaderc_combined \
  -framework lcms2 \
  -framework Libplacebo \
  -framework Libdovi \
  -framework Libunibreak \
  -framework gmp \
  -framework nettle \
  -framework hogweed \
  -framework gnutls \
  -framework Libdav1d \
  -framework Libuavs3d \
  -framework Libuchardet \
  -framework Libbluray \
  -framework Libluajit \
  -o build/direct/Marquee

rm -rf build/qa/Marquee.app
cp -R dist/Marquee.app build/qa/Marquee.app
rm -rf build/qa/Marquee.app/Contents/Resources/Secrets.plist
cp build/direct/Marquee build/qa/Marquee.app/Contents/MacOS/Marquee

ASSET_BUILD="$ROOT/build/qa-assets"
ASSET_INFO="$ASSET_BUILD/asset-info.plist"
rm -rf "$ASSET_BUILD"
mkdir -p "$ASSET_BUILD"
xcrun actool \
  --compile "$ASSET_BUILD" \
  --platform macosx \
  --minimum-deployment-target 12.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ASSET_INFO" \
  "$ROOT/Marquee/Assets.xcassets" >/dev/null
if [[ -f "$ASSET_BUILD/Assets.car" ]]; then
  cp "$ASSET_BUILD/Assets.car" build/qa/Marquee.app/Contents/Resources/Assets.car
fi
if [[ -f "$ASSET_BUILD/AppIcon.icns" ]]; then
  cp "$ASSET_BUILD/AppIcon.icns" build/qa/Marquee.app/Contents/Resources/AppIcon.icns
fi

rm -rf build/qa/Marquee.app/Contents/Resources/Sounds
cp -R Marquee/Resources/Sounds build/qa/Marquee.app/Contents/Resources/Sounds

GIT_BUILD_COUNT="$(git rev-list --count HEAD)"
PROJECT_BUILD_NUMBER="$(awk -F '= ' '/CURRENT_PROJECT_VERSION/ { value=$2; gsub(/[ ;]/, "", value); print value; exit }' Marquee.xcodeproj/project.pbxproj)"
BUILD_NUMBER="$GIT_BUILD_COUNT"
if [[ "$PROJECT_BUILD_NUMBER" =~ ^[0-9]+$ ]] && (( PROJECT_BUILD_NUMBER > GIT_BUILD_COUNT )); then
  BUILD_NUMBER="$PROJECT_BUILD_NUMBER"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}-qa" build/qa/Marquee.app/Contents/Info.plist
verify_app_excludes_local_secrets build/qa/Marquee.app
codesign --force --deep --sign - build/qa/Marquee.app

if [[ "$LAUNCH" == "1" ]]; then
  pkill -x Marquee 2>/dev/null || true
  printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > /tmp/marquee-qa-start.txt
  open -n "$ROOT/build/qa/Marquee.app"
fi

#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
GENERATOR="$SCRIPT_DIR/generate-audio-identity-packs.sh"
SOUNDS_DIR="$REPO_ROOT/Marquee/Resources/Sounds"
MANIFEST="$SOUNDS_DIR/CuratedPacks.sha256"
FFMPEG=${FFMPEG:-$(command -v ffmpeg || true)}
FFPROBE=${FFPROBE:-$(command -v ffprobe || true)}
RELEASE_CHECKS=0
if [ "${1:-}" = "--release" ] && [ "$#" -eq 1 ]; then
  RELEASE_CHECKS=1
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--release]" >&2
  exit 64
fi

bash -n "$GENERATOR"
bash -n "$0"
[ "$RELEASE_CHECKS" -eq 0 ] || [ -x "$FFMPEG" ] \
  || { echo "missing checked ffmpeg: $FFMPEG" >&2; exit 69; }
[ -x "$FFPROBE" ] || { echo "missing checked ffprobe: $FFPROBE" >&2; exit 69; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/marquee-audio-pack-verify.XXXXXX")
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT HUP INT TERM

make_fixture() {
  fixture=$1
  mkdir -p "$fixture/scripts" "$fixture/Marquee/Resources/Sounds"
  cp "$GENERATOR" "$fixture/scripts/generate-audio-identity-packs.sh"
  cp "$0" "$fixture/scripts/verify-audio-identity-packs.sh"
  chmod +x "$fixture/scripts/generate-audio-identity-packs.sh"
  chmod +x "$fixture/scripts/verify-audio-identity-packs.sh"
}

expect_failure() {
  description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: $description" >&2
    exit 1
  fi
}

[ -f "$MANIFEST" ] || { echo "missing checked-in manifest: $MANIFEST" >&2; exit 1; }
[ ! -L "$MANIFEST" ] || { echo "checked manifest must not be a symlink" >&2; exit 1; }
[ "$(grep -Ec '^[0-9a-f]{64}  CuratedPacks-[0-9a-f]{64}/(velvet|hearth|nocturne)-(launch|focus|select|back|boundary)\.wav$' "$MANIFEST")" = "15" ] \
  || { echo "manifest must contain exactly 15 allowlisted curated assets" >&2; exit 1; }
PACK_DIRECTORY=$(awk 'NR == 1 {split($2, parts, "/"); print parts[1]}' "$MANIFEST")
[ "$(awk '{split($2, parts, "/"); print parts[1]}' "$MANIFEST" | sort -u | wc -l | tr -d ' ')" = "1" ] \
  || { echo "manifest must reference one content-addressed pack directory" >&2; exit 1; }
PACK_PATH="$SOUNDS_DIR/$PACK_DIRECTORY"
PACK_ENTRIES=$(find "$SOUNDS_DIR" -mindepth 1 -maxdepth 1 \
  -name 'CuratedPacks-*' -print | LC_ALL=C sort)
[ "$PACK_ENTRIES" = "$PACK_PATH" ] \
  || { echo "Sounds must contain exactly the manifest-selected curated pack" >&2; exit 1; }
[ -d "$PACK_PATH" ] && [ ! -L "$PACK_PATH" ] || { echo "missing or symlinked pack directory: $PACK_PATH" >&2; exit 1; }
NORMALIZED_MANIFEST="$TMP_ROOT/manifest.sha256"
sed "s#  $PACK_DIRECTORY/#  #" "$MANIFEST" > "$NORMALIZED_MANIFEST"
NORMALIZED_HASH=$(shasum -a 256 "$NORMALIZED_MANIFEST" | awk '{print $1}')
[ "$PACK_DIRECTORY" = "CuratedPacks-$NORMALIZED_HASH" ] \
  || { echo "pack directory suffix does not match normalized manifest hash" >&2; exit 1; }
EXPECTED_FILES='hearth-back.wav
hearth-boundary.wav
hearth-focus.wav
hearth-launch.wav
hearth-select.wav
nocturne-back.wav
nocturne-boundary.wav
nocturne-focus.wav
nocturne-launch.wav
nocturne-select.wav
velvet-back.wav
velvet-boundary.wav
velvet-focus.wav
velvet-launch.wav
velvet-select.wav'
MANIFEST_FILES=$(awk '{split($2, parts, "/"); print parts[2]}' "$MANIFEST" | sort)
[ "$MANIFEST_FILES" = "$EXPECTED_FILES" ] || { echo "manifest asset allowlist mismatch" >&2; exit 1; }
ACTUAL_FILES=$(for asset in "$PACK_PATH"/*; do [ -f "$asset" ] && basename "$asset"; done | sort)
[ "$ACTUAL_FILES" = "$EXPECTED_FILES" ] || { echo "checked pack contains missing or extra top-level assets" >&2; exit 1; }
[ "$(find "$PACK_PATH" -type f | wc -l | tr -d ' ')" = "15" ] \
  || { echo "checked pack contains nested or extra files" >&2; exit 1; }
(cd "$SOUNDS_DIR" && shasum -a 256 -c CuratedPacks.sha256 >/dev/null)

if [ "$RELEASE_CHECKS" -eq 1 ]; then
  FIXTURE="$TMP_ROOT/repo"
  make_fixture "$FIXTURE"
  FIXTURE_GENERATOR="$FIXTURE/scripts/generate-audio-identity-packs.sh"
  FIXTURE_VERIFIER="$FIXTURE/scripts/verify-audio-identity-packs.sh"
  expect_failure "missing ffmpeg" "$FIXTURE_GENERATOR" --ffmpeg "$TMP_ROOT/missing/ffmpeg" --ffprobe "$FFPROBE"
  mkdir -p "$TMP_ROOT/fake-tools"
  printf '#!/bin/sh\necho not-ffmpeg\n' > "$TMP_ROOT/fake-tools/ffmpeg"
  chmod +x "$TMP_ROOT/fake-tools/ffmpeg"
  expect_failure "wrong ffmpeg executable" "$FIXTURE_GENERATOR" --ffmpeg "$TMP_ROOT/fake-tools/ffmpeg" --ffprobe "$FFPROBE"
  expect_failure "output override" "$FIXTURE_GENERATOR" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE" --output ../../escape
  mkdir "$FIXTURE/Marquee/Resources/Sounds/.CuratedPacks-generator-lock"
  expect_failure "concurrent generator lock" "$FIXTURE_GENERATOR" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE"
  rmdir "$FIXTURE/Marquee/Resources/Sounds/.CuratedPacks-generator-lock"
  mkdir "$FIXTURE/Marquee/Resources/Sounds/.CuratedPacks-generator-lock"
  printf '999999\n' > "$FIXTURE/Marquee/Resources/Sounds/.CuratedPacks-generator-lock/pid"

  SYMLINK_FIXTURE="$TMP_ROOT/symlink-repo"
  make_fixture "$SYMLINK_FIXTURE"
  rm -rf "$SYMLINK_FIXTURE/Marquee/Resources/Sounds"
  ln -s "$TMP_ROOT" "$SYMLINK_FIXTURE/Marquee/Resources/Sounds"
  expect_failure "symlinked destination" "$SYMLINK_FIXTURE/scripts/generate-audio-identity-packs.sh" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE"

  SPACED_TOOL_DIR="$TMP_ROOT/trusted tools"
  mkdir "$SPACED_TOOL_DIR"
  ln -s "$FFPROBE" "$SPACED_TOOL_DIR/ffprobe"
  SPACED_FFPROBE="$SPACED_TOOL_DIR/ffprobe"

  DISCOVERED_TOOL_DIR="$TMP_ROOT/discovered tools"
  mkdir "$DISCOVERED_TOOL_DIR"
  ln -s "$FFPROBE" "$DISCOVERED_TOOL_DIR/ffprobe"

  "$FIXTURE_GENERATOR" --ffmpeg "$FFMPEG" --ffprobe "$SPACED_FFPROBE" >/dev/null
  GENERATED_SOUNDS="$FIXTURE/Marquee/Resources/Sounds"
  cmp "$MANIFEST" "$GENERATED_SOUNDS/CuratedPacks.sha256" >/dev/null \
    || { echo "fresh generator manifest differs from checked manifest" >&2; exit 1; }
  for asset in $EXPECTED_FILES; do
    cmp "$PACK_PATH/$asset" "$GENERATED_SOUNDS/$PACK_DIRECTORY/$asset" >/dev/null \
      || { echo "fresh generator output differs from checked asset: $asset" >&2; exit 1; }
  done

  STALE_PACK="$GENERATED_SOUNDS/CuratedPacks-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  mkdir "$STALE_PACK"
  printf 'stale\n' > "$STALE_PACK/marker"
  INSTALLED_WITH_STALE_BEFORE=$(find "$GENERATED_SOUNDS" -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  expect_failure "stale curated-pack sibling verification" env FFPROBE="$FFPROBE" "$FIXTURE_VERIFIER"
  expect_failure "stale curated-pack sibling generation" "$FIXTURE_GENERATOR" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE"
  INSTALLED_WITH_STALE_AFTER=$(find "$GENERATED_SOUNDS" -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  [ "$INSTALLED_WITH_STALE_BEFORE" = "$INSTALLED_WITH_STALE_AFTER" ] \
    || { echo "stale-pack rejection changed installed assets or manifest" >&2; exit 1; }
  rm -rf -- "$STALE_PACK"
  env FFPROBE="$SPACED_FFPROBE" "$FIXTURE_VERIFIER" >/dev/null
  env -u FFPROBE PATH="$DISCOVERED_TOOL_DIR:$PATH" "$FIXTURE_VERIFIER" >/dev/null
  "$FIXTURE_GENERATOR" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE" >/dev/null

  INSTALLED_BEFORE=$(find "$GENERATED_SOUNDS" -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  expect_failure "validation failure" env MARQUEE_AUDIO_PACK_TEST_CORRUPT=1 "$FIXTURE_GENERATOR" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE"
  INSTALLED_AFTER=$(find "$GENERATED_SOUNDS" -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  [ "$INSTALLED_BEFORE" = "$INSTALLED_AFTER" ] || { echo "failed generation changed installed assets" >&2; exit 1; }

  mkdir "$GENERATED_SOUNDS/.CuratedPacks-staging-interrupted"
  printf 'partial' > "$GENERATED_SOUNDS/.CuratedPacks-staging-interrupted/partial.wav"
  "$FIXTURE_GENERATOR" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE" >/dev/null
  [ ! -e "$GENERATED_SOUNDS/.CuratedPacks-staging-interrupted" ] || { echo "interrupted staging was not recovered" >&2; exit 1; }
  INSTALLED_REPRO=$(find "$GENERATED_SOUNDS" -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  [ "$INSTALLED_BEFORE" = "$INSTALLED_REPRO" ] || { echo "two-run output was not reproducible" >&2; exit 1; }
  [ "$(find "$GENERATED_SOUNDS" -type d -name 'CuratedPacks-*' | wc -l | tr -d ' ')" = "1" ] \
    || { echo "repro run installed more than one pack directory" >&2; exit 1; }
fi

metric() {
  file=$1
  label=$2
  "$FFMPEG" -hide_banner -nostdin -i "$file" -af astats=metadata=0:reset=0 -f null - 2>&1 \
    | awk -F': ' -v label="$label" '$0 ~ label {value=$NF} END {gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value}'
}

gain_for() {
  case "$1" in
    *-launch.wav) echo 0.20 ;;
    *-focus.wav) echo 0.10 ;;
    *-select.wav) echo 0.14 ;;
    *-back.wav) echo 0.09 ;;
    *-boundary.wav) echo 0.05 ;;
    *) exit 1 ;;
  esac
}

METRICS="$TMP_ROOT/metrics.txt"
: > "$METRICS"
for relative in $(awk '{print $2}' "$MANIFEST"); do
  file="$SOUNDS_DIR/$relative"
  name=$(basename "$file")
  probe=$("$FFPROBE" -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_rate,channels:format=duration \
    -of default=noprint_wrappers=1 "$file")
  echo "$probe" | grep -q '^codec_name=pcm_s16le$' || { echo "$name codec mismatch" >&2; exit 1; }
  echo "$probe" | grep -q '^sample_rate=44100$' || { echo "$name sample-rate mismatch" >&2; exit 1; }
  echo "$probe" | grep -q '^channels=1$' || { echo "$name channel mismatch" >&2; exit 1; }

  duration=$(printf '%s\n' "$probe" | awk -F= '$1 == "duration" {print $2; exit}')
  [ -n "$duration" ] || { echo "$name duration missing" >&2; exit 1; }
  case "$name" in
    *-launch.wav) awk -v d="$duration" 'BEGIN {exit !(d >= 2.0 && d <= 3.5)}' || { echo "$name launch duration out of range: $duration" >&2; exit 1; } ;;
    *) awk -v d="$duration" 'BEGIN {exit !(d >= 0.020 && d <= 0.080)}' || { echo "$name cue duration out of range: $duration" >&2; exit 1; } ;;
  esac

  if [ "$RELEASE_CHECKS" -eq 1 ]; then
    peak=$(metric "$file" 'Peak level dB')
    rms=$(metric "$file" 'RMS level dB')
    printf '%s %s %s\n' "$name" "$peak" "$rms" >> "$METRICS"
    awk -v v="$peak" 'BEGIN {exit !(v <= -12)}' || { echo "$name peak too high: $peak dBFS" >&2; exit 1; }
    awk -v v="$rms" 'BEGIN {exit !(v <= -24)}' || { echo "$name RMS too high: $rms dBFS" >&2; exit 1; }
    gain=$(gain_for "$name")
    awk -v p="$peak" -v g="$gain" 'BEGIN {effective=p + 20*log(g)/log(10); exit !(effective <= -24)}' \
      || { echo "$name effective peak exceeds -24 dBFS" >&2; exit 1; }
  fi
done

if [ "$RELEASE_CHECKS" -eq 1 ]; then
  for pack in velvet hearth nocturne; do
    boundary_peak=$(awk -v name="$pack-boundary.wav" '$1 == name {print $2}' "$METRICS")
    boundary_rms=$(awk -v name="$pack-boundary.wav" '$1 == name {print $3}' "$METRICS")
    for cue in focus select back; do
      cue_peak=$(awk -v name="$pack-$cue.wav" '$1 == name {print $2}' "$METRICS")
      cue_rms=$(awk -v name="$pack-$cue.wav" '$1 == name {print $3}' "$METRICS")
      awk -v b="$boundary_peak" -v c="$cue_peak" 'BEGIN {exit !(b <= c - 3)}' || { echo "$pack boundary peak is not 3 dB below $cue" >&2; exit 1; }
      awk -v b="$boundary_rms" -v c="$cue_rms" 'BEGIN {exit !(b <= c - 3)}' || { echo "$pack boundary RMS is not 3 dB below $cue" >&2; exit 1; }
    done
  done
fi

if [ "$RELEASE_CHECKS" -eq 1 ]; then
  echo "verify-audio-identity-packs: PASS mode=release assets=15 content-address=verified exact-regeneration=verified format=mono/44100/s16 peak<=-12 rms<=-24 effective-peak<=-24 boundary-margin>=3dB negative-recovery=verified reproducible=verified whitespace-tool-path=verified"
else
  echo "verify-audio-identity-packs: PASS mode=integrity assets=15 content-address=verified allowlist=verified checksums=verified format=mono/44100/s16 duration=verified"
fi

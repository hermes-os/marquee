#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

usage() {
  echo "usage: $0 --ffmpeg /absolute/path/to/ffmpeg --ffprobe /absolute/path/to/ffprobe" >&2
  exit 64
}

FFMPEG=""
FFPROBE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ffmpeg)
      [ "$#" -ge 2 ] || usage
      FFMPEG="$2"
      shift 2
      ;;
    --ffprobe)
      [ "$#" -ge 2 ] || usage
      FFPROBE="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$FFMPEG" ] && [ -n "$FFPROBE" ] || usage
case "$FFMPEG" in /*/ffmpeg) ;; *) echo "ffmpeg path must be absolute and end in /ffmpeg" >&2; exit 64 ;; esac
case "$FFPROBE" in /*/ffprobe) ;; *) echo "ffprobe path must be absolute and end in /ffprobe" >&2; exit 64 ;; esac
[ -x "$FFMPEG" ] || { echo "ffmpeg is not executable: $FFMPEG" >&2; exit 69; }
[ -x "$FFPROBE" ] || { echo "ffprobe is not executable: $FFPROBE" >&2; exit 69; }
FFMPEG_VERSION=$("$FFMPEG" -version 2>/dev/null) \
  || { echo "checked ffmpeg path did not execute" >&2; exit 69; }
FFPROBE_VERSION=$("$FFPROBE" -version 2>/dev/null) \
  || { echo "checked ffprobe path did not execute" >&2; exit 69; }
case "$FFMPEG_VERSION" in 'ffmpeg version '*) ;; *) echo "checked ffmpeg path did not identify itself as ffmpeg" >&2; exit 69 ;; esac
case "$FFPROBE_VERSION" in 'ffprobe version '*) ;; *) echo "checked ffprobe path did not identify itself as ffprobe" >&2; exit 69 ;; esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SOUNDS_DIR="$REPO_ROOT/Marquee/Resources/Sounds"
case "$SOUNDS_DIR" in "$REPO_ROOT"/*) ;; *) echo "resolved Sounds path escaped repository" >&2; exit 73 ;; esac
[ -d "$SOUNDS_DIR" ] || { echo "missing Sounds directory: $SOUNDS_DIR" >&2; exit 72; }
[ ! -L "$SOUNDS_DIR" ] || { echo "Sounds directory must not be a symlink" >&2; exit 73; }

LOCK_DIR="$SOUNDS_DIR/.CuratedPacks-generator-lock"
[ ! -L "$LOCK_DIR" ] || { echo "refusing symlinked generator lock" >&2; exit 73; }
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_PID_FILE="$LOCK_DIR/pid"
  if [ -f "$LOCK_PID_FILE" ] && [ ! -L "$LOCK_PID_FILE" ]; then
    LOCK_PID=$(sed -n '1p' "$LOCK_PID_FILE")
  else
    LOCK_PID=""
  fi
  case "$LOCK_PID" in
    ''|*[!0-9]*) echo "another curated-pack generator owns an invalid lock" >&2; exit 75 ;;
  esac
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "another curated-pack generator is active: pid=$LOCK_PID" >&2
    exit 75
  fi
  rm -rf -- "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
STAGING="$SOUNDS_DIR/.CuratedPacks-staging-$$"
CHECKED_MANIFEST_STAGING="$SOUNDS_DIR/.CuratedPacks.sha256.$$"
cleanup() {
  if [ -d "$STAGING" ] && [ ! -L "$STAGING" ]; then
    rm -rf -- "$STAGING"
  fi
  if [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
    rm -rf -- "$LOCK_DIR"
  fi
  if [ -f "$CHECKED_MANIFEST_STAGING" ] && [ ! -L "$CHECKED_MANIFEST_STAGING" ]; then
    rm -f -- "$CHECKED_MANIFEST_STAGING"
  fi
}
trap cleanup EXIT HUP INT TERM

INSTALLED_PACK_COUNT=$(find "$SOUNDS_DIR" -mindepth 1 -maxdepth 1 \
  -name 'CuratedPacks-*' -print | wc -l | tr -d ' ')
[ "$INSTALLED_PACK_COUNT" -le 1 ] \
  || { echo "multiple curated-pack directories require explicit cleanup" >&2; exit 65; }

for stale in "$SOUNDS_DIR"/.CuratedPacks-staging-*; do
  [ -e "$stale" ] || continue
  [ ! -L "$stale" ] || { echo "refusing symlinked staging path: $stale" >&2; exit 73; }
  rm -rf -- "$stale"
done

mkdir "$STAGING"

generate_launch() {
  output=$1
  first=$2
  second=$3
  third=$4
  "$FFMPEG" -hide_banner -loglevel error -nostdin \
    -f lavfi -i "sine=frequency=${first}:sample_rate=44100:duration=2.6" \
    -f lavfi -i "sine=frequency=${second}:sample_rate=44100:duration=2.6" \
    -f lavfi -i "sine=frequency=${third}:sample_rate=44100:duration=2.6" \
    -filter_complex "[0:a][1:a][2:a]amix=inputs=3:normalize=0,volume=0.18,lowpass=f=1800,afade=t=in:st=0:d=0.18,afade=t=out:st=2.12:d=0.48[a]" \
    -map "[a]" -ac 1 -ar 44100 -c:a pcm_s16le -map_metadata -1 \
    -fflags +bitexact -flags:a +bitexact -y "$output"
}

generate_cue() {
  output=$1
  duration=$2
  first=$3
  second=$4
  gain=$5
  fade_out=$6
  "$FFMPEG" -hide_banner -loglevel error -nostdin \
    -f lavfi -i "sine=frequency=${first}:sample_rate=44100:duration=${duration}" \
    -f lavfi -i "sine=frequency=${second}:sample_rate=44100:duration=${duration}" \
    -filter_complex "[0:a][1:a]amix=inputs=2:normalize=0,volume=${gain},lowpass=f=2400,afade=t=in:st=0:d=0.004,afade=t=out:st=${fade_out}:d=0.012[a]" \
    -map "[a]" -ac 1 -ar 44100 -c:a pcm_s16le -map_metadata -1 \
    -fflags +bitexact -flags:a +bitexact -y "$output"
}

generate_launch "$STAGING/velvet-launch.wav" 196.00 293.66 392.00
generate_cue "$STAGING/velvet-focus.wav" 0.045 392.00 587.33 0.25 0.033
generate_cue "$STAGING/velvet-select.wav" 0.065 293.66 440.00 0.28 0.053
generate_cue "$STAGING/velvet-back.wav" 0.055 349.23 233.08 0.22 0.043
generate_cue "$STAGING/velvet-boundary.wav" 0.035 196.00 185.00 0.09 0.023

generate_launch "$STAGING/hearth-launch.wav" 174.61 261.63 349.23
generate_cue "$STAGING/hearth-focus.wav" 0.048 349.23 523.25 0.25 0.036
generate_cue "$STAGING/hearth-select.wav" 0.068 261.63 392.00 0.28 0.056
generate_cue "$STAGING/hearth-back.wav" 0.058 311.13 207.65 0.22 0.046
generate_cue "$STAGING/hearth-boundary.wav" 0.038 174.61 164.81 0.09 0.026

generate_launch "$STAGING/nocturne-launch.wav" 146.83 220.00 329.63
generate_cue "$STAGING/nocturne-focus.wav" 0.050 329.63 493.88 0.25 0.038
generate_cue "$STAGING/nocturne-select.wav" 0.070 246.94 369.99 0.28 0.058
generate_cue "$STAGING/nocturne-back.wav" 0.060 293.66 196.00 0.22 0.048
generate_cue "$STAGING/nocturne-boundary.wav" 0.040 146.83 138.59 0.09 0.028

if [ "${MARQUEE_AUDIO_PACK_TEST_CORRUPT:-0}" = "1" ]; then
  rm -f -- "$STAGING/nocturne-boundary.wav"
fi

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
ACTUAL_FILES=$(for path in "$STAGING"/*; do [ -f "$path" ] && basename "$path"; done | LC_ALL=C sort)
[ "$ACTUAL_FILES" = "$EXPECTED_FILES" ] || { echo "generated asset allowlist mismatch" >&2; exit 65; }

for file in $EXPECTED_FILES; do
  probe=$("$FFPROBE" -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_rate,channels,sample_fmt \
    -of default=noprint_wrappers=1 "$STAGING/$file")
  echo "$probe" | grep -q '^codec_name=pcm_s16le$' || { echo "$file is not signed 16-bit PCM" >&2; exit 65; }
  echo "$probe" | grep -q '^sample_rate=44100$' || { echo "$file is not 44.1 kHz" >&2; exit 65; }
  echo "$probe" | grep -q '^channels=1$' || { echo "$file is not mono" >&2; exit 65; }
done

MANIFEST="$STAGING/manifest.sha256"
: > "$MANIFEST"
for file in $EXPECTED_FILES; do
  shasum -a 256 "$STAGING/$file" | awk -v name="$file" '{print $1 "  " name}' >> "$MANIFEST"
done
MANIFEST_HASH=$(shasum -a 256 "$MANIFEST" | awk '{print $1}')
FINAL="$SOUNDS_DIR/CuratedPacks-$MANIFEST_HASH"
[ ! -L "$FINAL" ] || { echo "refusing symlinked final path: $FINAL" >&2; exit 73; }
INSTALLED_PACK=$(find "$SOUNDS_DIR" -mindepth 1 -maxdepth 1 \
  -name 'CuratedPacks-*' -print)
[ -z "$INSTALLED_PACK" ] || [ "$INSTALLED_PACK" = "$FINAL" ] \
  || { echo "installed curated pack does not match generated content address: $INSTALLED_PACK" >&2; exit 65; }
CHECKED_MANIFEST="$SOUNDS_DIR/CuratedPacks.sha256"
[ ! -L "$CHECKED_MANIFEST" ] || { echo "refusing symlinked checked manifest: $CHECKED_MANIFEST" >&2; exit 73; }
PACK_DIRECTORY=$(basename "$FINAL")
awk -v directory="$PACK_DIRECTORY" '{print $1 "  " directory "/" $2}' \
  "$MANIFEST" > "$CHECKED_MANIFEST_STAGING"

if [ -e "$FINAL" ]; then
  [ -d "$FINAL" ] || { echo "final path exists and is not a directory: $FINAL" >&2; exit 73; }
  FINAL_FILES=$(for path in "$FINAL"/*; do [ -f "$path" ] && basename "$path"; done | LC_ALL=C sort)
  [ "$FINAL_FILES" = "$EXPECTED_FILES" ] \
    || { echo "existing content-addressed pack allowlist mismatch" >&2; exit 65; }
  [ "$(find "$FINAL" -type f | wc -l | tr -d ' ')" = "15" ] \
    || { echo "existing content-addressed pack contains nested or extra files" >&2; exit 65; }
  (cd "$FINAL" && shasum -a 256 -c "$MANIFEST" >/dev/null)
else
  rm -f -- "$MANIFEST"
  mv -- "$STAGING" "$FINAL"
fi
mv -f -- "$CHECKED_MANIFEST_STAGING" "$CHECKED_MANIFEST"
cleanup
trap - EXIT HUP INT TERM
echo "installed=$FINAL"
echo "manifest_hash=$MANIFEST_HASH"
echo "manifest=$CHECKED_MANIFEST"

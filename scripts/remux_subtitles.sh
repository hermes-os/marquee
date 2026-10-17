#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/remux_subtitles.sh [--in-place] [--mkv] ROOT_DIR

Walk ROOT_DIR and remux .mp4/.mov files that have a same-basename .srt file.

Options:
  --mkv       Write MKV files instead of MP4/MOV containers.
  --in-place  Replace the source file after writing a .bak copy. Not allowed with --mkv.

Default output goes to a sibling _remuxed/ folder under each source folder.
All actions are logged to remux_log.txt in the current working directory.
USAGE
}

mode="copy"
container="source"
root=""
log_file="remux_log.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-place)
      mode="in_place"
      shift
      ;;
    --mkv)
      container="mkv"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$root" ]]; then
        echo "Only one ROOT_DIR is supported." >&2
        usage >&2
        exit 2
      fi
      root="$1"
      shift
      ;;
  esac
done

if [[ -z "$root" ]]; then
  usage >&2
  exit 2
fi

if [[ "$mode" == "in_place" && "$container" == "mkv" ]]; then
  echo "--in-place cannot be combined with --mkv because the extension changes." >&2
  exit 2
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required but was not found in PATH." >&2
  exit 127
fi

if [[ ! -d "$root" ]]; then
  echo "ROOT_DIR does not exist or is not a directory: $root" >&2
  exit 2
fi

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log_file"
}

output_path_for() {
  local video="$1"
  local dir
  local filename
  local base
  local ext

  dir="$(dirname "$video")"
  filename="$(basename "$video")"
  base="${filename%.*}"
  ext="${filename##*.}"

  if [[ "$mode" == "in_place" ]]; then
    printf '%s/.%s.remux.tmp.%s' "$dir" "$base" "$ext"
    return
  fi

  mkdir -p "$dir/_remuxed"
  if [[ "$container" == "mkv" ]]; then
    printf '%s/_remuxed/%s.mkv' "$dir" "$base"
  else
    printf '%s/_remuxed/%s.%s' "$dir" "$base" "$ext"
  fi
}

remux_one() {
  local video="$1"
  local dir
  local filename
  local base
  local srt
  local output
  local backup

  dir="$(dirname "$video")"
  filename="$(basename "$video")"
  base="${filename%.*}"
  srt="$dir/$base.srt"

  if [[ ! -f "$srt" ]]; then
    log "SKIP no matching SRT: $video"
    return
  fi

  output="$(output_path_for "$video")"
  if [[ "$mode" != "in_place" && -f "$output" ]]; then
    log "SKIP output exists: $output"
    return
  fi

  log "REMUX start: $video"
  if [[ "$container" == "mkv" ]]; then
    ffmpeg -hide_banner -y -i "$video" -i "$srt" -map 0 -map 1 -c copy "$output" >>"$log_file" 2>&1
  else
    ffmpeg -hide_banner -y -i "$video" -i "$srt" -map 0 -map 1 -c copy -c:s mov_text "$output" >>"$log_file" 2>&1
  fi

  if [[ "$mode" == "in_place" ]]; then
    backup="$video.bak"
    if [[ -e "$backup" ]]; then
      log "FAIL backup exists, leaving temp output: $backup"
      return
    fi
    mv "$video" "$backup"
    mv "$output" "$video"
    log "OK in-place: $video backup=$backup"
  else
    log "OK output: $output"
  fi
}

log "START root=$root mode=$mode container=$container"

while IFS= read -r -d '' video; do
  remux_one "$video"
done < <(find "$root" -type f \( -iname '*.mp4' -o -iname '*.mov' \) -print0)

log "DONE"

#!/usr/bin/env bash
set -euo pipefail

cmake --build build/v3-debug
export QT_LOGGING_RULES="marquee.*=true"
exec ./build/v3-debug/marquee "$@"

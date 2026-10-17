#!/usr/bin/env bash
set -euo pipefail

cmake -S . -B build/v3-debug -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DMARQUEE_BUILD_TESTS=ON \
  "$@"

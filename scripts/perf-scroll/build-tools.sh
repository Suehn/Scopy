#!/bin/zsh
# Compiles the small Swift helpers used by profile_scroll.py and profile_capture.py / profile_search.py into scripts/perf-scroll/build/.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
# A compile failure must fail the build, otherwise a stale binary silently measures the wrong thing.
for tool in wheel winpos warp axcheck typekeys click pbwrite axsearch axrows statusclick panelready panelwatch hoverstall enterlatency; do
  swiftc -O "$tool.swift" -o "build/$tool"
done
ls build

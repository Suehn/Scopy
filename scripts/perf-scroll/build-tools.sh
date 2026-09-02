#!/bin/zsh
# Compiles the small Swift helpers used by profile_scroll.py into scripts/perf-scroll/build/.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for tool in wheel winpos warp mouseloc axcheck; do
  swiftc -O "$tool.swift" -o "build/$tool" 2>&1 | grep -v warning || true
done
ls build

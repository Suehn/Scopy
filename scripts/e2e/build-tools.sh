#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p scripts/e2e/build
swiftc -O scripts/e2e/bridge.swift -o scripts/e2e/build/bridge
for tool in click typekeys warp winpos wheel enterlatency axcheck; do
    swiftc -O "scripts/perf-scroll/$tool.swift" -o "scripts/e2e/build/$tool"
done

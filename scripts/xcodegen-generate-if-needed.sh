#!/bin/bash
set -euo pipefail

STAMP_FILE=".xcodegen.signature"
PBXPROJ_FILE="Scopy.xcodeproj/project.pbxproj"

compute_signature() {
    local project_hashes
    local swift_paths_hash

    project_hashes=$(
        shasum project.yml Package.swift 2>/dev/null \
            | awk '{print $1}' \
            | tr '\n' ' '
    )

    swift_paths_hash=$(
        find Scopy ScopyTests ScopyUITests ScopyTestHost \
            -type f \
            -name "*.swift" \
            -print 2>/dev/null \
            | sort \
            | shasum \
            | awk '{print $1}'
    )

    echo "${project_hashes}|${swift_paths_hash}" | shasum | awk '{print $1}'
}

main() {
    local sig
    sig="$(compute_signature)"

    if [[ "${FORCE_XCODEGEN:-}" == "1" ]]; then
        echo "FORCE_XCODEGEN=1 set; generating Xcode project..."
        xcodegen generate
        echo "$sig" > "$STAMP_FILE"
        return 0
    fi

    if [[ -f "$PBXPROJ_FILE" ]] && [[ -f "$STAMP_FILE" ]] && [[ "$(cat "$STAMP_FILE")" == "$sig" ]]; then
        echo "Xcode project up-to-date; skipping xcodegen"
        return 0
    fi

    echo "Generating Xcode project..."
    xcodegen generate
    echo "$sig" > "$STAMP_FILE"
}

main "$@"


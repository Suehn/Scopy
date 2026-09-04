#!/bin/bash
set -euo pipefail

STAMP_FILE=".xcodegen.signature"
PBXPROJ_FILE="Scopy.xcodeproj/project.pbxproj"

compute_signature() {
    local project_hashes
    local source_paths_hash
    local generator_version

    project_hashes=$(
        shasum project.yml Package.swift 2>/dev/null \
            | awk '{print $1}' \
            | tr '\n' ' '
    )

    # XcodeGen also discovers resources and asset catalogs. Their addition/removal
    # changes the project even when the set of Swift sources stays the same.
    source_paths_hash=$(
        find Scopy ScopyTests ScopyUITests ScopyTestHost \
            -name .DS_Store -prune -o \
            -print 2>/dev/null \
            | LC_ALL=C sort \
            | shasum \
            | awk '{print $1}'
    )

    generator_version="$(xcodegen --version)"
    echo "${project_hashes}|${source_paths_hash}|${generator_version}" | shasum | awk '{print $1}'
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

#!/bin/bash
set -euo pipefail

tag_on_head() {
    git tag --points-at HEAD --list 'v[0-9]*' --sort=v:refname | grep -v '^v0\.18\.' | tail -n 1 || true
}

best_merged_tag() {
    git tag --merged HEAD --list 'v[0-9]*' --sort=v:refname | grep -v '^v0\.18\.' | tail -n 1 || true
}

resolve_tag() {
    local tag
    tag="$(tag_on_head)"
    if [[ -n "${tag}" ]]; then
        echo "${tag}"
        return 0
    fi
    best_merged_tag
}

marketing_version_from_tag() {
    local tag="$1"
    if [[ -z "${tag}" ]]; then
        echo "0.0.0"
        return 0
    fi
    echo "${tag#v}"
}

build_number() {
    git rev-list --count HEAD 2>/dev/null || echo "0"
}

print_xcodebuild_args() {
    local tag version build
    tag="$(resolve_tag)"
    version="$(marketing_version_from_tag "${tag}")"
    build="$(build_number)"
    echo "MARKETING_VERSION=${version} CURRENT_PROJECT_VERSION=${build}"
}

usage() {
    cat <<EOF
Usage: scripts/version.sh [--tag|--marketing|--build|--xcodebuild-args]

  --tag            Print resolved git tag (prefers tag on HEAD, else nearest)
  --marketing       Print MARKETING_VERSION derived from tag (default 0.0.0)
  --build           Print CURRENT_PROJECT_VERSION (git rev-list --count HEAD)
  --xcodebuild-args Print: MARKETING_VERSION=... CURRENT_PROJECT_VERSION=...
EOF
}

main() {
    local cmd="${1:---xcodebuild-args}"
    case "${cmd}" in
    --tag)
        resolve_tag
        ;;
    --marketing)
        marketing_version_from_tag "$(resolve_tag)"
        ;;
    --build)
        build_number
        ;;
    --xcodebuild-args)
        print_xcodebuild_args
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Unknown option: ${cmd}" >&2
        usage >&2
        exit 2
        ;;
    esac
}

main "$@"

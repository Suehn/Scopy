#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

DOC_INDEX="doc/implementation/README.md"

extract_current_version_tag() {
    if [[ ! -f "${DOC_INDEX}" ]]; then
        echo "Missing ${DOC_INDEX}" >&2
        exit 1
    fi

    # Expected line: | **当前版本** | v0.43.18 |
    local tag
    tag="$(awk -F'|' '/\*\*当前版本\*\*/ {gsub(/[[:space:]]/, "", $3); print $3; exit}' "${DOC_INDEX}")"
    if [[ -z "${tag}" ]]; then
        echo "Failed to parse current version from ${DOC_INDEX}" >&2
        exit 1
    fi
    if [[ "${tag}" != v* ]]; then
        echo "Invalid version tag in ${DOC_INDEX}: ${tag} (expected prefix 'v')" >&2
        exit 1
    fi
    if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?([-.][0-9A-Za-z]+)?$ ]]; then
        echo "Invalid version tag format in ${DOC_INDEX}: ${tag}" >&2
        exit 1
    fi
    if [[ "${tag}" =~ ^v0\.18\. ]]; then
        echo "Refusing legacy tag line in ${DOC_INDEX}: ${tag}" >&2
        exit 1
    fi

    echo "${tag}"
}

ensure_clean_worktree() {
    if ! git diff --quiet; then
        echo "Working tree has unstaged changes; commit/stash before tagging." >&2
        exit 1
    fi
    if ! git diff --cached --quiet; then
        echo "Index has staged changes; commit/stash before tagging." >&2
        exit 1
    fi
}

tag_message() {
    local tag="$1"
    local doc_file="doc/implementation/releases/${tag}.md"
    if [[ -f "${doc_file}" ]]; then
        local title
        title="$(awk 'NR==1{print; exit}' "${doc_file}")"
        title="${title#\# }"
        echo "${title}"
        return 0
    fi
    echo "Release ${tag}"
}

main() {
    local cmd="${1:---ensure}"

    local tag
    tag="$(extract_current_version_tag)"

    case "${cmd}" in
    --tag)
        echo "${tag}"
        exit 0
        ;;
    --ensure)
        ;;
    *)
        echo "Usage: scripts/release/tag-from-doc.sh [--ensure|--tag]" >&2
        exit 2
        ;;
    esac

    ensure_clean_worktree

    if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        if [[ "$(git rev-list -n 1 "${tag}")" != "$(git rev-parse HEAD)" ]]; then
            echo "Tag ${tag} already exists but does not point at HEAD; refusing to retag." >&2
            exit 1
        fi
        echo "${tag}"
        exit 0
    fi

    local message
    message="$(tag_message "${tag}")"
    git tag -a "${tag}" -m "${message}"
    echo "${tag}"
}

main "$@"

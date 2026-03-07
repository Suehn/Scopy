#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

source scripts/release/release-metadata.sh

validate_tag() {
    local tag="$1"
    if [[ -z "${tag}" || "${tag}" != v* ]]; then
        echo "Invalid tag in release metadata: ${tag}" >&2
        exit 1
    fi
    if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?([-.][0-9A-Za-z]+)?$ ]]; then
        echo "Invalid tag format in release metadata: ${tag}" >&2
        exit 1
    fi
    if [[ "${tag}" =~ ^v0\.18\. ]]; then
        echo "Refusing legacy tag in release metadata: ${tag}" >&2
        exit 1
    fi
}

ensure_clean_worktree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Working tree is not clean (includes untracked files); commit/stash before tagging." >&2
        git status --short >&2
        exit 1
    fi
}

ensure_release_doc_tracked() {
    local doc_file="$1"
    if [[ ! -f "${doc_file}" ]]; then
        echo "Missing release doc: ${doc_file}" >&2
        exit 1
    fi
    if ! git ls-files --error-unmatch "${doc_file}" >/dev/null 2>&1; then
        echo "Release doc is not tracked in git: ${doc_file}" >&2
        exit 1
    fi
}

tag_message() {
    local doc_file="$1"
    if [[ -f "${doc_file}" ]]; then
        local title
        title="$(awk 'NR==1{print; exit}' "${doc_file}")"
        title="${title#\# }"
        echo "${title}"
        return 0
    fi
    echo "Release $(release_meta_require version)"
}

main() {
    local cmd="${1:---ensure}"
    local tag doc_file

    tag="$(release_meta_require version)"
    doc_file="$(release_meta_require release_doc)"
    validate_tag "${tag}"

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
    ensure_release_doc_tracked "${doc_file}"

    if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        if [[ "$(git rev-list -n 1 "${tag}")" != "$(git rev-parse HEAD)" ]]; then
            echo "Tag ${tag} already exists but does not point at HEAD; refusing to retag." >&2
            exit 1
        fi
        echo "${tag}"
        exit 0
    fi

    git tag -a "${tag}" -m "$(tag_message "${doc_file}")"
    echo "${tag}"
}

main "$@"


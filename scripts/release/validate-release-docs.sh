#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

source scripts/release/release-metadata.sh

TAG="$(release_meta_require version)"
RELEASE_DOC="$(release_meta_require release_doc)"
CHANGELOG="$(release_meta_require changelog_file)"
METADATA_FILE="$(release_meta_file)"

if [[ ! -f "${METADATA_FILE}" ]]; then
    echo "Missing ${METADATA_FILE}" >&2
    exit 1
fi

if [[ ! -f "${RELEASE_DOC}" ]]; then
    echo "Missing version doc: ${RELEASE_DOC}" >&2
    exit 1
fi

if [[ ! -f "${CHANGELOG}" ]]; then
    echo "Missing changelog: ${CHANGELOG}" >&2
    exit 1
fi

if [[ "$(basename "${RELEASE_DOC}" .md)" != "${TAG}" ]]; then
    echo "release_doc basename does not match version: ${RELEASE_DOC} vs ${TAG}" >&2
    exit 1
fi

if ! grep -Fq "## [${TAG}]" "${CHANGELOG}"; then
    echo "Changelog does not contain heading: ## [${TAG}] ..." >&2
    exit 1
fi

echo "OK: ${TAG}"


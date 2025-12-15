#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

TAG="$(bash scripts/release/tag-from-doc.sh --tag)"
if [[ -z "${TAG}" || "${TAG}" != v* ]]; then
    echo "Failed to resolve release tag from doc index." >&2
    exit 1
fi
if [[ "${TAG}" =~ ^v0\.18\. ]]; then
    echo "Refusing legacy tag: ${TAG}" >&2
    exit 1
fi

DOC_INDEX="doc/implemented-doc/README.md"
VERSION_DOC="doc/implemented-doc/${TAG}.md"
CHANGELOG="doc/implemented-doc/CHANGELOG.md"

if [[ ! -f "${DOC_INDEX}" ]]; then
    echo "Missing ${DOC_INDEX}" >&2
    exit 1
fi

if [[ ! -f "${VERSION_DOC}" ]]; then
    echo "Missing version doc: ${VERSION_DOC}" >&2
    exit 1
fi

if [[ ! -f "${CHANGELOG}" ]]; then
    echo "Missing changelog: ${CHANGELOG}" >&2
    exit 1
fi

if ! rg -n "^## \\[${TAG}\\]" "${CHANGELOG}" >/dev/null; then
    echo "Changelog does not contain heading: ## [${TAG}] ..." >&2
    exit 1
fi

echo "OK: ${TAG}"


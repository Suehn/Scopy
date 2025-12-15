#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

TAG="$(bash scripts/release/tag-from-doc.sh --ensure)"
if [[ -z "${TAG}" || "${TAG}" != v* ]]; then
    echo "Failed to resolve tag after tagging step." >&2
    exit 1
fi

git push origin main
git push origin "${TAG}"

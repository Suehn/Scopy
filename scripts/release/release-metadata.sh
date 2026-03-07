#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
METADATA_FILE="${PROJECT_ROOT}/doc/meta/release-current.yml"

release_meta_file() {
    echo "${METADATA_FILE}"
}

release_meta_get() {
    local key="$1"
    python3 - "${METADATA_FILE}" "${key}" <<'PY'
import pathlib
import sys

meta_path = pathlib.Path(sys.argv[1])
query = sys.argv[2]

if not meta_path.is_file():
    raise SystemExit(f"Missing metadata file: {meta_path}")

data = {}
current_top = None
for raw in meta_path.read_text(encoding="utf-8").splitlines():
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    indent = len(raw) - len(raw.lstrip(" "))
    stripped = raw.strip()
    if ":" not in stripped:
        continue
    key, value = stripped.split(":", 1)
    value = value.strip()
    if indent == 0:
        current_top = key
        if value == "":
            data[key] = {}
        else:
            data[key] = None if value == "null" else value
    elif indent == 2 and current_top:
        bucket = data.setdefault(current_top, {})
        if not isinstance(bucket, dict):
            bucket = {}
            data[current_top] = bucket
        bucket[key] = None if value == "null" else value

node = data
for part in query.split("."):
    if not isinstance(node, dict) or part not in node:
        raise SystemExit("")
    node = node[part]

if node is None:
    print("null")
else:
    print(node)
PY
}

release_meta_require() {
    local key="$1"
    local value
    value="$(release_meta_get "$key" || true)"
    if [[ -z "${value}" || "${value}" == "null" ]]; then
        echo "Missing required metadata key: ${key}" >&2
        exit 1
    fi
    echo "${value}"
}


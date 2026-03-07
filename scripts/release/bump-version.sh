#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

source scripts/release/release-metadata.sh

RELEASE_INDEX="doc/releases/README.md"
CHANGELOG="$(release_meta_require changelog_file)"

usage() {
    cat <<EOF
Usage: scripts/release/bump-version.sh [--patch] [--title "Summary line"]

  --patch   Bump patch version (default)
  --title   Optional short summary used in metadata and changelog placeholders
EOF
}

parse_args() {
    BUMP_KIND="patch"
    TITLE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --patch)
            BUMP_KIND="patch"
            shift
            ;;
        --title)
            TITLE="${2:-}"
            if [[ -z "${TITLE}" ]]; then
                echo "Missing --title value" >&2
                exit 2
            fi
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        esac
    done
}

ensure_clean_worktree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Working tree is not clean (includes untracked files); commit/stash before bumping version docs." >&2
        git status --short >&2
        exit 1
    fi
}

bump_patch_tag() {
    local tag="$1"
    if [[ ! "${tag}" =~ ^v([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
        echo "Unsupported tag format for --patch bump: ${tag} (expected vX.Y or vX.Y.Z)" >&2
        exit 1
    fi
    local major minor patch
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[4]:-0}"
    patch=$((patch + 1))
    echo "v${major}.${minor}.${patch}"
}

create_version_doc() {
    local tag="$1"
    local summary="$2"
    local doc="doc/releases/history/${tag}.md"

    if [[ -f "${doc}" ]]; then
        echo "Version doc already exists: ${doc}" >&2
        exit 1
    fi

    cat > "${doc}" <<EOF
# ${tag}

## Summary

- ${summary}

## Key Changes

- TODO

## Verification

- TODO

## Follow-up

- TODO
EOF
}

insert_changelog_section() {
    local tag="$1"
    local date_str="$2"
    local summary="$3"

    python3 - "${CHANGELOG}" "${tag}" "${date_str}" "${summary}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
tag = sys.argv[2]
date_str = sys.argv[3]
summary = sys.argv[4]
text = path.read_text(encoding="utf-8")
heading = f"## [{tag}] - {date_str}\n\n### {summary}\n\n- TODO\n"
if f"## [{tag}]" in text:
    raise SystemExit(f"Changelog already contains {tag}")
needle = "## [Unreleased]\n\n### Notes\n\n- No unreleased entries.\n"
if needle in text:
    text = text.replace(needle, needle + "\n" + heading + "\n", 1)
else:
    marker = "## [Unreleased]"
    idx = text.find(marker)
    if idx == -1:
        text = heading + "\n" + text
    else:
        insert_at = text.find("\n", idx)
        text = text[:insert_at + 1] + "\n" + heading + "\n" + text[insert_at + 1:]
path.write_text(text, encoding="utf-8")
PY
}

update_release_metadata_and_index() {
    local old_tag="$1"
    local new_tag="$2"
    local date_str="$3"
    local summary="$4"

    python3 - "$(release_meta_file)" "${RELEASE_INDEX}" "${new_tag}" "${date_str}" "${summary}" <<'PY'
from pathlib import Path
import re
import sys

meta_path = Path(sys.argv[1])
index_path = Path(sys.argv[2])
tag = sys.argv[3]
date_str = sys.argv[4]
summary = sys.argv[5]

meta = meta_path.read_text(encoding="utf-8")
meta = re.sub(r"^version: .*$", f"version: {tag}", meta, count=1, flags=re.M)
meta = re.sub(r"^date: .*$", f"date: {date_str}", meta, count=1, flags=re.M)
meta = re.sub(r"^release_doc: .*$", f"release_doc: doc/releases/history/{tag}.md", meta, count=1, flags=re.M)
meta = re.sub(r"^profile_doc: .*$", "profile_doc: null", meta, count=1, flags=re.M)
meta = re.sub(r"^last_verified_at: .*$", f"last_verified_at: {date_str}", meta, count=1, flags=re.M)
meta = re.sub(r"^summary: .*$", f"summary: {summary}", meta, count=1, flags=re.M)
meta_path.write_text(meta, encoding="utf-8")

current_block = f"""<!-- release-current:start -->
- Version: `{tag}`
- Date: `{date_str}`
- Release note: [{tag}](./history/{tag}.md)
- Changelog: [CHANGELOG.md](./CHANGELOG.md)
- Profile doc: `none`
<!-- release-current:end -->""".replace("`", chr(96))

index = index_path.read_text(encoding="utf-8")
index = re.sub(r"<!-- release-current:start -->.*?<!-- release-current:end -->", current_block, index, count=1, flags=re.S)

recent_match = re.search(r"<!-- release-recent:start -->\n(.*?)\n<!-- release-recent:end -->", index, flags=re.S)
if not recent_match:
    raise SystemExit("Missing recent release markers in doc/releases/README.md")
recent_lines = [line for line in recent_match.group(1).splitlines() if line.strip()]
new_line = f"- `{date_str}` [{tag}](./history/{tag}.md) - {summary}".replace("`", chr(96))
recent_lines = [new_line] + [line for line in recent_lines if f"[{tag}]" not in line]
recent_lines = recent_lines[:12]
recent_block = "<!-- release-recent:start -->\n" + "\n".join(recent_lines) + "\n<!-- release-recent:end -->"
index = re.sub(r"<!-- release-recent:start -->.*?<!-- release-recent:end -->", recent_block, index, count=1, flags=re.S)
index_path.write_text(index, encoding="utf-8")
PY
}

main() {
    parse_args "$@"
    ensure_clean_worktree

    local old_tag new_tag date_str summary
    old_tag="$(release_meta_require version)"

    case "${BUMP_KIND}" in
    patch)
        new_tag="$(bump_patch_tag "${old_tag}")"
        ;;
    *)
        echo "Unsupported bump kind: ${BUMP_KIND}" >&2
        exit 2
        ;;
    esac

    date_str="$(date +%Y-%m-%d)"
    summary="${TITLE:-Dev/Release: TODO}"

    create_version_doc "${new_tag}" "${summary}"
    update_release_metadata_and_index "${old_tag}" "${new_tag}" "${date_str}" "${summary}"
    insert_changelog_section "${new_tag}" "${date_str}" "${summary}"

    echo "Bumped: ${old_tag} -> ${new_tag}"
    echo "Next:"
    echo "  - Fill in doc: doc/releases/history/${new_tag}.md"
    echo "  - Review metadata + release index + changelog"
    echo "  - Run: make docs-validate && make release-validate"
    echo "  - Commit, then run: make tag-release"
    echo "  - Publish: make push-release"
}

main "$@"


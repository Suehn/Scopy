#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

DOC_INDEX="doc/implemented-doc/README.md"
CHANGELOG="doc/implemented-doc/CHANGELOG.md"

usage() {
    cat <<EOF
Usage: scripts/release/bump-version.sh [--patch] [--title "Summary line"]

  --patch   Bump patch version (default)
  --title   Optional short summary used in README/CHANGELOG placeholders
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

extract_current_tag() {
    if [[ ! -f "${DOC_INDEX}" ]]; then
        echo "Missing ${DOC_INDEX}" >&2
        exit 1
    fi
    local tag
    tag="$(awk -F'|' '/\*\*当前版本\*\*/ {gsub(/[[:space:]]/, "", $3); print $3; exit}' "${DOC_INDEX}")"
    if [[ -z "${tag}" ]]; then
        echo "Failed to parse current version from ${DOC_INDEX}" >&2
        exit 1
    fi
    echo "${tag}"
}

bump_patch_tag() {
    local tag="$1"
    if [[ ! "${tag}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "Unsupported tag format for --patch bump: ${tag} (expected vX.Y.Z)" >&2
        exit 1
    fi
    local major minor patch
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    patch=$((patch + 1))
    echo "v${major}.${minor}.${patch}"
}

ensure_clean_worktree() {
    if ! git diff --quiet; then
        echo "Working tree has unstaged changes; commit/stash before bumping version docs." >&2
        exit 1
    fi
    if ! git diff --cached --quiet; then
        echo "Index has staged changes; commit/stash before bumping version docs." >&2
        exit 1
    fi
}

insert_changelog_section() {
    local tag="$1"
    local date_str="$2"
    local summary="$3"

    if [[ ! -f "${CHANGELOG}" ]]; then
        echo "Missing ${CHANGELOG}" >&2
        exit 1
    fi

    if rg -n "^## \\[${tag}\\]" "${CHANGELOG}" >/dev/null; then
        echo "Changelog already contains ${tag}; refusing to insert." >&2
        exit 1
    fi

    local tmp
    tmp="$(mktemp)"
    awk -v tag="${tag}" -v date_str="${date_str}" -v summary="${summary}" '
      BEGIN { inserted=0 }
      /^## \[/ && inserted==0 {
        print "## [" tag "] - " date_str
        print ""
        print "### " summary
        print ""
        print "- TODO"
        print ""
        inserted=1
      }
      { print }
    ' "${CHANGELOG}" > "${tmp}"
    mv "${tmp}" "${CHANGELOG}"
}

update_doc_index() {
    local old_tag="$1"
    local new_tag="$2"
    local date_str="$3"
    local summary="$4"

    local tmp
    tmp="$(mktemp)"
    awk -v old_tag="${old_tag}" -v new_tag="${new_tag}" -v date_str="${date_str}" -v summary="${summary}" '
      {
        line=$0
        if (line ~ /\| \*\*当前版本\*\* \|/) {
          gsub(old_tag, new_tag, line)
        }
        if (line ~ /\| \*\*最后更新\*\* \|/) {
          sub(/\| \*\*最后更新\*\* \| [0-9]{4}-[0-9]{2}-[0-9]{2} \|/, "| **最后更新** | " date_str " |", line)
        }
        print line
      }
    ' "${DOC_INDEX}" > "${tmp}"
    mv "${tmp}" "${DOC_INDEX}"

    if ! rg -n "\\| \\[${new_tag}\\]\\(\\./${new_tag}\\.md\\)" "${DOC_INDEX}" >/dev/null; then
        tmp="$(mktemp)"
        awk -v new_tag="${new_tag}" -v date_str="${date_str}" -v summary="${summary}" '
          BEGIN { inserted=0 }
          /^\| \[v/ && inserted==0 {
            print "| [" new_tag "](./" new_tag ".md) | " date_str " | " summary " | ✅ |"
            inserted=1
          }
          { print }
        ' "${DOC_INDEX}" > "${tmp}"
        mv "${tmp}" "${DOC_INDEX}"
    fi
}

create_version_doc() {
    local tag="$1"
    local date_str="$2"
    local summary="$3"

    local doc="doc/implemented-doc/${tag}.md"
    if [[ -f "${doc}" ]]; then
        echo "Version doc already exists: ${doc}" >&2
        exit 1
    fi

    cat > "${doc}" <<EOF
# ${tag}

## 📌 一页纸总结（What / Why / Result）

### What

- ${summary}

### Why

- TODO

### Result

- TODO

---

## 🏗️ 实现路线

1. TODO

---

## 📂 核心改动

- TODO

---

## 🎯 关键指标

- TODO

---

## 📊 当前状态

- 单元测试：\`make test-unit\` TODO
- Strict Concurrency：\`make test-strict\` TODO

---

## 🔮 遗留与后续

- TODO
EOF
}

main() {
    parse_args "$@"
    ensure_clean_worktree

    local old_tag new_tag date_str summary
    old_tag="$(extract_current_tag)"
    if [[ "${old_tag}" =~ ^v0\.18\. ]]; then
        echo "Refusing legacy tag in doc index: ${old_tag}" >&2
        exit 1
    fi

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

    create_version_doc "${new_tag}" "${date_str}" "${summary}"
    update_doc_index "${old_tag}" "${new_tag}" "${date_str}" "${summary}"
    insert_changelog_section "${new_tag}" "${date_str}" "${summary}"

    echo "Bumped: ${old_tag} -> ${new_tag}"
    echo "Next:"
    echo "  - Fill in doc: doc/implemented-doc/${new_tag}.md"
    echo "  - Update doc index + changelog if needed"
    echo "  - Commit, then push to main (auto-tag will tag from doc index)"
}

main "$@"


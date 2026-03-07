#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "${PROJECT_ROOT}"

source scripts/release/release-metadata.sh

python3 - <<'PY'
from pathlib import Path
import re
import sys

root = Path(".").resolve()
required_docs = [
    Path("doc/current/README.md"),
    Path("doc/current/maintainer-guide.md"),
    Path("doc/current/development-guide.md"),
    Path("doc/current/release-runbook.md"),
    Path("doc/releases/README.md"),
    Path("doc/releases/history/README.md"),
    Path("doc/perf/README.md"),
    Path("doc/perf/baselines/README.md"),
    Path("doc/perf/release-profiles/README.md"),
    Path("doc/perf/studies/README.md"),
    Path("doc/reviews/README.md"),
    Path("doc/reviews/code/README.md"),
    Path("doc/reviews/perf/README.md"),
    Path("doc/reviews/implementation/README.md"),
    Path("doc/proposals/README.md"),
    Path("doc/meta/doc-taxonomy.md"),
    Path("doc/archive/specs/README.md"),
]
missing = [str(p) for p in required_docs if not p.exists()]
if missing:
    print("Missing required docs:", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)

scan_files = []
for pattern in ["README.md", "CLAUDE.md", "AGENTS.md", "DEPLOYMENT.md", "doc/**/*.md"]:
    scan_files.extend(root.glob(pattern))
scan_files = sorted({p for p in scan_files if p.exists()})

exclude_roots = [
    (root / "doc/archive").resolve(),
]
link_re = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
errors = []

for file_path in scan_files:
    resolved_path = file_path.resolve()
    if any(str(resolved_path).startswith(str(ex)) for ex in exclude_roots):
        continue
    text = resolved_path.read_text(encoding="utf-8")
    text = re.sub(r"\`\`\`[\s\S]*?\`\`\`", "", text)
    for target in link_re.findall(text):
        if target.startswith(("http://", "https://", "#", "mailto:")):
            continue
        clean = target.split("#", 1)[0]
        resolved = (resolved_path.parent / clean).resolve()
        if not resolved.exists():
            errors.append(f"{file_path.relative_to(root)} -> missing {target}")

if errors:
    print("Broken markdown links:", file=sys.stderr)
    for item in errors:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
PY

TAG="$(release_meta_require version)"
DATE="$(release_meta_require date)"
RELEASE_DOC="$(release_meta_require release_doc)"
CHANGELOG="$(release_meta_require changelog_file)"
PROFILE_DOC="$(release_meta_get profile_doc || true)"
RELEASE_INDEX="$(release_meta_require release_index)"
DEVELOPMENT_DOC="$(release_meta_require development_doc)"

if [[ ! -f "${DEVELOPMENT_DOC}" ]]; then
    echo "development_doc does not exist: ${DEVELOPMENT_DOC}" >&2
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

if ! grep -Fq -- "- Version: \`${TAG}\`" "${RELEASE_INDEX}"; then
    echo "Release index current block does not match metadata version: ${TAG}" >&2
    exit 1
fi

if ! grep -Fq -- "- Date: \`${DATE}\`" "${RELEASE_INDEX}"; then
    echo "Release index current block does not match metadata date: ${DATE}" >&2
    exit 1
fi

if ! grep -Fq -- "- Release note: [${TAG}](./history/${TAG}.md)" "${RELEASE_INDEX}"; then
    echo "Release index current block does not point at the metadata release doc: ${TAG}" >&2
    exit 1
fi

if [[ "${PROFILE_DOC}" == "null" || -z "${PROFILE_DOC}" ]]; then
    if ! grep -Fq -- "- Profile doc: \`none\`" "${RELEASE_INDEX}"; then
        echo "Release index current block should mark profile_doc as none" >&2
        exit 1
    fi
fi

echo "Docs OK: ${TAG}"

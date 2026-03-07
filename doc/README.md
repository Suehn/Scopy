---
doc_type: portal
status: active
owner: maintainers
last_reviewed: 2026-03-07
canonical: true
---

# Scopy Documentation

This directory is split into active operating docs, release history, performance evidence, reviews, and proposals.

## Start Here

- Current active doc set: [current/README.md](./current/README.md)
- Current maintainer workflow: [current/maintainer-guide.md](./current/maintainer-guide.md)
- Current development guide: [current/development-guide.md](./current/development-guide.md)
- Current release metadata: [meta/release-current.yml](./meta/release-current.yml)
- Current release index: [releases/README.md](./releases/README.md)
- Current requirements: [current/product-spec.md](./current/product-spec.md)
- Current release runbook: [current/release-runbook.md](./current/release-runbook.md)

## Structure

- `current/`: active maintainer docs that should describe today's truth.
- `releases/`: current release index, current changelog window, and historical release docs.
- `perf/`: release profiles, baselines, and deeper performance studies.
- `reviews/`: code, perf, and implementation reviews.
- `proposals/`: design drafts and future-looking specs that are not active requirements.
- `archive/`: preserved pre-reorg material and split historical changelog data.
- `meta/`: machine-readable metadata and doc taxonomy.

## Compatibility

- Legacy paths under `doc/implementation/`, `doc/profiles/`, and `doc/specs/` remain only as compatibility links for old references.
- Do not use those directories as new navigation entrypoints.
- New automation must read [meta/release-current.yml](./meta/release-current.yml), not scrape Markdown pages.

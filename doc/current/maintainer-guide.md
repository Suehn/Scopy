---
doc_type: guide
status: active
owner: maintainers
last_reviewed: 2026-04-24
canonical: true
related_versions:
  - v0.7.2
---

# Maintainer Guide

## Canonical Docs

- Release metadata: [../meta/release-current.yml](../meta/release-current.yml)
- Release index: [../releases/README.md](../releases/README.md)
- Release changelog: [../releases/CHANGELOG.md](../releases/CHANGELOG.md)
- Development guide: [development-guide.md](./development-guide.md)
- Release runbook: [release-runbook.md](./release-runbook.md)
- Requirements: [product-spec.md](./product-spec.md)
- Architecture/optimization guidance: [architecture.md](./architecture.md)

## Read By Scenario

### Release Work

- Start with [release-runbook.md](./release-runbook.md).
- Then confirm [../meta/release-current.yml](../meta/release-current.yml), [../releases/README.md](../releases/README.md), and [../releases/CHANGELOG.md](../releases/CHANGELOG.md).

### Product Or Architecture Work

- Read [product-spec.md](./product-spec.md) for current product boundaries.
- Then read [development-guide.md](./development-guide.md) for module structure, runtime flows, and implementation entrypoints.
- Use [architecture.md](./architecture.md) for runtime invariants and architectural constraints.

### Performance Or Regression Work

- Start with [../perf/README.md](../perf/README.md).
- Then branch into studies, release profiles, or perf reviews depending on whether you need root cause, version delta, or audit findings.

### Audit Or Review Work

- Start with [../reviews/README.md](../reviews/README.md).

## Validation

- `make docs-validate`
- `make release-validate`
- `bash scripts/release/tag-from-doc.sh --tag`

## Active Vs Historical Docs

- `doc/current/` contains active operating guidance and current constraints.
- `doc/releases/` contains the current release window and immutable release history.
- `doc/perf/` and `doc/reviews/` contain evidence, not source-of-truth product requirements.
- `doc/archive/` preserves pre-reorg material; use it for traceability, not day-to-day navigation.

## Compatibility Policy

- Legacy paths are preserved only for inbound compatibility. New links should target canonical locations under `doc/current`, `doc/releases`, `doc/perf`, `doc/reviews`, `doc/proposals`, and `doc/meta`.
- Do not add new automation that scrapes Markdown tables for release state.

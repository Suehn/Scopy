---
doc_type: taxonomy
status: active
owner: maintainers
last_reviewed: 2026-03-07
canonical: true
---

# Documentation Taxonomy

## Active Docs

- `portal`: entry pages that route maintainers to the right canonical docs.
- `runbook`: operational instructions that should match current automation and release flow.
- `spec`: active product or architecture requirements.
- `guide`: maintainer-facing process and governance docs.

## Historical Docs

- `release-note`: immutable release snapshot for one shipped version.
- `profile`: performance comparison for one release or benchmark window.
- `review`: audit, acceptance, or deep review output tied to concrete evidence.
- `proposal`: design or research doc that is not the active source of truth.
- `archive`: preserved legacy material kept for traceability after reorg.

## Rules

- Active docs should be concise and link outward to history rather than embedding it.
- Historical docs are append-only unless fixing metadata, broken links, or obvious factual mistakes.
- New automation may depend only on `doc/meta/*` and explicitly named canonical docs.


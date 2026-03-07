---
doc_type: portal
status: active
owner: maintainers
last_reviewed: 2026-03-07
canonical: true
---

# Performance Evidence

This directory holds the canonical performance evidence set.

## When To Read What

### Release Delta

- Start with [release-profiles/README.md](./release-profiles/README.md).

### Lab Baseline

- Start with [baselines/README.md](./baselines/README.md).

### Deep Investigation

- Start with [studies/README.md](./studies/README.md).

## Current Guidance

- Not every release requires a dedicated profile doc.
- If a release does not get a profile file, record `profile_doc: null` in [../meta/release-current.yml](../meta/release-current.yml) and keep the evidence in the release note or studies.
- Legacy pre-reorg profile index is preserved in [../archive/perf-index-legacy.md](../archive/perf-index-legacy.md).

## Preferred Reading Order

- Current release context: [../releases/README.md](../releases/README.md)
- Latest dedicated profile: [release-profiles/v0.59.fix3-profile.md](./release-profiles/v0.59.fix3-profile.md)
- Latest cross-cutting study: [studies/perf-front-back-unified-2026-02-28.md](./studies/perf-front-back-unified-2026-02-28.md)

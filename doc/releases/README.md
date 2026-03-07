---
doc_type: portal
status: active
owner: maintainers
last_reviewed: 2026-03-07
canonical: true
---

# Release Docs

This page is the human-facing index for current release state. Automation should read [../meta/release-current.yml](../meta/release-current.yml).

## How To Use This Page

- Treat the current release block as a human mirror of metadata.
- Use the recent release list as the operational window.
- Use [history/README.md](./history/README.md) for immutable release notes beyond the current window.

## Current Release

<!-- release-current:start -->
- Version: `v0.60.2`
- Date: `2026-03-07`
- Release note: [v0.60.2](./history/v0.60.2.md)
- Changelog: [CHANGELOG.md](./CHANGELOG.md)
- Profile doc: `none`
<!-- release-current:end -->

## Recent Releases

<!-- release-recent:start -->
- `2026-03-07` [v0.60.2](./history/v0.60.2.md) - Historical image replay compatibility fix for Codex and temporary image files
- `2026-02-28` [v0.60.1](./history/v0.60.1.md) - Perf and release hardening with frontend profile flow, unified perf table, and cleanup-path convergence
- `2026-01-30` [v0.60](./history/v0.60.md) - Refactor and stability release for settings persistence, storage deletion, and hotkey concurrency
- `2026-01-29` [v0.59.fix3](./history/v0.59.fix3.md) - Search and SQLite performance tightening with O(1) stats reads
- `2026-01-27` [v0.59.fix2](./history/v0.59.fix2.md) - Swift 6 strict-concurrency and test harness compatibility fixes
- `2026-01-19` [v0.59.fix1](./history/v0.59.fix1.md) - Full-index cache hardening and mutation-seq correctness fallback
- `2026-01-13` [v0.59](./history/v0.59.md) - Cold-start refine improvements and real DB regression coverage
- `2026-01-12` [v0.58.fix2](./history/v0.58.fix2.md) - Two-character Chinese short query optimization
- `2026-01-11` [v0.58.fix1](./history/v0.58.fix1.md) - Further two-character short query optimization
- `2026-01-11` [v0.58](./history/v0.58.md) - Large-text fuzzy search speed-up with real DB baseline
- `2026-01-03` [v0.57.fix2](./history/v0.57.fix2.md) - Excel clipboard semantics fix
<!-- release-recent:end -->

## Full History

- Current history directory: [history/README.md](./history/README.md)
- Legacy pre-reorg index snapshot: [../archive/release-index-legacy.md](../archive/release-index-legacy.md)

# Frontend Scroll Performance Baseline Manifest

## Capture

- Local time: `2026-07-10T22:58:36+0800`
- UTC time: `2026-07-10T14:58:36Z`
- Repository HEAD: `db7503a74797814d3df2e204370ecdeddcd6eb2c`
- Nearest tag: `v0.8.8`
- Branch: `main` tracking `origin/main`
- Worktree: dirty before this task's product-code implementation; existing safe-triangle, release/build, project, test, and documentation changes are preserved as user work.
- Project baselines from `project.yml`: Swift 5.9, macOS 14.0, Xcode project generation baseline 16.0.

## Machine and Toolchain

- Hardware: MacBook Pro (`Mac15,6`), Apple M3 Pro, 11 CPU cores, 36 GB memory.
- OS: macOS 15.7.3 (24G419), arm64.
- Xcode: 26.1.1 (17B100).
- SDK: macOS 26.1.
- XcodeGen: 2.45.4.

Machine-unique identifiers are intentionally omitted from the evidence artifact.

## Current Database Snapshot

- Source: `~/Library/Application Support/Scopy/clipboard.db`
- Repository-local ignored snapshot: `perf-db/clipboard.db`
- Snapshot command: `make snapshot-perf-db`
- Snapshot completed: `2026-07-10T22:58:16+0800`
- Snapshot size: 98,213,888 bytes.
- SHA-256: `9ef898f44b64a797ab1b62278d7b35e7b5a7d74fd1e5e6ac12536ad876a118b0`
- SQLite `user_version`: 7.
- Schema table version: 1.
- Journal mode reported from the copied database: WAL.
- Clipboard items: 7,776 total; 8 pinned; 2,873 text; 1,988 image.
- Metadata row: mutation sequence 4,537; 7,776 items; 7,768 unpinned; 548,921,941 logical content bytes; 397,922,323 external bytes.

## Pre-change Correctness Baseline

- `make build`: passed (`BUILD SUCCEEDED`).
- `make test-unit`: passed (`TEST SUCCEEDED`; 535 tests, 1 skipped, 0 failures).
- `git diff --check`: passed with no output.
- Apple API probe: `xcrun swiftc -typecheck -target arm64-apple-macos14.0 .trellis/tasks/07-10-frontend-scroll-performance/research/apple-api-probe.swift` passed.

These checks were run against the current dirty worktree before this task's product-code implementation. They establish correctness health, not a passive-row performance baseline. Causal performance evidence will come from the same-binary deterministic micro A/B after the measurement contract exists; realistic regression evidence will use the fingerprinted database above.

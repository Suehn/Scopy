---
doc_type: portal
status: active
owner: maintainers
last_reviewed: 2026-09-05
canonical: true
---

# Release Docs

This page is the human-facing index for current release state. Automation should read [../meta/release-current.yml](../meta/release-current.yml).

## How To Use This Page

- Treat the current release block as a human mirror of metadata.
- Use the recent release list as the operational window.
- Use [history/README.md](./history/README.md) for immutable release notes beyond the current window.
- Release titles and notes describe behavior at that version; they never override the current Markdown contract in [markdown-chatgpt-wacz-style-contract.md](../current/markdown-chatgpt-wacz-style-contract.md).

## Current Release

<!-- release-current:start -->
- Version: `v0.80.3`
- Date: `2026-09-05`
- Release note: [v0.80.3](./history/v0.80.3.md)
- Changelog: [CHANGELOG.md](./CHANGELOG.md)
- Profile doc: `none`
<!-- release-current:end -->

## Recent Releases

<!-- release-recent:start -->
- `2026-09-05` [v0.80.3](./history/v0.80.3.md) - Preserve Chinese tables and emphasis when capturing ChatGPT copies
- `2026-09-05` [v0.80.2](./history/v0.80.2.md) - Fix Chinese emphasis and single-dollar math while simplifying capture tests
- `2026-09-05` [v0.80.1](./history/v0.80.1.md) - Keep search pagination correctly ranked and apply new rows in small batches
- `2026-09-04` [v0.80.0](./history/v0.80.0.md) - Copy reports whether it reached the pasteboard, copied folders replay as folders, and any hover preview can be pinned into a movable, resizable, always-on-top window
- `2026-09-03` [v0.79.0](./history/v0.79.0.md) - Row construction stops doing render work and search indexes mutate in place: search typing blocks the main thread 31% less with 35% shorter worst stalls, clipboard capture 12% cheaper
- `2026-09-03` [v0.78.2](./history/v0.78.2.md) - Marker-bearing clipboard content remains captured; history pages skip inline payload blobs; search evidence failures stay correctly scoped
- `2026-09-03` [v0.78.1](./history/v0.78.1.md) - Protected pasteboard transactions stay out of history; valid search hits survive unrenderable match evidence
- `2026-09-03` [v0.78.0](./history/v0.78.0.md) - Hover previews at final size, search keeps rows while typing, rich copies stop blocking the main thread, binary index caches, prefetched and chunked page loads
- `2026-09-02` [v0.77.1](./history/v0.77.1.md) - Mouse-wheel scroll detection only starts on a current scroll-wheel event; test gates recorded for v0.77.0
- `2026-09-02` [v0.77.0](./history/v0.77.0.md) - Mouse-wheel scrolling suppresses hover work, selection stops re-diffing the List, 100-row pages: scroll CPU 9.9 -> 2.9 s, main thread 42% -> 22%, callback max 75 -> 17-25 ms
- `2026-09-02` [v0.76.0](./history/v0.76.0.md) - Real-input scroll profiling finds the cursor, revision, and observation costs; scroll CPU -32%, callback p95 83 -> 17 ms
- `2026-09-02` [v0.75.0](./history/v0.75.0.md) - Frame-driven export settle and a PAM-backed export canvas: post-load export 2-3x faster, identical output, defaults speed 3 / 256 colors / 80-95
<!-- release-recent:end -->

## Full History

- Current history directory: [history/README.md](./history/README.md)
- Legacy pre-reorg index snapshot: [../archive/release-index-legacy.md](../archive/release-index-legacy.md)

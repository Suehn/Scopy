---
doc_type: review
status: historical
owner: maintainers
last_reviewed: 2026-09-05
canonical: false
---

# Repository audit — 2026-09-05

This is a bounded audit and implementation pass against `212b817`, covering the six requested directions. It does not certify every subsystem or claim a new application performance gain.

## Scope and ownership

- Starting checkout: `main`, 15 commits ahead of the locally recorded `origin/main`; three dirty UI files contained `SCOPY_EXP_OPAQUE_ROWS` experiments.
- Work ran in the separate `codex/repo-audit-20260905` worktree. The existing UI experiments and active `codex/search-pagination-performance` changes were preserved.
- Environment: Apple M3 Pro, macOS 15.7.3, Xcode 26.1.1 (`17B100`). Language/deployment settings remain those in `project.yml`.

## Decisions across the six directions

| Direction | Finding and action |
| --- | --- |
| Dead code / low-value tests | Removed 189 lines of unreachable runtime code after checking Swift sources, tests, benchmark tools and scripts for callers. Kept small tests that encode product behavior; assertion count alone does not make a test useless. |
| Performance opportunities | Re-read the existing five-run scroll evidence and its rejected experiments. Search pagination/refinement is already under active work in a separate worktree. No new runtime speedup is claimed for deleting unreachable code. |
| Agent development and verification | Fixed project-generation cache invalidation and per-worktree test build isolation. Added `make test-tooling`, with real regression tests and existing evidence validators, to CI. |
| Open PRs / issues | GitHub's public repository issues endpoint returned an empty list for `state=open&per_page=100`; this endpoint includes PRs. There was no open item to review, close or merge at inspection time. |
| Merge eligible work | This pass produces an independently reviewable cleanup/tooling change. No remote release/tag or blanket merge of unrelated commits is part of it. |
| Stalled branches / work | Reviewed the July 17 `feature/ui-polish-typography` branch: four unique commits touch 22 files and include a Markdown dark palette without updated contract tests or visual evidence. It is not eligible for wholesale merge under the current light-theme contract. The current pagination work is active, not abandoned. |

## Removed code and surviving product paths

| Removed | Why safe within this repository | Surviving path |
| --- | --- | --- |
| `ThumbnailGenerationTracker` actor | Only its own declaration and singleton construction referenced it | `ClipboardService` thumbnail work scheduling and publication |
| `getThumbnailPath`, `getFileThumbnailPath`, `saveThumbnail`, `cleanupThumbnailCache` | No callers; these were a second, unused thumbnail API | `ClipboardService` uses the existing filename/PNG helpers and publication path; settings still call `clearThumbnailCache` |
| Deprecated `getOriginalImageData` | No callers | `loadPayloadData(for:)` |
| Six `plist*` helpers | Private, uncalled remnants of the old cache codec | `SearchIndexBinaryCodec` and its hardening tests |
| `computeTitle`, `computeMetadata`, `primaryFilePath` | Uncalled forwarding wrappers | `computeDisplayTextPair`, `primaryFileURL` |
| `fetchStorageRefsForUnpinned` | No callers | Existing transactional deletion / storage-reference return path |
| `isDatabaseCorrupted` | Only assigned; never read | Rollback failure still calls the same close/open recovery path |

No ingest receipt, migration, supported clipboard representation, search ranking, renderer, settings transaction or hotkey behavior was changed.

## Verification tooling fixes

1. The XcodeGen cache previously hashed only Swift filenames plus `project.yml` and `Package.swift`. Adding a PNG test fixture or changing XcodeGen version could incorrectly skip generation. The cache now includes resource/source paths and generator version. Editing source contents still skips regeneration, and a failed generation never publishes a success stamp.
2. Explicit test variants previously shared paths such as `DerivedData/Scopy-Strict` across all checkouts. They now live beneath `DerivedData/Scopy-<checkout-path-hash>/`, with the existing per-variant suffixes. Ordinary Xcode builds keep the default project-path isolation.
3. `make test-tooling` runs seven shell/Make regressions, 17 source-manifest checks, 36 warm-scroll summary checks and the quality-manifest self-test. CI runs this without requiring Xcode or GUI access.

The three new tests for resource changes, generator-version changes and worktree isolation were also run against the original `212b817` scripts: **3 failures out of 3, zero errors**. All seven pass against the fixes. Logs are in the implementation worktree's `logs/audit-tooling-before.log` and `logs/audit-tooling-final.log`.

## Performance evidence boundary

The existing main-worktree files `logs/perf-scroll/final-base-summary.json` and `final-v081-summary.json` each contain five runs. Recomputing their app-CPU means gives 3.878 s and 3.572 s over the documented 12-second scroll, a 7.9% reduction already represented by pre-existing commit `456abdf`. This audit did not rerun that workload or produce that gain. The `v081` filename is an experiment label, not evidence of a published v0.81 release.

The same files show WindowServer CPU means of 4.010 s and 4.334 s. Therefore the app-CPU reduction must not be presented as a measured reduction in total system energy. The [scroll study](../../perf/studies/perf-scroll-ceiling-2026-09-04.md) also rejects several tempting row/container changes; do not repeat them without a distinct hypothesis and controlled A/B.

## Validation record

- Final app build: passed.
- Tooling checks: passed, including the before/after regression proof above.
- Documentation, release metadata and 15 workflow-policy tests: passed.
- The standard `make test-unit` / `make test-strict` commands built their bundles but stalled before test execution. A sample of the owned runner showed `XCTestDriver._prepareTestConfigurationAndIDESession` waiting on `XCTFuture`; those runs were stopped and are **environment-blocked**, not passed.
- Direct XCTest execution of the same final ordinary and strict bundles: **822 tests each, 4 skipped, 0 failures** (29.148 s ordinary, 25.999 s strict). The selection matches the Makefile's four excluded integration/performance classes. The four conditional skips were row-pixel capture, live-network enrichment, perf metrics, and the opt-in 5k performance test. This validates the test bodies without certifying the blocked IDE-session launch path.
- Reproduction of the direct run: pass the comma-separated `ScopyTests.<class>` list from `logs/audit-direct-selection.json` to `/Applications/Xcode.app/Contents/Developer/usr/bin/xctest -XCTest <selection> <products>/ScopyTests.xctest`, with `DYLD_FRAMEWORK_PATH=<products>/Scopy.app/Contents/Frameworks` so the runner resolves the already-built Sparkle framework. The selection JSON records both product directories. Logs: `logs/audit-direct-unit.log`, `logs/audit-direct-strict.log`.
- No frontend runtime or renderer behavior changed, so no fresh scroll benchmark, PNG export or UI visual gate is claimed.

## Remaining separate work

- Finish and independently validate the active search pagination changes before integrating them.
- Rebuild any desired July UI styling changes on the current canonical contract, with the required screenshot/export evidence; do not treat age alone as permission to merge or delete the branch.
- The strict compiler still reports existing Sendable warnings in the raw export pointer, revision memo and attributed-string key paths. These require their own ownership/lifetime review; deleting unused code does not resolve them.

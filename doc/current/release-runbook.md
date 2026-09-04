---
doc_type: runbook
status: active
owner: maintainers
last_reviewed: 2026-09-04
canonical: true
related_versions:
  - v0.80.0
  - v0.78.2
  - v0.70.0
  - v0.65.4
  - v0.65.0
  - v0.8.8
  - v0.8.1
  - v0.8.0
  - v0.7.8
  - v0.7.7
  - v0.7.6
  - v0.7.5
  - v0.7.4
  - v0.7.2
---

# Release Runbook

## Sources Of Truth

- Version metadata: [../meta/release-current.yml](../meta/release-current.yml)
- Release index: [../releases/README.md](../releases/README.md)
- Changelog window: [../releases/CHANGELOG.md](../releases/CHANGELOG.md)
- Current release note is the `release_doc` pointed to by metadata.

## Metadata-Driven Release State

- `doc/meta/release-current.yml` is the only machine-readable source for current version, release date, release note path, profile linkage, and last verified timestamp.
- `doc/releases/README.md` is the human-friendly portal that mirrors the current metadata window.
- Do not hand-maintain current version/date in multiple active docs.

## Tag Authority And Workflow Boundary

- Only a maintainer running the explicit metadata-driven `make tag-release` or `make push-release` flow may create a release tag. A push to `main`, including release metadata, notes, scripts, or profile changes, is validation-only.
- `.github/workflows/ci.yml` and `.github/workflows/tsan.yml` declare top-level `contents: read`. `.github/workflows/release.yml` is the only write-capable workflow and may start only from an existing `v*` tag or explicit `workflow_dispatch`.
- `make release-validate` runs the content-based workflow policy; `make test-release-policy` proves representative safe and unsafe workflows. Renaming a workflow must not evade this check.
- Do not reintroduce a push-triggered tag job. Fixed build/unit/strict jobs cannot infer every conditional TSan, UI, performance, packaging, or deployment gate required by the change scope.
- Do not rely on a tag pushed with the repository `GITHUB_TOKEN` to recursively start another workflow. GitHub documents that repository-token events generally do not create a new workflow run except dispatch events: [Triggering workflows with `GITHUB_TOKEN`](https://docs.github.com/en/actions/concepts/security/github_token#when-github_token-triggers-workflow-runs).

## Build Injection

- `CFBundleShortVersionString = $(MARKETING_VERSION)`
- `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`
- `scripts/version.sh` remains the build-time source for `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- Before the release tag exists on `HEAD`, `scripts/version.sh` intentionally resolves the nearest reachable release tag. A pre-tag `make release` is therefore only a Release-configuration compile smoke and must not be cited as evidence for the new target version.
- Target-version release evidence starts after `make tag-release`: first verify `bash scripts/version.sh --xcodebuild-args` contains the target `MARKETING_VERSION`, then trust local tagged release builds or the GitHub tag workflow assets.
- For post-release commits after the tagged release commit, version injection should inherit the nearest reachable release tag. Do not infer the current release from highest version-sort order, because historical tags such as `v0.64` can sort after newer chronological releases such as `v0.7.1`.
- Homebrew version comparison is numeric, not chronological: `0.8.8 < 0.64 < 0.65.0`. Continue monotonically from the current metadata release and never publish a version Homebrew would compare below an already published version.
- Release packaging must use `scripts/version.sh --tag` as the single resolver for both injected version settings and the DMG filename; if they disagree, stop packaging.

## Tagged Packaging Output Contract

- Local and GitHub tagged packaging both execute `scripts/build-release.sh`. The script owns XcodeGen, the explicit DerivedData root, app existence validation, DMG creation, and the `.sha256` sidecar; the workflow must not duplicate those paths.
- GitHub sets `SCOPY_XCODE_DERIVED_DATA=${{ runner.temp }}/Scopy-Release`. The app stays under `<DerivedData>/Build/Products/Release/Scopy.app`; only final `Scopy-<version>.dmg` and `.dmg.sha256` artifacts live under repository `.build/`.
- `softprops/action-gh-release` uploads `.build/Scopy-*.dmg` and `.build/Scopy-*.dmg.sha256`. The existing-release reuse path downloads the checksum to the same `.build` location before resolving the cask SHA.
- `make test-release-policy` includes a packaging-path regression: the real workflow must call the shared packager, must not reference `.build/Release/Scopy.app`, and the packager must emit both artifacts.
- Failure evidence: [v0.65.0 run 29150976451](https://github.com/Suehn/Scopy/actions/runs/29150976451) built the Release app successfully, then failed immediately in `Create DMG` because the workflow still copied the pre-isolation `.build/Release/Scopy.app` path. `v0.65.1` supersedes that failed tag; do not move or reuse `v0.65.0`.

## Release Steps

1. Update [../meta/release-current.yml](../meta/release-current.yml), the new release note under [../releases/history/](../releases/history/README.md), [../releases/README.md](../releases/README.md), and [../releases/CHANGELOG.md](../releases/CHANGELOG.md).
2. Add or explicitly skip a release profile in [../perf/release-profiles/](../perf/release-profiles/README.md), and keep `profile_doc` in metadata aligned with that choice.
3. Run `make build`, `make test-unit`, and `make test-strict`; add TSan, UI, snapshot/backend, frontend, packaging, and deployment gates required by the change scope.
4. Run `make docs-validate`, `make release-validate`, and `make test-release-policy`.
5. Commit the coherent release candidate and confirm the worktree is clean. Do not tag an uncommitted or partially verified tree.
6. Create the tag deliberately with `make tag-release`.
7. Push `main` and the tag with `make push-release`.
8. Wait for the `Build and Release` workflow to publish `Scopy-<version>.dmg` and `.sha256`.
9. Verify Homebrew sync and installation.

## Release Environment

- Release CI currently targets `macos-15`.
- Hosted TSan CI also targets `macos-15` with Xcode 16.0 via [../../.github/workflows/tsan.yml](../../.github/workflows/tsan.yml).
- Project baseline remains `macOS 14.0` and `Xcode 16.0` unless intentionally changed in project configuration and workflows.
- Xcode app/test products use Xcode DerivedData; SwiftPM products and benchmark binaries use repository `.build`. Do not point Xcode `BUILD_DIR` at `.build`: mixing both build systems can retain file-provider/Finder metadata in an app bundle and make CodeSign fail with `resource fork, Finder information, or similar detritus not allowed`.
- `./deploy.sh release --no-launch` uses an isolated DerivedData root at `~/Library/Developer/Xcode/DerivedData/Scopy-Deploy` by default. Override it only with `SCOPY_XCODE_DERIVED_DATA=<absolute-path>`; a failed build prints the retained log path and its last 80 lines.
- Every Swift-flag test variant builds into its own DerivedData root (`Scopy-Strict`, `Scopy-Perf`, `Scopy-PerfHeavy`, `Scopy-SnapshotPerf`, `Scopy-RealDB`, `Scopy-TSan` under `~/Library/Developer/Xcode/DerivedData/Scopy-<checkout-path-hash>`). Both checkout and flag variant are isolated, so concurrent worktrees cannot overwrite each other's build database or test products. Plain `build`/`test`/`test-unit` use Xcode's default project-path-scoped DerivedData. The former "Stage SwiftPM Resource Bundles" pre-build phase was removed outright: the package declares no resources, so the phase only burned a 2.5s retry loop on every build.
- Tooling verification on 2026-09-05 (Apple M3 Pro, macOS 15.7.3, Xcode 26.1.1): 7 shell/Make regression tests, 17 source-manifest checks, 36 warm-scroll evidence checks, and the quality-manifest self-test passed. `make test-tooling` runs these locally and in CI. These are correctness checks, not app runtime performance measurements.
- `scripts/build-release.sh` uses the same isolation and retained-log contract for tagged packaging while keeping the final DMG under `.build/`.
- XCTest runtime fixtures belong in the test bundle. Performance DB copies and in-progress JSON belong under `/tmp` or DerivedData; shell wrappers may copy completed evidence into repository `logs/` only after `xcodebuild` succeeds. This avoids file-coordination/TCC stalls in Documents-hosted worktrees.

## Verification Expectations

- Baseline build/tests: `make build`, `make test-unit`
- Release workflow policy: `make release-validate`, `make test-release-policy`; ordinary workflows must remain top-level read-only and unable to create or push tags
- Concurrency-sensitive changes: `make test-strict`, and `make test-tsan` when the environment permits; on the known-bad `macOS 26.x + Xcode 26.2 (17C52)` combo the command skips because Apple hosted TSan crashes before test bootstrap, while the supported real-coverage path runs in Hosted TSan CI on `macos-15`
- Perf-sensitive changes:
  - `make test-snapshot-perf-release`
  - `make perf-search-warm-load`
  - `scripts/perf-warm-scroll-ab.sh` when a fixed frontend causal comparison exists
  - `make perf-frontend-profile-standard` before commit, or `make perf-frontend-profile-full` before release
  - `make perf-unified-table` when comparing frontend and backend evidence, including `warm-load-summary.json` from `perf-search-warm-load` / `perf-audit`

## Current Performance Evidence

The product/performance baseline shipped by `v0.65.1` is the verified `v0.65.0` source: direction-aware hover transfer, passive history rows, and the crash-consistent storage protocol. `v0.65.1` changes only the tagged packaging path and carries the same runtime evidence below.

It also makes external clipboard ingest restart-replayable/exactly-once and cleanup commit-time conditional. Schema v8 adds content-free ingest receipts; durable sources remain in the Application Support spool through commit, and cleanup preserves rows that became pinned or changed payload identity after planning. This is a D1 process-restart correctness change, not a D2/D3 power-loss guarantee.

Storage byte accounting above the signed 32-bit range remains lossless. The storage changes are correctness and deletion-safety work; snapshot, cleanup, frontend, and unified results are regression gates, not performance-improvement claims.

- Environment: Apple M3 Pro, arm64, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`).
- The focused strict-concurrency performance test runs 100,000 cached `SafeTriangle.contains` checks in about `9.4ms` on average across five runs (`~94ns` per call, `1.617%` relative standard deviation).
- One transfer samples for at most `500ms` at approximately `60Hz`, or about 31 checks; triangle construction runs only on initial geometry acquisition or a real popover frame change.
- The Core Graphics UI trajectory stays outside the popover beyond the former `120ms` grace while making forward progress, then enters the preview; outside-corridor and popover-to-row paths are separate regressions.
- Focused safe-triangle strict coverage: 37 passed; UI trajectory coverage: 3 passed; dedicated Markdown/image hover profile smoke: 2 passed with both expected JSON outputs.
- The final five-pair Release fixed workload ran both AB and BA order automatically with identical observed work on all ten runs. Passive medians improved whole-run row-body count `66.49%`, row-body total `61.07%`, main-run-loop total `3.77%`, and main-run-loop p95 `4.94%`; every pair improved row-body count, row-body total, and run-loop total.
- All fixed runs used `NSScreen CADisplayLink` and required no manual pointer movement. Callback cadence is not presented as FPS.
- A live Release sample selected the follow-on bottleneck: 411 of 457 sampled row-body stacks entered the uncached Markdown context-menu signal scan. The implemented cache is revision-keyed, bounded, prewarmed off-main, generation-guarded, and semantically separate from exact export capability.
- The final five-pair passive/passive `markdown-menu-cache` AB/BA completed the same 51,270px observed path in all ten runs with 1,135 row bodies per side. Current recorded 1,135 cache hits and zero measurement misses/uncached scans; median row-body total improved `92.09%`, main-run-loop total `9.61%`, and main-run-loop p95 `12.93%`, with row-body and run-loop totals improving in every pair.
- Final-source 7,807-row real-snapshot smoke and standard profiles completed unattended. Standard main-run-loop p95 changed `-17.55%` for accessibility, `-13.85%` for mixed, and `+5.29%` for text-biased, while other metrics remained noisy. An earlier three-repeat full guard against 7,794 rows changed the same metric by `-5.19%`, `+3.16%`, and `+11.69%`; text-biased improved in two pairwise repeats and regressed in the third. Both remain explicit broad-profile observations, not pass claims.
- The real-snapshot baseline disables five older feature flags together and is not an old-revision comparison; both variants retain passive rows and the Markdown menu cache. Use the two fixed AB/BA axes for causal v0.65.0 claims and do not attribute the full-profile variance to either new slice.
- Full unit and strict-concurrency suites each executed 727 tests with 1 skip and 0 failures; TSan executed 707 tests with 1 skip, 0 failures, and no race reports.
- An isolated copy of the refreshed 7,807-row schema-v7 snapshot migrated through the final Release service to schema v8 with unchanged row count, an empty `ingest_receipts` table, and `PRAGMA integrity_check = ok`.
- Snapshot Release search: `cmd p95 0.126958ms` against 50ms and `cm p95 1.860976ms` against 20ms.
- Targeted 10k cleanup gates passed 2 tests: inline cleanup p95 `213.51ms` against `500ms`; external cleanup committed/attempted 9,147 file removals with zero failures in `1748.44ms` against `1800ms`. Treat the external result as a narrow pass.
- The final-source three-repeat full profile ran 10 seconds and at least 260 samples per scenario. Baseline/current frame p95 remained `8.333ms` across accessibility, mixed, and text-biased; mixed long-frame and direction metrics remain non-causal variance. The include-hover smoke produced both expected Markdown/image buckets.
- Release deployment succeeded twice consecutively without cleanup after moving Xcode products to DerivedData; `make build` also passed.
- The final unified table compares the pre-storage audit with the final source: warm load `162.567ms -> 169.693ms`, peak RSS `131.938MB -> 132.328MB`, with mixed search movements still far below SLOs. Artifact: `logs/perf-unified-2026-07-11_19-10-16.md`.
- Dedicated evidence and caveats are in [v0.65.0 Release Performance Profile](../perf/release-profiles/v0.65.0-profile.md).
- Full build, unit, strict-concurrency, TSan, snapshot-performance, documentation, and release validation results are mirrored in `doc/meta/release-current.yml` and the `v0.65.0` release note.

## Search Match Evidence Release Evidence (2026-08-09)

This section records the final `v0.65.2` release evidence for source-aware search match snippets.

- Environment: Apple M3, arm64, macOS 27.0 (`26A5388g`), Xcode 26.5 (`17F42`), project Swift 5.9, and deployment target macOS 14.0.
- Real snapshot: schema v8, 6,421 items, 148,647,936 bytes (142 MiB).
- `make test-snapshot-perf-release` passed after match evidence construction was included in the search service's end-to-end timing: `cmd p95 0.947952ms` against `50ms`, and `cm p95 9.274006ms` against `20ms`, over 30 samples per workload.
- The final full frontend profile ran three repeats of 10 seconds and waited for the active regex query (`.`) before measurement. Every baseline/current search run loaded 550 rows, verified 550 search-evidence contexts, and passed the readiness gate; a missing context fails the scenario instead of silently measuring the empty-query path.
- The current search-evidence variant recorded callback-interval p95 `16.666651ms`, callback over-threshold ratio `0.6734%`, SwiftUI row-body p95 `0.810027ms`, and display-model p95 `1.736045ms`. Full-profile main-run-loop p95 is intentionally absent because the 10-second event stream exceeded the 2,000-event retention cap; the shorter final standard run recorded `4.053950ms`. Callback cadence and the frontend baseline/current flags remain environment-sensitive regression observations, not frame-rate or pre-feature causal claims.
- The same-host, same-snapshot backend audit compares tagged `v0.65.1` with the final candidate. Service P95 changed from `4.490ms` to `9.449ms` for `cm`, `8.307ms` to `15.174ms` for `数学`, `0.124ms` to `0.927ms` for `cmd`, and `4.561ms` to `9.289ms` for `cm` without thumbnails. The bounded evidence work is the expected source of this cost; the absolute results remain below the release SLOs.
- Full-index warm load stayed effectively flat at `188.216ms -> 187.971ms`, while peak RSS changed from `222.391MB -> 220.391MB`.
- `make perf-unified-table` produced `logs/perf-unified-2026-08-09_20-03-12.md`. Its backend columns are a causal revision comparison; its frontend columns compare existing runtime feature-flag variants within the candidate and must not be presented as a before/after search-evidence speedup.
- The optional include-hover smoke was attempted. Both Markdown and image cases stopped at harness discovery because the locked host reported the Scopy application as disabled and omitted the harness window from the accessibility tree. No hover bucket was produced, so this run is recorded as environment-blocked rather than passed.
- Retained evidence: `logs/snapshot-release-cmd.jsonl`, `logs/snapshot-release-cm.jsonl`, `logs/perf-frontend-profile-2026-08-09_19-36-44/frontend-scroll-profile-summary.json`, `logs/perf-audit-v0.65.1-baseline-2026-08-09_20-01-14/`, `logs/perf-audit-v0.65.2-current-2026-08-09_20-02-20/`, and `logs/perf-unified-2026-08-09_20-03-12.md`.

## Search Cache And Metrics Release Evidence (2026-08-22)

This section records the final `v0.65.3` release evidence for restart-surviving index caches, typing-safe warm-up, index-only corpus metrics, and the history-list revision token.

- Environment: Apple M3 Pro, arm64, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0.
- Real snapshot (same-day): 9,566 items, 146,255,872 bytes, schema v8 at snapshot time; the current service migrated an isolated copy to schema v9, creating `idx_plain_text_bytes` with unchanged aggregate results.
- Disk-cache invalidation is now keyed by `scopy_meta.mutation_seq` plus a live item-count tripwire; cache formats are `fullindex.v4` / `shortindex.v2` and older cache files are removed at engine open. File-attribute churn (WAL checkpoint, mtime drift) no longer invalidates a logically unchanged cache; this is covered by a dedicated regression test.
- Real-database regression (isolated same-day copy, 9,559 items): rebuild refine `1789.7ms` vs disk-cache refine `271.6ms` with identical ordering; prefilter `2.3ms`; prewarmed refine `32.3ms` vs cold no-prewarm `1903.2ms`.
- Corpus-metrics aggregate on the real database: `268ms` full scan -> `<1ms` index-only scan with identical results; one-time warm index build `14ms`.
- `make test-snapshot-perf-release`: `cmd p95 0.612020ms` against `50ms`, `cm p95 5.352020ms` against `20ms`, 30 samples per workload.
- Same-host, same-snapshot backend audit vs `v0.65.2`: service P95 `cm 5.237ms -> 5.246ms`, `数学 24.801ms -> 24.379ms`, `cmd 0.565ms -> 0.634ms`, `cm:noThumb 5.375ms -> 4.763ms`; peak RSS `191.03MB -> 155.03MB`; cold full-index warm load `234.7ms -> 254.0ms` (run-to-run variance; the release claim is cache validity across restarts, not a faster cold build). Engine `cm` audit movement re-measured below baseline (`5.100ms` / `5.209ms`) and is recorded as variance.
- Frontend standard profile: frame p95 `-34.8%` accessibility, `-38.1%` mixed, `-90.9%` search-evidence, `0.0%` text-bias; row-body p95 down in all scenarios. Baseline/current compare runtime feature-flag variants within one revision and are regression observations.
- Full frontend profile (three repeats of 10 seconds): frame p95 flat at `0.00%` in mixed, search-evidence, and text-bias; the accessibility scenario moved one 8.333ms frame bucket (`33.333ms -> 41.667ms`) with long-frame attribution dominated by `19.2s` of cold thumbnail decodes in that variant, outside this release's paths. Row-body p95 decreased in all four scenarios.
- `make perf-unified-table` produced `logs/perf-unified-2026-08-22_02-50-57.md` from the two same-day backend audits plus the full frontend summary.
- Retained evidence: `logs/perf-audit-v0.65.2-baseline-2026-08-22_02-37-42/`, `logs/perf-audit-v0.65.3-current-2026-08-22_02-39-07/`, `logs/perf-frontend-profile-2026-08-22_02-28-30/`, `logs/perf-frontend-profile-2026-08-22_02-40-40/`, `logs/perf-unified-2026-08-22_02-50-57.md`, `logs/test-real-db.log`, and [v0.65.3 Release Performance Profile](../perf/release-profiles/v0.65.3-profile.md).

## ChatGPT-Aligned Markdown Renderer Release Evidence (2026-08-28)

This section records historical `v0.65.4` release evidence for the single preview/PNG renderer aligned to the canonical contract as it existed at that tag. `my-archiving-session.wacz` did not contain a hydrated completed-answer DOM or computed-style snapshot. Current safe-HTML, asset-readiness, and preview-lifecycle requirements live only in the canonical current contract and supersede any behavioral implication below; this history is not an active compatibility requirement.

- Renderer boundary: preview and PNG export both consume the output of `MarkdownHTMLRenderer -> MarkdownHTMLDocumentBuilder`; the legacy selector, shadow renderer, feature flags, fallback parser, duplicate normalizers, and obsolete assets are removed.
- Semantic/source-path coverage: local CommonMark/GFM, stable footnotes, HTML-only KaTeX, syntax highlighting, tasks, citations, table sizing/overflow, literal raw HTML, CJK, RTL, Unicode, malformed ATX headings, protected URLs/file paths, and long-document export. Visual claims are limited to the real-application PNG evidence below.
- Automated evidence: the JavaScript renderer suite passed 44/44; normal and strict Swift executions each completed 756 tests with 27 skips and zero failures; app build, docs validation, release validation, and the 15-case workflow policy passed.
- End-to-end evidence: the real application exported the long fixture to a visually accepted 1080 x 4571 PNG with the tail present. The optional include-hover XCUITest path could not establish the host accessibility harness and is recorded as environment-blocked, not passed.
- No performance improvement is claimed and no dedicated profile was created; release metadata intentionally sets `profile_doc: null`.

## Interactive Rich Rendering And Preview Stability Release Evidence (v0.70.0, 2026-08-28)

- Product boundary: strict `scopy-rich` v2 supports web results, image groups, news, weather, finance, and currency with frozen input and a bundled asset allowlist. Promotions, merchant cards, and maps remain out of scope. Invalid or unsupported envelopes stay visible code fences, and copied prose never manufactures private metadata.
- One-chain guarantee: preview and export use the same parse result, HTML, base CSS, runtime, fonts, and local assets. Preview hydrates deterministic controls; export freezes the same DOM and cancels links/actions before capture.
- Link boundary: explicit preview clicks may open only validated HTTP(S) or strict Codex absolute-file destinations. Source pills retain only supplied URLs and expose supporting sources in a focusable popup. Export and programmatic navigation remain inert.
- Lifecycle repair: hidden premeasurement no longer competes for the shared `WKWebView`; an owner lease prevents stale teardown, identical in-flight HTML is not reloaded, bridge/scroll setup is idempotent, and scroll configuration retries when the internal WebKit scroll view appears late.
- Real fixtures: `user_markdown_stress.md` is the complete 47,419-byte, 2,728-line user stress input; `chatgpt_rich_copy_sample.md` is the user's lossy visible-text copy and must remain ordinary Markdown; `chatgpt_rich_surfaces.md` is the separate deterministic structured fixture.
- Automated evidence: Node renderer and runtime tests passed 77/77; normal and strict Swift executions each passed 749 tests with 2 skips and zero failures; app build, docs validation, release validation, and the 15-case release policy passed.
- End-to-end evidence: the real app exported the user stress fixture at 2160 x 141619 and the copied-text fixture at 1080 x 8653. Top, middle, and tail crops were visually inspected with content present and no synthetic cards in the lossy copy.
- UI automation boundary: the optional hover run timed out while enabling macOS automation mode before the scenario began. It is environment-blocked, not passed. First-load/navigation/scroll ownership is covered by focused lifecycle tests plus real application export.
- Archive boundary: the WACZ proves captured runtime/resources and limited saved structure, not hydrated final DOM, computed style, dark mode, or computed fonts. No performance improvement is claimed; `profile_doc` remains `null`.

## Renderer Hardening And Rich Fidelity Release Evidence (v0.71.0, 2026-08-29)

- The canonical safe-HTML subset is parsed into explicit AST nodes before all residual raw HTML is literalized. It supports only attribute-free paired `u`/`kbd`/`mark`/`sub`/`sup`, exact block `details`/plain `summary`, and complete-comment removal; malformed or unsafe cases fail closed.
- Strict `scopy-rich` v2 remains the only structured-data card input. Consecutive public Markdown image-only paragraphs may reuse the image-grid/lightbox presentation using only their visible `src`/`alt`/`title`; this path cannot infer a missing card, source, date, citation, article, or private metadata.
- The renderer IIFE, KaTeX 0.16.45 CSS, every lockfile/CSS-referenced KaTeX font, sidecar, and `asset-manifest.json` are synchronized and verified as one set. The built app must contain only the canonical nested resource tree; flat duplicates are a build failure.
- Preview readiness now waits for stylesheet, fonts, terminal local-image state, hydration, stable paint, and a current layout epoch. Exact layout scale participates in cache readiness, resize/toggle bursts are coalesced, terminal failures stay visible, and export refuses a merely nonzero but nonterminal DOM.
- Real validation inputs are the complete user stress fixture, the exact public ChatGPT copy fixture, and the safe-HTML torture fixture. The two exact public ChatGPT Search image URLs resolve only to bundled local images; no general remote fetch or URL inference is introduced.
- Local visual evidence belongs under the ignored `artifacts/render-validation/` directory. Keep a short README there with the source fixture, output scale, pixel dimensions, observed result, and any environment-blocked check; these files are runtime evidence, not release artifacts and are never committed.
- This gate makes no new pixel-perfect, dark-mode, computed-font, or live-Edge claim. The WACZ and supplied screenshots remain bounded evidence; the 2026-08-28 Edge content-inspection attempt timed out and is environment-blocked.
- F2-F7 closeout on 2026-08-29: Node passed 99/99; asset verification passed with renderer `dc71d101…`, KaTeX 0.16.45, and 60 fonts; `make build` passed; normal and strict Swift suites each executed 762 tests with 2 skips and zero failures. The built app's `MarkdownPreview` asset tree passed the same verifier, and the Resources root contained no flat renderer duplicates.
- The final Debug build directly exported `markdown_safe_html_torture.md` at 1080 x 1526, `chatgpt_public_copy_markdown_sample.md` at 1080 x 14534, and `user_markdown_stress.md` at 1080 x 69304. The public-copy and stress PNGs were byte-for-byte identical to the already visually reviewed 100% outputs; the safe-HTML image was inspected with visible headings, nested quote/list content, safe elements, code, table, footnote, and display math.
- The live preview harness reached terminal `rendered` on the first open at 80%, 100%, and 200% logical layout scales. At 100%, two preview scrolls preserved the same terminal render state, with no second hover required. Toggle-height reporting, local overflow ownership, and stale-callback rejection remain separately pinned by renderer/runtime and Swift lifecycle tests.
- XCUITest is environment-blocked on this host: two focused export cases stopped before product assertions with `Application 'com.scopy.app' has not loaded accessibility`. The same Debug executable succeeded through the non-Accessibility auto-export path and through Computer Use inspection, so do not record the XCUITest wrapper as passed or treat that host failure as a renderer assertion failure.
- Rich fidelity pass closeout on 2026-08-29 (same release): the wide-thread threshold now equals the 816px output surface, so 100% scale renders the 48rem desktop column; chart trend/warm colors are defined once as `--scopy-rich-*` tokens with SVG gradient stops inheriting `currentColor`; finance metrics follow the reference three-column order; citations resolve bundled favicons only through the closed exact-host map; file-link icons receive a 1.15 optical scale. Reference-screenshot pixel sampling confirmed the pre-existing trend palette already matched the ChatGPT desktop captures, so no color values changed.
- Rich fidelity verification on this host (MacBook Pro, macOS 15.x Darwin 24.6.0, 2026-08-29): Node contract tests 100/100; `npm run build` + `npm run verify:assets` passed with renderer `11727ec7…`, KaTeX 0.16.45, 60 fonts; `make build` passed; `make test-unit` and `make test-strict` each 762 executed / 2 skipped / 0 failures (one transient `ThumbnailPipelineTests` CGImageSource failure in a single strict run was excluded after passing in isolation and in a full green rerun; it is unrelated to renderer changes).
- Final Debug build direct exports at 100%: `chatgpt_rich_surfaces.md` 1080 x 5740 with three uncropped news cards, all eight weather days plus a complete hourly chart, three-column reference-ordered finance metrics, and live bundled favicon citation pills; `chatgpt_public_copy_markdown_sample.md` 1080 x 14027 with the OpenAI favicon pill and the 48rem text column. Evidence crops live under the ignored `artifacts/render-validation/` directory.

## Rich Type Completion, Link Enrichment, And Auto-Update Release Evidence (v0.72.0, 2026-08-29)

- Strict v2 now covers `video`, `product`, `product_carousel`, `entity`, and `map`, and the closed public-copy adapters promote exact visible video/product/place shapes; the honest ceiling (surfaces whose copy lacks data stay prose) is contract-recorded. Verified by Node 106/106, both Swift suites green, and reviewed direct exports (`rich-surfaces-all-types.png` 1080x8423, `public-copy-with-adapters.png` 1080x14769 under `artifacts/render-validation/`).
- Opt-in, default-off link enrichment fetches Open Graph metadata for assistant-shaped bare links in the backend only (cookie-less, size/time-capped, public hosts, imagery frozen as v2-limit data URIs into content-hash sidecars under Application Support/Scopy/LinkEnrichment). The renderer/CSP never fetch; sidecar fingerprints participate in every render/metric cache key; rendererVersion bumped to v6. The live-network test is gated behind `SCOPY_NETWORK_TESTS=1`.
- Sparkle 2.9.6 auto-update: daily checks with reminder + install-and-relaunch, "检查更新…" in About, feed at `releases/latest/download/appcast.xml`, EdDSA public key in Info.plist. The release workflow signs and attaches `appcast.xml` when the `SPARKLE_ED_PRIVATE_KEY` secret exists and emits a loud warning when it does not; the one-time secret setup is documented in `.secrets/README.md` (gitignored).

## Architecture And Short-Query Release Evidence (v0.72.2, 2026-08-31)

- Environment: Apple M3 Pro, 36GB, arm64, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0.
- Real snapshot: schema v9, 9,566 items, 146,255,872 bytes, SHA256 `bdd4da11e68e47607b188ca75f6582e40a8a6a126b9017f1ceaffd98d5c88976`, `integrity_check=ok`.
- The Release gate now separates service `cmd`, explicitly prepared engine `cm`, and one cold service `cm` observation. Results: `0.682ms / 50ms`, `5.458ms / 20ms`, and `103.974ms` observation-only respectively.
- The same-snapshot immutable diagnostic compared tagged `v0.72.1` with the candidate. Service `cmd` p95 moved `0.630ms -> 1.314ms`; first `cm` observation `732.886ms -> 50.390ms`; service warm `cm` p95 `6.302ms -> 47.684ms` while the candidate median remained `6.119ms`. The URI disables normal path-keyed cache reuse and the host was busy, so these are build-contention diagnostics, not causal release percentages.
- The design chooses immediate SQL fallback over awaiting a non-cancellation-aware index task. It therefore avoids a long first-query stall but can show a temporary 47-68ms tail while building; explicit prepared steady state remains `5.458ms`.
- Default performance suite: 27 executed, 7 heavy-only skips, 0 failures; 5k p95 `4.95ms`, 10k p95 `30.86ms`, disk-backed service 10k p95 `29.07ms`, exact long-document p95 `99.56ms`.
- Unit and strict suites each executed 780 with 3 skips and 0 failures; TSan executed 761 with 3 skips and 0 failures; integration executed 15 with 0 failures.
- Frontend profiling reached the UI runner but timed out while enabling automation mode before any scenario. No summary or unified table was generated; this is `environment-blocked`, not a pass or frontend speedup claim.
- Detailed comparison and scope boundaries: [v0.72.2 Release Performance Profile](../perf/release-profiles/v0.72.2-profile.md).

## Bundled pngquant Engine Release Evidence (v0.73.0, 2026-09-02)

- Environment: Apple M3 Pro (5 performance + 6 efficiency cores), 36GB, arm64, macOS 15.7.3 (`24G419`), rustc 1.98.0 (Homebrew), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0. No Swift source changed.
- Deployment semantics: `Scopy/Resources/Tools/pngquant` is a universal (`arm64` + `x86_64`) ad-hoc-signed build of the maintainer fork (CLI `kornelski/pngquant` `913a90d` + fork `af354ef`; engine `ImageOptim/libimagequant` `9388d26` + fork `perf` `fddcf09`), features `static cocoa`, linking only system frameworks and `libz`. Rebuild commands and the full provenance are in `Scopy/Resources/ThirdParty/pngquant/PROVENANCE.md`; the Intel slice is cross-built with `RUSTC_BOOTSTRAP=1 cargo build --release --target x86_64-apple-darwin -Zbuild-std=std,panic_abort` and was verified under Rosetta only.
- Engine pipeline (quantize + dithered remap), min of 5 runs, upstream `9388d26` vs fork, ms: photo 2048x2048 speed 3 `116.7 -> 37.0` (3.15x), speed 1 `269.2 -> 130.6`, speed 10 `62.2 -> 23.2`; UI 2560x1600 speed 3 `114.4 -> 38.9` (2.94x); photo with alpha speed 3 `138.1 -> 35.2` (3.92x); 810k-color gradient noise speed 3 `238.9 -> 68.2` (3.50x). Single-threaded speed 3: `330.1 -> 180.6`, `228.5 -> 169.5`, `249.9 -> 166.6`, `535.5 -> 352.1`.
- Quality: 58 CLI outputs (4 bench images + `test.png`, speeds 1/4/10, `--nofs`, `--posterize 2`, `--quality 60-80`, one and all threads) compared pixel by pixel against unchanged upstream 4.5.0: MSE within -4.0%..+0.7%, all-threads and single-thread outputs byte-identical, `x86_64` and `arm64` outputs byte-identical, no visible dithering seams in 4x crops. Method: `scripts/check_output.sh` and `examples/compare.rs` in the fork.
- Real Scopy assets with Scopy's arguments, old official `3.0.3` vs this build: sizes mostly within 1%, two previously skipped exports now compress (`97,038 -> 26,699`, `2,592,990 -> 648,541`), one already-4-bit export stays unchanged via exit 98 instead of shrinking 1.4%; whole-CLI time `0.08 -> 0.06s` (screenshot), `2.52 -> 2.38s`, `3.11 -> 3.00s`, `0.59 -> 0.55s`, `36.26 -> 35.98s` (298-megapixel export). libpng level-9 encoding dominates large exports and is unchanged.
- Gates: build pass; unit 780 executed / 3 skipped / 0 failures; strict 780 executed / 3 skipped / 0 failures; integration 15 executed / 0 failures; docs/release/policy validation pass. TSan, snapshot, and frontend performance gates were not run because no Swift source changed.

## Export Encode Path Release Evidence (v0.74.0, 2026-09-02)

- Environment: Apple M3 Pro (5 performance + 6 efficiency cores), 36GB, arm64, macOS 15.7.3 (`24G419`), rustc 1.98.0 (Homebrew), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0.
- Deployment semantics: `Scopy/Resources/Tools/pngquant` is rebuilt from the fork `perf` branch at `256e081` (engine unchanged at `fddcf09`), same features (`static cocoa`), universal, ad-hoc signed; the write path now uses zlib-rs instead of system `libz`. Exports call the tool with a memory-mapped PAM input and `--output`; `--skip-if-larger` is only passed for captured PNG files. Rebuild commands are in `Scopy/Resources/ThirdParty/pngquant/PROVENANCE.md`.
- Reference export `chatgpt_public_copy_markdown_sample.md` at 200% (2160x29511, min of 3): whole tool `2.05 -> 0.21s` with PAM input (`0.56s` with PNG input); tool stages read `4ms`, quantize `25ms`, remap `89ms`, write `93ms`; Scopy-side hand-off (preallocate, map, flatten) `110ms` versus ImageIO encode `403ms`; app launch to PNG on the pasteboard `6.10-6.32s -> 3.50-3.70s`. Old and new app outputs have identical palette and scanlines (`1,973,376 -> 1,959,158` bytes).
- Encoder evidence on the reference scanline stream (31.4 MB): system zlib level 9 memLevel 5 `1777ms`, zlib-rs level 9 `497ms`, libdeflate level 9 `224ms` (+2.3% size), zlib-rs level 9 in 256 KiB dictionary-primed parallel pieces `76ms` at sequential size. Writer output verified scanline-identical to libpng on palette, `tRNS`, 4-bit and truecolor-fallback images; sizes `+0.09%`, `-0.58%`, `-0.24%`, `-0.40%`, `+0.47%`.
- Gates: build pass; unit 784 executed / 3 skipped / 0 failures; strict 784 executed / 3 skipped / 0 failures; integration 15 executed / 0 failures; fork `cargo test` 4 passed; docs/release/policy validation pass. TSan, snapshot, and frontend performance gates were not run because no search, cleanup, or scrolling code changed.

## Export Settle And Canvas Release Evidence (v0.75.0, 2026-09-02)

- Environment: Apple M3 Pro (5 performance + 6 efficiency cores), 36GB, arm64, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0; Debug build driven through `SCOPY_UITEST_AUTO_EXPORT_MARKDOWN` with `/usr/bin/log show --info` stage timestamps (note: zsh shadows `log` with a builtin; call `/usr/bin/log`).
- Deployment semantics: no bundled-tool change (`pngquant` as in v0.74.0). Export waits are animation-frame driven (`layoutWatcherJS`, polled every 8 ms); the export canvas is a preallocated mmapped PAM file (128-byte header) that pngquant maps; defaults speed 3 / 256 colors / quality 80-95.
- Fixture exports at the maintainer's saved settings (speed 1, 16 colors, 0-70), launch-to-PNG, v0.74.0 vs v0.75.0: chatgpt_public_copy 200% `3.57 -> 2.05s`, 100% `2.55 -> 1.40s`; rich_markdown 200% `2.27 -> 1.14s`; chatgpt_rich_surfaces 200% `3.07 -> 2.02s`; user_markdown_stress 200% (tiled, 2160x138038) `14.24 -> 8.73s`; all five outputs byte-identical. Stage detail on the 200% reference: prepareLayout `1.15 -> 0.14s`, applyScale `0.15 -> 0.07s`, snapshotOnce `0.22 -> 0.14s`, snapshot-to-canvas draw `0.31 -> 0.07s`.
- Post-load work at the new defaults: chatgpt_public_copy 200% `0.79s` (launch-to-PNG `1.51s`), 100% `0.65s`; rich_markdown 200% `0.45s`; chatgpt_rich_surfaces 200% `0.86s`.
- Banded snapshot draw vs single draw on 63.7 Mpx: 206 pixels in one row differ (max channel diff 27), identical set for 256/1024-row bands with or without 16-row overlap.
- Gates: build pass; unit 782 executed / 3 skipped / 0 failures; strict 782 executed / 3 skipped / 0 failures; integration 15 executed / 0 failures; docs/release/policy validation pass. TSan, snapshot, and frontend performance gates not run: no search, cleanup, or scrolling code changed.

## History Scroll Release Evidence (v0.76.0, 2026-09-02)

- Environment: Apple M3 Pro (5 performance + 6 efficiency cores), 36GB, arm64, 120 Hz display, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`), Release build; real panel (`SCOPY_PROFILE_OPEN_PANEL=1`), real snapshot DB `perf-db/clipboard.db` (9,566 rows, 146,255,872 bytes); the maintainer's system has an Accessibility pointer customization (`mouseDriverCursorSize` 2.35).
- Method: `scripts/perf-scroll/profile_scroll.py` (`--mode wheel`: 24 px pixel scroll-wheel `CGEvent`s at 60 Hz, flipping every 4 s, 12 s, cursor over the list; `--mode fixed`: 1440 display-link commands of 36 px) with `sample` attribution; the terminal must be trusted for Accessibility to post events (`build/axcheck`).
- Wheel workload, v0.75.0 -> v0.76.0: Scopy CPU `14.34 -> 9.76 s` per 12 s; callback interval p95 `83.3 -> 16.7 ms`, max `91.7 -> 25.0 ms`, over-threshold `13.1% -> 0%`; GPU `42% -> 19%`; main-thread shares `-[NSCursor set]` `21.4% -> 0.0%`, `ClipboardItemContentRevision` `11.2% -> 0.4%`, `installObservationSlow` `8.7% -> 0.2%`.
- Fixed workload: main run-loop busy `8,378 -> 3,931 ms` of 12,000, run-loop p95 `7.11 -> 4.94 ms`, max `12.0 -> 7.8 ms`, Scopy CPU over the 30 s sample window `23.29 -> 11.73 s`.
- Gates: build pass; unit 783 executed / 3 skipped / 0 failures; strict 783 executed / 3 skipped / 0 failures; integration 15 executed / 0 failures; docs/release/policy validation pass; `make perf-frontend-profile` smoke passed (`logs/perf-frontend-profile-2026-09-02_19-33-39/`); full tier not run, the real-input profile is the release evidence. TSan, snapshot, and backend performance gates not run: no search, cleanup, or storage code changed.

## History Scroll Steady-State Release Evidence (v0.77.0, 2026-09-02)

- Environment: same host as the v0.76.0 section (Apple M3 Pro, 36GB, 120 Hz, macOS 15.7.3, Xcode 26.1.1), Release build, real panel, real snapshot DB (9,566 rows). Steady state means `scripts/perf-scroll/profile_scroll.py --reuse-db`: one working copy under `logs/perf-scroll/db-warm` keeps thumbnails generated by earlier runs; a fresh copy regenerates them (~0.7 s off-main per run) and re-runs the List body per thumbnail.
- Method: `--mode wheel` (mouse-like: 24 px pixel scroll-wheel `CGEvent`s at 60 Hz, flipping every 4 s, 12 s, cursor over the list) and `--mode wheel --phased` (trackpad-like: the same stream with began/changed/ended gesture phases); `sample` attribution on the main thread; page-apply hitches read from the profiler's long-callback attribution.
- Changes: unified scroll state in `ListLiveScrollObserverView` (clip-view bounds + live-scroll notifications, `ListProgrammaticScrollGate` for keyboard follow); `HistoryRowSelectionFanout` (selection no longer re-runs the List body); `loadMorePageSize` 500 -> 100; lazy row descriptor in `HistoryItemView`; memoized revisions in `ClipboardItemDisplayText.prewarm`; `ListLiveScrollObserverView.layout()` resolves the scroll view only until attached; `PerfFeatureFlags.passiveHistoryRowEnabled` read once.
- Mouse-like wheel, v0.76.0 -> now (12 s): Scopy CPU `9.94 -> 2.83 s` (fresh DB `3.03 s`), main thread `5.02 -> 2.61 s` (42% -> 22%), hover sessions `322 -> 2`, hover preview decodes during scroll `2-5 s -> 0`; callback interval p95 `16.7 -> 8.3 ms`, max `25-42 -> 16.7-25 ms`; over-threshold 0%.
- Trackpad-like wheel, v0.76.0 -> now: Scopy CPU `4.50 -> 2.74 s`, main thread `3.37 -> 2.44 s` (28% -> 20%); callback interval p95 `8.3 -> 8.3 ms`, max `83.3 -> 16.7 ms` (the 75 ms hitch was the 500-row page apply: every ForEach child re-initialized with a descriptor miss).
- Floor reference (same input, minimal lists, `logs/perf-scroll/floor-experiment/`): SwiftUI `List` with plain text rows `1.31 s`, `NSTableView` with AppKit cells `0.66 s`; a lean-row experiment build of Scopy `3.4 s` before these changes. Remaining main-thread cost is SwiftUI List machinery (CA commit and hosting layout ~14%, AttributeGraph ~11%, NSTableView recycling ~8%, automatic row heights ~5%).
- GPU: unchanged by scrolling (idle 20% with the panel open vs 8-12% without it, unrelated to the list).
- Gates at tag time: `make release` pass; docs/release/policy validation pass. `make test-unit` on the final source was in progress when the tag was cut at the maintainer's request (the previous run on the same code executed 790 tests with 3 failures, all assertions on the old 500-row page size, since aligned); `make test-strict` and the UI subset are queued after it. Recorded in `v0.77.1`: unit 790 executed / 3 skipped / 0 failures, strict 790 / 3 / 0, UI subset 29 passed and 3 failed (one pointer-synthesis flake that passed on rerun; `testHoverPreviewDismissesOnScroll` and `testSearchEvidenceExplainsMultipleDistantMatches` fail identically on `v0.76.0`). `v0.77.1` also gates clip-view-driven scroll starts on a current scroll-wheel event. TSan, snapshot, and backend performance gates not run: no search, cleanup, or storage code changed.

## Interaction Latency Release Evidence (v0.78.0, 2026-09-03)

- Environment: Apple M3 Pro, 36GB, 120 Hz, macOS 15.7.3, Xcode 26.1.1, Release builds, real panel, real 9,566-row snapshot DB (warm copy via `--reuse-db`); drivers in `scripts/perf-scroll/` (`profile_scroll.py`, `profile_search.py`, `profile_capture.py`), stage timelines from the app's info logs.
- Hover preview (Markdown text items of 8-14 KB, preview delay 1.0 s, preview scale 125% vs Settings 100%): before, every hover rendered twice (Settings scale, then the preview scale), navigated the WebView twice (once at 0 px width) and resized the popover twice, final content at 1.33 s cold / 1.31 s warm; after, the document is built at 320-360 ms, laid out offscreen at the popover width by 390 ms, the popover opens at its final size at 1.04 s with the render already on screen, and a warm hover performs no navigation.
- Search typing (`clipboard hist`, 14 keys at 8/s): List body runs 56 -> 31, rows re-initialized 541 -> 486, the list no longer empties between keystrokes; remaining per-keystroke work is result-row layout (text, hosting cells).
- Clipboard capture (three 1.2 MB RTF+HTML copies): main-thread samples in extraction 58.5% -> 0.3% (idle 38% -> 90%); each copy blocked the main thread 1.9-2.4 s before. Plain 1 MB text: normalization off the main thread.
- Launch: short-index cache 2,887 ms (stale plist decoded then rejected) -> 0 ms stale / 55 ms hit; launch CPU 3.3 s -> 0.75 s over the first 12 s; cache file 16.3 MB plist -> 14.7 MB binary. Storage details walk measured at 5 ms on this DB, left as is.
- Page loads while scrolling (continuous 8 s downward wheel): callback bursts of 25-33 ms per page -> 17 ms (two 120 Hz frames) per chunk, over-threshold ratio 0.065 -> 0.014, with pages prefetched 40 rows ahead.
- Preview image cache: per-entry cap 96 -> 256 MB, total 160 -> 320 MB, so a tall screenshot's 64 Mpx preview stays cached for its TTL instead of being decoded on every hover; decode quality unchanged.
- Gates at tag time: unit 791 executed / 3 skipped / 0 failures; docs, release and policy validation pass; strict 791 / 3 / 0 after the tag; UI subset 29 passed, 3 failed (unchanged from v0.77.1); TSan/snapshot/backend not run (no query, cleanup, or storage-schema change).

## History Summary And Search Fallback Release Evidence (v0.78.2, 2026-09-03)

- Environment: Apple M3 Pro, 36GB, 120 Hz display, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0; real 9,566-row snapshot DB (`146,255,872` bytes).
- List-query change: recent, pinned, and unpinned queries no longer select inline `raw_data`; full payloads still load through the existing item lookup on demand. The snapshot's first 50 history rows contain `420,646` bytes of inline payload, and its 15 pinned rows contain `42,194` bytes, now excluded from routine list hydration. This is avoided transfer volume, not a claimed wall-clock speedup.
- Release-app capture (`logs/perf-capture/v0782-final/`): 10/10 generated text changes reached the run DB and became the first ten Recent rows in order; main run-loop busy p95 `0.9 ms`, max `33.6 ms`.
- Search release benchmark: `cmd` p95 `0.561 ms` against a `50 ms` limit; prepared `cm` p95 `4.508 ms` against a `20 ms` limit; cold `cm` observed `61.224 ms` and remains record-only.
- Full frontend profile (`logs/perf-frontend-profile-2026-09-03_02-05-13/`): three 10-second repeats for baseline/current across four snapshot scenarios completed. Current frame p95 was `8.333 ms` in accessibility, search-evidence, and text-bias; mixed had `16.667 ms` versus baseline `8.333 ms`. Raw runs also contained a `16.667 ms` baseline mixed sample with comparable app main-run-loop averages, so this is not a causal before/after comparison.
- Standard recheck (`logs/perf-frontend-profile-2026-09-03_02-14-10/`): mixed returned to `8.333 -> 8.333 ms` and drop ratio improved `0.027 -> 0.021`; search-evidence showed the inverse p95 clock step while its drop ratio improved `0.016 -> 0.012`. The discrete 120/60 Hz sampling variance is recorded rather than presented as a product improvement or regression.
- `make perf-unified-table` produced `logs/perf-unified-2026-09-03_02-18-42.md`. Its backend columns are a causal `v0.78.1` (`e4c7616`) versus `v0.78.2` candidate comparison with 20 warmups and 30 measured iterations; engine/service p95 values remain within their release limits, full-index warm load was `50.986 -> 50.516 ms`, and peak RSS was `115.375 -> 117.141 MB`. Its frontend columns are the runtime feature-flag variants described above and are not a revision comparison.
- Gates: Debug and Release builds passed; Markdown renderer 106/106 and asset synchronization 4/4 passed; targeted 7/7, storage 48/48, pagination 1/1, unit 795 executed / 3 skipped / 0 failures, strict 795 / 3 / 0; documentation/release/policy validators passed before tag. No migration, schema, renderer, or interaction behavior changed. Hosted TSan remains the release workflow's concurrency check.

## Row Construction And Index Mutation Release Evidence (v0.79.0, 2026-09-03)

- Environment: Apple M3 Pro, 36GB, 120 Hz display, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0; Release builds; real 9,566-row snapshot DB (`146,255,872` bytes) as a warm working copy; input posted as real `CGEvent`s; main-thread blocking measured as Accessibility round-trip latency (`scripts/perf-scroll/hoverstall`), which is answered on the app's main thread and therefore measures exactly how long that thread was unavailable.
- Search typing (`markdown`, 8 keys at 8/s, four paired runs alternating shipped `v0.78.2` and the candidate): main thread blocked `339/313/255/257 ms -> 184/174/225/226 ms`, means `291 -> 202 ms`; worst stall per run `147/109/86/79 ms -> 81/70/62/61 ms`, means `105 -> 68 ms`. The app's own search remained `12-39 ms` throughout, so this is front-end cost only.
- Same workload through the app profiler: row descriptor lookups `166 miss / 1245 hit -> 75 miss / 699 hit`, `row.display_model` total `110.3 -> 55.8 ms`, `text.metadata` total `108.9 -> 54.9 ms`. `row.init` count is unchanged by design; the change removes work from each init, not the number of inits.
- Clipboard capture (12 unique 4 KB text writes to the app's private pasteboard, five paired runs, full fuzzy index resident from a prior search): process CPU `0.372 -> 0.328 s` mean, improving in every pair.
- Scroll regression check (12 s mouse-wheel wheel stream, warm snapshot, four baseline and three candidate runs): CPU `3.82 -> 3.91 s`, main run-loop busy `2946 -> 2980 ms`, callback p95 unchanged at the `8.333/16.667 ms` clock steps. The baseline's own spread across its four runs was `3.76-3.92 s`, so both deltas are inside run-to-run variance and are recorded as no regression, not as a change.
- Correctness checks against the same snapshot: `markdown` 42 hits, `状态` 49 hits plus 1 pinned, `cm` 50 hits, and `markdown` 42 again after inserting new items through the mutated index path, identical between builds; rendered search-evidence text is byte-identical.
- Snapshot release bench: `cmd` p95 `0.526 ms` against a `50 ms` limit, prepared `cm` p95 `4.422 ms` against a `20 ms` limit, cold `cm` observed `59.510 ms` and remains record-only. All three improved slightly against the `v0.78.2` record (`0.561 / 4.508 / 61.224 ms`).
- Gates: `make build` and Release build passed; unit 795 executed / 3 skipped / 0 failures; strict 795 / 3 / 0; documentation, release, and policy validators passed before tag. TSan not run: no concurrency structure changed and the index change stays inside the existing search actor. Full frontend profile and unified table not run: this release's causal evidence is the paired real-input runs above, and the flag-toggle frontend harness is not a revision comparison.
- Measurement notes for future rounds: `scripts/perf-scroll/profile_scroll.py` previously referenced its repository path before defining it and therefore failed on every invocation, and it copied the superseded `fullindex.v4.plist` cache instead of the v5 binary caches, so earlier runs rebuilt the search index; both are fixed in this release. Menu-bar managers that hide the status item make `build/statusclick` unusable, so the panel is driven by the global hotkey.

## Copy Contract And Pinned Preview Release Evidence (v0.80.0, 2026-09-04)

- Environment: Apple M3 Pro, 36GB, macOS 15.7.3 (`24G419`), Xcode 26.1.1 (`17B100`), project Swift 5.9, deployment target macOS 14.0; Release build for the snapshot bench, Debug for the behavioral checks; real 9,566-row snapshot DB (`146,255,872` bytes) at `perf-db/clipboard.db`.
- Snapshot release bench: `cmd` p95 `0.546 ms` against a `50 ms` limit, prepared `cm` p95 `4.129 ms` against a `20 ms` limit, cold `cm` observed `61.413 ms` and remains record-only. Against the `v0.79.0` record (`0.526 / 4.422 / 59.510 ms`) the prepared short-index query improved and the other two moved within run-to-run spread.
- Write-path note: `SQLiteStatement.bindText` moved from a `-1` C-string length to an explicit byte count. It binds out of the string's own contiguous UTF-8 storage (`String.withUTF8`), so the common path adds no allocation; an earlier `Array(value.utf8)` formulation was replaced for exactly this reason before measuring.
- Maintenance semantics changed: the `> 128 MB` WAL branch in `StorageService.performCleanup` now issues `SQLITE_CHECKPOINT_TRUNCATE` instead of `PRAGMA incremental_vacuum`. The database is not created with `auto_vacuum=INCREMENTAL`, so the previous pragma could not reclaim anything; the truncating checkpoint is what actually shrinks an oversized `-wal`. `incrementalVacuum` is removed rather than kept behind a condition.
- Pinned preview verified against the running app through the Accessibility API (`AXUIElement` walk, press, and attribute set) because XCUITest could not start: separate `Pinned Preview` window created with the content moved into it and the popover gone; Markdown `History.Preview.RenderStatus` reads `rendered` both before and after pinning, so the shared WebView is reused rather than re-navigated; window resized to `420x500` and `980x760` with the document still `rendered`; `AXPosition` and `AXSize` settable and applied, and the frame restored from `setFrameAutosaveName` on the next pin; `kCGWindowLayer` observed as `3` by default, `0` after toggling always-on-top off, `3` again after toggling it back; explicit close removes the window and hover previews plus the shared WebView return; the window stays up after the history panel closes.
- Scroll reference: not re-measured. The only scroll-path change is one `Bool` added to `HistoryItemView`'s `Equatable`; the pinned flag reaches rows through the existing `HistoryRowContext` channel and changes only on pin and unpin.
- Gates: `make build` passed, and each of the two commits builds standalone; unit 821 executed / 3 skipped / 0 failures (807 at the first commit); strict 821 / 3 / 0 with no `Sendable` diagnostics; documentation and release validators passed before tag. TSan not run: the event-queue change stays inside the existing actor and the pinned preview is `@MainActor` throughout.
- Environment-blocked, and blocking for this host rather than for the release: XCUITest and `make perf-frontend-profile` both fail with `Timed out while enabling automation mode`, which requires an interactive system-authentication approval that could not be granted here. Each attempt also leaves `testmanagerd` unable to accept new sessions, which makes ordinary `make test-unit` fail with `The test runner hung before establishing connection` until that daemon is killed; kill it before concluding that a unit-test failure is real. `ScopyUITests/HistoryListUITests/testPinnedPreviewSurvivesListScrollAndClosesOnlyExplicitly` is committed and has never been executed.

## Homebrew Acceptance

Verify all of the following after release publication:

1. `curl -fsSL https://raw.githubusercontent.com/Suehn/Scopy/main/Casks/scopy.rb | sed -n '1,12p'`
2. `curl -fsSL https://raw.githubusercontent.com/Suehn/homebrew-scopy/main/Casks/scopy.rb | sed -n '1,12p'`
3. `brew tap Suehn/scopy`
4. `brew update`
5. `brew info --cask scopy`
6. `brew fetch --cask scopy -f`
7. Confirm `/Applications/Scopy.app` exists

If `HOMEBREW_GITHUB_API_TOKEN` is not configured, the workflow skips the external tap update by design. Treat either stale cask surface as a release follow-up blocker: sync the affected cask to the published DMG sha256, push the cask commit, and rerun the acceptance checks above.

Known release pitfalls:

- If `make push-release` fails over SSH because the local proxy closes the transport, retry the release push over HTTPS with `http.version=HTTP/1.1`.
- If the Xcode build succeeds but `Create DMG` fails immediately, search the workflow for `.build/Release/Scopy.app`. Xcode products must remain in DerivedData and the workflow must delegate to `scripts/build-release.sh`; bump the patch version before republishing instead of moving the failed tag.
- If `raw.githubusercontent.com` still shows an old cask right after a push, verify with GitHub API, git refs, a local tap checkout, or `brew info --cask --json=v2 scopy`; raw CDN lag is not authoritative by itself.
- If `brew fetch --cask scopy -f` fails with `LibreSSL SSL_connect` / `SSL_ERROR_SYSCALL` against `release-assets.githubusercontent.com`, separate local TLS transport failure from cask version or sha drift and rerun install checks when the transport path recovers.
- Local `make test-tsan` can skip on the known-bad `macOS 26.x + Xcode 26.2 (17C52)` runtime; Hosted TSan on `macos-15 + Xcode 16.0` remains the release concurrency coverage path.

## Historical Material

- Legacy deployment notes are preserved in [../archive/release-runbook-legacy.md](../archive/release-runbook-legacy.md).
- Older changelog entries live under [../archive/changelog/](../archive/changelog/README.md).

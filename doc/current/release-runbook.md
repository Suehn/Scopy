---
doc_type: runbook
status: active
owner: maintainers
last_reviewed: 2026-07-11
canonical: true
related_versions:
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
- Homebrew version comparison is numeric, not chronological: `0.8.8 < 0.64 < 0.65.0`. Because historical `v0.64` shipped, the next distributable version is `v0.65.0`; do not publish `v0.8.9`, which Homebrew would still treat as older than `0.64`. Continue from `v0.65.x` or later after this repair.
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

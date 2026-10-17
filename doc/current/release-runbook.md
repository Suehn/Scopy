---
doc_type: runbook
status: active
owner: maintainers
last_reviewed: 2026-09-05
canonical: true
related_versions:
  - v0.80.1
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
3. Run `make build` and `make test-unit`; add TSan, UI, snapshot/backend, frontend, packaging, and deployment gates required by the change scope.
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
- Every Swift-flag test variant builds into its own DerivedData root (`Scopy-Strict` and `Scopy-TSan` under `~/Library/Developer/Xcode/DerivedData/Scopy-<checkout-path-hash>`). Both checkout and flag variant are isolated, so concurrent worktrees cannot overwrite each other's build database or test products. Plain `build` uses Xcode's default project-path-scoped DerivedData; `test-unit` is the single strict native run. The former "Stage SwiftPM Resource Bundles" pre-build phase was removed outright: the package declares no resources, so the phase only burned a 2.5s retry loop on every build.
- `make test-tooling` runs the shell/Make regression checks locally and in CI; they are correctness checks, not app runtime performance measurements (the 2026-09-05 run is archived in [../archive/release-runbook-evidence-2026-09-05.md](../archive/release-runbook-evidence-2026-09-05.md)).
- `scripts/build-release.sh` uses the same isolation and retained-log contract for tagged packaging while keeping the final DMG under `.build/`.
- XCTest runtime fixtures belong in the test bundle. Performance DB copies and in-progress JSON belong under `/tmp` or DerivedData; shell wrappers may copy completed evidence into repository `logs/` only after `xcodebuild` succeeds. This avoids file-coordination/TCC stalls in Documents-hosted worktrees.

## Verification Expectations

- Baseline build/tests: `make build`, `make test-unit`
- Release workflow policy: `make release-validate`, `make test-release-policy`; ordinary workflows must remain top-level read-only and unable to create or push tags
- Concurrency-sensitive changes: strict compilation is included in `make test-unit`; add `make test-tsan` when the environment permits; on the known-bad `macOS 26.x + Xcode 26.2 (17C52)` combo the command skips because Apple hosted TSan crashes before test bootstrap, while the supported real-coverage path runs in Hosted TSan CI on `macos-15`
- Perf-sensitive changes:
  - `make test-snapshot-perf-release`
  - `make perf-search-warm-load`
  - `make perf-scroll-wheel`, `make perf-search-type`, or `make perf-capture` as an interleaved A/B under the development guide's performance evidence protocol when the release claims an interaction-latency change
  - `make perf-frontend-profile-full` before release only where XCUITest can run; otherwise record it as environment-blocked

## Homebrew Acceptance

Use the checksum from the published `Scopy-<version>.dmg.sha256` asset and verify the downloaded DMG against it. Compare both casks' version and SHA:

```bash
curl -fsSL https://raw.githubusercontent.com/Suehn/Scopy/main/Casks/scopy.rb
curl -fsSL https://raw.githubusercontent.com/Suehn/homebrew-scopy/main/Casks/scopy.rb
brew tap Suehn/scopy
brew update
brew info --cask --json=v2 Suehn/scopy/scopy
brew fetch --cask Suehn/scopy/scopy -f
brew reinstall --cask Suehn/scopy/scopy --force --appdir=/Applications
defaults read /Applications/Scopy.app/Contents/Info CFBundleShortVersionString
defaults read /Applications/Scopy.app/Contents/Info CFBundleVersion
```

- Use the fully qualified cask token so a different tap cannot satisfy acceptance. Confirm the app launches from `/Applications` after installation; a download or Caskroom copy alone is insufficient.
- The release workflow may push a follow-up cask commit to `main`. Fetch and inspect it, then integrate without overwriting local work.
- External tap synchronization depends on `HOMEBREW_GITHUB_API_TOKEN` and may skip. If needed within the authorized release, update the tap cask to the verified release version/SHA in an isolated checkout, push it, and recheck Homebrew. A successful main-repository cask update does not prove external tap parity.
- Raw CDN lag and TLS download failures are different from a wrong cask version/SHA. Check repository refs and Homebrew's parsed state before choosing a repair; do not blindly reset taps, delete directories, or change global Git settings.
- Never overwrite published tags or assets. Use a new monotonic version for a repair release.

## Evidence Retention

Current release evidence is linked by `release_doc` and `profile_doc` in metadata. Record new performance/deployment changes here with their environment, measured values, and a link to their detailed release/profile evidence. Do not treat an older pass as verification of a new checkout.

Dated historical observations formerly embedded in this runbook are preserved in [release-runbook-evidence-2026-09-05.md](../archive/release-runbook-evidence-2026-09-05.md).

### 2026-10-17 Unreleased Reliability And Test Simplification

- Source baseline: `bb9269f57d804420e3cf2aa417326dfaff4893dc`; local branch `codex/behavioral-reliability`. This is development evidence, not a release, packaging, or installation acceptance. Version metadata and the installed application were not changed.
- Environment: macOS 27.2, Xcode 27.0 (`27A5194q`, `/Applications/Xcode-beta.app`), Swift 6.4 compiler. Project baselines remain unchanged.
- Native test methods: 829 → 747; UI methods: 69 → 56 (95 fewer overall). Removed mock-only behavior checks, implementation mirrors, the AppState test compatibility facade, HotKeyService testing mode, and row descriptor dependency injection. Native CI now runs strict concurrency and warnings-as-errors once through `make test-unit`.
- Debug and universal Release builds passed. The final complete `make test-unit` passed: 747 cases, 0 failures, 4 existing skips, 48.975 seconds of test execution. Skips were the opt-in row screenshot and live-network probes, plus two export cases whose string-loaded documents cannot load the renderer in this test host. These skips are separate from the six WebKit failures below. Local XCUITest and TSan were not run in this pass.
- The initial six WebKit failures were a test-host issue: the standalone runner's document stayed `hidden`, with resources ready but `layoutEpoch=0`. Reusing the existing `ScopyTestHost` with accessory activation made the same unmodified six cases pass (11.309 seconds); the typography probe reported `visible`, `layoutEpoch=2`, and `paintReady=true`. Window-position/activation experiments were reverted; production paint readiness was unchanged. The host's empty delegate was removed.
- Those six cases were then reduced to four: computed styles, resize, hidden-prewarm visibility, and one combined image/source-icon load. The combined case retains delayed native loading, real decoding/geometry, ordinary-image and compact-icon fallback, and export preservation; duplicate SVG structure checks stay in Node. Resize checks use 80%/115%, overlay/reserved scrollbars, and narrow/wide/narrow sizes (two loads/eight checks instead of six loads/36 checks). All four passed in the final complete run.
- Renderer: all 211 Node cases and atomic asset verification passed. A real application export of the math/CJK/table/code fixture was visually checked; baseline/current PNG bytes matched (53,155 bytes, SHA-256 `72e87337a91d054f0c99d3b8987ab3b94324cdeda04194e7a21245e752104069`).
- Real DB snapshot: 16,690 rows, 340,828,160 bytes, SHA-256 `2724012f0ee77159913116aec7d28ecff336191e084826161aeed7f2df43625d`. The original database was not mutated by benchmarks.

| Release search workload | Baseline, quiet A/B (ms) | Current, quiet A/B (ms) | Final gate (ms) |
| --- | --- | --- | --- |
| Prepared `cm`, p95 | 16.217 / 18.320 | 16.732 / 16.502 | 19.017, limit 20 |
| Cold `cm`, single request | 125.093 / 117.455 | 116.945 / 113.837 | 112.181, observation only |
| Service `cmd`, p95 | 15.514 | 15.425 | 25.101, limit 50 |

- `make test-snapshot-perf-release` passed. The measurements establish no observed regression; they do not establish a speed improvement. Quiet prepared-query runs used interleaved A–B–B–A ordering. An initial Unicode implementation regression was corrected before these final measurements.
- Actual app capture with a private pasteboard and snapshot copy: all three newly committed DB IDs matched the first three Recent rows. Actual wheel scrolling recorded 239 active frames / 180 input events; active frame interval p95 was 25.000 ms, main-runloop busy p95 0.878 ms. These are smoke observations, not frontend A/B improvement evidence.
- Actual Carbon hotkey registration/press used an isolated app identity and preferences: one registration update, one pressed event, one handler invocation; panel hidden in 67.6 ms. Settings transaction/coordinator behavior passed native tests; manual Settings inspection was blocked by the app automation connection timeout.
- Local raw evidence is retained under ignored `logs/behavioral-reliability/` (`native-hosted-final.log`, `webkit-six-hosted.log`, `webkit-focused-final.log`, earlier `native-*.log`, `snapshot-perf-final.log`, `backend-*.jsonl`, `capture-final/`, `scroll/`). UI text dumps were redacted; do not publish clipboard snapshots or screenshots. Hotkey and PNG fixtures are under `/tmp/scopy-behavioral-validation-20261017/` and are temporary local evidence.

### 2026-10-17 Continuation: Reliability Fixes And Search Matcher

- Same source baseline and branch, uncommitted on top of the section above; development evidence, not a release. Environment: Apple M3, 8 cores, 24 GB; macOS 27.2 (`26B5101f`); Xcode 27.0 (`27A5194q`); Swift 6.4. Project baselines (Swift 5.9, macOS 14) unchanged. The Xcode 16 CI compile was not run locally.
- Fixes:
  - **Capture:** a pending envelope whose payload was already gone (`ENOENT`) is quarantined and capture continues; it no longer blocks the FIFO head. A quarantine-name collision now uses a unique name; previously it retried forever.
  - **Quit:** quit waits at most 5 s for pending deletes. Search now closes before storage, so storage's final close truncates the WAL: an isolated real-app quit left a 461,472-byte `-wal`; now 0 bytes, with terminate completing in 0.110 s. A failed delete cancels only a user or updater Quit; logout, restart and shutdown (`kAEQuitReason`) still quit. The real logout path was not exercised.
  - **History list:** a new item joining a filtered list counts once, and pagination still reaches the oldest row. Scan-decided search pages derive `hasMore` from the ids they already hold, with no second count.
  - **Storage:** `resolvingSymlinksInPath` returns the `/private/var` spelling for a file removed mid-call (7,041 of 200,000 resolutions in a race probe). That gave one file two reservation keys and failed the containment check. Keys and the check now resolve the directory, which removed a 1-in-60 flake in `testOrphanCleanupReservationSerializesReconcileAfterDeleteGuard` (200/200 after).
  - **Search:** CJK trigram queries use the FTS index again. Every Swift-side substring decision goes through `LoweredTextMatcher`, which decides on UTF-8 bytes where they provably agree with `String` and defers otherwise. Full-index postings are conservative for scalars inside multi-scalar characters.
- Matcher evidence: a differential fuzz of 400,000 random texts compared each decided outcome with `text.lowercased().range(of:)`. Texts mixed combining marks, Kelvin sign, İ, Prepend, ZWJ, VS16, Hangul jamo, CJK and emoji. Result: 0 mismatches, 96% decided on bytes. Disabling the preceding-neighbour check produced 258 mismatches; disabling the following-neighbour check produced 2,388.
- `make test-unit`: 744 passed, 0 failed, 0 skipped (50.3 s). The `ScopyTSanTests` bundle under Thread Sanitizer (the `make test-tsan` command, run in a scratch copy of the tree): 741 passed, 0 failures, no TSan reports. `make test-snapshot-perf-release` passed: `cmd` p95 15.8 ms (limit 50), prepared `cm` p95 16.0 ms (limit 20).
- Release-build A/B against baseline `bb9269f` on the same 16,690-row snapshot (SHA-256 prefix `2724012f0ee77159`, 62 MB of text), A–B–B–A, median of 5 after 1 warm-up. Each binary used its own APFS clone, because the two cache versions (`shortindex` v3 and v4) evict each other in one directory. Sharing a directory inflated the baseline's `e`/`co` to 74/84 ms in an earlier run; those numbers are void.

| Query (layer) | Baseline (ms) | Current (ms) | Change |
| --- | --- | --- | --- |
| `한` (service) | 60.4 | 37.0 | −39% |
| `é` (service) | 89.5 | 65.0 | −27% |
| `が` (service) | 74.0 | 42.1 | −43% |
| `д` (service) | 64.0 | 31.0 | −52% |
| `我` (service) | 59.7 | 31.6 | −47% |
| `的` (service) | 30.7 | 25.0 | −19% |
| `e` (service) | 23.9 | 23.3 | −3% |
| `co` (service) | 22.6 | 23.5 | +4% |
| Cold `cm`, single request (service, 5 runs) | 110.7–121.0 | 83.5–85.2 | −24% |
| Forced `config`, relevance (engine) | 16.6 | 4.8 | −71% |
| Forced `config`, recent (engine) | 27.4 | 25.4 | −7% |
| Forced `cmd`, relevance (engine) | 20.8 | 17.0 | −18% |
| Forced `cmd`, recent (engine) | 16.4 | 17.2 | +5% |
| Forced `é cole` (engine) | 211.2 | 117.8 | −44% |
| Forced `한 국어`, `数 据库`, `我 config`; exact `量子纠缠态`, `我们的`, `résumé`, `config` | — | — | within ±0.2 ms |

- Remaining costs: ASCII matches now rank by UTF-16 offsets, the same unit as the full index, instead of byte offsets. That adds about 1 ms to `co` and to forced `cmd` recent; most of those queries' time is match-context building, which is unchanged. The first whole-character non-ASCII needle builds a lowercase-expansion table once (about 20 ms).
- Local raw evidence: ignored `logs/claude-*.log` (`claude-test-unit-final4.log`, `claude-snapshot-perf-final2.log`, `claude-ab-final3.log`, `claude-flake-orphan*.log`). The differential fuzzer and A/B scripts were scratch files and are not retained.

### 2026-10-18 Recent History Keyset Paging

- Source baseline: `209f3ca` (`codex/behavioral-reliability`); branch `codex/keyset-history-paging`. This is development evidence, not a release. Environment: Apple M3, 8 cores, 24 GB; macOS 27.2 (`26B5101f`); Xcode 27.0 (`27A5194q`); Swift 6.4. Project baselines (Swift 5.9, macOS 14) unchanged.
- Change: the recent list continues from the key of its last row (`RecentHistoryCursor`, `last_used_at DESC, id ASC` on `idx_recent_order`) instead of an offset. The mutation-sequence rebase is gone. Before, any event between pages made the next read return `offset + limit` rows from 0 and replace the visible prefix in one step. Now a stale read is read again as one page from the same cursor.
- Real DB snapshot: 16,709 rows (49 pinned), 340,828,160 bytes, SHA-256 `1e37e0fdc9099546d399e0999574dc389994df50da9c356ed18f37c01adbbaf0`. The original database was not mutated.
- SQLite page read of 301 summary rows on that snapshot (Python `sqlite3`, read-only, 30 iterations, p50 / p95 ms). The keyset rows equal the offset rows at every depth. SQL time only; the old rebase also converted and replaced every prefix row in the UI.

| Depth (rows) | Offset page | Old rebase prefix read | Keyset page |
| --- | --- | --- | --- |
| 350 | 2.11 / 3.19 | 3.77 / 5.21 | 2.41 / 2.94 |
| 2,000 | 2.09 / 3.36 | 19.03 / 21.07 | 1.91 / 2.07 |
| 5,000 | 0.59 / 0.70 | 28.56 / 31.44 | 0.43 / 0.50 |
| 10,000 | 1.24 / 1.42 | 48.39 / 57.17 | 0.99 / 1.08 |
| 16,000 | 2.83 / 3.06 | 80.08 / 93.78 | 1.95 / 2.10 |

- `make test-unit`: 742 passed, 0 failed (50.8 s). `make test-tsan` (`ScopyTSanTests`): 739 passed, 0 failed, no ThreadSanitizer reports (63.8 s). The real-storage paging test `testRealHistoryPagesContinueFromTheLastRowAcrossConcurrentChangesAndQuitPersistsDeletion` and `testLoadReadsAgainUntilNoEventArrivesDuringTheRead` passed 10/10 iterations each. A temporary probe confirmed that every iteration of the former hit the between-chunks re-read.
- `make test-snapshot-perf-release` passed in every run of an A–B–B–A against `209f3ca`; each checkout used its own APFS clone of the snapshot. Search code is unchanged, so this shows no regression, not an improvement.

| Release search workload | Baseline A1 / A2 (ms) | Current B1 / B2 (ms) | Limit (ms) |
| --- | --- | --- | --- |
| Service `cmd`, p95 | 15.38 / 15.59 | 15.38 / 15.21 | 50 |
| Prepared `cm`, p95 | 16.85 / 15.99 | 16.94 / 16.04 | 20 |
| Cold `cm`, single request | 86.4 / 92.0 | 83.3 / 83.1 | observation only |

- Not run: `make perf-frontend-profile`, which drives the real app with synthetic wheel input. Frontend scroll/load-more latency is therefore not measured for this change.

### 2026-10-18 v0.82.2 Release Gates

- Release candidate `5fb38d7` contains the three sections above. Environment: Apple M3, 8 cores, 24 GB; macOS 27.2 (`26B5101f`); Xcode 27.0 (`27A5194q`). Release note: [v0.82.2](../releases/history/v0.82.2.md).
- `make build` passed; `make test-unit` 742 passed, 0 failed, 0 skipped (51.3 s). Hosted CI `39057779920` and Hosted TSan `39057779924` passed on the same commit.
- `make test-snapshot-perf-release`, five consecutive runs on one clone of the snapshot (SHA-256 prefix `2724012f0ee77159`, unchanged after the runs):

| Run | Service `cmd` p95 (ms) | Prepared `cm` p95 (ms) | Cold `cm` (ms) | Gate |
| --- | --- | --- | --- | --- |
| 1 | 16.07 | 17.11 | 185.1 (cache rebuild on the fresh clone) | pass |
| 2 | 16.55 | 18.74 | 89.4 | pass |
| 3 | 16.43 | 21.89 | 89.5 | fail (limit 20) |
| 4 | 15.27 | 16.68 | 84.8 | pass |
| 5 | 15.50 | 16.79 | 85.4 | pass |

- Run 3 coincided with external load: right after it, another application used 1.7 cores and the load average was 7. Prepared `cm` p95 sits at 80–95% of its limit on this snapshot for both this candidate and baseline `bb9269f` (16.2 / 18.3 ms), so external load can push it over.

### 2026-10-18 Search Stage 1: Bounded Fragment Context And CRC-32 Cache Check

- Source baseline: `c05ba8d` (v0.82.2); branch `claude/search-fragment-crc`. Development evidence, not a release. Environment: Apple M3, 8 cores, 24 GB; macOS 27.2 (`26B5101f`); Xcode 27.0 (`27A5194q`); Swift 6.4. Project baselines (Swift 5.9, macOS 14) unchanged. The Xcode 16 CI compile was not run locally.
- Changes:
  - **Match context:** `SearchMatchContextBuilder.makeFragment` walks at most `leadingContextCharacters` back from the match, `index(_:offsetBy:limitedBy:)`, instead of counting characters from the start of the text. Same slice: a fuzz of 975,395 random texts and UTF-16 match positions (combining marks, ZWJ, emoji, flags, CR LF, Hangul jamo, Prepend, Indic clusters) found 0 differences in slice start or leading count.
  - **Index caches:** the `.crc32` sidecar (zlib `crc32_z`) replaces the `.sha256` sidecar. It only guards against truncation and corruption; the header's mutation sequence and the decoder's checks are unchanged. Cache versions: short index 4 → 5, full index 8 → 9, so older files are deleted and rebuilt once.
- Real DB snapshot: 16,727 rows, 341,401,600 bytes, 65 MB of plain text, SHA-256 `30841d150cc108a5114328f0308e4283ce36cb0b4065eb8a893d3d9b16f4ee6c` (unchanged after the runs). Each binary used its own `cp -c` APFS clone.
- Release ScopyBench binaries (SHA-256 prefix): baseline `c065d858`, fragment change alone `deef157b`, stage 1 `a65aba48`. Median of each run's samples (service `cmd`: 30 after 20 warm-ups; prepared engine `cm`: 30 after 3; service `co`/`e`: 15 after 3; cold `cm`: 1). One discarded warm-up run per clone.

| Service / engine workload (ms) | A/A, 3 interleaved pairs | Baseline, 5 ABBA pairs | Fragment change, 5 ABBA pairs |
| --- | --- | --- | --- |
| Service `cmd` | 15.07 / 15.01 | 15.07–15.73 (mean 15.38) | 12.15–12.34 (mean 12.26) |
| Prepared `cm` | 16.17 / 16.18 | mean 16.43 | mean 16.57 |
| Service `co` | 23.25 / 23.13 | mean 25.22 | mean 23.80 |
| Service `e` | 24.41 / 24.46 | mean 24.77 | mean 25.25 |
| Cold `cm` | 85.35 / 96.89 | mean 88.68 | mean 85.34 |

- Only `cmd` moved: every fragment-change run beat every baseline run, by 3.1 ms against an A/A resolution of 0.06 ms. The other workloads overlap the noise.
- A second 5-pair ABBA, baseline against stage 1, ran under external load (load average 5–7, another application's renderer at 80% CPU): `cmd` 15.68–16.65 → 13.39–13.41 ms, prepared `cm` 18.13 → 17.94, `co` 25.89 → 25.55, `e` 27.20 → 26.98, cold `cm` 87.99 → 88.70 (means). The cold request runs before the short index is ready, so the checksum is not on its path.
- Cache loads, from the engine's own `Short/Full index disk cache load hit in N ms` log lines, 12-run A/A and 16-run ABBA, first (cold page cache) run per side discarded:

| Disk cache load (ms) | A/A | Baseline | Stage 1 |
| --- | --- | --- | --- |
| Full index, 74 MB | 91–94 / 91–96 | 91–96 (median 91) | 68–73 (median 70) |
| Short index, 35 MB | 80–89 / 81–89 | 80–91 (median 83) | 71–78 (median 74) |

- The checksum alone on those files, warm: SHA-256 24.2–25.0 ms vs CRC-32 1.9–2.1 ms (74 MB), 11.4–12.3 vs 0.8–0.9 ms (35 MB). The full index reloads after every 60 s idle trim and the short index on every launch.
- `make build` passed; `make test-unit`: 742 passed, 0 failed, 0 skipped (51.5 s). `make test-snapshot-perf-release` on the stage-1 clone, three runs: `cmd` p95 12.18 / 11.92 / 14.17 ms (limit 50), prepared `cm` p95 16.29 / 16.06 / 15.43 ms (limit 20), cold `cm` 213.5 (first run after the build) / 83.5 / 83.6 ms. All passed.
- Not measured: the app's first launch after the upgrade, which rebuilds both caches once (about 4.1–4.6 s for the full index on this snapshot).

### 2026-10-18 Search Stage 2: Recent Early Stop, Page Continuation And Relevance Prefix Reads

- Source baseline: `cd41a95` (stage 1, branch `claude/search-fragment-crc`); branch `claude/search-recent-early-stop`. Development evidence, not a release. Environment and project baselines as in stage 1.
- Changes:
  - **Recent early stop:** recency decides before the score, so a recent-sorted fuzzy ranking scores rows newest first. It stops once the window and one more hit are in and the next row starts another (pinned, last used) group, so rows that share a timestamp keep their score order. This covers `FullIndexRanker.rankComplete` and the one- and two-character SQL path `SearchReadStore.searchShortQuerySubstring`. The SQL path reads order and recency from the covering `idx_recent_order`, because a row's recency columns lie behind its text's overflow pages. Filters become index-only rowid subqueries. `total` is `-1` with `hasMore` until the scan reaches the end; the footer already shows "+" for a negative total.
  - **Page continuation:** a page whose offset is the previous page's end, with the same query, filters and sort, continues that scan instead of rescoring from the start. The ranker keeps the scan in its `SortedMatchesCache`; the read store keeps it while `mutation_seq` is unchanged. Any other request runs the original query, and callers see no new API.
  - **Relevance prefix reads:** relevance reads each plain text's first 4 KB through SQLite blob I/O (`SQLiteBlobReader`). A row whose prefix ends between two ASCII characters is decided there. Any other row is read in full only while its best possible score could still enter the window.
  - **Fallback threshold:** past 4,096 short-index candidates, the engine scans every row instead of passing the ids to SQL. It now does so above 10% of the rows (recent) or 50% (relevance), down from 85%.
- Real DB snapshot, clones and protocol as in stage 1 (SHA-256 `30841d15…ee6c`, unchanged after the runs). Release ScopyBench binaries (SHA-256 prefix):
  - stage 1 with the new bench options: `0302b297`;
  - stage 2: `14f431e5`;
  - stage 2 without page continuation: `1eea5b3e`;
  - stage 2 with full-text relevance reads and the 85% threshold: `23be5ec8`.
- Workloads, all engine layer except `cmd` and the cold requests:
  - `f*`: full index (`--force-full-fuzzy`), searching `数据库` untimed before each run so the ranking cache misses as on a new keystroke; 15 samples after 3 warm-ups.
  - `s*` and `r*`: prepared short index, 15 samples after 3 warm-ups.
  - `p*`: ten consecutive 300-row pages per sample; 7 samples after 2 warm-ups.
  - `cmd`, prepared `cm` and the cold requests: as in stage 1.
- Results are means of run medians, in ms. The first stage-2 run on its fresh clone (cold page cache: cold `cm` 111.1, cold recent `cm` 327.9) is left out of the cold rows.

| Workload (ms) | A/A, 3 interleaved pairs | Stage 1, 5 ABBA pairs | Stage 2, 5 ABBA pairs |
| --- | --- | --- | --- |
| Recent full index `e` | 13.41 / 13.52 | 13.31 | 4.07 |
| Recent full index `co` | 20.45 / 20.76 | 20.52 | 4.74 |
| Recent full index `数据` | 23.90 / 23.98 | 23.67 | 14.09 |
| Recent full index `cm` | 134.9 / 135.2 | 134.1 | 94.6 |
| Recent short `e` | 25.17 / 25.05 | 24.45 | 3.59 |
| Recent short `co` | 25.36 / 24.88 | 25.27 | 4.30 |
| Recent short `数据` | 32.22 / 30.92 | 31.18 | 15.30 |
| Recent short `cm` | 97.73 / 96.98 | 96.82 | 87.88 |
| Recent cold `cm` (service) | 168.2 / 166.7 | 165.1–171.6 | 106.1–109.0 |
| Recent short `e`, 10 pages | 423.1 / 413.5 | 418.6 | 134.2 |
| Recent short `co`, 10 pages | 491.2 / 479.7 | 476.5 | 266.6 |
| Recent full index `e`, 10 pages | 148.9 / 146.3 | 144.7 | 126.5 |
| Service `cmd` (control) | 12.16 / 12.09 | 11.83 | 11.90 |
| Prepared relevance `cm` (gate) | 16.05 / 16.24 | 16.07 | 10.04 |
| Cold relevance `cm` (service) | 86.0 / 86.8 | 83.8–87.5 | 84.6–88.5 |
| Relevance short `e` | 24.57 / 24.80 | 23.86 | 20.79 |
| Relevance short `co` | 23.81 / 22.70 | 23.32 | 21.01 |
| Relevance short `数据` | 34.86 / 34.38 | 34.25 | 30.12 |
| Relevance full index `e` (control) | 9.24 / 9.11 | 9.05 | 9.15 |

- Each item was isolated with 5-pair ABBA runs against stage 2:
  - **Page continuation**, against the binary without it: short `e` 172.0 → 135.2, short `co` 375.2 → 266.2, full-index `e` 137.8 → 128.3 (10 pages, ms).
  - **Relevance prefix reads**, against full-text reads with the 85% threshold: prepared `cm` 16.05 → 9.96, `e` 24.43 → 20.93, `co` 23.00 → 21.26, `数据` 33.50 → 30.95. Cold `cm` is about equal; that binary's first cold run, a 508.6 ms outlier, is left out.
- Dropped parts of the deep-paging item, measured on this snapshot:
  - **Empty-query keyset:** `LIMIT/OFFSET` pages cost 1.3 / 0.5 / 0.7 ms at offsets 0 / 3,000 / 9,000.
  - **FTS rowid cache:** an FTS page costs a constant ~15 ms at any depth, with at most 3.2k matches. Match evidence costs 107–445 ms per 300-row page, so the offset is not the cost.
  - **`instr` fallback keyset:** this fallback is reached only by exact-mode non-ASCII queries with no FTS match.
- Remaining cost: match-evidence generation is 76–80 ms of the 88–100 ms recent short `cm`, and most of each FTS or `instr` page.
- `make build` passed; `make test-unit`: 747 passed, 0 failed.
  - New golden tests compare page windows with the full ranking on the full-index, short-index SQL and full-scan paths, for timestamp ties, the 4 KB prefix cut, CJK and combining-mark prefixes, filters, and a commit between pages.
  - Removing tie-group completion or the continuation sort makes them fail.
- `make test-snapshot-perf-release` on the stage-2 clone, four runs:
  - `cmd` p95 12.08 / 12.05 / 11.92 / 12.62 ms (limit 50);
  - prepared `cm` p95 10.23 / 10.18 / 9.92 / 10.66 ms (limit 20);
  - cold `cm` 103.2 / 85.9 / 85.5 / 88.5 ms.

  All printed under their limits. Only the fourth run's exit status was captured, and it was 0.
- Load average during the A/B runs: 2.6–3.5.
- Not measured: the real app's typing and scrolling (`make perf-search-type`, `make perf-scroll-wheel`).
- Unchanged: cold relevance requests, which run before the short index is ready.

### 2026-10-18 Search Stage 3: SIMD Plain-Text Skip In LoweredTextMatcher

- Source baseline: stage 2 at `b4a1f95` (includes `main` `347238f`); branch `claude/search-simd-matcher`. Development evidence, not a release. Environment and project baselines as in stage 1.
- **Change:** between special scalars, lowercasing keeps each scalar's UTF-16 length and adds no ASCII unit. So `LoweredTextMatcher` now checks 16 bytes per step (`SIMD16<UInt8>`) for well-formedness and counts their UTF-16 units. It stops at the first special scalar, malformed byte, or byte that can start the ASCII needle in either case, and leaves the last 17 bytes to the per-scalar path. Decisions are unchanged.
- **Differential fuzz:** 3 seeds × 400,000 random texts, compared with `text.lowercased()` and `range(of:)` or a UTF-16 search.
  - Texts mixed combining marks, Kelvin sign, İ, Prepend, ZWJ, VS16, Hangul jamo, CJK, emoji, four-byte scalars, malformed bytes (1 text in 6) and runs of up to 600 pieces.
  - Result: 4,675,599 comparisons, 3,884,315 decided on bytes, 0 mismatches.
  - On seed 1, both the stage-2 and the stage-3 matcher decided exactly 1,294,738 of the 1,558,492 comparisons.
- **Negative controls:** each disables one check; mismatches on seed 1 at 400,000 texts, then on the new unit test.

| Disabled check | Fuzz mismatches | `LoweredTextMatcherTests` mismatches |
| --- | --- | --- |
| Preceding-neighbour check | 3,512 | 74 |
| Following-neighbour check | 20,769 | 668 |
| Continuation structure | 5,106 | 62 |
| E0/ED/F0/F4 second-byte ranges | 11,541 | 159 |
| Invalid leads (C0, C1, F5–FF) | 4,239 | 47 |
| Special-scalar stops | 155,524 | 1,961 |
| Uppercase needle stop | 49,682 | 1,292 |
| Stop byte's own well-formedness | 123 | 3 |
| Back-up before the final scalar | 136,326 | 422 |
| Second unit of four-byte scalars | 498,916 | 5,424 |
| Neighbour bookkeeping after a skip | 2,084 | 39 |
| Lane flush every 7 blocks (moved to 64) | 1 | 1,889 |

- **New unit test:** `LoweredTextMatcherTests` runs the same comparison on 1,500 seeded texts with long runs, in 1.4 s in the Debug test host.
  - It decides 80.7% of comparisons, against a 70% floor.
  - The real XCTest run fails on the weakest control (3 mismatches).
- Real DB snapshot as in stage 1 (SHA-256 `30841d15…ee6c`). Each binary used a fresh APFS clone.
- Release ScopyBench binaries (SHA-256 prefix), both built from one scratch copy so the embedded paths match: stage 2 `67265065`, stage 3 `9f4d3823`. Workloads as in stage 2. Means of run medians, ms.

| Workload (ms) | A/A, 3 interleaved pairs | Stage 2, 5 ABBA pairs | Stage 3, 5 ABBA pairs |
| --- | --- | --- | --- |
| Prepared relevance `cm` (gate) | 9.68 / 9.65 | 9.67 | 7.72 |
| Relevance short `e` | 20.13 / 20.17 | 20.21 | 17.99 |
| Relevance short `co` | 20.42 / 20.52 | 20.85 | 16.77 |
| Relevance short `数据` | 29.47 / 29.52 | 29.70 | 26.46 |
| Relevance full index `e` | 8.89 / 8.95 | 8.94 | 7.79 |
| Recent full index `cm` | 92.72 / 92.71 | 92.60 | 86.61 |
| Recent short `cm` | 86.04 / 85.97 | 86.03 | 85.20 |
| Recent short `co`, 10 pages | 258.85 / 259.17 | 258.71 | 256.13 |
| Service `cmd` | 11.72 / 11.74 | 11.73 | 11.72 |

- Unchanged within noise: recent `e`, `co` and `数据` on both indexes, and the `e` page runs. Their early-stopped scans read little text.
- **Cold requests:**
  - During the 5-pair run, XProtect's remediator used 88% CPU. Both sides then had single-request outliers of 140–330 ms.
  - A second 10-pair ABBA of the cold requests alone ran after XProtect exited. Medians, first entry per side excluded (a page-in outlier on both sides):

| Cold request | Stage 2 (ms) | Stage 3 (ms) |
| --- | --- | --- |
| Relevance `cm` | 86.7 (84.0–88) | 64.8 (64.0–68) |
| Recent `cm` | 106.4 (105.5–108) | 102.5 (99.4–105) |

- `make build` passed; `make test-unit`: 753 passed, 0 failed. `make test-snapshot-perf-release` on the stage-3 clone passed three times:
  - `cmd` p95 12.79 / 12.65 / 12.19 ms (limit 50);
  - prepared `cm` p95 9.07 / 7.91 / 7.94 ms (limit 20);
  - cold `cm` 138.5 (first run after the build) / 63.4 / 63.6 ms.

### 2026-10-18 Search Stage 4: Short-Index Bigram Filter For Fuzzy+ ASCII Words

- **Source baseline:** stage 3 at `bce089d` (includes `main` `b169d85`); branch `claude/search-bigram-filter`. Development evidence, not a release. Environment and project baselines as in stage 1.
- **Change:**
  - Fuzzy+ matches an ASCII word of three or more characters as a substring of whole characters, so each adjacent byte pair of the word is adjacent in the lowercased text.
  - While the short index is installed, `searchInFullIndex` drops full-index candidates that lack one of those pairs in the short index's ASCII bigram postings. This runs before scoring and before the staging decision.
  - Pairs with ";" or "`" are skipped, an id the short index does not hold passes, and fuzzy mode is never filtered.
- **Where it applies:** on this snapshot, a heavy-text corpus (average plain text ≥ 1 KB), every fuzzy+ query made only of such words skips the full index.
  - While typing, the FTS prefilter serves it. The per-request phases show `fts_prefilter` and no full-index phase, for `config` and for mixed queries such as `co config` and `config 数据`.
  - On refine (`forceFullFuzzy`), SQL substring search serves it.
  - So here the filter serves only the refine of a mixed query, one that also has a word under three characters or a non-ASCII word. On lighter corpora it serves every such query.
- **Dropped:**
  - **CJK bigrams** (estimated 5.1× for `数据库`): non-ASCII fuzzy+ words, and every fuzzy-mode query of three or more characters, match as subsequences. A bigram filter would drop real matches such as `数x据y库`.
  - **Incremental narrowing while typing (item 8):** it was to apply only together with the bigram filter. On this corpus, typing a query of three or more characters never reaches the full index.
- **No missed matches:**
  - **Committed test:** `testFuzzyPlusFullIndexFindsTheSameRowsThroughTheShortIndexBigrams` builds two engines on one seeded 400-row fixture, one with the short index and one without (below its corpus size only a forced build creates it). It compares ids, `total` and `hasMore` for 16 fuzzy+ and fuzzy queries in both sort orders.
  - **Fixture content:** U+037E, U+1FEF, the Kelvin sign, combining marks, ZWJ, ZWSP, soft hyphen, İ, a ligature, CR LF and lone ";" and "`".
  - **Scratch run** of the same test, not committed: 30 seeds × 1,900 rows, 1,920 result comparisons, 0 mismatches.
  - **Controls:** keeping the ";" and "`" pairs fails the committed test (12 failures), and so does filtering fuzzy mode (4). Filtering two-character words does not fail it: fuzzy+ matches them as UTF-16 code-unit substrings, so their bigrams are also present. That is a safe extension, not taken.
- Real DB snapshot as in stage 1, a fresh APFS clone per binary. Release ScopyBench binaries from one scratch copy: stage 3 `9f4d3823`, stage 4 `af634d7a`. Engine layer with the short index prepared, `数据库` searched untimed before each run, 15 samples after 3 warm-ups. Means of run medians, ms.

| Workload (ms) | A/A, 3 interleaved pairs | Stage 3, 5 ABBA pairs | Stage 4, 5 ABBA pairs |
| --- | --- | --- | --- |
| Refine `co config`, relevance | 33.95 / 34.06 | 33.64 | 20.74 |
| Refine `co config`, recent | 33.38 / 33.51 | 33.56 | 31.37 |
| Refine `a function`, relevance | 36.75 / 36.57 | 36.53 | 26.54 |
| Refine `a function`, recent | 48.12 / 47.95 | 48.68 | 46.41 |
| Refine `数据 select`, relevance | 72.64 / 72.64 | 73.00 | 68.65 |
| Refine `数据 select`, recent | 171.04 / 170.69 | 172.42 | 170.20 |
| Refine `a the`, relevance | 26.46 / 26.43 | 26.62 | 21.64 |
| Refine `a the`, recent | 12.99 / 12.98 | 13.10 | 12.84 |
| Typing `config`, recent (FTS, control) | 13.94 / 13.86 | 14.05 | 13.89 |
| Service `cmd` (control) | 11.87 / 11.96 | 11.91 | 12.02 |
| Prepared `cm` (control) | 7.94 / 7.91 | 7.84 | 7.98 |

- Recent-sorted refines gain less. They already stop early, and match evidence dominates them (for example, 77 of 88 ms for `select`).
- **Gates:**
  - `make build` passed; `make test-unit`: 755 passed, 0 failed.
  - `make test-snapshot-perf-release` on the stage-4 clone passed three times: `cmd` p95 12.61 / 12.35 / 16.62 ms (limit 50); prepared `cm` p95 8.76 / 8.25 / 8.30 ms (limit 20); cold `cm` 138.6 (first run after the build) / 65.1 / 65.2 ms.
- **Pre-existing, not changed here:** the full index's character filter requires a literal ";" or "`" in the text. So a row that matches a fuzzy+ word only through U+037E or U+1FEF is missed whenever it has no literal ";" or "`" elsewhere, and the SQL paths miss it too.

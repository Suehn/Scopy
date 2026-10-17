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

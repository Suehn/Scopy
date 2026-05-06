---
doc_type: runbook
status: active
owner: maintainers
last_reviewed: 2026-05-07
canonical: true
related_versions:
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

## Build Injection

- `CFBundleShortVersionString = $(MARKETING_VERSION)`
- `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`
- `scripts/version.sh` remains the build-time source for `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- For post-release commits after the tagged release commit, version injection should inherit the nearest reachable release tag. Do not infer the current release from highest version-sort order, because historical tags such as `v0.64` can sort after newer chronological releases such as `v0.7.1`.
- Release packaging must use `scripts/version.sh --tag` as the single resolver for both injected version settings and the DMG filename; if they disagree, stop packaging.

## Release Steps

1. Update [../meta/release-current.yml](../meta/release-current.yml), the new release note under [../releases/history/](../releases/history/README.md), [../releases/README.md](../releases/README.md), and [../releases/CHANGELOG.md](../releases/CHANGELOG.md).
2. Add or explicitly skip a release profile in [../perf/release-profiles/](../perf/release-profiles/README.md), and keep `profile_doc` in metadata aligned with that choice.
3. Run `make docs-validate`.
4. Run `make release-validate`.
5. Create the tag with `make tag-release`.
6. Push `main` and the tag with `make push-release`.
7. Wait for the `Build and Release` workflow to publish `Scopy-<version>.dmg` and `.sha256`.
8. Verify Homebrew sync and installation.

## Release Environment

- Release CI currently targets `macos-15`.
- Hosted TSan CI also targets `macos-15` with Xcode 16.0 via [../../.github/workflows/tsan.yml](../../.github/workflows/tsan.yml).
- Project baseline remains `macOS 14.0` and `Xcode 16.0` unless intentionally changed in project configuration and workflows.

## Verification Expectations

- Baseline build/tests: `make build`, `make test-unit`
- Concurrency-sensitive changes: `make test-strict`, and `make test-tsan` when the environment permits; on the known-bad `macOS 26.x + Xcode 26.2 (17C52)` combo the command skips because Apple hosted TSan crashes before test bootstrap, while the supported real-coverage path runs in Hosted TSan CI on `macos-15`
- Perf-sensitive changes:
  - `make test-snapshot-perf-release`
  - `make perf-search-warm-load`
  - `make perf-frontend-profile-standard` before commit, or `make perf-frontend-profile-full` before release
  - `make perf-unified-table` when comparing frontend and backend evidence, including `warm-load-summary.json` from `perf-search-warm-load` / `perf-audit`

## Current Performance Evidence

The `v0.7.6` release used the real snapshot DB at `perf-db/clipboard.db` (6421 items / 148647936 bytes) on 2026-05-07.

- `make perf-frontend-profile`: generated `logs/perf-frontend-profile-2026-05-07_03-18-32/frontend-scroll-profile-summary.md` after isolating Scopy app processes before the script, between variants, and on exit.
- `make perf-frontend-profile-standard`: generated `logs/perf-frontend-profile-2026-05-07_03-22-16/frontend-scroll-profile-summary.md` with 1 repeat, 6 seconds per scenario, and a 120-sample minimum.
- Standard profile row display-model p95 stayed effectively flat across real snapshot scenarios: real-snapshot-accessibility -0.19%, real-snapshot-mixed -1.06%, and real-snapshot-text-bias +2.65%.
- Standard profile thumbnail total-load p95 improved in the same scenarios: real-snapshot-accessibility -36.92%, real-snapshot-mixed -32.32%, and real-snapshot-text-bias -91.55%.
- The `v0.7.6` evidence is frontend-focused; `make test-snapshot-perf-release` and backend perf audit were not rerun because the release did not intentionally change search, storage, or warm-load behavior.

Treat the frontend profile as row/thumbnail regression guardrail evidence, not a blanket UI performance win. The script's `baseline` and `current` variants are feature-flag variants inside the same build, and short-run frame/drop counters remain noisy.

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

## Historical Material

- Legacy deployment notes are preserved in [../archive/release-runbook-legacy.md](../archive/release-runbook-legacy.md).
- Older changelog entries live under [../archive/changelog/](../archive/changelog/README.md).

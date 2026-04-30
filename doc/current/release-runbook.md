---
doc_type: runbook
status: active
owner: maintainers
last_reviewed: 2026-04-30
canonical: true
related_versions:
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

The `v0.7.5` release used the real snapshot DB at `perf-db/clipboard.db`（6421 items / 148647936 bytes）on 2026-04-30.

- `make test-snapshot-perf-release`: cmd p95 0.289ms <= 50ms; cm p95 9.187ms <= 20ms.
- `bash scripts/perf-audit.sh --skip-tests --bench-db perf-db/clipboard.db --bench-metrics --out logs/perf-audit-perf-opt-2026-04-30_23-19-00`: full fuzzy `abc` p95 improved from 5.672ms to 0.490ms, and full fuzzy `cmd` p95 improved from 6.630ms to 0.884ms versus `logs/perf-audit-v0.7.4-current-2026-04-30_20-19-15`.
- The same audit recorded `fuzzy_sorted_matches_cache_store_count=2051` in warm-load metrics, confirming the bounded first-page top-K cache path was exercised.
- `make perf-frontend-profile-standard`: generated `logs/perf-frontend-profile-2026-04-30_23-26-29/frontend-scroll-profile-summary.md`.
- `make perf-unified-table`: generated `logs/perf-unified-2026-04-30_23-29-33.md` from the `v0.7.4` backend baseline, current backend audit, and the standard frontend summary.

Treat the frontend profile as a real-scroll regression smoke, not a clean pre-change/post-change frontend A/B. The script's `baseline` and `current` variants are feature-flag variants inside the same build, while the backend comparison above uses separate audit directories.

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

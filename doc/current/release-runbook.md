---
doc_type: runbook
status: active
owner: maintainers
last_reviewed: 2026-05-08
canonical: true
related_versions:
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

The current release `v0.7.8` does not add a dedicated release profile. Its release evidence lives in the release note because the changes are explicit UI/service action fixes and pagination behavior corrections rather than a broad performance tuning pass.

- `make build`, `make test-unit`, and `make test-strict` passed on 2026-05-08 for the history action and pinned-pagination release.
- Focused UI tests passed for storage-backed image AirDrop/Open Folder, inline-image AirDrop without Open Folder, and file AirDrop/Open Folder context menu visibility on 2026-05-08.
- Focused unit coverage passed for inline image `fileURLs(itemID:)` temporary PNG generation on 2026-05-08.
- The latest dedicated profile remains [v0.7.6](../perf/release-profiles/v0.7.6-profile.md), which used the real snapshot DB at `perf-db/clipboard.db` (6421 items / 148647936 bytes) for row descriptor and thumbnail scheduler evidence.

Do not treat `v0.7.8` as a blanket frontend performance release. Use the v0.7.6 profile for row/thumbnail scheduler regression context and the v0.7.8 release note for file-action and pagination evidence.

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
- If `raw.githubusercontent.com` still shows an old cask right after a push, verify with GitHub API, git refs, a local tap checkout, or `brew info --cask --json=v2 scopy`; raw CDN lag is not authoritative by itself.
- If `brew fetch --cask scopy -f` fails with `LibreSSL SSL_connect` / `SSL_ERROR_SYSCALL` against `release-assets.githubusercontent.com`, separate local TLS transport failure from cask version or sha drift and rerun install checks when the transport path recovers.
- Local `make test-tsan` can skip on the known-bad `macOS 26.x + Xcode 26.2 (17C52)` runtime; Hosted TSan on `macos-15 + Xcode 16.0` remains the release concurrency coverage path.

## Historical Material

- Legacy deployment notes are preserved in [../archive/release-runbook-legacy.md](../archive/release-runbook-legacy.md).
- Older changelog entries live under [../archive/changelog/](../archive/changelog/README.md).

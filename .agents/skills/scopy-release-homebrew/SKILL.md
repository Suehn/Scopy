---
name: scopy-release-homebrew
description: "Run the Scopy tag-driven release flow through docs validation, commit/tag/push, GitHub release assets, Homebrew cask parity, and installation verification. Use for Scopy release cutovers or release readiness checks."
---

# Scopy Release And Homebrew Verification

Use this skill for Scopy release cutovers. The goal is not just a tag: release closure means the GitHub DMG and sha exist, both Homebrew cask surfaces point at the released version and sha, and Homebrew can install the app into `/Applications`.

## Guardrails

- Start with a read-only inventory: `git status --short`, `git log --oneline --decorate --max-count=20`, `git tag --list 'v*' --sort=v:refname | tail`, and `sed -n '1,80p' doc/meta/release-current.yml`.
- Do not overwrite an existing release tag or replace assets under an existing tag. Bump the version for a repair release.
- Keep `doc/meta/release-current.yml`, `doc/releases/README.md`, `doc/releases/CHANGELOG.md`, and `doc/releases/history/vX.Y.Z.md` together.
- If there is no dedicated release profile, set `profile_doc: null` and make the release index current block say `Profile doc: none`.
- Local `make test-tsan` may skip on the known-bad `macOS 26.x + Xcode 26.2 (17C52)` runtime. Treat Hosted TSan on `macos-15 + Xcode 16.0` as the release concurrency coverage path.

## Documentation And Local Gates

Run these before commit/tag work:

```bash
make docs-validate
make release-validate
```

For code-bearing releases, also run the relevant quality gates from `AGENTS.md` and `doc/current/release-runbook.md`, normally:

```bash
make build
make test-unit
make test-strict
```

Add performance gates by risk:

```bash
make test-snapshot-perf-release
make perf-frontend-profile-standard
bash scripts/perf-frontend-profile.sh --include-hover
make perf-unified-table BACKEND_BASELINE=<path> BACKEND_CURRENT=<path> FRONTEND_SUMMARY=<path>
```

Use `make quality-manifest-self-test` when changing quality evidence tooling.

## Commit, Tag, And Push

Commit the release docs and any skill/tooling updates first. Commit messages must include:

```text
Co-authored-by: Codex <noreply@openai.com>
```

Then create and push the tag from metadata:

```bash
make tag-release
make push-release
```

If `make push-release` fails over SSH because the local proxy closes the connection, switch the remote to HTTPS or push over HTTPS with HTTP/1.1:

```bash
git config http.version HTTP/1.1
git push origin main
git push origin "$(bash scripts/release/tag-from-doc.sh --tag)"
```

## GitHub Release Assets

Wait for the `Build and Release` workflow for the tag. Verify that the release has both files:

- `Scopy-<version>.dmg`
- `Scopy-<version>.dmg.sha256`

Record the sha from the `.sha256` asset and use it for cask parity. Do not treat a green workflow alone as release closure; cask update jobs can drift or skip.

## Cask Parity

Verify the repository cask and external tap cask both point at the target version and sha:

```bash
curl -fsSL https://raw.githubusercontent.com/Suehn/Scopy/main/Casks/scopy.rb | sed -n '1,12p'
curl -fsSL https://raw.githubusercontent.com/Suehn/homebrew-scopy/main/Casks/scopy.rb | sed -n '1,12p'
```

If raw URLs still show stale content right after a push, verify with GitHub API, git refs, a local tap checkout, or `brew info --cask --json=v2 scopy`. Raw CDN lag is not authoritative by itself.

If `HOMEBREW_GITHUB_API_TOKEN` is absent or the workflow skipped the external tap update, manually update `Suehn/homebrew-scopy` so `Casks/scopy.rb` matches the repo cask version and sha, then push that tap commit.

## Homebrew Install Acceptance

Final acceptance uses Homebrew, not only file inspection:

```bash
brew tap Suehn/scopy
brew update
brew info --cask --json=v2 scopy
brew fetch --cask scopy -f
brew reinstall --cask scopy --force --appdir=/Applications
defaults read /Applications/Scopy.app/Contents/Info CFBundleShortVersionString
defaults read /Applications/Scopy.app/Contents/Info CFBundleVersion
```

`brew info --cask --json=v2 scopy` is the strongest single state check because it exposes cask version, installed version, `tap_git_head`, bundle version, and outdated state.

If `brew fetch --cask scopy -f` fails with `LibreSSL SSL_connect` / `SSL_ERROR_SYSCALL` against `release-assets.githubusercontent.com`, separate local TLS transport failure from cask drift or sha mismatch. Re-run install checks after the transport path recovers.

## Completion Report

Report:

- release version and tag;
- commit hash and tag hash;
- docs and release gates run;
- GitHub asset names and sha256;
- repo cask version/sha;
- external tap cask version/sha;
- Homebrew install result and `/Applications/Scopy.app` bundle versions;
- any environment-specific skips, especially local TSan or local TLS download failure.

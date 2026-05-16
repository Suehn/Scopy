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
- Do not cite a pre-tag `make release` run as target-version release evidence. `make release` uses `scripts/version.sh`, which is tag-driven and resolves the nearest reachable tag before the new tag exists. For target-version release evidence, create the metadata tag first, then verify `bash scripts/version.sh --xcodebuild-args` prints the target `MARKETING_VERSION`, or use the GitHub tag workflow assets.
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

After `make tag-release` and before trusting any local release build, verify the tag-driven version resolver has moved to the target version:

```bash
bash scripts/release/tag-from-doc.sh --tag
bash scripts/version.sh --xcodebuild-args
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

After `Build and Release` succeeds, fetch/pull `main` again because the workflow can push a follow-up repository cask commit such as `chore: bump cask to <version>`:

```bash
git fetch origin main
git log --oneline --decorate --max-count=5 origin/main
git pull --ff-only --no-tags origin main
```

If `git fetch origin main --tags` reports `would clobber existing tag`, do not debug release state through tags. Fetch or pull `main` without tags and verify the new release tag separately.

## Cask Parity

Verify the repository cask and external tap cask both point at the target version and sha:

```bash
curl -fsSL https://raw.githubusercontent.com/Suehn/Scopy/main/Casks/scopy.rb | sed -n '1,12p'
curl -fsSL https://raw.githubusercontent.com/Suehn/homebrew-scopy/main/Casks/scopy.rb | sed -n '1,12p'
```

Also verify refs and local cask contents. This catches the common pitfall where the Scopy repository cask is updated but the external Homebrew tap is still stale:

```bash
git show origin/main:Casks/scopy.rb | sed -n '1,12p'
git ls-remote git@github.com:Suehn/homebrew-scopy.git refs/heads/main
brew tap-info Suehn/scopy
brew cat Suehn/scopy/scopy | sed -n '1,16p'
```

If raw URLs still show stale content right after a push, verify with GitHub refs, a local tap checkout, or `brew info --cask --json=v2 Suehn/scopy/scopy`. Raw CDN lag is not authoritative by itself.

Known v0.8.0 pitfall: `Build and Release` successfully updated `Suehn/Scopy/Casks/scopy.rb`, but `Suehn/homebrew-scopy` stayed at `0.7.9` because the external tap update path can skip when `HOMEBREW_GITHUB_API_TOKEN` is absent or invalid. Treat "repo cask is correct" as insufficient until the external tap and Homebrew parser both show the same target version and sha.

If `HOMEBREW_GITHUB_API_TOKEN` is absent or the workflow skipped the external tap update, manually update `Suehn/homebrew-scopy` so `Casks/scopy.rb` matches the repo cask version and sha, then push that tap commit:

```bash
VERSION="<version without leading v, for example 0.8.0>"
SHA256="<sha from Scopy-${VERSION}.dmg.sha256>"
TAP_DIR="/tmp/scopy-homebrew-tap-update"

rm -rf "${TAP_DIR}"
git clone git@github.com:Suehn/homebrew-scopy.git "${TAP_DIR}"

cd "${TAP_DIR}"
perl -0pi -e 's/version "[^"]+"/version "'"${VERSION}"'"/; s/sha256 "[^"]+"/sha256 "'"${SHA256}"'"/' Casks/scopy.rb
git diff --check
git diff -- Casks/scopy.rb
git add Casks/scopy.rb
git commit -m "scopy ${VERSION}" -m "Co-authored-by: Codex <noreply@openai.com>"
git push origin HEAD:main
```

After manual tap push, verify the external tap by ref and by Homebrew, not just by the pushed commit:

```bash
git ls-remote git@github.com:Suehn/homebrew-scopy.git refs/heads/main
brew update
brew tap-info Suehn/scopy
brew cat Suehn/scopy/scopy | sed -n '1,16p'
```

## Homebrew Install Acceptance

Final acceptance uses Homebrew, not only file inspection:

```bash
brew tap Suehn/scopy
brew update
brew info --cask --json=v2 Suehn/scopy/scopy
brew fetch --cask Suehn/scopy/scopy -f
brew reinstall --cask Suehn/scopy/scopy --force --appdir=/Applications
defaults read /Applications/Scopy.app/Contents/Info CFBundleShortVersionString
defaults read /Applications/Scopy.app/Contents/Info CFBundleVersion
```

Use the fully qualified cask token `Suehn/scopy/scopy` for acceptance. It prevents Homebrew from resolving a stale cask from another tap or cache. `brew info --cask --json=v2 Suehn/scopy/scopy` is the strongest single state check because it exposes cask version, installed version, `tap_git_head`, bundle version, and outdated state.

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

# release: docs tag homebrew and release skill

## Goal

Update Scopy release-facing documentation according to the repository requirements, cut a new release through commit/tag/push, verify the release is installable via Homebrew, and capture the validated release workflow as a reusable local skill so future releases avoid known failure modes.

## What I already know

* User explicitly requested docs update, release, tag, Homebrew installability, and a skill documenting the flow.
* Repository release instructions require release metadata, version docs/index/CHANGELOG, release validation, tag-driven GitHub release, cask parity, and Homebrew install verification.
* Prior Scopy release memory says external tap drift, raw CDN lag, and local network/TLS download failures are common pitfalls.

## Assumptions

* This task should release the next patch version after the current release metadata unless repo state shows a different intended version.
* The workflow skill should live in the project-local shared skill layer under .agents/skills/ because the requested flow is Scopy-specific.
* Existing uncommitted user changes, if any appear later, must not be reverted.

## Requirements

* Inspect current git/release state before editing.
* Update release docs and metadata to a coherent new version.
* Run the repository's required release validation gates as far as the local environment permits.
* Commit release docs/skill changes with the required Codex co-author trailer.
* Create and push the release tag.
* Verify GitHub release assets and Homebrew cask parity.
* Verify brew can install or upgrade Scopy to the released version in /Applications.
* Add a reusable skill documenting the validated Scopy release process, including known pitfalls and verification commands.

## Acceptance Criteria

* [ ] Release metadata, release history, index, CHANGELOG, and any needed current docs are updated and validate.
* [ ] Required build/test/release gates pass or any environment-specific skip is explicitly justified.
* [ ] Release commit exists on main and includes Co-authored-by: Codex <noreply@openai.com>.
* [ ] Release tag is pushed and GitHub release assets include DMG and SHA256 for the target version.
* [ ] Repo cask and external tap cask both point at the target version and SHA.
* [ ] brew installs Scopy to /Applications/Scopy.app, and installed Info.plist version matches target release.
* [ ] Project-local release skill exists and documents the verified process.

## Out of Scope

* Feature development unrelated to release preparation.
* Releasing by overwriting an existing tag's assets.
* Broad Trellis workflow changes beyond adding the requested skill.

## Technical Notes

* Memory group: scopy-release-cutovers-docs-and-homebrew-cask-sync.
* Known minimum commands: make docs-validate, make release-validate, make tag-release, make push-release, brew info --cask --json=v2 scopy, brew fetch --cask scopy -f, brew reinstall --cask scopy --force --appdir=/Applications.

---
name: scopy-release-homebrew
description: "Prepare, publish, or verify Scopy releases across tags, GitHub DMGs, both Homebrew casks, and the installed app. Use for 发版, 发布准备, or release/install verification; ordinary code or documentation cleanup does not trigger publication."
---

# Scopy Release

Read `doc/meta/release-current.yml` and `doc/current/release-runbook.md` in the target checkout. The runbook owns commands, gates, packaging, and Homebrew acceptance; do not maintain a second procedure here.

First inspect Git status, HEAD, release metadata, and the requested mode/version. Resolve omitted version details from current release state and the verified change scope; ask only if the choice materially changes the release. For readiness, inspect and validate within that scope. For an authorized release, continue through publication and installation using the runbook and a coherent verified commit; existing session authorization is sufficient. Preserve unrelated work. General cleanup is not release authorization, and `deploy.sh --no-launch` still replaces the installed app.

Keep these decision points explicit:

- A pre-tag Release build resolves the nearest reachable tag. It does not verify the intended new version. After tagging, check `scripts/version.sh --xcodebuild-args` and the actual packaged bundle.
- Never move an existing release tag or replace its assets. Repair a published release with a new monotonic version.
- A green GitHub workflow is insufficient: external tap synchronization can skip. Compare the DMG checksum with both `Suehn/Scopy` and `Suehn/homebrew-scopy` casks, then verify the fully qualified `Suehn/scopy/scopy` Homebrew installation and `/Applications/Scopy.app` bundle.
- Distinguish failed gates, environment-blocked checks, and unattempted checks. Stop publication if required evidence or artifact identity does not reconcile; investigate the actual failure instead of applying a historical network/tap reset recipe.

Report the target tag/commit, gates and skips, asset checksum, both cask states, and installed bundle versions. For readiness-only work, report remaining gates without claiming publication or installation.

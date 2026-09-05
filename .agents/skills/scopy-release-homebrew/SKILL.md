---
name: scopy-release-homebrew
description: "Prepare or verify a Scopy release through Git tags, GitHub DMG assets, Homebrew cask parity, and installed bundle verification. Use for release cutovers or readiness checks."
---

# Scopy Release

Read `doc/meta/release-current.yml` and `doc/current/release-runbook.md` in the target checkout. The runbook owns commands, gates, packaging, and Homebrew acceptance; do not maintain a second procedure here.

First inspect Git status, HEAD, and the requested target version. For readiness, inspect state and run relevant validation; tagging, pushing, or reinstalling requires that scope in the user request. An authorized release proceeds through the runbook using a coherent verified commit; preserve unrelated work and do not infer release authorization from a general cleanup request.

Keep these decision points explicit:

- A pre-tag Release build resolves the nearest reachable tag. It does not verify the intended new version. After tagging, check `scripts/version.sh --xcodebuild-args` and the actual packaged bundle.
- Never move an existing release tag or replace its assets. Repair a published release with a new monotonic version.
- A green GitHub workflow is insufficient: external tap synchronization can skip. Compare the DMG checksum with both `Suehn/Scopy` and `Suehn/homebrew-scopy` casks, then verify the fully qualified `Suehn/scopy/scopy` Homebrew installation and `/Applications/Scopy.app` bundle.
- Distinguish failed gates, environment-blocked checks, and unattempted checks. Stop publication if required evidence or artifact identity does not reconcile; investigate the actual failure instead of applying a historical network/tap reset recipe.

Report the target tag/commit, gates and skips, asset checksum, both cask states, and installed bundle versions. For readiness-only work, report remaining gates without claiming publication or installation.

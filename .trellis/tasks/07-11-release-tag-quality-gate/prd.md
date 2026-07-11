# Release Tag Quality Gate

## Goal

Eliminate the push-triggered path that can create a release tag before Scopy's required build, unit, strict-concurrency, documentation, and release checks are complete. Preserve the documented explicit tag-driven release flow, make the authority for tag creation singular and auditable, and prevent a renamed workflow from silently reintroducing automatic tag creation.

## What I Already Know

- `.github/workflows/auto-tag.yml` runs on selected pushes to `main`, has `contents: write`, validates only release-document shape, then creates and pushes the metadata-derived tag.
- `.github/workflows/ci.yml` runs build, unit, and strict-concurrency as independent jobs on the same push. The auto-tag workflow has no dependency on their results.
- `.github/workflows/release.yml` is correctly downstream of a `v*` tag or explicit `workflow_dispatch`; it builds/publishes assets and updates casks but does not establish that the tag was quality-gated.
- `scripts/release/push-main.sh` already provides an explicit maintainer path: ensure the metadata tag locally, push `main`, then push that tag.
- `doc/current/release-runbook.md`, `AGENTS.md`, and the Makefile already describe `make release-validate` -> `make tag-release` -> `make push-release` as the canonical release sequence.
- Current GitHub documentation says events caused by the repository `GITHUB_TOKEN` do not normally start another workflow run except dispatch events. Depending on a workflow-created tag to recursively start `Build and Release` is therefore not a stable contract.
- Public workflow history contains 78 auto-tag runs and shows auto-tag and tag-triggered release runs near the same commits. The explicit `push-main.sh` pushes `main` and the tag separately, so the two tag paths can race or redundantly act on the same release candidate.
- The remote currently has `v0.8.8`; `v0.65.0` does not yet exist. This task must not create either a local or remote release tag.
- The current `.codex/config.toml` and `.trellis/tasks/07-11-markdown-preview-architecture/` changes are unrelated and must remain untouched.

## Requirements

1. Remove every workflow path that creates or pushes a Git tag from a `main` push.
2. Keep tag creation explicit through the existing metadata-driven `make tag-release` / `make push-release` maintainer flow.
3. Keep `Build and Release` triggered only by a deliberate `v*` tag push or explicit dispatch.
4. Add a dependency-free repository policy validator that rejects workflow-owned tag creation even if a future workflow is renamed.
5. Run the policy validator in ordinary CI so pull requests cannot silently reintroduce the unsafe path.
6. Keep build, unit, and strict-concurrency jobs unchanged; the new release-policy job must be lightweight and independent of Xcode.
7. Preserve release metadata, version resolution, DMG naming, cask update behavior, and Homebrew acceptance contracts.
8. Update current maintainer/release docs, release metadata, release note, changelog, and the historical audit closure status.
9. Add focused tests for safe tag-trigger workflows and unsafe direct/indirect tag-creation command forms.
10. Do not push, tag, dispatch workflows, publish a release, alter branch protection, or mutate Homebrew state.

## Acceptance Criteria

- [x] `.github/workflows/auto-tag.yml` is removed.
- [x] No workflow contains `tag-from-doc.sh`, `git tag`, `git push --tags`, `git push --follow-tags`, or a direct `refs/tags` creation command.
- [x] `.github/workflows/release.yml` still accepts only `push.tags: v*` and `workflow_dispatch` as release entrypoints.
- [x] A dependency-free validator scans all workflow files by content, not only the old filename, and exits nonzero for representative unsafe fixtures.
- [x] The validator accepts the real safe workflows and a synthetic tag-trigger-only release workflow.
- [x] CI has a lightweight release-policy job that runs `make docs-validate`, `make release-validate`, and the focused validator tests.
- [x] Existing build, unit, strict-concurrency, TSan, release packaging, version, and Homebrew workflow semantics are otherwise unchanged.
- [x] `make release-validate` includes the workflow policy and passes.
- [x] Focused validator tests, `make build`, `make test-unit`, `make test-strict`, `make docs-validate`, and `git diff --check` pass.
- [x] Current docs identify explicit maintainer tag creation as the only authority and explain why workflow-created tags are forbidden.
- [x] Changes are split into coherent local commits; no tag, push, dispatch, publication, or Homebrew mutation occurs.

## Definition Of Done

- A release-document push cannot itself create a tag, regardless of build/test status.
- A future workflow that attempts to create or push a tag fails the repository's release-policy gate before merge.
- The supported explicit release path remains metadata-driven and documented.
- Failure cases, rollback, tests, and official GitHub behavior are recorded in task and release documentation.

## Expansion Sweep

### Future Evolution

- A later task may replace explicit local tagging with a manual dispatch that validates a structured gate manifest and invokes release directly. This task should not pre-commit to cross-workflow orchestration.
- Branch protection may require the new release-policy CI job, but changing repository settings is an external administrative action and is not part of this local patch.

### Related Scenarios

- Post-release cask commits to `main` must never attempt to recreate or move an existing release tag.
- A metadata bump, release-note edit, or release-script edit should run CI validation but remain incapable of publishing by itself.

### Failure And Edge Cases

- Renaming `auto-tag.yml` must not evade the validator.
- A safe `on.push.tags` release trigger is not tag creation and must not be rejected.
- Comments and ordinary inputs mentioning a tag must not be confused with shell commands that create or push refs.
- A malformed or missing release document must still fail existing validation before an explicit tag is created.

## Feasible Approaches

### A. Remove automatic tag creation and enforce the policy (recommended)

- Delete `auto-tag.yml`, retain explicit Make/script release commands, add a workflow-policy validator and CI job.
- Lowest privilege and complexity; matches current runbook and supports conditional local performance/UI gates.
- Requires a deliberate maintainer tag push after gates, which is already the documented process.

### B. Move tag creation into the CI workflow with `needs`

- Add release validation and a tag job that depends on build/unit/strict jobs.
- Preserves automation but gives ordinary CI write permission and still cannot infer conditional TSan/UI/performance requirements safely.
- Path detection, multi-commit pushes, existing tags, and post-release cask commits add branching complexity.

### C. Orchestrate through `workflow_run` or manual dispatch

- A separate privileged workflow verifies a successful CI SHA, then creates a tag and explicitly dispatches release.
- Can centralize remote attestation but introduces API/token/commit-selection complexity and privileged cross-workflow trust boundaries.
- Better treated as a future enhancement only if explicit maintainer tagging becomes an operational bottleneck.

## Decision (ADR-lite, Accepted)

**Context**: The current automatic path is weaker than the documented release process, races with the explicit push script, and relies on cross-workflow trigger behavior that is not a stable `GITHUB_TOKEN` contract. Conditional performance and UI gates also cannot be inferred safely from a generic push-trigger job.

**Decision**: Prefer Approach A. Remove workflow-owned tag creation, enforce that invariant by scanning every workflow, and keep the existing explicit metadata-driven release command as the single tag authority.

**Consequences**: Release publication remains deliberate and auditable, ordinary CI loses unnecessary write permission, and rollback is a small workflow/policy revert. Automation convenience decreases only for an undocumented competing path. A future dispatch-based design remains possible without carrying this race forward.

## Out Of Scope

- Rewriting the tag-triggered `Build and Release` packaging/cask workflow.
- Changing project Swift, macOS, or Xcode baselines.
- Creating or deleting any local/remote tag.
- Pushing `main`, dispatching Actions, publishing GitHub Releases, or updating Homebrew.
- Editing GitHub branch protection, environments, secrets, or required-check settings.
- Building a generalized gate-attestation service.

## Technical Notes

- Primary files: `.github/workflows/auto-tag.yml`, `.github/workflows/ci.yml`, `scripts/release/validate-release-docs.sh`, a new release-policy validator/test, `Makefile`, and current release/maintainer docs.
- Existing explicit authority: `scripts/release/tag-from-doc.sh`, `scripts/release/push-main.sh`, `make tag-release`, and `make push-release`.
- Official GitHub source: `https://docs.github.com/en/actions/concepts/security/github_token`.
- Official dependency source: `https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds`.

## Research References

- [`research/release-tag-gating.md`](research/release-tag-gating.md) — bounded research on current workflow evidence, official GitHub contracts, remote history, alternatives, and recommendation.
- [`verification.md`](verification.md) — final gates, unchanged boundaries, commits, rollback, and non-mutation evidence.

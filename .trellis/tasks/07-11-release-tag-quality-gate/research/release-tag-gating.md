# Release Tag Gating Research

## Conclusion

Remove `.github/workflows/auto-tag.yml`, keep the explicit metadata-driven `make tag-release` / `make push-release` path, and add a dependency-free workflow policy validator that runs in ordinary CI. This closes the confirmed automatic bypass with the smallest privilege and rollback surface while preserving the documented release mechanism.

## Current Flow Evidence

### Automatic path

- `.github/workflows/auto-tag.yml:3-13` runs on a `main` push that changes release, docs, profile, or release-script paths.
- `.github/workflows/auto-tag.yml:15-19` gives its only job `contents: write`.
- `.github/workflows/auto-tag.yml:27-28` runs only `validate-release-docs.sh`; it does not build or run unit/strict tests.
- `.github/workflows/auto-tag.yml:30-53` derives, creates, and pushes the metadata tag immediately.

### Quality path

- `.github/workflows/ci.yml:3-12` starts a separate workflow on the same `main` push.
- `.github/workflows/ci.yml:14-78` defines build, unit, and strict-concurrency as parallel jobs. No job or cross-workflow dependency connects them to `auto-tag.yml`.
- GitHub documents that jobs run in parallel by default and that `jobs.<job_id>.needs` is the mechanism that requires successful prerequisites: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds.

### Release path

- `.github/workflows/release.yml:3-12` starts only from a `v*` tag push or explicit `workflow_dispatch`.
- `scripts/release/push-main.sh:7-14` already owns the explicit local path: ensure the metadata tag, push `main`, then push the tag.
- `Makefile:404-416` exposes the explicit tag, push, and release-validation targets.
- `doc/current/release-runbook.md:46-55` requires docs validation, release validation, tag creation, tag/main push, asset publication, and Homebrew verification in that order.

The automatic path is therefore a second tag authority with weaker gates than the canonical maintainer path.

## GitHub Token Contract

GitHub's current documentation states that events caused by the repository `GITHUB_TOKEN` do not create another workflow run, except `workflow_dispatch` and `repository_dispatch`. It explicitly gives a workflow-authenticated push as an event that will not start another push workflow:

- https://docs.github.com/en/actions/concepts/security/github_token#when-github_token-triggers-workflow-runs

`auto-tag.yml` does not provide a GitHub App or personal access token to checkout/push and does not dispatch `release.yml` explicitly. A workflow-created tag is therefore not a supported recursive trigger contract for `Build and Release`.

Public API evidence must be interpreted carefully. The repository reports 78 historical auto-tag runs, and several tag-triggered release runs begin near the same commit/time. But `push-main.sh` pushes `main` and the tag separately; the branch push can start auto-tag while the explicit tag push independently starts release. Those paired runs do not prove that an Actions-token tag push recursively triggered release. They do prove two tag-capable paths can race or redundantly inspect the same candidate.

Example June 15 sequence:

- Auto Tag run `27524178183`, `main`, SHA `fdc047d...`, started `2026-06-15T04:32:16Z`.
- Build and Release run `27524179898`, tag `v0.8.8`, same SHA, started `2026-06-15T04:32:19Z`.
- The explicit script pushes `main` before the tag, which explains the overlapping workflows without relying on recursion.

## Confirmed Failure Modes

| Scenario | Current result | Required result |
| --- | --- | --- |
| Release-doc push while build fails | Auto-tag can create/push a tag because it has no build dependency | No automatic tag can exist |
| Unit or strict-concurrency failure | Independent CI failure cannot stop auto-tag | No automatic tag can exist |
| `docs-validate` failure outside the narrow release script | Auto-tag runs only the narrow release-doc validator | No automatic tag can exist |
| Conditional TSan/UI/performance evidence missing | Generic auto-tag cannot infer task-specific gates | Maintainer completes contextual gates before explicit tag |
| Main and tag pushed by `push-main.sh` | Auto-tag and explicit release path start concurrently | One explicit tag authority |
| Workflow-created tag authenticated by `GITHUB_TOKEN` | Recursive release trigger is not a documented contract | Release starts from deliberate tag push or explicit dispatch |
| Post-release docs/cask commit | Auto-tag starts and then skips because existing tag points elsewhere | CI validates only; no tag-capable job runs |
| Unsafe workflow renamed | Filename-only deletion check can miss it | Content-based policy rejects workflow tag commands |

## Approach Comparison

### A. Delete automatic tag creation and enforce the invariant — recommended

Implementation:

- Delete `.github/workflows/auto-tag.yml`.
- Keep `tag-from-doc.sh`, `push-main.sh`, `make tag-release`, and `make push-release` unchanged.
- Add a dependency-free validator that scans every workflow for commands that create or push tags.
- Add a lightweight CI job for docs validation, release validation, and validator tests.

Advantages:

- Removes the bypass rather than trying to synchronize it.
- Removes `contents: write` from ordinary branch-push automation.
- Matches the existing runbook and supports conditional performance/UI gates that depend on change scope.
- Small, reviewable rollback: restore the workflow and remove the policy guard.

Trade-off:

- A maintainer must deliberately run the already-documented release command.

### B. Put a tag job inside `ci.yml` with `needs`

Implementation:

- Add release validation and path detection jobs.
- Give a final tag job `needs: [build, unit_tests, strict_concurrency, release_validation]` plus write permission.

Advantages:

- GitHub `needs` correctly blocks the job on failed prerequisites.
- Keeps automatic tag creation after the fixed CI set.

Risks:

- Gives general CI a privileged write job.
- Multi-commit path detection, post-release cask commits, existing tags, retries, and force-updated branches require more state logic.
- Fixed CI still cannot prove conditional TSan, UI smoke, or performance requirements.
- Larger rollback and more opportunities for a job-level `if`/skip mistake.

### C. `workflow_run` or manual dispatch orchestration

Implementation:

- A privileged workflow receives a successful CI SHA, verifies checks, creates the tag, then explicitly dispatches release.

Advantages:

- Can make remote CI attestation and commit identity explicit.
- Avoids relying on recursive `GITHUB_TOKEN` push events if release is dispatched directly.

Risks:

- Introduces API calls, token/permission design, SHA selection, stale-run/retry handling, and cross-workflow trust boundaries.
- `workflow_run` workflows are privileged and need careful untrusted-code handling.
- Disproportionate complexity while the existing explicit release command is already canonical.

## Validator Boundary

The validator should inspect workflow contents, not only filenames. It should reject shell/API command forms that create or push tags, including:

- `tag-from-doc.sh` from any workflow;
- `git tag`;
- `git push --tags` or `git push --follow-tags`;
- `git push` whose ref/argument is a tag variable or `refs/tags/...`;
- API creation under `git/refs` with a `refs/tags/...` ref.

It must allow:

- `on.push.tags: ["v*"]` in the tag-triggered release workflow;
- tag inputs, version parsing, release API lookup, and release naming;
- `git push origin HEAD:main` for post-release cask synchronization.

Focused tests should run the validator against temporary safe/unsafe workflow directories. This proves semantics without creating a local or remote tag.

## Verification Plan

1. Baseline policy test fails against the current `auto-tag.yml`.
2. Remove auto-tag and add the validator plus fixtures/unit tests.
3. Add a lightweight CI release-policy job with no write permission.
4. Confirm current workflows pass the content policy.
5. Confirm representative renamed unsafe workflows fail.
6. Run `make docs-validate`, `make release-validate`, focused policy tests, `make build`, `make test-unit`, `make test-strict`, and `git diff --check`.
7. Do not run `make tag-release`, `make push-release`, workflow dispatch, or any publication command.

## Recommendation

Choose Approach A. It has the highest risk reduction per line changed, aligns with the repository's current operating contract, eliminates ordinary-workflow write privilege, covers future renamed regressions, and leaves a dispatch-based design available if deliberate release operation later becomes a measured bottleneck.

# Release Tag Quality Gate Verification

Date: 2026-07-11

## Outcome

The push-triggered tag authority is removed. Ordinary CI and Hosted TSan are top-level read-only, `Build and Release` still consumes only an existing `v*` tag or explicit dispatch, and the supported tag-creation path is the deliberate metadata-driven maintainer flow.

## Baseline Failure Closed

| Baseline condition | Former behavior | Verified result |
|---|---|---|
| Release/docs push while build, unit, or strict fails | Independent `auto-tag.yml` could create/push the tag after only narrow release-doc validation | No push-triggered tag-capable workflow exists |
| Ordinary workflow inherits repository write defaults | A future job/action could regain ref mutation authority without an explicit permission block | Every non-release workflow must declare top-level read-only permissions |
| Unsafe workflow is renamed | Deleting only `auto-tag.yml` would not prevent recurrence | Content-based scan covers every `.yml` and `.yaml` workflow |
| Workflow-owned tag push uses `GITHUB_TOKEN` | Downstream release trigger depended on unsupported recursive workflow behavior | Release starts from a deliberate existing tag or explicit dispatch |
| Post-release cask branch update | Broad push rejection could break the existing release workflow | Exact `git push origin HEAD:main` remains the sole allowlisted branch push |

## Coherent Commits

| Commit | Scope |
|---|---|
| `5cb8c95` | Task plan, failure evidence, alternatives, and accepted design |
| `2f15994` | Remove auto-tag; add CI policy job, validator, Make target, and focused tests |
| `9f8304e` | Lock ordinary workflows to top-level read-only permissions and test the invariant |
| `83632d9` | Add the seven-section executable release-tag-authority specification |
| `fe494ac` | Update current/release docs, metadata, release note, changelog, and audit closure |

## Verification Evidence

| Check | Result |
|---|---|
| `make test-release-policy` | 14 tests, 0 failures |
| Direct workflow policy | `Release workflow tag policy OK: 3 workflow(s)` |
| YAML parse | `ci.yml`, `release.yml`, and `tsan.yml` passed Ruby standard-library parsing |
| Python syntax | Validator and tests passed `python3 -m py_compile` |
| `make build` | Passed |
| `make test-unit` | 706 executed, 1 skipped, 0 failures; `TEST SUCCEEDED` |
| `make test-strict` | 706 executed, 1 skipped, 0 failures; `TEST SUCCEEDED` |
| `make docs-validate` | `Docs OK: v0.65.0` |
| `make release-validate` | Workflow policy passed; `OK: v0.65.0` |
| `git diff --check` | Passed |
| Release/package boundary | `tag-from-doc.sh`, `push-main.sh`, `release.yml`, `project.yml`, `build-release.sh`, and `Casks/scopy.rb` unchanged from task baseline |
| Local tag check | `git tag --list v0.65.0` returned empty |
| Remote tag check | `git ls-remote --tags origin refs/tags/v0.65.0` returned empty |

The workflow-policy tests intentionally use temporary workflow fixtures and never invoke a tag, push, workflow dispatch, release publication, or Homebrew mutation.

## Scope-Aware Gate Notes

- TSan was not rerun for this tooling-only slice. No Swift, actor, thread, Xcode project, or test-target source changed; the release's immediately preceding TSan evidence remains 686 executed, 1 skipped, 0 failures.
- Snapshot/backend and frontend performance profiles were not rerun because no product runtime or algorithm changed. No performance improvement is claimed.
- Release packaging was not exercised because doing so after a target tag would expand scope into release mutation. The packaging, version, cask, and Homebrew files are unchanged.

## Policy Boundary And Rollback

The scanner is deliberately conservative: a future workflow requiring a different branch push or write permission must receive explicit review instead of silently widening the allowlist. It cannot prove arbitrary secret-backed third-party action behavior, so top-level read-only permission is the primary boundary for all non-release workflows.

Rollback is commit-local and ordered: revert documentation/spec commits, then `9f8304e`, then `2f15994`. Restoring `auto-tag.yml` would intentionally reopen the closed P0 and must not be treated as a normal rollback. No database, user data, release asset, tag, remote branch, or Homebrew state needs rollback.

## Delegation Record

Three bounded agent attempts were made sequentially for research, implementation review, and verification review. Each produced no output or file change and was stopped; no nested agents were allowed, and all implementation and evidence were reviewed directly in the primary task.

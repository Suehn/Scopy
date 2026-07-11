# Build And Release Output Guidelines

> Executable contract for Xcode, SwiftPM, local deployment, and tagged packaging outputs.

## Scenario: Keep Xcode And SwiftPM Products Isolated

### 1. Scope / Trigger

Apply this contract when changing `project.yml`, `deploy.sh`, `scripts/build-release.sh`, Makefile build targets, XcodeGen build settings, or CI release commands.

The repository may live under a file-provider-backed `Documents` directory. An app bundle created inside the workspace can inherit Finder/resource-fork metadata; if Xcode and SwiftPM also share `.build`, a later CodeSign step can fail repeatedly even when Swift compilation succeeds.

### 2. Signatures

```bash
./deploy.sh [debug|release] [clean] [--no-launch]

SCOPY_XCODE_DERIVED_DATA=/absolute/safe/path \
  ./deploy.sh release --no-launch

./scripts/build-release.sh
```

`project.yml` must not set repository-local `BUILD_DIR` or `CONFIGURATION_BUILD_DIR`. Xcode uses DerivedData. Direct `swift build`, `ScopyBench`, and final DMG files continue to use repository `.build`.

### 3. Contracts

- `deploy.sh` default DerivedData: `~/Library/Developer/Xcode/DerivedData/Scopy-Deploy`.
- `scripts/build-release.sh` default DerivedData: `~/Library/Developer/Xcode/DerivedData/Scopy-Release`.
- Optional environment key: `SCOPY_XCODE_DERIVED_DATA`.
  - Type: absolute filesystem path.
  - Forbidden values: `/`, `$HOME`, and repository root.
  - Purpose: deterministic override for CI or local isolation.
- Deploy output app: `$SCOPY_XCODE_DERIVED_DATA/Build/Products/<Configuration>/Scopy.app`.
- Tagged packaging output: `.build/Scopy-<version>.dmg`; only the final artifact shares the SwiftPM directory, never the Xcode app bundle.
- Build failure: retain `<DerivedData>/deploy-<Configuration>.log` or `<DerivedData>/build-release.log`, print its path and final 80 lines, return nonzero.
- `clean` may delete only the validated deploy DerivedData root.

### 4. Validation And Error Matrix

| Condition | Required behavior |
|---|---|
| Unknown deploy argument | Print usage, exit 2, no build/deploy mutation |
| Relative `SCOPY_XCODE_DERIVED_DATA` | Reject, exit 2 |
| Override equals `/`, `$HOME`, or repo root | Reject before any `rm -rf`, exit 2 |
| Xcode build/CodeSign fails | Preserve log, print actionable tail, exit 1 |
| Expected `.app` missing after successful command | Exit 1; do not replace `/Applications/Scopy.app` |
| Install copy fails | Restore `Scopy_backup.app`, exit 1 |
| Build succeeds | Deploy exact app from the selected DerivedData/configuration |

### 5. Good / Base / Bad Cases

- Good: `./deploy.sh release --no-launch` succeeds twice consecutively without cleanup; `/Applications/Scopy.app` exists.
- Base: `./deploy.sh` builds Debug and retains the existing launch prompt.
- Bad: setting `BUILD_DIR: $(SRCROOT)/.build` in `project.yml`; SwiftPM and Xcode then own the same tree and signing becomes sensitive to stale/file-provider metadata.
- Bad: fixing the symptom only with a one-time `xattr -cr .build/Release/Scopy.app`; a later build can recreate the contaminated bundle.

### 6. Tests Required

After changing this contract:

1. `bash -n deploy.sh scripts/build-release.sh`.
2. Reject a relative override and `/`; assert exit code 2 before build output changes.
3. Run `./deploy.sh release --no-launch` twice; assert both exit 0 and the installed app exists.
4. Run `make build`; assert Xcode product path is DerivedData, not repository `.build`.
5. Run `make test-snapshot-perf-release`; assert SwiftPM `.build/release/ScopyBench` still works and thresholds pass.
6. Run `make docs-validate` and `make release-validate` when release docs or metadata change.

### 7. Wrong Vs Correct

#### Wrong

```yaml
settings:
  base:
    BUILD_DIR: $(SRCROOT)/.build
    CONFIGURATION_BUILD_DIR: $(BUILD_DIR)/$(CONFIGURATION)
```

#### Correct

```yaml
settings:
  base:
    # Keep normal Xcode DerivedData defaults.
    SWIFT_INCLUDE_PATHS: "$(inherited) $(OBJROOT)/../Products/$(CONFIGURATION)"
```

```bash
xcodebuild build \
  -project Scopy.xcodeproj \
  -scheme Scopy \
  -configuration Release \
  -derivedDataPath "$XCODE_DERIVED_DATA"
```

## Scenario: Keep Release Tag Authority Explicit

### 1. Scope / Trigger

Apply this contract when changing `.github/workflows/`, `scripts/release/`, release-related Make targets, or the tag-driven packaging flow. A push to `main` may validate a release candidate, but it must never create or push a Git tag. Conditional performance, concurrency, UI, and packaging gates depend on the change scope and cannot be inferred safely by a generic push-triggered tag job.

### 2. Signatures

```bash
make release-validate
make test-release-policy
make tag-release
make push-release

python3 scripts/release/validate_workflow_tag_policy.py \
  [--workflow-dir /path/to/workflows]
```

Only the explicit maintainer commands `make tag-release` and `make push-release` may invoke `scripts/release/tag-from-doc.sh` and create the metadata-derived tag.

### 3. Contracts

- Every non-release workflow declares top-level `permissions: contents: read` (or `read-all`) so all jobs remain read-only even if repository defaults drift.
- `.github/workflows/release.yml` is the only workflow allowed `contents: write`; its entrypoints are exactly `push.tags: ["v*"]` and `workflow_dispatch`.
- Workflows may consume an existing tag, parse a tag name, publish an existing tag's assets, and push the branch-only cask update as the exact command `git push origin HEAD:main`.
- No workflow may invoke `tag-from-doc.sh`, execute `git tag`, create `refs/tags/*`, create a release tag through `gh`/`hub`, use a known tag-creation action, or perform any other `git push` form.
- `make release-validate` must run `validate_workflow_tag_policy.py`; the validator uses only the Python standard library and scans both `.yml` and `.yaml` workflow files by content.
- A release tag is created only after the maintainer has completed the gates required by `doc/current/release-runbook.md`; pushing release documents alone is validation-only.

### 4. Validation And Error Matrix

| Condition | Required behavior |
|---|---|
| Non-release workflow omits top-level read-only permissions | Policy exits 1 before any job can inherit repository defaults |
| Non-release workflow grants `contents: write` or `write-all` | Policy exits 1 and reports file, line, and reason |
| Any workflow creates or pushes a tag | Policy exits 1, even if the workflow was renamed |
| Release workflow adds a branch, path, PR, schedule, or `workflow_run` trigger | Policy exits 1 |
| Release workflow loses `v*` tag or explicit dispatch entrypoint | Policy exits 1 |
| Workflow directory is missing or empty | Policy exits 2 |
| Existing tag-driven release plus exact `HEAD:main` cask update | Policy exits 0 |
| Release metadata/document mismatch | `make release-validate` exits nonzero before any explicit tag command |

### 5. Good / Base / Bad Cases

- Good: CI validates docs, release metadata, policy fixtures, build, unit tests, and strict concurrency while retaining read-only repository permission.
- Base: a maintainer runs the required gates, commits the release candidate, then deliberately runs `make tag-release` or `make push-release`.
- Bad: a `main`-push workflow runs `tag-from-doc.sh --ensure` after only validating release-document shape.
- Bad: a renamed workflow uses `git push --follow-tags`, a direct `refs/tags/...` API call, or a third-party tag action.
- Bad: relying on a tag pushed with the repository `GITHUB_TOKEN` to recursively trigger the release workflow.

### 6. Tests Required

1. `make test-release-policy`; assert the real workflows and safe tag-trigger fixture pass.
2. Assert missing top-level read permission, renamed helper, `git tag`, non-allowlisted push, direct tag-ref API, release-creation CLI, known tag action, write permission, forbidden release trigger, and folded-scalar fixtures fail for the intended reason.
3. `make release-validate` and `make docs-validate`; assert both exit 0.
4. Parse every workflow as YAML and run `python3 -m py_compile` on the validator/tests.
5. Run `make build`, `make test-unit`, and `make test-strict` for workflow-policy changes.
6. Assert `scripts/release/tag-from-doc.sh`, `scripts/release/push-main.sh`, `.github/workflows/release.yml`, and `project.yml` are unchanged unless explicitly in task scope.
7. Assert the candidate tag is absent locally and remotely; never exercise tag, push, dispatch, release, or Homebrew mutation during policy tests.

### 7. Wrong Vs Correct

#### Wrong

```yaml
on:
  push:
    branches: [main]
permissions:
  contents: write
steps:
  - run: bash scripts/release/tag-from-doc.sh --ensure
  - run: git push origin "$TAG"
```

#### Correct

```yaml
# ci.yml validates but cannot publish.
permissions:
  contents: read
steps:
  - run: make release-validate
  - run: make test-release-policy
```

```yaml
# release.yml consumes a deliberate existing tag.
on:
  push:
    tags:
      - "v*"
  workflow_dispatch:
```

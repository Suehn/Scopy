# Fix Reliable Release Deploy Build

## Goal

Make `./deploy.sh release` complete reliably from the current Scopy workspace without requiring manual deletion of build artifacts, while preserving the project version and deployment baselines defined by repository metadata.

## What I Already Know

- The user reproduced the failure three times at the Release compile step.
- The script writes Xcode products into the repository `.build` directory.
- SwiftPM release benchmarks also use `.build`; prior isolated Xcode builds under `/tmp` pass while the shared `.build` path has exhibited codesign resource-fork/FinderInfo contamination.
- The current worktree contains in-progress safe-triangle changes and the user's `.codex/config.toml`; none may be discarded.

## Assumptions

- The expected fix is in the build/deploy tooling, not a one-off cleanup command.
- Release deployment should remain compatible with both arm64 and the existing `project.yml` deployment/version baselines.

## Requirements

- Capture the complete failing Release build error before changing the script.
- Isolate Xcode app products from SwiftPM products so repeated Release builds are idempotent.
- Preserve the existing install/launch behavior of `deploy.sh`.
- Do not delete or reset user changes.
- Keep diagnostic output actionable when a future build fails.

## Acceptance Criteria

- [x] `./deploy.sh release --no-launch` succeeds from the current dirty worktree.
- [x] A second consecutive identical command also succeeds without cleanup.
- [x] `make test-snapshot-perf-release` continues to use SwiftPM `.build` and passes.
- [x] `make build` and unit tests remain valid with the repository build conventions.
- [x] Documentation/release notes describe the durable build-directory contract change.

## Definition of Done

- Relevant build scripts are minimal and maintainable.
- Release build succeeds twice consecutively.
- Safe-triangle focused tests remain green.
- No unrelated working-tree changes are overwritten.

## Out of Scope

- Creating a git tag, GitHub release, or Homebrew publication.
- Changing `SWIFT_VERSION`, `MACOSX_DEPLOYMENT_TARGET`, or the Xcode baseline.
- Cleaning unrelated pre-existing strict-concurrency warnings.

## Technical Notes

- Primary files: `deploy.sh`, `project.yml`, `Makefile`, and Xcode build settings.
- Confirmed failure: CodeSign rejected `.build/Release/Scopy.app` with `resource fork, Finder information, or similar detritus not allowed`; the bundle root carried `com.apple.FinderInfo` under the file-provider-backed workspace.
- Decision: restore Xcode defaults in `project.yml`; local deploy/tagged packaging use explicit DerivedData roots outside the workspace, while SwiftPM and final DMG artifacts retain `.build`.
- `deploy.sh` now accepts composable arguments, validates an override before any optional cleanup, and preserves the build log with an actionable tail on failure.

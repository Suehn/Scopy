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

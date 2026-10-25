# Real-app differential verification

This driver launches production Scopy bundles directly and reads their real Accessibility trees, private pasteboards, SQLite records, and ingest artifacts. It does not use XCUITest or install an app. Coordinate an exclusive desktop-input period before running it; builds can run separately, but functional results are not performance measurements.

## Current executable scenario

`capture-quit-restart` captures Unicode text and Markdown through the real monitor, asserts that each committed item reaches the real list, writes an 8.65 MB deterministic text capture, waits for durable acceptance, requests normal AppKit termination, then restarts the same isolated app. It verifies content, identity, usage count, database integrity, and final spool cleanup. It records whether the large capture was still pending or already committed when quit was requested. A remaining envelope after quit is reported separately from the SQLite commit: an acknowledged receipt can make replay a no-op.

```sh
bash scripts/e2e/build-tools.sh
python3 scripts/e2e/run.py \
  --baseline /absolute/path/to/baseline/Scopy.app \
  --candidate /absolute/path/to/candidate/Scopy.app \
  --output /absolute/path/to/a/new/evidence-directory
```

Omit `--candidate` to validate the baseline and driver. Every run requires a new output directory. `result.json` reports the outcome; raw AX trees, per-stage database records, spool manifests, input fixtures, settings, build hashes, and app logs remain under each side. Fixture bodies are synthetic. Database text is represented by byte count, SHA-256 and a bounded prefix in observations; payload and envelope files remain in the isolated storage root.

`--seed /absolute/path/to/offline/storage-root` copies a complete stopped Scopy storage root to both sides. The source must already contain `.scopy-writer.lock`; the driver holds its exclusive lock while copying and refuses symlinks. Copying the whole directory preserves `clipboard.db`, WAL state, `content/`, `ingest/`, thumbnails and search caches. Never pass a live production root. Without a seed, both sides start with the same empty storage state and empty home caches.

## Isolation

- Each run copies the bundles and gives them one new `com.scopy.e2e.<random>` identity, reused sequentially across sides. The source bundles stay untouched. Staging changes only bundle identity, automatic-updater settings and the ad-hoc signature; source and staged executable hashes are recorded.
- `CFFIXED_USER_HOME` redirects Foundation Application Support and cache lookups. A helper verifies both before launch. It does **not** redirect UserDefaults on the maintainer's macOS: preferences live in the real user's Preferences directory under the new test bundle ID. The driver refuses a nonempty test domain, initializes deterministic English settings, records the final values, and removes only its own newly created domain.
- Window and preview preferences start from the isolated domain. The global hotkey uses Command+Control+Option+Shift+F12. Launch-at-login is never changed.
- Each app uses its own storage directory and a `ScopyE2E.*` pasteboard. The production outbound history-copy route uses the same monitor-owned pasteboard. The bridge rejects every other pasteboard name and only reads the general pasteboard's change count. Any general change invalidates the run; the driver never restores the user's clipboard.
- A process sandbox denies writes to the installed app, production Scopy Application Support/cache roots, original preference plist and shared `temporaryDirectory/Scopy` tree. The latter matters because Foundation's temporary directory ignores `TMPDIR`, and startup normally sweeps old AirDrop files there. AirDrop is outside this driver's coverage.
- The driver requests normal AppKit quit for the lifecycle assertion. SIGTERM/SIGKILL are only bounded failure cleanup and do not count as termination-drain evidence. Only the PID it launched is stopped.

## Baseline provenance

The redesign baseline is v0.84.0 (`6cc0c5812b3dc7e42cd738bb72ad36f035c08643`). Source `452703787eb96f0893d6f1c9e4f2ac00c4792800` has identical production source, package/build declarations and renderer assets; its differences are the Cask and task documents. Rebuild it in a checkout of that source, with independent DerivedData:

```sh
make markdown-assets-gate setup
xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release \
  -derivedDataPath /absolute/path/to/Scopy-e2e-v084 build \
  MARKETING_VERSION=0.84.0 CURRENT_PROJECT_VERSION=734
```

Record `git rev-parse HEAD`, `git diff v0.84.0 HEAD -- Scopy ScopyUISupport Package.swift project.yml Tools/MarkdownRenderer`, Xcode/Swift/macOS versions, resolved dependencies, renderer asset hashes, executable hash and the build log alongside the run. A version label alone is not build provenance.

## Interpretation and remaining coverage

The differential comparison retains database order and all semantic item fields, checks a one-to-one UUID/content mapping and compares ingest receipt targets and metadata. Exact capture timestamps and random ingest IDs remain in raw evidence; creation windows, ordering, receipt count and item references are checked before normalization. It never sorts away a result-order difference or collapses duplicate rows.

Passing this scenario proves the paths it executes. Search/pagination, copy shortcuts, pin/delete/undo, settings Save/Cancel, hover/pinned previews, image/file capture, PNG export and measured performance require their own real-app scenarios. The full redesign acceptance must list those outcomes rather than treating this lifecycle result as complete E2E coverage. Existing `scripts/perf-scroll` tools supply input and timing primitives; interleaved A/A and A/B are required before making performance claims.

For this tooling change run `make test-tooling`, compile the helpers, and run a real baseline. The narrow safety tests are `python3 -m unittest discover -s scripts/e2e -p 'test_*.py'`; they exercise refusal of active seed writers and semantic comparison regressions without a GUI.

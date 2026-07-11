# Debug Retrospective: Apparent Mouse-Gated Profiling

## 1. Symptom And Evidence

The fixed workload sometimes appeared to start only after the user moved the mouse. App metrics and process samples showed that scrolling had already completed; the XCTest runner was blocked in `open()` from `Data(contentsOf:)` while reading or writing under the repository in `~/Documents`. The same block later reproduced in unit fixture and bundled JavaScript reads through `#filePath`.

## 2. Root-Cause Category

- Primary: implicit cross-boundary assumption that an XCTest process can synchronously use a Documents-hosted repository as runtime storage.
- Secondary: coverage gap because earlier smoke runs checked final output but did not repeatedly prove unattended completion or sample the runner while output was missing.

## 3. Why Earlier Fixes Did Not Resolve It

Window activation, display-link selection, scroll-view re-resolution, and launch timing affected how scrolling began, but none could release a runner blocked in filesystem `open()`. Mouse movement merely correlated with macOS file coordination completing. More retries or watchdogs would have obscured the boundary failure and added nondeterminism.

## 4. Durable Fix

- Copy profile DB inputs to `/tmp` before launch.
- Write all in-progress profile JSON to `/tmp`, then copy complete outputs into `logs/` after successful `xcodebuild`.
- Bundle unit fixtures and renderer assets; resolve them through `TestFixture` instead of runtime `#filePath`.
- Start app-side scrolling from one post-launch notification, resolve the production table/outline scroll view, and drive it with `NSScreen CADisplayLink`.
- Keep metric semantics explicit: callback cadence is not FPS.

## 5. Prevention

The frontend quality spec now defines the bundle/temporary-storage contract and validation matrix. Future stalls must be sampled before adding activation or pointer workarounds. Completion requires repeated unattended AB/BA and real-snapshot output, not one run that happens to finish after user input.

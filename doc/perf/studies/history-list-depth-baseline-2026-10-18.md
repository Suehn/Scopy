# History list at depth: frontend baseline

Date: 2026-10-18. Host: Apple M3 (4P+4E), 24 GB, macOS 27.2 (`26B5101f`), Xcode 27.0 (`27A5194q`), AC power,
panel 480x640 on a 2560x1664 Retina display. Another Scopy (the installed app) was running and was not touched.

Build: Release of `main` at `347238f`, copied and re-signed ad hoc as `com.scopy.verify.phase3` so that its
preferences never touch `com.scopy.app` (that domain was given Sparkle checks off, website icons off and an unused
hotkey). Data: a copy of `perf-db/clipboard.db` (SHA-256 `40875760…86b7`, 6,421 rows, 27 pinned) kept warm across
runs; `SCOPY_SERVICE_DB_PATH` keeps the spool and storage beside it. The binary was launched directly with
`USE_MOCK_SERVICE=0`, a private monitor pasteboard, `SCOPY_PROFILE_OPEN_PANEL=1` and `SCOPY_SCROLL_PROFILE=1`. The
driver (`run.py`) and its raw output stay in the session scratchpad and `logs/phase3/`.

## States and workloads

- **Fresh**: the first page after launch, 80 Accessibility outline rows (77 items and the section headers).
- **Deep**: after seven 3 s mouse-wheel bursts (120 px per event, 60 events/s, 1 s apart), 3,380 outline rows.
  Depth is read from Accessibility (`AXOutline` `AXRows`). The profile's `fixed_workload.loaded_count` read 77 in
  every gated run; that was the start-barrier bug below, not a stale value.
- Each run measures one 8 s window: **type** `cm` at 8 keys/s with real key events (the AX readback must show the
  query), **hover** (`build/hoverstall`, pointer stepped over 6 rows), **capture** (10 unique 2,000-byte texts on
  the private pasteboard, 0.5 s apart), or **idle**. States and workloads were interleaved, 3 runs per cell.

## Main-thread cost: what the instruments say

| 10 events per window | AX probe: blocked ms (stalls > 50 ms) | `sample`, AX-free: main-thread busy samples | process CPU, AX-free |
| --- | --- | --- | --- |
| capture, fresh | 0 (0) | 378 | 0.2 s |
| capture, deep | 1,089 ± 20 (10) | 981 | 1.3 ± 0.4 s |
| type, fresh | 134 ± 17 (2) | 199 | 0.8 s |
| type, deep | 293 ± 7 (2) | 238 | 0.8 s |
| hover, fresh / deep | 0 / 0 | — | 0.4 / 0.4 s (probe attached) |

`sample` ran at ~1.4 ms per sample over 7 s. Its deep capture window spends 488 samples in
`GraphHost.flushTransactions` (34 fresh): `OutlineListCoordinator.diffRows` 163 (9 fresh), `HistoryLiveRow.body`
133 (3 fresh), the rest walking the List's view-list nodes (`ForEachList.applyNodes`, `ViewListTree.getIDs`). That
is about 69 ms of main-thread work per capture with 3,380 loaded rows, nearly all of it SwiftUI List machinery.
`HistoryListState`, `upsertRecentItem` and the rest of `HistoryViewModel` do not reach a single sample.

The structural counters agree (profile from launch, no start barrier): ten captures at 3,380 rows add 10
`list.body` runs and 33,796 `row.init` (151,328 against 117,532 for the same state without captures), ten at 80
rows add 600–700. Every List update constructs a row value for every loaded row, because `HistoryLiveRow` takes
a content closure, which SwiftUI cannot compare, so each update re-runs every row's body; the wrapped
`HistoryItemView` is `.equatable()`, so its own body is skipped, but its initializer is not.

Typing does not scale with depth: replacing 3,380 rows by the results costs about what replacing 80 does.

`scripts/perf-scroll/profile_search.py --query cm --rate 8 --reuse-db` (what `make perf-search-type` runs, pointed
at the isolated copy; fresh state, profiled from launch), 3 runs: Scopy CPU 0.73–0.79 s over the 3 s typing window
plus tail, `list.body` 9, `row.init` 1,549–1,550, 353 result rows by AX readback.

## Instrument findings

- **The Accessibility probe distorts depth.** `hoverstall` answers each `kAXWindows` query on the app's main
  thread (`accessibilityWindowsAttribute` → `_NSCGSGetSpaces`), and in the deep state its answers take ~100 ms after
  each List change. With the probe attached, the deep typing window spends 702 of 1,125 busy main-thread samples
  answering it. Its stall readings are valid for comparing like with like, not for absolute cost with large lists.
- **The profile start barrier did not hold** (found after this study and fixed
  since). With `SCOPY_PROFILE_START_NOTIFICATION` set, the first `TimelineView` callback after launch opened the
  measurement window, so every gated report covered the 8 s after launch, not the workload. That is why `list.body`
  and `row.init` looked missing and `loaded_count` read 77. Counters here come from runs profiled from launch. With
  the barrier fixed, the same deep capture (`main` code) reports 10 `list.body`, 33,602 `row.init` and
  `loaded_count` 3,387.
- **`TimelineView(.animation)` cadence does see the capture stalls.** An earlier version of this list said it did
  not; those readings came from the launch window above. In the fixed deep capture, the callbacks drop to 412 in
  8 s, the longest gap is 208 ms, and 2.4% of the intervals are over the threshold. `sample` remains the attribution
  source.
- **The main run-loop observer started only on `scrollDidStart`**, which a mouse-wheel stream without gesture phases
  never sends, so `main_runloop_active_ms` was empty for typing, hover and capture. The barrier release now starts
  it too: the fixed deep capture records 2,336 ms of main run-loop activity, p95 0.9 ms and max 208 ms.
- With the window open, the profiler's own ingestion is not free at depth. The gated deep capture used 2.41 s of
  CPU, against 1.1–1.4 s for the same workload in runs whose profile window had already closed. Take cost from
  `sample` and process CPU with the window closed or the profiler off.

## Memory

Footprint is 85 MB fresh and 176–182 MB deep (the profiler's own sample buffers add about 23 MB to both). The deep
heap holds 37.6 MB more live objects than the fresh one: 17 MB of `String` storage (the loaded rows carry 10.5 MB of
`plainText`), the display-text and descriptor caches (bounded at 20,000 and 4,096 entries), about 3 MB of List
structures (`ListOutlineItem`, view traits, IDs: about 1 KB per row), and the DTO array. vmmap reports 57 MB of
malloc fragmentation in the deep state and none fresh: the churn of the deep scroll, freed but not yet returned.
The thumbnail cache is capped at 32 MB.

## Decisions for the next change

- Bounding `HistoryListState.upsertRecentItem` (binary search, shifted index range, group-position map): **dropped**.
  It never appears in a sample, while the List machinery costs ~69 ms per capture at 3,380 rows.
- `fileExists` in context-menu predicates (0.5–2 µs per call, about 3 per menu): **dropped**.
- `IconService` LaunchServices lookups on the main thread (~10 ms for the first lookup in a process, then
  0.1–1 ms, cached per bundle ID and preloaded at start): **dropped**; one-time and absent from every sample.
- `ClipboardItemDisplayText` full-text counting on first draw (2.6 ms for 100 KB, 21 ms for the largest 838 KB
  row): **dropped**; prewarm runs on the cooperative pool and the counting never shows on the main thread.
- Unbounded loaded rows: real, as an O(loaded rows) main-thread cost per List update (~20 µs per row per
  capture) and ~6 KB of live memory per row. SwiftUI List diffing and row re-evaluation dominate it, so the remedy
  is the AppKit list proposed in
  [history-list-explicit-updates.md](../../proposals/history-list-explicit-updates.md), not a change inside
  `HistoryListState`.

Not measured: the installed app's own behaviour, launch, scrolling cost at depth, and anything with VoiceOver on.

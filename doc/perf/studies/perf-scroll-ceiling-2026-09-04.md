# History-list scroll: where the time goes and how much of it can be removed

Date: 2026-09-04. Host: Apple M3 Pro (5P+6E), 36 GB, 120 Hz; macOS 15.7.3 (`24G419`); Xcode 26.1.1.
Build: Release, `MARKETING_VERSION=0.80.0`. Data: the real 9,566-row snapshot database, warm copy
(`logs/perf-scroll/db-warm`). Workload: `profile_scroll.py --mode wheel --duration 12`, 720 posted
pixel scroll-wheel events at ~2,850 px/s with the direction reversed every 4 s, panel 480x640,
about 780 row appearances per run.

Every figure below is the mean of 3-5 runs. Run-to-run spread on this workload is about 1% (sd
0.03-0.08 s on CPU), so differences above ~3% are real.

## The measurement had to be fixed first

Three harness defects made earlier runs measure something other than scrolling. All three are
fixed in `scripts/perf-scroll/`; numbers taken before this date are not comparable to the ones
here.

1. `winpos` returned the app's **largest** window. A hover preview popover is larger than the
   panel, so when one was up the synthetic input went to the popover and the list never moved —
   the run then looked almost free (0.80 s instead of 3.8 s). It now prefers the highest window
   layer, which is the panel.
2. The pointer was left wherever the previous run put it. Sitting over the list while the panel
   opened, it started a hover preview during the settle, and that popover swallowed the input.
   The driver now parks the pointer before launching.
3. The pointer was still over the list when the wheel stopped, so the row under it opened a
   preview once the scroll settled. That presentation landed inside the measured window as about
   260 ms of main-thread work and as the run's worst callback. **The "94 ms scroll hitch" in
   earlier notes was a preview presentation, not a scroll cost**; with the pointer parked
   afterwards the worst callback is 35 ms.

Instrumentation overhead was measured rather than assumed, twice. A single pair taken before the
harness was fixed suggested about 1%; three runs per side on the fixed harness put it at **5.8%**
(`3.447 s` with `SCOPY_SCROLL_PROFILE=0` against `3.660 s` with the profiler on). The app's own
`TimelineView(.animation)` frame sampler is only present when profiling, so every figure in this
document is about 6% above what the same build costs a user. Ratios are unaffected, since both
sides of every comparison carry it; absolute production CPU for the shipped build is `3.447 s`,
and the `v0.80.0` baseline in the same configuration is about `3.65 s`.

A/B runs keep the profiler on anyway, because `scroll_speed_px_per_sec` is the only signal that
confirms the list actually moved, and a run where it did not is otherwise indistinguishable from a
large win.

## Where the 3.88 s goes

`v0.80.0` costs `3.878 s` of CPU over the 12 s scroll, essentially all of it on the main thread
(the panel idles at `0.01 s` per 12 s, so no idle correction applies). Peeling the row apart one
layer at a time:

| Configuration | CPU | main run-loop busy |
| --- | ---: | ---: |
| Minimal `List(0..<9566) { Text().frame(height: 44) }` in the same panel | `2.05 s` | — |
| + `HistoryItemView` struct, its dynamic properties, `.equatable()`, the list wrappers | `2.67 s` | `1852 ms` |
| + the lean row's view nodes (icon, two texts, paddings, frames) | `2.90 s` | `1920 ms` |
| + the real content and appearance (`rowVisualContent`) | `3.19 s` | `2072 ms` |
| + popovers, context menu, `onChange`, scroll-wheel monitor | `3.31 s` | `2095 ms` |
| + `.onHover` | `3.51 s` | `2254 ms` |
| `v0.80.0` as shipped | `3.878 s` | `2508 ms` |

### Per-frame and per-row, separated

The minimal-List figure above is not a constant: it depends on how many rows the scroll mounts,
which depends on row height. Measuring it at two heights separates the two terms.

| Minimal `List` row height | rows mounted in 12 s | CPU |
| ---: | ---: | ---: |
| `44 pt` | 777 | `2.09 s` |
| `88 pt` | 389 | `1.917 s` |

Solving gives **`0.45 ms` per row mount and a fixed `1.74 s` that does not depend on the rows at
all** — 720 scroll frames at about `2.4 ms` each. So of the `3.878 s` a scroll costs:

- **`1.74 s` (45%) is per-frame**: clip-view scrolling, `NSTableView`'s visible-range bookkeeping,
  Core Animation commit, compositing. Identical for any row.
- **`2.14 s` (55%) is per-row**: about `4.3 ms` for one Scopy row against `0.45 ms` for a `Text`,
  roughly ten times the cost.

Two components of the per-frame term were tested and are not worth anything: coalescing the
clip-view settle timer, which today allocates and cancels a `DispatchWorkItem` on every scroll
frame, measured `3.74 s` against a contemporaneous control of `3.64 s`; hiding the scroll
indicators measured `3.63 s`. Both are inside the noise or worse.

The one per-frame component that does cost is the panel itself. Made fully opaque — no
`NSVisualEffectView`, opaque window, opaque list background — a scroll costs `3.323 s` against
`3.660 s` for the same build with the frosted panel, and `2128 ms` of run-loop busy against
`2411 ms`. **The frosted panel is worth about 9% of scroll CPU.** That is a product trade, not an
optimisation, and it is not taken here.

Read as buckets: the whole of Scopy's row — every view, every modifier, every piece of
interaction — is `2.14 s`. The largest single row modifier is `.onHover` at 0.20 s; the largest
single bucket is the row's own scaffolding at 0.62 s above a `Text` row.

## What was tried on the container, and what it measured

The container is where the majority of the cost is, so it was attacked first. Every attempt
measured worse or negligible:

| Attempt | Result |
| --- | --- |
| `ScrollView` + `LazyVStack` instead of `List` | CPU `3.74 s`, busy `3687 ms` — busy 37% worse |
| `NSTableView` + `NSHostingView` cells rendering the same `HistoryItemView`, fixed row heights, `rootView` reassigned on reuse, `sizingOptions = []`, page appends via `insertRows` | CPU `3.76 s`, busy `3427 ms` — busy 52% worse |
| Exact `.frame(height:)` per row instead of `.frame(minHeight:)` | CPU `4.13 s` at the matched height — worse; automatic row heights are not avoided this way |
| Opaque panel fill instead of the `NSVisualEffectView` | CPU `3.56 s` — 8%, but it is the panel's design |
| Removing the per-row `listRowInsets` / `listRowBackground` | no change |
| Showing list separators instead of hiding them | CPU `3.71 s` — worse |
| Removing `.equatable()` from the row | busy `3660 ms` against `2254 ms` — much worse, it stays |
| Installing `.onHover` only while the list is idle, with the scroll phase delivered through the same per-row fan-out selection already uses | CPU `3.656 s` against `3.572 s`, busy `2664 ms` against `2309 ms`, worst callback `61.7 ms` against `35.0 ms` — worse |
| Folding `HistorySelectionAwareRow` into the row (its wrapper existed only because the old nested `Button` made row-owned selection break the harness identifiers) and resolving the launch-time accessibility branch once instead of per row | CPU `3.560 s` against `3.572 s` — neutral. The `0.25 s` the "bare rows" probe showed came from dropping the `Group`, and moving the accessibility modifiers into the row costs back what removing it saves |
| Truncating what reaches `Text` | not taken: titles are already capped at 100 characters, and real-vs-constant strings measured `0.18 s` across the whole row |

The `NSTableView` result is the important one: reassigning `rootView` on a recycled hosting view
is not cheaper than what `List` already does, so replacing the container is not the lever it was
assumed to be. A hand-tuned version might do better, but the naive form starts 52% behind.

The conditional-`.onHover` result is the second: `.onHover` costs 0.20 s, and leaving it off while
the list moves looked like the last item of size. It behaves correctly — both hover gates pass,
including the one that matters, where the pointer never moves and the preview still appears once
the scroll settles — but it costs more than it saves. Switching a `_ConditionalContent` branch
inside the row tears the row's subtree down and rebuilds it for every visible row at each scroll
boundary (`interaction.idle_disappear_fast_path` 323 -> 399) and pulls extra `List` body runs with
it (`list.body` 7 -> 12, `row.init` 1106 -> 2300). This is the same shape of result as the
per-row hover marker tried before it and as exact row heights: **any per-row structural switching
in this list costs more than the work it removes.**

## What shipped

Three row-level costs, all removed without any behaviour change (`456abdf`):

- The row's activation surface was a `Button`. A SwiftUI button installs a pointer region, and
  `NSTableView` makes SwiftUI recompute a re-inserted cell's pointer region, which re-evaluates
  the row body. `NSHostingView.updateRemovedState` -> `PointerRegionUpdater.updatePointerRegion`
  was 5.7% of main-thread samples and is now zero. The surface keeps its tap target,
  accessibility identifier, button trait and default action.
- The row carried `.id(item.id)` inside a `ForEach` whose elements are already `Identifiable` by
  that id, giving every row a second identity scope for nothing. `ScrollViewReader` still finds
  rows through `ForEach`'s own identity.
- Liveness, pointer presence and the two ownership tokens were `@State`. Nothing reads them while
  the body is built, but they are written on every row appearance and every pointer crossing, and
  each write invalidated the row.

Measured interleaved in one session, 5 runs per side:

| | `v0.80.0` | after |
| --- | ---: | ---: |
| CPU over the 12 s scroll | `3.878 +- 0.037 s` | `3.572 +- 0.026 s` (-7.9%) |
| main run-loop busy | `2508 +- 37 ms` | `2309 +- 31 ms` (-7.9%) |
| worst callback | `35.0 ms` | `35.0 ms` |
| callback p95 | `8.33-16.67 ms` | unchanged |

## The list is not dropping frames

Everything above measures CPU. Whether the scroll is *smooth* is a different question, and the
harness cannot answer it: its callback intervals are quantised to the 8.333 ms display tick and
cannot see a hitch. Instruments can.

An `Animation Hitches` trace over the same 12 s / 2,850 px/s scroll records **zero hitches**
(`hitches-summary`: 0 rows across 967 presented frames). The app's own counters agree: dropped-frame
ratio `0.005`, worst callback interval `16.67 ms`, i.e. at most one skipped frame on a 120 Hz
display across the whole run.

So the history list already scrolls at the display's limit under input far more aggressive than a
person produces. **There is no smoothness deficit to recover.** What the work in this document
improves is CPU, which is battery and heat, not perceived scrolling.

Note for anyone sharing a trace: an Instruments `.trace` bundle embeds the recording process's
whole environment, including any secrets exported in the shell. `logs/` is git-ignored so these
stay out of the repository, but they should not be attached to a bug report unedited.

## The ceiling

Removing **everything** from the row — all content, all interaction — leaves the `1.74 s` of
per-frame cost plus what a `Text` row would still cost, about `1.96 s`, which is `1.98x`. That is
the arithmetic maximum for row-level work, and it is not a reachable product. Adding the frosted
panel's 9% on top of it would reach about `2.2x`, and only with a row that draws nothing on a
panel that no longer looks like Scopy. What remains addressable after this change:

| Remaining | Cost | Why it is not free |
| --- | ---: | --- |
| `.onHover` | `0.20 s` | Attempted and reverted: installing it only while the list is idle is correct but measures worse (above). Removing it outright needs list-level pointer tracking with a row-index-to-item mapping; the earlier attempt at that shape (list tracking area + per-row marker view) also measured worse |
| list wrappers (selection fan-out, accessibility group) | `0.25 s` | Both are functionally required; the three `listRow*` modifiers inside them are already free |
| popovers, context menu, `onChange` | `0.12 s` | Folding four popovers into one `popover(item:)` is worth part of it |
| row view nodes and content | `0.51 s` | This is the row people look at. Merging `background`/`overlay`/`animation` into single nodes was measured before and gave nothing |

A realistic further capture is `0.2-0.3 s`, taking the total to about **1.15-1.20x**, or about
`1.3x` if the frosted panel is also given up. **1.5x is not available in this architecture**: it would require deleting three quarters of everything the row
does, and the container underneath it — which is over half the cost — measured worse under every
replacement tried.

If a large factor is ever required, the honest options are to change the workload rather than the
code (fewer visible rows, cheaper rows by design) or to accept a substantially plainer row. Both
are product decisions, not optimisations.

## Reproducing

```
make perf-scroll-tools
xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release build
python3 scripts/perf-scroll/ab_scroll.py <Release Scopy.app> <label> --runs 5 --mode wheel \
    --duration 12 --reuse-db
python3 scripts/perf-scroll/profile_scroll.py <app> <label> --mode wheel --duration 12 \
    --reuse-db --sample --no-app-profile
python3 scripts/perf-scroll/analyze_sample.py logs/perf-scroll/<label>/sample.txt \
    --thread main --grep 'PointerRegionUpdater'
./scripts/perf-scroll/verify_row_click.sh <app> 260
```

`verify_row_click.sh` is the functional gate for anything that touches the row's activation
surface: a real click must put the row's content on the app's pasteboard and close the panel.

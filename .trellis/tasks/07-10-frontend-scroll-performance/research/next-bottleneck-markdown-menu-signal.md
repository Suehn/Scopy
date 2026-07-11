# Next Bottleneck: Markdown Menu Fast-Signal Rescan

## Evidence

After the passive-row architecture and P1 fixes passed, a fresh 8-second `sample` capture was taken during the actual Release fixed-warm current path. Raw evidence is retained at:

- `logs/perf-next-bottleneck-2026-07-11_04-40/scopy-live.sample.txt`
- `logs/perf-next-bottleneck-2026-07-11_04-40/fixed-warm-text-current.json`

The matching profile completed 1,440 commands and 51,270px observed work. It recorded 1,148 row bodies at `1.9995ms` average. In the main-thread sample:

- 457 samples entered `HistoryItemView.body`.
- 421 entered `HistoryItemView.rowContent`.
- 418 entered SwiftUI context-menu construction.
- 411 entered `HistoryItemView.canOfferPNGExport`.

Thus about 90% of sampled row-body work was under the PNG-export menu predicate, not descriptor or relative-time cache misses.

## Root Cause

`HistoryItemMarkdownExportController.canOfferPNGMenuItem` first checks the exact Markdown capability cache. When exact capability is absent, it calls `MarkdownDetector.hasFastMarkdownSignal` directly. The fast result is intentionally not stored in the exact capability cache, but no separate cache exists, so every row body repeats multiple Foundation substring searches across up to 4,096 characters.

This is a stable presentation predicate for one `ClipboardItemContentRevision`; recomputing it during every body is unnecessary.

## Decision

Add a separate bounded `markdownMenuSignalCache` keyed by `ClipboardItemContentRevision`:

- Keep it semantically separate from the exact Markdown export capability cache.
- Preserve exact capability precedence when available.
- Compute the fast signal once on miss and cache both `true` and `false`.
- Extend existing presentation prewarm to compute the menu signal off the main actor for text/RTF/HTML items.
- Clear, generation-guard, and trim it with the other presentation caches.
- Add hit/miss/uncached counters and miss timing so measurement can prove the scan left the row-body hot path.
- Retain a test-only feature flag for same-binary causal A/B; production defaults to enabled.

## Measurement Contract

Extend the existing fixed-warm script with a `markdown-menu-cache` axis:

- Both variants keep passive rows enabled.
- Only `SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE` changes.
- Keep Release, 50 text rows, 4,096 characters, two warm rounds, 1,440 × 36px commands, equal observed work, and AB/BA ordering.
- Current must have menu-signal cache hits with zero measurement misses; baseline must exercise the uncached scan.
- Primary metric is row-body total ms/s; main-run-loop busy time remains the broader pressure guard.

## Rejected Alternatives

- Storing the fast result in the exact capability cache would change semantics and could incorrectly present a heuristic as an exact export decision.
- Removing the context menu or evaluating it only after a hover would risk keyboard/accessibility behavior.
- Optimizing revision hashing first is not supported by the trace; it was not the dominant row-body stack.

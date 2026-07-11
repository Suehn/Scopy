# Final Audit Gaps Reopened On 2026-07-11

## Why The Task Returned To Execute

The first final verification found that green build/test commands did not prove several PRD invariants. The task remains in progress until the correctness races and final-source evidence gaps below are closed.

## Product Correctness

1. Image optimization snapshots an item, suspends for compression, and then updates the row by ID. The persistence update is not compare-and-swap, and the external-file path mutates the current payload before ownership is revalidated. A same-ID replacement can therefore be overwritten.
2. Markdown export checks the content revision only after `MarkdownExportService` has already written PNG data to the pasteboard. Rejecting stale feedback after the side effect is insufficient.
3. `HistoryItemView` tears down its interaction state unconditionally on disappearance. List virtualization can therefore cancel or discard explicit note, export, or optimization work even though idle rows must remain passive without destroying user-owned work.
4. `ScrollPerformanceProfile` creates one main-actor task per static metric event and finalizes immediately when the fixed workload completes. Already-queued pre-completion events can observe the completed flag and be rejected instead of drained.

## Evidence And Harness

1. The five-pair passive-row artifact predates later product/harness edits. The final-source passive-row rerun has only two pairs and 360 commands; a final five-pair run is still required.
2. The passive-row script gates medians but does not enforce all-pair improvement. The menu-cache axis has the stronger all-pair gate.
3. Relative-time misses are extracted but not gated; maximum active/candidate gauges and descriptor-cache gates are incomplete.
4. The fixed mock workload records configuration values but does not fingerprint the generated row identities/content. UUIDs and timestamps are regenerated, and sample rows are not all identical 4,096-character payloads.
5. Integrated UI coverage does not yet prove stationary hover restoration and real vertical/horizontal scroller routing through the production list observer.

## Full Composite Profile

`logs/perf-frontend-profile-2026-07-11_09-51-16` completed three 10-second repeats per variant. The text-biased main-run-loop p95 improved in repeats 1 and 2 and regressed in repeat 3; aggregate long-frame count improved `326 -> 258`, while callback over-threshold ratio worsened at the medians. The harness disables five older feature flags together and keeps passive rows/menu caching enabled on both sides, so this is broad unresolved variance rather than causal evidence for the current task.

## Required Closure

- Add optimistic concurrency and pre-side-effect authorization with deterministic same-ID race tests.
- Retain explicit user-owned row sessions across virtualization without restoring idle-row fan-out.
- Serialize/drain profiler events before final output.
- Harden fixed-workload dataset identity and all-pair/structural gates.
- Run focused product/UI tests, then build, unit, strict, TSan, snapshot backend, both five-pair AB/BA axes, real-snapshot profiles, unified table, docs, and release validation from final source.

## Second Adversarial Audit — 2026-07-11

The first correctness slice closed the original image-CAS, pasteboard-authorization,
virtualization-retention, and profiler-drain defects and passed 46 focused tests plus the
613-test unit suite. A separate read-only audit found no new P0, but reopened the following P1
boundaries before final profiling:

1. A filtered/search result projection must not be treated as authoritative deletion of an
   off-screen action session. Revision ownership needs an item registry invalidated by real
   delete/clear events, not absence from the current page.
2. Dirty note drafts must survive payload-only revision changes, and Save must retain the draft
   until asynchronous persistence reports success.
3. View-owned hover/preview callbacks need appearance plus attachment-generation liveness so a
   recycled old row cannot mutate the newly attached row's shared explicit-action session.
4. Long-running export must not overwrite a pasteboard changed after the command began; success
   dumps must be written only after an authorized pasteboard commit, and every failure must leave
   auditable error evidence.
5. Markdown export, image optimization, pngquant processes, and profiler ingress require hard
   concurrency/memory/time bounds with deterministic cancellation or timeout behavior.
6. Post-CAS search/event publication must revalidate the current payload and must not emit an
   older full DTO after a newer payload or deletion wins during an awaited publication step.

These are implementation blockers, not caveats to be waived in release notes. Both fixed A/B axes
and every real-snapshot profile remain stale until the P1 slice and its focused tests are complete.

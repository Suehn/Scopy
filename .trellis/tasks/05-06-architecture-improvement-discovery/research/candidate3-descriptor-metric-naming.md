# Research: Candidate 3 descriptor metric naming

- Query: Should the descriptor production path keep the existing `row.display_model_ms` metric name around `HistoryItemRowDescriptor` construction for profile continuity, or should the extraction rename it to a new metric such as `row.descriptor_ms` and update perf analysis scripts/docs in the same slice?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: keep the existing `row.display_model_ms` metric name for the first `HistoryItemRowDescriptor` extraction. Treat the new descriptor as the same measured row-presentation preparation phase, not a new performance bucket.

The extraction is behavior-preserving and mostly moves the previous display-model derivation into a dedicated `Scopy/Presentation` type. Renaming the metric in the same slice would mix a semantic refactor with observability churn, break historical profile continuity, and require script/docs/test updates that do not improve the Module boundary. A comment near the metric or a research/spec note can explain that `row.display_model_ms` now measures descriptor construction.

The current worktree already reflects this direction: `HistoryItemRowDescriptor` exists in `Scopy/Presentation`, and its initializer records `row.display_model_ms` around descriptor construction. `HistoryItemView` stores a `HistoryItemRowDescriptor` and uses it for app icon request identity, text, preview fields, thumbnail flags, and layout height. This research records that as the recommended decision, not as an additional code change.

Architecture vocabulary reading:

- Module: the Module name can change from display model to row descriptor while the measured work remains row presentation preparation.
- Interface: metric names are an observability Interface consumed by scripts, tests, logs, and release/perf comparisons. Keep that Interface stable unless the measured semantics genuinely change.
- Implementation: moving code from a private view-local display model into `HistoryItemRowDescriptor` is an Implementation relocation. The metric should follow the work, not the old type name.
- Depth: preserving the metric name lets the first slice deepen code structure without making performance tooling shallower or noisier.
- Seam: the useful seam is between row rendering and descriptor derivation. Renaming the metric would create a second seam in perf tooling with no product or architecture payoff.
- Adapter: `HistoryItemRowDescriptor` is an Adapter over DTO/settings/presentation caches. The existing `row.display_model_ms` bucket should adapt to the new code owner during this transition.
- Leverage: keeping the name preserves existing perf scripts, unified tables, long-frame attribution summaries, and tests, so the implementation can use the same gates before/after.
- Locality: code ownership moves to `Scopy/Presentation`; observability ownership stays local to the existing frontend perf pipeline.

Next one-question grilling prompt:

Is Candidate 3 now sufficiently specified for a check pass on the current uncommitted `HistoryItemRowDescriptor` implementation, or should one more grilling question decide whether `HistoryItemView` should receive a descriptor directly for tests/previews instead of constructing it internally?

Concrete tests and perf gates:

- Keep or add unit coverage that proves `ScrollPerformanceProfile` long-frame attribution still recognizes `row.display_model_ms`.
- Run `make build`, `make test-unit`, and `make test-strict` for the descriptor extraction.
- Run `make perf-frontend-profile` as the descriptor slice smoke guard because row construction and row/body buckets are touched.
- Use `make perf-frontend-profile-standard` before commit-level confidence if `row.display_model_ms`, `swiftui.row_body_ms`, `row.file_preview_ms`, or long-frame attribution changes materially.
- If a later slice intentionally renames to `row.descriptor_ms`, update `scripts/perf-frontend-profile.sh`, `scripts/perf-unified-table.sh`, `ScopyTests/ScrollPerformanceTests.swift`, release profile docs, and any comparison baselines in one coordinated change.

Evidence that would change the answer:

- The descriptor starts measuring substantially different work than the old display model, for example async loading, icon lookup, thumbnail scheduling, or non-row presentation batching.
- The perf pipeline gains a metric alias/migration mechanism that can display historical `row.display_model_ms` and new `row.descriptor_ms` as one continuous series.
- Product/release docs explicitly decide to start a new performance baseline for Candidate 3.
- Keeping the old name causes repeated maintainer confusion even with a nearby comment and research/spec note.
- The implementation splits old display-model work into multiple separately useful buckets; in that case a broader metric design should be grilled instead of a one-name rename.

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:115 - Candidate 3 is the row asset and preview pipeline Module candidate.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:9 - Prior Candidate 3 research limits the first slice to a row-ready descriptor.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-placement.md:40 - Prior placement research raised the metric naming question for this grilling step.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:11 - Implement context currently includes the descriptor placement research.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:11 - Check context currently includes the descriptor placement research.
- .trellis/spec/frontend/component-guidelines.md:19 - History row work is performance-sensitive and should stay behind caches/controllers/profile hooks.
- .trellis/spec/frontend/quality-guidelines.md:29 - Scroll/render/thumbnail/preview performance changes require frontend perf profiling.
- .trellis/spec/frontend/quality-guidelines.md:42 - UI performance claims need profiler output, not subjective smoothness.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:7 - Current worktree has an internal `HistoryItemRowDescriptor`.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:40 - Current descriptor initializer starts timing construction when profiling is enabled.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:44 - Current descriptor records `row.display_model_ms`.
- Scopy/Views/History/HistoryItemView.swift:79 - Current `HistoryItemView` stores a `HistoryItemRowDescriptor`.
- Scopy/Views/History/HistoryItemView.swift:126 - Current `HistoryItemView` constructs the descriptor in init.
- Scopy/Views/History/HistoryItemView.swift:531 - Current row icon lookup uses `descriptor.appIconBundleID` while leaving `IconService` in the row.
- Scopy/Views/History/HistoryItemView.swift:734 - Current row layout reads `descriptor.needsThumbnailHeight`.
- ScopyTests/HistoryItemRowDescriptorTests.swift:8 - Current worktree has focused descriptor tests.
- ScopyTests/HistoryItemRowDescriptorTests.swift:23 - Current tests instantiate the descriptor with injectable dependencies.
- ScopyTests/ScrollPerformanceTests.swift:241 - Existing long-frame attribution tests use `row.display_model_ms` as a metric event.
- ScopyTests/ScrollPerformanceTests.swift:282 - Existing tests assert `row.display_model_ms` appears in attribution output.
- scripts/perf-frontend-profile.sh:185 - The frontend profile script lists metric bucket keys.
- scripts/perf-frontend-profile.sh:186 - The frontend profile script directly consumes `row.display_model_ms`.
- scripts/perf-frontend-profile.sh:507 - The markdown summary prints `row.display_model_ms.p95`.
- scripts/perf-unified-table.sh:207 - The unified performance table maps `row.display_model_ms` into `frontend.row.display_model.p95_ms`.
- logs/perf-frontend-profile-final-autoscroll-2026-05-01_21-28-27/frontend-scroll-profile-summary.md:21 - Existing profile summaries report `row.display_model_ms.p95`.
- logs/perf-frontend-profile-final-autoscroll-2026-05-01_21-28-27/frontend-scroll-profile-summary.md:99 - Existing long-frame attribution summaries include `row.display_model_ms`.
- logs/perf-unified-2026-04-30_23-29-33.md:34 - Existing unified perf artifacts report `frontend.row.display_model.p95_ms`.

Code patterns:

- The profiling pipeline treats metric names as stable data keys: source emits `row.display_model_ms`, frontend profile aggregation buckets it, markdown summaries print it, unified tables map it, and tests assert attribution includes it.
- Current `HistoryItemRowDescriptor` keeps descriptor construction synchronous and value-like, so the old display-model metric still describes the same kind of row preparation work.
- Existing Candidate 3 decisions deliberately exclude icon loading, thumbnail async scheduling, `NSImage`, `Task`, and scroll coordinator state from the descriptor. That keeps the measured work close enough to the old display model to preserve the metric.
- Renaming would require synchronized script/test/log-baseline documentation changes and would reduce before/after comparability for a behavior-preserving architecture slice.
- If maintainers want clearer terminology, prefer comments or docs first; reserve a metric rename for a deliberate observability migration.

External references:

- None. This research is based on repository code, Trellis specs, task research, current worktree evidence, and existing local perf artifacts. No new Apple API or third-party API is proposed.

Related specs:

- .trellis/spec/frontend/index.md
- .trellis/spec/frontend/component-guidelines.md
- .trellis/spec/frontend/quality-guidelines.md
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-icon-scope.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-placement.md

## Caveats / Not Found

- I did not run new tests or benchmarks in this research pass.
- The worktree already contains uncommitted `HistoryItemRowDescriptor` implementation and tests. I treated those files as current evidence but did not modify them.
- I did not find an alias/migration layer that would let `row.display_model_ms` and `row.descriptor_ms` be reported as one continuous metric series.
- Existing logs contain historical `row.display_model_ms` data; renaming now would make comparisons noisier unless every consumer is updated together.

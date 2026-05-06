# brainstorm: search planner maintainability

## Goal

Improve Scopy search maintainability by deepening the internal search path planning module while preserving the current public search interface and user-visible behavior. The first goal is locality: make mode/path/fallback decisions easier to understand, test, and evolve before attempting behavior or performance changes.

## What I already know

* The user chose candidate 2: Search planner Module.
* The user chose maintainability first: split internal planner behavior while keeping existing behavior unchanged.
* `SearchEngineImpl.search(request:)` should remain the external interface for callers.
* Current search behavior includes Exact, Fuzzy, Fuzzy+, Regex, short-query recent-only handling, staged fuzzy refine, full-index paths, FTS paths, SQL fallback paths, timeout/cancellation, and metrics.
* Current release baseline is `v0.7.5`; recent releases already improved fuzzy top-K reuse and frontend row presentation caching.

## Assumptions (temporary)

* No user-visible search semantics should change in the first implementation pass.
* The planner should be an internal seam first, not a new public protocol or package-level interface.
* Performance changes are allowed only if they naturally fall out of preserving equivalent path decisions; deliberate optimization belongs to a follow-up step.
* The existing performance and search test suite should be used as the behavior preservation guard.
* Confirmed decision: the first seam is a decision-only planner. It should choose and explain the path, but it should not execute SQL, own SQLite connections, mutate caches, or replace existing search execution methods in the first pass.
* Confirmed decision: each decision-only plan should be explainable and carry `path`, `coverage`, `reason`, and `requiredCapabilities`; it must not carry executable closures, SQL fragments, or runner objects in the first pass.
* Confirmed decision: use two-layer explainability. Stable `reason` and `requiredCapabilities` describe public/core search concepts for tests and maintenance; optional diagnostics can record volatile internal branch facts for debugging and performance attribution without becoming the primary test contract.
* Confirmed decision: first planner scope covers top-level mode dispatch plus the main fuzzy and short-query path choices. It should include empty-query handling, Exact short-query recent-only, Regex recent-only, Fuzzy/Fuzzy+ staged versus full paths, Fuzzy+ substring-only fallback, and short-query full-index/short-index/SQL-fallback path selection. It should not attempt to model the complete SQL fallback tree in the first pass.
* Confirmed decision: use staged shadow-then-execute integration. The first pass adds the decision-only planner, parity-focused tests, and optional diagnostics while existing `SearchEngineImpl` branches remain responsible for execution. A later pass may dispatch through the plan after parity is trusted.
* Confirmed decision: first-pass parity tests should cover eight representative decisions without Cartesian expansion: empty query -> all-with-filters; Exact short query <=2 -> recent-only cache; Exact long query >=3 -> FTS; Regex -> recent-only regex; Fuzzy long query without staged shortcut -> full-index fuzzy; Fuzzy+ forced full with long ASCII tokens -> substring-only fallback; Fuzzy/Fuzzy+ short query with full index ready -> full-index short-query; Fuzzy/Fuzzy+ short query without indexes ready -> short-index-or-SQL-fallback.

## Open Questions

* None for now; the minimum parity test set is confirmed below.

## Requirements (evolving)

* Preserve `SearchEngineImpl.search(request:)` as the caller-facing interface.
* Preserve existing `SearchCoverage`, `SearchResult`, sorting, paging, recent-only, staged-refine, fallback, timeout, and cancellation behavior.
* Concentrate search path decision logic so future maintainers can inspect why a request used FTS, full index, short-query index, cache, recent-only, or SQL fallback.
* Keep the planner test surface focused on decisions and invariants rather than requiring UI-level tests.
* Avoid introducing a speculative external seam with only one adapter.
* The first planner output should be inspectable enough for focused unit tests, while `SearchEngineImpl` remains responsible for executing the selected existing path.
* Planner tests should be able to assert the selected `path`, expected `coverage`, and the explanation signals without depending on database execution details.
* Planner tests should prefer the stable explanation layer; diagnostics are allowed for targeted regression tests but should not make ordinary path tests brittle.

## Acceptance Criteria (evolving)

* [ ] Existing build and unit test gates pass.
* [ ] Existing search behavior tests pass without weakening expectations.
* [ ] New or updated tests prove representative planner decisions without hitting every database path through UI state.
* [ ] Parity tests cover the eight confirmed representative decisions and avoid unnecessary app/type/sort/ASCII/candidate-count Cartesian expansion.
* [ ] Search performance release gate does not regress beyond normal noise.
* [ ] No user-visible search behavior change is documented as part of the first pass.

## Definition of Done (team quality bar)

* Tests added/updated where appropriate.
* `make build` passes.
* `make test-unit` passes.
* `make test-strict` passes if concurrency/cancellation paths are touched.
* `make test-snapshot-perf-release` passes if search engine internals are changed.
* Docs/notes updated only if the architecture contract changes.
* Rollback is straightforward because the external search interface is preserved.

## Out of Scope (explicit)

* Changing search ranking semantics.
* Changing Exact short-query recent-only limits.
* Changing Regex recent-only behavior.
* Adding semantic search or embeddings.
* Replacing SQLite/FTS.
* Rewriting `HistoryViewModel` search session flow in this task.
* Public plugin-style search adapters.
* Full modeling of every internal SQL/FTS/non-ASCII/candidate-count fallback branch in the first planner pass.

## Technical Notes

* `Scopy/Infrastructure/Search/SearchEngineImpl.swift` contains the current search entrypoint, timeout/cancellation wrapper, metrics, mode dispatch, FTS, full-index, short-query, and SQL fallback logic.
* `Scopy/Domain/Models/SearchRequest.swift`, `SearchResultPage.swift`, `SearchCoverage.swift`, `SearchMode.swift`, and `SearchSortMode.swift` define the caller-visible contract.
* `Scopy/Observables/HistoryViewModel.swift` depends on search coverage and staged refine behavior, so planner extraction must preserve those states exactly.
* Relevant validation commands from project guidance include `make build`, `make test-unit`, `make test-strict`, and `make test-snapshot-perf-release` for search/performance internals.

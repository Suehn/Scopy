# Search Guidelines

> Contracts for Scopy search planning, execution parity, fallback behavior, and verification.

---

## Scenario: Decision-Only Search Planner

### 1. Scope / Trigger

Use these rules when changing search path selection in `Scopy/Infrastructure/Search/`, especially `SearchEngineImpl` and `SearchPlanner`.

The first planner pass is a maintainability seam only. It may explain the selected path, but existing search execution methods remain responsible for SQL, FTS, cache, full-index, timeout, cancellation, sorting, paging, and coverage behavior.

### 2. Signatures

- Planner entrypoint: `SearchPlanner.plan(request: SearchRequest, state: SearchPlanner.State) -> SearchPlan`.
- State input: `SearchPlanner.State(fullIndexReady:shortQueryIndexReady:prefersFTSForFuzzy:shortQueryCacheLimit:)`.
- Plan output fields: `path`, `coverage`, `reason`, `requiredCapabilities`, `diagnostics`.
- Search entrypoint remains `SearchEngineImpl.search(request:)`; callers must not use `SearchPlanner` as a public adapter or execution API.

### 3. Contracts

- `SearchPlan.path` is the stable path identity for tests and maintenance notes.
- `SearchPlan.reason` and `requiredCapabilities` are the stable explanation layer.
- `diagnostics` may include volatile branch facts, but ordinary path tests should not depend on diagnostics.
- `SearchPlanner` must not own SQLite connections, execute SQL, mutate caches, build runner closures, or change search result semantics.
- If planner and engine need the same predicate or tokenization rule, put that pure helper on `SearchPlanner` and make `SearchEngineImpl` delegate to it.

### 4. Validation & Error Matrix

| Condition | Required handling |
| --- | --- |
| Empty query | Plan `allWithFilters`; execution preserves existing all-items-with-filters path |
| Exact query length <= 2 | Plan recent-cache coverage with the existing short-query limit |
| Exact query length >= 3 and valid FTS query | Plan complete FTS coverage |
| Regex mode | Plan recent-only regex coverage |
| Fuzzy/Fuzzy+ long query with staged FTS shortcut | Plan staged refine with FTS + interactive refine capabilities |
| Fuzzy+ forced full with long ASCII tokens | Plan substring-only fallback using the same token predicate as execution |
| Short fuzzy query | Prefer full index when ready, then short-query index, then index-or-SQL fallback |
| Planner explanation diverges from execution predicate | Treat as a bug; share the pure predicate/helper and add or update focused tests |

### 5. Good/Base/Bad Cases

- Good: `SearchEngineImpl` records planner path/reason for attribution, then continues to call the existing execution branch.
- Base: planner tests assert representative path, coverage, reason, and capabilities without opening a database.
- Bad: planner carries SQL fragments or closures, or duplicates execution predicates that can drift over time.

### 6. Tests Required

- Add focused unit tests for representative planner decisions, not a Cartesian product of every app/type/sort combination.
- Cover empty query, Exact short, Exact long FTS, Regex recent-only, fuzzy full-index path, staged fuzzy prefilter, Fuzzy+ substring-only fallback, and short-query fallback behavior.
- After touching search internals, run `make build`, `make test-unit`, and `make test-snapshot-perf-release`.

### 7. Wrong vs Correct

#### Wrong

```swift
// Planner and engine each define their own copy of the fallback predicate.
let plannerFallback = tokens.allSatisfy { $0.count >= 3 && $0.canBeConverted(to: .ascii) }
let engineFallback = tokens.allSatisfy { $0.count > 2 && $0.canBeConverted(to: .ascii) }
```

#### Correct

```swift
let tokens = SearchPlanner.fuzzyPlusTokens(trimmedQuery.lowercased())
guard SearchPlanner.shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: tokens) else { return nil }
```

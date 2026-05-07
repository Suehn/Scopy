# Research: Quality Tooling Architecture

- Query: Identify Scopy maintainability, testing, observability, and tooling architecture opportunities that reduce future regression risk without changing product behavior.
- Scope: internal
- Date: 2026-05-07

## Findings

### Files found

- `.trellis/tasks/05-07-architecture-quality-deepening/prd.md` - task source of truth; requires at least three candidates, architecture vocabulary, tests, and evidence-backed selection.
- `.trellis/workflow.md:5` - Trellis principle that research, decisions, and lessons must be persisted because conversations get compacted.
- `.trellis/workflow.md:230` - Phase 1.2 research requires persisted output under `{TASK_DIR}/research/`.
- `.trellis/spec/backend/quality-guidelines.md:27` - backend verification gate matrix for build, unit, strict/TSan, snapshot perf, and release validation.
- `.trellis/spec/frontend/quality-guidelines.md:17` - frontend verification gate matrix for UI, settings, list/history, scroll/render/thumbnail/preview, and hotkey work.
- `.trellis/spec/frontend/quality-guidelines.md:42` - performance claims must use profiler output and real snapshot DB flows for large history behavior.
- `.trellis/spec/backend/logging-guidelines.md:7` - observability source of truth is `ScopyLog` categories with privacy rules.
- `Makefile:73` - unit/perf/snapshot targets write separate logs, but there is no single command-level evidence manifest.
- `Makefile:127` - release snapshot perf gate parses JSONL p95 and enforces thresholds.
- `Makefile:162` - local TSan target can print `SKIPPED` for known bad macOS/Xcode combinations without a structured skip status.
- `Makefile:317` - frontend profile tiers exist for smoke, standard, and full evidence.
- `Makefile:332` - unified perf table requires caller-supplied backend and frontend artifact paths.
- `scripts/perf-frontend-profile.sh:1` - frontend profile script is the current Module for realistic scroll/profile benchmark orchestration.
- `scripts/perf-frontend-profile.sh:121` - baseline/current variants are hard-coded feature-flag Adapters around the same UI tests.
- `scripts/perf-frontend-profile.sh:182` - an embedded Python summarizer parses raw JSON and builds the profile summary.
- `scripts/perf-frontend-profile.sh:198` - frontend metric key list is duplicated in shell-embedded Python rather than shared with the Swift producer.
- `scripts/perf-frontend-profile.sh:344` - summary schema is built dynamically in Python.
- `scripts/perf-frontend-profile.sh:483` - the script writes `frontend-scroll-profile-summary.json`.
- `scripts/perf-frontend-profile.sh:573` - the script also writes Markdown evidence.
- `scripts/perf-unified-table.sh:1` - unified table generator consumes backend audit and frontend profile artifacts as separate inputs.
- `ScopyUISupport/ScrollPerformanceProfile.swift` - Swift producer for frame, runloop, long-frame, bucket, accessibility, and summary data.
- `ScopyUITests/HistoryListUITests.swift:13` - UI test harness forwards a small set of perf feature flags into the app.
- `ScopyUITests/HistoryListUITests.swift:157` - profile scenarios are represented as separate XCTest methods.
- `scripts/test-flow.sh:1` - full real-app smoke flow builds, installs, launches, and runs health checks.
- `scripts/health-check.sh:22` - health checks are process/log/database/hotkey/memory shell checks with warning/pass text output.
- `doc/current/release-runbook.md:57` - local TSan skip is documented as known-bad, with hosted TSan as the real-coverage path.
- `doc/releases/CHANGELOG.md:14` - current v0.7.6 release evidence records frontend profile isolation and recent validation results.

### Candidate 1 - Verification Evidence Manifest Module

**Rank: 1 / first implementation recommendation.**

**Files / Modules**

- `Makefile:73`, `Makefile:127`, `Makefile:162`, `Makefile:185`, `Makefile:317`, `Makefile:332`
- `scripts/release/validate-release-docs.sh:1`
- `scripts/docs/validate-docs.sh:73`
- `doc/current/release-runbook.md:57`
- `.trellis/spec/backend/quality-guidelines.md:27`
- `.trellis/spec/frontend/quality-guidelines.md:17`

**Problem**

Scopy has many useful gates, but the Interface is the human shape of each command: log file names, stdout text, and scattered doc notes. The Implementation for each target decides its own artifact format and skip semantics. That makes future architecture/performance work vulnerable to weak claims such as "ran tests" without a machine-readable statement of command, status, artifact paths, environment, thresholds, and known skips. `make test-tsan` is the sharpest example: known local skip is legitimate, but today it is a log line rather than a typed outcome at `Makefile:162`.

**Solution**

Add a small tooling-only Module, for example `scripts/quality/record-gate-result.py` plus a `make quality-manifest` or wrapper target. Its Interface should be deliberately narrow:

1. record one gate result: command, started/ended timestamps, exit status, status enum `passed|failed|skipped|not_run`, log/artifact paths, key metrics, environment facts, skip reason.
2. read one or more records and emit a single `logs/quality-manifest-<timestamp>.json` plus Markdown summary.
3. validate required gate sets from a task-supplied profile, for example baseline gates `make build`, `make test-unit`, `make test-strict`, optional `make test-tsan`, and perf gates when selected.

The first Adapter can wrap only a few existing commands, starting with `build`, `test-unit`, `test-strict`, and `test-tsan`. The second Adapter can ingest existing perf artifacts from `test-snapshot-perf-release` and `perf-frontend-profile` after the shape is stable.

**Benefits**

- Depth: one small Interface hides repeated evidence parsing and lets future tasks ask "is the gate set complete?" instead of manually reading logs.
- Locality: skip policy for known TSan environments lives with the evidence record rather than being re-explained in every release note.
- Leverage: Trellis completion audits can cite one manifest artifact and still point to raw logs for detail.
- Regression risk reduction: prevents false-positive quality closure when a command was skipped, failed before summary generation, or produced missing artifacts.

**Risks**

- Wrapper churn can annoy developers if it replaces familiar `make` targets. Keep existing targets and add manifest recording as an opt-in or aggregate target first.
- A manifest can become paperwork if it only records command names. The useful part is structured status, artifact existence, threshold values, and skip reasons.
- Do not make this a release process rewrite. It is a Seam around evidence collection, not a new release workflow.

**Tests / perf verification**

- Add focused tests for the manifest writer using fixture logs and explicit skip cases.
- Run `make build`, `make test-unit`, and `make test-strict` after adding the wrapper.
- For the first implementation, run the new manifest command over at least one passing command and one synthetic skip fixture. If it later wraps perf gates, verify `make test-snapshot-perf-release` still enforces p95 thresholds at `Makefile:142`-`Makefile:146`.

### Candidate 2 - Frontend Profile Schema Module

**Rank: 2.**

**Files / Modules**

- `scripts/perf-frontend-profile.sh:1`
- `scripts/perf-frontend-profile.sh:121`
- `scripts/perf-frontend-profile.sh:182`
- `scripts/perf-frontend-profile.sh:198`
- `scripts/perf-frontend-profile.sh:344`
- `scripts/perf-frontend-profile.sh:483`
- `scripts/perf-frontend-profile.sh:573`
- `scripts/perf-unified-table.sh:1`
- `ScopyUISupport/ScrollPerformanceProfile.swift`
- `ScopyUITests/HistoryListUITests.swift:13`
- `ScopyUITests/HistoryListUITests.swift:157`
- `doc/releases/CHANGELOG.md:73`

**Problem**

The frontend profile pipeline is valuable, but the Interface between the Swift producer, UI test harness, shell orchestrator, embedded Python summarizer, and unified table is broad. Metric names such as `row.display_model_ms`, `swiftui.row_body_ms`, and `main_runloop_active_ms` are effectively a schema, but today that schema is partly implicit in `ScopyUISupport/ScrollPerformanceProfile.swift` and partly duplicated in `scripts/perf-frontend-profile.sh:198`. The unified table then consumes whichever summary path the caller provides at `Makefile:332`. That increases drift risk when future performance work adds, renames, or stops emitting a metric.

**Solution**

Create a Profile Schema Module that defines the metric keys, summary fields, and required scenarios in one place. Two viable shapes:

1. Swift-owned schema exported through the existing UI-support target, with the shell/Python summarizer validating against a generated JSON schema.
2. Tooling-owned JSON schema under `scripts/perf/profile-schema.json`, with Swift tests asserting the producer emits required keys and Python validating raw/summary files.

Keep the Implementation small at first: validate raw run JSON before summary aggregation, fail when required scenarios are missing, and report missing metric keys as `not_emitted` rather than silently producing `null`.

**Benefits**

- Depth: callers depend on named profile concepts rather than remembering where each metric is emitted.
- Locality: adding or deprecating a frontend metric happens at one schema Seam, then producer/summarizer/tests follow.
- Leverage: future scroll/thumbnail/preview changes get stronger evidence without reworking the whole harness.
- Better AI-navigability: agents can inspect the schema to know which metrics are stable contract versus experimental diagnostics.

**Risks**

- Over-specifying every diagnostic metric could slow iteration. Only stable summary metrics should be required; experimental buckets can stay optional.
- Schema validation may fail old logs. Treat old artifacts as historical and validate only newly generated runs unless migration is needed.
- This should not reopen the v0.7.6 row descriptor / thumbnail scheduler work unless fresh profile data points there.

**Tests / perf verification**

- Add unit tests for schema validation with fixture raw profile JSON.
- Add a focused shell or Python test that a missing required scenario fails before Markdown generation.
- Run `make perf-frontend-profile` as the smoke check. For changes to summary inputs consumed by release evidence, run `make perf-frontend-profile-standard` and `make perf-unified-table`.

### Candidate 3 - Runtime Health Check Result Module

**Rank: 3.**

**Files / Modules**

- `scripts/test-flow.sh:1`
- `scripts/test-flow.sh:134`
- `scripts/test-flow.sh:155`
- `scripts/test-flow.sh:181`
- `scripts/health-check.sh:22`
- `scripts/health-check.sh:35`
- `scripts/health-check.sh:68`
- `scripts/health-check.sh:93`
- `scripts/health-check.sh:114`
- `.trellis/spec/backend/logging-guidelines.md:7`
- `.trellis/spec/backend/logging-guidelines.md:30`
- `.trellis/spec/backend/logging-guidelines.md:44`

**Problem**

The real-app smoke flow is useful because it exercises installation and launch, but the Interface is plain stdout with emojis and warnings. Some warnings still produce success, such as "Hotkey status unknown" in `scripts/health-check.sh:109`, while memory threshold and log scanning are shell-local heuristics. This makes the Module shallow: each check's result semantics live in its Implementation text and cannot be consumed by Trellis, release notes, or CI without brittle parsing.

**Solution**

Split health checks into a result-producing Module:

- Interface: `health-check --json --strict=<profile>` emits typed checks with status `passed|warning|failed|skipped`, evidence fields, and remediation text.
- Implementation: existing shell checks can remain initially, but each check returns a structured record before rendering human text.
- Adapter: `scripts/test-flow.sh` can call the JSON mode and decide whether warnings fail under a release or smoke profile.

This is not about adding new runtime probes. It is about making existing probes composable and less ambiguous.

**Benefits**

- Depth: one health-check Interface supports human output, test-flow decisions, and future manifest ingestion.
- Locality: process/log/database/hotkey/memory heuristics live in one structured result shape.
- Leverage: launch/install regressions become easier to diagnose and cite in a task completion audit.
- Privacy alignment: structured fields can avoid storing raw clipboard/log content while still recording counts, categories, and status.

**Risks**

- Real-app smoke checks can be environment-sensitive; strict mode must distinguish product failures from missing permissions or first-run no-DB states.
- Installing to `/Applications` remains destructive to the user's current app state; keep this outside default build/test gates.
- Should not duplicate XCTest UI coverage. Use it for deployed-app sanity and health telemetry only.

**Tests / perf verification**

- Add shell/Python fixture tests for JSON output and warning-vs-failure policy.
- Run `make health-check` against a launched app if environment permits.
- Keep normal code gates unchanged: `make build`, `make test-unit`, and `make test-strict` for any script-to-code integration.

### Candidate 4 - Search/Performance Attribution Contract Extension

**Rank: 4.**

**Files / Modules**

- `.trellis/spec/backend/search-guidelines.md:7`
- `.trellis/spec/backend/search-guidelines.md:22`
- `.trellis/spec/backend/search-guidelines.md:30`
- `.trellis/spec/backend/search-guidelines.md:49`
- `Makefile:127`
- `scripts/perf-search-warm-load.sh`
- `scripts/perf-audit.sh`
- `scripts/perf-unified-table.sh:1`
- `Scopy/Infrastructure/Search/SearchPlanner.swift`
- `ScopyTests/SearchPlannerTests.swift`
- `ScopyTests/SearchBackendConsistencyTests.swift`
- `doc/releases/CHANGELOG.md:206`

**Problem**

The Search Planner is already a good maintainability Seam: it explains path decisions without owning SQL or execution. The next weak point is attribution across planner path, backend counters, warm-load reason, and frontend summary. Release notes already care about warm-load reason and counters, but perf tools still require manual artifact selection and interpretation. Future search or large-history work can pass raw latency thresholds while changing the reason path in a risky way.

**Solution**

Extend the search/perf attribution contract, not the search execution Interface. Add stable output fields for planner path/reason, cache/index readiness, warm-load reason, and benchmark scenario metadata into the existing JSONL artifacts. Then let `perf-unified-table` include those fields as first-class columns. Keep `SearchEngineImpl.search(request:)` as the public execution entrypoint per spec; the new Adapter is perf/diagnostic output only.

**Benefits**

- Depth: the planner Interface already concentrates decision knowledge; exposing it in perf artifacts increases leverage without changing execution.
- Locality: performance regressions can be traced to path/reason/counter changes instead of only p95 deltas.
- Regression risk reduction: makes "fast for the wrong reason" and "threshold pass but path changed" visible.

**Risks**

- Search diagnostics can become noisy. Keep stable fields limited to planner path, reason, capabilities, cache/index readiness, and warm-load reason.
- Do not let diagnostic fields become a public app API.
- This candidate touches hotter paths and should probably wait until the tooling manifest/profile schema work is in place.

**Tests / perf verification**

- Extend SearchPlanner/SearchBackendConsistency tests to assert representative path/reason output.
- Run `make build`, `make test-unit`, and `make test-snapshot-perf-release`.
- Run `make perf-search-warm-load` and `make perf-unified-table` when adding unified columns.

## Code Patterns

- Existing gates already use `bash -o pipefail` around `xcodebuild | tee`, which is the right base for reliable status capture (`Makefile:77`, `Makefile:189`).
- Snapshot release perf parses JSONL p95 and enforces numeric thresholds in the target itself (`Makefile:142`-`Makefile:146`); this is a good pattern to preserve in a manifest Adapter rather than replacing with prose.
- Frontend profile has a real artifact pipeline: raw JSON, summary JSON, and summary Markdown are explicitly documented in the script help (`scripts/perf-frontend-profile.sh:41`-`scripts/perf-frontend-profile.sh:44`).
- Frontend profile currently uses feature-flag variants inside one build (`scripts/perf-frontend-profile.sh:128`-`scripts/perf-frontend-profile.sh:140`), so it is best interpreted as regression guardrail evidence rather than absolute product benchmarking.
- Frontend profile schema exists informally: the embedded Python list of bucket keys is the clearest sign of a missing deeper Module (`scripts/perf-frontend-profile.sh:198`-`scripts/perf-frontend-profile.sh:214`).
- Specs already encode risk-based gate routing for backend and frontend changes; a quality manifest should consume those contracts instead of inventing a parallel policy (`.trellis/spec/backend/quality-guidelines.md:29`-`.trellis/spec/backend/quality-guidelines.md:38`, `.trellis/spec/frontend/quality-guidelines.md:19`-`.trellis/spec/frontend/quality-guidelines.md:30`).
- Logging guidance distinguishes operationally safe public values from sensitive clipboard/query/file data (`.trellis/spec/backend/logging-guidelines.md:22`-`.trellis/spec/backend/logging-guidelines.md:26`), which should also shape structured health/manifest artifacts.

## Related Specs

- `.trellis/spec/backend/quality-guidelines.md` - required gate matrix and review checklist.
- `.trellis/spec/frontend/quality-guidelines.md` - UI/profile gate matrix and frontend profile isolation warning.
- `.trellis/spec/backend/logging-guidelines.md` - structured observability and privacy boundaries.
- `.trellis/spec/backend/search-guidelines.md` - Search Planner Interface and validation matrix.
- `.trellis/workflow.md` - persisted Trellis research and decisions.
- `doc/current/development-guide.md` - current development/test workflow.
- `doc/current/release-runbook.md` - release evidence and local TSan skip policy.

## External References

- No external references used. This research is intentionally internal because the requested candidates are Scopy-specific quality/tooling seams, and the relevant contracts are local Makefile/script/spec/release artifacts.

## Recommendation

Implement Candidate 1 first: Verification Evidence Manifest Module.

Reasoning: it has the best ratio of leverage to product risk. It does not change Scopy runtime behavior, can start with a small Interface around existing commands, and directly supports the PRD's completion-audit requirement. It also improves future implementation of Candidates 2-4 because frontend profile schema, health checks, and search attribution can all become manifest inputs later.

Second choice is Candidate 2 if the selected architecture task must stay closer to frontend performance. It is higher risk than Candidate 1 because it touches the profile pipeline used for current release evidence, but still product-behavior neutral.

## Caveats / Not Found

- No `CONTEXT.md` or ADR files were found in the initial task PRD notes, so architecture vocabulary comes from the `improve-codebase-architecture` skill and Trellis specs rather than a project glossary.
- I did not run build or test commands; this was a research-only pass.
- I did not inspect every test file. Scope was targeted at quality gates, perf/profile tooling, health checks, release validation, and known regression-risk areas.
- The line references above are current as of 2026-05-07 on the local checkout and may drift after implementation changes.

# Performance comparisons

Freeze the workload, binary identities and expected metric direction before the
quiet slot. Use separate Release builds: A is production-equivalent v0.85.0 and B
is the committed candidate. Record the Release build logs; a matching version
string alone does not prove build provenance.

`compare.py` is the common evidence rule. The schedule contains one discarded
warmup per side, three A/A pairs and three ABBA groups (five groups when the
expected effect is below 5%). Each observation is one whole run. Inner query
iterations are not independent runs. A missing, failed, reordered, unproven or
non-finite observation prevents a complete result. Keep every failed attempt.
Max-type metrics use the median of per-run maxima for the headline. Conclusions
follow the canonical development guide's A/A resolution and pooled-variation
rule; they apply only to the named workload.

## Engine comparison

`compare_search.py` freezes an offline database copy and the two ScopyBench
executables, then runs the existing cold-build, warm-query and disk-load paths.
It never starts ClipboardService or an app, so database payload references are
not dereferenced. A source with a nonempty WAL is rejected. Database preparation
creates sidecars only beside the copied file and verifies the database SHA.

```sh
python3 scripts/perf-scroll/compare_search.py \
  --baseline /path/to/A/ScopyBench --candidate /path/to/B/ScopyBench \
  --baseline-checkout /path/to/A/checkout --candidate-checkout /path/to/B/checkout \
  --baseline-build-log /path/to/A-release-build.log \
  --candidate-build-log /path/to/B-release-build.log \
  --snapshot /path/to/offline/clipboard.db \
  --output /tmp/scopy-search-comparison --prepare-only

# Run only after the coordinator grants a quiet slot.
python3 scripts/perf-scroll/compare_search.py \
  --run-plan /tmp/scopy-search-comparison/plan.json
```

The default corpus is declared as 10,000 rows; another count must be supplied
explicitly. `full_index_source_database`, `full_index_source_memory` or
`full_index_source_disk_cache` must prove the chosen path. Cold means the full
index is absent; it does not mean the OS file cache was flushed. The warm query
resets ranking with another query before each timed sample.

The process resource record covers startup, preparation, untimed resets and
shutdown as well as timed queries. It separates user CPU, kernel CPU, peak RSS,
faults and block-I/O operation counts. It does not calculate wait time by
subtracting CPU from wall time: parallel CPU may exceed wall duration. Peak
benchmark RSS is not real-app physical footprint. Full raw records remain under
`runs/`; summaries never print clipboard bodies or query results.

## Real-app export comparison

Build `axprobe` and `procstats` before the quiet slot. `compare_export.py` consumes
the existing E2E `Session.start(on_launch=...)` boundary: staged test bundle ID,
private preferences/home/storage/pasteboards and cleanup. It uses synthetic
Markdown fixtures with an empty storage root. No global clipboard is changed.

```sh
python3 scripts/perf-scroll/compare_export.py \
  --baseline /path/to/v0.85.0/Scopy.app --candidate /path/to/candidate/Scopy.app \
  --candidate-commit COMMIT \
  --fixture ScopyUITests/Fixtures/user_markdown_stress.md \
  --output /tmp/scopy-export-comparison
```

Use `--e2e-root /path/to/checkout/scripts/e2e` when consuming that boundary before
it is integrated. `--smoke` runs only the discarded warmups and cannot establish
a gain. PNG/private-pasteboard hashes must match, and every run must produce the
same PNG. A byte difference requires separate pixel/semantic adjudication before
the performance result is accepted.

The wall clock starts at the post-Popen launch observation. A separate file
watcher records the first complete atomic PNG, at 10 ms polling resolution;
panel activation and readiness checks do not move its completion timestamp.
The kernel-resource stream records the actual CPU/IO/footprint observation
window, including its offset from PNG completion. Kernel CPU absolute-time units
are converted with `mach_timebase_info`; the helper was cross-checked against
`getrusage`. App-process physical footprint includes its kernel lifetime peak.
It excludes WebKit service processes and is not a total allocation count.

`axprobe watch` caches an AX window and repeatedly queries its role. Its result
is an AX round trip including IPC, scheduling and the query's own work. It is not
pure main-thread stall duration, presented frames, or FPS. The output records
when the first window became queryable; early launch work outside that window
is not covered. Error/timeout observations invalidate the run instead of being
discarded. An idle A/A probe establishes observer noise. Use a separate `sample`
diagnostic to attribute a large round trip to app stacks; keep diagnostics out
of the timed A/B series.

`axprobe snapshot` reads only identifiers, row counts and geometry. An optional
controlled query is returned as an equality boolean. It never requests row
values, titles or descriptions. This is an instrumented semantic observation;
it is not a compositor visibility measurement. Full row exposure belongs in
functional checks, not unqualified production-speed claims.

## Other interaction workloads

Use a complete synthetic storage root for hover, capture and copy. An old DB
whose external payloads are absent cannot measure these paths. For real-corpus
list/search profiling, first online-backup the DB read-only, copy referenced
payloads into the isolated root, rewrite only the copy's paths, and freeze that
same root for both sides. Never launch a copied DB with original absolute
payload references.

Declare separately: input-event posting to AX query match; input to expected
row IDs with valid geometry; pointer movement to an observed preview window;
capture write to DB commit and then row publication; copy input to private
pasteboard change and panel disappearance. Those are different boundaries.
Keep app profiler counters for instrumented ratios. Absolute CPU requires a
matched profiler-off observation and stated observer overhead. Callback
intervals and over-threshold ratios are callback cadence, not compositor frame
drops. `list.body`, `row.init`, run-loop pressure and correlated timing buckets
remain available under their canonical names.

Offline tool verification:

```sh
make test-tooling
```

Native/UI validation and final quiet A/B remain separate from these tool tests.
Archive completed evidence to `logs/` and publish bounded conclusions through
the canonical performance-study path. Do not change historical raw data.

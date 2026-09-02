# Real-input scroll profiling

`profile_scroll.py` launches a Scopy build with a copy of the real snapshot database (`perf-db/clipboard.db`), opens the
real history panel (`SCOPY_PROFILE_OPEN_PANEL=1`), and drives the list either with **real scroll-wheel input**
(`--mode wheel`: pixel scroll-wheel `CGEvent`s posted at the panel; the terminal running it must be trusted under
System Settings > Privacy & Security > Accessibility, check with `build/axcheck`) or with the app's deterministic
display-link workload (`--mode fixed`, one clip-view step per display callback, 1440 commands by default).

During the run it records process CPU time (`ps`), GPU utilization (`ioreg`), the app's own `SCOPY_SCROLL_PROFILE`
report (animation-callback intervals, main run-loop busy time, counters), and optionally a `sample` call tree
(`--sample`) or an Instruments trace (`--xctrace 'Time Profiler'`). `analyze_sample.py` turns the `sample` output into
heavy-branch listings and per-subsystem shares (`--grep`).

```
make perf-scroll-tools                       # compile helpers into scripts/perf-scroll/build
make release                                 # the Release app under DerivedData is what gets profiled
python3 scripts/perf-scroll/profile_scroll.py <Release Scopy.app> baseline --mode wheel --duration 12 --sample
python3 scripts/perf-scroll/analyze_sample.py logs/perf-scroll/baseline/sample.txt --thread main --grep 'NSCursor set'
```

Interpretation rules: animation-callback intervals are callback cadence, not presented frames; the main-thread
`sample` tree is the attribution source; compare same-workload runs only (wheel vs wheel, fixed vs fixed).

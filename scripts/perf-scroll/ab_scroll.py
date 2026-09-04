#!/usr/bin/env python3
"""Repeat a scroll profile N times and report the distribution.

usage: ab_scroll.py <app.app> <label> --runs 5 [--no-app-profile] [passthrough args...]

Every release-note scroll number so far came from a single run of `profile_scroll.py` while the
app carried its own instrumentation. Run-to-run spread on this workload is about +-4%, so a
single run cannot resolve anything smaller than that; this wrapper reports mean, min and max so a
candidate is compared against a distribution instead of a point.
"""
import argparse, json, os, re, statistics, subprocess, sys
S = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(S, '..', '..'))

ap = argparse.ArgumentParser()
ap.add_argument('app'); ap.add_argument('label')
ap.add_argument('--runs', type=int, default=5)
args, passthrough = ap.parse_known_args()

CPU = re.compile(r'scopy cpu ([\d.]+)s .*?windowserver cpu ([\d.]+)s')
BUSY = re.compile(r'runloop busy ms (\d+) p95 ([\d.]+) max ([\d.]+)')
CB = re.compile(r'all callbacks (\d+) p95 ([\d.]+) max ([\d.]+)')

rows = []
for i in range(1, args.runs + 1):
    label = f'{args.label}-{i}'
    cmd = [sys.executable, os.path.join(S, 'profile_scroll.py'), args.app, label] + passthrough
    print(f'--- run {i}/{args.runs}: {label}', flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
    row = {'label': label}
    m = CPU.search(r.stdout)
    if m:
        row['cpu'] = float(m.group(1)); row['windowserver'] = float(m.group(2))
    m = BUSY.search(r.stdout)
    if m:
        row['runloop_busy_ms'] = int(m.group(1)); row['runloop_p95'] = float(m.group(2))
    m = CB.search(r.stdout)
    if m:
        row['callbacks'] = int(m.group(1)); row['callback_p95'] = float(m.group(2)); row['callback_max'] = float(m.group(3))
    rows.append(row)

def stat(key):
    v = [r[key] for r in rows if key in r]
    if not v:
        return None
    return {'n': len(v), 'mean': round(statistics.mean(v), 3), 'min': round(min(v), 3),
            'max': round(max(v), 3),
            'stdev': round(statistics.stdev(v), 3) if len(v) > 1 else 0.0}

summary = {k: stat(k) for k in ('cpu', 'windowserver', 'runloop_busy_ms', 'callback_p95', 'callback_max')}
summary = {k: v for k, v in summary.items() if v}
out = os.path.join(repo, 'logs', 'perf-scroll', f'{args.label}-summary.json')
json.dump({'label': args.label, 'runs': rows, 'summary': summary}, open(out, 'w'), indent=2)
print('\n=== ' + args.label)
for k, v in summary.items():
    print(f'  {k:16s} mean {v["mean"]:>9} min {v["min"]:>9} max {v["max"]:>9} sd {v["stdev"]:>7} (n={v["n"]})')
print('summary ->', out)

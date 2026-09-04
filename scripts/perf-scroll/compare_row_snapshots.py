#!/usr/bin/env python3
"""Compare two directories of row snapshots pixel by pixel.

usage: compare_row_snapshots.py <before-dir> <after-dir>

A row simplification is only safe to ship if it leaves the rendering alone, and this host cannot
take screenshots. The snapshot test rasterises rows with ImageRenderer instead; this compares two
captures and reports any pixel that moved.
"""
import os, sys, subprocess, tempfile

before, after = sys.argv[1], sys.argv[2]
names = sorted(set(os.listdir(before)) & set(os.listdir(after)))
if not names:
    print('no snapshots in common'); sys.exit(1)
worst = 0
for name in names:
    a, b = os.path.join(before, name), os.path.join(after, name)
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        if fa.read() == fb.read():
            print(f'  {name:24s} identical bytes')
            continue
    # Fall back to a pixel comparison: PNG encoders are not bit-stable across runs.
    with tempfile.NamedTemporaryFile(suffix='.txt') as out:
        r = subprocess.run(['magick', 'compare', '-metric', 'AE', a, b, 'null:'],
                           capture_output=True, text=True)
        diff = (r.stderr or r.stdout).strip()
    print(f'  {name:24s} DIFFERS ({diff} pixels)')
    try:
        worst = max(worst, int(float(diff.split()[0])))
    except Exception:
        worst = max(worst, 1)
print(f'\n{"IDENTICAL" if worst == 0 else f"CHANGED: worst {worst} pixels"}')
sys.exit(0 if worst == 0 else 1)

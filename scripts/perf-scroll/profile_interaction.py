#!/usr/bin/env python3
"""Measure the two interactions every use of Scopy goes through: opening the panel and pressing return.

usage: profile_interaction.py <app.app> <label> [--cycles 6] [--settle 12] [--sample] [--reuse-db]
                              [--down N] [--query TEXT]

Launches a build against a copy of the real snapshot database, then per cycle:
  open   global hotkey -> panel window on screen -> app answers a cheap Accessibility query again
  enter  return key    -> content on the app's private pasteboard -> panel window gone
"""
import argparse, json, os, shutil, signal, subprocess, sys, tempfile, time

S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(S, '..', '..'))
TOOLS = os.environ.get('SCOPY_PERF_SCROLL_TOOLS', os.path.join(S, 'build'))

ap = argparse.ArgumentParser()
ap.add_argument('app'); ap.add_argument('label')
ap.add_argument('--cycles', type=int, default=6)
ap.add_argument('--settle', type=float, default=12.0)
ap.add_argument('--gap', type=float, default=1.5)
ap.add_argument('--sample', action='store_true')
ap.add_argument('--reuse-db', action='store_true')
ap.add_argument('--down', type=int, default=0, help='arrow-down presses before return (selects a lower row)')
ap.add_argument('--query', default=None)
ap.add_argument('--hotkey', type=int, default=8)
ap.add_argument('--click-row', type=int, default=None, help='activate the row this many points below the panel top instead of pressing return')
ap.add_argument('--count-rows', action='store_true')
a = ap.parse_args()

out = os.path.join(REPO, 'logs', 'perf-panel', a.label)
os.makedirs(out, exist_ok=True)
DB_FILES = ('clipboard.db', 'clipboard.db-wal', 'clipboard.db-shm',
            'clipboard.db.fullindex.v5.bin', 'clipboard.db.fullindex.v5.bin.metadata.plist',
            'clipboard.db.fullindex.v5.bin.sha256',
            'clipboard.db.shortindex.v3.bin', 'clipboard.db.shortindex.v3.bin.sha256')

def make_db():
    if a.reuse_db:
        d = os.path.join(REPO, 'logs', 'perf-panel', 'db-warm')
        if os.path.exists(os.path.join(d, 'clipboard.db')):
            return d
        os.makedirs(d, exist_ok=True)
    else:
        d = tempfile.mkdtemp(prefix='scopy-panel-db-')
    for f in DB_FILES:
        src = os.path.join(REPO, 'perf-db', f)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(d, f))
    return d

dbdir = make_db()
pbname = 'ScopyPanel.' + str(os.getpid())
env = dict(os.environ, USE_MOCK_SERVICE='0',
           SCOPY_SERVICE_DB_PATH=os.path.join(dbdir, 'clipboard.db'),
           SCOPY_SERVICE_MONITOR_PASTEBOARD=pbname,
           SCOPY_PROFILE_ACCESSIBILITY='1')
p = subprocess.Popen([a.app + '/Contents/MacOS/Scopy'], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f'launched pid {p.pid} db {dbdir} pasteboard {pbname}', flush=True)

def run(tool, *extra):
    r = subprocess.run([os.path.join(TOOLS, tool), str(p.pid)] + list(extra), capture_output=True, text=True)
    return (r.stdout.strip() or r.stderr.strip())

lines = []
try:
    time.sleep(a.settle)
    sampler = None
    if a.sample:
        sampler = subprocess.Popen(['sample', str(p.pid), str(int(a.cycles * (a.gap + 3)) + 2), '-mayDie',
                                    '-file', os.path.join(out, 'sample.txt')],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for i in range(a.cycles):
        o = run('panelready', '--hotkey', str(a.hotkey), *(['--count-rows'] if a.count_rows else []))
        print(f'  cycle {i+1} {o}', flush=True)
        lines.append(o)
        time.sleep(0.8)
        # The panel is a non-activating NSPanel: without a click into it, posted key events go to the
        # frontmost application instead. Click the header search field the way profile_search.py does.
        wp = subprocess.run([os.path.join(TOOLS, 'winpos'), str(p.pid)], capture_output=True, text=True)
        if wp.returncode == 0 and wp.stdout.strip() != 'none':
            pos = [int(v) for v in wp.stdout.split()]
            subprocess.run([os.path.join(TOOLS, 'click'), str(pos[0] + 100), str(pos[1] + 30)],
                           capture_output=True, text=True)
            time.sleep(0.4)
        if a.query and i == 0:
            subprocess.run([os.path.join(TOOLS, 'typekeys'), '8', a.query], capture_output=True, text=True)
            time.sleep(2.0)
        cmd = [os.path.join(TOOLS, 'enterlatency'), str(p.pid), pbname, '--down', str(a.down)]
        if a.click_row is not None and wp.returncode == 0 and wp.stdout.strip() != 'none':
            cmd += ['--click', str(pos[0] + pos[2] // 2), str(pos[1] + a.click_row)]
        e = subprocess.run(cmd, capture_output=True, text=True)
        el = (e.stdout.strip() or e.stderr.strip())
        print(f'  cycle {i+1} {el}', flush=True)
        lines.append(el)
        if 'panel not open' in el:
            run('panelready', '--hotkey', str(a.hotkey))   # make sure it is closed for the next cycle
        time.sleep(a.gap)
    if sampler:
        sampler.wait()
finally:
    p.send_signal(signal.SIGTERM)
    try: p.wait(6)
    except subprocess.TimeoutExpired: p.kill()
    if not a.reuse_db: shutil.rmtree(dbdir, ignore_errors=True)

def stat(key):
    vals = []
    for l in lines:
        for tok in l.split():
            if tok.startswith(key + '='):
                try:
                    v = float(tok.split('=')[1])
                    if v == v: vals.append(v)
                except ValueError: pass
    if not vals: return 'n/a'
    v = sorted(vals)
    return f'n={len(v)} min={v[0]:.1f} med={v[len(v)//2]:.1f} max={v[-1]:.1f}'
print()
for k in ('visible_ms', 'quiet_ms', 'worst_probe_ms', 'ax_items', 'pasteboard_ms', 'hidden_ms', 'bytes'):
    print(f'{k:16s}', stat(k))
json.dump({'lines': lines}, open(os.path.join(out, 'interaction.json'), 'w'), indent=1)
print('output dir', out)

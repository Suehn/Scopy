#!/usr/bin/env python3
"""Profile search typing in the real Scopy panel with the real snapshot DB.
usage: profile_search.py <app.app> <label> [--query cm] [--rate 8] [--sample] [--reuse-db] [--settle 6] [--attempts 4]
       [--field-x 100] [--field-y 30] [--out DIR]
Launches the app exactly like profile_scroll.py (copy of perf-db/clipboard.db, panel opened by SCOPY_PROFILE_OPEN_PANEL,
app profiler enabled), clicks into the header search field with a synthetic mouse click (build/click at --field-x /
--field-y points from the panel's top-left corner), then types --query with real key events (build/typekeys, `<bs>` and
`<cmd-a>` tokens allowed) at --rate characters per second while `sample` (--sample) and sample.sh watch the process.
The measurement window is the typing time plus a 2 s tail for the results to land; it then screenshots the panel
(panel-after.png; panel-before.png is taken before the click) so the caller can confirm the query and the result list,
reads the search field value and the exposed rows back through Accessibility (build/axsearch) so the typed text and
the list change are confirmed even when Screen Recording is not granted (then screenshots show only the wallpaper),
waits for the app's profile JSON, and prints the CPU line plus the profiler counters that mention search or row.
"""
import argparse, json, math, os, shutil, signal, subprocess, sys, tempfile, time
S=os.path.dirname(os.path.abspath(__file__))
TOOLS=os.environ.get('SCOPY_PERF_SCROLL_TOOLS', os.path.join(S, 'build'))
repo=os.path.abspath(os.path.join(S, '..', '..'))
ap=argparse.ArgumentParser(); ap.add_argument('app'); ap.add_argument('label')
ap.add_argument('--query', default='cm'); ap.add_argument('--rate', type=float, default=8.0)
ap.add_argument('--sample', action='store_true'); ap.add_argument('--reuse-db', action='store_true')
ap.add_argument('--settle', type=float, default=6); ap.add_argument('--attempts', type=int, default=4)
ap.add_argument('--field-x', type=int, default=100, help='click x offset from the panel left edge (pt)')
ap.add_argument('--field-y', type=int, default=30, help='click y offset from the panel top edge (pt)')
ap.add_argument('--out', default=None)
a=ap.parse_args()
out=a.out or os.path.join(repo, 'logs', 'perf-scroll', a.label); os.makedirs(out, exist_ok=True)
profile_json=os.path.join(out, 'profile.json')
TAIL=2.0

def expected_text(query):
    text=''; selected=False; keys=0; rest=query
    while rest:
        keys+=1
        if rest.startswith('<bs>'): text='' if selected else text[:-1]; selected=False; rest=rest[4:]
        elif rest.startswith('<cmd-a>'): selected=True; rest=rest[7:]
        else: text=rest[0] if selected else text+rest[0]; selected=False; rest=rest[1:]
    return text, keys

EXPECTED, key_count=expected_text(a.query)
typing_seconds=key_count / a.rate
window=max(1, math.ceil(typing_seconds + TAIL))
axcheck=subprocess.run([os.path.join(TOOLS, 'axcheck')], capture_output=True, text=True).stdout
if 'CGPreflightScreenCaptureAccess: true' not in axcheck:
    print('note: Screen Recording is not granted for this terminal; screenshots will only show the wallpaper, rely on the AX readback', flush=True)

def make_db():
    if a.reuse_db:
        dbdir=os.path.join(repo, 'logs', 'perf-scroll', 'db-warm')
        if os.path.exists(os.path.join(dbdir, 'clipboard.db')): return dbdir
        os.makedirs(dbdir, exist_ok=True)
    else:
        dbdir=tempfile.mkdtemp(prefix='scopy-profile-db-')
    for f in ('clipboard.db','clipboard.db-wal','clipboard.db-shm','clipboard.db.fullindex.v4.plist','clipboard.db.fullindex.v4.plist.metadata.plist'):
        src=os.path.join(repo, 'perf-db', f)
        if os.path.exists(src): shutil.copy(src, os.path.join(dbdir, f))
    return dbdir

def drop_db(dbdir):
    if not a.reuse_db: shutil.rmtree(dbdir, ignore_errors=True)

def screenshot(pos, name):
    path=os.path.join(out, name)
    subprocess.run(['screencapture', '-x', '-R', f'{pos[0]},{pos[1]},{pos[2]},{pos[3]}', path], check=False)
    return path

def run_once(index):
    if os.path.exists(profile_json): os.remove(profile_json)
    dbdir=make_db()
    env=dict(os.environ, USE_MOCK_SERVICE='0', SCOPY_SERVICE_DB_PATH=os.path.join(dbdir, 'clipboard.db'), SCOPY_SERVICE_MONITOR_PASTEBOARD='ScopyProfile.'+str(os.getpid()),
             SCOPY_PROFILE_OPEN_PANEL='1', SCOPY_SCROLL_PROFILE='1', SCOPY_PROFILE_MIN_SAMPLES='10', SCOPY_PROFILE_MAX_SAMPLES='131072', SCOPY_PROFILE_OUTPUT=profile_json,
             SCOPY_PROFILE_DURATION_SEC=str(int(a.settle + window + 6)))
    p=subprocess.Popen([a.app+'/Contents/MacOS/Scopy'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(a.settle)
    pos=None
    for _ in range(20):
        r=subprocess.run([os.path.join(TOOLS, 'winpos'), str(p.pid)], capture_output=True, text=True)
        if r.returncode==0 and r.stdout.strip()!='none': pos=[int(v) for v in r.stdout.split()]; break
        print('window check:', r.stdout.strip(), flush=True); time.sleep(0.5)
    result={'pid': p.pid, 'window': pos}
    if not pos:
        p.send_signal(signal.SIGTERM); drop_db(dbdir); print('no usable window'); return None
    x=pos[0]+a.field_x; y=pos[1]+a.field_y
    print(f'attempt {index}: pid {p.pid} window {pos} click at ({x},{y}) query {a.query!r} rate {a.rate}/s window {window}s', flush=True)
    screenshot(pos, 'panel-before.png')
    click=subprocess.run([os.path.join(TOOLS, 'click'), str(x), str(y)], capture_output=True, text=True)
    result['click']=click.stdout.strip()
    time.sleep(0.4)
    procs=[]
    if a.sample:
        procs.append(subprocess.Popen(['sample', str(p.pid), str(window), '-mayDie', '-file', os.path.join(out, 'sample.txt')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    sampler=subprocess.Popen([os.path.join(S, 'sample.sh'), str(p.pid), str(window)], stdout=subprocess.PIPE, text=True)
    typed=subprocess.run([os.path.join(TOOLS, 'typekeys'), str(a.rate), a.query], capture_output=True, text=True)
    result['typekeys']=typed.stdout.strip()
    time.sleep(TAIL)
    result['screenshot']=screenshot(pos, 'panel-after.png')
    result['ax']=subprocess.run([os.path.join(TOOLS, 'axsearch'), str(p.pid)], capture_output=True, text=True).stdout.strip()
    result['cpu']=sampler.communicate()[0].strip()
    for q in procs: q.wait()
    deadline=time.time()+60
    while time.time()<deadline and not os.path.exists(profile_json): time.sleep(0.5)
    time.sleep(1.0)
    p.send_signal(signal.SIGTERM)
    try: p.wait(5)
    except subprocess.TimeoutExpired: p.kill()
    drop_db(dbdir)
    return result

result=None
for i in range(1, a.attempts+1):
    result=run_once(i)
    if result and f'search field value: "{EXPECTED}"' in result.get('ax', ''): break
    print(f'attempt {i}: the search field does not contain {EXPECTED!r} (ax: {(result or {}).get("ax", "")!r}); retrying', flush=True)

if result:
    print(result.get('click', '')); print(result.get('typekeys', ''))
    print(f'cpu over typing + {TAIL:.0f}s tail ({window}s):', result.get('cpu', ''))
    print('screenshot', result.get('screenshot', ''))
    print('ax readback:', result.get('ax', '').replace('\n', '\n  '))
if os.path.exists(profile_json):
    d=json.load(open(profile_json))
    counters=((d.get('structural_metrics') or {}).get('counters') or {})
    hits={k: v for k, v in counters.items() if 'search' in k or 'row.' in k}
    print('profiler counters (search/row.):', hits if hits else 'none present', '| all counters:', sorted(counters))
    rl=d.get('main_runloop_active_ms') or {}
    print('app profiler: runloop busy ms', round(rl.get('total_ms', 0)), 'p95', round(rl.get('p95', 0), 2), 'max', round(rl.get('max', 0), 1), 'of', round(d.get('duration_seconds') or 0, 1), 's')
else: print('no profile json written')
print('output dir', out)

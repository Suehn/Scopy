#!/usr/bin/env python3
"""Profile clipboard capture in the real Scopy panel with the real snapshot DB.
usage: profile_capture.py <app.app> <label> [--scenario text|rich|image] [--count 10] [--interval 1.0] [--size N]
       [--sample] [--settle 6] [--out DIR]
Launches the app on a fresh copy of perf-db/clipboard.db with the panel open and the clipboard monitor bound to a
private named pasteboard (SCOPY_SERVICE_MONITOR_PASTEBOARD), waits for the panel via build/winpos, then drives
build/pbwrite against that pasteboard while `sample`-ing the whole process (--sample, all threads) and measuring CPU
with sample.sh over the writes plus 3 s. The list is inspected twice, right after the last write and after the 3 s
wait: build/winpos (is the panel still open; another app taking key focus closes it), build/axrows (row order through
Accessibility, needs Accessibility trust) and a screenshot of the panel region (panel.png; needs Screen Recording
permission for the terminal, otherwise macOS leaves the windows out). After SIGTERM it lists the newest rows of the
run's DB and checks that their ids are the first rows of the Recent section. It also prints the pbwrite timestamps,
the CPU figures and any app log lines mentioning "capture" or "ingest". The SCOPY_SCROLL_PROFILE report only
finalizes after scrolling samples, so profile.json is normally absent for a capture-only run.
"""
import argparse, json, datetime, math, os, re, shutil, signal, sqlite3, subprocess, sys, tempfile, time
S=os.path.dirname(os.path.abspath(__file__))
TOOLS=os.environ.get('SCOPY_PERF_SCROLL_TOOLS', os.path.join(S, 'build'))
repo=os.path.abspath(os.path.join(S, '..', '..'))
ap=argparse.ArgumentParser(); ap.add_argument('app'); ap.add_argument('label')
ap.add_argument('--scenario', default='text', choices=['text','rich','rtf','html','image'])
ap.add_argument('--count', type=int, default=10); ap.add_argument('--interval', type=float, default=1.0)
ap.add_argument('--size', type=int, default=None); ap.add_argument('--sample', action='store_true')
ap.add_argument('--settle', type=float, default=6); ap.add_argument('--out', default=None)
a=ap.parse_args()
out=a.out or os.path.join(repo, 'logs', 'perf-capture', a.label); os.makedirs(out, exist_ok=True)
profile_json=os.path.join(out, 'profile.json')
POST_WAIT=3.0
ROWS=a.count+3

def make_db():
    dbdir=tempfile.mkdtemp(prefix='scopy-capture-db-')
    for f in ('clipboard.db','clipboard.db-wal','clipboard.db-shm','clipboard.db.fullindex.v4.plist','clipboard.db.fullindex.v4.plist.metadata.plist'):
        src=os.path.join(repo, 'perf-db', f)
        if os.path.exists(src): shutil.copy(src, os.path.join(dbdir, f))
    return dbdir

def winpos(pid, activate=False):
    r=subprocess.run([os.path.join(TOOLS,'winpos'), str(pid)] + (['--activate'] if activate else []), capture_output=True, text=True)
    return r.stdout.strip()

def is_open(s): return bool(s) and s[0].isdigit()

def find_window(pid):
    for i in range(20):
        s=winpos(pid, activate=i >= 10)
        if is_open(s): return [int(v) for v in s.split()]
        print('window check:', s, flush=True); time.sleep(0.5)
    return None

def inspect(pid, tag):
    """One look at the panel: returns (winpos, axrows output). Writes axrows-<tag>.txt and panel.png when open."""
    s=winpos(pid)
    if not is_open(s): return s, ''
    ax=subprocess.run([os.path.join(TOOLS,'axrows'), str(pid), str(ROWS)], capture_output=True, text=True)
    text=ax.stdout+ax.stderr
    with open(os.path.join(out, f'axrows-{tag}.txt'),'w') as f: f.write(text)
    x,y,w,h=[int(v) for v in s.split()]
    subprocess.run(['screencapture','-x','-R',f'{x},{y},{w},{h}',os.path.join(out,'panel.png')])
    return s, text

def newest_rows(dbpath, n):
    con=sqlite3.connect(f'file:{dbpath}?mode=ro', uri=True)
    try:
        rows=con.execute('SELECT id, type, created_at, size_bytes, app_bundle_id, substr(plain_text,1,60) FROM clipboard_items ORDER BY created_at DESC LIMIT ?', (n,)).fetchall()
    finally: con.close()
    return rows

def ax_ids(text):
    """Row ids in display order starting at the Recent section (after its header; from the top when there is none)."""
    rows=[]; start=0
    for l in text.splitlines():
        m=re.match(r'row \d+: (\S+) \| (.*)', l)
        if not m: continue
        if m.group(1)=='header':
            if 'Recent' in m.group(2): start=len(rows)
            continue
        rows.append(m.group(1))
    return rows[start:]

if os.path.exists(profile_json): os.remove(profile_json)
dbdir=make_db()
pb_name=f'ScopyDrv.{os.getpid()}'
window=a.count*a.interval + POST_WAIT
env=dict(os.environ, USE_MOCK_SERVICE='0', SCOPY_SERVICE_DB_PATH=os.path.join(dbdir,'clipboard.db'), SCOPY_SERVICE_MONITOR_PASTEBOARD=pb_name,
         SCOPY_PROFILE_OPEN_PANEL='1', SCOPY_SCROLL_PROFILE='1', SCOPY_PROFILE_ACCESSIBILITY='1', SCOPY_PROFILE_MIN_SAMPLES='10',
         SCOPY_PROFILE_MAX_SAMPLES='131072', SCOPY_PROFILE_OUTPUT=profile_json, SCOPY_PROFILE_DURATION_SEC=str(int(a.settle + window + 6)))
t_launch=time.time()
p=subprocess.Popen([a.app+'/Contents/MacOS/Scopy'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(a.settle)
pos=find_window(p.pid)
if not pos:
    p.send_signal(signal.SIGTERM); shutil.rmtree(dbdir, ignore_errors=True); print('no usable window'); sys.exit(1)
print(f'pid {p.pid} scenario {a.scenario} count {a.count} interval {a.interval}s size {a.size or "default"} pasteboard {pb_name} window {pos}', flush=True)

secs=int(math.ceil(window))
procs=[]
if a.sample:
    procs.append(subprocess.Popen(['sample', str(p.pid), str(secs), '-mayDie', '-file', os.path.join(out,'sample.txt')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
sampler=subprocess.Popen([os.path.join(S,'sample.sh'), str(p.pid), str(secs)], stdout=subprocess.PIPE, text=True)
cmd=[os.path.join(TOOLS,'pbwrite'), pb_name, a.scenario, str(a.count), str(a.interval)] + ([str(a.size)] if a.size else [])
pb=subprocess.run(cmd, capture_output=True, text=True)
with open(os.path.join(out,'pbwrite.txt'),'w') as f: f.write(pb.stdout + pb.stderr)
t_done=time.time()
looks=[('after last write',)+inspect(p.pid, 'immediate')]
# A short wheel burst gives the in-app profiler its minimum animation samples so profile.json
# (main run-loop busy max over the whole run, capture included) gets written.
subprocess.run([os.path.join(TOOLS,'wheel'), str(pos[0]+pos[2]//2), str(pos[1]+pos[3]//2+40), '24', '60', '1.5', '100'], capture_output=True)
time.sleep(max(0, POST_WAIT-(time.time()-t_done)))
cpu=sampler.communicate()[0].strip()
with open(os.path.join(out,'cpu.txt'),'w') as f: f.write(cpu+'\n')
s=winpos(p.pid)
if not is_open(s):  # best effort: press the status item to re-open the panel (needs the item to be on the menu bar)
    subprocess.run([os.path.join(TOOLS,'statusclick'), str(p.pid)], capture_output=True, text=True); time.sleep(1.5)
looks.append(('after 3 s wait',)+inspect(p.pid, 'final'))
for q in procs: q.wait()
deadline=time.time()+45
while time.time()<deadline and not os.path.exists(profile_json): time.sleep(0.25)
if os.path.exists(profile_json):
    _d=json.load(open(profile_json)); _rl=_d.get('main_runloop_active_ms') or {}
    print(f"main run-loop busy over the run: max {_rl.get('max',0):.1f} ms, p95 {_rl.get('p95',0):.1f} ms, total {_rl.get('total_ms',0):.0f} ms", flush=True)
p.send_signal(signal.SIGTERM)
try: p.wait(5)
except subprocess.TimeoutExpired: p.kill()
last=f'{max(2, int(math.ceil((time.time()-t_launch)/60))+1)}m'
log=subprocess.run(['/usr/bin/log','show','--last',last,'--style','compact','--predicate',f'processIdentifier == {p.pid}'], capture_output=True, text=True).stdout
with open(os.path.join(out,'applog.txt'),'w') as f: f.write(log)
matches=[l for l in log.splitlines() if re.search('capture|ingest', l, re.I)]
try: db_rows=newest_rows(os.path.join(dbdir,'clipboard.db'), ROWS); db_err=None
except Exception as e: db_rows=[]; db_err=str(e)
shutil.rmtree(dbdir, ignore_errors=True)

print('pbwrite:', ' '.join(cmd))
for l in pb.stdout.splitlines(): print('  ', l)
if pb.returncode!=0 or pb.stderr.strip(): print(f'pbwrite exit {pb.returncode} stderr: {pb.stderr.strip()}')
print(cpu)
good=None
for tag, s, text in looks:
    print(f'panel {tag}: {s if s else "none"}')
    for l in text.splitlines(): print('   ', l)
    if text and 'row' in text: good=text
print(f'newest {ROWS} rows in the run DB after exit:' + (f' read failed: {db_err}' if db_err else ''))
for id_,t,c,sz,app,txt in db_rows:
    print(f'   {id_} {t} {datetime.datetime.fromtimestamp(c).isoformat(timespec="milliseconds")} {sz}B {app or "-"} | {(txt or "").replace(chr(10),"⏎")}')
new_ids=[r[0] for r in db_rows[:a.count]]
if good is None: print('UI check: no accessibility read of the list succeeded (panel closed both times)')
else:
    shown=ax_ids(good)
    ok=shown[:a.count]==new_ids
    print(f'UI check: the {a.count} newest DB rows are the first {a.count} rows of the Recent section: {"OK" if ok else "FAIL"} (list shows {shown[:a.count]})')
print(f'app log lines matching capture|ingest (log show --last {last}): {len(matches)}')
for l in matches: print('  app:', l[:220])
print('profile json:', 'written' if os.path.exists(profile_json) else 'not written (the scroll profiler only finalizes after >=30 animation-callback samples, i.e. scrolling)')
print('screenshot', os.path.join(out,'panel.png'), '(only meaningful when the terminal has Screen Recording permission)')
print('output dir', out)

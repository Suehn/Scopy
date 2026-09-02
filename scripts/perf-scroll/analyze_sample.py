#!/usr/bin/env python3
"""Parse `sample` call-tree output. usage: analyze_sample.py sample.txt [--thread main|all] [--depth 40] [--min 2] [--grep PATTERN]"""
import re, sys, argparse
ap=argparse.ArgumentParser(); ap.add_argument('file'); ap.add_argument('--thread', default='main'); ap.add_argument('--depth', type=int, default=40)
ap.add_argument('--min', type=float, default=2.0, help='min percent of thread samples to print a branch'); ap.add_argument('--grep', default=None); ap.add_argument('--maxlines', type=int, default=120)
a=ap.parse_args()
lines=open(a.file, errors='replace').read().split('\n')
# call graph section
try: start=lines.index('Call graph:')+1
except ValueError: start=0
end=next((i for i,l in enumerate(lines) if l.startswith('Total number in stack')), len(lines))
node_re=re.compile(r'^([\s+!:|]*?)(\d+) (.*?)(?:  \(in (.*?)\))?(?: \+ \d+)?(?: \[0x[0-9a-f]+\])?(?:  \S+:\d+)?$')
class N:
    __slots__=('count','name','mod','children','depth')
    def __init__(s,c,n,m,d): s.count=c; s.name=n; s.mod=m; s.children=[]; s.depth=d
roots=[]; stack=[]
for l in lines[start:end]:
    if not l.strip(): continue
    m=node_re.match(l)
    if not m: continue
    indent=len(m.group(1)); cnt=int(m.group(2)); name=m.group(3).strip(); mod=m.group(4) or ''
    n=N(cnt,name,mod,indent)
    while stack and stack[-1].depth>=indent: stack.pop()
    (stack[-1].children if stack else roots).append(n); stack.append(n)
def is_main(n): return 'Main Thread' in n.name or 'com.apple.main-thread' in n.name
threads=roots
sel=[t for t in threads if is_main(t)] if a.thread=='main' else threads
total=sum(t.count for t in sel)
print(f'threads in file: {len(threads)}; selected {len(sel)} thread(s), {total} samples')
def short(n):
    nm=n.name
    nm=re.sub(r'<.*?>','<>',nm) if len(nm)>110 else nm
    return (nm[:105]+'…' if len(nm)>106 else nm) + (f' ({n.mod})' if n.mod else '')
# heavy-branch print
out=[]
def walk(n, depth, tot):
    if depth>a.depth or len(out)>=a.maxlines: return
    pct=n.count*100/tot
    if pct<a.min: return
    out.append(f"{'  '*depth}{pct:5.1f}% {n.count:6d}  {short(n)}")
    for c in sorted(n.children, key=lambda c:-c.count): walk(c, depth+1, tot)
for t in sel: walk(t, 0, total)
print('\n'.join(out))
if a.grep:
    pat=re.compile(a.grep)
    # sum of samples whose ancestry contains the pattern (count each sample once: take topmost matching node)
    agg=0; hits={}
    def collect(n, matched):
        global agg
        m=matched or bool(pat.search(n.name))
        if m and not matched:
            agg+=n.count; hits[short(n)]=hits.get(short(n),0)+n.count
        for c in n.children: collect(c, m)
    for t in sel: collect(t, False)
    print(f"\n== samples under nodes matching /{a.grep}/: {agg} ({agg*100/max(1,total):.1f}%)")
    for k,v in sorted(hits.items(), key=lambda kv:-kv[1])[:12]: print(f'   {v:6d}  {k}')

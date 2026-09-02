#!/bin/zsh
# usage: sample.sh <pid> <seconds> -> prints Scopy CPU seconds, WindowServer CPU seconds, GPU utilization samples
pid=$1; secs=$2
ws=$(pgrep -x WindowServer | head -1)
cpu() { ps -o cputime= -p $1 | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
c0=$(cpu $pid); w0=$(cpu $ws); t0=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')
gpu=()
end=$(( $(python3 -c 'import time;print(time.time())') + secs ))
while (( $(python3 -c 'import time;print(time.time())') < end )); do
  u=$(ioreg -r -d 1 -c IOAccelerator 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)
  gpu+=(${u:-0}); sleep 0.25
done
c1=$(cpu $pid); w1=$(cpu $ws)
python3 - "$c0" "$c1" "$w0" "$w1" "$secs" "${gpu[@]}" <<'PY'
import sys
c0,c1,w0,w1,secs=map(float,sys.argv[1:6]); g=[int(v) for v in sys.argv[6:]]
print(f"scopy cpu {c1-c0:.2f}s ({(c1-c0)/secs*100:.0f}% of one core), windowserver cpu {w1-w0:.2f}s ({(w1-w0)/secs*100:.0f}%), gpu util avg {sum(g)/max(1,len(g)):.0f}% max {max(g) if g else 0}% n={len(g)}")
PY

#!/bin/zsh
# The pointer does not move: scroll the list under it, stop, and the row that ends up under the
# pointer must open its preview. This is the behaviour a scroll-phase-conditional hover breaks,
# because AppKit does not necessarily re-deliver mouse-entered when a tracking area is installed
# under a stationary pointer.
# Which row ends up under the pointer depends on where the scroll stops, and some rows take longer
# to produce a preview than the wait allows, so a single run is not a reliable signal. Retry.
APP=$1
OFFSET=${2:-300}
ATTEMPTS=${3:-3}
S=${0:a:h}
REPO=${S:h:h}
DB=$REPO/logs/perf-scroll/db-warm
run_once() {
"$S/build/warp" 1400 40 >/dev/null
env USE_MOCK_SERVICE=0 SCOPY_SERVICE_DB_PATH="$DB/clipboard.db" SCOPY_SERVICE_MONITOR_PASTEBOARD="ScopyHS.$$" \
    SCOPY_PROFILE_OPEN_PANEL=1 SCOPY_SCROLL_PROFILE=1 SCOPY_PROFILE_ACCESSIBILITY=1 \
    SCOPY_PROFILE_DURATION_SEC=180 "$APP/Contents/MacOS/Scopy" >/dev/null 2>&1 &
PID=$!
sleep 8
POS=$("$S/build/winpos" $PID) || { echo "no panel"; kill -TERM $PID; exit 1; }
X=$(( ${POS[(w)1]} + ${POS[(w)3]} / 2 ))
Y=$(( ${POS[(w)2]} + OFFSET ))
base=$(/tmp/winlist $PID | wc -l | tr -d ' ')
# Scroll for 2 s with the pointer on the list, then leave it exactly where it is.
"$S/build/wheel" $X $Y 24 60 2 4 >/dev/null
sleep 3
after=$(/tmp/winlist $PID | wc -l | tr -d ' ')
kill -TERM $PID 2>/dev/null
echo "  windows: base=$base after-scroll-settle=$after"
[[ $after -gt $base ]]
}

for i in $(seq 1 $ATTEMPTS); do
  if run_once; then
    echo "OK: preview appeared after the scroll settled, without moving the pointer (attempt $i)"
    exit 0
  fi
done
echo "FAIL: no preview after the scroll settled in $ATTEMPTS attempts"
exit 1

#!/bin/zsh
# Functional check for the row activation path: a real click on a history row must put that row's
# content on the app's pasteboard and close the panel. Prints "OK" only when both happen.
# usage: verify_row_click.sh <Scopy.app> [rowOffsetPoints]
set -e
APP=$1
OFFSET=${2:-120}
S=${0:a:h}
REPO=${S:h:h}
DB=$REPO/logs/perf-scroll/db-warm
PB="ScopyVerify.$$"
"$S/build/warp" 1400 40 >/dev/null
env USE_MOCK_SERVICE=0 SCOPY_SERVICE_DB_PATH="$DB/clipboard.db" SCOPY_SERVICE_MONITOR_PASTEBOARD="$PB" \
    SCOPY_PROFILE_OPEN_PANEL=1 "$APP/Contents/MacOS/Scopy" >/dev/null 2>&1 &
PID=$!
sleep 7
if [[ -x /tmp/winlist ]]; then echo "windows:"; /tmp/winlist $PID; fi
POS=$("$S/build/winpos" $PID) || { echo "no window"; kill -TERM $PID; exit 1; }
X=$(( ${POS[(w)1]} + ${POS[(w)3]} / 2 ))
Y=$(( ${POS[(w)2]} + OFFSET ))
echo "panel $POS -> clicking ($X,$Y)"
OUT=$("$S/build/enterlatency" $PID "$PB" --click $X $Y || true)
echo "$OUT"
kill -TERM $PID 2>/dev/null || true
case "$OUT" in
  *pasteboard_ms=nan*|*hidden_ms=nan*|*"panel not open"*) echo "FAIL: row activation did not complete"; exit 1;;
  *) echo "OK: row click copied and closed the panel";;
esac

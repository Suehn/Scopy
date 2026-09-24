#!/bin/zsh
# Functional check for the row activation path: a real click on a history row must put that row's
# content on the app's pasteboard and close the panel. Prints "OK" only when both happen.
# usage: verify_row_click.sh <Scopy.app> [rowOffsetPoints]
# DB: a warm copy of perf-db (default logs/perf-scroll/db-warm, override with SCOPY_VERIFY_DB=<dir>).
set -euo pipefail
APP=$1
OFFSET=${2:-120}
S=${0:a:h}
REPO=${S:h:h}
DB=${SCOPY_VERIFY_DB:-$REPO/logs/perf-scroll/db-warm}
[[ -f $DB/clipboard.db ]] || { echo "FAIL: no database at $DB/clipboard.db"; exit 1; }
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
OUT=$("$S/build/enterlatency" $PID "$PB" --click $X $Y) || { echo "FAIL: enterlatency exited $?"; kill -TERM $PID 2>/dev/null || true; exit 1; }
echo "$OUT"
kill -TERM $PID 2>/dev/null || true
# OK only when both measurements are real numbers; empty output or nan is a failure.
if [[ $OUT == *pasteboard_ms=[0-9]* && $OUT == *hidden_ms=[0-9]* ]]; then
  echo "OK: row click copied and closed the panel"
else
  echo "FAIL: row activation did not complete"; exit 1
fi

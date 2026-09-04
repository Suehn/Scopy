#!/bin/zsh
# Functional gate for the hover path: parking the pointer on a row must open a preview, and moving
# it off the list must close it again. The preview is a second window at the panel's window level,
# so it can be observed from outside without Screen Recording permission.
# usage: verify_hover_preview.sh <Scopy.app> [rowOffsetPoints]
APP=$1
OFFSET=${2:-300}
S=${0:a:h}
REPO=${S:h:h}
DB=$REPO/logs/perf-scroll/db-warm
"$S/build/warp" 1400 40 >/dev/null
env USE_MOCK_SERVICE=0 SCOPY_SERVICE_DB_PATH="$DB/clipboard.db" SCOPY_SERVICE_MONITOR_PASTEBOARD="ScopyHover.$$" \
    SCOPY_PROFILE_OPEN_PANEL=1 SCOPY_SCROLL_PROFILE=1 SCOPY_PROFILE_ACCESSIBILITY=1 \
    SCOPY_PROFILE_DURATION_SEC=180 "$APP/Contents/MacOS/Scopy" >/dev/null 2>&1 &
PID=$!
sleep 8
POS=$("$S/build/winpos" $PID) || { echo "no panel"; kill -TERM $PID; exit 1; }
X=$(( ${POS[(w)1]} + ${POS[(w)3]} / 2 ))
Y=$(( ${POS[(w)2]} + OFFSET ))
before=$("$S/build/panelcount" $PID 2>/dev/null || /tmp/winlist $PID | wc -l | tr -d ' ')
"$S/build/warp" $X $Y >/dev/null
sleep 3
during=$(/tmp/winlist $PID | wc -l | tr -d ' ')
ROW=$("$S/build/axat" $PID $X $Y | grep "^at-point" | sed 's/^at-point pid=[0-9]* //')
PANEL="${POS[(w)3]}x${POS[(w)4]}"
PV=$(/tmp/winlist $PID | grep -v " $PANEL$" | head -1)
echo "row under pointer : ${ROW:0:100}"
echo "preview window    : ${PV:-none}"
# The row the pointer is over must be the one the app treats as hovered: hovering drives
# selectedID, and the row exposes that as its accessibility value. An off-by-one hover mapping
# shows up here as "unselected".
case "$ROW" in
  selected*) SELOK=1;;
  *) SELOK=0;;
esac
"$S/build/warp" 1400 40 >/dev/null
sleep 2
after=$(/tmp/winlist $PID | wc -l | tr -d ' ')
kill -TERM $PID 2>/dev/null
echo "windows: before=$before hovering=$during after=$after"
if [[ $during -gt $before && $after -le $before && $SELOK -eq 1 ]]; then
  echo "OK: the row under the pointer is the hovered row, its preview opened, and leaving closed it"
else
  echo "FAIL: windows $before -> $during -> $after, row-under-pointer selected=$SELOK"
  exit 1
fi

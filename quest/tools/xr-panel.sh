#!/usr/bin/env bash
# Milestone 4d on the headset (quest/PHASE4.md): a whole turn on the war table without the 2D side panel. From the
# lord's chair a simulated ray selects the town and the hero on the board, opens the hero's window, moves the hero on
# the map and ends the turn with the hourglass. Each step is checked in the bridge stats or the logs, with a
# screenshot in OUT. Usage: xr-panel.sh [apk]
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
Q="$TOOLS/quest.sh"
OUT="${OUT:-$TOOLS/../out/panel-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
command -v cygpath >/dev/null && OUT="$(cygpath -m "$OUT")"
trap '"$Q" stop >/dev/null || true' EXIT
set -E
trap 'echo "FAIL: line $LINENO" >&2' ERR # a step that timed out

EYE="0 0.45 0.82" # table_view: metres from the map's middle (up, towards the chair)
# aim_at x y z: the ray from the eye to a point in the map's frame (x right, y up, z towards the chair)
aim_at() {
	# shellcheck disable=SC2046,SC2086
	"$Q" test aim $(awk -v x="$1" -v y="$2" -v z="$3" -v e="$EYE" 'BEGIN { split(e, eye, " ")
		dx = x - eye[1]; dy = y - eye[2]; dz = z - eye[3]; deg = 57.29578
		print atan2(-dx, -dz) * deg, atan2(dy, sqrt(dx * dx + dz * dz)) * deg }') >/dev/null
	sleep 1
}
stat() { "$Q" test bridge | sed -n "s/.*\"$1\": \([-0-9a-z]*\).*/\1/p"; }
shot() { "$Q" screenshot "$OUT/$1.jpg" >/dev/null; }
# both eyes' whole view, as the display shows it: the seated player's screen stands above quest.sh screenshot's crop
display() { "$Q" adb shell dumpsys display | sed -n 's/.*DisplayInfo{"VCMI", displayId \([0-9]*\).*/\1/p' | head -1 | tr -d '\r'; }
eyes_shot() { "$Q" adb exec-out screencap -d "$(display)" -p >"$OUT/$1.png"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

OUT="$OUT/smoke" "$TOOLS/xr-smoke.sh" "$@" >/dev/null
"$Q" test head 0 0 1.6 >/dev/null
"$Q" test recenter >/dev/null
for _ in 1 2 3 4 5 6; do "$Q" test pad 97 >/dev/null; sleep 0.7; done # the scenario's dialogs
"$Q" test head_off >/dev/null
"$Q" test tabletop 1 >/dev/null
sleep 12 # seated, the sprites loaded
# shellcheck disable=SC2086
"$Q" test table_view ${EYE#* } >/dev/null
sleep 2
[ "$(stat tabletop)" = true ] || fail "not in tabletop mode"
hero="$(stat selected)"

# the board (table_panel.gd BOARD_POSE): the first town's row, then the first hero's
aim_at -0.741 0.221 -0.571
shot 1-hover-town
"$Q" test click >/dev/null; sleep 2
town="$(stat selected)"
[ "$town" != "$hero" ] || fail "the town's row did not select it (selected $town)"
echo "select town: ok ($hero -> $town)"
aim_at -0.7635 0.5025 -0.6436
"$Q" test click >/dev/null; sleep 2
[ "$(stat selected)" = "$hero" ] || fail "the hero's row did not select it (selected $(stat selected))"
shot 2-hero-selected
echo "select hero: ok"
# a click on the selected entry opens its window, as in the 2D lists
"$Q" test click >/dev/null; sleep 4
[ "$(stat windows_above)" -gt 0 ] || fail "a second click did not open the hero"
eyes_shot 3-hero-open
echo "open hero: ok"
"$Q" test aim_off >/dev/null
"$Q" test pad 97 >/dev/null; sleep 3 # B closes it
[ "$(stat windows_above)" = 0 ] || fail "the hero window did not close"

# the hero walks: two clicks on a tile near it; some tiles are blocked, so several are tried
moves="$(stat move_sequence)"
for z in 0.1 0.0 0.2 -0.1; do
	for x in -0.5 -0.4 -0.6 -0.3; do
		aim_at "$x" 0 "$z"
		"$Q" test click >/dev/null; sleep 1
		"$Q" test click >/dev/null; sleep 4
		[ "$(stat move_sequence)" = "$moves" ] || break 2
	done
done
[ "$(stat move_sequence)" != "$moves" ] || fail "the hero did not move"
shot 4-hero-moved
echo "move hero: ok"
# what the hero visited may ask or tell something on the screen: Enter accepts it
for _ in 1 2 3 4; do
	[ "$(stat windows_above)" -gt 0 ] || break
	eyes_shot 4-dialog
	"$Q" adb shell input -d "$(display)" keyevent ENTER
	sleep 2
done
[ "$(stat windows_above)" = 0 ] || fail "a dialog stayed open after the move"

# the hourglass ends the turn (table_panel.gd HOURGLASS_AT)
mark="$("$Q" mark-game)"
aim_at 0.86 0.045 0.42
shot 5-hover-hourglass
"$Q" adb logcat -c
"$Q" test click >/dev/null
sleep 1
[ "$("$Q" adb logcat -d | grep -c "table panel end_turn")" -gt 0 ] || fail "the hourglass was not clicked"
sleep 2
# the game asks on the screen whether to end the turn while a hero can still move
[ "$(stat windows_above)" = 0 ] || "$Q" adb shell input -d "$(display)" keyevent ENTER
MARK="$mark" "$Q" wait-game "Sending to all clients: 7NewTurn" 300 >/dev/null || fail "the next day did not start"
sleep 3
for _ in 1 2 3; do "$Q" test pad 97 >/dev/null; sleep 0.7; done # the new day's dialogs
"$Q" test aim_off >/dev/null
sleep 2
shot 6-next-day
echo "end turn: ok"
echo "$OUT"

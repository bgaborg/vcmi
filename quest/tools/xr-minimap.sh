#!/usr/bin/env bash
# Minimap test on the headset (quest/DATA_BRIDGE.md milestone 2): starts the first scenario, looks at the war table,
# moves the hero a few tiles, then reveals the map with the vcmieagles cheat. After each step a screenshot and the
# bridge stats; the fog generation must rise after the moves and after the cheat, the object list after the moves,
# the tile snapshot stays one.
# Screenshots and the stats in quest/out/minimap-<time>/.
# MAP_ROW=<n> plays row n of the G-size maps instead (1: the heaviest, as xr-perf.sh), PLAYER its first player (red).
# Godot frame timings while the table shows the revealed map: sample.csv.
# Needs `quest.sh awake` once per reboot. Usage: [MAP_ROW=1] xr-minimap.sh [apk]   (installs the APK first when given)

set -eo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
Q="$TOOLS/quest.sh"
OUT="$TOOLS/../out/minimap-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
command -v cygpath >/dev/null && OUT="$(cygpath -m "$OUT")"
trap '"$Q" test head_off >/dev/null' EXIT

keys() { "$Q" adb shell "d=\$(dumpsys display | sed -n 's/.*DisplayInfo{\"VCMI\", displayId \([0-9]*\).*/\1/p' | head -1); [ -n \"\$d\" ] || { echo 'no VCMI display' >&2; exit 1; }; $1"; }
# step <name>: the screen and the table, and the bridge stats, also in stats.txt
step() {
	"$Q" test head 0 0 1.6 >/dev/null
	"$Q" screenshot "$OUT/$1-screen.jpg" >/dev/null
	# the war table: right of the player and below the eyes (room.gd _build_props), the screen stays where it is
	"$Q" test head -80 -28 1.6 >/dev/null
	"$Q" screenshot "$OUT/$1-table.jpg" >/dev/null
	echo "$1: $("$Q" test bridge | sed -n 's/.*, bridge //p')" | tee -a "$OUT/stats.txt"
}
fog() { sed -n "s/^$1:.*\"fog_generation\": \([0-9]*\).*/\1/p" "$OUT/stats.txt"; }

if [ -z "${MAP_ROW:-}" ]; then
	OUT="$OUT" "$TOOLS/xr-smoke.sh" "$@" >/dev/null
else
	OUT="$OUT" SMOKE_TO_LOBBY=1 "$TOOLS/xr-smoke.sh" "$@" >/dev/null
	"$Q" test head 0 0 1.6 >/dev/null
	"$Q" test recenter >/dev/null
	# as xr-perf.sh: the G size filter, the map row, A to begin
	aim_px() { "$Q" test aim "$(awk -v x="$1" 'BEGIN {print (702 - x) / 15.47}')" "$(awk -v y="$2" 'BEGIN {print (632 - y) / 15.8}')" >/dev/null; }
	aim_px 657 440 && "$Q" test click >/dev/null && sleep 1
	aim_px 570 "$(awk -v r="$MAP_ROW" 'BEGIN {print 515 + 20.4 * (r - 1)}')" && "$Q" test click >/dev/null && sleep 1
	"$Q" test aim_off >/dev/null
	mark="$("$Q" mark-game)"
	"$Q" test pad 96 >/dev/null
	MARK="$mark" "$Q" wait-game "Server gives turn to ${PLAYER:-red}" 300 >/dev/null
fi
"$Q" test head 0 0 1.6 >/dev/null
"$Q" test recenter >/dev/null
for _ in 1 2 3 4 5 6; do "$Q" test pad 97 >/dev/null; sleep 0.7; done
step 1-start

# the selected hero walks: a blocked direction does nothing, so several are tried
keys 'for k in NUMPAD_6 NUMPAD_6 NUMPAD_6 NUMPAD_2 NUMPAD_2 NUMPAD_4 NUMPAD_8; do input -d $d keyevent $k; sleep 1.2; done'
sleep 1
step 2-moved

keys 'input -d $d keyevent TAB; sleep 0.5; input -d $d text vcmieagles; input -d $d keyevent ENTER'
sleep 2
step 3-revealed
"$Q" test head -80 -28 1.6 >/dev/null
"$Q" sample 10 "$OUT/sample.csv" >/dev/null
echo "$OUT"

[ "$(fog 2-moved)" -gt "$(fog 1-start)" ] || { echo "fog did not change with the hero moves" >&2; exit 1; }
[ "$(fog 3-revealed)" -gt "$(fog 2-moved)" ] || { echo "fog did not change with the cheat" >&2; exit 1; }
[ "$(grep -c '"tiles_generation": 1,' "$OUT/stats.txt")" = 3 ] || { echo "tile snapshot not taken exactly once" >&2; exit 1; }
objects() { sed -n "s/^$1:.*\"objects_sequence\": \([0-9]*\).*/\1/p" "$OUT/stats.txt"; }
grep -q '"objects": [1-9]' "$OUT/stats.txt" || { echo "no objects" >&2; exit 1; }
[ "$(objects 2-moved)" -gt "$(objects 1-start)" ] || { echo "objects did not change with the hero moves" >&2; exit 1; }

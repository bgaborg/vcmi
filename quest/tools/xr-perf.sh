#!/usr/bin/env bash
# Performance baseline on the headset (on a desk, nobody wearing it), for quest/DATA_BRIDGE.md milestone 0:
# starts a G-size (252x252) map with an upscaling filter, reveals it with a cheat, zooms out so every object is
# on screen and animates, and samples each step with `quest.sh sample` into quest/out/perf-<time>-<filter>/.
# Needs `quest.sh awake` once per reboot. The heaviest map, [HotA] Might and Magic (row 5), needs HotA's
# "Famous community maps" pack: "maps.famousmaps" : true in the headset's config/modSettings.json.
# A run takes at most 15 minutes: the wait for the AI turn gets what is left of that budget.
# Usage: xr-perf.sh <auto|none|xbrz2|...> [row of the map in the G list, default 1] [sample rows per step, default 15: about 25 s]
#        [colour of the human player, default red: the lobby's first playable colour on Might and Magic]

set -eo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
Q="$TOOLS/quest.sh"
FILTER="${1:?usage: xr-perf.sh <filter> [row] [rows] [player]}"
ROW="${2:-1}"
ROWS_PER_STEP="${3:-15}"
PLAYER="${4:-red}"
DEADLINE=$(($(date +%s) + 900))
CONFIG=/sdcard/Android/data/is.xyz.vcmi.quest/files/vcmi-data/config
game() { "$Q" adb shell "$@"; }
# keys and text into the game's virtual display (the cheat console needs text, the zoom keys have no gamepad binding)
keys() { game "d=\$(dumpsys display | sed -n 's/.*DisplayInfo{\"VCMI\", displayId \([0-9]*\).*/\1/p' | head -1); [ -n \"\$d\" ] || { echo 'no VCMI display' >&2; exit 1; }; $1"; }
sample() { "$Q" sample "$ROWS_PER_STEP" "$OUT/$1.csv" >/dev/null; }
shot() { "$Q" screenshot "$OUT/$1.jpg" >/dev/null; }
# angles of the test pointer for a point of the game screen, for the screen `xr-smoke.sh` sets (2 m away, 2.4 m wide)
aim_px() { "$Q" test aim "$(awk -v x="$1" 'BEGIN {print (702 - x) / 15.47}')" "$(awk -v y="$2" 'BEGIN {print (632 - y) / 15.8}')" >/dev/null; }
# seconds since the epoch on the host, for durations
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN {printf "%.1f", b - a}'; }

"$Q" stop
# the filter for this run. The settings file is put back when the script ends, after the game stops: it saves all
# of its settings on any later change. A backup left by a failed restore is the original, so it is kept.
sampler=
game "[ -e $CONFIG/settings.json.perf ] || cp $CONFIG/settings.json $CONFIG/settings.json.perf"
trap 'set +e; [ -z "$sampler" ] || kill "$sampler" 2>/dev/null; "$Q" stop; game "mv $CONFIG/settings.json.perf $CONFIG/settings.json"' EXIT
# a stopped run exits through the EXIT trap too; a `kill` lands when the running step returns (Ctrl-C at once)
trap 'exit 130' INT TERM
current="$(game "cat $CONFIG/settings.json.perf")"
echo "$current" | python -I -c '
import json, sys
s = json.load(sys.stdin)
s.setdefault("video", {})["upscalingFilter"] = sys.argv[1]
print(json.dumps(s, indent="\t"))' "$FILTER" | "$Q" adb shell "cat > $CONFIG/settings.json"

OUT="$(OUT="$TOOLS/../out/perf-$(date +%Y%m%d-%H%M%S)-$FILTER" SMOKE_TO_LOBBY=1 "$TOOLS/xr-smoke.sh" | tail -1)"
echo "$OUT"
"$Q" test head 0 0 1.6 >/dev/null
"$Q" test recenter >/dev/null
sample 1-lobby

# G size filter, then the map row, then A to begin
aim_px 657 440 && "$Q" test click >/dev/null && sleep 1
aim_px 570 "$(awk -v r="$ROW" 'BEGIN {print 515 + 20.4 * (r - 1)}')" && "$Q" test click >/dev/null && sleep 1
"$Q" test aim_off >/dev/null
shot 2-map-selected
mark="$("$Q" mark-game)"
start="$(now)"
"$Q" test pad 96 >/dev/null
MARK="$mark" "$Q" wait-game "Server gives turn to $PLAYER" 300 >/dev/null
echo "map load (to the first turn of $PLAYER): $(since "$start") s" | tee "$OUT/times.txt"

# B closes the start dialogs (globalReturn) and does nothing on the bare adventure map
for _ in 1 2 3 4 5 6; do "$Q" test pad 97 >/dev/null; sleep 0.7; done
shot 3-start
sample 2-start-view

keys 'input -d $d keyevent TAB; sleep 0.5; input -d $d text vcmieagles; input -d $d keyevent ENTER'
sleep 2
shot 4-revealed
sample 3-revealed-normal-zoom

# scroll with the right stick for a step
"$Q" test stick 1 0 >/dev/null
sample 4-scrolling-normal-zoom
"$Q" test stick 0 0 >/dev/null

# about 90 steps fit a 252x252 map on the screen; the AI turn below plays with every move on screen
keys 'for i in $(seq 100); do input -d $d keyevent NUMPAD_SUBTRACT; done'
# the zoom animates after the keys
sleep 6
shot 5-zoomed-out
sample 5-revealed-zoomed-out-whole-map

# end turn (E; the gamepad Back did nothing), Enter on the reminder that heroes can still move, then wait for the next own turn
mark="$("$Q" mark-game)"
start="$(now)"
keys 'input -d $d keyevent E; sleep 1; input -d $d keyevent ENTER'
left=$((DEADLINE - $(date +%s)))
"$Q" sample "$left" "$OUT/6-ai-turn.csv" >/dev/null &
sampler=$!
if MARK="$mark" "$Q" wait-game "Server gives turn to $PLAYER" "$left" >/dev/null; then
	echo "ai turn: $(since "$start") s" | tee -a "$OUT/times.txt"
else
	echo "ai turn: more than $(since "$start") s (the 15 minute budget ran out)" | tee -a "$OUT/times.txt"
fi
kill "$sampler" 2>/dev/null || true
sampler=
shot 6-next-turn
"$Q" test head_off >/dev/null
echo "$OUT"

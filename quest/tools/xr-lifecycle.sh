#!/usr/bin/env bash
# shellcheck disable=SC2016 # the single-quoted commands run on the headset, where their $ expand
# Data bridge lifecycle test on the headset (quest/DATA_BRIDGE.md milestone 1): new game, quick save and load,
# restart, end turn and replay of the enemy turn, quit to the main menu. After each step the `bridge` test command
# prints the bridge stats (ticks, observers, in_game, map); the observer count must grow by one per new game, load
# or replay pass, never twice for one map. Screenshots and the stats in quest/out/lifecycle-<time>/.
# Needs `quest.sh awake` once per reboot. Usage: xr-lifecycle.sh [apk]   (installs the APK first when given)

set -eo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
Q="$TOOLS/quest.sh"
OUT="$TOOLS/../out/lifecycle-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
command -v cygpath >/dev/null && OUT="$(cygpath -m "$OUT")"
# a failed step must not leave the test head pose on
trap '"$Q" test head_off >/dev/null' EXIT

# keys into the game's virtual display; `input keycombination` for Ctrl shortcuts
keys() { "$Q" adb shell "d=\$(dumpsys display | sed -n 's/.*DisplayInfo{\"VCMI\", displayId \([0-9]*\).*/\1/p' | head -1); [ -n \"\$d\" ] || { echo 'no VCMI display' >&2; exit 1; }; $1"; }
# step <name>: screenshot and bridge stats, also in stats.txt
step() {
	"$Q" screenshot "$OUT/$1.jpg" >/dev/null
	echo "$1: $("$Q" test bridge | sed -n 's/.*, bridge //p')" | tee -a "$OUT/stats.txt"
}
# wait_turn: the next turn start after the mark
wait_turn() { MARK="$1" "$Q" wait-game "Server gives turn to" "${2:-120}" >/dev/null; }

OUT="$OUT" "$TOOLS/xr-smoke.sh" "$@" >/dev/null
"$Q" test head 0 0 1.6 >/dev/null
"$Q" test recenter >/dev/null
# B closes the start dialogs
for _ in 1 2 3; do "$Q" test pad 97 >/dev/null; sleep 0.7; done
step 1-new-game
# while the human plays, the latest turn start is theirs
human="$("$Q" adb shell "grep 'Server gives turn to' /sdcard/Android/data/is.xyz.vcmi.quest/files/vcmi-data/cache/VCMI_Client_log.txt | tail -1" | sed -n 's/.*Server gives turn to \([a-z]*\).*/\1/p')"
[ -n "$human" ] || { echo "no player found" >&2; exit 1; }

keys 'input -d $d keyevent F8'
sleep 2
mark="$("$Q" mark-game)"
keys 'input -d $d keyevent F9; sleep 1; input -d $d keyevent ENTER'
wait_turn "$mark"
for _ in 1 2 3; do "$Q" test pad 97 >/dev/null; sleep 0.7; done
step 2-quick-load

mark="$("$Q" mark-game)"
keys 'input -d $d keyevent R; sleep 1; input -d $d keyevent ENTER'
wait_turn "$mark"
for _ in 1 2 3; do "$Q" test pad 97 >/dev/null; sleep 0.7; done
step 3-restart

# end turn, wait for the own turn again, then replay the enemy turns and let the replay finish
mark="$("$Q" mark-game)"
keys 'input -d $d keyevent E; sleep 1; input -d $d keyevent ENTER'
MARK="$mark" "$Q" wait-game "Server gives turn to $human" 300 >/dev/null
for _ in 1 2 3; do "$Q" test pad 97 >/dev/null; sleep 0.7; done
step 4-next-turn
mark="$("$Q" mark-game)"
# the picker lists the own current turn first; the entry below is the last enemy turn
# held 200 ms: a plain keycombination can arrive as R alone, and the ENTER below would then confirm a restart
keys 'input -d $d keycombination -t 200 CTRL_LEFT R; sleep 1; input -d $d keyevent DPAD_DOWN; sleep 0.5; input -d $d keyevent ENTER'
MARK="$mark" "$Q" wait-game "Replay: day" 30 >/dev/null
sleep 3
step 5-replay-running
# the end of a replay is not logged; a small map's enemy turn replays within this
sleep 40
step 6-after-replay

keys 'input -d $d keycombination -t 200 CTRL_LEFT M; sleep 1; input -d $d keyevent ENTER'
sleep 3
step 7-main-menu
echo "$OUT"
[ "$(sed -n 's/.*"observers": \([0-9]*\).*/\1/p' "$OUT/stats.txt" | xargs)" = "1 2 3 3 4 4 4" ] || { echo "wrong observer counts" >&2; exit 1; }
if ! { [ "$(grep -c '"in_game": false' "$OUT/stats.txt")" = 1 ] && tail -1 "$OUT/stats.txt" | grep -q '"in_game": false'; }; then
	echo "in_game wrong" >&2
	exit 1
fi

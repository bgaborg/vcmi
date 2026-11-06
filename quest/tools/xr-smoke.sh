#!/usr/bin/env bash
# Drives the XR host on the headset (on a desk, nobody wearing it) from start to the adventure map,
# with a screenshot per step in quest/out/smoke-<time>/. Waits on log lines, not on fixed times.
# Needs `quest.sh awake` once per reboot. Usage: xr-smoke.sh [apk]   (installs the APK first when given)

set -eo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
Q="$TOOLS/quest.sh"
OUT="$TOOLS/../out/smoke-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
command -v cygpath >/dev/null && OUT="$(cygpath -m "$OUT")"

shot() { "$Q" screenshot "$OUT/$1.jpg" >/dev/null; echo "$OUT/$1.jpg"; }
# step <game log regex> <seconds> <test command...>: runs the command, then waits for the game log line it causes
step() {
	local pattern="$1" seconds="$2" mark
	shift 2
	mark="$("$Q" mark-game)"
	"$Q" test "$@" >/dev/null
	MARK="$mark" "$Q" wait-game "$pattern" "$seconds" >/dev/null
}

if [ -n "${1:-}" ]; then
	"$Q" stop
	"$Q" install "$1" | tail -1
fi
"$Q" stop
mark="$("$Q" mark-log)"
"$Q" start-xr >/dev/null
MARK="$mark" "$Q" wait-log "VCMI XR: screen placed" 30 >/dev/null
MARK="$mark" "$Q" wait-log "Initialization of VCMI \(together\)" 60 >/dev/null

# a standing head looking ahead, screen recentred in front of it
"$Q" test head 0 0 1.6 >/dev/null
"$Q" test recenter >/dev/null
"$Q" test aim 0 0 >/dev/null
shot 1-intro
# clicks skip the intro videos until the main menu music starts
for _ in 1 2 3; do
	step "Playing music file Music/MainMenu" 4 click && break
done
shot 2-main-menu

# NEW GAME, then SINGLE SCENARIO at the same button position; the submenu logs nothing, so it gets a moment to open
"$Q" test aim -12 12 >/dev/null
"$Q" test click >/dev/null
sleep 1
step "Received CPack of type 16LobbyUpdateState" 20 click
shot 3-scenario-list

# A on the gamepad starts the scenario
step "Received CPack of type 16PlayerStartsTurn" 60 pad 96
"$Q" test aim_off >/dev/null
shot 4-adventure-map
# leave no simulated head behind: it would lock the screen to the head of whoever wears the headset next
"$Q" test head_off >/dev/null
echo "$OUT"

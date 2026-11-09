#!/usr/bin/env bash
# Renders the war room (quest/xr/room.gd) to PNGs without a headset, for design review.
# Usage (Git Bash on Windows, needs a GPU): quest/tools/render-room.sh [sprites]
#   sprites: only the views of the war table, with the sprites the headset saved (test command `sprites`, main.gd):
#   pulls files/sprites.bin from the headset when it is reachable, else uses quest/out/sprites-dump/sprites.bin.
#   Shader and layout changes in room.gd then render on the PC in seconds, without an APK.
# Writes quest/out/room-preview/{head,left,right,back,seated,table,overview}.png at 1920x1080: the views from the
# standing head (1.6 m, ~100 degrees like the Quest) ahead, left, right, behind and at the war table, ahead from a
# seated head (1.2 m), and a wide view from a corner. Also prints the draw calls of the head view and warns about
# geometry that could cover the screen. Needs an active desktop session (the window hangs while it is disconnected).
# The game layer is stood in by a cropped headset screenshot at the default screen pose (2 m, 2.4 m wide).
# Scene: quest/xr/preview/ (not exported). Godot: the official 4.7.2 Windows editor, unpacked by hand
# into $GODOT_WIN (default ~/vcmi-tools/godot-4.7.2-win) from the release zip checked against SHA512-SUMS.txt.

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT_WIN:-$HOME/vcmi-tools/godot-4.7.2-win}/Godot_v4.7.2-stable_win64_console.exe"
[ -x "$GODOT" ] || { echo "Godot not found: $GODOT" >&2; exit 1; }

# the import rewrites project.godot without its comments: restore it once, however this script ends (as bake-room.sh)
KEEP="$(mktemp)"
cp "$REPO/quest/xr/project.godot" "$KEEP"
trap 'mv "$KEEP" "$REPO/quest/xr/project.godot"' EXIT
trap 'exit 1' INT TERM
# the Mobile renderer, as on the Quest; no XR, so a PC OpenXR runtime is not started
"$GODOT" --headless --path "$REPO/quest/xr" --import > /dev/null 2>&1
ARGS=()
if [ "${1:-}" = sprites ]; then
	ARGS=(-- sprites "${@:2}")
	mkdir -p "$REPO/quest/out/sprites-dump"
	DUMP="$REPO/quest/out/sprites-dump"
	command -v cygpath >/dev/null && DUMP="$(cygpath -m "$DUMP")"
	# Wi-Fi adb drops between sessions: connect first when the headset's address is given (QUEST_ADDRESS=ip:5555)
	[ -z "${QUEST_ADDRESS:-}" ] || "$REPO/quest/tools/quest.sh" adb connect "$QUEST_ADDRESS" >/dev/null 2>&1 || true
	"$REPO/quest/tools/quest.sh" adb pull /sdcard/Android/data/is.xyz.vcmi.quest/files/sprites.bin "$DUMP/" 2>/dev/null \
		|| echo "headset not reachable: using the last quest/out/sprites-dump/sprites.bin"
fi
STATUS=0
LOG="$("$GODOT" --rendering-method mobile --xr-mode off --resolution 640x360 --path "$REPO/quest/xr" res://preview/preview.tscn "${ARGS[@]}" 2>&1)" || STATUS=$?
echo "$LOG"
if [ "$STATUS" -ne 0 ] || grep -q "SCRIPT ERROR" <<< "$LOG"; then exit 1; fi
ls "$REPO/quest/out/room-preview/"*.png

#!/usr/bin/env bash
# Bakes the war room lightmap (quest/xr/assets/room/room.lmbake + room.exr) with the Windows Godot editor.
# Usage (Git Bash on Windows, needs a GPU): quest/tools/bake-room.sh, after changing anything static in quest/xr/room.gd.
# Opens quest/xr/preview/bake_room.tscn in the editor, which presses Bake Lightmaps and quits. Commit the .lmbake,
# the .exr and its .import. The export (export-xr.sh) only imports the result, so it needs no GPU.
# Needs an active desktop session: the editor window hangs while the Windows session is disconnected or locked.
# Godot: as render-room.sh, in $GODOT_WIN (default ~/vcmi-tools/godot-4.7.2-win).

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT_WIN:-$HOME/vcmi-tools/godot-4.7.2-win}/Godot_v4.7.2-stable_win64_console.exe"
[ -x "$GODOT" ] || { echo "Godot not found: $GODOT" >&2; exit 1; }

# the editor (also the import) rewrites project.godot without its comments: restore it once, however this script ends
KEEP="$(mktemp)"
cp "$REPO/quest/xr/project.godot" "$KEEP"
trap 'mv "$KEEP" "$REPO/quest/xr/project.godot"' EXIT
trap 'exit 1' INT TERM
# an editor killed during a bake leaves this lock, and the next editor would wait at a recovery mode dialog
rm -f "${APPDATA:-$HOME/AppData/Roaming}/Godot/app_userdata/VCMI XR/.recovery_mode_lock"
"$GODOT" --headless --path "$REPO/quest/xr" --import > /dev/null 2>&1
# a script error would leave the editor open, waiting
if timeout 120 "$GODOT" --headless --xr-mode off --path "$REPO/quest/xr" --check-only --script res://room.gd 2>&1 | grep -A1 "SCRIPT ERROR"; then
	exit 1
fi
LOG="$(timeout 900 "$GODOT" -e --path "$REPO/quest/xr" res://preview/bake_room.tscn -- --bake-room 2>&1)" || { echo "$LOG"; exit 1; }
echo "$LOG" | grep -E "room bake|ERROR|WARNING" || true
grep -q "room bake: [1-9]" <<< "$LOG"

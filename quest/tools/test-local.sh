#!/usr/bin/env bash
# Runs the Godot host's local tests (quest/xr/tests/*_test.gd) headless on the PC, in seconds, without an APK or the
# headset. For logic of the host that needs no game (picking, layout maths); game behaviour is tested on the Quest.
# A test that does not end within 60 s (a script error stops it before quit) fails.
# Usage (Git Bash on Windows): quest/tools/test-local.sh [name]   (name: one test, e.g. table_uv)
# Godot: as render-room.sh, the 4.7.2 Windows editor in $GODOT_WIN (default ~/vcmi-tools/godot-4.7.2-win).

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT_WIN:-$HOME/vcmi-tools/godot-4.7.2-win}/Godot_v4.7.2-stable_win64_console.exe"
[ -x "$GODOT" ] || { echo "Godot not found: $GODOT" >&2; exit 1; }

# the import rewrites project.godot without its comments: restore it however this script ends (as render-room.sh)
KEEP="$(mktemp)"
cp "$REPO/quest/xr/project.godot" "$KEEP"
trap 'mv "$KEEP" "$REPO/quest/xr/project.godot"' EXIT
trap 'exit 1' INT TERM
"$GODOT" --headless --path "$REPO/quest/xr" --import > /dev/null 2>&1

STATUS=0
for test in "$REPO"/quest/xr/tests/${1:-*}_test.gd; do
	name="$(basename "$test")"
	timeout 60 "$GODOT" --headless --xr-mode off --path "$REPO/quest/xr" --script "res://tests/$name" 2>&1 | grep -E "_test: |ERROR|SCRIPT" || STATUS=1
	[ "${PIPESTATUS[0]}" -eq 0 ] || STATUS=1
done
exit $STATUS

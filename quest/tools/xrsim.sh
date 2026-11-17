#!/usr/bin/env bash
# Runs the Godot XR host (quest/xr) on the PC with Meta XR Simulator as its OpenXR runtime, for this run only (the
# system's active runtime stays as it is), and plays a script of test commands in it (pc_bridge.gd). With the Windows
# build of the game (quest/tools/make-pc.sh) the game runs inside the host, as on the headset; without it the room, the
# table and the controllers run alone. Scripts: xrsim-smoke.txt (the host's modes), xrsim-game.txt (into a scenario).
# Usage (Git Bash on Windows): quest/tools/xrsim.sh [script]   (default quest/tools/xrsim-smoke.txt)
# Writes quest/out/xrsim/<shot>.png (rendered by the host itself, pc_bridge.gd) and run.log. Fails when the
# host reports a script error, does not reach the script's `quit` within XRSIM_TIMEOUT, or a shot differs from the baseline
# (BASELINE=1 quest/tools/xrsim.sh [script] keeps a run's shots as the script's baseline, in quest/out/xrsim-baseline/).
# Simulator: Meta XR Simulator (`metavr tools install xrsim`, quest/EMULATORS.md) in $XRSIM (default v207.1 in AppData).
# Godot: as render-room.sh, the 4.7.2 Windows editor in $GODOT_WIN.
# Meta XR Operator (`metavr tools install xroperator`, quest/EMULATORS.md), when installed in $XROPERATOR, is loaded as an
# OpenXR API layer for this run: `metavr xroperator call <tool>` or an agent through `metavr mcp server` then drives the
# controllers and the head and captures the compositor's image. XRSIM_TIMEOUT (default 120 s) bounds the run, for
# xrsim-live.txt, which keeps the host open to drive it that way.

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT_WIN:-$HOME/vcmi-tools/godot-4.7.2-win}/Godot_v4.7.2-stable_win64_console.exe"
XRSIM="${XRSIM:-$APPDATA/metavr/tools/xrsim/PFiles/MetaXRSimulator/v207.1}"
OPERATORS=("$APPDATA"/metavr/tools/meta-xr-operator/*/windows) # shortcut: the last by name, so with several versions 207.10 sorts before 207.9
XROPERATOR="${XROPERATOR:-${OPERATORS[-1]}}"
TIMEOUT="${XRSIM_TIMEOUT:-120}"
SCRIPT="$(realpath "${1:-$REPO/quest/tools/xrsim-smoke.txt}")" # absolute: Godot resolves a relative one elsewhere
[ -x "$GODOT" ] || { echo "Godot not found: $GODOT" >&2; exit 1; }
[ -f "$XRSIM/meta_openxr_simulator.json" ] || { echo "Meta XR Simulator not found: $XRSIM" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "no script: $SCRIPT" >&2; exit 1; }
OUT="$REPO/quest/out/xrsim"
mkdir -p "$OUT"
rm -f "$OUT"/*.png

# the import rewrites project.godot without its comments: restore it however this script ends (as render-room.sh)
KEEP="$(mktemp)"
cp "$REPO/quest/xr/project.godot" "$KEEP"
trap 'mv "$KEEP" "$REPO/quest/xr/project.godot"' EXIT
trap 'exit 1' INT TERM

rm -f "$OUT/run.log"
# each run starts from the host's defaults: an environment or screen place saved by an earlier run would change the shots
rm -f "$APPDATA/Godot/app_userdata/VCMI XR/screen.cfg"
if [ -f "$XROPERATOR/XrApiLayer_METAX_operator.json" ]; then
	XR_API_LAYER_PATH="$(cygpath -w "$XROPERATOR")"
	export XR_API_LAYER_PATH XR_ENABLE_API_LAYERS=XR_APILAYER_METAX_operator
	echo "xrsim: Meta XR Operator on http://127.0.0.1:8720"
fi
# registers new extensions (vcmi_xr_pc.gdextension) in .godot/extension_list.cfg, which a plain run only reads
timeout 120 "$GODOT" --headless --path "$REPO/quest/xr" --import > "$OUT/import.log" 2>&1 || true
XR_RUNTIME_JSON="$(cygpath -w "$XRSIM/meta_openxr_simulator.json")" VCMI_XR_SCRIPT="$(cygpath -w "$SCRIPT")" \
	VCMI_XR_SHOTS="$(cygpath -w "$OUT")" timeout "$TIMEOUT" "$GODOT" --path "$REPO/quest/xr" > "$OUT/run.log" 2>&1 || true
grep -v "^\[Meta XR Simulator\]" "$OUT/run.log" | grep -E "OpenXR: Running|VCMI XR|SCRIPT ERROR" || true
ls "$OUT"/*.png 2>/dev/null || true
if grep -q "SCRIPT ERROR" "$OUT/run.log"; then
	echo "xrsim: FAIL (script error)"
	exit 1
fi
grep -q "VCMI XR sim: quit" "$OUT/run.log" || { echo "xrsim: FAIL (the script did not reach quit)"; exit 1; }
# against the shots of a run kept as the reference (BASELINE=1 keeps this run's), as Meta's vrs_pixmatch.py compares a
# replay's frames: a shot that differs from its reference in more than 2 % of its pixels fails
BASE="$REPO/quest/out/xrsim-baseline/$(basename "$SCRIPT" .txt)"
if [ "${BASELINE:-0}" = 1 ]; then
	rm -rf "$BASE" && mkdir -p "$BASE" && cp "$OUT"/*.png "$BASE"/
	echo "xrsim: baseline kept in $BASE"
elif [ -d "$BASE" ]; then
	python "$REPO/quest/tools/xrsim-compare.py" "$BASE" "$OUT" || { echo "xrsim: FAIL (shots differ from the baseline)"; exit 1; }
fi
echo "xrsim: PASS"

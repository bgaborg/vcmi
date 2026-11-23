#!/usr/bin/env bash
# The PC's `quest.sh test`: sends one command to the Godot host that quest/tools/xrsim.sh runs in Meta XR Simulator
# (xrsim-live.txt keeps it open) and prints the host's lines from the next two seconds. The commands are the
# headset's test commands (main.gd _on_test_command) plus pc_bridge.gd's: shot <name>, tap <x> <y>, type <text>,
# key <android key code>, quit.
# Usage: quest/tools/xrsim-cmd.sh <command> [args...]   e.g. quest/tools/xrsim-cmd.sh key 61
set -eo pipefail
OUT="$(cd "$(dirname "$0")/../.." && pwd)/quest/out/xrsim"
[ $# -gt 0 ] || { echo "usage: $0 <command> [args...]" >&2; exit 1; }
[ -f "$OUT/run.log" ] || { echo "the host is not running (quest/tools/xrsim.sh)" >&2; exit 1; }
before=$(wc -l < "$OUT/run.log")
echo "$*" >> "$OUT/inbox.txt"
sleep "${WAIT:-2}"
tail -n "+$((before + 1))" "$OUT/run.log" | grep -E "^VCMI XR" || true

#!/usr/bin/env bash
# adb helper for the VCMI Quest build. Run `quest/tools/quest.sh help`.

set -euo pipefail

# Git Bash would rewrite device paths such as /sdcard/... into Windows paths
export MSYS_NO_PATHCONV=1

PKG="${VCMI_QUEST_PKG:-is.xyz.vcmi.quest}"
DATA_DIR="/sdcard/Android/data/$PKG/files/vcmi-data"
LOG_DIR="$DATA_DIR/cache"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/out"

if command -v adb >/dev/null 2>&1; then
	ADB=adb
elif [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
	ADB="$ANDROID_HOME/platform-tools/adb"
elif [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" ]; then
	ADB="$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"
else
	echo "adb not found: add platform-tools to PATH or set ANDROID_HOME" >&2
	exit 1
fi

# Several entries for one headset (wireless debugging and `adb tcpip 5555`) make plain adb calls fail: pick one, port 5555 first
if [ -z "${ANDROID_SERIAL:-}" ]; then
	devices="$("$ADB" devices | tr -d '\r' | awk '$2 == "device" { print $1 }')"
	ANDROID_SERIAL="$(echo "$devices" | grep ':5555$' | head -1 || true)"
	[ -n "$ANDROID_SERIAL" ] || ANDROID_SERIAL="$(echo "$devices" | head -1)"
	# none listed: leave it unset, so adb reports the missing device itself
	if [ -n "$ANDROID_SERIAL" ]; then export ANDROID_SERIAL; else unset ANDROID_SERIAL; fi
fi

adb_shell() { "$ADB" shell "$@" | tr -d '\r'; }

app_pid() { adb_shell pidof "$PKG" || true; }

# epoch seconds with milliseconds: logcat -T takes them, and they have no space to quote
device_time() { adb_shell date +%s.%3N; }

# lines in the game log; the game starts a new log on each start
game_lines() { adb_shell "wc -l < '$LOG_DIR/VCMI_Client_log.txt' 2>/dev/null || echo 0"; }

# wait_on_device <source command> <regex> <seconds>: prints the first matching line of the source, fails on timeout.
# The loop runs on the headset: one adb call, and no logcat stream that adb.exe would keep open after grep exits.
wait_on_device() {
	local pattern="${2//\'/\'\\\'\'}"
	# a deadline, not a pass count: one pass over a long log takes longer than its 0.25 s sleep
	adb_shell "end=\$((\$(date +%s) + $3)); while [ \$(date +%s) -lt \$end ]; do $1 | grep -m1 -E '$pattern' && exit 0; sleep 0.25; done; echo 'timed out' >&2; exit 1"
}

usage() {
	cat <<EOF
Usage: quest.sh <command> [args]

  devices                 list connected devices
  adb <args>              run adb on the selected headset
  info                    device model, OS build, refresh rate, installed app version
  install <apk>           install or update the APK (keeps app data)
  start                   launch the app (refuses if it is already running)
  stop                    force-stop the app
  restart                 force-stop and launch the app
  start-xr                launch the immersive Godot host directly, without the launcher
  logcat                  follow logcat for the running app
  pull-logs [dir]         copy VCMI logs from the device (default: quest/out/logs-<timestamp>)
  sample <rows> [csv]     rows about 1.7 s apart: VrApi frame stats, game / Godot / process CPU, PSS, native heap, graphics, temperature
  screenshot [jpg]        capture the headset view (works for immersive apps; black while the headset sleeps)
  panel [png]             capture the display panel as shown (both eyes, lens-distorted); the metacam screenshot can draw
                          layers wrong (a black block over the cylinder layer), the panel cannot
  awake                   keep the headset awake and rendering without being worn (until reboot)
  sleep-normal            undo awake: the proximity sensor controls sleep again
  wait-log <regex> [s]    wait until a new logcat line matches (default 60 s); prints it, fails on timeout
  wait-game <regex> [s]   the same for a new line of the game log (VCMI_Client_log.txt, more detail than logcat)
  mark-log, mark-game     print the current position; MARK=<it> wait-log|wait-game then also matches lines after it,
                          for events that can happen before the wait starts
  test <cmd> [a] [b] [c]  send a test command to the Godot XR host (quest/xr/main.gd): head yaw pitch height,
                          head_off, recenter, aim yaw pitch, aim_off, click, rclick, pad keycode, stick x y,
                          lstick x y, screen distance width, env index, lmenu seconds, wrist 1/0, gfx feature on, probe,
                          bridge (list: quest/PHASE2.md); the result is in logcat as "VCMI XR test:"

Package: $PKG (override with VCMI_QUEST_PKG)
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
	devices)
		"$ADB" devices -l
		;;
	adb)
		"$ADB" "$@"
		;;
	info)
		echo "model:    $(adb_shell getprop ro.product.model)"
		echo "build:    $(adb_shell getprop ro.build.display.id)"
		echo "android:  $(adb_shell getprop ro.build.version.release) (SDK $(adb_shell getprop ro.build.version.sdk))"
		echo "refresh:  $(adb_shell getprop debug.oculus.refreshRate)"
		adb_shell dumpsys package "$PKG" | grep -E "versionName|versionCode" | head -2 || echo "$PKG is not installed"
		;;
	install)
		[ $# -ge 1 ] || { usage; exit 1; }
		"$ADB" install -r "$1"
		;;
	start)
		# A second launcher intent into a running game hangs ActivityLauncher (ANR) and the process gets killed
		if [ -n "$(app_pid)" ]; then
			echo "$PKG is already running; use restart" >&2
			exit 1
		fi
		adb_shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
		echo "started $PKG"
		;;
	start-xr)
		if [ -n "$(app_pid)" ]; then
			echo "$PKG is already running; stop it first" >&2
			exit 1
		fi
		adb_shell am start -a android.intent.action.MAIN -c com.oculus.intent.category.VR -n "$PKG/eu.vcmi.vcmi.VcmiXrActivity"
		;;
	stop)
		adb_shell am force-stop "$PKG"
		;;
	restart)
		adb_shell am force-stop "$PKG"
		adb_shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
		echo "restarted $PKG"
		;;
	logcat)
		pid="$(app_pid)"
		[ -n "$pid" ] || { echo "$PKG is not running" >&2; exit 1; }
		# pidof returns several PIDs when the editor or server process runs too
		args=()
		for p in $pid; do args+=(--pid="$p"); done
		"$ADB" logcat "${args[@]}"
		;;
	pull-logs)
		out="${1:-$OUT_DIR/logs-$(date +%Y%m%d-%H%M%S)}"
		mkdir -p "$out"
		for f in $(adb_shell ls "$LOG_DIR" | grep -E '\.txt$'); do
			"$ADB" pull "$LOG_DIR/$f" "$out/$f" >/dev/null
			echo "$out/$f"
		done
		"$ADB" logcat -d > "$out/logcat.txt"
		echo "$out/logcat.txt"
		;;
	sample)
		[ $# -ge 1 ] || { usage; exit 1; }
		rows="$1"
		mkdir -p "$OUT_DIR"
		csv="${2:-$OUT_DIR/sample-$(date +%Y%m%d-%H%M%S).csv}"
		echo "time,fps,app_gpu_ms,cpu_gpu_ms,gpu_util,cpu_util,game_cpu_percent,godot_cpu_percent,process_cpu_percent,pss_kb,native_heap_kb,graphics_kb,battery_temp_c" > "$csv"
		# one row per loop, measured on the headset in one adb call: the compositor's VrApi line of the last second,
		# thread CPU over 1 s (SDLThread: the game loop, VkThread: Godot), the memory summary
		for ((i = 0; i < rows; i++)); do
			# shellcheck disable=SC2016 # the single-quoted part expands on the headset
			row="$(adb_shell "P=$PKG; "'
p=$(pidof $P) || exit 1
v=$(logcat -d -s VrApi:I | tail -1)
f() { echo "$v" | sed -n "s/.*[,:] *$1=\([0-9.]*\).*/\1/p"; }
c=$(top -H -b -n 2 -d 1 -p $p | awk "/^Threads/ {n++} n == 2 && \$1 ~ /^[0-9]+\$/ {s += \$9; if (\$12 == \"SDLThread\" && \$9 > g) g = \$9; if (\$12 == \"VkThread\" && \$9 > k) k = \$9} END {printf \"%s,%s,%s\", g + 0, k + 0, s}")
m=$(dumpsys meminfo $p | awk "/TOTAL PSS:/ {t = \$3} /Native Heap:/ {n = \$3} /Graphics:/ {g = \$2} END {printf \"%s,%s,%s\", t, n, g}")
echo "$(f FPS),$(f App),$(f "CPU&GPU"),$(f GPU%),$(f CPU%),$c,$m,$(dumpsys battery | awk "/temperature:/ {print \$2 / 10}")"')" || { echo "$PKG is not running" >&2; break; }
			echo "$(date +%H:%M:%S),$row" | tee -a "$csv"
		done
		echo "saved $csv"
		;;
	screenshot)
		# screencap is empty for immersive apps; the Meta capture service composites all layers
		mkdir -p "$OUT_DIR"
		jpg="${1:-$OUT_DIR/screenshot-$(date +%Y%m%d-%H%M%S).jpg}"
		# Git Bash: adb.exe needs a Windows path (path conversion is off for the device paths)
		command -v cygpath >/dev/null && jpg="$(cygpath -m "$jpg")"
		before="$(adb_shell ls -t /sdcard/Oculus/Screenshots | head -1)"
		adb_shell am startservice -n com.oculus.metacam/.capture.CaptureService -a TAKE_SCREENSHOT >/dev/null
		for _ in $(seq 20); do
			latest="$(adb_shell ls -t /sdcard/Oculus/Screenshots | head -1)"
			[ -n "$latest" ] && [ "$latest" != "$before" ] && break
			adb_shell sleep 0.5
		done
		[ "$latest" != "$before" ] || { echo "no new screenshot" >&2; exit 1; }
		adb_shell sleep 1 # the file is written after it is listed
		"$ADB" pull "/sdcard/Oculus/Screenshots/$latest" "$jpg" >/dev/null
		echo "$jpg"
		;;
	panel)
		mkdir -p "$OUT_DIR"
		png="${1:-$OUT_DIR/panel-$(date +%Y%m%d-%H%M%S).png}"
		command -v cygpath >/dev/null && png="$(cygpath -m "$png")"
		adb_shell screencap -p /sdcard/vcmi-panel.png
		"$ADB" pull /sdcard/vcmi-panel.png "$png" >/dev/null
		adb_shell rm /sdcard/vcmi-panel.png
		echo "$png"
		;;
	awake)
		adb_shell input keyevent KEYCODE_WAKEUP
		adb_shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null
		echo "proximity sensor overridden until reboot or: quest.sh sleep-normal"
		;;
	sleep-normal)
		adb_shell am broadcast -a com.oculus.vrpowermanager.automation_disable >/dev/null
		;;
	wait-log|wait-game)
		[ -n "${1:-}" ] || { usage; exit 1; }
		if [ "$cmd" = wait-log ]; then
			source="logcat -d -T '${MARK:-$(device_time)}'"
		else
			source="tail -n +$(( ${MARK:-$(game_lines)} + 1 )) '$LOG_DIR/VCMI_Client_log.txt'"
		fi
		wait_on_device "$source" "$1" "${2:-60}"
		;;
	mark-log)
		device_time
		;;
	mark-game)
		game_lines
		;;
	test)
		[ -n "${1:-}" ] || { usage; exit 1; }
		since="$(device_time)"
		adb_shell am broadcast -a is.xyz.vcmi.quest.TEST -p "$PKG" --es cmd "$1" --ef a "${2:-0}" --ef b "${3:-0}" --ef c "${4:-0}" >/dev/null
		wait_on_device "logcat -d -s godot:I -T '$since'" "VCMI XR test: $1 ->" 10
		;;
	help|-h|--help)
		usage
		;;
	*)
		usage
		exit 1
		;;
esac

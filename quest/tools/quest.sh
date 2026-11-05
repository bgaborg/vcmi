#!/usr/bin/env bash
# adb helper for the VCMI Quest build. Run `quest/tools/quest.sh help`.

set -euo pipefail

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

adb_shell() { "$ADB" shell "$@" | tr -d '\r'; }

app_pid() { adb_shell pidof "$PKG" || true; }

usage() {
	cat <<EOF
Usage: quest.sh <command> [args]

  devices                 list connected devices
  info                    device model, OS build, refresh rate, installed app version
  install <apk>           install or update the APK (keeps app data)
  start                   launch the app
  stop                    force-stop the app
  logcat                  follow logcat for the running app
  pull-logs [dir]         copy VCMI logs from the device (default: quest/out/logs-<timestamp>)
  sample <seconds> [csv]  sample PSS memory, CPU and battery temperature once per second
  screenshot [png]        capture the headset view

Package: $PKG (override with VCMI_QUEST_PKG)
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
	devices)
		"$ADB" devices -l
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
		adb_shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
		echo "started $PKG"
		;;
	stop)
		adb_shell am force-stop "$PKG"
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
		seconds="$1"
		mkdir -p "$OUT_DIR"
		csv="${2:-$OUT_DIR/sample-$(date +%Y%m%d-%H%M%S).csv}"
		echo "time,pss_kb,cpu_percent,battery_temp_c" > "$csv"
		for ((i = 0; i < seconds; i++)); do
			pid="$(app_pid | awk '{print $1}')"
			if [ -z "$pid" ]; then
				echo "$PKG is not running" >&2
				break
			fi
			pss="$(adb_shell dumpsys meminfo "$PKG" | awk '/TOTAL PSS:/ {print $3; exit} /^ *TOTAL / {print $2; exit}')"
			cpu="$(adb_shell top -b -n 1 -p "$pid" | awk -v p="$pid" '$1 == p {print $9}')"
			temp="$(adb_shell dumpsys battery | awk '/temperature:/ {printf "%.1f", $2 / 10}')"
			echo "$(date +%H:%M:%S),$pss,$cpu,$temp" | tee -a "$csv"
			sleep 1
		done
		echo "saved $csv"
		;;
	screenshot)
		mkdir -p "$OUT_DIR"
		png="${1:-$OUT_DIR/screenshot-$(date +%Y%m%d-%H%M%S).png}"
		"$ADB" exec-out screencap -p > "$png"
		echo "$png"
		;;
	help|-h|--help)
		usage
		;;
	*)
		usage
		exit 1
		;;
esac

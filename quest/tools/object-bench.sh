#!/usr/bin/env bash
# Object benchmark on the headset, without the APK or a game start: times the bridge's object list and sprite decode
# (quest/bridge/ObjectScan, SpriteDecode) on a saved game, with real Quest timings, in about a minute per change.
#
#   object-bench.sh build                  in WSL, in the Linux checkout of make-apk.sh (after one APK build there):
#                                          builds libobject-bench.so and bench.jar into quest/out/object-bench/
#   object-bench.sh run [save] [repeats]   in Git Bash: pushes them with the libraries they need and runs them; the
#                                          default save is the heaviest map, Might and Magic (252x252x2, 53k objects)
#
# The library reads the game's data from the headset (Data, Mods, Maps, Saves of the installed game) and a copy of
# its config, so the game's own settings are not touched. Stop the game first: `run` does.

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/quest/out/object-bench"
TOOLS="${VCMI_TOOLS:-$HOME/vcmi-tools}"
DEVICE=/data/local/tmp/object-bench
GAME_DATA=/sdcard/Android/data/is.xyz.vcmi.quest/files/vcmi-data
DEFAULT_SAVE="Saves/Might and Magic HOTA v1.2 2026-11-06 1/Autosave-111.vsgm1"

case "${1:-}" in
build)
	# the toolchain make-apk.sh installs
	export PATH="$HOME/.local/bin:$TOOLS/jdk17/bin:$PATH" JAVA_HOME="$TOOLS/jdk17"
	BUILD="$REPO/out/build/android-conan-ninja-release"
	[ -d "$BUILD" ] || { echo "no Android build tree: run make-apk.sh first" >&2; exit 1; }
	cmake "$BUILD" -DCMAKE_PROJECT_VCMI_INCLUDE="$REPO/quest/bench/bench.cmake" >/dev/null
	cmake --build "$BUILD" --target object-bench
	NDK="$(sed -n 's|^set(CMAKE_SYSROOT \(.*\)/toolchains/llvm/.*|\1|p' "$REPO/conan-generated/conan_toolchain.cmake")"
	BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
	mkdir -p "$OUT/libs"
	"$BIN/llvm-strip" -o "$OUT/libobject-bench.so" "$BUILD/object-bench/libobject-bench.so"
	# the shared libraries it needs, found the way the dynamic linker would, from the APK build's native libraries
	LIBS="$BUILD/android-build/libs/arm64-v8a"
	rm -f "$OUT/libs/"*.so
	todo=("$OUT/libobject-bench.so")
	while [ ${#todo[@]} -gt 0 ]; do
		lib="${todo[0]}"
		todo=("${todo[@]:1}")
		for need in $("$BIN/llvm-readelf" -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
			if [ -f "$LIBS/$need" ] && [ ! -f "$OUT/libs/$need" ]; then
				cp "$LIBS/$need" "$OUT/libs/"
				todo+=("$OUT/libs/$need")
			fi
		done
	done
	rm -rf "$OUT/classes"
	javac --release 8 -cp "$TOOLS/android-sdk/platforms/android-35/android.jar" -d "$OUT/classes" "$REPO/quest/bench/NativeMethods.java"
	BUILD_TOOLS=("$TOOLS"/android-sdk/build-tools/*) # the newest last: the glob sorts the version names
	"${BUILD_TOOLS[-1]}/d8" --min-api 24 --output "$OUT" "$OUT/classes/eu/vcmi/vcmi/NativeMethods.class"
	mv "$OUT/classes.dex" "$OUT/bench.dex"
	ls -la "$OUT" "$OUT/libs"
	;;
run)
	Q="$REPO/quest/tools/quest.sh"
	SAVE="${2:-$DEFAULT_SAVE}"
	REPEATS="${3:-10}"
	OUT_WIN="$OUT"
	command -v cygpath >/dev/null && OUT_WIN="$(cygpath -m "$OUT")"
	"$Q" stop >/dev/null
	"$Q" adb shell "mkdir -p $DEVICE/libs $DEVICE/internal $DEVICE/data"
	"$Q" adb push "$OUT_WIN/libobject-bench.so" "$OUT_WIN/bench.dex" "$DEVICE/" >/dev/null
	"$Q" adb push "$OUT_WIN/libs/." "$DEVICE/libs/" >/dev/null
	# the game's internal data (copied from the APK) is the repository's config and its own mod
	REPO_WIN="$REPO"
	command -v cygpath >/dev/null && REPO_WIN="$(cygpath -m "$REPO")"
	"$Q" adb push "$REPO_WIN/config" "$REPO_WIN/Mods" "$DEVICE/internal/" >/dev/null
	# the user data: the game's own folders, and a copy of its config so settings written here stay here
	"$Q" adb shell "cd $DEVICE/data && for d in Data Mods Maps Saves; do [ -e \$d ] || ln -s $GAME_DATA/\$d \$d; done; rm -rf config cache; cp -r $GAME_DATA/config config; mkdir -p cache"
	"$Q" adb shell "cd $DEVICE && VCMI_DATA_ROOT=$DEVICE/data VCMI_INTERNAL_ROOT=$DEVICE/internal LD_LIBRARY_PATH=$DEVICE/libs CLASSPATH=$DEVICE/bench.dex app_process $DEVICE eu.vcmi.vcmi.NativeMethods $DEVICE/libobject-bench.so '$DEVICE/data/$SAVE' $REPEATS"
	# the sprite table and page 0 of the sprite atlas (a PPM: PIL or most image viewers open it)
	"$Q" adb pull "$DEVICE/sprites.tsv" "$DEVICE/page0.ppm" "$OUT_WIN/" >/dev/null && echo "pulled sprites.tsv and page0.ppm to $OUT"
	;;
*)
	sed -n '2,12p' "$0"
	exit 1
	;;
esac

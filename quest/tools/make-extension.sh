#!/usr/bin/env bash
# Builds the Godot extension of the Quest build (quest/xr/extension, libvcmi_xr.so) into
# android/vcmi-app/src/quest/jniLibs/arm64-v8a/, with the NDK of the conan toolchain the game is built with.
# Downloads the pinned godot-cpp into $VCMI_TOOLS (default ~/vcmi-tools) on first run.
# Used by make-apk.sh after the conan install; run on Linux or WSL.

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS="${VCMI_TOOLS:-$HOME/vcmi-tools}"

# the 4.5 API loads on later Godot versions, such as the 4.7.2 in android/vcmi-app/quest.gradle
GODOT_CPP_TAG=godot-4.5-stable
GODOT_CPP="$TOOLS/godot-cpp-$GODOT_CPP_TAG"
BUILD="$TOOLS/vcmi-xr-extension-build"

[ -d "$GODOT_CPP" ] || git clone -q --depth 1 --branch "$GODOT_CPP_TAG" https://github.com/godotengine/godot-cpp "$GODOT_CPP"

# the NDK root, from the sysroot the conan toolchain of the game sets
NDK="$(sed -n 's|^set(CMAKE_SYSROOT \(.*\)/toolchains/llvm/.*|\1|p' "$REPO/conan-generated/conan_toolchain.cmake")"
[ -f "$NDK/build/cmake/android.toolchain.cmake" ] || { echo "NDK not found: run the conan install of make-apk.sh first" >&2; exit 1; }

cmake -S "$REPO/quest/xr/extension" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
	-DGODOT_CPP_DIR="$GODOT_CPP" >/dev/null
cmake --build "$BUILD"
mkdir -p "$REPO/android/vcmi-app/src/quest/jniLibs/arm64-v8a"
cp "$BUILD/libvcmi_xr.so" "$REPO/android/vcmi-app/src/quest/jniLibs/arm64-v8a/"

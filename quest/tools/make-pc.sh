#!/usr/bin/env bash
# Builds the PC test setup of the Quest build (quest/EMULATORS.md): the game as a library (VCMI_client.dll with the
# bridge, clientapp/CMakeLists.txt VCMI_QUEST_PC) and the Godot extension for Windows (quest/xr/bin/vcmi_xr.dll), which
# loads the game into the Godot host. quest/tools/xrsim.sh then runs room, table and game in Meta XR Simulator.
# Usage (Git Bash on Windows): quest/tools/make-pc.sh
# Needs Visual Studio 2019 with "Desktop development with C++" (MSVC v142, as VCMI's prebuilt dependencies), Conan 2
# (pip install --user conan) and VCMI's dependencies restored into Conan once:
#   conan profile detect && conan cache restore dependencies-windows-x64.txz   (github.com/vcmi/vcmi-dependencies)
# The Heroes 3 data comes from $H3_DATA (default the GOG install); VCMI's settings and saves go to $OUT/userdata, not
# to Documents.

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${VCMI_PC_BUILD:-$HOME/vcmi-build/win}"
TOOLS="${VCMI_TOOLS:-$HOME/vcmi-tools}"
GODOT_DIR="${GODOT_WIN:-$TOOLS/godot-4.7.2-win}"
H3_DATA="${H3_DATA:-/c/GOG Games/Heroes of Might and Magic 3 Complete}"
CMAKE="${CMAKE:-/c/Program Files (x86)/Microsoft Visual Studio/2019/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe}"
CONAN="${CONAN:-$APPDATA/Python/Python311/Scripts/conan.exe}"
GODOT_CPP_TAG=godot-4.5-stable # as make-extension.sh
GODOT_CPP="$TOOLS/godot-cpp-$GODOT_CPP_TAG"
export MSYS_NO_PATHCONV=1
win() { cygpath -w "$1"; }

[ -x "$CMAKE" ] || { echo "CMake of Visual Studio 2019 not found: $CMAKE" >&2; exit 1; }
[ -x "$CONAN" ] || { echo "Conan not found: $CONAN (pip install --user conan)" >&2; exit 1; }
[ -d "$H3_DATA/Data" ] || { echo "no Heroes 3 data in $H3_DATA (set H3_DATA)" >&2; exit 1; }

cd "$REPO"
git submodule update --init dependencies
[ -f "$OUT/conan/conan_toolchain.cmake" ] || "$CONAN" install . --output-folder="$(win "$OUT/conan")" --build=never \
	--profile=dependencies/conan_profiles/msvc-x64 -s "&:compiler.version=192" -s "&:build_type=Release" \
	-o "&:target_pre_windows10=True"

# the client only: no launcher, editor, server or tests; Discord's submodule is not checked out
"$CMAKE" -S . -B "$(win "$OUT/build")" -G "Visual Studio 16 2019" -A x64 \
	-DCMAKE_TOOLCHAIN_FILE="$(win "$OUT/conan/conan_toolchain.cmake")" -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
	-DVCMI_QUEST_PC=ON -DENABLE_LAUNCHER=OFF -DENABLE_EDITOR=OFF -DENABLE_SERVER=OFF -DENABLE_TEST=OFF \
	-DENABLE_TRANSLATIONS=OFF -DENABLE_MMAI=OFF -DENABLE_DISCORD=OFF >/dev/null
"$CMAKE" --build "$(win "$OUT/build")" --config Release --target vcmiclient -- /m /v:minimal
GAME="$OUT/build/bin/Release"

[ -d "$GODOT_CPP" ] || git clone -q --depth 1 --branch "$GODOT_CPP_TAG" https://github.com/godotengine/godot-cpp "$GODOT_CPP"
"$CMAKE" -S quest/xr/extension -B "$(win "$OUT/extension")" -G "Visual Studio 16 2019" -A x64 \
	-DGODOT_CPP_DIR="$(win "$GODOT_CPP")" >/dev/null
"$CMAKE" --build "$(win "$OUT/extension")" --config Release -- /m /v:minimal
mkdir -p quest/xr/bin
cp "$OUT/extension/Release/vcmi_xr.dll" quest/xr/bin/

# the game reads its data from its own folder (VCMIDirs.cpp, dataPaths "."): links to the Heroes 3 install
for dir in Data Maps Mp3; do
	[ -e "$GAME/$dir" ] || powershell.exe -NoProfile -Command \
		"New-Item -ItemType Junction -Path '$(win "$GAME/$dir")' -Target '$(win "$H3_DATA/$dir")'" >/dev/null
done

# VCMI finds dirs.json next to the process's executable: Godot's, as the game runs inside the host
mkdir -p "$GODOT_DIR/config" "$OUT/userdata/config"
printf '{ "userDataPath": "%s" }\n' "$(cygpath -m "$OUT/userdata")" > "$GODOT_DIR/config/dirs.json"
# a window of the headset's surface size (main.gd SURFACE_SIZE), no intro; kept once the player changes settings
SETTINGS="$OUT/userdata/config/settings.json"
[ -f "$SETTINGS" ] || cat > "$SETTINGS" <<'EOF'
{
	"video" : {
		"resolution" : { "width" : 2560, "height" : 1440, "scaling" : 0 },
		"fullscreen" : false,
		"showIntro" : false,
		"upscalingFilter" : "none"
	}
}
EOF
echo "make-pc: $GAME/VCMI_client.dll and quest/xr/bin/vcmi_xr.dll; run quest/tools/xrsim.sh"

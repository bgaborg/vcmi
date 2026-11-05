#!/usr/bin/env bash
# Builds the Quest APK on Linux or WSL (Ubuntu 24.04), same steps as .github/workflows/quest.yml.
# Run from a Linux checkout of the repo (not /mnt/c: slow, and CRLF line endings break scripts).
# Installs the toolchain without sudo into $VCMI_TOOLS (default ~/vcmi-tools) on first run.
#
# Android SDK license: the first run needs an accepted license. Either run
#   $VCMI_TOOLS/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses
# or pass the licenses folder of an existing SDK: SDK_LICENSES=/mnt/c/Users/<you>/AppData/Local/Android/Sdk/licenses

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS="${VCMI_TOOLS:-$HOME/vcmi-tools}"
SDK="$TOOLS/android-sdk"
PRESET=android-conan-ninja-release
GRADLE_PROPERTIES="vcmiQuest=true;applicationIdSuffix=.quest;applicationLabel=VCMI Quest;applicationVariant=quest;signingConfig=dailySigning"
CMDLINE_TOOLS_URL=https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip

export PATH="$HOME/.local/bin:$TOOLS/jdk17/bin:$PATH"
export JAVA_HOME="$TOOLS/jdk17" ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"

mkdir -p "$TOOLS"

# Toolchain
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
for tool in conan cmake ninja; do
	command -v "$tool" >/dev/null || uv tool install "$tool"
done

if [ ! -x "$TOOLS/jdk17/bin/java" ]; then
	curl -sL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" -o "$TOOLS/jdk17.tgz"
	mkdir -p "$TOOLS/jdk17" && tar -xzf "$TOOLS/jdk17.tgz" -C "$TOOLS/jdk17" --strip-components=1 && rm "$TOOLS/jdk17.tgz"
fi

if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
	curl -sLo "$TOOLS/clt.zip" "$CMDLINE_TOOLS_URL"
	python3 -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TOOLS/clt.zip" "$TOOLS/clt"
	mkdir -p "$SDK/cmdline-tools" && mv "$TOOLS/clt/cmdline-tools" "$SDK/cmdline-tools/latest"
	chmod +x "$SDK/cmdline-tools/latest/bin/"*
	rm -rf "$TOOLS/clt" "$TOOLS/clt.zip"
fi

if [ ! -d "$SDK/platforms/android-35" ] || [ ! -d "$SDK/build-tools/35.0.0" ]; then
	if [ -n "${SDK_LICENSES:-}" ]; then
		mkdir -p "$SDK/licenses" && cp "$SDK_LICENSES"/* "$SDK/licenses/"
	fi
	"$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" "platform-tools" "platforms;android-35" "build-tools;35.0.0"
fi

# Conan dependencies (prebuilt by vcmi-dependencies)
cd "$REPO"
if [ ! -f conan-generated/conan_toolchain.cmake ]; then
	conan profile detect --exist-ok
	RUNNER_TEMP="$TOOLS" source CI/install_conan_dependencies.sh dependencies-android-arm64-v8a
	conan install . \
		--output-folder=conan-generated \
		--build=never \
		--profile=dependencies/conan_profiles/android-64-ndk \
		--profile=dependencies/conan_profiles/base/android-system \
		--conf="tools.cmake.cmaketoolchain:generator=Ninja"
fi

# Build
mkdir -p ~/.gradle && echo "android.bundle.enableUncompressedNativeLibs=true" > ~/.gradle/gradle.properties
cmake --preset "$PRESET" -DENABLE_OPENXR=ON "-DANDROID_GRADLE_PROPERTIES=$GRADLE_PROPERTIES"
cmake --build --preset "$PRESET" -j "${JOBS:-$(( $(nproc) * 2 / 3 ))}"

APK="$REPO/out/build/$PRESET/android-build/vcmi-app/build/outputs/apk/release/vcmi-release.apk"
mkdir -p "$REPO/quest/out" && cp "$APK" "$REPO/quest/out/vcmi-quest-release.apk"
echo "APK: $REPO/quest/out/vcmi-quest-release.apk"

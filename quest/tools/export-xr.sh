#!/usr/bin/env bash
# Exports the Godot XR host (quest/xr) to android/vcmi-app/src/quest/assets/vcmi-xr.pck, the main pack VcmiXrActivity starts.
# Downloads the pinned Godot editor (Linux) and OpenXR vendors addon into $VCMI_TOOLS (default ~/vcmi-tools) on first run.
# Used by make-apk.sh and .github/workflows/quest.yml.

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS="${VCMI_TOOLS:-$HOME/vcmi-tools}"

# keep equal to the godot and godot-openxr-vendors-meta versions in android/vcmi-app/quest.gradle
GODOT_VERSION=4.7.2
GODOT_SHA512=9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65
VENDORS_VERSION=5.1.0
VENDORS_SHA512=2e60b98306c6bf6e8dd1bef28bf6393f00dd5c2d1c6ad764c3572d235b1bef3de7d0efda2452fe238a0988657b2a346e39fdf59f4f8d4d3b5206b8cd95090945
GODOT="$TOOLS/godot-$GODOT_VERSION/Godot_v$GODOT_VERSION-stable_linux.x86_64"

download() { # url, sha512, file
	[ -f "$3" ] && echo "$2  $3" | sha512sum -c --quiet && return
	curl -sL -o "$3" "$1"
	echo "$2  $3" | sha512sum -c --quiet
}
unpack() { python3 -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$1" "$2"; }

mkdir -p "$TOOLS"
if [ ! -x "$GODOT" ]; then
	download "https://github.com/godotengine/godot/releases/download/$GODOT_VERSION-stable/Godot_v$GODOT_VERSION-stable_linux.x86_64.zip" "$GODOT_SHA512" "$TOOLS/godot.zip"
	unpack "$TOOLS/godot.zip" "$TOOLS/godot-$GODOT_VERSION" && chmod +x "$GODOT" && rm "$TOOLS/godot.zip"
fi

if [ ! -f "$REPO/quest/xr/addons/godotopenxrvendors/.version-$VENDORS_VERSION" ]; then
	download "https://github.com/GodotVR/godot_openxr_vendors/releases/download/$VENDORS_VERSION-stable/godotopenxrvendorsaddon.zip" "$VENDORS_SHA512" "$TOOLS/vendors-$VENDORS_VERSION.zip"
	rm -rf "$TOOLS/vendors" "$REPO/quest/xr/addons/godotopenxrvendors"
	unpack "$TOOLS/vendors-$VENDORS_VERSION.zip" "$TOOLS/vendors"
	mkdir -p "$REPO/quest/xr/addons" && mv "$TOOLS/vendors/asset/addons/godotopenxrvendors" "$REPO/quest/xr/addons/"
	touch "$REPO/quest/xr/addons/godotopenxrvendors/.version-$VENDORS_VERSION"
fi

# the export does not compile scripts; a parse error would only show on the headset
if "$GODOT" --headless --path "$REPO/quest/xr" --check-only --script res://main.gd 2>&1 | grep -A1 "SCRIPT ERROR"; then
	exit 1
fi
mkdir -p "$REPO/android/vcmi-app/src/quest/assets"
"$GODOT" --headless --path "$REPO/quest/xr" --export-pack Quest "$REPO/android/vcmi-app/src/quest/assets/vcmi-xr.pck"

# Phase 7: the release (plan and checks)

How the Quest build is released, what it may ship, and what is checked before. Status of all phases: [`PROJECT_PLAN.md`](PROJECT_PLAN.md#0-status-and-next-steps). What to check on the headset first: [`HEADSET_CHECKLIST.md`](HEADSET_CHECKLIST.md).

## 1. Decision: sideload first (2026-11-15)

- **Sideload** (developer mode, `adb install` or SideQuest), as a GitHub release of the fork: an APK and its source tag. No store until a person has played a whole campaign map in the headset (phase 3 exit) and the store's policy is checked (risks, [`PROJECT_PLAN.md` section 7](PROJECT_PLAN.md#7-risks)).
- Why not the Horizon Store now: the game needs the player's own Heroes 3 data, imported in the launcher; a store app that does nothing without files the store does not sell is a review risk. App Lab no longer exists as a separate channel.
- The APK is signed with VCMI's public daily key (`CI/android`, [`PHASE1.md`](PHASE1.md#build)). Anyone can sign an update with it, which is acceptable for a sideloaded test build and not for a store build: a store release needs its own key, kept out of the repository.

## 2. What the APK may ship: licence check (2026-11-15)

| Part | Licence | In the APK | What it asks for |
|---|---|---|---|
| VCMI (the game, the launcher) | GPL v2 or later (`license.txt`) | `libvcmi*.so`, Java | the corresponding source: this fork's tag |
| xBRZ (`client/filters/xBRZ`, also compiled into the GDExtension by `quest/xr/extension/CMakeLists.txt`) | GPL v3, with a linking exception | `libvcmiclient`, `libvcmi_xr.so` | the combined work is therefore distributed under GPL v3 (VCMI's "or later" allows it) |
| The bridge and the GDExtension (`quest/bridge`, `quest/xr/extension`) | GPL v2 or later (file headers) | as above | as above |
| The libraries of VCMI's Android build: Qt 5 (LGPL v3), Boost, TBB (Apache 2.0), libpng, Ogg, Opus, minizip, bzip2, xz, libiconv (LGPL) | as upstream VCMI for Android ships them | `libQt5*`, `libboost_*`, `libtbb`, and the rest | the same notices as upstream's APK; Qt stays a shared library (LGPL) |
| Godot 4.7.2 and godot-cpp | MIT | `libgodot_android.so`, the extension | the copyright notice |
| godotopenxrvendors 5.1.0 | MIT; the Khronos OpenXR loader Apache 2.0 (`addons/godotopenxrvendors/khronos/LICENSE`) | `libgodotopenxrvendors.so`, `libopenxr_loader.so` | the notices; Apache 2.0 is compatible with GPL v3, not v2 only, which the line above settles |
| `addons/godotopenxrvendors/meta/LICENSE-SDK` | Oculus SDK licence | nothing: the Meta loader is not used since the plugin moved to the Khronos loader | none; keep it out of the APK if a future plugin version ships Meta's loader again |
| War room assets (`quest/xr/assets/room/`) | CC0, public domain, CC BY 4.0 | the textures and models | CC BY: the credits in `assets/room/LICENSES.md`, which the export includes (`export_presets.cfg` `include_filter`) |
| Heroes 3 data | the player's own | nothing | never ship it; `quest/out/h3/` (local renders) is git-ignored |

Before each release: `unzip -l` the APK and compare its native libraries with this table; a new library needs a row.

## 3. Release steps

1. The checklist rows of [`HEADSET_CHECKLIST.md`](HEADSET_CHECKLIST.md) pass on the headset, or their failures are listed in the release notes.
2. Performance: the war room and the heaviest map at 72 Hz without dropped frames, and a battle with seven stacks a side (`quest/tools/quest.sh` performance commands, [`XR_PERFORMANCE.md`](XR_PERFORMANCE.md)); 30 minutes without thermal throttling.
3. `quest/tools/make-apk.sh` in WSL; tag the commit `quest-v<version>`; push the tag; attach the APK to a GitHub release of the fork with the release notes (what works, the known limits of `HEADSET_CHECKLIST.md` section 4, the install steps of [`README.md`](README.md)).
4. The notes link this file's licence table and the source tag (GPL: the corresponding source, including `quest/tools` that build it).

## 4. Left for the headset

- Data import through the system file picker on the headset (phase 1 checklist 1.3): the steps in [`README.md`](README.md) assume it works.
- The performance and thermal pass (step 2).

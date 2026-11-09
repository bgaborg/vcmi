# Phases 2-3 - the XR host, and working on the headset

How the Godot XR host works (phases 2b and 3), what the phase 2 spike taught, and how to build, drive and test the Quest build without a person wearing the headset. Status and next steps: [`PROJECT_PLAN.md`](PROJECT_PLAN.md#0-status-and-next-steps).

## How the XR host works

Godot project `quest/xr/` (`main.gd` host, `room.gd` war room), Android side in `android/vcmi-app/src/quest/` (`VcmiXrActivity`, `VcmiBridge`, `QuestGamepad`, `QuestPause`). The unchanged `VcmiSDLActivity` runs on a private 2560x1440 virtual display drawn into an `OpenXRCompositionLayerCylinder`.

| Part | How |
|---|---|
| Pointer | trigger = left click, grip = right click (hold popups). The game's cursor is not drawn into the display: Godot draws a dot where the ray hits. Once the gamepad is used, the game also shows its own cursor |
| Gamepad | the controllers are one SDL gamepad (`QuestGamepad`, SDL's Android joystick entry points): right A / B = accept / cancel, left X / Y = next hero / town, left menu (short press) = options, stick clicks = map level / grid, right thumbstick = map scroll. Bound by the game in `config/keyBindingsConfig.json` ("joystickButtons", "joystickAxes"). Registered on the first pointer move: SDL sends buttons of an unopened gamepad as keyboard keys |
| Wrist panel | above the left controller when it is turned to the eyes; the right ray and trigger press end turn, spells, kingdom, quests, sleep, dig, quick save, quick load as the game's own keys. Godot does not know the open screen, so labels name the key (in battle D is defend) |
| Screen | left thumbstick: distance up / down (1-4 m; the screen is a cylinder around the head, so nearer curves more), width left / right (1-4 m, at most 115 deg of arc). Saved in `user://screen.cfg`. Recenter follows the runtime event and puts the screen at the current eye height (so no seated / standing mode) |
| Environments | holding the left menu button 0.6 s goes to the next: war room (default), passthrough (`XR_FB_passthrough`, alpha blend), black. Saved in `user://screen.cfg` |
| War room | `room.gd`: a castle study, baked lightmap only (`assets/room/room.lmbake`), flames animated in their shader. Assets and licences: [`LICENSES.md`](xr/assets/room/LICENSES.md); GPU rules: [`XR_PERFORMANCE.md`](XR_PERFORMANCE.md). |
| Haptics | Godot pulses the controller on a click on the screen (0.5) and on gamepad buttons (0.25), 30 ms, if the game's "Haptic feedback" option is on. The game's own `hapticFeedback()` runs for touch input only |
| Pause | the game activity stays resumed on its display when the host pauses (Meta menu, headset off, Guardian), so `VcmiBridge` runs SDL's own pause (`QuestPause`): game loop and audio stop until the host resumes |
| HD | the game's defaults on the 2560x1440 display: 200 % interface scaling, `video.upscalingFilter` is `none` on Quest unless the player picks a concrete xBRZ filter such as `xbrz2` (`VcmiBridge`; "auto" is not saved, so it falls back to `none`); `video.useHdTextures` uses installed HD packs |

Godot findings:
- Godot's hole punch writes no depth, so the room would draw over the screen: the screen mesh has a depth-writing material that multiplies by zero (`blend_mul`, first in the transparent pass), which clears colour and alpha where the room drew behind it; the room's additive effects write no alpha.
- Godot does not ship the OpenXR loader: `quest.gradle` adds the Khronos loader AAR.
- `OpenXRCompositionLayerCylinder.aspect_ratio` is width / height; Godot 4.7.2 `intersects_ray` uses the inverse, so `main.gd` has its own ray-cylinder hit.
- Godot's default reference space is Stage, which a recenter does not move: the project uses Local Floor.
- The screen is placed from the head tracker pose; the `XRCamera3D` node moves only after the first `_process`.

## Horizon OS findings

From the phase 2 spike (own OpenXR code in `clientxr/`, removed 2026-11-06); they still apply.

- The immersive entry point must be a real activity (`VcmiXrActivity`, not resizeable, landscape, no `<layout>`). As an activity-alias of the panel activity, Horizon ran it as a panel and drew the home passthrough over the game.
- Hybrid app: the launcher is a panel (`com.oculus.intent.category.2D`); the game starts through `com.oculus.intent.category.VR` (focus aware) in a new task with its own affinity, else it joins the launcher's panel task. The launcher then closes its task (`ActivityLauncher.java`). Manifest: `metavr:uses-metavr-sdk`, `android.hardware.vr.headtracking`, `oculus.software.vr.app.hybrid`.
- Horizon queues or stops an immersive launch while tracking is lost ("Finding position in room", for example in a dark room). A run that shows only the home room is often this.
- Runtime `Oculus` 209.166.0 (2026-11-05): GLES, Vulkan, cylinder layers and display refresh rate are available.
- `upscalingFilter` `xbrz4rcas` makes the first frames take about 10 s.

## Working on the headset

The target is the Android APK on the headset; do not substitute a desktop build. Everything below runs without the user: ask only for one-time steps (a cable, wireless debugging, a system dialog).

### Build

- Build in the WSL Ubuntu 24.04 clone `~/vcmi-quest` (distro `Ubuntu`), not on `/mnt/c` (slow; CRLF breaks scripts): `quest/tools/make-apk.sh`, the same steps as CI. The first run installs the toolchain without sudo into `~/vcmi-tools` (set `SDK_LICENSES` to the licences folder of an SDK where the Android licence is accepted) and takes ~15 min; later builds ~2 min. It calls `export-xr.sh` (headless Godot export of `quest/xr` to `vcmi-xr.pck`) and `make-extension.sh` (`libvcmi_xr.so`). Output: `quest/out/vcmi-quest-release.apk` in the clone; copy it to the Windows checkout's `quest/out/`.
- Sync the Windows checkout into the clone with a binary patch, `git diff --binary HEAD` then `git apply --index`, plus a copy of new untracked binary files. A patch built from a temporary index loses the executable bit of new scripts: `chmod +x quest/tools/*.sh` in the clone.
- Call WSL from Git Bash as `MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash /mnt/c/<path>/script.sh` with the commands in a script file. An inline `bash -lc "..."` string breaks on quoting and `$` expansion.
- The Godot pack must be stored uncompressed in the APK (`quest.gradle`: `noCompress 'pck'`): deflated, the room took 27 s to load instead of 1.6 s.
- CI: `.github/workflows/quest.yml`, manual dispatch only. Build settings: [`PHASE1.md`](PHASE1.md#build).

### Connect

- `quest/tools/quest.sh awake` first in every session, before building: it wakes the headset and keeps it rendering without being worn, until reboot. A launch while it sleeps fails, and one during the system loading screen can take longer than `xr-smoke.sh` waits.
- Wireless debugging: `adb mdns services`, `adb connect <name or ip:port>`, then `adb tcpip 5555` once per reboot so the port stays fixed. If the adb server restarts it drops the device: `adb connect <ip>:5555`. `quest.sh` picks the `:5555` entry when both are listed, and finds `adb.exe` in the Android SDK when it is not on the Git Bash `PATH`.

### Drive and capture

| `quest.sh` command | Use |
|---|---|
| `install <apk>`, `start`, `start-xr`, `stop`, `restart` | `start` opens the launcher; `start-xr` starts the immersive host directly |
| `test <cmd> [a] [b] [c]` | test command to the Godot host (below) |
| `screenshot [jpg]` | the headset view (metacam). It sometimes draws a black block over the top right of the cylinder layer that the display does not show; `panel [png]` captures the real display (both eyes, lens-distorted) |
| `wait-log`, `wait-game`, `mark-log`, `mark-game` | wait for a logcat or game log line; the loop runs on the headset, because adb.exe on Windows keeps a logcat stream open after grep exits |
| `pull-logs`, `logcat` | game logs (`VCMI_Client_log.txt`, `server_log.txt`, on the device in `/sdcard/Android/data/is.xyz.vcmi.quest/files/vcmi-data/cache/`) and logcat into `quest/out/`. Native crashes: `logcat \| grep "#0[0-9] pc"` |
| `sample <rows> [csv]` | rows ~1.7 s apart: Godot FPS and app GPU ms (VrApi line), CPU of the game thread (SDLThread), Godot (VkThread) and process, PSS, graphics memory |

Save every screenshot under `quest/out/` with a descriptive name.

Test commands (`main.gd` `_on_test_command`) drive the same code paths as the controllers. Each logs `VCMI XR test: <cmd> -> screen ..., environment ..., pointer (x, y), hotkey ..., controllers tracked [...], bridge ...`.

| Command | Does |
|---|---|
| `head yaw pitch height`, `head_off` | a simulated head pose (the origin moves by its inverse; the screen stays world-locked) |
| `recenter` | places the screen again in front of the head |
| `aim yaw pitch`, `aim_off`, `click`, `rclick` | the pointer in degrees from the screen centre, and its buttons |
| `pad keycode`, `stick x y`, `lstick x y` | a gamepad button; right thumbstick; left thumbstick (screen distance and width; `lstick 0 0` releases and saves) |
| `screen distance width`, `env index` | screen in metres; environment 0 war room, 1 passthrough, 2 black. Not saved |
| `lmenu seconds` | holds the left menu button (under 0.6 s: game options; longer: next environment) |
| `wrist 1` / `wrist 0` | holds the hotkey panel 0.35 m in front of the head, so `aim` and `click` reach it (at the default head `aim 6.5 -14` is Kingdom) |
| `gfx feature 0/1` | switches a room GPU cost at runtime (`room.gd` `set_feature`; `gfx 10 level` foveation, `gfx 11 0/1` dynamic foveation) |
| `probe`, `bridge` | only the log line; `bridge` for the data bridge stats |

Keys and text into the game itself: its display id is in `dumpsys display` ("VCMI"), then `quest.sh adb shell input -d <id> keyevent|text ...`. Ctrl shortcuts need `input -d <id> keycombination -t 200 CTRL_LEFT <key>`: without `-t` the Ctrl can be lost, and Ctrl+R arrives as R (restart scenario). Ctrl+R opens the "Replay Turn" picker with the own current turn first; `DPAD_DOWN` then `ENTER` picks the last enemy turn.

### Test scripts (`quest/tools/`)

| Script | What | When |
|---|---|---|
| `xr-smoke.sh [apk]` | start to the adventure map in ~20 s, screenshot per step (`quest/out/smoke-<time>/`); sets screen 2 m x 2.4 m and the war room | after every change to the host or the APK |
| `object-bench.sh build` (WSL), `object-bench.sh run [save] [repeats]` | the bridge's object list (`quest/bridge/ObjectScan`) on the headset without the APK or a game: loads a save with VCMI's library through `app_process` and times the full list and the per-event updates, with a self-check, then decodes and packs all the map's sprites (`quest/bridge/SpriteDecode`; writes `sprites.tsv` and `page0.ppm` to the device folder); about a minute per change | after changes to `ObjectScan` or `SpriteDecode` |
| `[MAP_ROW=1] xr-minimap.sh [apk]` | minimap on the war table: screenshots and bridge stats at the start, after hero moves and after the map reveal, GPU sample; fails when the fog does not follow; `MAP_ROW=1` on the heaviest G map for the budgets | after changes to the minimap, `quest/bridge` or the extension |
| `xr-lifecycle.sh [apk]` | data bridge lifecycle: new game, save / load, restart, replay, quit; checks observer counts itself and fails on a difference | after changes to `quest/bridge` or the extension |
| `xr-perf.sh <filter> [row] [rows] [player]` | the heaviest-map stress run (DATA_BRIDGE milestone 0), at most 15 min; sets `video.upscalingFilter` for the run and restores `settings.json` | only to compare a new view against the 2D baseline. The heaviest map ([HotA] Might and Magic, row 5) needs `"maps.famousmaps" : true` in the headset's `config/modSettings.json` |

### War room tools (Windows)

`bake-room.sh` (rebake after changing anything static in `room.gd`; commit the `.lmbake`, the `.exr` and its `.import`) and `render-room.sh` (preview PNGs in `quest/out/room-preview/`, warns about geometry that could cover the screen; `render-room.sh sprites [name|near]` renders only the war table with the sprites the headset saved with the test command `sprites`, about 13 s, for shader and layout changes without an APK; `QUEST_ADDRESS=<ip>:5555` pulls the newest capture; see `MILESTONE_3B.md` section 1d) and `test-local.sh [name]` (the host's headless tests in `quest/xr/tests/*_test.gd`, such as the table picking maths, in about 6 s) run the Windows Godot 4.7.2 editor from `~/vcmi-tools/godot-4.7.2-win` in Git Bash. They need an active Windows desktop session (the editor hangs while it is disconnected or locked) and restore `project.godot`, which the editor rewrites.

### Measuring

- GPU: `quest.sh sample` and `gfx` A/B runs; compare only at the same GPU clock level. Rules and numbers: [`XR_PERFORMANCE.md`](XR_PERFORMANCE.md#4-profiling-on-the-headset).
- CPU and memory of the game: [`DATA_BRIDGE.md` section 4](DATA_BRIDGE.md#4-performance-and-memory).

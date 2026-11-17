# Testing without the headset: Meta XR Simulator only

Read this before any emulator or simulator work. On the PC the room, the table and the game run together in Meta XR
Simulator (section 3); the APK on the headset stays the target and the check for each milestone: its performance, the
Android side, the real controllers and comfort ([`HEADSET_CHECKLIST.md`](HEADSET_CHECKLIST.md)).

## 1. Forbidden: 2D emulators

**Never run VCMI Quest in Meta Spatial Simulator (SpatialSim, `metavr ssim`) or in an Android emulator (AVD).**
They are 2D: SpatialSim rejects the immersive activity (`SimSwmService: Rejecting immersive app launch:
eu.vcmi.vcmi.VcmiXrActivity`), so the war room, the table, the controllers and the loading screen never appear. What
is left, the flat game and its launcher, is upstream VCMI and tells nothing about this project. Tried on 2026-11-15:
hours of setup, no use. SpatialSim was uninstalled. No build option for x86_64 or a panel-only game exists, and none
is to be added.

## 2. The Meta VR CLI (`metavr`)

Meta's command-line tool installs Meta's tools and searches Meta's documentation.

- **Install** (Windows, the script from `https://developers.meta.com/horizon/install-cli/windows/`, read before
  running: it downloads `metavr.exe` from oculus.com, checks its SHA-256, puts it in `%USERPROFILE%\.metavr\bin`):
  `METAVR_NO_PATH=1` keeps the user PATH unchanged; call it as `~/.metavr/bin/metavr.exe`.
- `metavr tools list` / `metavr tools install xrsim`: Meta's tools and versions.
- `metavr docs search <words>`: Meta's documentation; `metavr skills show <skill>`: Meta's agent skills
  (`hz-xr-simulator-control`, `hz-xr-simulator-install-and-configure`, `hz-vr-debug`).
- Repository with the skills: <https://github.com/meta-quest/agentic-tools>.

## 3. Meta XR Simulator with the Godot host

`quest/tools/xrsim.sh [script]` runs the host from `quest/xr` with Godot 4.7.2 on Windows and the simulator
(v207.1 in `%APPDATA%\metavr\tools\xrsim`) as its OpenXR runtime **for that process only** (`XR_RUNTIME_JSON`). It
never switches the system's active OpenXR runtime (`metavr xrsim runtime activate` asks for UAC and changes it for
every app).

- **The game runs inside the host**, as on the headset, once `quest/tools/make-pc.sh` has built it (about 20 minutes
  the first time; prerequisites in its header: Visual Studio 2019 with the C++ workload, Conan 2, VCMI's prebuilt
  Windows dependencies, a Heroes 3 install):
  - `VCMI_client.dll` is the unchanged client as a library with the bridge (`clientapp/CMakeLists.txt`,
    `VCMI_QUEST_PC`), in `~/vcmi-build/win/build/bin/Release`, its data folders linked to the Heroes 3 install.
  - The VcmiData extension, built for Windows into `quest/xr/bin/` (`vcmi_xr_pc.gdextension`, not exported to the
    APK), loads that library and runs the client's `wmain` on a thread (`pc_start`).
  - The game draws with SDL's offscreen video driver and software renderer; the bridge's PC part
    (`quest/bridge/PcHost.cpp`) resizes its window to the headset's 2560x1440 (the offscreen desktop is 1024x768),
    copies each frame on the game thread, pushes the pointer and the keys as SDL events, and drives an SDL virtual
    gamepad for the controllers' buttons and right stick (as `QuestGamepad` on Android).
  - `pc_bridge.gd` has the same methods as the Android plugin: its frames fill a viewport that `main.gd` puts on the
    screen's cylinder layer, and the table gets the game's data from the bridge as on the headset.
  - VCMI's settings, logs and saves go to `~/vcmi-build/win/userdata` (`dirs.json` next to the Godot executable, as
    VCMI looks for it beside the process's executable), not to Documents.
  - Not on the PC yet: Ctrl, Shift and Alt as modifiers and typing text (pushed key events change neither SDL's
    keyboard state nor its text input; `PcHost.cpp` shortcut). Quitting the game from its menu ends the host, as the app ends on the headset.
- **Scripted tests**: a script lists test commands with times (the same commands `quest.sh test` sends to the
  headset), plus `shot <name>`, `tap <x> <y>` (a click at a game pixel) and `quit`. `xrsim-smoke.txt` runs the
  host's modes, `xrsim-game.txt` goes from the main menu into a scenario and onto the table, then uses the gamepad
  (`pad`, `stick`). The run fails on a script error, on not reaching `quit`, or when a shot differs from the script's baseline (`BASELINE=1 quest/tools/xrsim.sh
  [script]` keeps one in `quest/out/xrsim-baseline/<script>`).
- **Screenshots**: the host renders each one itself, from the headset's pose into a 1280x720 image
  (`pc_bridge.gd`), so nothing of the desktop is ever captured. Godot cannot read the XR eye images back (they render
  into the runtime's swapchain), and a copy of the host's window goes stale while another window covers it (tried
  2026-11-15/16 with PrintWindow). The game screen, a composition layer, is not in them: each shot also saves the
  game's own frame as `<name>-game.png`.
- **Meta XR Operator** (`metavr tools install xroperator`, v207.0.1, [`META_TOOLS.md`](META_TOOLS.md)): `xrsim.sh` loads it as an
  OpenXR API layer for its run when installed (`XR_API_LAYER_PATH`, no system setting). It injects real OpenXR input
  (controller poses, buttons, trigger, sticks, the head pose) and captures the compositor's image, the room and the
  game screen layer together. `quest/tools/xrop.py` drives it from scripts (`aim`, `click`, `press`, `shot`); an agent
  uses it through `metavr mcp server` (`.mcp.json`). `XRSIM_TIMEOUT=960 quest/tools/xrsim.sh
  quest/tools/xrsim-live.txt` keeps the host open for that. The simulator's and the Operator's controllers are
  Touch Plus (`/interaction_profiles/meta/touch_controller_plus`): the action map lists that profile, without it they
  give no input.
- Each scripted run starts from the host's default settings (`xrsim.sh` removes Godot's `screen.cfg`).
- The simulator's window shows "XR Simulator runtime disabled" and no view while it is not the system runtime; that
  is expected with the per-process setup.
- `metavr xrsim record` (the compositor to MP4) fails against v207.1: "its build doesn't include the recording
  service" (checked again 2026-11-17). `metavr xrsim runtime fps` reads the frame rate (72 Hz).
- Meta's record-and-replay: record in the simulator's window ("Record session"), replay automatically with a
  `session_capture` block in `%APPDATA%\MetaXR\MetaXrSimulator\persistent_data.json` (remove it afterwards, or every
  launch replays), compare frames with the simulator's `scripts\vrs_pixmatch.py`. The host quits when the runtime
  asks the session to end (`main.gd`, PC only), which replay needs.

## 4. Rules

- Screenshots only from the host or the simulator, never of the desktop.
- No system settings: not the active OpenXR runtime, not Hyper-V or virtualisation-based security, not the user PATH.
- Read an installer before running it; install Meta's tools only from Meta's sites.
- Stop the simulator and the host when a run ends (the host quits at its script's end).

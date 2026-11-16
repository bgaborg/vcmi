# Testing without the headset: Meta XR Simulator only

Read this before any emulator or simulator work. The headset stays the only place where the whole game runs in VR
([`HEADSET_CHECKLIST.md`](HEADSET_CHECKLIST.md)).

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

- The game does not run there yet: its bridge is the Android plugin, and `quest/xr/pc_bridge.gd` stands in, so the
  game screen stays black. The table's contents come from the VcmiData extension, built for Android only: the table
  is an empty desk on the PC.
- **Scripted tests**: `quest/tools/xrsim-smoke.txt` lists test commands with times (the same commands `quest.sh test`
  sends to the headset), plus `shot <name>` and `quit`. The run fails on a script error, on not reaching `quit`, or
  when a shot differs from the baseline (`BASELINE=1 quest/tools/xrsim.sh` keeps one in `quest/out/xrsim-baseline`).
- **Screenshots**: the host renders each one itself, from the headset's pose into a 1280x720 image
  (`pc_bridge.gd`), so nothing of the desktop is ever captured. Godot cannot read the XR eye images back (they render
  into the runtime's swapchain), and a copy of the host's window goes stale while another window covers it (tried
  2026-11-15/16 with PrintWindow). The game screen, a composition layer, is not in the shots.
- The simulator's window shows "XR Simulator runtime disabled" and no view while it is not the system runtime; that
  is expected with the per-process setup.
- `metavr xrsim record` (the compositor to MP4) fails against v207.1: "its build doesn't include the recording
  service".
- Meta's record-and-replay: record in the simulator's window ("Record session"), replay automatically with a
  `session_capture` block in `%APPDATA%\MetaXR\MetaXrSimulator\persistent_data.json` (remove it afterwards, or every
  launch replays), compare frames with the simulator's `scripts\vrs_pixmatch.py`. The host quits when the runtime
  asks the session to end (`main.gd`, PC only), which replay needs.

## 4. Rules

- Screenshots only from the host or the simulator, never of the desktop.
- No system settings: not the active OpenXR runtime, not Hyper-V or virtualisation-based security, not the user PATH.
- Read an installer before running it; install Meta's tools only from Meta's sites.
- Stop the simulator and the host when a run ends (the host quits at its script's end).

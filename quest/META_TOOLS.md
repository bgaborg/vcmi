# Meta's tools for developing on the PC instead of the headset

The goal: build and test the Quest app on the PC, with the war room, the table, the controllers and the game running in Meta
XR Simulator ([`EMULATORS.md`](EMULATORS.md)), and install it on the headset only for what the PC cannot show. This file
records what Meta offers for that, what was tried on 2026-11-17 and what it gave. [V] means verified here; [D] means
documented by Meta but not tried here.

## What changed on 2026-11-17

| | Before | Now |
|---|---|---|
| Controllers in the simulator | no input at all and no models: the simulator's controllers are Touch Plus (`/interaction_profiles/meta/touch_controller_plus`), which the action map did not list | the profile is in `quest/xr/openxr_action_map.tres` (the Touch bindings): the models, the ray, the pointer dot, the trigger, the buttons and the wrist panel work [V] |
| Input in tests | test commands that skip the controller path (`pad`, `tap`, `aim`) | real OpenXR input from Meta XR Operator: poses, trigger, buttons, sticks, the head pose [V] |
| Screenshots | rendered by the host, without the game screen layer (a black rectangle on the table shots) | `openxr_capture_composited_image`: what the eye sees, room and game screen together [V] |
| An agent driving the app | none | `metavr mcp server` in `.mcp.json` (Meta's docs, device, perf and XR Operator tools); `quest/tools/xrop.py` from the shell [V] |
| Repeatable runs | an environment saved by an earlier run changed the shots | `xrsim.sh` starts from the host's default settings |

Verified chain: the injected right trigger, aimed by `xrop.py`, went through Godot's pointer ray and the bridge into
VCMI and opened the game's New Game menu, then the Load Game lobby; holding the left Menu button switched the room's
environment, as on the headset. Shots: `quest/out/xroperator-*.png`, `quest/out/xrop-*.png`.

## Meta XR Operator (in use)

An OpenXR API layer with an MCP server inside the app (`http://127.0.0.1:8720`), standalone v207.0.1 for any OpenXR app.

- Install: `metavr tools install xroperator` (Meta's site, 15.6 MB, into `%APPDATA%\metavr\tools\meta-xr-operator`).
- Load: `quest/tools/xrsim.sh` sets `XR_API_LAYER_PATH` and `XR_ENABLE_API_LAYERS=XR_APILAYER_METAX_operator` for its
  run only when it is installed. No system setting changes.
- Drive it:
  - from scripts: `python quest/tools/xrop.py aim:-6,13 click sleep:2 shot:quest/out/x.png`, with steps `aim`,
    `click`, `press`, `sleep`, `shot` and any tool name followed by its JSON;
  - by an agent: the `metavr` MCP server (`.mcp.json`), which forwards the Operator's tools;
  - single calls: `metavr xroperator status`, `metavr xroperator call <tool> --args '{...}'`.
- Keep the host open with `XRSIM_TIMEOUT=960 quest/tools/xrsim.sh quest/tools/xrsim-live.txt`, in the background.
- The 31 tools [V]:
  - session, system, frame and instance info;
  - head and controller poses, get and set; hand poses and gestures (pinch, poke, grab);
  - controller input: trigger, grip, A/B/X/Y, Menu, the sticks;
  - the composited image;
  - spatial entities (room walls, planes);
  - pose and vector maths.
- Limits: experimental (names may change); one app at a time on port 8720; screenshots only (no video, no audio).
  Aiming by angles is coarse: a click meant for one menu entry can land on the next.
- Custom tools [D]: the app can register its own tools (`XR_METAX1_agentic_external_tool`, header in the bundle's
  `openxr/`). A small C++ part of the VcmiData GDExtension could expose `vcmi_state` and `vcmi_cmd`, giving the game's
  state and the host's test commands to the agent. About 1–2 days.
- On the headset [D]: the layer goes into the APK (`.so` and json, INTERNET permission,
  `com.oculus.experimental.enabled`), then `adb forward tcp:8720 tcp:8720`. It is not needed while we stay on the PC.

## Meta XR Simulator (v207.1, the newest; in use)

Run per process (`XR_RUNTIME_JSON`), never with `metavr xrsim runtime activate`: that changes the system's OpenXR runtime
and asks for admin rights.

- Refresh rate and frame rate [V/D]: `metavr xrsim runtime fps` reads 72 Hz [V]. `metavr xrsim device refresh-rates`
  and `device refresh-rate <hz>` set 72, 90 or 120 Hz on the simulated Quest 3 [D].
- Logs: `metavr xrsim runtime logs --tail N` [D].
- Layers: `metavr xrsim layer list|toggle` shows or hides one layer, for example the game screen [D].
- Video: `metavr xrsim record` does not work against v207.1 ("doesn't include the recording service") [V].
- Record and replay (VRS) [D]: the v207.1 known issues list "VRS Recording doesn't capture user interactions", so a
  replay test has to wait for the next simulator release. The host already quits when the replay ends.
- Rooms and passthrough: tried, not working yet.
  - The simulator ships room servers:
    - `synthetic_env_server\LaunchLivingRoom.bat`, `LaunchGameRoom.bat`, `LaunchBedroom.bat`;
    - six extra rooms in `xrooms_ses`;
    - `json_synthenv_server\json_server.exe <room.json> --port 33792`, with two rooms in `config/anchors`.
  - Started next to the host, the living room server exited on its own. Passthrough stayed the magenta checkerboard
    (black for a moment), and the scene query never finished ("Scene query is still in progress").
  - Meta's documented remedy, `"ses_texture_format": "jpg"` in `config/sim_core_configuration.json`, made no
    difference; it was set back to `gpu_handle`.
  - Next to try: choose the environment in the simulator's own window (`MetaXRSimulator.exe`), which probably
    manages the room servers, then `json_server.exe` with the furnished room.
- Our real room [D]: the `scene_data_recorder` APK in the simulator package records the room on the headset
  (`/sdcard/scene_recorder_out.json`); `json_server.exe` then serves it on the PC. One headset session, then every
  "room scan" placement test can run on the PC.
- Hands [D]: Inputs → Hand, keys 1–4 for the poses; a webcam can drive the hands since 207.0. Operator gestures
  do the same from scripts.
- Requirements [D]: Vulkan or Direct3D on Windows (not OpenGL). The host uses Vulkan.

## What only the headset can show

The simulator has no Android and no Quest hardware [D]. So these need the APK on the headset, and nothing else does:

- the Android side: the virtual display, the activity, permissions and system dialogs (the "spatial data" prompt),
  the lifecycle (sleep, the Meta menu);
- performance, temperature and the CPU/GPU levels;
- real passthrough and the real room scan;
- comfort and legibility in the lenses.

A device session per milestone (Android build, performance, passthrough, comfort) is enough; everything else stays on
the PC. Meta's headset tools for those sessions:
- `metavr perf capture --mode vr --app is.xyz.vcmi.quest -o <trace>` and `perf analyze-trace`;
- `metavr tapedeck` (record and replay input on the device);
- `metavr vrc-local` (store checks, offline).

## Next steps, ranked

1. Rooms on the PC: choose the room in the simulator's window, then the JSON server, then record our room once with
   `scene_data_recorder` on the next headset session. This brings passthrough, room scan and the table's placement to
   the PC.
2. Tests with real input: run `xrop.py` steps from `xrsim.sh` scripts instead of `tap`/`pad`, and use composited shots
   for the baselines (they show the game screen).
3. `aimat:<x>,<y>` in `xrop.py`: aim at a game pixel from the screen's geometry instead of by angles.
4. The custom tools `vcmi_state` and `vcmi_cmd` (`XR_METAX1_agentic_external_tool`).
5. Refresh-rate runs at 72, 90 and 120 Hz in the simulator.
6. VRS record and replay tests, once a simulator after v207.1 fixes the recording.

## Notes

- Telemetry: Meta's tools report "Telemetry consent: opted-in" for this account (`metavr telemetry status`;
  `metavr telemetry opt-out` turns it off). It was not changed.
- On 2026-11-17 a research run of `metavr vrc-local guide` downloaded the VRC-local bundle (310 MB) and installed ten
  skills into `~/.claude/skills` and `~/.agents/skills` (analyze-drive, da-scout, perf-render-capture,
  renderdoc-optimize, runtime-optimizer, troubleshoot, unity-release-cpu-attribution, vrc-drive, vrc-listing-assets,
  vrc-listing-check, vrc-verdict). They are still there.
- Sources:
  - [Meta XR Operator](https://developers.meta.com/vr/blog/meta-xr-operator-close-the-build-test-verify-loop-for-vr/)
  - [Agentic tooling for VR](https://developers.meta.com/vr/blog/build-faster-and-earn-more-agentic-tooling-for-vr/)
  - [XR Simulator docs](https://developers.meta.com/horizon/documentation/native/xrsim-intro)
  - [Operator standalone](https://developers.meta.com/vr/documentation/unity/meta-xr-operator/connecting-ai-agents)
  - [Agent skills](https://github.com/meta-quest/agentic-tools)

# Phase 2 - XR spike

Status of [phase 2](PROJECT_PLAN.md#phase-2---xr-spike-done-superseded).

**Superseded (2026-11-06):** the XR part moves to Godot ([phase 2b](PROJECT_PLAN.md#phase-2b---godot-host-spike)); the `clientxr/` code below gets removed. The Horizon OS findings (real activity instead of an alias, hybrid categories, tracking loss, clean session exit) still apply.

## Done: groundwork (builds without the headset)

| Part | Where |
|---|---|
| CMake option `ENABLE_OPENXR` (Android only, off by default; `make-apk.sh` and `quest.yml` turn it on) | `CMakeLists.txt` |
| Static library `vcmiXr`, linked into `vcmiclient`; defines `VCMI_OPENXR` for `vcmiclient` and `vcmisdl3` | [`clientxr/CMakeLists.txt`](../clientxr/CMakeLists.txt) |
| Khronos OpenXR loader 1.1.65: headers from the AAR (downloaded by CMake, SHA-256 pinned), `libopenxr_loader.so` and the OpenXR manifest entries through the same AAR as a Gradle dependency | `clientxr/CMakeLists.txt`, [`android/vcmi-app/quest.gradle`](../android/vcmi-app/quest.gradle) |
| Runtime probe: at start-up, created a temporary `XrInstance` and logged the runtime, the HMD system and the extensions phase 2 depends on. Removed in the spike; its results are below | was `clientxr/session/XrRuntimeProbe.cpp` |
| EGL config RGB888 instead of RGB565, no alpha (an alpha channel would let the panel compositor blend the window with the room) | `clientsdl3/render/ScreenHandler.cpp` |
| Quest APK: minSdk 24 (loader AAR), arm64-v8a only (the AAR ships all ABIs) | `quest.gradle` |

## Next: on the headset

1. Install the APK, start it, check that the game still runs as a panel.
2. Read the probe output:

   ```sh
   quest/tools/quest.sh pull-logs
   grep "OpenXR:" quest/out/logs-*/VCMI_Client_log.txt
   ```

   Expected: runtime name and version, system `Meta Quest 3`, and yes / no for `XR_KHR_opengl_es_enable`, `XR_KHR_vulkan_enable2`, `XR_KHR_composition_layer_cylinder`, `XR_FB_passthrough`, `XR_FB_display_refresh_rate`. A warning instead means instance creation does not work from a panel app; record the `XrResult`.
3. Compare colour banding with the phase 1 build (RGB565), for example on the main menu background.

### Probe results (2026-11-05, Quest 3, installed over adb Wi-Fi)

The panel app creates an `XrInstance` and gets the HMD system; the probe takes about 30 ms at start-up.

| Item | Result |
|---|---|
| Runtime | `Oculus` 209.166.0 |
| System | `Meta Quest 3`, vendor 10291, orientation and position tracking |
| Max swapchain | 8192x8192 |
| Max layers | 32 |
| Instance extensions | 75 |
| `XR_KHR_android_create_instance` | yes |
| `XR_KHR_opengl_es_enable` | yes |
| `XR_KHR_vulkan_enable2` | yes |
| `XR_KHR_composition_layer_cylinder` | yes |
| `XR_FB_passthrough` | no - possibly hidden from apps without the VR manifest entries; check again in the spike |
| `XR_FB_display_refresh_rate` | yes |

Both graphics APIs are available, so the choice is not forced by the runtime. The SDL3 client already renders through an EGL/GLES context, so the spike starts with `XR_KHR_opengl_es_enable`.

Play check with the RGB888 build: started a map, moved a hero, quit the game; no crash, no new warnings in the client log, and the picture looked fine. A side-by-side banding comparison with the RGB565 build was not done.

## Spike: the game on a quad layer (GLES)

| Part | Where |
|---|---|
| `XrDisplay`: instance and session on the SDL EGL context (`XR_KHR_opengl_es_enable`), `LOCAL` reference space, session lifecycle (begin on ready, end on stopping, quit on exiting) | [`clientxr/session/XrDisplay.cpp`](../clientxr/session/XrDisplay.cpp) |
| Frame: `composeFrame()` and the cursor are drawn into an SDL render target, one `glBlitFramebuffer` copies it into the acquired swapchain image (flipped: SDL targets are top row first). SDL cannot draw into swapchain images: it calls `glTexImage2D` on wrapped textures, and swapchain images are immutable | `XrDisplay.cpp` |
| Quad layer: 2.4 m wide, 2 m in front of the head position at session start (`LOCAL` space). The cylinder layer comes back once the quad is confirmed | `XrDisplay.cpp` |
| Swapchain usage `SAMPLED` and `COLOR_ATTACHMENT`; alpha of the copied frame forced to 1 | `XrDisplay.cpp` |
| Controllers: OpenXR actions for the Touch profile. The aim ray of the hand that pressed last hits the layer and is pushed as SDL mouse motion; trigger = left button, grip = right button (popup) | `XrDisplay.cpp` |
| Transparent projection layer over the game screen: a box per controller and the ray of the active hand, up to the screen. The game switches to the software cursor, the hardware cursor is drawn on the window only | `XrDisplay.cpp`, `ScreenHandler.cpp` |
| Immersive entry point is its own activity (`VcmiXrActivity`, not resizeable, landscape, no `<layout>`); the launcher closes itself after Play. As an activity-alias of the panel activity, Horizon ran it in a panel window and drew the home passthrough over the game | `src/quest/java`, `src/quest/AndroidManifest.xml`, `ActivityLauncher.java` |
| `metavr:uses-metavr-sdk`, `android.hardware.vr.headtracking`, `oculus.software.vr.app.hybrid` | `src/quest/AndroidManifest.xml` |
| Swapchain `GL_SRGB8_ALPHA8` with sRGB encoding off during the copy (`GL_EXT_sRGB_write_control`), else `GL_RGBA8` | `XrDisplay.cpp` |
| While the session runs, `presentScreenTexture()` submits the XR frame instead of `SDL_RenderPresent`; `xrWaitFrame` paces the loop | `clientsdl3/render/ScreenHandler.cpp` |
| GLES 3.0 context requested (blit framebuffers) | `ScreenHandler.cpp` |
| Runtime probe removed (an extra instance on every start); its loader code is now `XrLoader`, `EntryPoint.cpp` is upstream again | [`clientxr/session/XrLoader.cpp`](../clientxr/session/XrLoader.cpp) |
| Hybrid app: the launcher stays a panel (`com.oculus.intent.category.2D`), the game starts through the alias `VcmiXrActivity` (`com.oculus.intent.category.VR`, focus aware) in a new task (own task affinity, else it joins the launcher's panel task); `VcmiSDLActivity` itself stays a panel activity for `quest.sh start-panel` | [`src/quest/AndroidManifest.xml`](../android/vcmi-app/src/quest/AndroidManifest.xml), `ActivityLauncher.java` |

Known limits of the spike:
- controller input is a mouse only: no thumbstick scrolling, no A/B/X/Y, no keyboard; input is read only on frames the game submits
- controllers are drawn as boxes, not as the controller models (`XR_FB_render_model`); no depth buffer
- the game frame rate limiter still runs on top of `xrWaitFrame`
- frames the game skips (nothing changed, up to 100 ms) submit no XR frame and poll no XR events; the compositor keeps the last layer
- an EGL context loss on resume (`SDL_EVENT_RENDER_DEVICE_RESET`) is not handled: the session stays bound to the old context
- the XR session starts only when the activity was launched with the immersive category; the notification "open game" intent and `quest.sh start-panel` run the game as a panel

### Test on the headset

1. With the room lit, start VCMI from the library, press Play in the launcher. Expected: the room disappears, the main menu shows on a screen in front of you on a black background. Point a controller at it: the cursor follows; trigger clicks, grip opens popups.
2. Check: picture upright, colours like the panel build (not washed out or too dark), sharp text, no judder when you move your head.
3. Meta button: the system menu opens over the game; closing it returns to the game. Quit from the system menu ends the game.
4. Logs: `grep "OpenXR:"` in the client log - GLES context version, swapchain formats and the chosen format, swapchain size, session states.
5. Panel fallback: `quest.sh stop`, then `quest.sh start-panel` - the game as a panel like in phase 1.

### Results

2026-11-05, Quest 3:
- The game shows on the quad layer when started from the launcher; the session reaches focused at 72 Hz.
- Horizon blocks or stops immersive apps while tracking is lost ("Finding position in room", for example in a dark room): the launch is queued, or the session stops right after focus. Earlier runs that showed only the room were this, not the layer.
- With `upscalingFilter` `xbrz4rcas` the swapchain is 5396x2884 and the first frames take about 10 s.
- Passthrough over a focused session with correct frames: Horizon ran the alias as a panel (`mode=multi-window`); fixed with a real activity, see the table.
- Controllers: trigger and grip work; the ray and the software cursor show where they point.

## Phase 2b: Godot host

Status of [phase 2b](PROJECT_PLAN.md#phase-2b---godot-host-spike), 2026-11-06, Quest 3:
- The Godot host (`quest/xr`, `VcmiXrActivity`, `VcmiBridge`) reaches a focused OpenXR session at 90 Hz; the unchanged `VcmiSDLActivity` runs on a private virtual display (2560x1440) drawn into a cylinder layer. Horizon OS allows the launch.
- Godot does not ship the OpenXR loader: `quest.gradle` adds the Khronos loader AAR.
- `OpenXRCompositionLayerCylinder.aspect_ratio` is width / height; Godot 4.7.2 `intersects_ray` uses the inverse, so `main.gd` has its own ray-cylinder hit.
- Godot's default reference space is Stage, which a recenter does not move: the project uses Local Floor.
- The screen is placed from the head tracker pose; the `XRCamera3D` node moves only after the first `_process`.

- Pointer: the game's cursor is not drawn into the virtual display; Godot draws a dot where the ray hits (no VCMI change). Once the gamepad is used, the game also shows its own cursor.
- Haptics: Godot pulses the controller on a click on the screen (amplitude 0.5) and on gamepad buttons (0.25), 30 ms. The game's `hapticFeedback()` runs for touch input only, so it is not routed to the controllers.
- Controllers as an SDL gamepad (`org.libsdl.app.QuestGamepad`, SDL's own Android joystick entry points): right A/B = accept/cancel, left X/Y = next hero/town, left menu = options, stick clicks = map level/grid, right thumbstick = map scroll. The game binds them in `config/keyBindingsConfig.json` ("joystickButtons", "joystickAxes"); no VCMI change. The gamepad is registered on the first pointer move: SDL sends buttons of a gamepad the game has not opened yet as keyboard keys.
- Pause: the game activity stays resumed on its virtual display when the host pauses (Meta menu, headset off, Guardian dialog), so `VcmiBridge` runs SDL's own pause (`org.libsdl.app.QuestPause`): the game loop and audio stop until the host resumes. Checked with HOME and with sleep / wake into the Guardian dialog: logcat `VcmiBridge: game paused` / `game resumed`, the game's players in `dumpsys audio` go paused / started.

## Testing without the headset

Test commands drive the same code paths as the controllers: `pad keycode`, `stick x y` (right thumbstick), `lstick x y` (left thumbstick: screen distance and width; `lstick 0 0` releases it and saves), `screen distance width` (sets the screen in metres until the next launch; `xr-smoke.sh` sets `2 2.4`), `lmenu seconds` (holds the left menu button: under 0.6 s the game options, longer switches passthrough), `head yaw pitch height` (a simulated head pose; the origin moves by its inverse and the screen stays world-locked), `head_off`, `recenter`, `aim yaw pitch` (degrees from the screen centre), `aim_off`, `click`, `rclick`, `probe`. Each logs `VCMI XR test: <cmd> -> screen <position> heading <deg> distance <m> width <m>, pointer (<x>, <y>)`.

On the headset (on a desk, nobody wearing it): `quest/tools/quest.sh awake`, `start-xr`, `test <cmd>`, `screenshot`, `panel`. This covers the whole Android path: the virtual display, the Android surface layer, SDL input. Comfort, stereo depth and how the controllers feel still need a person.

Headset notes:
- `quest/tools/xr-smoke.sh [apk]` goes from start to the adventure map in about 20 s with a screenshot per step (`quest/out/smoke-<time>/`). It waits on log lines (`quest.sh wait-log`, `wait-game`, `mark-log`, `mark-game`); the waits run on the headset, because adb.exe on Windows keeps a logcat stream open after grep exits.
- The metacam screenshot sometimes draws a black block over the top right of the cylinder layer; the display does not show it. `quest.sh panel` captures the display panel itself (both eyes, lens-distorted) to check such cases.
- `quest.sh` picks the `adb tcpip 5555` connection when wireless debugging adds a second entry for the same headset.

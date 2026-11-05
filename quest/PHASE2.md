# Phase 2 - XR spike

Status of [phase 2](PROJECT_PLAN.md#phase-2---xr-spike). The app still runs as a 2D panel; nothing renders to OpenXR yet.

## Done: groundwork (builds without the headset)

| Part | Where |
|---|---|
| CMake option `ENABLE_OPENXR` (Android only, off by default; `make-apk.sh` and `quest.yml` turn it on) | `CMakeLists.txt` |
| Static library `vcmiXr`, linked into `vcmiclient`; defines `VCMI_OPENXR` for `vcmiclient` and `vcmisdl3` | [`clientxr/CMakeLists.txt`](../clientxr/CMakeLists.txt) |
| Khronos OpenXR loader 1.1.65: headers from the AAR (downloaded by CMake, SHA-256 pinned), `libopenxr_loader.so` and the OpenXR manifest entries through the same AAR as a Gradle dependency | `clientxr/CMakeLists.txt`, [`android/vcmi-app/quest.gradle`](../android/vcmi-app/quest.gradle) |
| Runtime probe: at start-up, creates a temporary `XrInstance` and logs the runtime, the HMD system and the extensions phase 2 depends on; the loader is opened with `dlopen`, so a failure only logs a warning | [`clientxr/session/XrRuntimeProbe.cpp`](../clientxr/session/XrRuntimeProbe.cpp), `clientapp/EntryPoint.cpp` |
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

## Then: the spike itself

- XR session on the SDL EGL context (`XR_KHR_opengl_es_enable`), VR manifest entries, session lifecycle.
- `composeFrame()` into a texture, copied to a swapchain on a cylinder layer.
- Decision GLES vs Vulkan, written down here.

# GPU performance of the Godot XR host on Quest 3

How to keep the 3D scene around the game (`quest/xr`, Godot 4.7.2, Mobile renderer, Vulkan, OpenXR) inside the 13.9 ms frame at 72 Hz. Research from Meta, Qualcomm and Godot sources and Quest titles, then what was measured in the war room (`room.gd`). The game itself is an OpenXR composition layer: nothing below changes its sharpness or cost.

## 1. Measured in the war room (2026-11-07)

App GPU time from the compositor's VrApi line (`quest.sh sample`), standing head at the screen, GPU at clock level 5 in the A/B rows, 8-15 rows per case. Features switched at runtime with the test command `gfx` (`main.gd`, `room.gd` `set_feature`).

| Room | App GPU | GPU busy |
|---|---|---|
| No room (black), for reference | 3.6-4.0 ms | 40 % |
| First war room: glow, 3 flickering dynamic lights, probe reflections on every surface, bicubic lightmap | 12.1 ms | 98 % |
| Glow off, all lights baked, probe reflections only on props, bilinear lightmap | 9.1 ms | 78 % |
| Plus fixed foveation level 1 / 2 / 3 | 8.5 / 8.2 / **6.9 ms** | 63 % at level 3 |
| Final build, re-baked, fixed level 3 | 6.86 ms | 63 %, GPU clock level 2 |

Single toggles from the first room (each against 12.1 ms; ±0.3 ms noise between runs):

| Off | Saving |
|---|---|
| Dynamic flickering lights | 0.1-1.8 ms (noisy) |
| Reflection probe | 1.2 ms |
| Lightmap | 0.8 ms (not an option; for scale) |
| Dirt detail texture on UV2 | 0.4 ms |
| Glow alone, parallax, normal maps, decor props, flames and light shafts | ~0 each |

- **Glow costs far more than its own pass:** it moves tonemapping out of the main render pass, which turns foveation off. Foveation set at runtime changed nothing while glow was on; with glow off, level 3 saves 2.2 ms.
- **Dynamic foveation does not help here:** the runtime keeps level 0 until the GPU is nearly full (`Fov=0` at 78 %). The project uses fixed level 3.
- **What is left:** about 3 ms over no room, most likely the shading of the walls and floor (albedo, normal, ORM, lightmap) in the unfoveated centre; not measured on its own.

## 2. Ranked techniques

**1. Keep the frame on the single-pass path, then foveate. Done.** On a tile-based GPU (Adreno 740) Godot's Mobile renderer tonemaps in a subpass while the image is still in tile memory. These force a separate full-screen tonemap pass, and then the main pass is neither foveated nor subsampled: glow, auto exposure, depth of field, `scaling_3d_scale` other than 1.0, FXAA/screen-space AA, any shader reading `SCREEN_TEXTURE`/`DEPTH_TEXTURE` (soft particles, proximity fade), post-transparent compositor effects. Settings: `xr/openxr/foveation_level=3`, `get_viewport().vrs_mode = Viewport.VRS_XR`; `xr/openxr/foveation_with_subsampled_images` is on by default (about 1 ms more on Quest 3, Godot PR #116220). Tonemap (AgX) and debanding stay in the subpass. Check: the visual profiler shows opaque, transparent and tonemap as one pass. Meta: fixed foveation saves up to about 25 % on pixel-heavy apps. Sources: [Godot OpenXR settings](https://docs.godotengine.org/en/latest/tutorials/xr/openxr_settings.html), [PR 116220](https://github.com/godotengine/godot/pull/116220), [PR 117868](https://github.com/godotengine/godot/pull/117868), [Meta advanced GPU pipelines](https://developers.meta.com/horizon/documentation/native/android/po-advanced-gpu-pipelines/), [Meta fixed foveated rendering](https://developers.meta.com/horizon/documentation/native/android/os-fixed-foveated-rendering/), [W4 Games](https://www.w4games.com/blog/w4-games-news-1/where-every-millisecond-counts-optimizing-godot-for-standalone-xr-159), [Godot forum XR guide](https://forum.godotengine.org/t/performance-considerations-for-stand-alone-xr/52324).

**2. Application SpaceWarp. Not done.** Render at 36 Hz, the runtime synthesises every other frame from motion vectors and depth: Meta quotes up to about 70 % more GPU time per frame. Godot 4.7 has `xr/openxr/extensions/frame_synthesis` (`XR_EXT_frame_synthesis`); the vendors plugin has Meta's sample. A static room is the best case, and the game layer keeps its own 72 Hz. Risks: artefacts on transparent effects (flames, embers, shafts) and fast controllers; Red Matter 2 and Asgard's Wrath 2 shipped without it. Sources: [Meta App SpaceWarp](https://developers.meta.com/horizon/essentials/app-spacewarp), [Godot vendors plugin 4.0](https://godotengine.org/article/godot-openxr-vendors-plugin-400/), [Mixed on Red Matter 2](https://mixed-news.com/en/metas-new-rendering-technique-for-quest-2-is-no-silver-bullet/).

**3. No dynamic lights. Done.** Every lit pixel runs the light loop; Godot Mobile also picks shader variants by light count per object. Bake everything; animate fire in the flame shader, or with a global shader uniform times a vertex-colour or UV2 mask on nearby surfaces. If one must stay: small `omni_range`, a tight `light_cull_mask`, or vertex shading (`render_mode vertex_lighting`, `rendering/shading/overrides/force_vertex_shading`).

**4. Reflection probe only on glossy objects. Done.** `ReflectionProbe.reflection_mask` set to the decor layer (frames, banner gold, candles, books, logs, table pieces); the room shell and the baked props (table, weapons, chandelier) skip the box-projected cubemap lookup. Put a glossy baked prop on both layers if it should reflect. Do not use `ambient_light_disabled` for this: on Mobile it also skips the lightmap.

**5. Cheaper surface shading (the remaining ~3 ms). Partly done.**
- `rendering/lightmapping/lightmap_gi/use_bicubic_filter=false` (done): one lightmap fetch instead of the four of bicubic. Non-directional lightmaps (the default) need one sample, directional four.
- Baked albedo: lighting times albedo baked into one unlit UV2 texture for walls, floor and ceiling (`render_mode unshaded`), the classic mobile VR approach (reportedly Batman Arkham Shadow). Largest remaining lever, loses view-dependent specular and needs a detail texture for close-up detail.
- Smaller: no parallax and no triplanar on large surfaces (triplanar is three times the fetches), `specular_mode = SPECULAR_DISABLED` on matte materials, half-size ORM maps, drop the dirt detail (0.4 ms measured).
- Source: [Arkham Shadow analysis](https://foro3d.com/en/2026/mayo/pipeline-grafico-de-arkham-shadow-optimizacion-para-vr-en-quest-3.html) (secondary).

**6. MSAA costs time, it does not save it** (+0.5-1.5 ms). Meta recommends 2x-4x on Quest because the resolve from tile memory is almost free; only on the single-pass path (`msaa_3d`). Sources: [Meta MSAA analysis](https://developers.meta.com/horizon/documentation/native/android/mobile-msaa-analysis/), [Meta loads, stores and passes](https://developers.meta.com/horizon/blog/loads-stores-passes-and-advanced-gpu-pipelines/).

**7. Eye-buffer resolution.** Cost scales with pixels: `OpenXRInterface.render_target_size_multiplier` (0.9 is about 19 % fewer pixels). Not `scaling_3d_scale`: it adds an upscale and forces the separate pass.

**8. Overdraw.** Godot Mobile has no depth prepass; opaque objects are sorted front to back and the GPU's hidden-surface removal helps. Keep alpha-blended effects small on screen; alpha scissor or opaque for banners and shelves. Compressed textures with mipmaps (ASTC/ETC2) are already right.

## 3. What Quest titles do

Public detail is thin; no rendering postmortems were found for Demeo, Moss, Resident Evil 4 VR or The Walking Dead: Saints & Sinners.
- Demeo (2025 technical update): Unity URP, Unity 6 lighting, eye-tracked foveation ([Mixed](https://mixed-news.com/en/demeo-technical-update/), [Resolution Games](https://www.resolutiongames.com/blog/the-411-on-demeos-technical-update)).
- Red Matter 2: modified mobile shaders, high-quality lightmaps, eye-tracked foveation on Quest Pro for more resolution, no SpaceWarp ([Android Central](https://www.androidcentral.com/gaming/virtual-reality/heres-what-eye-tracked-foveated-rendering-on-the-quest-pro-looks-like)).
- Asgard's Wrath 2: no SpaceWarp ([GDC](https://schedule.gdconf.com/session/asgards-wrath-2-how-we-built-vrs-largest-open-world-rpg-presented-by-meta/903519)).
- Batman Arkham Shadow: mostly baked lighting by one account, some real-time shadows by another ([UploadVR](https://uploadvr.com/batman-arkham-shadow-quest-3)).
- Common pattern: baked lighting, few or no dynamic lights, no bloom, MSAA, fixed foveation.

## 4. Profiling on the headset

- `quest.sh sample <rows>`: FPS, app GPU ms, GPU busy, CPU and memory into a CSV. The VrApi line in logcat also shows `Fov=` (the foveation level in use) and `CPU4/GPU=` (clock levels): compare times only at the same GPU level.
- Test command `gfx <feature> <0|1>` switches room features at runtime for A/B runs (list in `room.gd set_feature`); `gfx 10 <level>` foveation level, `gfx 11 <0|1>` dynamic foveation. Switching a material feature recompiles shaders: drop the first rows after a switch.
- `adb shell ovrgpuprofiler -t -v`: per-stage GPU trace; load and store counts show a separate tonemap pass ([Meta](https://developers.meta.com/horizon/documentation/native/android/po-advanced-gpu-pipelines/)).
- RenderDoc Meta Fork: per-draw tile timings ([Meta blog](https://developers.meta.com/horizon/blog/how-to-optimize-your-oculus-quest-app-w-renderdoc-quest-hardware-and-software-offerings/)). Perfetto with GPU counters for system traces.

## 5. Next, when the budget is needed

About 7 ms of the 13.9 ms frame is left for the 3D view ([`PROJECT_PLAN.md`](PROJECT_PLAN.md#budget-left-for-the-3d-view)). If it needs more, in order: baked albedo for walls, floor and ceiling; then SpaceWarp, checked for artefacts on the flames and the controllers; `render_target_size_multiplier` 0.9 only if both are not enough. Keep the 3D view's own materials on the rules above (no glow, no dynamic lights, no screen-reading shaders).

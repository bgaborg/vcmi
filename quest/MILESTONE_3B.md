# Data bridge milestone 3b: map object sprites (research findings)

Status: 2026-11-07, plan steps 1 and 2 done: the decode benchmark changed the design (section 1a); the bridge decodes .def and PNG frames (section 1b). **Read this before continuing 3b.** Next: plan step 3 (section 7). Context: [`DATA_BRIDGE.md`](DATA_BRIDGE.md) (sections 3-5, milestone 3a results).

Original recommendation (revised in section 1a, keep for the facts): 8-bit indexed sprite pages with one palette row per animation, decoded by a new bridge function that calls `CDefFile` directly on a worker thread. Bodies in one alpha-scissor MultiMesh pass, shadows in one blended pass. Frames advance in the shader as the 2D map does. Sprites replace the markers only when a tile is at least ~12 px on screen. No changes to upstream files. This replaces the older plan in `DATA_BRIDGE.md` ("draw each frame twice into an `SDL_Surface`").

## 1. Required checks before continuing

These were not checked by the research. Each one can change the design, so measure them first and record the results here:

1. **JSON and PNG animations:** count the HotA objects on the heaviest map whose animation is a mod JSON layout or PNG frames, not a `.def` (`existsResource(path.toType<EResType::JSON>())`). Few: they keep their markers. Many: add an RGBA fallback through `loadAnimation` → `IImage::draw` on the GUI thread.
2. **MultiMesh custom data precision:** check whether Godot's Mobile renderer keeps `INSTANCE_CUSTOM` at full float32 on Quest. If it is half precision, object ids above 2048 lose precision: pass the id through the transform instead.
3. **Frame and pixel counts:** the atlas sizes below (frames, content pixels, pages, MB) and the build time are estimates. Step 1 of the plan measures them; the budgets (section 6) must hold, or the design changes (for example a disk cache when the build takes over 2 s).
4. **Shimmer when shrunk:** indexed pages cannot be filtered or mipmapped. Check on the headset whether sprites shimmer between 12 and 32 px per tile. If they do, use RGBA8 pages with mipmaps (about 5x the memory, still under 256 MB).

## 1a. Results of plan step 1 and the revised design

Measured with `quest/tools/object-bench.sh run` on the heaviest map's autosave (Might and Magic, 252x252x2), on the Quest without the game. The benchmark (`benchSprites` in `quest/bench/ObjectBench.cpp`) decodes every animation of the map with `quest/bridge/SpriteDecode` (`CDefFile` with an index loader) and shelf-packs the frames into 2048² R8 pages. It also writes `sprites.tsv` (per animation: .def, JSON layout, frames, pixels, trimmed pixels) and page 0 as `page0.ppm` into the benchmark folder.

| Item | Estimate | Measured |
|---|---|---|
| Animations (string table + 8 hero flags) | 1 875 | 1 883: 974 with a mod JSON layout, 1 JSON only (`AVWcoat`), no .def missing otherwise |
| Frames, distinct (same frame name decoded once) | 5-8k | 11 840, 8 060 distinct |
| Pixels, distinct frames | 10-25 M | 50.4 M as stored in the .def, 34.6 M trimmed to the visible box |
| R8 pages of 2048² | 3-6 (12-25 MB) | 13 (55 MB), fill 93 %, nothing too big |
| Decode, one thread | 0.5-1 s | 0.97-1.2 s (0.5 ms per animation; no row runs past its end), pack 55-59 ms |

- **Check 1, JSON animations: many.** 974 of them come from the installed `hd-remastered` mod (1 from HotA's `factory`). It replaces the frames with 32-bit RGBA PNGs at 1x size (2 876 frames, 17.1 M pixels, 12.3 M trimmed), and 638 frames have a `-overlay.png` with the owner flag mask (the `-OVERLAY` / `-SHADOW` names are built in `RenderHandler::loadScaledImage`, `clientsdl3/render/RenderHandler.cpp:464-472`). The game uses these 1x layouts on the Quest: its scaling factor is 1 with `upscalingFilter` `none` (`clientsdl3/render/ScreenHandler.cpp:172-176`), so `getAnimationLayout` reads `SPRITES/`. Markers for half the map's animations are not acceptable, and palette pages cannot hold them: **the atlas must be RGBA.**
- **Check 3, sizes: over budget.** All animations of the map do not fit 32 MB even as R8 (55 MB), and 1 s of decoding misses the budget. 45 animations of 40+ frames hold 11 M of the pixels (the airship `AAir00`: 265 frames, 2.4 M; HotA lakes and monoliths: 50 frames). Large terrain decorations (256x192 patches) are a further share; they are mostly transparent, which trimming partly removes.
- **Checks 2 and 4** are unchanged: 2 at plan step 4, and 4 is settled by the RGBA pages, which can have mipmaps.

**Revised design: an RGBA atlas of what the zoomed view shows, filled on demand.** This is how the 2D map works: it decodes the animations it draws, through a cache.
- **Format:** RGBA8 pages of 2048² with mipmaps, plus an R8 mask array of the same layout for the owner colour. For a .def, the extension bakes the palette (index 0 transparent; 1-4 black at alpha 64/128, as section 2; index 5 keeps its colour and also goes to the mask, see section 1b). For a PNG frame, `loadScaledImage` (`RenderHandler.cpp:408-513`) allows a separate `-SHADOW` image or a generated shadow (`generateShadow`), and a separate `-OVERLAY` image or a generated mask (`generateOverlay`). `hd-remastered` uses neither shadow option: its shadows are in the body's alpha (semi-transparent dark pixels), and its masks are `-OVERLAY` PNGs with an alpha of 0 or 255 (checked in step 2).
- **What is loaded:** only the animations of objects in the zoomed view plus a margin. At about 18k trimmed pixels per animation (all frames), a view with 150 animations needs about 2.7 M pixels: one RGBA page (16 MB, 21 MB with mipmaps, plus 4 MB of mask). Loading on a worker thread at 0.5 ms per animation: about 75 ms for a new view, with markers until the sprites are in. `shortcut:` the 0.5 ms is the .def decode only; half the animations are PNGs, whose decode in Godot is not measured yet: plan step 3 measures it against the 150 ms budget.
- **When the pages are full:** clear them and fill again from the current view. `shortcut:` no per-animation eviction; use an LRU of shelves if panning shows refills.
- **PNG frames:** the bridge reads the JSON layout with lib's `JsonNode` as `RenderHandler::initFromJson` does (`RenderHandler.cpp:156-202`: `basepath`, `images` with `file`) and hands the raw PNG bytes (`CResourceHandler`). Godot decodes them on the worker with `Image::load_png_from_buffer`. An entry with `defFile` takes a frame of another .def. `shortcut:` not read yet; no installed mod uses it (2 088 layouts checked).
- **Drawing:** frames are trimmed to the visible box. With baked RGBA, the bodies (alpha 1, alpha scissor and depth write) and the shadows (alpha < 1, blended) are two materials on the same MultiMesh; the rest of section 5 holds.
- **Budgets** (replacing the table in section 6 for the atlas): pages ≤ 64 MB in all (2 RGBA pages with mipmaps and their masks); a new view's sprites in ≤ 150 ms on the worker; main thread ≤ 1 ms per frame (one page upload, or a sub-rectangle with `RenderingServer::texture_2d_update`). The GPU and change-update budgets stay as they are.
- `shortcut:` sizes per view are estimated from the map's average; plan step 3 measures a real zoomed view.

## 1b. Results of plan step 2: the bridge decodes the frames

- **Bridge (API version 5):** `decodeAnimation(name, VcmiAnimationData *)` returns the frames of an animation from `quest/bridge/SpriteDecode`, which reads them as the 2D map finds them. The .def frames come as palette indices with the palette (`VCMI_FRAME_INDEXED`). The frames a mod's JSON layout replaces (`basepath`, `images` with `file`, and `sequences`, which replace their whole group) come as the PNG file's bytes, found under `SPRITES/`, `DATA/` or the path itself, plus the `-OVERLAY` PNG (`VCMI_FRAME_PNG`). It works only in game, on any thread, and the storage is per thread. Frames are keyed by group and frame: a frame a layout skips is missing, not an empty frame. A layout that is no valid JSON loses the whole animation (0 frames and a warning; the game throws there too), which then keeps its marker.
- **Extension:** `VcmiData.decode_animation(name)` returns the frames as RGBA8 images plus an L8 owner mask, with the palette baked as `setShadowTransparency` does (0 clear; 1 and 4 shadow at alpha 64/128; 2 and 3 the same when they match H3's colours within 8). PNGs are decoded by `Image::load_png_from_buffer`.
- **Owner mask:** index 5 is H3's flag yellow on map objects (for example the HotA tree `TPMTREE2` has a few such pixels). The 2D map colours it only for owned objects (`MapRendererObjects::renderImage`, `client/mapView/MapRenderer.cpp:557-584`: player colour, or the neutral colour for neutral objects). Objects without an owner draw it in its palette colour (`WITH_SHADOW` or `ONLY_BODY_IGNORE_OVERLAY`, `MapRenderer.cpp:425-427`). So the baked image keeps index 5's colour, and the shader puts the owner colour on the mask only for owned objects.
- **Test command `atlas`:** `quest.sh test atlas <i>` saves the frames of animation `i` (from `animation_names`) in full frames, with the mask in red, to the game's `files/atlas/`. `atlas -1` decodes all of the map's animations on a worker and prints the times and the first indices of each kind (PNG, .def with a flag, PNG with a flag). On the main thread a decode of all of them made the system close the app (no frames for seconds), so the atlas fill must stay on workers.
- **Check:** the HD frames (`avlxds01`, the gold mine `AVMgold0` and the shipyard `AVXshyd0`) match the mod's PNGs pixel for pixel, and their flags sit exactly on the mask. The .def frames match the step 1 page (`quest/out/atlas-step2-compare.png`, `quest/out/object-bench/sprite-page0-crop.png`).
- **Times on the Quest** (heaviest map, new game, 1 730 animations, 10 349 frames, one worker): 1.8-2.2 s for all, which is 1.1-1.2 ms per animation (bridge 1.0-1.3 s, bake and PNG decode 0.8 s). The slowest animation is `AVGgolm0` at 19-23 ms. The benchmark without the game: 1.7 s for the bridge side of 1 883 animations, with 2 885 PNG frames (17.2 M pixels, 29.7 MB of files) of which 638 have a mask, and none failed.
- **Budget for a new view:** 150 animations at 1.2 ms make about 180 ms on one worker, above the 150 ms budget. Plan step 3 uses two workers, or a smaller margin around the view.

## 2. How VCMI loads `.def` sprites

- `CDefFile(path)` reads the file through `CResourceHandler` (`client/render/CDefFile.cpp:43-96`), with the 256-colour palette (`:62-68`) and frame offsets per group. `loadFrame(frame, group, IImageLoader&)` (`:99`) decodes the RLE into any loader: `init(size, margins, fullSize, SDL_Color* pal)` plus runs of 8-bit indices (`client/render/IImageLoader.h`). It uses only `SDL_Color`, no SDL calls, no renderer, no GL context.
- `RenderHandler::getAnimationFile` / `getAnimationLayout` (`clientsdl3/render/RenderHandler.cpp:95-133`, `:205-280`) cache files and merge mod JSON overrides; both are private. A mod that replaces a whole `.def` comes through `CResourceHandler` automatically.
- Special palette entries (`clientsdl3/render/ScalableImage.cpp:33-53`, `:198-222`): 0 transparent; 1 and 4 shadow at alpha 64 / 128; 2 and 3 only when they match the source colours; 5 the owner flag (`setOverlayColor`, `:171`).
- Player colour on map objects is only index 5, from `graphics->playerColors[owner]` or `neutralColor` (`client/mapView/MapRenderer.cpp:557-584`, `client/render/Graphics.cpp:148-160`). The 224-255 player ramp is not used on map objects. Hero flags are a separate animation, `AF00`-`AF07` (`MapRenderer.cpp:495-517`).
- Threads: upstream already reads the filesystem from TBB workers (`RenderHandler.cpp:376-391`), so a bridge worker is safe when it runs only in game and never during a mod reload.

## 3. Atlas

- R8 palette indices plus one RGBA8 palette row per animation (256 x N, about 2 MB). The extension bakes entries 0-7; the shader maps index 5 to `owner_colors[owner]` (9 colours). Nearest sampling.
- A `Texture2DArray` of 2048² R8 pages (4 MB each), shelf-packed, sprites trimmed to their content, 1 px padding. Adreno 740 allows 16384² and 2048 layers.
- Estimate (check 3): 1 875 animations, 5-8k frames, 10-25 Mpx, 3-6 pages, 12-25 MB; 0.5-1 s to build on a worker at map load (the game takes 5.8 s to load that map). Names published later are added lazily.
- Tables as `FORMAT_RGBAF` data textures read with `texelFetch`: per frame `{page, x, y, w}`, `{h, marginX, marginY, -}`; per animation and group `{firstFrame, count, mirror}`. Groups 10-15 mirror 6-8 and 1-3 (`createFlippedGroup`, `MapRenderer.cpp:458-480`): a mirror bit, not copies.

## 4. Handing pixels to Godot

- New entry in `VcmiBridgeApi.h` (bump `VCMI_BRIDGE_VERSION`):
  `uint32_t (*decodeAnimation)(const char* name, VcmiFrame* frames, uint32_t cap, uint8_t* pixels, uint32_t pixelCap, uint8_t palette[768]);` returns the frame count, 0 for missing or JSON animations.
- The extension calls it from a `std::thread` and packs into the page buffers. On the main thread at most one upload per frame: `Image::create_from_data(2048, 2048, false, FORMAT_R8, ...)`, `Texture2DArray::create_from_images` first, `update_layer` after; about 1 ms per page. Palette and tables by size-stable `ImageTexture::update`.

## 5. Drawing

- Per instance: transform with the anchor tile and a depth lift; custom data `r` animation-group index, `g` object id, `b` owner + flags x 16. The vertex shader builds the quad from the frame rectangle and margins.
- Frame from `TIME`, as `MapRendererContext.cpp:322-341`: `frame = ((t_ms + id*97 % 180) / 180 + id) % count`.
- Order: VCMI sorts per tile by `drawLayerAt`, `printPriority`, then object rules (`lib/mapObjects/MapObjectDrawOrder.h:69-135`, `.cpp:42-75`). Approximation: one quad per object with the key `(specialGround, anchorY, layer, -printPriority, id)` encoded as a sub-millimetre depth lift; bodies with alpha scissor and depth write; shadows in a blended pass at a lower `render_priority`. Layer and special-ground fit in two spare `flags` bits, so `VcmiObject` stays 16 bytes. Exact per-tile order (about 4x the quads) only if a screenshot shows a wrong order.
- Hero flags are extra instances; boat flags wait for 3c. Fog: as the marker shader.
- LOD: on today's panel a tile is about 1.6 mm, about 3 px: keep the markers. Sprites at ≥ ~12 px per tile need a zoom (a simple one in 3b, or the zoomed panel of phase 4); hidden when zoomed out.
- Culling: chunks of 32x32 tiles (128 on the heaviest map), `custom_aabb` grown by 8 tiles up and left.

## 6. Budgets on Quest 3

| Item | Budget |
|---|---|
| Decode and pack, one worker thread | < 1 s, < 32 MB of pages |
| Godot main thread per frame (uploads) | < 1 ms |
| App GPU with sprites visible (`xr-perf.sh`) | ≤ +0.5 ms, 72 FPS held; 0 ms zoomed out |
| Change update of instances | < 0.1 ms |

## 7. Plan

1. **Done 2026-11-07, results in section 1a.** Decode benchmark without the game: add `client/render/CDefFile.cpp` and a `DefDecode.cpp` loader to `quest/bench/bench.cmake` (needs only SDL's include directory) and run it like `object-bench.sh` on the heaviest save. Report frames, content pixels, pages, JSON animations left out (check 1) and decode + pack time (check 3).
2. **Done 2026-11-07, results in section 1b.** Bridge `decodeAnimation` for the revised design: the .def frames as indices with the palette (`SpriteDecode`, as benchmarked), and for a JSON layout the PNG bytes of each frame and its overlay. Godot bakes and decodes them on the worker into RGBA. A test command `atlas <name>` saves the RGBA frames under `quest/out/` as PNG; compare with the 2D map's sprite, for one .def object and one `hd-remastered` object.
3. **Next.** Extension workers (two, section 1b) and the view-driven page fill, applying the owner mask only to owned objects; main-thread timers in the `bridge` stats, texture memory with `quest.sh sample`, and the real number of animations and pixels in a zoomed view.
4. Shader with palette, flag colour, mirroring and TIME frames on 100 objects of the first scenario; screenshot next to the 2D view. Check 2 (custom data precision) here.
5. All objects, chunks, depth-lift order, shadow pass and the LOD switch on the heaviest map; check 4 (shimmer) and the GPU budget.
6. Change log: update only the instances of changed records.

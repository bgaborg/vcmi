# Data bridge milestone 3b: map object sprites (research findings)

Status: 2026-11-09, plan steps 1-6 done, 3b complete: the decode benchmark changed the design (section 1a); the bridge decodes .def and PNG frames (section 1b); the atlas fills from the view (section 1c); the sprite shader draws the objects on the minimap (section 1d); a simple zoom and the LOD switch show them on the heaviest map (section 1e); object changes update only their sprites (section 1f), with the work left for phase 4 listed there. Next: milestone 3c (`DATA_BRIDGE.md` section 5). Context: [`DATA_BRIDGE.md`](DATA_BRIDGE.md) (sections 3-5, milestone 3a results).

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

## 1c. Results of plan step 3: the atlas of the view

`quest/xr/extension/SpriteAtlas.h`, used by `VcmiData`:
- **`atlas_view(tiles, level)`** collects the animations of the objects on a rectangle of tiles. The anchors are grown by 8 tiles, as an object is drawn up and left of its anchor, and the hero flags `AF0<owner>` are added. `atlas_busy`, `atlas_stats`, `atlas_page` and `atlas_textures` go with it, and `update()` uploads.
- **Workers:** 3 workers decode through the bridge (`bakeFrames`, shared with `decode_animation`), trim to the visible box, and shelf-pack the frames into 32 pages of 512² RGBA8 plus an R8 owner mask. The colour is premultiplied by alpha on the worker, so mipmaps blend edges right; the shader of step 4 is to blend premultiplied. A worker builds a page's images with mipmaps, at most two waiting for the upload. The main thread uploads at most one page per frame (`Texture2DArray::update_layer`) and does not wait for the workers there (`try_lock`); the other calls hold the lock only for copies. A frame bigger than a page (512 px) leaves its animation as a marker.
- **Refill:** a view whose animations do not all fit leaves the rest as markers and refills on the next view. A view that needs other animations refills when the old ones are more than twice as many and over 64. `shortcut:` no eviction of single animations; an LRU of shelves if panning in phase 4 shows refills.
- **Memory (computed, not measured):** 56 MB on the GPU (32 x 512² RGBA8 with mipmaps 45 MB, masks 11 MB), 42 MB of CPU pages, plus up to two built pages waiting (about 3.5 MB). The first upload creates the empty arrays on the main thread once: 40 ms (`create_us`), a hitch to move to map load or a worker in step 4.
- **Test command** `quest.sh test atlas-view <x> <y> <size>` (x < 0: the map's centre) loads a view, waits, prints `atlas_stats` and saves the first 16 pages to `files/atlas-pages.png`.

Measured on the Quest, heaviest map, new game (`quest/out/atlas-pages-512-crop.png`):

| Version | 30x30 view, cold | Pan by 5 tiles | 20x20 view after a refill | Main thread per upload |
|---|---|---|---|---|
| 2 pages of 2048², 2 workers | 1 151 ms, 9 animations left out | | | 7.4-11.3 ms |
| 32 pages of 512², 2 workers | 888 ms | 177 ms | 508 ms | 0.34-0.81 ms |
| + premultiplied (no `fix_alpha_edges`), 3 workers | 663 ms | 79 ms | 341 ms | 0.34-0.98 ms |
| + review fixes (premultiply on the worker, at most 2 built pages waiting) | **680 ms** | **94 ms** | **412 ms** | **0.32-0.38 ms, one spike 1.55 ms** |

- **A view is bigger than estimated.** A 30x30 view in the middle of the heaviest map holds 369-373 animations (not 150), 1 264-1 312 frames and 5.6-5.9 M trimmed pixels: 31-32 of the 32 pages. Animated decorations dominate: a waterfall of 18 frames and a mine of 15 fill most of two pages.
- **Mipmaps:** `fix_alpha_edges` cost about 18 ms per page. Premultiplied pages need no edge fix: 576 -> 45 ms of worker time for the view.
- **The cold view misses its 150 ms budget, panning meets it.** The cold view is bound by decoding: 0.61 s of worker time on 3 workers, and the wall time is about the same, so the bridge side (file reads) appears to run one at a time. Building pages while decoding (tried: build each page the packer has left) made no gain (888 / 161 / 605 ms) and was reverted.
- **Next for speed, when phase 4 needs it:** load the area around the player's heroes and towns at map start, so the first view is warm; a disk cache of baked animations per mod set; share identical frames (many animated decorations repeat frames).

## 1d. Results of plan step 4: the sprite shader

- **Extension:** `VcmiData.update_sprites(multimesh, tiles, level)` makes one instance per object (and per hero flag `AF0<owner>`) whose frames are in the atlas, sorted by anchor row, then heroes and boats after the other objects of the row (the 2D map draws them last on a tile), then column and id. The shader draws without depth, so the instance order is the drawing order. `shortcut:` special ground (clover field, cursed ground) is not drawn first, and boats fly no flag yet (the bridge publishes neither). It also builds the frame table (`sprite_table`: RGBAF, 2 texels per frame: page, x, y, width; height, then left and top from the frame's own full bottom right, full width). Groups 10-15 of heroes and boats take the mirrored group, as `createFlippedGroup` (`MapRenderer.cpp:458-480`). `sprite_names` gives each instance's animation, anchor and group, for debugging (only with `with_names`, as the test command `sprites` does). `update_sprites` must run again after an atlas refill, which moves the frames.
  - Instance: the transform maps pixels to the minimap's unit space, at the anchor tile's bottom right, where each frame's full bottom right sits, as `MapRendererObjects::renderImage` places it.
  - Colour: the anchor and visitable tile, for the fog test.
  - Custom: the first frame, the count + 1024 when mirrored, the owner colour (0-7, 8 neutral, 9 none; heroes none, as the 2D map), and the id + 0.5.
- **Shader** (`room.gd` `SPRITE_SHADER`): the quad of the current frame from the table. The frame is chosen from `TIME` as `MapRendererAdventureContext::objectImageIndex`: 180 ms a frame, with the clock and the frame offset by the id. Premultiplied blending; the pages hold the colour premultiplied in linear light and sRGB-encoded, so the GPU's decode gives the right value without shader maths (decoding plain premultiplied sRGB values would darken edges), and their mipmaps are averaged in linear light on the worker (`Image::generate_mipmaps` averages the encoded bytes); clear pixels are discarded; the owner colour (`Graphics.cpp:72-90`, in linear colour) goes on the mask; the fog test is the markers'. `precision_check` paints red an instance whose `.5` was lost.
- **Check 2, precision: passed.** The Mobile renderer keeps the instance data in 32-bit floats. On a 30x30 view of the heaviest map (905 instances, object ids far above 2048) `precision_check` paints nothing red (`quest/out/sprites-step4/heavy-zoom.png`); `update_sprites` took 3.8 ms there.
- **Check:** on the first scenario (72x72, 898-998 instances from about 445 animations, 150-170 animations left out because the 32 pages were full), every object sits where the 2D map has it, with the same animation: the Cove fort with its owner's flags, the windmill, lake, temple, watermill, mountains and snow (`quest/out/sprites-step4/2d-vs-table.png`). The first scenario picks its starting town at random, so a comparison needs the 2D screenshot and the capture from the same game. `update_sprites` takes 1.5-2.7 ms for 900-1000 instances on the main thread, which is to be divided by plan step 6.
- **Local tests:** the test command `sprites` saves all the table's input to `files/sprites.bin`: the minimap images, the atlas pages and masks, the table, the MultiMesh buffer and the names. `quest/tools/render-room.sh sprites [name|near]` renders the table from it on the PC in about 13 s, with the views `sprites`, `sprites-close` and `sprites-zoom`. `name` cuts out the frames of the first instance of an animation and draws it alone; `near` cuts out frame 0 of everything near the zoom tile; `zoom=x,y` moves the close view. `QUEST_ADDRESS=<ip>:5555` connects to the headset first and pulls the newest capture. The capture holds the base level of the pages; the preview builds their mipmaps again. Shader and layout work runs locally; the headset is needed only for new game data or for speed.
- **How it looks:** this is a check of the data, not the table's look. The tiles are minimap colours, without the 2D map's terrain tiles, roads and rivers; the whole map lies on 0.5 m, so the sprites are small; and they lie flat. A first look pass (the terrain tiles, roads and rivers through the same atlas from the tile data the bridge has) was offered and set aside on 2026-11-09 to keep the plan order; it belongs to phase 4 with the concept's paper cards and fog clouds.

## 1e. Results of plan step 5: zoom, LOD switch, the heaviest map

- **Zoom** (`room.gd` `set_zoom`): the minimap shows 1 / zoom of the map around a centre, clamped to the map. The terrain moves by its UV; the markers and sprites move by their node's transform and are cut at the panel's edge in their shaders (`world_to_panel`, `panel_half`). Test command `table_zoom <factor> <u> <v>`; the controls (grab, pinch) are phase 4. `shortcut:` markers grow with the zoom.
- **LOD switch** (`main.gd` `_update_sprite_view`, every frame in game): sprites instead of markers from 12 px per tile on screen, and only while the view shows one map level (the levels lie side by side). The size is computed from the head's distance to the minimap's centre, about 1 150 px per radian on the Quest 3. The atlas is asked for the tiles the zoomed minimap shows plus 2 on every side when the view moves more than 2 tiles, changes size or the map is new, and the sprites are rebuilt once it is loaded. After an atlas refill, which moves the frames, markers show until the rebuild. Placing or recentring the room updates the panel's clip. The test command `sprites` holds its own sprites until the next `table_zoom`.
- **What the plan had and is not needed:**
  - Chunks: a view holds at most a few thousand instances and the panel cuts the rest, so one MultiMesh is enough. Chunks come with phase 4's bigger views.
  - The depth lift and a separate shadow pass: instances are drawn in the 2D map's order without depth, shadows in the same premultiplied pass (section 1d).
- **Measured on the Quest** (heaviest map, the head 25 cm above the table, `quest.sh sample`, 10 rows each, `quest/out/sprites-step5/`):

| | App GPU, median | Max | FPS |
|---|---|---|---|
| Zoom 1, markers | 5.42-5.44 ms | 5.96 ms | 72 |
| Zoom 8, sprites, first version | 6.51 ms | 7.08 ms | 72 |
| Zoom 8, sprites, linear premultiplied pages and clear pixels discarded | **6.16 ms** | 6.64 ms | 72 |
| The same after the review fixes (linear mipmaps, one level at a time) | 6.55 ms (6 rows) | | 72 |

- **GPU:** the sprites cost +0.74-1.1 ms at zoom 8 (run-to-run spread), over the +0.5 ms budget (section 6) and inside the frame (13.9 ms at 72 Hz, 7 ms left for the table). The first version decoded sRGB with `pow` in every pixel and blended the clear parts of every quad: +1.07 ms. Next, when the budget is needed: draw the opaque pixels first with depth writes and a lift per instance in drawing order, so hidden pixels are not shaded (the section 5 design), then blend only the semi-transparent ones.
- **Check 4, shimmer:** mipmapped RGBA pages, and the LOD switch keeps sprites at 12 px a tile or more. Still frames look clean (`zoom8-b.jpg`); moving shimmer needs a person wearing the headset.
- The whole sprite set is rebuilt when the view moves; between views plan step 6 updates only the changed objects (section 1f).

## 1f. Results of plan step 6: change updates

- **Extension:** `VcmiData` keeps the view's sprites in drawing order, with their frame table. `update_sprite_changes(multimesh)` takes the objects changed since the last update (from the change log of milestone 3a), removes their sprites, inserts the new ones in order and writes the buffer again. It returns 1, or 3 when a changed object needs frames the table did not have (`main.gd` then sets the table again). It returns -1 when only a whole update will do: a new list or map, over 4 096 changes waiting (sprites not shown for long), or an animation that is not in the last `atlas_view`. `main.gd` then asks for the view again. Changes are applied only while the atlas is not loading. Animation names are kept in UTF-8 once instead of being converted per object, and the sprites carry no name string: together the full update got 1.4-2.5x faster. A full update that finds an object whose animation the view did not ask for (it changed while the atlas loaded) asks for the view again.
- **Check:** the test command `sprites_check` runs a whole `update_sprites` of the same view and compares it with the change-updated buffer, instance by instance (frames compared by their table entries). It matched in all 38 runs: hero steps on the first scenario and on the heaviest map, and 10 pans of the heaviest map.
- **Measured on the Quest** (`quest/out/sprites-step6/`):

| | Instances | Full update | Change update, per hero step |
|---|---|---|---|
| First scenario, zoom 2 | 979-997 | 0.97-1.27 ms (was 1.5-2.7 ms) | 52-176 µs, once 438 µs |
| Heaviest map, zoom 8 | 1 783-1 930 | 2.2-3.5 ms, of which the buffer 0.1-0.2 ms | 67-84 µs |

  Panning the heaviest map in 10 steps (2 full updates each, with the check) held 71-73 fps (`heavy-pan.csv`).
- **Left for phase 4**, measured and not blockers at 72 Hz, to do when phase 4's pan and zoom controls move the view all the time:
  - The full update on a view change stays on the main thread: 2.2-3.5 ms once per view, mostly the loop over all 53 808 objects. No frame drop was measured. Fix: a worker builds the instances from a copy of the objects in the view, or a tile index of the objects.
  - Change updates rewrite the whole buffer, so the slow ones reach 176 µs (once 438 µs), over the 0.1 ms budget. Fix: write only the range of instances that moved.
  - On the heaviest map at zoom 8 every pan of about 5 tiles refills the atlas (the 32 pages overflow): about 620 ms of loading with markers shown. Fix: the LRU eviction of shelves (section 1c's shortcut).
  - GPU: the sprites cost +0.74-1.1 ms against a +0.5 ms budget (section 1e). Measure again with phase 4's terrain tiles, then do the opaque-first pass of section 1e if needed.

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
3. **Done 2026-11-09, results in section 1c.** Extension workers and the view-driven page fill; main-thread upload timers in `atlas_stats`, and the real number of animations and pixels in a zoomed view. Texture memory is computed, not yet read with `quest.sh sample`.
4. **Done 2026-11-09, results in section 1d.** Shader on the atlas pages (premultiplied blending; the owner colour on the mask only for owned objects; mirroring and TIME frames) on the objects of the first scenario; screenshot next to the 2D view. Check 2 (custom data precision) here.
5. **Done 2026-11-09, results in section 1e.** All objects, the LOD switch with a simple zoom, on the heaviest map; check 4 (shimmer) and the GPU budget. Chunks, the depth lift and the shadow pass were not needed (section 1e).
6. **Done 2026-11-09, results in section 1f.** Change log: update only the instances of changed records. Keeping a view's rebuild off the main thread's frame was measured and left for phase 4 (section 1f).

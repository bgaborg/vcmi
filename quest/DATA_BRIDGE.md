# Data bridge: game data from VCMI to Godot

Status: option C chosen 2026-11-06; milestones 0, 1 and 2 done, milestone 3 (objects) in progress: 3a, the object list, done ([section 5](#5-milestones), [`PROJECT_PLAN.md`](PROJECT_PLAN.md#0-status-and-next-steps)).

Phases 4 (tabletop adventure map) and 5 (battle diorama) draw the game in 3D in Godot. Godot needs game data (tiles, objects, fog, heroes, battle stacks), not pixels. This plan picks how the data gets from the VCMI client to Godot, with the fewest changes to upstream VCMI and the lowest cost in CPU and memory on Quest 3.

## 1. Facts the design rests on

All paths are in this repository; line numbers are from 2026-11-06.

**One native library.** On Android VCMI builds static libraries and links them into one `libvcmiclient_arm64-v8a.so` (`CMakeLists.txt:75-80,104-105`, `clientapp/CMakeLists.txt:27-33`), loaded by `LibsLoader.java:22` when the game activity starts, after Godot. There is no `libvcmi.so`.

**Hidden client symbols.** Visibility is hidden by default (`CMakeLists.txt:356-357`). `lib/` classes marked `DLL_LINKAGE` are exported (`Global.h:210-221`); the client (`GAME`, `ENGINE`, `CPlayerInterface`, `client/mapView`, `client/battle`) is not. Code outside that `.so` cannot reach the client or its lock; code compiled into it can.

**Toolchain.** NDK r29, `c++_shared`, C++20 (conan profiles `android-64-ndk`, `base/android`); the APK ships one `libc++_shared.so`. Godot 4.7.2 is a separate `libgodot_android.so`; Godot and extensions talk through a C ABI.

**Same process.** `VcmiXrActivity` (Godot) and `VcmiSDLActivity` (game) run in one process and one address space, in one linker namespace. Data can be shared by pointer.

**Threads and locks.**
- Net packs arrive on `CServerHandler::threadNetwork`; `onPacketReceived` takes `ENGINE->interfaceMutex` (`client/CServerHandler.cpp:983-988`) and applies the pack under `CGameState::mutex` (`client/Client.cpp:335-345`).
- The game GUI thread holds `interfaceMutex` for the logic and drawing part of each frame and releases it to present and wait (`client/GameEngine.cpp:131-140`).
- Callbacks run with `interfaceMutex` held, but some release it inside a pack (`client/CPlayerInterface.cpp:1493,1534`).
- Godot renders on its own thread at 72 Hz (runtime default; 90 Hz possible, not budgeted). It must never wait for `interfaceMutex`.

**Hooks that need no upstream change.**
- `IMapObjectObserver` (`client/mapView/IMapRendererObserver.h:17-50`): object fade in / out, add / remove, `onHeroMoved`, teleport, embark / disembark; `hasOngoingAnimations` / `waitForOngoingAnimations` (`:23-24`), which the game calls after each hero step and fade (`client/mapView/mapHandler.cpp:30-43`, `client/HeroMovementController.cpp:195`, `client/CPlayerInterface.cpp:1553`); `endNetwork` (`:25`), called before the map is destroyed (`client/Client.cpp:132`). The constructor registers with `GAME->map()`, the destructor unregisters through it (`mapHandler.cpp:177-185`).
- `CClient::registerBattleInterface(IBattleEventsReceiver, color)` (`client/Client.h:160`): battle events, given to extra receivers after the 2D battle interface (`client/NetPacksClient.cpp:72-82`).
- `ENGINE->dispatchMainThread` (`client/GameEngine.h:144`): runs a function on the game GUI thread with the lock held.
- Read API: `GAME->interface()->cb` (`client/CPlayerInterface.h:103`): `getTile`, `getObj`, `isVisible`, `getMapSize`, `getPlayerTeam` (`lib/callback/IGameInfoCallback.h:109`, a `const TeamState*`). Fog per team: the public `TeamState::fogOfWarMap`, 1 byte per tile, indexed `z*W*H + x*H + y` (x-major, `lib/mapping/MapTilesStorage.h:24-26`, `lib/CPlayerState.h:157`).
- Lifetimes: `GAME->map()` throws when there is no map (`client/GameInstance.cpp:55-58`); `adventureInt` is reset before the map is destroyed (`client/Client.cpp:678`) and swapped by replays (`client/GameplayReplayer.cpp:162,190,347,349`); restart calls `endGame()` without `endNetwork` (`client/CServerHandler.cpp:829-833`).

**Sizes.**
- Map: up to 252 x 252 tiles, 2 levels (`lib/mapping/CMapHeader.h:227-232`): 127 008 tiles.
- Objects (milestone 0, counted from the map files): 7 009 on an XL map (Myth and Legend), 23 803 on the heaviest map shipped enabled (The Devil Is in the Detail, G), 64 622 on the heaviest HotA map at all (Might and Magic, G, in the "Famous community maps" pack, off by default). Distinct sprites: 540, 1 286 and 1 852.
- Battle: 187 hexes (`lib/battle/BattleHex.h:19-21`), 7 stacks per side plus war machines and summons.

**Memory today.**
- Image cache: RAM / 16, clamped to 64-512 MiB, `video.assetCacheSize` (`clientsdl3/render/RenderHandler.cpp:56-63`).
- HD Edition DDS cache: up to 256 MB (`client/render/hdEdition/DdsFormat.h:68`).
- xBRZ: "xbrz2 may use ~1.0 - 1.5 Gb" (`clientsdl3/render/ScreenHandler.cpp:470-480`), auto-selected on the Quest (log: "Selected upscaling filter 2").
- Quest 3 has 8 GB for the OS, the game and Godot.

**The 2D view keeps running.** Godot showing a tabletop does not change the game's window stack: the game still draws to its virtual display and the adventure map stays the top window (`MapViewController.cpp:321,352`). So its hero animations keep blocking the network thread (`MapViewController.cpp:620-631`) unless another window is on top of the adventure map (`:321,352`) or the move-time settings (`adventure.heroMoveTime`, `enemyMoveTime`) are 0 (`:306-307`). The game skips a frame only between two steps of a walking hero on the plain adventure map (`client/GameEngine.cpp:122`, `GameInstance::wantsFrameRendered`, `client/GameInstance.cpp:127-143`); otherwise it renders every frame at `video.targetfps`. A normal frame redraws only the top window; a full redraw of all windows happens when one is pushed or popped (`client/gui/WindowHandler.cpp:37-51,142-176`). `IImage` has no pixel accessor; it can draw into an `SDL_Surface` (`clientsdl3/render/IImage.h:88-122`).

## 2. Options

| | A: JNI hook | B: GDExtension linked to VCMI | C: in-client bridge + thin GDExtension (recommended) |
|---|---|---|---|
| What | client code serialises data and calls Java `VcmiBridge`, which emits signals with `PackedByteArray` | a godot-cpp `.so` links VCMI and reads game state | quest-only sources compiled into `libvcmiclient` fill plain buffers under the game's lock; a small godot-cpp extension reads them by pointer through one exported `extern "C"` table |
| Upstream change | client sources, CMake, JNI glue | VCMI must export client symbols and the lock: many files | 4 lines in `clientapp/CMakeLists.txt` |
| Copies per update | C++ -> `byte[]` -> `PackedByteArray`, plus JNI calls | 0 | 1 (buffer -> Godot array or texture) |
| Godot waits for the game lock | no | yes, or unsafe reads | no (lock-free buffer exchange) |
| Decoding | in GDScript: slow for 127k tiles | native | native, in the extension |
| Build | nothing new | the extension becomes a VCMI target with VCMI's flags, Boost headers and STL | extension built with godot-cpp and the same NDK; no VCMI headers |
| Rebase risk | medium | high | low |

C combines A's small upstream change with B's speed. The C ABI boundary means the two sides share no C++ types.

## 3. Design (option C)

### Layout

```
quest/bridge/                  quest-only C++, compiled into libvcmiclient_<abi>.so
  VcmiBridgeApi.h              the C ABI: plain structs, the function table, VCMI_BRIDGE_VERSION
  Bridge.cpp                   lifecycle task, observer, buffers, battle receiver; includes the two below
  ObjectScan.cpp/.h            the object records (milestone 3a), also built into quest/bench
  SpriteDecode.cpp/.h          the frames of an animation: .def indices and mod PNGs (MILESTONE_3B.md), also in quest/bench
quest/xr/extension/            godot-cpp GDExtension libvcmi_xr.so
  CMakeLists.txt               built by quest/tools/make-extension.sh into src/quest/jniLibs
  VcmiData.cpp                 Godot class: finds the table, turns buffers into Image / MultiMesh / arrays
  SpriteAtlas.h                the sprites of the view in Texture2DArray pages, filled by workers (MILESTONE_3B.md 1c)
android/vcmi-app/src/quest/assets/vcmi_xr.gdextension   android_aar_plugin style, path returned by VcmiBridge
```

Upstream change, `clientapp/CMakeLists.txt` (4 lines, inside its `if(ANDROID)`): when `quest/bridge/Bridge.cpp` exists, add it to `target_sources(vcmiclient PRIVATE ...)` ([`PROJECT_PLAN.md`](PROJECT_PLAN.md#changes-to-upstream-files-keep-this-list-short)). Client headers come through `vcmiclientcommon`'s include directories. The table is `extern "C" __attribute__((visibility("default")))`: `--gc-sections` keeps exported symbols of a shared library, and `-Bsymbolic` does not affect `dlsym`.

### Lifecycle

1. Godot loads `libvcmi_xr.so` at startup (GDExtension, path from `VcmiBridge.getPluginGDExtensionLibrariesPaths()`, as godot_openxr_vendors does).
2. Each second until it succeeds, the extension tries `dlopen("libvcmiclient_arm64-v8a.so", RTLD_NOLOAD)` and `dlsym("vcmi_bridge_api")`: the game library loads after Godot. The table carries `VCMI_BRIDGE_VERSION`; a mismatch disables the bridge and logs it.
3. The first call posts a lifecycle task with `ENGINE->dispatchMainThread`. On the game GUI thread it re-posts itself every 100 ms. It reads `GAME->interface()` and `adventureInt` each tick and never caches `cb`:
   - `adventureInt` is null (main menu, between games): nothing to do.
   - The bridge holds an observer keyed by a `std::weak_ptr` to the current `adventureInt`: use it.
   - Otherwise a new game, load or replay pass has started: create a new observer keyed by it, register battle receivers for the local players' colours on the current `CClient`, and publish the tile snapshot. A map exists whenever `adventureInt` does. The `weak_ptr` keeps its control block alive, so a new interface cannot reuse an old identity.
   - It never creates an observer while the bridge's own animation wait is active: `CMapHandler::waitForOngoingAnimations` iterates the observer list while that wait has the lock released (`mapHandler.cpp:37-43`).
4. Observers are never deleted: deleting one through a missing map throws in the destructor (`mapHandler.cpp:182-185`), and a replay restores the old map with the observer still registered. Each is a few dozen bytes per game or replay pass; all buffers live in the bridge, not in the observer (`shortcut:` comment in the code). An observer whose `adventureInt` has expired publishes nothing.

### Data flow: latest state, not event streams

Tiles and fog are small, so the bridge publishes their full state; objects are many (64 743 on the heaviest map), so after one full list per map it publishes the records that changed:

- **Published copy under a lock Godot only tries** (built in milestone 2 for tiles and fog): the game copies the full current state into the bridge's copy under a small mutex (never `interfaceMutex`) and raises a generation counter; Godot reads the counters each frame and copies only when one changed, with `try_lock`, so it never waits and simply tries again next frame when the game is writing. Simpler than the triple buffer planned first and enough at these sizes; a triple buffer (atomic index exchange) only if a milestone measures lock contention.
- **When the game publishes:** tiles and fog in the 100 ms lifecycle task, objects at the map events (below), only if something changed (an object event happened or the team's `fogOfWarMap` differs from the last copy: a 127 KB compare, about 15 µs). The fog array covers every source: hero sight, spells, observatories, Cartographers, allied vision, Cover of Darkness.
- **Tiles:** one snapshot per map load (terrain does not change in play), as a plain array the extension reads once.
- **Current animation:** one record in the object state (hero step from / to / duration, fade, teleport) with a sequence number. The game waits for each step (below), so at most one animation is pending; Godot echoes the sequence number to confirm it.
- **One producer at a time:** publishes come from the network thread and the GUI thread, both holding `interfaceMutex`; the windows in which the lock is released are waits that publish nothing.
- **Objects (milestone 3a): one record per object id, then the changes.** `quest/bridge/ObjectScan` encodes the objects as the 2D map draws them, indexed by the game's object id (`CMap::objects`). The bridge publishes the whole list once per map (and for each new observer), then each map event marks its object (and a hero's boat); the events after a change (`onHeroMoved`, After*, FadeIn, InstantAdd) encode the marked objects at once and publish the records that changed, with a sequence number, into a log of the last 4 096 changes. Events before a change (FadeOut, InstantRemove, Before*) only mark: the old state is still there; the next event or tick publishes them. FadeOut and InstantRemove objects are encoded again on every tick for 2 s, because the wait for the 2D fade releases `interfaceMutex` before the erase (`NetPacksClient.cpp:510-537`) and no event follows it. A boat with a hero on board carries the hero's owner and stands in for the hero, whom the 2D map hides. Owner changes come as InstantRemove + InstantAdd (`NetPacksClient.cpp:731-753`), so no scan is needed for them; a hero entering or leaving a garrison fires no event (`NetPacksClient.cpp:664-683`), so the tick encodes the heroes on the map again (130 heroes: 5.5 µs). Godot asks for the changes after its sequence number and gets the whole list instead when the log no longer holds them (`resync`).
- **Godot side:** each frame one call for the counters; a copy only when one changed. Object changes update only their MultiMesh instances (`set_instance_*`), with spare instances for objects that appear; a new list fills the whole MultiMesh once.
- **Hidden objects:** heroes in a garrison or a boat are flagged hidden, as the 2D map hides them (`MapRendererBaseContext::objectTransparency`). Objects in the fog are hidden by the reader: the shader drops an object whose anchor and visitable tiles are both in the fog (the 2D view checks every tile of the object).
- **Fog layout:** copied as the game stores it (x-major), straight into the Godot byte array; Godot uploads it as an H x (W x levels) texture and the shader swaps the axes (`UV.yx`). Reordering it in the extension cost 0.3-0.5 ms per update on the heaviest map.
- **Tile layout:** the extension turns the snapshot into one RGBA image per map with the game's minimap colours (`TerrainType::minimapUnblocked` / `minimapBlocked`, sent in the snapshot), the levels side by side, mipmapped.

### Plain records

```
struct VcmiTile   { uint8_t terrain, terrainView, river, riverDir, road, roadDir, flags, pad; };  // 8 bytes
struct VcmiObject { uint32_t id; uint16_t x, y; uint8_t z, owner, group, visit;
                    uint16_t animation, flags; };                                                   // 16 bytes
struct VcmiMove   { uint32_t sequence, object; uint16_t fromX, fromY, toX, toY; uint8_t fromZ, toZ, type, pad;
                    uint32_t durationMs; };                                                         // 24 bytes, one in the object state
```

- Tiles: 127 008 x 8 bytes = 1 MB, once per map.
- Fog: up to 127 KB (1 byte per tile, as the game stores it), three buffers: 381 KB.
- Objects: 64 743 x 16 bytes = 1 MB on the heaviest map (the bridge's table, its published copy and Godot's copy), plus a log of 4 096 changes. Frames advance in the shader from time, so the record has no frame; `visit` is the offset of the visitable tile.
- Animation names: a string table published with the object list (`animation` is its index; 1 875 names on the heaviest map).
- Battle: under 4 KB.

### Animation timing

The 2D animations must not slow the game down while the tabletop is shown, and the 3D animations need the game's timing:

- **A 3D-mode window over the adventure map:** while Godot reports that the tabletop is shown, the bridge keeps its own empty full-screen window above the adventure map. The adventure map is then not the top window and is inactive: it is not drawn in normal frames, its widgets cannot redraw (`CIntObject.cpp:241`), its tick stops, and it skips its own hero and fade animations (`MapViewController.cpp:321,352`). The network thread no longer waits for 2D animations, and no setting has to be changed. Dialogs (town, hero, questions, battles) open above it and draw as usual.
  - **Push:** in the 100 ms lifecycle task, only when the adventure map is the top window, `GAME->map().hasOngoingAnimations()` is false and no replay runs. Pushing during a 2D step would freeze that step and the network thread with it (`MapViewController.cpp:627-631`).
  - **Put back:** the game closes every window above the adventure map at each turn start and end (`closeAllDialogs`, `CPlayerInterface.cpp:194-221`, called at `:231,280`), our window included. The same task pushes it again with the same guard, so at most one 2D step of an enemy turn plays before it is back.
  - **Pop:** only when it is the top window (`popWindow` throws otherwise, `WindowHandler.cpp:24-25`); with a dialog above it, the task waits until the dialog closes.
  - **Hotkeys:** the window looks keys up in `adventureInt->getAdventureShortcuts().getShortcuts()` and calls the enabled callback, as `AdventureOptions.cpp:47` does; `AdventureMapInterface::keyPressed` only scrolls.
- **3D durations:** `VcmiMove.durationMs` comes from the move-time settings (`adventure.heroMoveTime`, `enemyMoveTime`), which stay as the player set them.
- **Waiting for the 3D step:** the bridge's observer implements `hasOngoingAnimations` / `waitForOngoingAnimations`, which the game calls after each hero step on the network thread with `interfaceMutex` held (`HeroMovementController.cpp:194-195`). `hasOngoingAnimations` is true only from `onHeroMoved` until Godot confirms or the timeout passes (it also locks input and forces frames: `CPlayerInterface.cpp:2079`, `GameInstance.cpp:139-140`; `AdventureMapInterface.cpp:679` asserts it false). The wait releases `interfaceMutex` (`vstd::makeUnlockGuard`, as `MapViewController.cpp:627-631` does) and waits on a condition variable with a timeout of the step duration + 200 ms, so a stalled Godot frame cannot stall the game. With the adventure map not on top the 2D controller is not busy, so the two waits never overlap.
- **Battles (phase 5):** extra receivers run after the 2D battle interface has waited for its animations (`NetPacksClient.cpp:75-85`, `BattleInterface.cpp:884-900`), so the 3D battle trails a shortened 2D one. The bridge sets `battle.speedFactor` to 18 (the fastest UI value; default 2) while the 3D battle is shown, through the game's settings API, a C++ global read live (`settings.json` is not re-read while the game runs; `settings.write`, as `client/replay/ReplayAbortOverlay.cpp:58-60,83-102` saves and restores it; written to disk, `lib/CConfigHandler.cpp:179-182`), with the original kept in Godot's `user://` and restored on the next start after a crash. No switch while the replay overlay is open. Its receiver blocks with the same unlock guard and Godot confirmation. Receivers are registered per `CClient` (a new one per game) by the lifecycle task.

### Sprites and textures

Superseded by the milestone 3b research, [`MILESTONE_3B.md`](MILESTONE_3B.md) (indexed pages decoded with `CDefFile`, no `SDL_Surface`). The original plan, kept for history:

- Godot asks for an animation by its table index. The bridge loads it through the game's cache (`ENGINE->renderHandler().loadAnimation`, `client/render/IRenderHandler.h:37-48`) at scale 1 (an xBRZ image can be an unfinished stand-in) and draws each frame into its own RGBA `SDL_Surface` on the game GUI thread.
- Player colour mask: draw a frame twice with two `playerColored` colours; the pixels that differ are the mask. Godot applies the owner colour in a shader, so one texture serves all eight colours.
- Godot packs the frames of many animations into a few large atlas pages (up to 1 852 animations on one map, milestone 0) and builds mipmaps; the bridge frees its surface once Godot has it. The decoded image also stays in the game's cache: that copy is counted in the memory budget.

### Rendering in Godot

- Terrain: one texture per map level built from the tiles, mipmapped. Fog: a second texture, 1 byte per tile, sampled in the same shader, re-uploaded when the fog buffer is fresh (127 KB).
- Objects: one `MultiMeshInstance3D` per atlas page (transform, frame rectangle and owner in custom data): a few draw calls for tens of thousands of objects. One per animation would be up to 1 852 draw calls. Animated frames advance in the shader from time, not by rewriting instance data each frame.
- GDScript sees ready Godot objects, never raw records.

## 4. Performance and memory

### Budgets on Quest 3 (verified in milestone 0 and each milestone after)

| Item | Budget |
|---|---|
| Godot frame at 72 Hz | 13.9 ms, of which ~7 ms is left for the 3D view ([`PROJECT_PLAN.md`](PROJECT_PLAN.md#budget-left-for-the-3d-view)); bridge consumer < 0.5 ms when fresh, < 0.05 ms otherwise |
| Game side per publish | < 0.3 ms (copy of objects + fog compare) |
| Lifecycle task | < 0.05 ms per 100 ms when nothing changed |
| Map load snapshot | < 30 ms once |
| Bridge memory | < 5 MB of buffers (64 622 objects: 3.1 MB triple-buffered, fog 0.4 MB, tile snapshot 1 MB) |
| Sprite atlases | < 256 MB of textures: the game itself already reaches 3.5 GB on the heaviest map (milestone 0) |

### Optimisations

The design above already reads only under the lock the game holds, keeps Godot lock-free, decodes natively (no per-object JNI calls, Dictionaries or GDScript loops), copies full state instead of deltas and batches by atlas page. One more:

- **No 2D map drawing while the tabletop is shown:** the 3D-mode window is the top window, so normal frames draw only that empty window, not the adventure map. What remains is the game loop at 60 Hz: logic, an upload of the unchanged screen texture and a present, because `wantsFrameRendered` asks for a frame whenever the adventure map is not on top. Zero frames needs a small generic upstream hook (a window that reports it has nothing to draw, so `wantsFrameRendered` can skip); proposed only if milestone 2 shows those frames cost something measurable. Milestone 0 shows why the 2D map must not draw: it is the most expensive thing on the headset (below).

### Memory

- xBRZ: on the heaviest map, auto (xbrz2) grew to 6.75 GB PSS and the low-memory killer ended the game; `none` peaked at 3.5 GB. The Quest build defaults to `none` (`VcmiBridge.defaultUpscalingNone`, done 2026-11-07); a player can still pick xBRZ.
- Sprite atlases: one per animation for all colours; requested on first use. Freeing unused atlases comes only if milestone 3 shows the texture budget is exceeded.
- The 2D view's caches stay as they are (releasing them needs an upstream change).
- ETC2 / ASTC compression of atlases only if the texture budget is exceeded.

### Milestone 0 results (2026-11-06)

Measured with `quest/tools/xr-perf.sh` on the heaviest map, [HotA] Might and Magic (252 x 252 x 2, 64 622 objects, 8 players), with the map revealed by the `vcmieagles` cheat and the 2D map zoomed out until the whole map is on screen, so every object is drawn and animates. Rows from `quest.sh sample` (about one per 1.7 s); CPU in % of one core; memory in decimal GB; data in `quest/out/perf-20261106-194305-auto` and `perf-20261106-202443-none`.

| Step | xBRZ | Game thread CPU | Godot CPU | Process CPU | Godot FPS / app GPU ms | PSS max | Graphics max |
|---|---|---|---|---|---|---|---|
| Lobby | auto / none | 4 / 4 | 11 / 11 | 20 / 20 | 72 / 8.0 | 1.28 / 1.04 GB | 0.42 / 0.35 GB |
| Map start (normal zoom) | auto / none | 16 / 21 | 11 / 11 | 31 / 36 | 71-72 / 8.4 | 2.12 / 1.76 GB | 0.54 / 0.41 GB |
| Revealed, normal zoom | auto / none | 24 / 32 | 11 / 11 | 42 / 49 | 71-72 / 8.9 | 2.30 / 1.84 GB | 0.64 / 0.45 GB |
| Scrolling, normal zoom | auto / none | 27 / 31 | 11 / 11 | 45 / 47 | 72 / 8.8 | 4.19 / 1.84 GB | 1.80 / 0.45 GB |
| Whole map on screen | auto / none | 96 / 92 | 11 / 11 | 120 / 107 | 72 / 9.0 | 4.63 / 2.46 GB | 2.09 / 0.81 GB |
| AI turn, whole map on screen | auto / none | 95 / 95 | 12 / 11 | 116 / 112 | 72 / 9.2 | 6.75 (killed) / 3.50 GB | 3.04 / 1.31 GB |

- **Order:** in the auto run, scrolling came after a first zoom-out, so its memory includes what that drew.
- **Map load:** 5.8 s (auto) and 5.9 s (none) from Begin to the first turn.
- **AI turn** (7 AI players, every move on screen): 921 s with auto, then the low-memory killer ended the game at the new day; 692 s with `none`, game survived. Not measured yet: the same turn at normal zoom without the cheat, the case a player sees.
- **Godot is not the problem:** 71-73 FPS and 8-9 ms app GPU time of the 13.9 ms frame in every step, at about 11 % of one core. These GPU times are with the earlier war room; the rebuilt one takes 6.9 ms ([`XR_PERFORMANCE.md`](XR_PERFORMANCE.md)).
- **The 2D map is:** the game thread draws in software and saturates one core when many objects are on screen (88-97 %); the AI turn is then paced by it. The tabletop's 3D-mode window, which stops the 2D map from drawing, is the main optimisation, not an extra.
- **Memory grows with what the 2D map has drawn:** sprites stay in the game's caches, upscaled ones (xBRZ) in graphics memory. With `none` the heaviest case stays under half of the 8 GB.

### Milestone 1 results (2026-11-07)

`quest/tools/xr-lifecycle.sh` on the headset (first scenario, 72 x 72 x 2), data in `quest/out/lifecycle-20261107-082943`:

| Step | Observers | In game |
|---|---|---|
| New game | 1 | yes |
| Quick save, quick load | 2 | yes |
| Restart | 3 | yes |
| End turn, own turn again | 3 | yes |
| Replay of the enemy turn running | 4 | yes |
| Replay finished, live game restored | 4 | yes |
| Quit to the main menu | 4 | no |

- The extension finds the table with `dlopen(RTLD_NOLOAD)` about 1 s after the host starts and logs `VCMI bridge: connected, version 1`.
- One observer per new map, none for the restored live game after a replay; ticks arrive at the planned 10 per second through the steps. The script checks the observer and in-game columns and fails on any difference.

### Milestone 2 results (2026-11-07)

`quest/tools/xr-minimap.sh` on the headset: the first scenario (72 x 72 x 2) and, with `MAP_ROW=1`, the heaviest map, [HotA] Might and Magic (252 x 252 x 2, xBRZ `none`); data in `quest/out/minimap-20261107-102514` and `minimap-20261107-102314`. The minimap lies on the war table, 0.8 x 0.4 m for two levels, unshaded; the fog patch on it matches the game's own minimap.

| Item | 72 x 72 x 2 | 252 x 252 x 2 | Budget |
|---|---|---|---|
| Game: tile snapshot + first fog (once per map) | 0.27 ms | 2.0 ms | < 30 ms |
| Game: fog publish (compare + copy, when changed) | 3-4 µs | 12-21 µs | < 0.3 ms |
| Godot: tiles to image + mipmaps + first fog (once per map) | 0.28 ms | 0.9-2.1 ms | one frame |
| Godot: fog update (copy + image) | 42-49 µs | 139-191 µs | < 0.5 ms |
| Godot app GPU, looking at the table | | 9.1-9.4 ms (8.8 ms in the main menu, panel hidden) | ~7 ms left |
| Bridge memory | | tiles 1 MB, fog 127 KB, Godot copies about the same | < 5 MB |

- The panel costs about 0.4 ms of GPU time in the table view. Godot stays at 72 FPS.
- The fog is published only from the 100 ms tick, so the minimap trails the game by up to 100 ms.
- First version: the fog image was reordered and mipmapped in the extension, 0.27-0.53 ms per update on the heaviest map, over budget; the shader's axis swap removed that.
- Godot 4.7.2: a `Shader` whose code is set after it went into the `ShaderMaterial` draws flat grey; `room.gd` sets the code first.

### Milestone 3a results (2026-11-07): the object list

First version: a full scan of all objects on every map event and once a second (owner changes looked event-less), with a memcmp against the last list: 16 ms on the first scenario, because `visitablePos()` formats a debug log message for every scenery object; 6.3 ms on the heaviest map once that was avoided. Replaced by the record-per-id list with a change log (section 3).

`quest/tools/object-bench.sh` runs `ObjectScan` on the headset without the game (a benchmark library started by `app_process`, about a minute per change); the heaviest map's autosave (64 743 object slots, 64 430 drawn, 130 heroes, 17 522 visitable, 1 557 minimap markers, 1 875 animations):

| Item | Measured | Budget |
|---|---|---|
| Full list, once per map | 6.2 ms best, 6.7 ms mean | < 30 ms |
| Tick: all heroes encoded again | 5.5 µs | < 50 µs |
| Map event: one object encoded | 0.1 µs | < 0.3 ms |
| Copy of the whole list (published for a new map) | 52-110 µs | |

In the game (`xr-minimap.sh`, `MAP_ROW=1`): the full list 4.7 ms once (53 808 objects at the map start), a change publish 2-3 µs, Godot's update 0.14-0.15 ms per frame with fresh data (mostly the fog). An enemy turn on the first scenario published 32 changes; `xr-lifecycle.sh` takes one full list per new game, load, restart and replay pass. The markers (heroes, towns and flaggable objects in the player's colour, hidden in the fog by the shader) are the visible check until the sprites of milestone 3b.

### How to measure

- `quest.sh sample` and `xr-perf.sh` ([`PHASE2.md`](PHASE2.md#working-on-the-headset)). A Perfetto trace (`adb shell perfetto`) only when a number needs explaining.
- Bridge timers: the test command `bridge` prints the stats, with the game-side times of the last tile/fog publish (`publish_us`), full object list (`objects_us`) and object change publish (`change_us`), and Godot's last update (`consume_us`).
- `quest/tools/object-bench.sh` for the object list on the headset without the game: real timings in about a minute per change.
- Each milestone records its numbers in this file. A milestone over budget is optimised before the next one starts.

## 5. Milestones

0. **Baseline** (no code), **done 2026-11-06:** frame time, CPU and PSS on the heaviest map with xBRZ auto and `none`; object counts (section 4, Milestone 0 results).
1. **Skeleton, done 2026-11-07:** `quest/bridge` with the table and version; the extension finds it after the game starts and logs the version; the lifecycle task survives new game, load, restart, replay and quit to menu; test command `bridge` in `main.gd`.
2. **Minimap, done 2026-11-07:** tile snapshot and fog buffer into Godot textures on the war table; fog follows hero moves and the map reveal (section 4, Milestone 2 results). View Air / View Earth do not change the fog (`ViewWorldEffect.cpp` only reads it), so they are not a test for it.
3. **Objects, in progress:** 3a, the object list and string table with markers on the minimap, done 2026-11-07 (section 4, Milestone 3a results); 3b, the sprites, done 2026-11-09 ([`MILESTONE_3B.md`](MILESTONE_3B.md), with the work left for phase 4 in its section 1f); 3c, the 3D-mode window and hero step timing through `waitForOngoingAnimations`.
4. **Battle:** receiver, battle buffer and the blocking-confirmation timing.

Phase 4 proper builds on 2 and 3; phase 5 on 4.

## 6. Risks

| Risk | Check | Fallback |
|---|---|---|
| `dlopen(RTLD_NOLOAD)` / `dlsym` does not find the table | passed in milestone 1 | the game's `JNI_OnLoad` stores the table address; `VcmiBridge` hands it to Godot as an integer |
| GDExtension classes unknown to the headless editor export (no desktop build) | passed in milestone 1 | `main.gd` uses `ClassDB.instantiate("VcmiData")` and untyped calls |
| godot-cpp with NDK r29 and the shared libc++ | passed in milestone 1 | `make-extension.sh` builds it with the NDK of the game's conan toolchain |
| Drawing frames into a surface is slow for big animations | milestone 3 timers | request frames lazily, one group at a time |
| The wait in `waitForOngoingAnimations` deadlocks with Godot paused (Meta menu) | milestone 3 | the timeout; skip the wait while the host is paused (the bridge already knows, `onMainPause`) |
| A crash leaves the battle speed at 18 | milestone 4 | original in `user://`, restored on the next bridge start |
| The 3D-mode window is pushed at a bad moment (mid-step, during a replay) | milestone 3 | the push guard; a test command that pushes and pops it during an enemy turn |
| A hero or town selected in Godot does not reach the game | milestone 3 | call the adventure map's own selection functions on the GUI thread through `dispatchMainThread` |
| `CMap::addLevel` grows the map during play | milestone 2 | the lifecycle task re-publishes tiles when the map size changes |
| Upstream renames client classes the bridge uses | each rebase | the bridge is one quest file; the compiler shows what changed |

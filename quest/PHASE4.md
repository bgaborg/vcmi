# Phase 4: the tabletop adventure map (plan)

Status: 2026-11-09, required checks done except check 3, which waits for a person in the headset (section 3a); milestones 4a, 4b and 4c built and played on the Quest with a simulated ray (sections 4a, 4b and 4c results; a battle, spells and the real buttons not yet checked). Next: milestone 4d.

Goal (from [`PROJECT_PLAN.md`](PROJECT_PLAN.md#phase-4---tabletop-adventure-map-after-data-bridge-milestones-2-and-3)): the adventure map is fully playable on the war table, and one button goes back to the 2D screen.

## 1. What exists

- **Data bridge, milestones 0-3** ([`DATA_BRIDGE.md`](DATA_BRIDGE.md)):
  - tiles with terrain, river and road ids and their views (`VcmiTile`), and the fog;
  - every object with its animation, group and owner, then only the changed records;
  - the sprite frames of any animation, decoded on a worker.
- **On the table** ([`MILESTONE_3B.md`](MILESTONE_3B.md)):
  - the minimap's colours with markers, or the object sprites once a tile is 12 px or more on screen;
  - a sprite atlas that follows the view;
  - a simple zoom (test command `table_zoom`), with no controls yet.
- **Tabletop mode** (milestone 3c): `setTabletop(1)` keeps an empty window over the adventure map. While it is on:
  - the 2D map stops drawing and animating;
  - hotkeys still work;
  - the game waits for each hero step on the table, and Godot slides the hero's sprite.
- **War room** (phase 3): the curved game screen, the controllers' ray and trigger clicks on it, wrist hotkeys, haptics, recenter, environments.

What is missing for play: clicking on the table, the hero's path, the terrain look, controls to move and zoom the map, the information the 2D side panel shows (resources, hero and town lists), and a way into and out of tabletop mode.

## 2. Design decisions (checked against the code)

1. **Table clicks go to the game's own tile handlers, through the bridge.**
   - `AdventureMapInterface::onTileHovered`, `onTileLeftClicked` and `onTileRightClicked` (`client/adventureMap/AdventureMapInterface.h:211-217`) check only the adventure state (`optionMapViewActive`, `AdventureMapShortcuts.cpp:765`), not whether the map is the active window. So they work with the tabletop window on top.
   - The bridge gets a `tileInput(x, y, z, kind)`. It keeps its own queue: the latest hover, and the clicks in order. The lifecycle tick drains it on the game thread, with `interfaceMutex` held.
     - Not through `dispatchMainThread`: that pushes an event before its task, and the game can drop the event (`ignoreEventsUntilInput`, `clientsdl3/events/InputHandler.cpp:285-304,522-536`), so a click would run one event late.
     - A click made while a hero walks waits until the walk ends, as in 2D (`capturedAllEvents`, `CPlayerInterface.cpp:2073`).
   - The tick drops the input when any window is above the tabletop window, checked when the input runs. The handlers do not check that themselves: with a dialog open the state stays `MAKING_TURN`, so a second table click would walk the hero away behind an open town window (`AdventureMapInterface.cpp:634-645`, `CPlayerInterface.cpp:1289`).
   - The tick also rejects tiles outside the map, as `MapViewActions.cpp:79` does (`getPathInfo` would read out of range), and inputs before the player has a current army (`AdventureMapInterface.cpp:631`).
   - The game then does everything the 2D map does: the first click sets the path, the second walks it, and objects are visited, attacked, or open their dialog.
   - Right click shows the info popup. Popups close only on a real right-button release (`EventDispatcher.cpp:347-354`), so the bridge pops the top popup when the grip is released. The popup is placed at the 2D cursor (`AdventureMapInterface.cpp:964`), which stays on the screen in phase 4.
   - The hover text the 2D map puts in its status bar (object name, movement cost) goes to a fake status bar while the map is covered (`GameEngine.cpp:302-308`). The table shows its own from the hovered tile in 4d.
   - No upstream change.
2. **The hero's path is drawn by Godot from the game's path.**
   - `PlayerLocalState::getPath(hero)` (`client/PlayerLocalState.h:78`) holds the nodes with `coord` and `turns` (`lib/pathfinder/CGPathNode.h:59-73`).
   - The bridge reads it each tick (there is no event when it changes, and it shrinks with each step, `HeroMovementController.cpp:149`), calling `hasPath` first (`getPath` asserts without one, `PlayerLocalState.cpp:43-47`). It publishes the path when it differs, and the table draws it as discs coloured by turn.
3. **The cursor at the ray's hit on the table is the game's own cursor image.**
   - After a hover, `CursorHandler::getCurrentImage()` (`client/gui/CursorHandler.h:170`) is the move, attack or visit cursor the 2D map would show (`CursorHandler.cpp:77-119`).
   - The cursor is shared with the screen: a window push resets it (`WindowHandler.cpp:48`) and the ray on the screen moves it. So the bridge reads it in the same tick, right after the hover.
   - The bridge hands it to Godot as pixels when it changes. Godot draws it, which matches the rebase rule "Godot draws the pointer".
4. **Dialogs stay on the game screen for phase 4.**
   - With the tabletop window on top, every dialog, battle and town screen still draws on the game screen (milestone 3c).
   - The bridge publishes whether any window is above the tabletop window. Godot shows the screen in front of the table while one is, and lowers or hides it otherwise, because then it only holds the stale map.
   - Panels per window type ([`PROJECT_PLAN.md` section 5](PROJECT_PLAN.md#5-in-game-popups-and-windows)) need a `WindowHandler` hook in VCMI, an upstream change. They wait until the table works (decision D2).
5. **The side panel's information comes from the bridge; its actions go through shortcuts and the tile handlers.**
   - Shown on the table edge: resources and the date; the hero and town lists with movement and mana.
   - Selecting a hero or town calls `PlayerLocalState::setSelection` on the game thread (the `DATA_BRIDGE.md` section 6 risk row).
   - End turn, next hero, sleep and spells already work as shortcuts, from the wrist panel and through the tabletop window.
6. **Terrain, rivers and roads are drawn like the sprites: instances of atlas frames for the tiles in view.**
   - A map level drawn whole would be 8 064² pixels (252 tiles × 32), 260 MB, so it is not baked into one texture.
   - The tile's `terrainView`, `riverDir` and `roadDir` (`VcmiTile`) give the frame, as `MapRendererTerrain`, `MapRendererRiver` and `MapRendererRoad` (`client/mapView/MapRenderer.cpp`) use them.
   - The mirroring is in `extTileFlags` (`MapRenderer.cpp:182,224,261,273`), which the bridge does not publish yet. It goes into `VcmiTile`'s free `pad` byte, a bridge version change.
   - Roads are drawn half a tile down, from the tile above (`MapRenderer.cpp:256-276`).
   - Zoomed out, the minimap colours stay, as the sprites do today.
7. **Objects first stay flat, then become standing paper cards** (milestone 4e).
   - Cards need per-object metadata (height, anchor, fold) from JSON, so mods can tune them.
   - That is look work, so it comes after the table plays.

No upstream VCMI change is planned for phase 4.

## 3. Required checks before milestone 4a

Each check can change the design; record the results here.

1. **Tile input with the tabletop on:** a test command sends hover, left and right clicks on chosen tiles. Expected:
   - the hero walks after two clicks;
   - a visit opens its dialog on the screen;
   - right click shows the popup;
   - nothing happens during an enemy turn.
2. **Cursor image:** after a hover, `getCurrentImage()` is the 2D map's cursor (move, attack, visit, no-go). If it is not reachable without a game change, Godot picks the cursor from the hovered tile itself (the path end and the object there).
3. **Picking precision:** the ray's jitter at the table distance, against the tile size at the zoom levels.
   - How small a tile can be before clicks miss: a test command picks a tile under a still controller for 5 s and logs how often it changes.
   - That sets the zoom at which tile clicks are allowed (below it, a click zooms in first).
4. **Screen policy:** the windows above the tabletop window are found in the stack (`findWindows` keeps its order; battles, the town and hero windows and popups push on top: `BattleInterface.cpp:103`, `CPlayerInterface.cpp:451`). The check: hiding the screen layer in Godot keeps the game rendering normally when a dialog opens. Leaving tabletop mode with a dialog open waits until it closes (the window is popped only when on top).
5. **World view and spell casting:** what a table click does in world view and while an adventure spell is being cast (both pass `optionMapViewActive`).
6. **Terrain frames:** whether the sprite decoder reads the terrain, river and road `.def` files as it reads the objects' (needed for 4c).

## 3a. Results of the required checks (2026-11-09)

What the checks built, kept for milestone 4a:
- **Bridge, version 7:**
  - `tileInput(x, y, z, kind)` with `VCMI_TILE_HOVER`, `CLICK`, `POPUP` and `POPUP_END`. Godot calls it as `VcmiData.tile_input`; the test command is `tile x y kind`.
  - A queue the lifecycle tick drains: the latest hover, then the other inputs in order.
  - Inputs are dropped with no tabletop window, a window above it, no current army, or a tile off the map.
  - New stats: `windows_above`, `inputs_run`, `inputs_dropped`.
- **Extension:**
  - `VcmiData.heroes()`: id, tile and owner of each hero (test command `heroes`).
  - `room.table_uv` and `main.gd` `_table_tile`: the tile under a ray on the table, through the zoom.
- **Test commands:** `table_pick` (check 3), `screen_hide`, and `decode:<animation>`.
- **Local test:** `quest/tools/test-local.sh` runs `quest/xr/tests/table_uv_test.gd` headless on the PC in about 6 s: rays onto known points of the minimap at zoom 1 and zoomed land on the expected map UV. Host logic that needs no game is tested this way, the game's behaviour on the Quest.

Results on the Quest, first scenario, tabletop on (`quest/out/phase4-checks/`):

1. **Tile input works through the game's own handlers.**
   - A hover set the cursor. The first click set the path, the second walked the hero 3 tiles, with the steps waited for as in milestone 3c.
   - A right click showed the tile's popup ("Rock") on the screen (`1-popup.jpg`), and `POPUP_END` closed it. Object popups (a hero, town or monster) are other window classes: `POPUP_END` closes any popup on top, as the game's own right-button release does (`EventDispatcher::dispatchClosePopup`); the hero's popup opened and closed this way, and table clicks worked again after it (`7-hero-popup.jpg`).
   - Popups open at the 2D cursor (`AdventureMapInterface.cpp:964`, `InfoWindows.cpp:219`), which table input does not move; 4a places the screen so that this does not matter, or moves the cursor to the tile first.
   - A click on the hero opened the hero window above the tabletop (`windows_above` 1). Two map clicks under it were dropped, and the hero did not move.
   - Clicks run up to 100 ms late (the tick period); 4a measures click-to-move against the budget.
2. **The cursor image follows the hover.** After each hover `getCurrentImage()` was a 40x40 image, a different one for an empty tile (move), the hero, and a blocked or far tile. So Godot can draw the game's own cursor at the ray's hit.
3. **Picking precision: not done.** The controllers are not tracked while they lie still: a person has to hold one pointed at the table. At zoom 1 a tile of the first scenario is 0.56 cm on the table.
4. **Screen policy works.**
   - With the game screen layer hidden (`5-screen-hidden.jpg`), a click opened the hero window. It was drawn completely when the layer came back (`6-screen-shown-dialog.jpg`): the game keeps rendering while the screen is hidden.
   - `windows_above` counts the window and drops to 0 when it closes.
   - Under dialogs the screen shows a stale map, or a starry background after a total redraw; a dialog's own dimming hides most of it.
5. **World view has no use on the table.** The 2D map that draws it is covered, so V showed nothing. An Escape afterwards opened the settings window instead of leaving world view. 4a drops the world view shortcuts in the tabletop window, and the table's own zoom replaces world view. Spell casting was not tried (no hero with an adventure spell); 4a tests it with a scenario that has one.
6. **Terrain, rivers and roads decode** through the bridge like the objects.

| Animation | Frames | Source | Bridge time |
|---|---|---|---|
| `DIRTTL` | 46 | HD mod PNG | 9.5 ms |
| `GRASTL` | 79 | HD mod PNG | 9.2 ms |
| `SUBBTL` | 79 | HD mod PNG | 10.8 ms |
| `WATRTL` | 80 | .def | 3.6 ms |
| `ROCKTL` | 48 | .def | 2.9 ms |
| `clrrvr` | 13 | .def | 2.2 ms |
| `lavrvr` | 13 | .def | 2.3 ms |
| `dirtrd` | 17 | HD mod PNG | 4.1 ms |
| `cobbrd` | 17 | .def | 2.3 ms |

   All frames are in group 0, decoded on the atlas workers in 4c. Water and lava move in 2D by rotating palette colours (`adventure.terrainAnimation`), which baked RGBA frames lose; 4c animates them (a few baked rotations, or the palette in the shader).

## 3b. Decisions taken (2026-11-09)

- **D1:** a button switches tabletop mode: "Table / screen" on the wrist panel, and the right thumbstick click. That click toggled the 2D map's grid, which the table does not show.
- **D2:** dialogs stay on the game screen, which shows only while one is open.
- **D3:** in tabletop mode a tile is 1.5 cm on the table, at least the zoom that shows one map level. `shortcut:` 1.5 cm is a safe guess until check 3 measures the ray's jitter, with a person holding a controller; the value is `TABLE_TILE_METRES` in `main.gd`.
- **The cursor image:** the game exports it only as a file (`IImage::exportBitmap`). So the table shows the ray's dot, the path and the selected hero's mark instead; the hover text and the cursor come with the side panel (4d).

## 4. Milestones, in order

Each one is tested on the Quest, reviewed, and recorded here with its numbers before the next starts.

### 4a. Play on the table (the first playable version)

- **Into and out of tabletop mode:** a wrist panel button and a controller shortcut (decision D1); the button back to the 2D screen is the phase exit.
- **Tile input:** the bridge's `tileInput`; the ray hit on the table maps to a tile through the zoom.
  - Hover: as the pointer moves over tiles.
  - Trigger: left click. Grip: right click while held, as in the plan's popup table.
- **On the table:** the hero's path as discs, the cursor image at the hit, the selected hero marked.
- **The screen policy** (decision 4): the screen comes forward when a dialog opens.
- **Exit:** on the first scenario, heroes move, visit, pick up and fight from the table, and the turn ends from the wrist; no 2D map click is needed.

#### 4a results (2026-11-09)

- **Bridge, version 8:**
  - `publishSelection` in the tick puts the selected hero or town (`stats.selected`) and the selected hero's path (`path`, `pathGeneration`) in the stats. The path runs from the first step to the end, with its turns.
  - The tabletop window drops the world view shortcuts (check 5).
- **Extension:** `update()` raises `PATH_CHANGED`; `path_nodes()`, `selected_tile()` (the visitable tile) and `windows_above()`.
- **Godot:**
  - `table_math.gd`: tile, map UV, zoom, following and level maths, tested on the PC (`tests/table_math_test.gd`).
  - `room.gd`: `table_hit`; `set_path` draws the path as discs (green this turn, orange later, the end larger) and a white disc under the selected hero, with the markers' material (fog, clipped at the panel's edge).
  - `main.gd`:
    - `_set_tabletop` switches the mode and zooms in.
    - `_update_table`: the path, following the selected hero once it leaves the middle 60 % of the table, and the screen shown only while `windows_above` > 0.
    - `_table_pointer`: the ray hovers tiles.
    - `_table_press`: trigger clicks, grip shows the popup while held.
    - The screen's ray ignores the hidden screen.
- **Local tests:** `test-local.sh` now runs three tests in about 7 s: the table maths, the picking maths, and whether the host scripts compile. The compile test caught a parse error that would otherwise have cost an APK build.
- **On the Quest**, first scenario, with a simulated ray aimed from above the table (`quest/out/phase4a/`):
  - Tabletop mode zoomed to 1.5 cm tiles around the hero, stopped at the map's edge (`1-table-on.jpg`).
  - The first click drew the path (`2-path.jpg`), and the second walked the hero 5 steps (each waited for about 160 ms, no timeouts). The fog opened and the white mark moved with the hero (`3-walked.jpg`).
  - The hero reached a chest: its dialog came forward on the game screen (`4-dialog-on-screen.jpg`). After A the screen hid again, and play went back to the table (`5-screen-hidden-again.jpg`).
  - `tabletop 0` brought the 2D screen back.
  - Ending the turn and going back to the main menu from tabletop mode both worked.
- **Fixed after the review:**
  - The screen also shows while the tabletop window is missing: at a turn's start the game shows its dialogs (new week, the next player) before the tick puts the window back, and replays run without it.
  - Leaving tabletop mode ends a table popup still held.
  - At the game's end the bridge clears the dialog count and the path, and outside a game the screen always shows.
  - Switching on before the map is known zooms in once it is.
- **Not checked yet:**
  - A battle started from the table. The battle window is above the tabletop window like any dialog, so the screen shows it.
  - Spell casting.
  - Switching with the real wrist button and stick click (only the test command was used).
  - A real controller ray, which needs a person.
  - The room's war-table flag prop stands over the map and hides a few tiles; 4c (the look) moves it.

### 4b. Moving around the map

- **Controls:** grab with one hand drags the map; grab with both hands zooms; the table height is set seated or standing.
- **The view follows the game:** the selected hero, and enemy heroes the tabletop shows during their turn, as `centerOnTile` does in 2D.
- **The sprite work left from 3b** ([`MILESTONE_3B.md`](MILESTONE_3B.md) section 1f), because panning becomes continuous:
  - the view rebuild off the main thread;
  - LRU eviction of atlas shelves instead of a refill on every pan;
  - writing only the instances that moved.
- **Exit:** panning and zooming the heaviest map holds 72 fps with no markers flashing, measured with `quest.sh sample`.

#### 4b results (2026-11-09)

- **Decisions:**
  - **Grips:**
    - One grip moved more than 1.5 cm drags the map.
    - Two grips zoom about their midpoint, from one map level up to 6 cm tiles.
    - A grip held still for 350 ms shows the tile's popup until it is released.
    - A hand that was the pivot of a zoom opens no popup.
  - **Table height:** it stays fixed at 0.8 m. `shortcut:` seated or standing comes with a person in the headset (check 3).
  - **The view rebuild stays on the main thread:** an index of the objects by 8x8-tile buckets per level, and integer animation keys instead of name sets, brought it from 2.2-3.7 ms to 0.7-1.3 ms on the heaviest map while panning, and 2.3 ms once after a far jump. A worker is not needed.
  - **Writing only the instances that moved is skipped:** the whole buffer takes about 0.1 ms.
- **Atlas:**
  - **Size:** 48 pages of 512² (about 84 MB with masks and mipmaps), instead of 24. The budget in section 5 is now 84 MB.
  - **Eviction:** a page that the current view does not use goes first, the one unused longest.
  - **Refill on fragmentation:** when every page holds something the view needs, a frame that does not fit makes all pages start again with only the view, in about 0.8 s on a worker. Only a frame that does not fit in such a fresh atlas marks the view as overflowed, which shows markers at that zoom.
  - **Retries:** animations that failed for lack of room are tried again by the next view.
- **On the Quest**, heaviest map (252x252x2, 53,808 objects), tabletop zoom (`quest/out/phase4b/`):
  - 15 pans of 2 tiles each and 3 far jumps (`table_pan`, the maths of a hand drag), with a check after each that the view's sprites match a full rebuild: all the same.
  - No overflow, and no markers.
  - The pages filled after about 8 pans. From then on a refill came about every 4 pans east, and once in 24 pans diagonally. Eviction never ran, because on this map every page holds some of the view.
  - 72-73 fps throughout, with an app GPU time of 5.8-6.4 ms (`heavy-pan-refill.csv`).
- **Fixed after the review:**
  - Animations that overflowed are retried even when nothing else is missing. Before, zooming in kept markers.
  - A new object list clears the atlas keys, because the indices then name other animations.
  - The pivot of a two-hand zoom no longer opens a popup when the other hand lets go.
- **Not checked yet:** a real two-hand grab and zoom, which needs a person (only `table_pan` was used).

### 4c. Terrain, rivers and roads

- Terrain, river and road frames through the atlas as tile instances in view (decision 6); animated water as the 2D map's `terrainAnimation`; fog with a soft edge.
- **GPU:** measure with the sprites. The budget is the 7 ms left for the table. If over, the opaque-first pass ([`MILESTONE_3B.md`](MILESTONE_3B.md) section 1e).
- **Exit:** the table looks like the 2D map at the same zoom (a screenshot next to the 2D view), within budget on the heaviest map.

#### 4c results (2026-11-09)

- **Bridge, version 9:**
  - `VcmiTile.flips` (the free byte) carries the game's `extTileFlags`: 2 bits each for terrain, river and road. Bit 1 mirrors left-right, which is VCMI's `CAnimation::verticalFlip`; bit 2 flips top-bottom.
  - `tileAnimation(layer, id)` names how the 2D map draws a terrain, river or road: `<file>#<mode>[,<start>:<length>]...`. The mode is opaque (terrain) or colour key (rivers, roads), and each range is a palette range that rotates (`paletteAnimation`).
- **Atlas** (`decodeBaked`):
  - Tile animations are baked with that palette.
  - The rotating ones get one group per rotation step, as `AssetGenerator::generatePaletteShiftedAnimation` makes the 2D map's `_Shifted` animations. Water bakes 12 steps of 80 tiles; the clear river 12 of 13.
  - Frames that are opaque to their border get their edge pixels copied into the padding (`extrude`), so the smaller mipmaps show no seams between tiles.
  - **64 pages (about 112 MB) instead of 48.** The heaviest map's tabletop view overflowed 48 pages once its terrain came in, and the table fell back to markers. With 64 it used 51.
- **Sprites:**
  - Each instance has a layer that sorts first: terrain, rivers, roads, objects, then fog, as the 2D map draws a tile.
  - Roads are drawn half a tile down.
  - Tiles cycle their palette steps every 180 ms (`terrainImageIndex`).
  - The shader flips top-bottom (frame count + 2048). It samples tiles inside their frame (a half-texel inset) and at most from mip 2, where the atlas padding still separates frames.
- **Fog as in 2D** (`MapRendererFow`):
  - Hidden tiles get a fog sprite over the objects: a soft edge from `TSHRE`, picked by the visible neighbours as `NeighborTilesInfo` does (the last 17 edges mirrored), else a starry `TSHRC` tile picked by the tile's coordinates.
  - Objects are now drawn whatever the fog, as in 2D. Before, an object whose anchor tile was hidden vanished whole, even where it stood on seen tiles.
  - A fog change renews only the fog sprites, in `update_sprite_changes`: 0.45-0.8 ms per hero step on the first scenario.
  - Fog lies over every tile an object drawn in the view can reach (the anchors' band, 8 tiles right and below). A pan that waits for the atlas then shows no hidden object.
  - The fog's two animations are asked for first, so an overflowing view fails an object animation, never the fog.
- **On the Quest** (`quest/out/phase4c/`):
  - **First scenario:**
    - Grass, the clear river, the cobblestone roads and the fog's soft edge match the 2D view of the same place (`6-table-fog-extruded.jpg`, `3-2d-view.jpg`). The pine forest at the fog's edge now stands half covered, as in 2D.
    - After the hero walked 3 steps, the fog opened onto the coast and the sea (`11-after-walk.jpg`), and the sprites still matched a full rebuild.
    - 72-73 fps, with an app GPU time of 5.8-7.0 ms.
  - **Heaviest map, revealed:**
    - Tabletop zoom, 20 pans of 2 tiles and 3 far jumps: 72-73 fps, with an app GPU time of 5.7-6.7 ms. That is 0.3-0.5 ms more than without terrain, inside the 7 ms left for the table.
    - No overflow, and sprites matched a full rebuild (`9-heavy-64-pages.jpg`, `heavy-terrain-pan64.csv`).
  - **Local render** (`render-room.sh sprites`): with the headset's saved sprites, the shader change rendered on the PC before an APK build.
- **Not checked yet / left:**
  - The review's other findings are fixed: the tile names are read again for each map (mods), and a palette rotating in more than 64 steps is baked still.
  - The water's motion was not watched (screenshots are stills); the frame table holds the 12 steps per tile.
  - A rebuild of the view's sprites now takes up to 3.5 ms on the heaviest map, right after a far jump, and up to 3 ms on the first scenario, whose view is mostly fog. That is over the 1 ms budget for one frame, but held 72 fps. `shortcut:` main thread; a worker or keeping the tile sprites between views if it shows.
  - Below the sprite zoom (markers), the fog's tiles show faint seams; that zoom draws markers, not sprites.
  - The 2D map's special ground (clover fields, cursed ground) under the roads, and the map border outside the map, are not drawn.

### 4d. The side panel on the table

- Resources and the date at the table edge; the hero and town lists (movement, mana) with selection through the bridge; the end turn button as the hourglass.
- **Exit:** the 2D side panel is not needed for a whole turn.

### 4e. Paper cards and the remaining animations

- Objects as standing cards with JSON metadata, and the pop-up animation.
- Hero flags: the trace in milestone 3c showed an enemy flag not moving with its hero.
- The animations the tabletop does not time yet: boats' flags, teleports, embarking and fades.
- **Exit:** a look review by a person wearing the headset.

### 4f. Exit pass

- A whole scenario played on the table: the first one, then the heaviest map for the budgets.
- A comfort check by a person wearing the headset.
- Then the `PROJECT_PLAN.md` exit: fully playable on the table, one button back to 2D.

## 5. Budgets

| | Budget |
|---|---|
| GPU, whole frame at 72 Hz | 13.9 ms; the war room takes 6.9 ms, so about 7 ms for the table |
| Main thread, per frame | the bridge consumer 0.5 ms; no single frame over 1 ms of table work (rebuilds go to a worker in 4b) |
| A click to the hero starting to move | under 100 ms, as in 2D |
| Hero step | the game's own time (150 ms default), waited for as in milestone 3c |
| Memory | atlas pages 112 MB (64 pages, raised in 4b and 4c from the 64 MB of [`MILESTONE_3B.md`](MILESTONE_3B.md) section 1a), terrain in them |

## 6. Open decisions

- **D1, into and out of tabletop mode:** a button (wrist and a controller shortcut) or automatic when the player looks at the table. Recommended: a button, because looking at the table to read the minimap must not switch modes.
- **D2, dialogs:** on the game screen, which comes forward when one opens (no upstream change), or as panels per window type (needs a VCMI `WindowHandler` hook). Recommended: the screen for phase 4, and panels after it, once the hook is proposed upstream.
- **D3, table size:** the war table today shows the whole map on 0.5 m. Playing needs tiles of a few centimetres, so the default view is zoomed, with the whole map on demand. The zoom where clicks are allowed comes from check 3.

## 7. Risks

| Risk | Check | Fallback |
|---|---|---|
| Tile clicks from the bridge behave differently from 2D clicks (dialogs open, state, cursor) | check 1 | drop input while a window is above the tabletop; the same `onTileHovered` before each click, as the 2D map does |
| Ray jitter makes small tiles unclickable | check 3 | click only above a zoom; snap to the hovered tile while the trigger is held |
| The game screen in front of the table hides the map when a dialog opens | 4a | place it above the far edge of the table, tilted |
| GPU with terrain, sprites and the room | 4c | the opaque-first pass; fewer terrain layers at low zoom |
| Mods change the side panel or add objects without card metadata | 4d, 4e | default card metadata; the panel built from bridge data, not from the 2D widgets |

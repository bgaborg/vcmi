# Phase 4: the tabletop adventure map (plan)

Status: 2026-11-09, required checks 1, 2, 4, 5 and 6 done (section 3a); check 3 needs a person to hold a controller. Next: check 3, then milestone 4a (section 4).

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

### 4b. Moving around the map

- **Controls:** grab with one hand drags the map; grab with both hands zooms; the table height is set seated or standing.
- **The view follows the game:** the selected hero, and enemy heroes the tabletop shows during their turn, as `centerOnTile` does in 2D.
- **The sprite work left from 3b** ([`MILESTONE_3B.md`](MILESTONE_3B.md) section 1f), because panning becomes continuous:
  - the view rebuild off the main thread;
  - LRU eviction of atlas shelves instead of a refill on every pan;
  - writing only the instances that moved.
- **Exit:** panning and zooming the heaviest map holds 72 fps with no markers flashing, measured with `quest.sh sample`.

### 4c. Terrain, rivers and roads

- Terrain, river and road frames through the atlas as tile instances in view (decision 6); animated water as the 2D map's `terrainAnimation`; fog with a soft edge.
- **GPU:** measure with the sprites. The budget is the 7 ms left for the table. If over, the opaque-first pass ([`MILESTONE_3B.md`](MILESTONE_3B.md) section 1e).
- **Exit:** the table looks like the 2D map at the same zoom (a screenshot next to the 2D view), within budget on the heaviest map.

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
| Memory | atlas pages and terrain within the 64 MB of [`MILESTONE_3B.md`](MILESTONE_3B.md) section 1a |

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

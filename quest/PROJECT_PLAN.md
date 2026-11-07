# VCMI for Meta Quest 3 - project plan

Native Quest 3 app (Android arm64, OpenXR). No PC streaming.
Goal: the most immersive way to play Heroes 3 on Quest 3, with no motion sickness.

| Doc | What is in it |
|---|---|
| this file | status and next steps, architecture, rules, roadmap, open decisions |
| [`PHASE2.md`](PHASE2.md) | how the XR host works (phases 2-3) and **working on the headset**: build, adb, test commands and scripts |
| [`DATA_BRIDGE.md`](DATA_BRIDGE.md) | game data from VCMI to Godot: design, budgets, milestones and their measurements |
| [`XR_PERFORMANCE.md`](XR_PERFORMANCE.md) | GPU cost of the 3D scene: measurements, rules, what to try next |
| [`PHASE1.md`](PHASE1.md) | build settings, phase 1 test checklist, SoD_SP gap analysis |
| [`xr/assets/room/LICENSES.md`](xr/assets/room/LICENSES.md) | sources and licences of the war room assets |

## 0. Status and next steps

As of 2026-11-07.

### Done

| Part | Result | Details |
|---|---|---|
| Phase 0, concept | WebXR mockup; the layout and comfort model work on the headset | [`concept/`](concept/index.html) |
| Phase 1, foundation | the Quest APK builds (local and CI) and runs as a 2D panel app; open items below | [`PHASE1.md`](PHASE1.md) |
| Phase 2, own OpenXR spike | worked, superseded by Godot; Horizon OS launch findings kept | [`PHASE2.md`](PHASE2.md#horizon-os-findings) |
| Phase 2b, Godot host | the unchanged game on a curved screen, real controller models, 72 Hz (runtime default; 90 Hz possible, not budgeted) | [`PHASE2.md`](PHASE2.md#how-the-xr-host-works) |
| Phase 3, war room MVP | controls, wrist hotkeys, haptics, screen size and distance, recenter, pause, environments (war room, passthrough, black) | [`PHASE2.md`](PHASE2.md#how-the-xr-host-works) |
| War room rebuild | lit castle study, baked light, app GPU 12.1 -> 6.9 ms | [`XR_PERFORMANCE.md`](XR_PERFORMANCE.md) |
| Data bridge milestone 0 | baseline on the heaviest map | [`DATA_BRIDGE.md`](DATA_BRIDGE.md#milestone-0-results-2026-11-06) |
| Data bridge milestone 1 | skeleton: the Godot extension finds the game's table; lifecycle survives new game, load, restart, replay, quit | [`DATA_BRIDGE.md`](DATA_BRIDGE.md#milestone-1-results-2026-11-07) |
| Data bridge milestone 2 | the game's minimap on the war table: tile snapshot and fog, within budget on the heaviest map | [`DATA_BRIDGE.md`](DATA_BRIDGE.md#milestone-2-results-2026-11-07) |
| Data bridge milestone 3a | the object list: one full list per map (6 ms on the heaviest map), then the changed records (0.1 µs an object); markers on the minimap; `object-bench.sh` measures it on the headset without the game | [`DATA_BRIDGE.md`](DATA_BRIDGE.md#milestone-3a-results-2026-11-07-the-object-list) |
| xBRZ default `none` | `VcmiBridge` writes `video.upscalingFilter: none` before the game starts when the player has not chosen a filter; no upstream change | [`DATA_BRIDGE.md`](DATA_BRIDGE.md#memory) |

Not closed yet:
- Phase 1: mod preset tests, data import through the system file picker, a full game start to end ([`PHASE1.md`](PHASE1.md#follow-ups)).
- Phase 3 exit: a full campaign map in VR with no comfort complaints needs a person wearing the headset; then sideload release v0.1.

### Next, in order

1. **Data bridge milestone 3, objects:** 3b, the map object sprites. **Read [`MILESTONE_3B.md`](MILESTONE_3B.md) first** (research findings, design and budgets). Plan step 1 is done: the installed HD mod makes half the map's sprites RGBA PNGs, and the whole map's sprites do not fit the budget, so the atlas is now RGBA and holds only the zoomed view (its section 1a). Plan step 2 is done: the bridge decodes .def and PNG frames, matching the mod's images, at 1.2 ms per animation on a worker. The next step is plan step 3: the view-driven atlas fill on two workers, with the page upload and its timers. Then 3c, the 3D-mode window and hero step timing ([`DATA_BRIDGE.md` section 5](DATA_BRIDGE.md#5-milestones)).
2. **Phase 4, tabletop adventure map:** builds on milestones 2 and 3.
3. **Milestone 4, battle**, then **phase 5, battle diorama**.

Each milestone records its numbers in `DATA_BRIDGE.md` and is optimised before the next one starts.

### Budget left for the 3D view

- **GPU:** the frame at 72 Hz is 13.9 ms. The war room takes 6.9 ms app GPU time (measured 2026-11-07, [`XR_PERFORMANCE.md`](XR_PERFORMANCE.md#1-measured-in-the-war-room-2026-11-07)). About 7 ms is left for the table and the bridge consumer (< 0.5 ms); the minimap takes about 0.4 ms of it (looking at the table the room takes 8.8 ms, 9.2 ms with the minimap, [`DATA_BRIDGE.md`](DATA_BRIDGE.md#milestone-2-results-2026-11-07)). The game screen is a composition layer: it costs the compositor, not app GPU time. More GPU when needed: [`XR_PERFORMANCE.md` section 5](XR_PERFORMANCE.md#5-next-when-the-budget-is-needed).
- **CPU and memory, the 2D game** (milestone 0, heaviest map, whole map on screen): the game thread uses 92-96 % of one core, Godot 11 %. The 2D map drawing is the main cost, which is why the tabletop hides it ([`DATA_BRIDGE.md`](DATA_BRIDGE.md#animation-timing)).

## 1. Architecture and repository layout

A fork of [vcmi/vcmi](https://github.com/vcmi/vcmi): [bgaborg/vcmi](https://github.com/bgaborg/vcmi), branch `quest`.
The XR part is a [Godot](https://godotengine.org) 4.7.2 project. VCMI itself stays unchanged: no XR code in the VCMI C++ tree.

```
one APK, one Android process (is.xyz.vcmi.quest)
  ActivityLauncher (Qt, 2D panel)        upstream, unchanged except the Play hook
        | Play
        v
  VcmiXrActivity (Godot host)            quest source set
    Godot engine (godot-lib AAR) + godot_openxr_vendors (Meta)
      OpenXR session, room, controller models, ray, recenter, haptics
      OpenXRCompositionLayerCylinder, use_android_surface = true
            | android.view.Surface
            v
    VirtualDisplay (private, owned by the app)
      VcmiSDLActivity                    upstream, unchanged: SDL + GLES draw the game into the display
            ^
            | MotionEvent / KeyEvent, dispatched directly (same process)
    Input bridge (VcmiBridge, Java)      ray hit -> hover / click; controllers -> SDL gamepad and keys
    Data bridge (quest/bridge)           game data -> Godot extension, DATA_BRIDGE.md
```

- The game draws into an Android `Surface` owned by the OpenXR runtime (`XR_KHR_android_surface_swapchain`, Godot's `use_android_surface`). No copy, no shared GL context.
- The app starts its own game activity on a private virtual display it created (`ActivityOptions.setLaunchDisplayId`), as Meta's Spatial SDK does for panels.
- The compositor keeps 72 Hz even when the game stalls: Godot submits the frames, the game only updates the surface.
- Godot (MIT, GPL compatible) brings the OpenXR session, Meta controller models, passthrough, cylinder layers, glTF and spatial audio as nodes. The phase 2 spike did the same in own C++ inside VCMI's renderer: every feature was new engine code in files upstream changes often, so it was dropped.

### Layout

```
quest/                       docs and tools
  concept/                   WebXR prototype (phase 0)
  xr/                        Godot project (main.gd host, room.gd war room); exported to a .pck at build time
  xr/extension/              Godot extension libvcmi_xr.so (data bridge, Godot side)
  bridge/                    data bridge, game side, compiled into the game library
  tools/                     build, adb and test scripts (PHASE2.md, "Working on the headset")
  out/                       screenshots, logs, measurements (not in git)
  hdpack/                    planned: PC tool that builds a VCMI HD mod from the user's own H3 data
android/vcmi-app/
  quest.gradle               Quest build: source set, Godot and OpenXR AARs, .pck uncompressed
  src/quest/                 manifest, VcmiXrActivity, VcmiBridge, QuestGamepad, QuestPause
.github/workflows/quest.yml  APK build (manual dispatch)
```

### Rebase rules

The goal: `git rebase upstream/develop` has no conflicts in normal weeks.

1. New code goes only into new files: `quest/`, `android/vcmi-app/src/quest/`, `android/vcmi-app/quest.gradle`, `.github/workflows/quest.yml`.
2. No change to VCMI C++ (`client/`, `clientsdl3/`, `lib/`, ...) unless a phase cannot work without it. Then a small generic hook, proposed upstream first.
3. Every change to an upstream file is in the table below and is a few lines. Today they are spread over several commits; the next rebase squashes them into one `quest: upstream hooks` commit at the bottom of the series, so conflicts can only land there.
4. Planned, not set up yet: a weekly run of `quest.yml` that rebases `quest` on vcmi/vcmi `develop` inside the runner and builds the APK, without pushing. Schedules run from the default branch (`quest` on the fork); in GitHub expressions a bare `0` is falsy, so a conditional full checkout needs `'0'`.

### Changes to upstream files (keep this list short)

Checked against the merge base with `develop` on 2026-11-07; nothing else outside the paths of rule 1 differs (apart from `.claude/CLAUDE.md`).

| File | Hook | Why it cannot live in the Quest source set |
|---|---|---|
| `android/vcmi-app/build.gradle` | `apply from: 'quest.gradle'` (2 lines) | Gradle reads only this file |
| `android/vcmi-app/src/main/java/eu/vcmi/vcmi/ActivityLauncher.java` | Play starts the immersive activity if the build declares one, then closes the launcher task (16 lines) | the launcher starts `VcmiSDLActivity` by class |
| `clientapp/CMakeLists.txt` | adds `quest/bridge/Bridge.cpp` to `vcmiclient` on Android when it exists (4 lines) | the data bridge must be in the game library to reach the client and its lock ([`DATA_BRIDGE.md`](DATA_BRIDGE.md)) |

Remotes: `origin` is the fork. Planned: add `upstream` (`https://github.com/vcmi/vcmi.git`) for the first rebase: `git fetch upstream develop && git rebase upstream/develop`.

## 2. Constraints

- **Licence:** VCMI is GPL (`license.txt`). The fork and the APK source stay public under GPL.
- **Game data:** never ship or commit H3 files or art derived from them (also not upscaled). The user imports their own SoD / Complete / HD Edition data with the launcher. Ship tools only.
- **Other assets:** only CC0, public domain or CC BY, each recorded in a `LICENSES.md` next to it ([war room](xr/assets/room/LICENSES.md)). Stored as plain git files: GitHub refuses Git LFS uploads to a public fork. API keys (for example Meshy) never go into files.
- **Threading:** VCMI renders on its SDL thread into the virtual display; Godot renders on its own thread. They share no GL context. Godot never waits for the game's lock.
- **Comfort (acceptance criteria for every phase):**
  - The viewpoint never moves without the user's own head movement: no artificial locomotion, no camera glide.
  - World-locked content only; no head-locked UI except short system toasts.
  - The map moves only under direct hand control. Jumps to a hero use a fade, not a scroll.
  - No camera shake. Big effects flash or pulse the table.
  - Compositor at 72 Hz or more at all times, also when game logic stalls.

## 3. High-resolution graphics (HD)

HoMM3 HD Mod patches the Windows `Heroes3.exe` and cannot run on Quest. VCMI has the same result built in: any output resolution and xBRZ upscaling. An H3 install with HD Mod still imports (VCMI uses the SoD / Complete files).

### HD sources, in priority order

| # | Source | Format | Notes |
|---|---|---|---|
| 1 | VCMI HD mod packs | `sprites2x..4x`, `data2x..4x`, `video2x..4x`, `-shadow`, `-overlay`, player-colour variants ([`docs/modders/HD_Graphics.md`](../docs/modders/HD_Graphics.md)) | launcher mod manager |
| 2 | Ubisoft HD Edition import | x2 / x3 DXT paks, core graphics (`client/render/hdEdition/`) | the user must own HD Edition |
| 3 | Quest HD pack builder (`hdpack/`, planned) | writes a mod in the format of row 1 | runs on the user's PC with the user's data; AI upscaler or xBRZ + sharpen |
| 4 | xBRZ runtime upscaling | `video.upscalingFilter`, `video.asyncUpscaling` | fallback; on Quest it costs much memory (section 0) |

Loader order per image: `SPRITES{N}X/`, `DATA{N}X/`, the HD Edition pak, then upscaling of the base image (`clientsdl3/render/RenderHandler.cpp`). Maximum 4x. Setting: `video.useHdTextures`.

### Resolution target per view

Quest 3 shows about 25 pixels per degree at the centre.

| View | Distance | Target scale | Reason |
|---|---|---|---|
| War room screen | default 2 m, 2.4 m wide (~69 deg) | logical 1280x720 at 2x (display 2560x1440) | ~1600 px of panel detail is visible |
| UI panels | 0.5-0.8 m | 2x | sharp text; minimum font size setting |
| Tabletop map objects | 0.3-0.8 m | 4x | a 5 cm tile at 0.5 m is ~140 px; base tile 32 px |
| Tabletop terrain page | 0.3-0.8 m | 3x-4x | flat texture, mipmapped |
| Battle stacks and obstacles | 0.4-0.8 m | 3x-4x | seen close; `-overlay` for the hover outline |

### For the 3D views (phases 4-5)

- Godot builds mipmaps for the table textures (SDL textures have none), so distant objects do not shimmer.
- The Adreno 740 has ASTC and ETC2, not DXT. HD Edition DXT is decoded to RGBA on the CPU today (`DdsFormat.cpp`); compress textures for the 3D scene only if the texture budget is exceeded.
- XR graphics presets (Low / High / Ultra): upscaling filter, HD texture use and scale per asset class (objects 4x, creatures 4x per battle, UI 2x).

## 4. Mods

HD Mod, SoD_SP and the original Horn of the Abyss patch `Heroes3.exe` and do not run in VCMI. Their VCMI paths:

| Original mod | What players want | VCMI path on Quest |
|---|---|---|
| HD Mod | high resolution | built in (section 3) |
| HD Mod | QoL hotkeys, army management | key bindings (`config/keyBindingsConfig.json`): `heroArmySplit`, `exchangeArmy*`, `exchangeArtifacts*`, `townSwapArmies`, `townUpgradeGarrison`, `townOpenHeroExchange`, `battleAutocombat`; settings `quickCombat`, `stackRange`, `movementHighlightOnHover`, `showQueue`; mod `vcmi-extras` |
| SoD_SP | single-player fixes, options | no port; VCMI re-implements the rules. Gap analysis in [`PHASE1.md`](PHASE1.md#sod_sp-gap-analysis) |
| Horn of the Abyss | Cove, Factory, Bulwark, content, campaigns | VCMI mod `hota` ([vcmi-mods/horn-of-the-abyss](https://github.com/vcmi-mods/horn-of-the-abyss)); VCMI reads HotA maps and their event scripts. HD Mod from the HotA installer is not needed |

### Quest mod preset (candidates, test each: [`PHASE1.md`](PHASE1.md#test-checklist) rows 4.x)

| Mod | Why on Quest |
|---|---|
| `hota` | new factions and content |
| `vcmi-extras` | HD Mod-style QoL (Quick Exchange, Revisit, Search, icons, extended lobby) |
| `hd-remastered` | 32-bit art from ERA HD Edition, 1x only: better art, not a higher scale |
| `hq-music`, `heroes3-extended-soundtrack`, `new-sfx-sounds` | audio quality; input for spatial audio |
| `vivid-battlefields`, `diverse-battlefields` | battle backdrops for the diorama |
| `h3-campaigns-remade` | campaigns |
| `heroes-o-pedia` | in-game reference: a headset user cannot open a browser easily |
| `mmai` | ML battle AI (check CPU cost) |

Source: [vcmi-mods-repository `vcmi-1.7.json`](https://github.com/vcmi/vcmi-mods-repository/blob/develop/vcmi-1.7.json).

### Mod work

- QoL hotkeys in VR: done as the wrist panel (phase 3). Later: radial menu (`client/widgets/RadialMenu.cpp`) on a thumbstick press; grab / drop / split gestures for stacks (phase 4).
- XR adventure layout: the adventure UI is data-driven (`config/widgets/adventureMap.json`); an `adventureMapXR.json` can put the named widgets (`minimap`, `heroList`, `townList`, `buttonEndTurn`, resource bar) on separate panels.
- Compatibility: test the XR layout with UI mods (`new-interface-mod`, `vcmi-extras.adventureMap`); HD packs and `hota` must work on the table, with card metadata for HotA objects.

## 5. In-game popups and windows

All windows go through `WindowHandler::pushWindow` / `popWindow` (`client/gui/WindowHandler.h`) and draw into one screen. Until phase 4 they stay on the main screen; no routing.

| Type | VCMI classes (examples) | Placement on the table (phase 4+) | Input |
|---|---|---|---|
| Hold popup (right-click info) | `CRClickPopup` family | small panel 15-20 cm above the object, yaw toward the user | shows while grip is held |
| Message / question | `CInfoWindow`, selection dialogs | panel in front of the table, ~0.7 m, slightly below eye level; table dims | ray + trigger; haptic pulse on open |
| Large modal window | hero, town, exchange, market, kingdom, quest log, puzzle | large curved panel behind the table | ray + trigger |
| Spellbook | `CSpellWindow` | book panel in the left hand | right-hand ray |
| Battle popups | stack / spell info | above the stack | grip hold |
| Status text / tooltips | status bar | table edge panel | none |
| Tutorial | `CTutorialWindow` | an XR controls tutorial instead | ray + trigger |

- All popups are world-locked; one outside the view shows a direction cue at the view edge. A new window opens 5 cm in front of the previous one; older ones dim.
- Text input (save names, chat): Quest system keyboard through SDL text input; not yet checked from the virtual display.
- Implementation: a `WindowHandler` hook draws each top-level window into its own offscreen target (`createOffscreenCanvas` exists), passed through the data bridge. This is a VCMI C++ change: upstream first (rebase rule 2). Placement per window type comes from JSON in `quest/xr/`; unknown windows (mods) go to the front panel. The ray hit maps panel coordinates to the window rect; the existing event dispatch does the rest.

## 6. Roadmap

Done phases (0-3, data bridge milestones 0-1) are in section 0.

The phase 0 concept (war room screen, pop-up book map, battle diorama; [screenshots](concept/screenshots/)) runs in the Quest Browser over HTTPS:

```sh
cd quest/concept
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout key.pem -out cert.pem \
  -subj "/CN=vcmi-concept" -addext "subjectAltName=IP:<lan-ip>,DNS:localhost"
python3 serve_https.py 8443   # Quest Browser: https://<lan-ip>:8443, ?mode=screen|table|battle
```

### Phase 4 - Tabletop adventure map (after data bridge milestones 2 and 3)

- A Godot scene in `quest/xr/`, fed by the data bridge.
- Terrain, rivers and roads as a texture per map level; objects as instanced paper cards (pop-up animation); fog as a cloud layer; the path as discs.
- Picking: the ray hits the table, then a tile; the tile goes to the game (hover / click).
- Panels (section 5): resource bar at the table edge, hero / town lists on the left wrist, minimap as a small tablet, dialogs in front of the table.
- Controls: grab-drag the map, two-hand zoom; army gestures (grab / drop / split stacks). Seated / standing mode sets the table height.
- Card metadata (height, anchor, fold style) from JSON, so mods can tune it; HotA objects included.
- HD: 4x object cards, 3x-4x terrain; mipmaps; XR graphics presets (section 3).
- **Exit:** the adventure map is fully playable on the table; one button goes back to the 2D screen.

### Phase 5 - Battle diorama (after data bridge milestone 4)

- Hexes, stacks, obstacles, `EBattleFieldLayer`, animation frames through the bridge; hex to world mapping in Godot (2D: `BattleFieldController.cpp`).
- Cards for stacks, obstacles and heroes; corpses lie flat; projectiles fly in 3D arcs; effects as billboards.
- Battle UI on the table edge, spellbook in the hand, popups above stacks. HotA creatures and battlefield mods work.
- HD: creature animations at 3x-4x per battle, with `-overlay` and `-shadow`.
- **Exit:** all battle types playable, including sieges, with no regressions against the 2D battle.

### HD pack builder (parallel track)

- PC tool in `hdpack/` (Python, `uv`): reads the user's H3 data, upscales sprites and images, writes a VCMI HD mod with `-shadow` and `-overlay` images.
- Reject results with visible artifacts; compare with HD Edition art where it exists.
- **Exit:** a full HD mod for SoD that loads on Quest with no xBRZ fallback for map objects and creatures.

### Phase 6 - Immersion

- Spatial audio on the table (`AudioStreamPlayer3D`; sound events through the bridge).
- MR: snap the board to a real table (Meta scene and anchors).
- Gestures: flip the hourglass to end a turn. Town screen as a diorama or wide panel. Co-located multiplayer with shared anchors.

### Phase 7 - Release

- Performance pass (frame time, thermal, memory with 4x HD); store or sideload decision; GPL check; data import on the headset; build guide and settings docs.

After the roadmap: hand tracking (ray from the hand, pinch = click).

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Godot XR APIs marked experimental (`use_android_surface`) change | build breaks on an update | pinned Godot 4.7.2 and vendors 5.1.0; update on purpose |
| RAM with xBRZ and HD assets | the low-memory killer ends the game | xBRZ `none` by default (done); pre-made HD; scale per asset class |
| CPU: AI, server and the 2D map drawing on one core | slow AI turns | the 3D-mode window stops 2D drawing (`DATA_BRIDGE.md`); Godot's frame rate is independent of the game |
| GPU budget of the 3D view | dropped frames | ~7 ms left (section 0); next levers in `XR_PERFORMANCE.md` section 5 |
| Text input on the virtual display | no save names or chat | check the system keyboard; fallback: a Godot keyboard that sends keys |
| Upstream drift | rebase cost | rebase rules (section 1); hooks proposed upstream |
| UI or `hota` mods change widgets or content | XR layout or cards break | data-driven layout; default card metadata for unknown objects |
| HD art coverage is partial; xBRZ runs on the CPU | hitches at first use | HD pack builder; preload the cache |
| Upscaled H3 art is copyrighted | legal | ship the builder only |
| Store policy and GPL | no store release | sideload first; check policy before phase 7 |

Data bridge risks: [`DATA_BRIDGE.md` section 6](DATA_BRIDGE.md#6-risks).

## 8. Open decisions

1. **HD pack builder upscaler:** AI model (quality, model licence) or xBRZ + sharpen (fast, no licence issue).
2. **Upstream strategy:** which hooks to propose to VCMI. The contributor opens the PRs ([`AGENTS.md`](../AGENTS.md)).

Decided:
- 2026-11-06: Godot hosts the XR part; the game keeps its own renderer.
- 2026-11-06: the war room is the default environment; passthrough and black are a long left menu press away.
- 2026-11-06: data bridge option C, an in-client bridge plus a thin Godot extension ([`DATA_BRIDGE.md`](DATA_BRIDGE.md#2-options)).
- 2026-11-07: xBRZ `none` by default on Quest, set by the Quest Java side in `settings.json` (no upstream change); a player can still pick a concrete xBRZ filter.
- Separate package ID `is.xyz.vcmi.quest`, installs next to the normal Android build.

# VCMI for Meta Quest 3 - project plan

Native Quest 3 app (Android arm64, OpenXR). No PC streaming.
Goal: the most immersive way to play Heroes 3 on Quest 3, with no motion sickness.

## 1. Repository layout

A fork of [vcmi/vcmi](https://github.com/vcmi/vcmi): [bgaborg/vcmi](https://github.com/bgaborg/vcmi), branch `quest`. It is not one subdirectory only.
The XR code is a new top-level module, plus small gated hooks in existing code.

```
vcmi/                        fork bgaborg/vcmi, branch `quest` (tracks upstream `develop`)
  quest/                     project docs and prototypes (this file)
    concept/                 WebXR prototype (done, phase 0)
    hdpack/                  NEW  PC tool: builds a VCMI HD mod from the user's own H3 data
  clientxr/                  NEW  static lib `vcmiXr`: OpenXR session, layers, input, 3D scene
    session/                 XrInstance, XrSession, state machine, frame loop
    layers/                  quad / cylinder / projection layers, swapchains
    input/                   OpenXR actions -> VCMI input events, haptics
    scene/                   GLES3 renderer: room, table, cards, fog, effects
    tabletop/                adventure map + battle diorama (consumes layer exports)
  android/vcmi-app/          `quest` product flavor, VR manifest, OpenXR loader
  config/xr/                 NEW  default XR settings + JSON schema
  config/widgets/            NEW  `adventureMapXR.json` layout
```

Why a separate `clientxr/` module and not a fork-wide rewrite:
- The client already links one backend (`client/CMakeLists.txt` -> `clientsdl3`). XR sits next to it, the same way.
- Upstream rebases stay cheap if the changes to upstream files are only small hooks.
- Hooks are gated by one CMake option `ENABLE_OPENXR` (Android only). With the option off, the build is identical to upstream.

### Changes to upstream files (keep this list short)

| File | Hook |
|---|---|
| `CMakeLists.txt` | `option(ENABLE_OPENXR ...)`, `add_subdirectory(clientxr)` |
| `clientsdl3/render/ScreenHandler.cpp` | RGBA8888 EGL config (today RGB565, line ~328); present composed frame to XR layer instead of `SDL_RenderPresent` |
| `client/GameEngine.cpp` (`mainLoop`) | frame pacing from `xrWaitFrame` |
| `clientsdl3/events/InputHandler.cpp` | inject XR pointer / button events; route `hapticFeedback()` to controllers |
| `client/mapView/` | layer export: terrain texture + object instance list (phase 4) |
| `client/battle/BattleRenderer.cpp` | object export with hex + layer (phase 5) |
| `android/` | `quest` flavor, `com.oculus.intent.category.VR`, head tracking feature, loader |

Remotes:

```sh
git remote -v
# origin    https://github.com/bgaborg/vcmi.git   (fork, branch `quest`)
# upstream  https://github.com/vcmi/vcmi.git      (rebase source, `develop`)
git fetch upstream develop && git rebase upstream/develop
```

## 2. Constraints

- **License:** VCMI is GPL (see `license.txt`). The fork and the APK source must stay public under GPL.
- **Game data:** never ship H3 files. The user imports their own SoD / Complete / HD Edition data (existing launcher flow).
- **HD content:** see section 3. Never ship upscaled H3 art; ship only tools.
- **Threading:** all rendering is on the main GUI thread. The XR frame loop must run there too.
- **Comfort rules (acceptance criteria for every phase):**
  - The user's viewpoint never moves without the user's own head movement. No artificial locomotion and no camera glide.
  - World-locked content only. No head-locked UI except short system toasts.
  - Map moves only under direct hand control. Jumps to a hero use a fade, not a scroll.
  - No camera shake. Big effects flash or pulse the table.
  - Compositor at 72 Hz or higher, all the time, even when game logic stalls.

## 3. High-resolution graphics (HD)

### HoMM3 HD Mod and VCMI

- HoMM3 HD Mod (baratorch) patches the original `Heroes3.exe` (Windows, x86). Its main feature is high-resolution output of the original art, plus UI and multiplayer fixes. It cannot run on Quest.
- VCMI already gives the same result natively:
  - any output resolution
  - xBRZ upscaling, "similar in effect to HOMM3 HD mod" (`docs/players/Installation_iOS.md:65`)
- For Quest, the HD goal is: high-resolution output plus HD art, through the VCMI HD pipeline below.
- An H3 install with HD Mod still imports: VCMI uses the SoD / Complete data files. It does not use the HD Mod files.

### HD sources, in priority order

| # | Source | Format | Notes |
|---|---|---|---|
| 1 | VCMI HD mod packs | `sprites2x..4x`, `data2x..4x`, `video2x..4x`, `-shadow`, `-overlay`, player-colour variants ([`docs/modders/HD_Graphics.md`](../docs/modders/HD_Graphics.md)) | install with the launcher mod manager |
| 2 | Ubisoft HD Edition import | x2 / x3 DXT paks, core graphics only (`client/render/hdEdition/`) | the user must own HD Edition |
| 3 | Quest HD pack builder (new, `hdpack/`) | writes a VCMI HD mod (format of row 1) | runs on the user's PC with the user's own data; AI upscaler or xBRZ + sharpen; ship the tool, never the art |
| 4 | xBRZ runtime upscaling | `video.upscalingFilter`, `video.asyncUpscaling` | fallback for every image that rows 1-3 do not cover |

Loader order per image: `SPRITES{N}X/`, then `DATA{N}X/`, then the HD Edition pak, then upscaling of the base image (`clientsdl3/render/RenderHandler.cpp:486-498`). The maximum is 4x. Setting: `video.useHdTextures`.

### Resolution target per view

Quest 3 shows about 25 pixels per degree at the centre of the view.

| View | Distance | Target scale | Reason |
|---|---|---|---|
| War room screen | 2.4 m, panel ~63 deg wide | logical 1280x720, rendered at 2x | ~1600 px of panel detail is visible; 2x is sharper than the eye resolves |
| UI panels (resources, lists, dialogs) | 0.5-0.8 m | 2x | text must stay sharp; minimum font size setting |
| Tabletop map objects | 0.3-0.8 m | 4x | a 5 cm tile at 0.5 m is ~140 px on screen; base tile is 32 px |
| Tabletop terrain page | 0.3-0.8 m | 3x-4x | flat texture, mipmapped |
| Battle stacks and obstacles | 0.4-0.8 m | 3x-4x | stacks are seen close; needs `-overlay` for hover outline |

### XR-specific HD work

- **Mipmaps:** SDL_Renderer textures have no mipmaps. The XR scene renderer builds mipmaps for cards and pages, so that distant objects do not shimmer.
- **GPU texture format:** the Quest 3 GPU (Adreno 740) supports ASTC and ETC2. It does not support BC / DXT. HD Edition DXT data is decoded to RGBA on the CPU today (`client/render/hdEdition/DdsFormat.cpp`, squish). For the 3D scene, transcode HD textures to ASTC one time and cache them on the device.
- **Memory budget per asset class:**
  - adventure objects at 4x
  - creature animations at 4x, loaded per battle
  - UI at 2x
  - preload the xBRZ cache for anything without HD art, so that it does not cause hitches at first use
- **XR graphics presets** (Low / High / Ultra) that set upscaling filter, HD texture use and scale per asset class.

## 4. Mods

### Original-exe mods and their VCMI equivalents

HD Mod, SoD_SP and the original Horn of the Abyss patch `Heroes3.exe` (Windows). None of them runs in VCMI, and none runs on Quest. Each one has a VCMI path:

| Original mod | What players want from it | VCMI path on Quest |
|---|---|---|
| HD Mod | high resolution | built in: any resolution, xBRZ, HD packs (section 3) |
| HD Mod | QoL hotkeys, army management | built-in key bindings (`config/keyBindingsConfig.json`): `heroArmySplit`, `exchangeArmyToLeft/Right/Swap`, `exchangeArtifacts*`, `townSwapArmies`, `townUpgradeGarrison`, `townOpenHeroExchange`, `battleAutocombat`; settings `quickCombat`, `stackRange`, `movementHighlightOnHover`, `showQueue`; mod `vcmi-extras` (Quick Exchange, Revisit / Search buttons, bonus and immunity icons, extended lobby) |
| SoD_SP | single-player bug fixes, extra options | no port. VCMI re-implements the rules, so it does not inherit many original bugs. Options come from game settings, the extended lobby (`vcmi-extras`) and small mods (`boost-ai`, `extreme-ai`, `tavern-invite`). Gap analysis task below |
| Horn of the Abyss | Cove, Factory, Bulwark towns, artifacts, skills, terrains, objects, campaigns | VCMI mod `hota` ([vcmi-mods/horn-of-the-abyss](https://github.com/vcmi-mods/horn-of-the-abyss)), type Expansion, CC BY-SA, assets by HotA Crew, version 1.8.005 when checked. VCMI reads HotA maps, including HotA event scripts (`lib/mapping/MapFeaturesH3M.h`, `HotaScriptConverter.h`) |

- The HotA installer for the exe game includes HD Mod. In VCMI, HD Mod is not needed, because the engine has these features built in.
- HotA campaigns: verify which campaigns load in VCMI (phase 1 test).

### Quest mod preset (candidates, test each in phase 1)

| Mod | Why on Quest |
|---|---|
| `hota` | new factions and content |
| `vcmi-extras` | HD Mod-style QoL (Quick Exchange, Revisit, Search, icons) |
| `hd-remastered` | 32-bit replacement art from ERA HD Edition. It ships `content/sprites` only (1x), so it improves the art, but it does not add HD scale |
| `hq-music`, `heroes3-extended-soundtrack`, `new-sfx-sounds` | audio quality; input for spatial audio |
| `vivid-battlefields`, `diverse-battlefields` | battle backdrops for the diorama |
| `h3-campaigns-remade` | campaigns |
| `heroes-o-pedia` | in-game reference; useful because a headset user cannot open a browser easily |
| `mmai` | ML battle AI (check CPU cost on Quest) |

Source: [vcmi-mods-repository `vcmi-1.7.json`](https://github.com/vcmi/vcmi-mods-repository/blob/develop/vcmi-1.7.json).

### Mod work in this project

- **QoL hotkeys in VR:** a keyboard is not available. Map the key bindings to controller input:
  - radial menu (`client/widgets/RadialMenu.cpp`, used for touch today) on a thumbstick press
  - two-hand gestures for army actions: grab a stack and drop it on a slot = move; drop with grip held = split
  - a hotkey panel on the wrist, with the most used bindings
- **SoD_SP gap analysis:** list the SoD_SP options that players use. For each one, record: VCMI setting, existing mod, or a new small mod (JSON only, if possible).
- **XR adventure layout:** the adventure UI is data-driven (`config/widgets/adventureMap.json`, `adventureMapPortrait.json`). Add `adventureMapXR.json`, which puts the named widgets (`minimap`, `heroList`, `townList`, `buttonEndTurn`, resource bar, ...) on separate XR panels.
- **Mod compatibility:**
  - UI mods (`new-interface-mod`, `vcmi-extras.adventureMap`) change the same widgets, so test the XR layout with them
  - HD packs and `hota` must work in tabletop mode, with card metadata for HotA objects

## 5. In-game popups and windows

All windows go through `WindowHandler::pushWindow` / `popWindow` (`client/gui/WindowHandler.h`). Today they draw into one screen.

### Window types and XR placement

| Type | VCMI classes (examples) | Placement in tabletop mode | Input |
|---|---|---|---|
| Hold popup (right-click info) | `CRClickPopup` family (`client/windows/InfoWindows.h`) | small panel 15-20 cm above the pointed object, turned to face the user (yaw only) | shows while grip is held, hides on release |
| Message / question | `CInfoWindow` (`showInfoDialog`), selection dialogs | panel in front of the table, about 0.7 m away, slightly below eye level; table dims (`backgroundDimLevel`) | ray + trigger; haptic pulse and sound on open |
| Large modal window | hero, town (`CCastleInterface`), exchange, market, kingdom, quest log, puzzle | large curved panel behind the table (same as the war room screen) | ray + trigger |
| Spellbook | `CSpellWindow` | book panel in the left hand | right-hand ray |
| Battle popups | stack / spell info | above the stack | grip hold |
| Status text / tooltips | status bar | table edge panel | none |
| Tutorial | `CTutorialWindow` (touch tutorial) | replace with an XR controls tutorial | ray + trigger |

### Rules

- All popups are world-locked. A popup outside the view shows a small direction cue at the view edge.
- A new window opens 5 cm in front of the previous one; older windows dim.
- Text: minimum font height setting; test readability at the panel distance.
- Text input (save names, chat): Quest system keyboard through SDL text input (verify on device).
- In screen mode (phase 3), popups stay on the main screen. No routing is needed.

### Implementation

- `WindowHandler` hook: each top-level window draws into its own offscreen target (`createOffscreenCanvas` exists) and gets its own quad layer.
- Placement class per window type comes from `config/xr/windows.json`. Unknown windows (for example from mods) fall back to the front panel.
- Input routing: the ray hits the panel; panel coordinates map to the window rect in logical screen coordinates; the existing event dispatch handles the rest.

## 6. Phases

### Phase 0 - Concept (done)

- WebXR mockup in [`quest/concept/`](concept/index.html): war room screen, pop-up book map, battle diorama, VR + AR.
- Result: the layout and the comfort model work on the headset.

| War room screen (Option 1) | Pop-up book map (Option 2) | Battle diorama (Option 3) |
|---|---|---|
| ![War room](concept/screenshots/screen.png) | ![Pop-up map](concept/screenshots/table.png) | ![Battle](concept/screenshots/battle.png) |

Run on the Quest (WebXR needs HTTPS):

```sh
cd quest/concept
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout key.pem -out cert.pem \
  -subj "/CN=vcmi-concept" -addext "subjectAltName=IP:<lan-ip>,DNS:localhost"
python3 serve_https.py 8443
# Quest Browser: https://<lan-ip>:8443 -> accept cert -> Enter VR / Enter AR
# ?mode=screen|table|battle selects the start mode
```

### Phase 1 - Foundation

- Fork, branch, CI job for Android arm64 with the `quest` flavor.
- Run the current APK on Quest 3 as a 2D panel app.
- Check: data import on Quest, AI turn time.
- Mods: install the Quest mod preset (section 4). Test HotA towns, maps and campaigns, `vcmi-extras`, `hd-remastered`.
- SoD_SP gap analysis (section 4).
- HD check: install one VCMI HD mod pack and HD Edition data on Quest. Measure RAM, load time and frame time at 2x / 3x / 4x and with xBRZ only.
- **Exit:** a full game is playable in a 2D panel; a baseline is measured (FPS, RAM, AI turn time).

### Phase 2 - XR spike

- OpenXR session on the SDL EGL context (`XR_KHR_opengl_es_enable`).
- Render `composeFrame()` to a texture, then copy it to an XR swapchain and show it on a cylinder layer.
- Handle the session lifecycle (focus, visibility, pause, Meta system menu).
- **Decision:** stay on GLES (shared SDL context) or move to Vulkan (SDL Vulkan renderer + `XR_KHR_vulkan_enable2`). Measure GL state conflicts between SDL_Renderer and the custom GL code.
- **Exit:** a stable 72/90 Hz compositor with the game frame on a curved layer, and a written decision on GLES vs Vulkan.

### Phase 3 - War room MVP, release v0.1

- Input bridge:
  - Laser ray hits the layer and gives logical coordinates, which feed `setCursorPosition`.
  - Trigger = left click, grip = right click, thumbstick = map scroll, A/B = keyboard shortcuts.
  - Hand tracking pinch as a second input method.
- Haptics through the existing `hapticFeedback()` calls.
- QoL hotkeys on controllers: radial menu, wrist hotkey panel (section 4).
- Popups stay on the main screen; dim the room and pulse haptics when a dialog opens.
- Environment: a low-poly war room (glTF) or passthrough, selected in settings.
- Seated / standing mode, recenter (trigger and the Meta button long-press), screen distance and size settings.
- Text readability: logical 1280x720 or higher, rendered at 2x, cylinder compositor layer.
- HD: 2x assets for the screen and UI panels; XR graphics presets.
- **Exit:** a full campaign map is playable start to end in VR with no comfort complaints. Sideload release v0.1.

### Phase 4 - Tabletop adventure map

- Layer export from `client/mapView/`:
  - terrain + river + road rendered into a texture per region (no objects, no fog)
  - an object instance list: tile, sprite frame, animation, owner flag, z-order
- The 3D scene in `clientxr/tabletop/` draws:
  - the map page as a flat texture
  - objects as instanced paper cards (pop-up animation)
  - fog as a cloud layer, the path as discs
- Picking: the ray hits the table plane, then a tile, then the existing MapView hover / click handlers.
- Panel routing: VCMI windows draw to separate targets, so they can show on separate quad layers:
  - the resource bar at the table edge
  - hero / town lists on the left wrist panel
  - the minimap as a small tablet
  - dialogs as a panel in front of the table
- Controls: grab-drag the map, two-hand pinch zoom (zoom range 4-256 px per tile already exists).
- Card metadata (height, anchor, fold style) from JSON, so mods can tune it. Include HotA objects.
- `adventureMapXR.json` layout; test with UI mods.
- Popup and window routing (section 5): hold popups above objects, dialogs in front of the table, large windows behind it.
- Army management gestures: grab / drop / split stacks.
- HD: 4x object cards and 3x-4x terrain page, mipmaps, ASTC cache on the device.
- **Exit:** the adventure map is fully playable on the table; the 2D screen fallback is available with one button.

### Phase 5 - Battle diorama

- Export from `BattleRenderer`: object, hex, `EBattleFieldLayer`, animation frame.
- Hex to world mapping (today hex to pixel is hard-coded in `BattleFieldController.cpp` ~924).
- Cards for stacks, obstacles, heroes. Corpses lie flat. Projectiles fly in 3D arcs. Effects are billboards.
- Battle UI on the table edge. Spellbook as a book panel in the hand.
- Battle popups above stacks (section 5).
- HotA creatures and battlefields (`hota`, battlefield mods) work as cards and backdrops.
- HD: creature animations at 3x-4x, loaded per battle, with `-overlay` and `-shadow` images.
- **Exit:** all battle types are playable, including siege walls and towers, with no regressions against the 2D battle.

### HD pack builder (parallel track, starts after phase 1)

- PC tool in `hdpack/` (Python, `uv`): reads the user's H3 data, upscales all sprites and images, writes a VCMI mod in the HD format.
- Produces `-shadow` and `-overlay` images, which flags and creature hover outlines need.
- Output check: compare with HD Edition art where it exists; reject results with visible artifacts.
- **Exit:** a full HD mod for SoD that loads on Quest with no xBRZ fallback for map objects and creatures.

### Phase 6 - Immersion

- Spatial audio: map ambient sources and battle sounds positioned on the table (check SDL3_mixer 3D support first).
- MR: snap the board to a real table (OpenXR scene / plane extensions).
- Gestures: flip the hourglass to end a turn, grab a stack to split it.
- Town screen as a diorama or a wide curved panel.
- Co-located hot-seat / multiplayer with shared spatial anchors.

### Phase 7 - Release

- Performance pass: frame time, thermal, memory with 4x HD assets.
- Store or sideload decision; GPL compliance check; user data import flow on headset.
- Docs: build guide for the `quest` flavor, settings, comfort options.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| SDL_Renderer and custom GL share one context and break each other's state | rendering bugs | phase 2 spike; fallback to the Vulkan path |
| Game loop skips frames, XR needs a frame every vsync | judder | resubmit the last layer image; the compositor reprojects it |
| CPU budget: AI (TBB) + server process + XR runtime | AI turns stall frames | limit AI threads; keep the XR loop on the main thread at a fixed rate |
| RAM with HD assets and xBRZ | crashes | prefer pre-made HD assets; cap scale per asset class |
| Text readability | eye strain | compositor layers, 2x rendering, minimum font size setting |
| Upstream drift | rebase cost | keep the hooks small; rebase often; propose generic hooks upstream (layer export, input injection) |
| Map layer export changes `MapViewCache` behavior | regressions in 2D | separate export path; 2D path unchanged |
| Windows assume one screen (centered, positioned at the cursor) | popups in wrong place or size | per-window offscreen target; fallback placement |
| UI mods change the adventure widgets | XR layout breaks | data-driven `adventureMapXR.json`; test with UI mods |
| `hota` updates change content | missing card metadata | default card metadata for unknown objects |
| Store policy and GPL | no store release | sideload first; check policy before phase 7 |
| Quest GPU has no DXT support; RGBA HD textures use a lot of RAM | crashes, long loads | ASTC transcode cache; scale per asset class |
| HD packs cover only part of the art; xBRZ runs on the CPU | hitches at first use | preload the xBRZ cache; HD pack builder covers the gaps |
| Distributing upscaled H3 art violates copyright | legal | ship the builder tool only; the user runs it on their own data |

## 8. Open decisions

1. GLES vs Vulkan (end of phase 2).
2. Passthrough or war room as the default environment.
3. Separate package ID (`is.xyz.vcmi.quest`) to install next to the normal Android build: recommended.
4. HD pack builder upscaler: AI model (quality, licence of the model) or xBRZ + sharpen (fast, no licence issue).
5. Upstream strategy: which hooks to propose to VCMI. The contributor opens the PRs (see [`AGENTS.md`](../AGENTS.md)).

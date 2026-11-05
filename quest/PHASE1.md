# Phase 1 - Foundation

Status of [phase 1](PROJECT_PLAN.md#phase-1---foundation): the Quest build runs as a 2D panel app.
This file has the build setup, the open follow-ups, the on-device test checklist, the baseline results and the SoD_SP gap analysis.

## Build

| Item | Value |
|---|---|
| Application ID | `is.xyz.vcmi.quest` (installs next to `is.xyz.vcmi` and `is.xyz.vcmi.daily`) |
| Label | VCMI Quest |
| ABI | arm64-v8a |
| Signing | daily key from `CI/android` (public, no secrets needed) |
| CI | [`.github/workflows/quest.yml`](../.github/workflows/quest.yml): manual dispatch only during phase 1 (builds are local); push trigger in a later phase. First run: [42025537281](https://github.com/bgaborg/vcmi/actions/runs/42025537281), `56962aa52`, success |
| Artifact | `<run>-vcmi-branch-quest-<commit>-quest-arm64-v8a.apk` |

The Quest build is the normal Android release build plus these Gradle properties:

```
vcmiQuest=true;applicationIdSuffix=.quest;applicationLabel=VCMI Quest;applicationVariant=quest;signingConfig=dailySigning
```

Local build (Linux or WSL Ubuntu 24.04, from a Linux checkout - not `/mnt/c`): [`tools/make-apk.sh`](tools/make-apk.sh). The first run installs the toolchain without sudo into `~/vcmi-tools` (uv, Conan, CMake, Ninja, JDK 17, Android SDK 35) and restores the prebuilt Conan dependencies; set `SDK_LICENSES` to the licenses folder of an SDK where the Android SDK license is already accepted. Output: `quest/out/vcmi-quest-release.apk`. First build ~15 min on 20 cores, incremental ~2 min.

`vcmiQuest=true` makes [`quest.gradle`](../android/vcmi-app/quest.gradle) merge [`src/quest/AndroidManifest.xml`](../android/vcmi-app/src/quest/AndroidManifest.xml) into every build type. The overlay adds:

- `com.oculus.supportedDevices` = `quest3|quest3s`
- `<layout>` on all activities: default panel 1280x720 dp, minimum 800x600 dp (H3 resolution)

### Changes to upstream files

| File | Change |
|---|---|
| `android/vcmi-app/build.gradle` | one line: `apply from: 'quest.gradle'` |
| `CMakeLists.txt` | option `ENABLE_OPENXR` (Android, off by default); `add_subdirectory(clientxr)` after `clientapp` (phase 2 prep) |
| `clientapp/EntryPoint.cpp` | calls the OpenXR runtime probe after `GameEngine` is created, `VCMI_OPENXR` only (phase 2 prep) |
| `clientsdl3/render/ScreenHandler.cpp` | RGB888 EGL config instead of RGB565, `VCMI_OPENXR` only (phase 2 prep) |

All other files are new. Upstream `github.yml` is unchanged; the fork does not run it on `quest` pushes.

### Deferred to later phases

- **Product flavor (`quest` / `standard`).** Still not needed: the Gradle properties above give the separate ID, label and manifest overlay, and `quest.gradle` adds the OpenXR loader dependency, minSdk 24 and the arm64 ABI filter, all without renaming Gradle tasks (`assembleRelease` -> `assembleQuestRelease` would change upstream CI and `aab-from-build.yml`). Add the flavor when the Quest build needs its own Java sources.
- **VR manifest entries** (`com.oculus.intent.category.VR`, `android.hardware.vr.headtracking`). These turn the app into an immersive app. Phase 2, with the first XR session. The OpenXR permissions and runtime broker queries are already merged from the loader AAR.
- **CMake preset `android-quest-release`.** Not added, to keep `CMakePresets.json` unchanged. Add it if local Quest builds become frequent.

## Follow-ups

Open phase 1 work, all on the headset. Phase 1 exits when these are done.

- [ ] Mod preset: install `hota` and `vcmi-extras` from the launcher (checklist 1.5, 4.1, 4.2), then the rest of the preset (4.3-4.8). The 128 HotA maps in `Maps/` fail to load until `hota` is installed.
- [ ] Baseline, every row, 30 min each with the FPS counter on (`video.performanceOverlay`). First: xBRZ off (`video.upscalingFilter` = `none`); repeat xBRZ 2x for 30 min to confirm the memory plateau.
- [ ] Input (checklist 2.x): check that A / B / X / Y reach VCMI as gamepad buttons; if so, map A to right click (`mouseClickRight`) as a Quest-only override. Today right click is a 1 s trigger hold (`general.longTouchTimeMilliseconds`).
- [ ] Data import through the system file picker (checklist 1.3); data was copied with adb so far.
- [ ] Panel size in pixels at the default 1280x720 dp.
- [ ] SoD_SP gap analysis: play through the "verify" rows.
- [ ] Lifecycle (checklist 3.3-3.5): Meta menu focus loss, sleep / wake, 10 min background, portrait panel.
- [ ] A full game, start to end (exit criterion).

## Device helper

[`tools/quest.sh`](tools/quest.sh) wraps adb (Git Bash on Windows). Output goes to `quest/out/` (ignored by git).

```sh
quest/tools/quest.sh info
quest/tools/quest.sh install <apk>
quest/tools/quest.sh start
quest/tools/quest.sh sample 300          # PSS, CPU, battery temperature, 1 sample per second
quest/tools/quest.sh pull-logs           # VCMI_Client_log.txt, server_log.txt, logcat
```

Logs on the device: `/sdcard/Android/data/is.xyz.vcmi.quest/files/vcmi-data/cache/`.

Frame rate: enable the in-game FPS counter (`video.performanceOverlay` in settings) and the Meta OVR Metrics Tool overlay. A 2D panel app has no VrApi frame log.

## Test checklist

Each row: result (pass / fail / note), and the log folder from `pull-logs` for failures.

### Install and data

| # | Test | Result |
|---|---|---|
| 1.1 | APK installs from CI artifact, app appears in the Library under "Unknown sources" | |
| 1.2 | Launcher opens as a panel at 1280x720 dp; panel resize works; minimum size holds | |
| 1.3 | Data import: copy SoD / Complete files to `/sdcard/Download/H3` (`adb push`), import from the launcher with the system file picker | |
| 1.4 | Data import: HD Edition data, same flow; graphics found (`video.useHdTextures`) | |
| 1.5 | Mod repository loads; a mod downloads and installs | |

### Input

| # | Test | Result |
|---|---|---|
| 2.1 | Controller ray + trigger: left click on launcher and in game | |
| 2.2 | Right click (hold popups): which input gives it today (long press, grip, B)? | |
| 2.3 | Hand tracking pinch: click and long press | |
| 2.4 | Map scroll: drag, thumbstick | |
| 2.5 | Bluetooth keyboard + mouse (optional): hotkeys work | |
| 2.6 | System keyboard opens for save names and chat | |

### Game

| # | Test | Result |
|---|---|---|
| 3.1 | New game on an SoD map, play 2 weeks, save, quit, load | |
| 3.2 | Battle: manual, auto-combat, quick combat, siege | |
| 3.3 | Panel loses focus (Meta menu), app resumes; headset sleep and wake | |
| 3.4 | App backgrounded for 10 min (foreground service keeps the game alive) | |
| 3.5 | Portrait layout: resize the panel taller than wide (`video.allowPortrait`) | |

### Mods (Quest mod preset, see [PROJECT_PLAN.md](PROJECT_PLAN.md#quest-mod-preset-candidates-test-each-in-phase-1))

| # | Mod | Test | Result |
|---|---|---|---|
| 4.1 | `hota` | Cove, Factory, Bulwark towns in a random map; one HotA map; one HotA campaign | |
| 4.2 | `vcmi-extras` | Quick Exchange, Revisit, Search buttons; extended lobby | |
| 4.3 | `hd-remastered` | art loads; RAM delta | |
| 4.4 | `hq-music`, `heroes3-extended-soundtrack`, `new-sfx-sounds` | playback | |
| 4.5 | `vivid-battlefields`, `diverse-battlefields` | battle backdrops | |
| 4.6 | `h3-campaigns-remade` | campaign starts | |
| 4.7 | `heroes-o-pedia` | opens, readable at panel size | |
| 4.8 | `mmai` | battle AI works; CPU time per AI move | |

## Baseline

Fill one row per configuration. Map: a fixed XL SoD map with 7 AI players, same save for every row.
Measure 5 minutes of play with `quest.sh sample 300`, and the AI turn time from the client log (end turn -> own turn).

| Config | Panel px | Load time to main menu (s) | Map load (s) | FPS adventure (avg / min) | FPS battle (avg / min) | PSS peak (MB) | CPU avg (%) | AI turn (s) | Battery temp after 30 min (C) |
|---|---|---|---|---|---|---|---|---|---|
| SoD, xBRZ off (`video.upscalingFilter` = `none`) | | | | | | | | | |
| SoD, xBRZ 2x (`auto`, partial, see notes) | | 1.4 | 0.7 | | | 1368 | 22 (max 155) | 2.1 (day 1) | 38 after 3 min |
| SoD, xBRZ 4x | | | | | | | | | |
| HD Edition data | | | | | | | | | |
| HD mod pack 2x | | | | | | | | | |
| HD mod pack 3x | | | | | | | | | |
| HD mod pack 4x | | | | | | | | | |
| + `hota` + `vcmi-extras` | | | | | | | | | |

CPU is percent of one core (`top`); 100 = one full core.

Notes on the xBRZ 2x row (2026-11-05, `quest/out/baseline-sod-xbrz2-auto.csv`, logs in `quest/out/logs-baseline1`):
- Recorded as "xBRZ off", but the default `upscalingFilter` = `auto` selected xBRZ 2x (log: `Selected upscaling filter 2`): the panel renders above the logical resolution and the device has more than 4 GB RAM (`ScreenHandler::loadUpscalingFilter`).
- Map `Myth and Legend` (144x144 + underground, 8 players: 1 human, 7 AI). Run stopped after 3 min of a planned 5, on day 1 to 2: one human turn, one round of AI turns.
- Samples are 1.7 s apart (adb round trips), 106 samples.
- PSS: 811 MB on the adventure map, +330 MB while the town, fort and recruitment screens were opened for the first time (each image gets an xBRZ 2x copy: 4x the pixels, plus its GPU texture), +125 MB at end of turn and AI turn, then flat at 1350-1368 MB for the last 80 s with small drops (cache eviction). No sign of a leak. The code estimates xBRZ 2x at 1.0-1.5 GB (`ScreenHandler::loadUpscalingFilter`).
- Asset cache budget 484 MiB (1/16 of RAM, `RenderHandler.cpp`). It counts surfaces and textures of images that nothing else uses; images in use by open windows and the map are outside the budget.
- Repeat the run with `upscalingFilter` = `none` for the xBRZ off row, and for 30 min to confirm the plateau.
- CPU peak 155% (1.5 cores) during the AI turn; 15-20% while idle on the adventure map.
- AI turn: all 7 AI players took 2.1 s on day 1, including 2 AI-vs-neutral battles. Not representative yet: early turns are short.
- Not measured: FPS (enable `video.performanceOverlay`), panel size in pixels.

**Exit criterion:** a full game is playable in the 2D panel and every row above is filled.

## SoD_SP gap analysis

Source: the default `SoD_SP.ini` of [RoseKavalier/H3Plugins](https://github.com/RoseKavalier/H3Plugins) (`SoD_SP_Public/Next Version`). One row per option.

Coverage:
- **setting** - a VCMI client setting (`config/schemas/settings.json`)
- **game setting** - `config/gameConfig.json`, can be changed by a mod through `"settings"` in `mod.json`
- **n/a** - the bug or limit does not exist in VCMI, because VCMI re-implements the rules
- **verify** - not confirmed from the code; check in game during phase 1
- **gap** - no equivalent; candidate for a small mod or for later

### Rules

| SoD_SP option | What it does | VCMI | Coverage |
|---|---|---|---|
| `DisablePlague` | no plague month | `creatures.monthPlagueProbability` = 0 | game setting |
| `DisableDoubleGrowth` | no double growth month | `creatures.monthDoubleGrowthProbability` = 0 | game setting |
| `DisableWeeklyGrowth` | no random +5 weekly growth | `creatures.weekSpecialProbability` = 0, or `allowRandomSpecialWeeks` = false (all three) | game setting |
| `NagaBank` | Naga Bank gives sulfur | creature bank rewards are JSON (`config/objects/creatureBanks.json`) | small mod |
| `Hireable` | tavern respects "can be hired by" | `TavernHeroesPool::isHeroAvailableFor` | verify |
| `HeroFusion` | two heroes on one tile bug | | verify |
| `AdmiralBugFix` | endless movement with Admiral's Hat | | verify |
| `MovementBugs` | movement restore after defeat, retreat on water, lighthouse | | verify |
| `EventBug` | "cancel after first visit" event | | verify |
| `Vanish` | upgraded wanderers deducted on retreat | | verify |
| `CreaturesSplit` | original wandering creature split | VCMI split rules | verify |
| `CombatObstacles` | original obstacles | VCMI obstacle generation | verify |
| `OriginalRNG` | original RNG | VCMI uses its own seeded RNG | n/a |

### Bug fixes

| SoD_SP option | What it does | VCMI | Coverage |
|---|---|---|---|
| `FixTurretBug` | Armorer / Air Shield vs. turrets | damage is `scripts/damage/damageCalculator.lua` | verify |
| `FixCreaturesOverflow` | stacks > 32,767 | 32-bit stack counts (`TQuantity`) | n/a |
| `FixResourcesOverflow` | resources > 2^31 | 32-bit amounts, 64-bit sums (`TResourceCap`, `lib/ResourceSet.h`) | verify |
| `FixPrimaryOverflow` | primary skills > 127 | 32-bit skills | n/a |
| `Earthquake` | Earthquake kills units | `core:catapult` spell script | verify |
| `AnchorBug` | obstacle anchor hex blocks spells | obstacle hexes from config | verify |
| `CloneBug` | HD+ Clone fix (off by default) | | verify |
| `EnchantersFix` | Enchanters' targets | `ENCHANTER` bonus | verify |
| `RealKills` | summons and clones not counted as casualties | battle results window | verify |

### AI

| SoD_SP option | What it does | VCMI | Coverage |
|---|---|---|---|
| `AICheats` | no Town Portal on cursed ground, no Fly without the spell | Nullkiller2 uses the same rules as players | n/a |
| `AINecromancy` | AI raises correct number | same server code for AI and players | n/a |
| `AIMagicMirror` | AI considers Magic Mirror | BattleAI | verify |
| `BerserkAI` | original berserk behaviour | BattleAI | verify |
| `FastBattleBugs`, `QCoverflow` | AI vs AI quick combat bugs | AI battles are simulated by BattleAI, not a formula | n/a |
| `AIMinimap` | minimap during AI turn | | verify |

### Interface

| SoD_SP option | What it does | VCMI | Coverage |
|---|---|---|---|
| `BattleQueuePanel`, `ShowMoveSequence` | turn order panel | `battle.showQueue`, `queueSize`, `queueSmallOutside` | setting |
| `BattleQueueText` | queue shows hex position | | gap (needs `CombatCoordinates`) |
| `QuickSpellPanel` | quick spell panel | `battle.enableQuickSpellPanel` | setting |
| `ShowHitPoints` | hit points on hover | `battle.showHealthBar`, `stackInfoBasicPanel` | setting |
| `TurboAnimation` | faster combat animations | `battle.speedFactor` | setting |
| `CombatRMBTextbox` | info stays open after right click | `battle.stickyHeroInfoWindows` (heroes only) | verify for stacks |
| `SpellDetails` | extra info on spell right click | | verify |
| `ResourcesFormat` | short format for large numbers | | verify |
| `CombatCoordinates` | hex coordinates on hover | | gap (low value in VR) |
| `AdventureCoordinates` | map coordinates on hover | | gap (low value in VR) |
| Colors (`[color]`) | text colors for the above | | n/a |

### Result

- Rules: plague, double growth and weekly growth are game settings; a JSON-only mod `quest-sodsp-rules` can set all three. Naga Bank fits in the same mod.
- Most bug-fix rows are n/a or verify. Each "verify" row is a short scenario to test in phase 1; record the result in the table.
- Gaps are only coordinate displays, which have little value in VR. No C++ work is planned for them.

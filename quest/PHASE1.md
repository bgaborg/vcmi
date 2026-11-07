# Phase 1 - Foundation

Phase 1: the Quest build runs as a 2D panel app. Build settings, open follow-ups, the test checklist, the panel baseline and the SoD_SP gap analysis. Status of all phases: [`PROJECT_PLAN.md`](PROJECT_PLAN.md#0-status-and-next-steps).

## Build

| Item | Value |
|---|---|
| Application ID | `is.xyz.vcmi.quest` (installs next to `is.xyz.vcmi` and `is.xyz.vcmi.daily`) |
| Label | VCMI Quest |
| ABI | arm64-v8a |
| Signing | daily key from `CI/android` (public, no secrets needed) |
| CI | [`.github/workflows/quest.yml`](../.github/workflows/quest.yml), manual dispatch (builds are local). First run: [42025537281](https://github.com/bgaborg/vcmi/actions/runs/42025537281) |
| Artifact | `<run>-vcmi-branch-quest-<commit>-quest-arm64-v8a.apk` |

The Quest build is the normal Android release build plus these Gradle properties:

```
vcmiQuest=true;applicationIdSuffix=.quest;applicationLabel=VCMI Quest;applicationVariant=quest;signingConfig=dailySigning
```

`vcmiQuest=true` makes [`quest.gradle`](../android/vcmi-app/quest.gradle) add the `src/quest` source set (manifest overlay, Java, assets, jniLibs) to every build type, plus the Godot and OpenXR AARs, minSdk 24 and the arm64 ABI filter. A build-type source set instead of a product flavor keeps the Gradle task names, and so upstream CI, unchanged. The manifest overlay adds `com.oculus.supportedDevices` = `quest3|quest3s`, a `<layout>` on the panel activities (default 1280x720 dp, minimum 800x600 dp) and the immersive `VcmiXrActivity`.

Local build and device work: [`PHASE2.md`](PHASE2.md#working-on-the-headset). Changed upstream files: [`PROJECT_PLAN.md`](PROJECT_PLAN.md#changes-to-upstream-files-keep-this-list-short).

## Follow-ups

Open phase 1 work, all on the headset:

- [ ] Mod preset: install `hota` and `vcmi-extras` from the launcher (checklist 1.5, 4.1, 4.2), then the rest (4.3-4.8). The 128 HotA maps in `Maps/` fail to load until `hota` is installed.
- [ ] Data import through the system file picker (checklist 1.3); data was copied with adb so far.
- [ ] SoD_SP gap analysis: play through the "verify" rows.
- [ ] A full game, start to end (exit criterion; in VR this is the phase 3 exit).

Done elsewhere: controller input is the XR host's gamepad (A / B / X / Y, grip = right click; [`PHASE2.md`](PHASE2.md#how-the-xr-host-works)); the Meta menu and sleep pause the game; the performance baseline moved to the XR build ([`DATA_BRIDGE.md`](DATA_BRIDGE.md#milestone-0-results-2026-11-06)).

## Test checklist

Each row: result (pass / fail / note), and the log folder from `quest.sh pull-logs` for failures.

### Install and data

| # | Test | Result |
|---|---|---|
| 1.1 | APK installs from CI artifact, app appears in the Library under "Unknown sources" | |
| 1.2 | Launcher opens as a panel at 1280x720 dp; panel resize works; minimum size holds | |
| 1.3 | Data import: copy SoD / Complete files to `/sdcard/Download/H3` (`adb push`), import from the launcher with the system file picker | |
| 1.4 | Data import: HD Edition data, same flow; graphics found (`video.useHdTextures`) | |
| 1.5 | Mod repository loads; a mod downloads and installs | |

### Input (in VR)

| # | Test | Result |
|---|---|---|
| 2.1 | Ray + trigger: left click in the launcher and in game | pass (XR host) |
| 2.2 | Right click (hold popups) | pass: grip |
| 2.3 | Hand tracking pinch | moved after the roadmap |
| 2.4 | Map scroll: right thumbstick | pass |
| 2.5 | Bluetooth keyboard + mouse (optional): hotkeys work | |
| 2.6 | System keyboard opens for save names and chat (game on the virtual display) | |

### Game

| # | Test | Result |
|---|---|---|
| 3.1 | New game on an SoD map, play 2 weeks, save, quit, load | |
| 3.2 | Battle: manual, auto-combat, quick combat, siege | |
| 3.3 | Meta menu, headset sleep and wake | pass in VR: the game pauses (`QuestPause`) |
| 3.4 | App backgrounded for 10 min (foreground service keeps the game alive) | |

### Mods (Quest mod preset, [`PROJECT_PLAN.md`](PROJECT_PLAN.md#4-mods))

| # | Mod | Test | Result |
|---|---|---|---|
| 4.1 | `hota` | Cove, Factory, Bulwark towns in a random map; one HotA map; one HotA campaign | |
| 4.2 | `vcmi-extras` | Quick Exchange, Revisit, Search buttons; extended lobby | |
| 4.3 | `hd-remastered` | art loads; RAM delta | |
| 4.4 | `hq-music`, `heroes3-extended-soundtrack`, `new-sfx-sounds` | playback | |
| 4.5 | `vivid-battlefields`, `diverse-battlefields` | battle backdrops | |
| 4.6 | `h3-campaigns-remade` | campaign starts | |
| 4.7 | `heroes-o-pedia` | opens, readable on the screen | |
| 4.8 | `mmai` | battle AI works; CPU time per AI move | |

## Panel baseline (2026-11-05)

One run as a 2D panel, before the XR host: `quest/out/baseline-sod-xbrz2-auto.csv`, logs in `quest/out/logs-baseline1`. The XR baseline on the heaviest map is [milestone 0](DATA_BRIDGE.md#milestone-0-results-2026-11-06); HD pack and xBRZ rows are measured there with `xr-perf.sh` when phase 4 sets the XR graphics presets.

- Map `Myth and Legend` (144x144 + underground, 1 human, 7 AI), xBRZ 2x: the default `upscalingFilter` = `auto` selects it when the output is above the logical resolution and the device has more than 4 GB RAM (`ScreenHandler::loadUpscalingFilter`, log `Selected upscaling filter 2`).
- Load to main menu 1.4 s, map load 0.7 s. AI turn on day 1: 2.1 s for 7 AI players (early turns are short).
- PSS: 811 MB on the adventure map, +330 MB when town, fort and recruitment screens open the first time (each image gets an xBRZ 2x copy and its GPU texture), +125 MB at the AI turn, then flat at 1350-1368 MB; no leak. Asset cache budget 484 MiB (1/16 of RAM); images in use by open windows and the map are outside it.
- CPU (percent of one core): 15-20 % idle on the map, peak 155 % during the AI turn. Battery 38 C after 3 min.

## SoD_SP gap analysis

Source: the default `SoD_SP.ini` of [RoseKavalier/H3Plugins](https://github.com/RoseKavalier/H3Plugins) (`SoD_SP_Public/Next Version`). One row per option.

Coverage:
- **setting** - a VCMI client setting (`config/schemas/settings.json`)
- **game setting** - `config/gameConfig.json`, can be changed by a mod through `"settings"` in `mod.json`
- **n/a** - the bug or limit does not exist in VCMI, because VCMI re-implements the rules
- **verify** - not confirmed from the code; check in game
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
- Most bug-fix rows are n/a or verify. Each "verify" row is a short scenario to test in game; record the result in the table.
- Gaps are only coordinate displays, which have little value in VR. No C++ work is planned for them.

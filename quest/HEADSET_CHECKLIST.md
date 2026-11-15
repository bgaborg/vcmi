# Headset checklist: what was built without the Quest

Everything below was written between 2026-11-12 and 2026-11-14, checked on the PC only (local tests, PC renders, an Android build). None of it has run on the headset. Check it in this order before a release: the earlier steps are needed by the later ones. Each step names what to look for and where the code is, so a failure can be found fast.

Build and install: `quest/tools/make-apk.sh` (WSL), then `quest/tools/quest.sh install <apk>`. Tools: [`PHASE2.md`, "Working on the headset"](PHASE2.md).

## 1. Start

| # | Check | Expected | If not |
|---|---|---|---|
| 1.1 | Start from the VCMI launcher with Play | "VCMI Loading..." before the eyes within a second or two, then the room | `main.gd` `_ready` (the text waits for `session_visible`); the black gap before Godot's first frame is the system's |
| 1.2 | `quest/tools/xr-smoke.sh` | passes | - |

## 2. The table (phase 4)

| # | Check | Expected | If not |
|---|---|---|---|
| 2.1 | Tabletop mode (right stick click) | seated at the table, facing the room; the map 45 cm under the eyes | `room.gd` (the table's turn), `main.gd` `_seat`, `table_drop` |
| 2.2 | `quest/tools/xr-panel.sh` | a whole turn passes | its aim points are in the map's frame; if the board's rows miss, the table's turn moved something |
| 2.3 | Wrist panel, "Settings" page: each - and + | the table moves 5 cm; the board tilts 5 degrees (to 20); the cards' angle changes; "Wrist" moves the panel to the other controller, and the first hand's ray presses it; "Room" changes the environment; all kept after a restart | `wrist_panel.gd`, `main.gd` `_wrist_setting`, `_save_screen` |
| 2.4 | The panel on the right wrist | readable, turned to the eyes as on the left | `wrist_panel.gd` `POSE` is not mirrored |
| 2.5 | Click a tile with the board tilted 20 degrees | the right tile is clicked | `room.gd` `set_tilt`, `table_uv` |
| 2.6 | Pan a full, revealed map | the sprites stay HD; no long reloads at each pan | `SpriteAtlas::plan` plans again when the view changes |
| 2.7 | A map with boats: board one, sail | the boat shows the hero's flag and its waves; the hero is hidden; they slide together | `ObjectScan.cpp` (`flagAnimation`, `overlayAnimation`), `VcmiData.cpp` `spritesOf`. The waves may need a moving group: only the standing groups are published |
| 2.8 | A teleport (monolith, town portal) | the hero is at the exit at once | `Bridge.cpp` `onAfterHeroTeleported` |
| 2.9 | An enemy hero walking in view | its flag moves with it | `VcmiData.cpp` `animate_move` |
| 2.10 | Passthrough (wrist "Room"), then tabletop mode | only the book with the map and its panels, lit evenly, at the table's height: set "Table" so that it lies on your real table. Out of tabletop mode nothing of the room shows | `main.gd` `_show_room`, `room.gd` `show_table_only` |
| 2.10a | Test command `fade <id> 0`, then `fade <id> 1` on an object in view (its id: `test bridge`, or `sprites_check`) | it fades out over half a second and shows again (it is still on the map), then fades in | `map_fades.gd`, `table_shaders.gd` SPRITE (`fades`) |
| 2.10b | Pick up a resource, beat a wandering monster | it fades out over half a second, then is gone; nothing flashes | `VcmiData.cpp` `fade_changes`, `drop_ghosts`; `main.gd` `_update_fades` |
| 2.11 | Point at the hourglass, hold the grip, turn the hand over | the hourglass flips and the turn ends (the trigger on it still does too) | `main.gd` `hourglass_grab`, `TableMath.turned_over` |
| 2.13 | Look around the war room for a minute | the walls, floor and panels near the fireplace, the torches and the candles breathe with their flames; the wall panels show boards; a faint warm haze deepens the far walls; still 72 Hz (`test gfx 9 0` turns the flicker off to compare) | `room.gd` `SURFACE_SHADER`, `_set_fires` |
| 1.0a | Press Play in the launcher | the VCMI shield and "Loading..." (Horizon's splash), then the gold "Loading..." with a bar filling as the war room is built, no Godot logo, no half-built room | `vr_splash.png`, `project.godot` `boot_splash`, `main.gd` (`LOADING_BAR`), `room.gd` `staged` |
| 2.12 | With a room scanned (a desk marked as a table), choose passthrough from a chair at the desk | one system dialog asks to share the room; allowed, the map lies on the desk's top, its near edge on your side; log line "a real table" | `table_anchor.gd`, `TableMath.on_real_table` |
| 2.12a | Passthrough without a scanned room, or the permission denied | the map at the wrist panel's height, as before | `table_anchor.gd` |

## 3. The battle (phase 5)

| # | Check | Expected | If not |
|---|---|---|---|
| 3.1 | Test command `battle 1` in tabletop mode | sample armies on the hex field (pikemen and griffins against skeletons and a dragon, markers until their art is read); the ray lights a hex; `battle 0` brings the map back | `battle_field.gd` |
| 3.2 | Start a real battle in tabletop mode | the field replaces the map; the 2D battle is on the screen before the chair; each stack is where the 2D battle has it | `Bridge.cpp` `publishBattle`, `main.gd` (`vcmi_data.battle()`) |
| 3.3 | Wait a second | the markers turn into the creatures, standing, the right way round, their feet on their hexes; the battlefield's picture is under the hexes | `battle_cards.gd` (`ANCHOR`, `FEET`, `WIDE`), `main.gd` (the worker), `Bridge.cpp` `imageFile` |
| 3.4 | In your turn | the active stack's hex is gold, the hexes it reaches are green, obstacles are dark | `publishBattle` (`reach`, `blocked`) |
| 3.5 | Point at a green hex and pull the trigger | the stack walks there, on the table (a slide) and in 2D | `hexInput`, `publishBattle` (the input part), `battle_cards.gd` `set_stacks` |
| 3.6 | Shoot an enemy with a shooter | it plays its shot, its own missile (an arrow, a bolt; a plain dart the first time, until it is read) flies to the target, the target flinches or dies | `Bridge.cpp` `BattleEvents` (registered in `registerBattleEvents`), `battle_cards.gd` `set_action` |
| 3.6a | The enemy's turn | its stacks attack and shoot with their own animations, not only your stacks' hits | the same; without events the table guesses (`battle_cards.gd` `set_stacks`) |
| 3.7 | Attack an enemy in melee | the stack attacks from its own side of the target | `publishBattle` `pointAt` |
| 3.8 | Wrist panel during the battle | its first page is "Battle": wait, defend, spell book, auto-combat, retreat, surrender | `wrist_panel.gd` `set_battle` |
| 3.8a | The heroes | each side's hero stands at its end of the field, facing in | `publishBattle` (`heroes`), `battle_cards.gd` `HERO_AT` |
| 3.9 | Cast a spell | open the book (wrist) and pick the spell on the screen; then try the target on the table (a hex click runs the 2D battle's own action for that hex, which should cast), else on the screen | `publishBattle` (the input part) |
| 3.10 | A two-hex creature, on both sides | stands over its two hexes | `battle_cards.gd` `WIDE` |
| 3.11 | The battle ends | the result window on the screen; after it the map is back on the table; no crash | `publishBattle` (the `try` around `getBattle`) |
| 3.9b | A mass spell (Slow, Haste for all) and Armageddon | the spell's animation on every unit it affects; Armageddon's over the whole field | `publishBattle` (`actionTargets`), `battle_cards.gd` `set_action` |
| 3.6b | A ray shooter shoots | coloured lines from it to the target, fading | `publishBattle` (`actionRay`), `battle_cards.gd` `play_ray` |
| 3.9a | A spell lands | the casting hero raises its hand; the spell's own animation plays on the first stack it touches (or on its hex), which also flashes red | `Bridge.cpp` `battleSpellCast` (`actionEffect`, `actionSide`), `battle_cards.gd` `play_effect`, `battle_field.gd` `flashes` |
| 3.12 | A siege | the walls, towers and moat are drawn on the field; a wall the catapult breaks changes to its broken picture; the gate opens; wall hexes are dark | `Bridge.cpp` `wallPieces` (a copy of `BattleSiegeController`'s private rules), `battle_field.gd` `poll`, `compose_picture` |
| 3.12b | A siege against a town with towers | a shooter stands on each tower's top in the picture, and shoots | `publishBattle` (`VCMI_STACK_TURRET`), `battle_cards.gd` `_place` |
| 3.13 | Listen during a table battle, turning the head | each strike, hit, death, step and spell sounds from its stack on the table, at the game's effects volume; the game's own sounds are silent; the 2D battle on the screen runs fast; after the battle the game's sounds and its battle speed are back | `battle_sounds.gd`, `Bridge.cpp` `updateTableBattle` |
| 3.13a | Tabletop off during a battle | the game's own sounds only, nothing twice | `battle_field.gd` (`visible`) |
| 3.12a | The creatures up close | standing and walking frames are sharper (2x) than the attack frames | `VcmiData::decode_animation_hd`, `battle_field.gd` `load_creatures` |
| 3.13 | Quick combat, and an enemy's battle against another enemy | nothing on the table, no crash | `battleInt` is null |
| 3.14 | Frame rate and memory with seven stacks a side | 72 fps; `quest.sh sample` | a draw call per card; frames are textures of their own (`battle_cards.gd`) |

## 4. Known limits, not failures

- Only the standing and moving frames of the creatures are upscaled; attacks and deaths are the game's 1x art.
- The table follows the 2D battle by up to a tenth of a second. A spell's animation plays on its first target only (a mass spell too), and effects that fill the 2D screen (Armageddon) are not shown.
- Chain lightning's bolt is straight and appears at once (the 2D one is jagged and jumps hop by hop), and every target plays the full effect.
- An object that vanishes during a pan (a sprite rebuild) goes at once, without its fade.
- Two attacks within a tenth of a second show as one.
- A melee attack always comes from the attacker's side; another side cannot be chosen from the table.
- The 2D battle's own hex highlight is off at the two side columns, and its status text can vanish when a new stack becomes active.
- Objects appear and vanish on the map at once, without the 2D map's fade.

When a step passes, move its result to the phase's document ([`PHASE4.md`](PHASE4.md), [`PHASE5.md`](PHASE5.md), [`VISUALS.md`](VISUALS.md)) and delete the row here.

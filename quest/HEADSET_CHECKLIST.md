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

## 3. The battle (phase 5)

| # | Check | Expected | If not |
|---|---|---|---|
| 3.1 | Test command `battle 1` in tabletop mode | sample armies on the hex field (pikemen and griffins against skeletons and a dragon, markers until their art is read); the ray lights a hex; `battle 0` brings the map back | `battle_field.gd` |
| 3.2 | Start a real battle in tabletop mode | the field replaces the map; the 2D battle is on the screen before the chair; each stack is where the 2D battle has it | `Bridge.cpp` `publishBattle`, `main.gd` (`vcmi_data.battle()`) |
| 3.3 | Wait a second | the markers turn into the creatures, standing, the right way round, their feet on their hexes; the battlefield's picture is under the hexes | `battle_cards.gd` (`ANCHOR`, `FEET`, `WIDE`), `main.gd` (the worker), `Bridge.cpp` `imageFile` |
| 3.4 | In your turn | the active stack's hex is gold, the hexes it reaches are green, obstacles are dark | `publishBattle` (`reach`, `blocked`) |
| 3.5 | Point at a green hex and pull the trigger | the stack walks there, on the table (a slide) and in 2D | `hexInput`, `publishBattle` (the input part), `battle_cards.gd` `set_stacks` |
| 3.6 | Shoot an enemy with a shooter | it shoots; the target flinches or dies | the same; the attack's animation is guessed from the turn (`battle_cards.gd`) |
| 3.7 | Attack an enemy in melee | the stack attacks from its own side of the target | `publishBattle` `pointAt` |
| 3.8 | Wrist panel during the battle | its first page is "Battle": wait, defend, spell book, auto-combat, retreat, surrender | `wrist_panel.gd` `set_battle` |
| 3.9 | Cast a spell | open the book (wrist) and pick the spell on the screen; then try the target on the table (a hex click runs the 2D battle's own action for that hex, which should cast), else on the screen | `publishBattle` (the input part) |
| 3.10 | A two-hex creature, on both sides | stands over its two hexes | `battle_cards.gd` `WIDE` |
| 3.11 | The battle ends | the result window on the screen; after it the map is back on the table; no crash | `publishBattle` (the `try` around `getBattle`) |
| 3.12 | A siege | playable; walls and the gate are dark hexes; the walls' pictures are missing | planned after this run |
| 3.13 | Quick combat, and an enemy's battle against another enemy | nothing on the table, no crash | `battleInt` is null |
| 3.14 | Frame rate and memory with seven stacks a side | 72 fps; `quest.sh sample` | a draw call per card; frames are textures of their own (`battle_cards.gd`) |

## 4. Known limits, not failures

- The creatures are the game's 1x art; from the chair they are a little soft.
- The table follows the 2D battle by up to a tenth of a second and shows no projectiles or spell effects.
- The attack's animation is guessed: after a retaliation only the hit shows.
- A melee attack always comes from the attacker's side; another side cannot be chosen from the table.
- The 2D battle's own hex highlight is off at the two side columns, and its status text can vanish when a new stack becomes active.
- Objects appear and vanish on the map at once, without the 2D map's fade.

When a step passes, move its result to the phase's document ([`PHASE4.md`](PHASE4.md), [`PHASE5.md`](PHASE5.md), [`VISUALS.md`](VISUALS.md)) and delete the row here.

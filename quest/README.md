# VCMI on Meta Quest 3: how to play

A sideloaded build of VCMI (Heroes of Might and Magic III) for the Quest 3. You sit in a war room; the game runs on a curved screen, or on the war table in front of you as a pop-up book. Developers: start at [`PROJECT_PLAN.md`](PROJECT_PLAN.md).

State on 2026-11-15: the curved screen and the map on the table have run on the headset. The battle on the table, its sounds, the wrist settings, the map on your real table in passthrough and what else [`HEADSET_CHECKLIST.md`](HEADSET_CHECKLIST.md) lists were built on a PC and have not run on a headset yet.

## Install

1. Build the APK: `quest/tools/make-apk.sh` in Linux or WSL ([`PHASE1.md`](PHASE1.md)).
2. Install it with developer mode on: `quest/tools/quest.sh install <apk>`. It installs next to a normal VCMI for Android (`is.xyz.vcmi.quest`).
3. Start VCMI from the library ("Unknown sources"). The launcher opens as a flat window: import your Heroes 3 data there as in VCMI for Android, then press Play.

## Controls

| | |
|---|---|
| Trigger | click where the ray points: on the screen, a tile or hex of the table, a board entry, a wrist button |
| Grip | right click. On the table: hold still for a tile's popup, move to drag the map, both hands to zoom |
| Right stick | scrolls the 2D map. Its click switches between the screen and the table |
| Left stick | the screen's distance and width; at the table, the table's height |
| A / B | accept / cancel. X / Y: next hero / next town |
| Left menu button | short: the game's options. Held: the next room (war room, passthrough, black) |
| Wrist panel | turn the back of the left controller to your eyes; press its buttons with the other hand's ray |

## The wrist panel

- **Keys:** end turn, spells, kingdom, quests, sleep, dig, quick save and load, table / screen, next hero. During a battle the page is **Battle**: wait, defend, spell book, stack info, auto-combat, end tactics, retreat, surrender, info for the stack you last pointed at.
- **Settings**, each with a - and a +, kept for the next start:
  - **Table:** how far under your eyes the map lies (30 to 110 cm). In passthrough with a scanned room the map lies on your real table by itself; without one, set it so the map lies on your table.
  - **Board tilt:** raises the map's far edge, up to 20 degrees.
  - **Cards:** how upright the map's objects stand.
  - **Wrist:** which controller carries the panel.
  - **Room:** war room, passthrough or black.

## The table

- The map is a book's page. The heroes and towns are on the board to the left, the resources and the date on the bar, the whole map on the small tablet. Click a hero or town to select it, again to open it.
- The hourglass at the near right ends the turn: click it, or point at it, hold the grip and turn your hand over.
- Dialogs, towns and the hero screen open on the game screen, which comes forward above the table.
- **Battles** are fought on the same page: the battlefield with its hexes, the creatures as standing cards, the heroes at its ends. Green hexes can be reached, the gold one is the active stack, dark ones are blocked. Click a hex to move, an enemy to attack or shoot. Spells: open the book from the wrist panel, pick the spell on the screen, then its target on the table or the screen. The 2D battle stays on the screen behind, and is always right when the two differ.
- In **passthrough** only the book and its panels show, on your own table. If you have scanned your room (the headset's Settings, Physical space, Space setup) and allow VCMI to use it when passthrough first starts, the map lies on the table you marked, its near edge on the side where you are.
- During a battle on the table its sounds come from the creatures and spells on the page, at the game's effects volume, and the 2D battle behind runs at its fastest speed. Your own battle speed is back after the battle.

## Known limits

[`HEADSET_CHECKLIST.md`, section 4](HEADSET_CHECKLIST.md#4-known-limits-not-failures).

## Licences

VCMI is GPL v2 or later; the Quest build as a whole is distributed under GPL v3 ([`RELEASE.md`](RELEASE.md), section 2). The war room's assets: [`xr/assets/room/LICENSES.md`](xr/assets/room/LICENSES.md). The game's data is yours: the build ships none, and `quest/tools/h3-extract.py` only reads your own install for local renders.

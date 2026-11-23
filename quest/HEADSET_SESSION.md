# Headset session for v0.1

One session that takes the port from "built on the PC" to a first public preview (sideload, [`RELEASE.md`](RELEASE.md)).
It works through [`HEADSET_CHECKLIST.md`](HEADSET_CHECKLIST.md) and the release's left-overs. Most of it runs with the
headset on the desk while Claude drives it over adb. You wear it for about an hour, for what only a person can judge.

| Part | Who | Time |
|---|---|---|
| Before: preparation on the PC | Claude | about a day of work, no headset |
| 0. Setup | you | 10 min |
| 1. Unattended run | Claude, headset on the desk | 1.5–2 h |
| 2. Wearing it | you, Claude driving the test commands | about 1 h |
| 3. Fixes and the release | Claude; you approve publishing | after the session |

## Before the session (PC only)

The aim: no surprises on the headset that the simulator could have shown, and no time on the headset spent getting
into a situation (a battle, a boat, a siege).

1. **Try the checklist in the simulator first**: the game in the host in Meta XR Simulator, real controller input
   through Meta XR Operator ([`META_TOOLS.md`](META_TOOLS.md)). These rows don't depend on Android:
   - the table: 2.1, 2.3, 2.5, 2.6, 2.10a, 2.11, 2.13, 2.14;
   - the battle: 3.1–3.13.

   A failure here gets fixed before the session.
2. **Each situation set up with VCMI's cheat codes** (`docs/players/Cheat_Codes.md`: armies, spells, `vcmimove`,
   `vcmiteleport x y`), found first in the simulator, then typed on the headset by the session script:
   - a hero next to a wandering monster with seven stacks a side (3.2–3.11, 3.14);
   - a hero with a boat (2.7);
   - a monolith (2.8);
   - an enemy hero in view (2.9);
   - a resource and a weak monster (2.10b);
   - a siege of a town with towers (3.12, 3.12b);
   - a mass spell, Armageddon, a ray shooter and chain lightning in the books and armies (3.6b, 3.9, 3.9a, 3.9b).
3. **`quest/tools/xr-session.sh`**: one script for part 1. It installs the APK, sets up each situation with the cheats, runs the steps
   below in order, and writes a report of pass or fail per row with screenshots to `quest/out/session-<date>/`.
4. **The APK** from the final commit, and the release notes drafted: what works, the known limits, the install steps.
5. **The import test's data**: the Heroes 3 files pushed to `/sdcard/Download/H3` on the headset at the start of
   part 1, for part 2's import test.

### Done so far (2026-11-23)

- **Typing on the PC** (`type <text>` in the scripts): cheat codes work in the simulator. `xrsim-game.txt` checks
  `vcmieagles`.
- **Live commands on the PC**: `quest/tools/xrsim-cmd.sh`, the PC's `quest.sh test`. A real battle is about a
  minute away: `type vcmiainur`, `vcmimove`, then two taps on a wandering monster.
- **Shown in the simulator, a real battle on the table:**
  - 3.2: the field replaces the map;
  - 3.3: the creatures stand on their hexes;
  - 3.4: reach and obstacles;
  - 3.5: a move made in 2D slides on the table (`out/pc-live-battle-table.png`, `out/pc-battle-moved-table.png`).

  Not yet checked there: a move started from the table, shots, spells, sieges, the battle's end.
- **Saves are not needed:** the cheats set up each situation on the headset too (`adb shell input text`, as
  `xr-minimap.sh` does), so there is no doubt about PC saves loading on Android.

## 0. Setup (you, 10 minutes)

- The headset charged, or on its cable, on the desk; developer mode and wireless debugging on.
- Space Setup with your desk marked as a table, and a chair at it (2.12).
- Say "go". Claude reconnects adb and wakes the headset (`quest.sh awake` keeps it running off your face).

## 1. Unattended run (Claude, headset on the desk, 1.5–2 hours)

Claude installs, drives and screenshots. Each step uses the existing tools ([`PHASE2.md`](PHASE2.md#working-on-the-headset)).
Failures are noted and the run goes on.

| Step | Checklist rows | Tool |
|---|---|---|
| Start, to the adventure map | 1.2 | `xr-smoke.sh` |
| The bridge's lifecycle: new game, save, load, restart, quit | (DATA_BRIDGE) | `xr-lifecycle.sh` |
| The minimap and the fog | (DATA_BRIDGE) | `xr-minimap.sh` |
| A whole turn without the 2D side panel | 2.2 | `xr-panel.sh` |
| Tabletop mode, the wrist panel's settings, a click on the tilted board, a pan over a revealed map | 2.1, 2.3, 2.5, 2.6 | `quest.sh test` (`aim`, `click`, `wrist`, `stick`), screenshots |
| Fades, by command and in play | 2.10a, 2.10b | `test fade`, a resource picked up |
| Boat, monolith, enemy hero | 2.7, 2.8, 2.9 | `vcmiteleport` next to each |
| The room's light and haze, at 72 Hz, with and without the flicker | 2.13 | `test gfx 9 0/1`, `quest.sh sample` |
| The sample battle, then a real one: placement, reach, a move, a shot, melee, the wrist's battle page, the heroes, two-hex creatures, the end | 3.1–3.8a, 3.10, 3.11 | `test battle 1`, a cheated army against a monster, `hex` clicks |
| Spells, mass spells, Armageddon, a ray shooter, a siege with towers, quick combat | 3.6b, 3.9–3.9b, 3.12, 3.12b, 3.13 (quick combat) | `vcmiistari`, `vcmiarmy`, `vcmiteleport` |
| Performance: the heaviest map, a battle with seven stacks a side | 3.14, RELEASE step 2 | `xr-perf.sh`, `quest.sh sample` |
| Heat: 30 minutes in play on the table, sampled | RELEASE step 2 | `quest.sh sample` |

Claude sends the report and its screenshots, and fixes what it can before part 2. A fix means a new APK, so it is
only worth doing when it blocks part 2.

## 2. Wearing it (you, about an hour)

Claude runs the test commands and reads the logs; you look, aim and say what you see. In this order:

| Step | Rows | What to judge |
|---|---|---|
| Launch from the launcher | 1.0a, 1.1 | the splash, the loading bar, no logo, no half-built room |
| The pointer on the screen, the table and the wrist panel | 2.14 | small, easy to find, hides nothing; aiming at a tile is steady enough (ray jitter against the tile size) |
| The wrist panel on the right wrist | 2.4 | readable, turned to you |
| The hourglass: grip, turn the hand over | 2.11 | the turn ends |
| Passthrough on your desk, with the room-sharing dialog, then once without it | 2.10, 2.12, 2.12a | the map lies on the desk's top, its near edge on your side |
| A table battle, turning the head | 3.13, 3.13a | each sound comes from its stack; nothing twice |
| Play the first scenario for 20–30 minutes | phase 3 exit | comfort, legibility of the cards and the screen, anything tiring or confusing |
| The data import on a fresh install | PHASE1 1.3 | pick `Download/H3` in the system file picker; the game starts. Claude clears the app's data first (`pm clear`), so this goes last |

Claude writes down what you say into the checklist rows as you go.

## 3. After the session

- Claude fixes the failures, rebuilds, and reruns the failed part-1 rows unattended. Rows that need a person wait for
  a short second session, or go into the release notes as known limits.
- Passing rows move into their phase documents, as `HEADSET_CHECKLIST.md` asks.
- The release ([`RELEASE.md`](RELEASE.md) section 3): the `quest-v0.1` tag, a GitHub release of the fork with the APK
  and notes. Publishing waits for your OK.
- Then the VCMI team first, on their Discord or GitHub; then a call for testers in the Heroes 3 and VCMI modding
  communities. Mods (VCMI's mod presets, Horn of the Abyss, new towns and creatures on the table) are the first
  thing to ask testers about; PHASE1's mod tests are still open.

## Not in v0.1

- A full campaign map in the headset: v0.1 is a preview, and the first scenario is the comfort check.
- A store build: it needs its own signing key and the store's policy check ([`RELEASE.md`](RELEASE.md)).

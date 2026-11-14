# Visual pass: the war table as a playable diorama

Status: 2026-11-12. Built and checked on the PC; the headset results are in section 5. This pass came before the
headset test of milestone 4d ([`PHASE4.md`](PHASE4.md)).

Goal: the table reads as one made thing (a book as large as the table, with paper cards standing on its pages), and the
map is comfortable to play on the Quest 3 from the lord's chair.

## 1. What was wrong

Seen in the PC renders of 2026-11-11 (`quest/out/visuals/00-before-seat.png`):

| # | Problem | Cause |
|---|---|---|
| 1 | Most of the book was black, with a starfield where the fog is, and the fog tiles showed seams | the 2D fog tiles were drawn as sprites; the minimap under them was black where unseen |
| 2 | Rocks and figures poked through the book, the bar and the board | the Meshy war table has figurines sculpted into its top (5 to 27 cm high) |
| 3 | The map was a 0.8 x 0.5 m rectangle on a 1.9 x 1.4 m table | `MINIMAP_AREA`, sized to fit between the figurines |
| 4 | The hero board was a 50 cm sign standing over the table | it stood upright beside the map |
| 5 | The table top was a low-resolution painted map, burnt orange by the candle light | the table's own texture; it competed with the game's map |
| 6 | The plastic castles, towers and flags did not fit the paper look | KayKit figures from the screen-only room |
| 7 | The tablet was a black rectangle | the whole map is in the fog on day 1, drawn black |
| 8 | The local renders showed the whole map, not what the player sees | the preview kept zoom 1 |

## 2. Design

One idea: **the unexplored map is the blank page.** The map is painted on the book's paper as the player explores, and
the cards stand on it.

- **The map fills the table.** The book is 1.5 x 0.94 m, whatever the map's shape: the view keeps the table's shape and
  the tiles stay square (`room.gd` `view_aspect`). A tile is 2.5 cm by default (was 1.5 cm) and 8 cm at the closest.
- **The hero stands near the player.** The view follows the selected hero to a point 0.68 of the way from the far
  edge to the near one (`main.gd` `TABLE_FOCUS`), about 65 cm from the chair. For this the view may pass the map's
  near edge (`view_reach`); blank page shows there.
- **The table's height follows the player,** as in Demeo: seated at the table, the map lies 0.45 m under the eyes,
  wherever the real head is (`main.gd` `table_drop`, `_seat`). Before, the map stood 0.84 m over the real floor: too
  high from a real chair; 0.6 m under the eyes was too low. The virtual floor is then not the real one.
- **The chair faces the room.** The table is turned so that the lord's chair stands on the wall's side and the shelf
  with the panels on the room's side.
- **Settings on the wrist panel** (`xr/wrist_panel.gd`), saved. The panel has two pages, "Keys" and "Settings". A
  setting is a line with its value between a - and a + button:
  - "Table": 5 cm a press, 0.3 to 1.1 m under the eyes (the left stick does the same at the table);
  - "Board tilt": the map with its book and shelf raised at the far edge as a lectern, 5 degrees a press, up to 20;
  - "Cards": the cards' angle from the table, 30 to 90 degrees;
  - "Wrist": the controller that carries the panel, left or right; the other hand's ray presses it;
  - "Room": war room, passthrough or black (also a long press of the left menu button).

  Checked on the PC: `render-room.sh sprites` draws both pages (`sprites-wrist.png`) and takes `tilt=<degrees>`;
  `tests/wrist_panel_test.gd` and the tilted picking in `tests/table_uv_test.gd`. Not yet seen on the headset.
- **Loading:** the host shows "VCMI Loading..." before the eyes from its first frame and builds the room after it
  (`main.gd` `_ready`). Horizon OS's own splash (`vr_splash.png`, `com.oculus.ossplash`) is loaded by the system but
  did not show after Play in the launcher. Not seen yet on the headset: the first seconds before the host's first
  frame can still be black.
- **The game screen** (dialogs, town screens) is raised 0.9 m while the player sits at the table, above the shelf.
- **Changing the view:** a plaque the ray clicks: "Table view" under the 2D screen, "2D screen" over the resource bar
  at the table (`main.gd` `view_switch`). The right stick click and the wrist panel's button do the same.
- **Fog:** no fog tiles and no black. Terrain and flat objects fade into the page over about a third of a tile, with an
  uneven edge (`table_shaders.gd` `painted`). The cards stand only where the tile is seen, as before.
- **Paper:** one colour under the fog, outside the map and in the margin, with a grain. It darkens away from the
  reading candle. A ruled line frames the map. The page, its margin and the map's flat colours are one mesh and one
  draw (`MINIMAP`, `plate`): the page covers most of the view, so it is drawn once.
- **Book:** a tome 3.5 cm thick: a red leather cover, a block of pages, a bookmark ribbon.
- **Desk:** the table's figurines are cut away when the model loads (`_clear_top`; the baked light stays). A dark
  leather desk mat with a gold line covers the painted top.
- **Panels stand on a shelf** behind the book's far edge, 12 cm high, so the cards at the far edge do not hide them:
  the hero and town board on the left, the resource bar in the middle (1.5 times its size, as it is 1.4 m away), the
  tablet with the whole map on the right. The hourglass stands at the near right corner.
- **Nothing floats:** each thing rests on the mat or the shelf; the book and the hourglass darken the mat under them.
- **Cards** are cut at the table's edge by where they stand, not by where their top leans to. Before, the top of a card
  whose foot was outside the view hung in the air.
- **Decoration:** the castles, towers and flags are gone. The two candles stand at the sides.

No change to VCMI code or to the extension. The fog data and the sprite atlas are as before; the fog tiles are skipped
in the vertex shader.

## 3. Steps

| # | Step | State |
|---|---|---|
| 1 | Preview views at the game's zoom: `sprites-play` (from the chair), `sprites-play-map`, `sprites-play-low`, `sprites-desk`; `-- sprites seen` shows the whole map explored | done |
| 2 | Fog as paper | done |
| 3 | Desk: figurines cut, mat, decoration removed | done |
| 4 | Book | done |
| 5 | The map fills the table; the view keeps the table's shape | done, with tests in `table_math_test.gd` and `table_uv_test.gd` |
| 6 | Panels on the shelf | done; the panel test passes |
| 7 | `lint.sh`, `test-local.sh` | pass |
| 8 | Headset: frame time and screenshots in a game | section 5 |

## 4. Budget and risks

| Risk | Check | Fallback |
|---|---|---|
| The fog fade costs fragment time: two more texture reads per flat sprite fragment | `xr-perf.sh` on the heaviest map | read the fog in the vertex shader for objects, per fragment for terrain tiles only |
| The larger map draws more: 60 x 38 tiles of 2.5 cm, against 53 x 33 of 1.5 cm | the same | a larger default tile |
| The atlas holds fewer views at 4x when more tiles show | the log line "the atlas cannot hold the view" | it already halves the scale |
| The far edge is 1.4 m from the chair: small tiles, a shaky ray | a person in the headset (check 3 of `PHASE4.md`) | zoom in; the map follows the hero |
| The board and bar are 1.4 m away | a person in the headset | a larger `BAR_SCALE`, a board scale |
| A blank page as large as the table is bright in a dark room | a person in the headset | a darker `PAPER` |

## 5. Results

### On the PC (2026-11-12)

Renders in `quest/out/visuals/`: `02-pc-seat-table-sized-seen.png` (from the chair, the map explored),
`02-pc-seat-table-sized-day1-fog.png` (day 1), `02-pc-desk-whole-map.png` (from the side),
`02-pc-shelf-board-bar.png`.

The test capture (`quest/out/sprites-dump/sprites.bin`) was saved with a smaller view. Where it has no tiles the
renders show the minimap's flat colours or dark rectangles. The game fills these.

### On the headset (2026-11-12, Quest 3, build of this pass)

The first scenario (72 x 72 x 2, 2225 objects), tabletop mode, the head placed at the chair by the test command
`table_view 0.45 0.82` (height above the map, distance towards the chair). `quest.sh sample`, 8 rows each:

| Case | fps | App GPU time | Budget (72 Hz) |
|---|---|---|---|
| Before this pass, looking at the table | 72 | 8.8 to 9.2 ms | 13.9 ms |
| Day 1, most of the page blank | 71 to 74 | 8.9 to 10.2 ms, about 9.1 | 13.9 ms |
| Map revealed with `vcmieagles`, the table full of cards | 72 to 73 | 9.7 to 11.8 ms, about 10.5 | 13.9 ms |

Memory with the map revealed: 2.35 GB PSS, 0.94 GB graphics. No script errors, and the log has no "the atlas cannot
hold the view" line.

Screenshots: `06-quest-seat-day1.jpg`, `07-quest-seat-revealed.jpg`, `07-quest-low-revealed.jpg` (leaning in). The
scripts are `quest/out/visuals/headset-check.sh` and `headset-revealed.sh` (not in git).

Seen in the screenshots: the map fills the table, nothing pokes through, the panels stand clear above the far edge, the
day-1 patch fades into the page. Drawing the page once (it was a page plane under a map plane) took the day-1 time
from about 9.9 ms to about 9.1 ms.

### Not done, or left for a person

- Not measured: the heaviest map (252 x 252) on the table, and the view at the closest zoom. Milestone 4f does this.
- `shortcut:` the hero is brought near the player only along the table's depth. At the map's left or right edge the
  view stops at the edge, so the hero stands up to 0.75 m to the side. The levels lie side by side in the map image,
  so passing that edge would show the other level; upgrade with a level mask in the shaders if it hinders play.
- In `07-quest-seat-revealed.jpg` the right edge is blurred. It is not the map: see [`PHASE4.md`](PHASE4.md), 4f results.
- The look review, the comfort check and the ray on small tiles need a person in the headset.
- `shortcut:` the map's sprites and the paper are unshaded. They do not take the candle's colour; only the paper has a
  painted falloff.
- `shortcut:` tall cards hide what stands behind them more than in 2D, because the player looks from about 30 degrees
  above the table, not 45. If it hinders play: a higher seat, or the book tilted towards the player as on a lectern.

## 6. The battle diorama (phase 5)

Phase 5 is not built. It will use what this pass made, so both views look like one book:

- the same book, paper and desk; the battlefield's background painted on the page, the hexes as inked lines;
- stacks, obstacles and heroes as cards (the `SPRITE` shader's card pass), corpses flat;
- the battle's buttons and the stack queue on the shelf, where the map's panels stand;
- a battle is one fixed view: the whole field on the table, no pan.

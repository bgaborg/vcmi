# Phase 5: the battle diorama (plan)

The battle played on the war table, as the adventure map is in [phase 4](PHASE4.md). Look and layout: [`VISUALS.md`, section 6](VISUALS.md#6-the-battle-diorama-phase-5). Data path: [`DATA_BRIDGE.md`](DATA_BRIDGE.md) (milestone 4, battle).

As of 2026-11-14: milestone 5a is built and checked on the PC; 5b is written and builds for Android. Nothing of phase 5 has run on the headset.

## 1. What exists

- **Until phase 5 is done,** a battle runs on the 2D game screen, which comes forward before the chair when the battle window opens (phase 4, dialogs). That stays the fallback.
- **5a (done on the PC):** the battlefield on the book's page, without the game:
  - `xr/battle_math.gd`: the 2D battle's hex layout (`BattleFieldController::hexPositionLocal`: 17 x 11 hexes on an 800 x 556 picture, even rows half a hex to the right), the hex under a point, and field pixels to metres on the page. The field fills the page's depth: a hex is 7.4 cm wide.
  - `xr/battle_field.gd`: one quad over the whole page. Its shader draws the paper (or the battlefield's picture), the hexes as inked lines and each hex's state as a wash of colour (reachable, active, hovered, target) from a 17 x 11 texture: one draw call, no texture per hex. A marker card stands for each stack, in its side's colour with its count; a two-hex stack's card is twice as wide.
  - `main.gd`: the test command `battle 1` shows a sample battle on the table instead of the map; the ray lights the hex under it, and a trigger press logs it. `battle 0` brings the map back.
  - PC: `quest/tools/render-room.sh sprites battle` (`out/room-preview/sprites-battle*.png`), `xr/tests/battle_math_test.gd`.

- **5b (written 2026-11-14, builds, never run):**
  - Bridge (`VcmiBridgeApi.battle`, `hexInput`; version 13): each lifecycle tick (100 ms) publishes the battle the game shows: the stacks (unit id, hex, side, owner, count, two-hex, alive, active, creature animation name) and, in the local player's turn, the hexes the active stack can move to. Polled, not from events: the table shows what the 2D battle holds after its animations, up to a tick later.
  - Hex input: the latest hover and the clicks run in the tick as `BattleActionsController::onHexHovered` and `onHexLeftClicked`, only while the battle window is the top window and its intro is over. A click ends auto-combat first, as in 2D.
  - Godot: in tabletop mode the field replaces the map while a battle is shown (`main.gd`, `battle_field.set_battle`). The game screen stays before the chair with the 2D battle. A ray that misses the screen is the table's: it lights the hex and sends the hover; the trigger sends the click.
  - **The attack's side:** before a hover or a click the bridge puts the game's mouse in the hex (`EventDispatcher::dispatchMouseMoved`, as a mouse move), 12 pixels from its middle towards the active stack. The 2D battle attacks from the legal hex nearest the mouse (`BattleFieldController::selectNearestDirection`), so an attack from the table comes from the attacker's side. `shortcut:` the player cannot choose another side from the table; add the ray's place inside the hex to `hexInput` when that is missed.
  - **Obstacles and the dead:** hexes with an obstacle, a wall or the gate (`getAccessibility`) are published as a mask and washed dark; a dead stack's card lies flat and grey on its hex.
  - **To check first on the headset:** a move, a shot and a melee attack from the table.
  - Not done in 5b: the battlefield's picture (an image, not an animation: the bridge decodes animations only), the map's markers and path under the field (to see on the headset), spell targeting from the table (cast from the 2D screen).

- **5c to 5f (written 2026-11-14, tested on the PC with the game's own art, build for Android, never run):**
  - **Creatures (5c):** `xr/battle_cards.gd`. `main.gd` asks a worker for each creature's animation once (`VcmiData.decode_animation`); a card then shows the frames of its group, 10 a second. A frame's pixels are placed about the frame's point that stands on the hex's middle (`ANCHOR` 196, 251; the feet's line `FEET` 263; a two-hex stack 44 further back), mirrored for the defender's side.
  - **Actions (5d):** from the state's changes between two publishes: a new hex slides the card there with the moving group; fewer creatures plays the hit group; death plays the death group and keeps its last frame. The bridge flags the stack whose turn it is (`VCMI_STACK_TURN`); when an enemy of it is hurt, it plays its attack group, or its shoot group when it is more than 2.5 hexes away. No battle events receiver yet.
  - **Keys (5e):** the wrist panel's first page is "Battle" while a battle is on (`wrist_panel.gd` `BATTLE_KEYS`).
  - **Picture (5f):** the bridge publishes the background's name and hands its file's bytes over (`imageFile`); `battle_field.gd` `decode_picture` reads a PNG, a BMP or a Heroes 3 PCX on a worker. Sieges: the walls are dark hexes only.
  - **On the PC:** `quest/tools/h3-extract.py` takes animations and pictures from the Heroes 3 data on the PC into `quest/out/h3/` (not in git); `render-room.sh sprites battle` then draws the sample battle with them (`sprites battle bare`: markers on paper). `tests/battle_math_test.gd` covers the placement, the groups and the PCX reader.

## 2. Facts from the code (read 2026-11-14; check again before 5b)

- **Events:** `IBattleEventsReceiver` (`lib/callback/IBattleEventsReceiver.h`): `battleStart`, `battleStackMoved`, `battleAttack`, `battleStacksAttacked`, `battleSpellCast`, `battleUnitsChanged`, `battleObstaclesChanged`, `battleNewRound`, `battleEnd`, and more. `CClient::registerBattleInterface` gives them to an extra receiver after the 2D battle interface ([`DATA_BRIDGE.md`](DATA_BRIDGE.md)).
- **State:** `CPlayerInterface::battleInt` (static, null outside a battle) has the stacks controller (the active stack), the field controller and the battle itself (`getBattle()->battleGetAllStacks()`).
- **Input:** `battleInt->actionsController->onHexHovered(hex)` and `onHexLeftClicked(hex)` are public. The bridge is compiled into the client, so it can call them on the game thread, as it does the map's tile hover and click. No upstream change.
- **Sprites:** a stack's animation is its creature's `animDefName`; `SpriteDecode` already decodes any animation for the atlas.

## 3. Milestones

Revised 2026-11-14, after 5b. The first plan drew the creatures with the map's sprite atlas and made the game wait for Godot at every battle event. That is much new C++ in the game process which cannot run on the PC, for at most 20 stacks. The revised plan keeps the 2D battle as the master and draws from Godot what the bridge publishes, so most of it is GDScript that the PC tests and renders cover.

1. **5a, the field on the table (done on the PC).** Left for the headset: the look, and whether a ray holds a 7.4 cm hex from the chair (the far rows are about 1.3 m away).
2. **5b, the battle's state and input (written, builds, never run).** Section 1.
3. **5c, the creatures.** One card per stack, textured with its creature's own animation. Godot decodes the animation on a worker (`VcmiData.decode_animation`, as the panel's icons) and plays a group's frames on the card: the standing group, mirrored for the side that faces left, placed as `BattleStacksController::getStackPositionAtHex` places the 450 x 400 frame. The marker card stays until the frames are there, and for a creature without them.
   - `shortcut:` the game's 1x art, not xBRZ: at most 20 cards, and the atlas's upscaler is not reachable from GDScript. Use the HD pack's frames, or expose the upscaler, when the cards look coarse in the headset.
   - `shortcut:` a draw call per card (at most about 20) instead of the atlas's multimesh.
4. **5d, the actions.** From the published state, 10 times a second: a stack whose hex changed slides there with its moving group; a stack that lost creatures plays its hit group; a stack that died plays its death group and stays on its last frame. The bridge adds the last attack (attacker, target hex, shot or not) from a battle events receiver, and the attacker plays its attack or shoot group. The game does not wait for the table: the 2D battle runs at its own speed, and the table follows up to a tick later.
   - Left out: projectiles, spell effects, the turn animations.
5. **5e, the battle's keys.** A "Battle" page on the wrist panel with the game's own battle keys (wait, defend, spell book, auto-combat, retreat, surrender, the active stack's info), shown while a battle is on. The stack queue, the log and the result stay on the game screen.
6. **5f, the battlefield's picture and sieges.** The bridge decodes the battlefield's background image for the page under the hexes. A siege is playable with the walls and the gate as dark hexes (5b's mask); the walls' own pictures, the towers and the moat are left for after the first headset run.
7. **Exit, on the headset:** every battle type against the 2D battle, the look, and the budgets with seven stacks a side ([`HEADSET_CHECKLIST.md`](HEADSET_CHECKLIST.md)).

## 4. Open decisions

- **The 2D battle while the table shows it.** It cannot be hidden as the adventure map is (the tabletop window), because the battle window is the top window and its animations time the events. Recommended: leave it running on the screen at the fastest speed (planned in `DATA_BRIDGE.md`), and move the screen aside while the table shows the battle.
- **Field size.** The field fills the page (1.35 x 0.94 m). Smaller would bring the far rows nearer; decide in the headset in 5a's check.

## 5. Risks

| Risk | Check | Fallback |
|---|---|---|
| Hex input from the bridge behaves differently from mouse input (cursor state, spell targeting, tactics phase) | 5b, each action type | send pointer events to the 2D battle at the hex's pixel instead |
| The atlas cannot hold both armies' animations at 2x (a creature has about 100 large frames) | 5c, seven stacks a side | idle and move groups only at 2x, the rest at 1x; frames loaded per action |
| The table trails the 2D battle by an action | 5d | accept in 5b to 5c; 5d waits per event |

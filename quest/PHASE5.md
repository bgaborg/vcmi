# Phase 5: the battle diorama (plan)

The battle played on the war table, as the adventure map is in [phase 4](PHASE4.md). Look and layout: [`VISUALS.md`, section 6](VISUALS.md#6-the-battle-diorama-phase-5). Data path: [`DATA_BRIDGE.md`](DATA_BRIDGE.md) (milestone 4, battle).

As of 2026-11-14: milestone 5a is built and checked on the PC. Nothing of phase 5 has run on the headset.

## 1. What exists

- **Until phase 5 is done,** a battle runs on the 2D game screen, which comes forward before the chair when the battle window opens (phase 4, dialogs). That stays the fallback.
- **5a (done on the PC):** the battlefield on the book's page, without the game:
  - `xr/battle_math.gd`: the 2D battle's hex layout (`BattleFieldController::hexPositionLocal`: 17 x 11 hexes on an 800 x 556 picture, even rows half a hex to the right), the hex under a point, and field pixels to metres on the page. The field fills the page's depth: a hex is 7.4 cm wide.
  - `xr/battle_field.gd`: one quad over the whole page. Its shader draws the paper (or the battlefield's picture), the hexes as inked lines and each hex's state as a wash of colour (reachable, active, hovered, target) from a 17 x 11 texture: one draw call, no texture per hex. A marker card stands for each stack, in its side's colour with its count; a two-hex stack's card is twice as wide.
  - `main.gd`: the test command `battle 1` shows a sample battle on the table instead of the map; the ray lights the hex under it, and a trigger press logs it. `battle 0` brings the map back.
  - PC: `quest/tools/render-room.sh sprites battle` (`out/room-preview/sprites-battle*.png`), `xr/tests/battle_math_test.gd`.

## 2. Facts from the code (read 2026-11-14; check again before 5b)

- **Events:** `IBattleEventsReceiver` (`lib/callback/IBattleEventsReceiver.h`): `battleStart`, `battleStackMoved`, `battleAttack`, `battleStacksAttacked`, `battleSpellCast`, `battleUnitsChanged`, `battleObstaclesChanged`, `battleNewRound`, `battleEnd`, and more. `CClient::registerBattleInterface` gives them to an extra receiver after the 2D battle interface ([`DATA_BRIDGE.md`](DATA_BRIDGE.md)).
- **State:** `CPlayerInterface::battleInt` (static, null outside a battle) has the stacks controller (the active stack), the field controller and the battle itself (`getBattle()->battleGetAllStacks()`).
- **Input:** `battleInt->actionsController->onHexHovered(hex)` and `onHexLeftClicked(hex)` are public. The bridge is compiled into the client, so it can call them on the game thread, as it does the map's tile hover and click. No upstream change.
- **Sprites:** a stack's animation is its creature's `animDefName`; `SpriteDecode` already decodes any animation for the atlas.

## 3. Milestones

Each is built, measured and reviewed before the next, as in phase 4.

1. **5a, the field on the table (done on the PC).** Left for the headset: the look, and whether a ray holds a 7.4 cm hex from the chair (the far rows are about 1.3 m away).
2. **5b, the battle's state and input.** The bridge publishes a battle record: the battlefield's picture name, the stacks (id, side, hex, two-hex, count, creature animation, alive, facing), the active stack, the hexes it reaches and the ones it can attack. It takes a hex hover and click from Godot. Godot shows the field instead of the map while a battle is on, with marker cards. **Exit:** a battle is fought on the table with markers; the 2D battle stays visible on the screen to compare.
3. **5c, the creatures.** The stacks' animations in the sprite atlas (the map's sprites leave it for the battle), drawn by the `SPRITE` shader's card pass, idle and facing; corpses flat; obstacles; the heroes at the field's ends.
4. **5d, the actions.** Moves, attacks, shots, spells and deaths shown from the events, with the game waiting for Godot as it does for a hero's step (the 2D battle at its fastest speed, [`DATA_BRIDGE.md`](DATA_BRIDGE.md)).
5. **5e, the battle's panel.** Wait, defend, spellbook, auto-combat, retreat and surrender, the stack queue and the log on the shelf; the result window on the game screen.
6. **5f, sieges and the exit pass.** Walls, towers, the moat and the catapult; then every battle type against the 2D battle, and the budgets on the largest armies.

## 4. Open decisions

- **The 2D battle while the table shows it.** It cannot be hidden as the adventure map is (the tabletop window), because the battle window is the top window and its animations time the events. Recommended: leave it running on the screen at the fastest speed (planned in `DATA_BRIDGE.md`), and move the screen aside while the table shows the battle.
- **Field size.** The field fills the page (1.35 x 0.94 m). Smaller would bring the far rows nearer; decide in the headset in 5a's check.

## 5. Risks

| Risk | Check | Fallback |
|---|---|---|
| Hex input from the bridge behaves differently from mouse input (cursor state, spell targeting, tactics phase) | 5b, each action type | send pointer events to the 2D battle at the hex's pixel instead |
| The atlas cannot hold both armies' animations at 2x (a creature has about 100 large frames) | 5c, seven stacks a side | idle and move groups only at 2x, the rest at 1x; frames loaded per action |
| The table trails the 2D battle by an action | 5d | accept in 5b to 5c; 5d waits per event |

/*
 * VcmiBridgeApi.h, Meta Quest build: the C ABI between the game (quest/bridge, compiled into
 * libvcmiclient) and the Godot extension (quest/xr/extension). Plain C, so the two sides share no C++ types.
 * The extension finds the table with dlsym("vcmi_bridge_api") (GetProcAddress on the PC). See quest/DATA_BRIDGE.md.
 *
 * License: GNU General Public License v2.0 or later
 */
#pragma once

#include <stdint.h>

// raise on any change to the structs below; the extension refuses a table with another version
#define VCMI_BRIDGE_VERSION 25

typedef struct VcmiBridgeStats
{
	uint32_t ticks; // lifecycle ticks run on the game thread, one per 100 ms once started
	uint32_t observers; // map observers created: one per new game, load or replay pass
	uint16_t mapWidth; // of the current adventure map, 0 outside a game
	uint16_t mapHeight;
	uint8_t mapLevels;
	uint8_t inGame; // 1 while an adventure map exists
	uint8_t tabletop; // 1 while the tabletop window is over the adventure map (setTabletop): the 2D map does not draw
	uint8_t windowsAbove; // windows over the tabletop window (dialogs, battles, popups): the game screen shows them
	uint32_t tilesGeneration; // raised on each tile snapshot (new map), 0 before the first
	uint32_t fogGeneration; // raised each time the local team's fog changes
	uint32_t publishMicros; // game thread time of the last tile or fog publish
	uint32_t objectsSnapshot; // raised on each full object list (new map); 0 before the first
	uint32_t objectsSequence; // raised on each changed object record
	uint32_t objectsMicros; // game thread time of the last full object list
	uint32_t changeMicros; // game thread time of the last object change publish
	uint32_t moveSequence; // hero steps the tabletop showed (VcmiMove.sequence of the last)
	uint32_t waitMicros; // how long the game waited for the last of them
	uint32_t moveTimeouts; // steps whose confirmation did not come in time
	uint32_t inputsRun; // tile inputs (tileInput) the game ran
	uint32_t inputsDropped; // tile inputs dropped: no tabletop, a window above it, no army, or off the map
	uint32_t selected; // object id of the selected hero or town, VCMI_NONE when none
	uint32_t pathGeneration; // raised when the selected hero's path changes (path)
} VcmiBridgeStats;

#define VCMI_NONE 0xffffffffu

// one tile of the selected hero's path, as the 2D map draws it: the tiles the hero walks, from the first step on
typedef struct VcmiPathNode
{
	uint16_t x, y;
	uint8_t z;
	uint8_t turns; // turns until the hero gets there: 0 this turn
	uint16_t pad;
} VcmiPathNode; // 8 bytes

#define VCMI_TILE_HOVER 0
#define VCMI_TILE_CLICK 1 // left click
#define VCMI_TILE_POPUP 2 // right button down: the info popup of the tile
#define VCMI_TILE_POPUP_END 3 // right button up: closes it

// what the 2D side panel shows (quest/PHASE4.md 4d), for the table's own panel; names in UTF-8, cut to fit
typedef struct VcmiPanelHero
{
	uint32_t id; // object id
	uint16_t portrait; // frame of PortraitsSmall (getIconIndex)
	uint16_t movement, maxMovement; // movement points left this turn, and a full turn's
	uint16_t mana, maxMana;
	uint8_t sleeping;
	uint8_t pad;
	char name[48];
} VcmiPanelHero; // 64 bytes

typedef struct VcmiPanelTown
{
	uint32_t id; // object id
	uint16_t icon; // frame of ITPA, as the 2D town list shows it
	uint16_t pad;
	char name[48];
} VcmiPanelTown; // 56 bytes

#define VCMI_PANEL_HEROES 16
#define VCMI_PANEL_TOWNS 48
#define VCMI_PANEL_RESOURCES 8

typedef struct VcmiPanel
{
	uint32_t generation; // raised when anything below changes; 0: no game
	int32_t resources[VCMI_PANEL_RESOURCES]; // by resource id: wood, mercury, ore, sulfur, crystal, gems, gold, ...
	uint16_t day, week, month; // day of the week, week of the month, month
	uint8_t heroCount, townCount; // the lists as the 2D panel orders them, cut to the arrays
	char date[64]; // as the 2D resource bar writes it
	VcmiPanelHero heroes[VCMI_PANEL_HEROES];
	VcmiPanelTown towns[VCMI_PANEL_TOWNS];
} VcmiPanel;

// one stack of the battle the game shows (quest/PHASE5.md 5b), as the 2D battle has it after its animations
typedef struct VcmiBattleStack
{
	uint32_t id; // unit id
	uint32_t count; // creatures in it
	uint16_t hex; // of its front half: column + 17 * row, as BattleHex
	uint8_t side; // 0 attacker, 1 defender
	uint8_t owner; // player 0-7, 255 neutral
	uint8_t flags; // VCMI_STACK_*
	uint8_t pad;
	uint16_t creature; // its creature's id, for creatureSounds; 65535 unknown
	char animation[32]; // the creature's battle animation (an AnimationPath), cut to fit
	char missile[24]; // a shooter's missile animation, empty for others
	int16_t x, y; // VCMI_STACK_TURRET: the corner of its 450 x 400 frame on the battlefield, as the 2D battle draws it
} VcmiBattleStack; // 76 bytes
#define VCMI_STACK_WIDE 1 // two hexes: the other one is behind it, towards its side's edge
#define VCMI_STACK_ALIVE 2
#define VCMI_STACK_ACTIVE 4 // the stack the local player chooses an action for
#define VCMI_STACK_TURRET 16 // the shooter in a besieged town's tower: it stands on no hex (hex is 0), at x, y
#define VCMI_STACK_TURN 8 // the stack whose turn it is, any player's (battleActiveUnit)

#define VCMI_ACTION_ATTACK 1
#define VCMI_ACTION_SHOT 2
#define VCMI_ACTION_SPELL 3
#define VCMI_ACTION_TARGETS 16
#define VCMI_RAY_LINES 8

// a piece of a besieged town's walls as the 2D battle draws it now: the picture named by the background's name with
// its last four letters ("BACK") replaced by `name`, its corner at x, y of the battlefield
typedef struct VcmiWallPiece
{
	char name[12];
	int16_t x, y;
} VcmiWallPiece; // 16 bytes
#define VCMI_WALL_PIECES 20

#define VCMI_BATTLE_STACKS 64
#define VCMI_BATTLE_HEXES 187

typedef struct VcmiBattle
{
	uint32_t generation; // raised when anything below changes; 0: the game is writing, try next frame
	uint8_t shown; // 1 while the game shows a battle
	uint8_t myTurn; // the local player chooses the active stack's action
	uint8_t stackCount;
	uint8_t soundVolume; // the game's sound effects volume, 0-100 (general.sound): the table's sounds follow it
	uint8_t reach[24]; // bit `hex`: the active stack can move there (the local player's turn only)
	uint8_t blocked[24]; // bit `hex`: an obstacle, a wall or the gate, or not part of this battlefield
	char picture[48]; // the battlefield's background, a name for imageFile; empty when unknown
	// the last attack or spell of this battle, from the game's battle events; actionSequence 0: none yet
	uint32_t actionSequence; // raised on each
	uint32_t actionStack; // the attacking or casting stack's unit id; VCMI_NONE when a hero cast the spell
	uint32_t actionTarget; // the first hurt or affected stack's unit id, VCMI_NONE when none
	uint16_t actionHex; // a spell's target hex, VCMI_BATTLE_HEXES and more when it has none
	uint8_t actionKind; // VCMI_ACTION_*
	uint8_t wallCount; // a siege's wall pieces, in drawing order; 0 in the field
	char heroes[2][32]; // the attacker's and the defender's hero: its battle animation, empty without a hero
	char actionEffect[32]; // a spell's own animation, played on what it affects; empty when it has none
	uint8_t actionSide; // a spell cast by a hero: its side (0 attacker, 1 defender); else 255
	uint8_t actionTargetCount; // of actionTargets
	uint8_t actionRayCount; // of actionRay: a shot drawn as a ray instead of a missile (CCreature projectileRay)
	uint8_t actionOnHex; // 1: actionEffect is the spell's `hit` animation, played once on its hex (no hex: the whole field)
	char actionSound[24]; // a spell's cast sound, a name for soundFile; empty when it has none
	uint32_t actionTargets[VCMI_ACTION_TARGETS]; // every stack a spell affects (unit ids), in its order; cut to fit
	uint8_t actionRay[VCMI_RAY_LINES][8]; // each line of the ray: RGBA at the shooter, RGBA at the target
	VcmiWallPiece walls[VCMI_WALL_PIECES];
	VcmiBattleStack stacks[VCMI_BATTLE_STACKS];
} VcmiBattle;

// a hero step the tabletop shows: the game waits until Godot confirms it (confirmMove) or durationMs + 200 ms pass. The
// object's record already holds the destination. Positions are anchor tiles, as VcmiObject's
typedef struct VcmiMove
{
	uint32_t sequence; // raised on each step; 0 before the first
	uint32_t object; // the moving object id: the hero, or its boat
	uint16_t fromX, fromY, toX, toY;
	uint8_t fromZ, toZ;
	uint16_t durationMs; // as the 2D map takes it: adventure.heroMoveTime, or enemyMoveTime for other players
} VcmiMove; // 20 bytes

// one map object, as the 2D map draws it, at index `id` of the object list; the list holds every object, in the fog
// or not: the reader hides those whose anchor and visitable tiles are both in the fog
typedef struct VcmiObject
{
	uint32_t id; // the game's object id, which is also its index in the list
	uint16_t x, y; // anchor tile: the bottom right of the object's sprite, as the game places it
	uint8_t z;
	uint8_t owner; // player 0-7, 255 neutral, 254 unflaggable; a boat with a hero: the hero's owner
	uint8_t group; // animation group: the facing of heroes and boats, else 0
	uint8_t visit; // visitable tile = anchor - (visit >> 4, visit & 15)
	uint16_t animation; // index into the animation names (VcmiBridgeApi.animation)
	uint16_t flags; // VCMI_OBJECT_*
	// a boat with a hero: its flag in the hero's colour and its waves, as index + 1 into the animation names; 0: none
	uint16_t flagAnimation, overlayAnimation;
} VcmiObject; // 20 bytes
#define VCMI_OBJECT_HERO 1
#define VCMI_OBJECT_BOAT 2
#define VCMI_OBJECT_TOWN 4
#define VCMI_OBJECT_FLAGGABLE 8 // drawn with the owner's colour
#define VCMI_OBJECT_VISITABLE 16
#define VCMI_OBJECT_PRESENT 32 // a drawn object; a record without it is an empty slot (no object, or erased)
#define VCMI_OBJECT_HIDDEN 64 // a hero in a garrison or a boat: the 2D map does not draw it

typedef struct VcmiObjectList
{
	uint32_t snapshot; // 0: nothing copied (no map, buffer too small, or the game is writing: try next frame)
	uint32_t sequence; // the list includes every change up to this one
	uint32_t count; // records in the list
	uint32_t animations; // animation names, indices 0 to animations - 1; a new snapshot starts the table again
} VcmiObjectList;

typedef struct VcmiObjectChanges
{
	uint32_t sequence; // the changes copied run up to this one; 0 when nothing was copied
	uint32_t count; // records copied (one per change, so an object can appear more than once: apply in order)
	uint32_t animations; // as VcmiObjectList
	uint8_t resync; // 1: the changes asked for are gone (another snapshot, or too many): take the whole list
	uint8_t pad[3];
} VcmiObjectChanges;

// one tile as the game stores it; terrain, river and road are the game's ids (0: no river, no road). flips: the game's
// extTileFlags, 2 bits each for terrain, river and road (bits 0-1, 2-3, 4-5): 1 mirrored left-right, 2 top-bottom
typedef struct VcmiTile
{
	uint8_t terrain, terrainView, river, riverDir, road, roadDir, flags, flips; // flags: VCMI_TILE_*
} VcmiTile;
#define VCMI_LAYER_TERRAIN 0
#define VCMI_LAYER_RIVER 1
#define VCMI_LAYER_ROAD 2
#define VCMI_TILE_BLOCKED 1
#define VCMI_TILE_VISITABLE 2

// tiles and fog are indexed as the game stores them: z * width * height + x * height + y (x-major)
typedef struct VcmiGrid
{
	uint32_t generation; // 0: nothing copied (no map, buffer too small, or the game is writing: try next frame)
	uint16_t width, height;
	uint8_t levels;
	uint8_t pad[3];
} VcmiGrid;

#define VCMI_TERRAIN_COLOURS 256

// one frame of a map object animation (quest/MILESTONE_3B.md); pixels in VcmiAnimationData.data at offset, size bytes
#define VCMI_FRAME_INDEXED \
	0 // width * height palette indices: 0 clear, 1 and 4 shadow, 2 and 3 shadow when the palette
		// has the H3 shadow colours there, 5 owner flag (ScalableImage.cpp:205-222)
#define VCMI_FRAME_PNG \
	1 // a PNG file at its full size (left, top 0), shadow in its alpha; the owner flag mask,
		// when there is one, is a second PNG at overlayOffset (its alpha)
typedef struct VcmiFrame
{
	uint16_t group, frame;
	uint16_t width, height;
	int16_t left, top; // offset of the pixels in the full frame
	uint16_t fullWidth, fullHeight;
	uint32_t offset, size;
	uint32_t overlayOffset, overlaySize; // VCMI_FRAME_PNG only; size 0 when none
	uint8_t format;
	uint8_t pad[3];
} VcmiFrame; // 36 bytes

typedef struct VcmiAnimationData
{
	const VcmiFrame * frames;
	const uint8_t * data;
	const uint8_t * palette; // 256 RGB entries of the .def
	uint32_t frameCount, dataSize;
} VcmiAnimationData;

typedef struct VcmiBridgeApi
{
	uint32_t version;
	// starts the lifecycle task; safe to call more than once and from any thread
	void (*start)(void);
	// copies the current stats; any thread
	void (*stats)(VcmiBridgeStats * out);
	// copies the tile snapshot (width * height * levels records) and, per terrain id, the game's minimap colours
	// as RGBA bytes: colours[2 * id] unblocked, colours[2 * id + 1] blocked (VCMI_TERRAIN_COLOURS * 2 entries);
	// never waits for the game, any thread
	void (*tiles)(VcmiTile * out, uint32_t capacity, uint32_t * colours, VcmiGrid * grid);
	// copies the local team's fog, 1 byte per tile, nonzero where visible; never waits, any thread
	void (*fog)(uint8_t * out, uint32_t capacity, VcmiGrid * grid);
	// copies the object list (list->count records); never waits, any thread
	void (*objects)(VcmiObject * out, uint32_t capacity, VcmiObjectList * list);
	// copies the current records of the objects changed after sequence `since` of snapshot `snapshot`; never waits,
	// any thread
	void (*objectChanges)(uint32_t snapshot, uint32_t since, VcmiObject * out, uint32_t capacity, VcmiObjectChanges * changes);
	// copies the name of animation `index` (an AnimationPath, NUL-terminated, cut to capacity) and returns its
	// length, 0 when unknown or the game is writing; any thread
	uint32_t (*animation)(uint32_t index, char * out, uint32_t capacity);
	// decodes animation `name` (as `animation` gives it) into frames and returns their count, 0 when it is missing or
	// no game is loaded; reads the game's files (milliseconds), so call it from a worker thread. `out` points into
	// storage of the calling thread, valid until its next call
	uint32_t (*decodeAnimation)(const char * name, VcmiAnimationData * out);
	// 1: the tabletop shows the map, so the game keeps its own empty window over the adventure map (the 2D map stops
	// drawing and animating) and waits for Godot's hero steps; 0: the 2D map again. Applied by the next lifecycle tick;
	// any thread
	void (*setTabletop)(uint8_t shown);
	// copies the last hero step the tabletop showed; any thread
	void (*move)(VcmiMove * out);
	// Godot has shown step `sequence`: the game goes on; any thread
	void (*confirmMove)(uint32_t sequence);
	// input on tile x, y of level z from the tabletop (VCMI_TILE_*), run by the next lifecycle tick as the 2D map's
	// own tile handlers; only the latest hover is kept. Dropped while no tabletop window is shown or a window is over
	// it. Any thread
	void (*tileInput)(uint16_t x, uint16_t y, uint8_t z, uint8_t kind);
	// copies the selected hero's path (stats.pathGeneration) and returns its node count; copies nothing when capacity
	// is smaller. VCMI_NONE while the game is writing: try next frame. Never waits, any thread
	uint32_t (*path)(VcmiPathNode * out, uint32_t capacity);
	// copies how the 2D map draws the tiles of terrain, river or road `id` (VCMI_LAYER_*) and returns its length, 0
	// when there is none (no river, no road, an unknown id) or no game: "<file>#<mode>[,<start>:<length>]...", the
	// animation (its frame is the tile's view or direction), the mode (o: opaque, k: palette index 0 clear) and the
	// palette ranges that rotate by one colour every 180 ms (paletteAnimation). Any thread
	uint32_t (*tileAnimation)(uint8_t layer, uint8_t id, char * out, uint32_t capacity);
	// copies the side panel's data (VcmiPanel); never waits (generation 0 while the game writes: try next frame).
	// Any thread
	void (*panel)(VcmiPanel * out);
	// selects the local player's hero or town `id` as a click in the 2D hero or town list does; with `open` 1, opens
	// its hero or town window instead. Run by the next lifecycle tick, dropped while a window is over the tabletop.
	// Any thread
	void (*selectObject)(uint32_t id, uint8_t open);
	// copies the battle the game shows (VcmiBattle); never waits (generation 0 while the game writes). Any thread
	void (*battle)(VcmiBattle * out);
	// input on a battlefield hex from the tabletop (VCMI_TILE_HOVER or VCMI_TILE_CLICK), run by the next lifecycle
	// tick as the 2D battlefield's own hover and click; only the latest hover is kept. Dropped outside a battle or
	// while a window is over the battle. Any thread
	void (*hexInput)(uint16_t hex, uint8_t kind);
	// the bytes of picture `name` (VcmiBattle.picture) as the game's files hold it: a PNG, a BMP or a Heroes 3 PCX
	// (width * height palette indices and a palette, or BGR); returns their count, 0 when it is missing or no game is
	// loaded. Reads the game's files, so call it from a worker thread. `out` points into storage of the calling
	// thread, valid until its next call
	uint32_t (*imageFile)(const char * name, const uint8_t ** out);
	// the same for sound `name` (VcmiBattle.actionSound, creatureSounds): a WAV or an Ogg file as the game's files hold
	// it. Worker thread
	uint32_t (*soundFile)(const char * name, const uint8_t ** out);
	// copies creature `creature`'s battle sounds (VcmiBattleStack.creature), each a name for soundFile or empty, joined
	// by '|': attack, defend, killed, move, shoot, cast, wince, startMoving, endMoving. Returns the length, 0 for an
	// unknown creature or no game. Any thread
	uint32_t (*creatureSounds)(uint16_t creature, char * out, uint32_t capacity);
	// 1 while the table shows the battle: the 2D battle runs at its fastest speed (battle.speedFactor 18, the player's
	// own kept in a file and put back after a crash) and the game's sound effects are muted, as Godot plays them on the
	// table. Run by the next lifecycle tick. Any thread
	void (*setTableBattle)(uint8_t shown);

	// The PC build only (quest/bridge/PcHost.cpp; null on Android, where the game's own activity runs it): the Godot
	// host loads the game library itself and runs the game offscreen, as the Android plugin runs it on a virtual display.
	// Runs the game on the calling thread until it quits (the client's main) and returns its exit code; its window gets
	// width x height pixels
	int (*pcMain)(int argc, char ** argv, uint32_t width, uint32_t height);
	// copies the game window's last frame as RGBA bytes into out (width * height * 4, nothing when capacity is smaller)
	// and returns 1, 0 while there is none yet; sets width and height in either case. Asks the game thread for the next
	// one. Any thread
	uint8_t (*pcFrame)(uint8_t * out, uint32_t capacity, uint32_t * width, uint32_t * height);
	// the pointer at window pixel x, y; button 0 only moves it, 1 (left) or 2 (right, as MotionEvent's buttons) also
	// presses or releases. Any thread
	void (*pcMouse)(float x, float y, uint8_t button, uint8_t pressed);
	// an Android key code (as VcmiBridge.key takes) pressed or released. Any thread
	void (*pcKey)(int32_t androidKeycode, uint8_t pressed);
	// the gamepad, as VcmiBridge.gamepadButton / gamepadAxis take it: a KeyEvent.KEYCODE_BUTTON_* code pressed or
	// released; axis 0..3 (left x, left y, right x, right y) at -1..1, positive y down. Any thread
	void (*pcButton)(int32_t androidKeycode, uint8_t pressed);
	void (*pcAxis)(int32_t axis, float value);
	// UTF-8 text typed into the focused text field (chat, cheats, save names), as an IME would. Any thread
	void (*pcText)(const char * utf8);
} VcmiBridgeApi;

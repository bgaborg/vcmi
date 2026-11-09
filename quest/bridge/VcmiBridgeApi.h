/*
 * VcmiBridgeApi.h, Meta Quest build: the C ABI between the game (quest/bridge, compiled into
 * libvcmiclient) and the Godot extension (quest/xr/extension). Plain C, so the two sides share no C++ types.
 * The extension finds the table with dlsym("vcmi_bridge_api"). See quest/DATA_BRIDGE.md.
 *
 * License: GNU General Public License v2.0 or later
 */
#pragma once

#include <stdint.h>

// raise on any change to the structs below; the extension refuses a table with another version
#define VCMI_BRIDGE_VERSION 6

typedef struct VcmiBridgeStats
{
	uint32_t ticks;      // lifecycle ticks run on the game thread, one per 100 ms once started
	uint32_t observers;  // map observers created: one per new game, load or replay pass
	uint16_t mapWidth;   // of the current adventure map, 0 outside a game
	uint16_t mapHeight;
	uint8_t mapLevels;
	uint8_t inGame;      // 1 while an adventure map exists
	uint8_t tabletop;    // 1 while the tabletop window is over the adventure map (setTabletop): the 2D map does not draw
	uint8_t pad;
	uint32_t tilesGeneration; // raised on each tile snapshot (new map), 0 before the first
	uint32_t fogGeneration;   // raised each time the local team's fog changes
	uint32_t publishMicros;   // game thread time of the last tile or fog publish
	uint32_t objectsSnapshot;   // raised on each full object list (new map); 0 before the first
	uint32_t objectsSequence;   // raised on each changed object record
	uint32_t objectsMicros;     // game thread time of the last full object list
	uint32_t changeMicros;      // game thread time of the last object change publish
	uint32_t moveSequence;      // hero steps the tabletop showed (VcmiMove.sequence of the last)
	uint32_t waitMicros;        // how long the game waited for the last of them
	uint32_t moveTimeouts;      // steps whose confirmation did not come in time
} VcmiBridgeStats;

// a hero step the tabletop shows: the game waits until Godot confirms it (confirmMove) or durationMs + 200 ms pass. The
// object's record already holds the destination. Positions are anchor tiles, as VcmiObject's
typedef struct VcmiMove
{
	uint32_t sequence;   // raised on each step; 0 before the first
	uint32_t object;     // the moving object id: the hero, or its boat
	uint16_t fromX, fromY, toX, toY;
	uint8_t fromZ, toZ;
	uint16_t durationMs; // as the 2D map takes it: adventure.heroMoveTime, or enemyMoveTime for other players
} VcmiMove; // 20 bytes

// one map object, as the 2D map draws it, at index `id` of the object list; the list holds every object, in the fog
// or not: the reader hides those whose anchor and visitable tiles are both in the fog
typedef struct VcmiObject
{
	uint32_t id;       // the game's object id, which is also its index in the list
	uint16_t x, y;     // anchor tile: the bottom right of the object's sprite, as the game places it
	uint8_t z;
	uint8_t owner;     // player 0-7, 255 neutral, 254 unflaggable; a boat with a hero: the hero's owner
	uint8_t group;     // animation group: the facing of heroes and boats, else 0
	uint8_t visit;     // visitable tile = anchor - (visit >> 4, visit & 15)
	uint16_t animation; // index into the animation names (VcmiBridgeApi.animation)
	uint16_t flags;    // VCMI_OBJECT_*
} VcmiObject;
#define VCMI_OBJECT_HERO 1
#define VCMI_OBJECT_BOAT 2
#define VCMI_OBJECT_TOWN 4
#define VCMI_OBJECT_FLAGGABLE 8 // drawn with the owner's colour
#define VCMI_OBJECT_VISITABLE 16
#define VCMI_OBJECT_PRESENT 32 // a drawn object; a record without it is an empty slot (no object, or erased)
#define VCMI_OBJECT_HIDDEN 64  // a hero in a garrison or a boat: the 2D map does not draw it

typedef struct VcmiObjectList
{
	uint32_t snapshot;   // 0: nothing copied (no map, buffer too small, or the game is writing: try next frame)
	uint32_t sequence;   // the list includes every change up to this one
	uint32_t count;      // records in the list
	uint32_t animations; // animation names, indices 0 to animations - 1; a new snapshot starts the table again
} VcmiObjectList;

typedef struct VcmiObjectChanges
{
	uint32_t sequence;   // the changes copied run up to this one; 0 when nothing was copied
	uint32_t count;      // records copied (one per change, so an object can appear more than once: apply in order)
	uint32_t animations; // as VcmiObjectList
	uint8_t resync;      // 1: the changes asked for are gone (another snapshot, or too many): take the whole list
	uint8_t pad[3];
} VcmiObjectChanges;

// one tile as the game stores it; terrain, river and road are the game's ids
typedef struct VcmiTile
{
	uint8_t terrain, terrainView, river, riverDir, road, roadDir, flags, pad; // flags: VCMI_TILE_*
} VcmiTile;
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
#define VCMI_FRAME_INDEXED 0 // width * height palette indices: 0 clear, 1 and 4 shadow, 2 and 3 shadow when the palette
                             // has the H3 shadow colours there, 5 owner flag (ScalableImage.cpp:205-222)
#define VCMI_FRAME_PNG 1     // a PNG file at its full size (left, top 0), shadow in its alpha; the owner flag mask,
                             // when there is one, is a second PNG at overlayOffset (its alpha)
typedef struct VcmiFrame
{
	uint16_t group, frame;
	uint16_t width, height;
	int16_t left, top;            // offset of the pixels in the full frame
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
} VcmiBridgeApi;

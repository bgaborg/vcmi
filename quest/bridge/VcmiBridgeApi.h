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
#define VCMI_BRIDGE_VERSION 2

typedef struct VcmiBridgeStats
{
	uint32_t ticks;      // lifecycle ticks run on the game thread, one per 100 ms once started
	uint32_t observers;  // map observers created: one per new game, load or replay pass
	uint16_t mapWidth;   // of the current adventure map, 0 outside a game
	uint16_t mapHeight;
	uint8_t mapLevels;
	uint8_t inGame;      // 1 while an adventure map exists
	uint16_t pad;
	uint32_t tilesGeneration; // raised on each tile snapshot (new map), 0 before the first
	uint32_t fogGeneration;   // raised each time the local team's fog changes
	uint32_t publishMicros;   // game thread time of the last tile or fog publish
} VcmiBridgeStats;

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
} VcmiBridgeApi;

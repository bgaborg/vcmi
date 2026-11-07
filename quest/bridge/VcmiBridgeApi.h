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
#define VCMI_BRIDGE_VERSION 1

typedef struct VcmiBridgeStats
{
	uint32_t ticks;      // lifecycle ticks run on the game thread, one per 100 ms once started
	uint32_t observers;  // map observers created: one per new game, load or replay pass
	uint16_t mapWidth;   // of the current adventure map, 0 outside a game
	uint16_t mapHeight;
	uint8_t mapLevels;
	uint8_t inGame;      // 1 while an adventure map exists
	uint16_t pad;
} VcmiBridgeStats;

typedef struct VcmiBridgeApi
{
	uint32_t version;
	// starts the lifecycle task; safe to call more than once and from any thread
	void (*start)(void);
	// copies the current stats; any thread
	void (*stats)(VcmiBridgeStats * out);
} VcmiBridgeApi;

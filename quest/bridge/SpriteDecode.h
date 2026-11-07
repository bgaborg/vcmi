/*
 * SpriteDecode.h, Meta Quest build: decodes a map object animation (.def) into 8-bit palette indices, one
 * frame after the other, with its palette (quest/MILESTONE_3B.md). Uses VCMI's CDefFile with its own loader: no SDL
 * surface, no renderer: it reads only through CResourceHandler, so it runs on any thread while a game is loaded, not during a
 * mod reload. Shared by the bridge and quest/bench.
 *
 * License: GNU General Public License v2.0 or later
 */
#pragma once

#include "VcmiBridgeApi.h"

/// one frame of an animation: where its pixels start in the pixel buffer, its size and its offset in the full frame
struct SpriteFrame
{
	uint32_t offset;
	uint16_t width, height;
	int16_t left, top;
	uint16_t fullWidth, fullHeight;
	uint16_t group, frame;
};

struct SpriteAnimation
{
	std::vector<SpriteFrame> frames;
	std::vector<uint8_t> pixels; // palette indices, row by row, frame after frame
	std::array<uint8_t, 768> palette{}; // RGB of the .def palette
	bool def = false;  // a .def file was found
	bool json = false; // a mod's JSON layout exists too: its frames (PNG or other .def) are not decoded here
	uint32_t overruns = 0; // rows whose last run went past the row's end (cut, as the 2D map's loader does)
};

/// `name` as VcmiObject.animation names it (ObjectTemplate::animationFile, original name); empty frames when missing
SpriteAnimation decodeAnimation(const std::string & name);

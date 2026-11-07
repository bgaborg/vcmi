/*
 * SpriteDecode.h, Meta Quest build: decodes a map object animation into its frames as the 2D map finds them
 * (quest/MILESTONE_3B.md): the .def frames as 8-bit palette indices with the palette, and the frames a mod's JSON
 * layout replaces as the PNG files' bytes, with their flag mask PNG. Uses VCMI's CDefFile with its own loader: no SDL
 * surface, no renderer: it reads only through CResourceHandler, so it runs on any thread while a game is loaded, not
 * during a mod reload. Shared by the bridge and quest/bench.
 *
 * License: GNU General Public License v2.0 or later
 */
#pragma once

#include "VcmiBridgeApi.h"

/// one frame of an animation; VcmiFrame on the bridge
using SpriteFrame = VcmiFrame;

struct SpriteAnimation
{
	std::vector<SpriteFrame> frames; // by group and frame; a frame a layout leaves out (a gap) is missing, not empty
	std::vector<uint8_t> data; // per frame: palette indices row by row, or the bytes of a PNG file
	std::array<uint8_t, 768> palette{}; // RGB of the .def palette
	bool def = false;  // a .def file was found
	bool json = false; // a mod's JSON layout replaces frames (with `file` or `sequences`)
	uint32_t overruns = 0; // rows whose last run went past the row's end (cut, as the 2D map's loader does)
};

/// `name` as VcmiObject.animation names it (ObjectTemplate::animationFile, original name); no frames when missing
SpriteAnimation decodeAnimation(const std::string & name);

// VcmiData.cpp, Meta Quest build: the Godot side of the data bridge (quest/DATA_BRIDGE.md).
// Finds the table the game exports (quest/bridge/VcmiBridgeApi.h) and hands its data to GDScript.
// License: GNU General Public License v2.0 or later

#include "../../bridge/VcmiBridgeApi.h"

#include <chrono>
#include <cstring>
#include <vector>

#include <dlfcn.h>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace
{
// the game library loads after Godot, so it is looked up again until found; the table lives as long as the process
const VcmiBridgeApi * api = nullptr;
bool refused = false;
}

class VcmiData : public RefCounted
{
	GDCLASS(VcmiData, RefCounted)

protected:
	static void _bind_methods()
	{
		ClassDB::bind_method(D_METHOD("connect_bridge"), &VcmiData::connect_bridge);
		ClassDB::bind_method(D_METHOD("stats"), &VcmiData::stats);
		ClassDB::bind_method(D_METHOD("update"), &VcmiData::update);
		ClassDB::bind_method(D_METHOD("terrain_image"), &VcmiData::terrain_image);
		ClassDB::bind_method(D_METHOD("fog_image"), &VcmiData::fog_image);
		BIND_CONSTANT(TERRAIN_CHANGED);
		BIND_CONSTANT(FOG_CHANGED);
		BIND_CONSTANT(IN_GAME);
	}

	uint32_t seenTiles = 0;
	uint32_t seenFog = 0;
	int64_t consumeMicros = 0; // of the last update that built an image
	std::vector<VcmiTile> tiles;
	PackedByteArray fog;
	uint32_t colours[VCMI_TERRAIN_COLOURS * 2] = {};
	Ref<Image> terrain;
	Ref<Image> fogMap;

	// the game stores tiles x-major (VcmiGrid); images are rows of y, with the levels side by side
	template<typename Pixel>
	static PackedByteArray toRows(const VcmiGrid & grid, int bytesPerPixel, Pixel pixel)
	{
		const int64_t width = int64_t(grid.width) * grid.levels;
		PackedByteArray data;
		data.resize(width * grid.height * bytesPerPixel);
		uint8_t * out = data.ptrw();
		size_t i = 0;
		for(int z = 0; z < grid.levels; z++)
			for(int x = 0; x < grid.width; x++)
				for(int y = 0; y < grid.height; y++, i++)
					pixel(i, out + ((int64_t(y) * width + int64_t(z) * grid.width + x) * bytesPerPixel));
		return data;
	}

	// one try per call: the game may be writing, then the next frame gets it
	template<typename Buffer, typename Copy>
	static bool fetch(Buffer & buffer, VcmiGrid & grid, Copy copy)
	{
		copy(buffer, grid);
		const int64_t count = int64_t(grid.width) * grid.height * grid.levels;
		if(grid.generation == 0 && count > int64_t(buffer.size()))
		{
			buffer.resize(count);
			copy(buffer, grid);
		}
		return grid.generation != 0;
	}

public:
	enum { TERRAIN_CHANGED = 1, FOG_CHANGED = 2, IN_GAME = 4 };

	/// true once the game's table is found and its lifecycle task started; call again until then
	bool connect_bridge()
	{
		if(api)
			return true;
		if(refused)
			return false;
		// RTLD_NOLOAD: only a library the game activity already loaded; the handle is kept, as the library is
		void * game = dlopen("libvcmiclient_arm64-v8a.so", RTLD_NOW | RTLD_NOLOAD);
		if(!game)
			return false;
		const auto * table = static_cast<const VcmiBridgeApi *>(dlsym(game, "vcmi_bridge_api"));
		if(!table || table->version != VCMI_BRIDGE_VERSION)
		{
			refused = true;
			UtilityFunctions::push_error("VCMI bridge: ", table ? "version " + String::num_int64(table->version) : String("no table"),
				" in the game, expected version ", VCMI_BRIDGE_VERSION, "; bridge off");
			return false;
		}
		api = table;
		api->start();
		UtilityFunctions::print("VCMI bridge: connected, version ", api->version);
		return true;
	}

	/// empty until connected
	Dictionary stats() const
	{
		Dictionary result;
		if(!api)
			return result;
		VcmiBridgeStats s;
		api->stats(&s);
		result["ticks"] = s.ticks;
		result["observers"] = s.observers;
		result["in_game"] = s.inGame != 0;
		result["map"] = Vector3i(s.mapWidth, s.mapHeight, s.mapLevels);
		result["tiles_generation"] = s.tilesGeneration;
		result["fog_generation"] = s.fogGeneration;
		result["publish_us"] = s.publishMicros;
		result["consume_us"] = consumeMicros;
		return result;
	}

	/// once per frame: fetches what the game published since the last call; TERRAIN_CHANGED | FOG_CHANGED when the images
	/// are new, IN_GAME while an adventure map exists
	int update()
	{
		if(!api)
			return 0;
		VcmiBridgeStats s;
		api->stats(&s);
		const int inGame = s.inGame ? IN_GAME : 0;
		if(s.tilesGeneration == seenTiles && s.fogGeneration == seenFog)
			return inGame;
		const auto from = std::chrono::steady_clock::now();
		int changed = 0;
		VcmiGrid grid;
		if(s.tilesGeneration != seenTiles && fetch(tiles, grid, [this](auto & buffer, VcmiGrid & g) { api->tiles(buffer.data(), buffer.size(), colours, &g); }))
		{
			seenTiles = grid.generation;
			terrain = Image::create_from_data(grid.width * grid.levels, grid.height, false, Image::FORMAT_RGBA8,
				toRows(grid, 4, [this](size_t i, uint8_t * out)
				{
					const VcmiTile & tile = tiles[i];
					// as the game's minimap: blocked colour on tiles an object blocks and nothing can be visited
					const bool blocked = (tile.flags & VCMI_TILE_BLOCKED) && !(tile.flags & VCMI_TILE_VISITABLE);
					std::memcpy(out, &colours[2 * tile.terrain + (blocked ? 1 : 0)], 4);
					out[3] = 255;
				}));
			terrain->generate_mipmaps();
			changed |= TERRAIN_CHANGED;
		}
		if(s.fogGeneration != seenFog && fetch(fog, grid, [](auto & buffer, VcmiGrid & g) { api->fog(buffer.ptrw(), buffer.size(), &g); }))
		{
			seenFog = grid.generation;
			fog.resize(int64_t(grid.width) * grid.height * grid.levels); // a smaller map than the one before
			// as the game stores it, without reordering (that took 0.3-0.5 ms on the heaviest map): one row per x of each
			// level, the tiles of a column along it, values 0 or 1. No mipmaps: on the table it is barely minified.
			fogMap = Image::create_from_data(grid.height, grid.width * grid.levels, false, Image::FORMAT_L8, fog);
			changed |= FOG_CHANGED;
		}
		if(changed)
			consumeMicros = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
		return changed | inGame;
	}

	/// the minimap colour of each tile, the map levels side by side; null before the first update with a map
	Ref<Image> terrain_image() const { return terrain; }
	/// 1 (of 255) where the local team sees; x-major: terrain_image with the axes swapped
	Ref<Image> fog_image() const { return fogMap; }
};

namespace
{
void initialize(ModuleInitializationLevel level)
{
	if(level == MODULE_INITIALIZATION_LEVEL_SCENE)
		GDREGISTER_CLASS(VcmiData);
}

void uninitialize(ModuleInitializationLevel)
{
}
}

extern "C" GDExtensionBool GDE_EXPORT vcmi_xr_init(GDExtensionInterfaceGetProcAddress get_proc_address,
	const GDExtensionClassLibraryPtr library, GDExtensionInitialization * initialization)
{
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize);
	init.register_terminator(uninitialize);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}

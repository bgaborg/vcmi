// VcmiData.cpp, Meta Quest build: the Godot side of the data bridge (quest/DATA_BRIDGE.md).
// Finds the table the game exports (quest/bridge/VcmiBridgeApi.h) and hands its data to GDScript.
// License: GNU General Public License v2.0 or later

#include "../../bridge/VcmiBridgeApi.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <vector>

#include <dlfcn.h>
#include <map>
#include <memory>
#include <set>
#include <tuple>
#include <string>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

#include "SpriteAtlas.h"

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
		ClassDB::bind_method(D_METHOD("animation_names"), &VcmiData::animation_names);
		ClassDB::bind_method(D_METHOD("object_count"), &VcmiData::object_count);
		ClassDB::bind_method(D_METHOD("update_markers", "multimesh", "panel_size", "metres"), &VcmiData::update_markers);
		ClassDB::bind_method(D_METHOD("decode_animation", "name"), &VcmiData::decode_animation);
		ClassDB::bind_method(D_METHOD("atlas_view", "tiles", "level"), &VcmiData::atlas_view);
		ClassDB::bind_method(D_METHOD("atlas_busy"), &VcmiData::atlas_busy);
		ClassDB::bind_method(D_METHOD("atlas_stats"), &VcmiData::atlas_stats);
		ClassDB::bind_method(D_METHOD("atlas_page", "layer"), &VcmiData::atlas_page);
		ClassDB::bind_method(D_METHOD("atlas_textures"), &VcmiData::atlas_textures);
		ClassDB::bind_method(D_METHOD("update_sprites", "multimesh", "tiles", "level", "with_names"), &VcmiData::update_sprites, DEFVAL(false));
		ClassDB::bind_method(D_METHOD("update_sprite_changes", "multimesh"), &VcmiData::update_sprite_changes);
		ClassDB::bind_method(D_METHOD("set_tabletop", "shown"), &VcmiData::set_tabletop);
		ClassDB::bind_method(D_METHOD("tile_input", "tile", "kind"), &VcmiData::tile_input);
		ClassDB::bind_method(D_METHOD("heroes"), &VcmiData::heroes);
		BIND_CONSTANT(TILE_HOVER);
		BIND_CONSTANT(TILE_CLICK);
		BIND_CONSTANT(TILE_POPUP);
		BIND_CONSTANT(TILE_POPUP_END);
		ClassDB::bind_method(D_METHOD("animate_move", "multimesh"), &VcmiData::animate_move);
		ClassDB::bind_method(D_METHOD("sprite_table"), &VcmiData::sprite_table);
		ClassDB::bind_method(D_METHOD("sprite_names"), &VcmiData::sprite_names);
		BIND_CONSTANT(TERRAIN_CHANGED);
		BIND_CONSTANT(FOG_CHANGED);
		BIND_CONSTANT(IN_GAME);
		BIND_CONSTANT(OBJECTS_CHANGED);
	}

	uint32_t seenTiles = 0;
	uint32_t seenFog = 0;
	uint32_t seenSnapshot = 0;
	uint32_t seenSequence = 0;
	bool resync = false; // the changes asked for were gone: the whole list on the next update
	VcmiGrid map{}; // of the last tile snapshot: places the objects
	std::vector<VcmiObject> objects; // by object id
	std::vector<VcmiObject> changeBuffer = std::vector<VcmiObject>(1024);
	std::vector<uint32_t> changedIds; // since the last update_markers
	bool markersReset = true; // a new list or map: update_markers fills the whole MultiMesh
	std::vector<int32_t> markerSlot; // MultiMesh instance of each object id, -1 for none
	std::vector<int32_t> freeSlots;
	VcmiGrid markerMap{};
	Vector2 markerPanel;
	PackedStringArray animations;
	uint32_t wantedAnimations = 0;
	int64_t consumeMicros = 0; // of the last update that built an image
	std::vector<VcmiTile> tiles;
	PackedByteArray fog;
	uint32_t colours[VCMI_TERRAIN_COLOURS * 2] = {};
	Ref<Image> terrain;
	Ref<Image> fogMap;
	std::unique_ptr<SpriteAtlas> atlas; // made by the first atlas_view
	std::vector<std::string> animationNames; // animations in UTF-8, for the atlas
	std::set<std::string> atlasNames; // of the last atlas_view

	struct Sprite
	{
		uint16_t y; uint8_t fixed; uint16_t x; uint32_t id; uint8_t order;
		float custom[4]; float origin[2]; float fog[4];
		auto key() const { return std::tie(y, fixed, x, id, order); } // the 2D map's drawing order
	};
	std::vector<Sprite> sprites; // of the last update_sprites and the changes since, in drawing order
	std::vector<float> table; // the frames the sprites use: 8 floats each (sprite_table)
	std::map<std::pair<std::string, int>, std::array<int, 2>> groups; // animation and group -> first frame, count
	Rect2i spriteAnchors; // of the last update_sprites: the anchor tiles of the objects drawn
	int spriteLevel = -1;
	std::vector<uint32_t> spriteChanges; // object ids changed since the last sprite update
	bool spritesStale = true; // a new list or map, or too many changes: update_sprite_changes asks for update_sprites
	int64_t spriteMicros = 0, changeMicros = 0, maxChangeMicros = 0, bufferMicros = 0; // main thread: the last update_sprites and change update
	VcmiMove move{}; // the last hero step the game asked the tabletop to show
	std::chrono::steady_clock::time_point moveStart; // when update() first saw it
	bool moveShown = true; // its time has passed and the game was told
	bool moveDrawn = true; // the sprites are back at their own place
	Ref<Image> spriteTable; // of the last update_sprites: the frames in the atlas, 2 texels each
	PackedStringArray spriteNames; // of the last update_sprites, per instance: "animation x,y group", for debugging

	// the flag colours of the players (Graphics.cpp:72-90), also the marker colours; the 9th is neutral
	static constexpr uint8_t PLAYER_COLOURS[9][3] = {{0xff, 0, 0}, {0x31, 0x52, 0xff}, {0x9c, 0x73, 0x52}, {0x42, 0x94, 0x29},
		{0xff, 0x84, 0}, {0x8c, 0x29, 0xa5}, {0x09, 0x9c, 0xa5}, {0xc6, 0x7b, 0x8c}, {0x84, 0x84, 0x84}};

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
	enum { TERRAIN_CHANGED = 1, FOG_CHANGED = 2, IN_GAME = 4, OBJECTS_CHANGED = 8 };
	enum { TILE_HOVER = VCMI_TILE_HOVER, TILE_CLICK = VCMI_TILE_CLICK, TILE_POPUP = VCMI_TILE_POPUP, TILE_POPUP_END = VCMI_TILE_POPUP_END };

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
		result["objects_snapshot"] = s.objectsSnapshot;
		result["objects_sequence"] = s.objectsSequence;
		result["objects_us"] = s.objectsMicros;
		result["change_us"] = s.changeMicros;
		result["tabletop"] = s.tabletop != 0;
		result["move_sequence"] = s.moveSequence;
		result["wait_us"] = s.waitMicros;
		result["move_timeouts"] = s.moveTimeouts;
		result["windows_above"] = s.windowsAbove;
		result["inputs_run"] = s.inputsRun;
		result["inputs_dropped"] = s.inputsDropped;
		result["objects"] = int64_t(objects.size());
		result["animations"] = animations.size();
		return result;
	}

	/// once per frame: fetches what the game published since the last call; TERRAIN_CHANGED | FOG_CHANGED when the images
	/// are new, IN_GAME while an adventure map exists
	int update()
	{
		if(!api)
			return 0;
		if(atlas)
			atlas->upload();
		const int result = fetchPublished();
		// after the objects: the game publishes a step before its record, so a record at the end comes with its step
		updateMove();
		return result;
	}

	int fetchPublished()
	{
		VcmiBridgeStats s;
		api->stats(&s);
		const int inGame = s.inGame ? IN_GAME : 0;
		if(s.tilesGeneration == seenTiles && s.fogGeneration == seenFog && s.objectsSnapshot == seenSnapshot
			&& s.objectsSequence == seenSequence && !resync && animations.size() >= wantedAnimations)
			return inGame;
		const auto from = std::chrono::steady_clock::now();
		int changed = 0;
		VcmiGrid grid;
		if(s.tilesGeneration != seenTiles && fetch(tiles, grid, [this](auto & buffer, VcmiGrid & g) { api->tiles(buffer.data(), buffer.size(), colours, &g); }))
		{
			seenTiles = grid.generation;
			map = grid;
			markersReset = true;
			spritesStale = true;
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
		if(s.objectsSnapshot != seenSnapshot || resync ? fetchObjects() : s.objectsSequence != seenSequence && fetchChanges())
			changed |= OBJECTS_CHANGED;
		fetchAnimations();
		if(changed)
			consumeMicros = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
		return changed | inGame;
	}

	/// one try, as fetch: the whole list
	bool fetchObjects()
	{
		VcmiObjectList list;
		api->objects(objects.data(), objects.size(), &list);
		if(list.snapshot == 0 && list.count > objects.size())
		{
			objects.resize(list.count);
			api->objects(objects.data(), objects.size(), &list);
		}
		if(list.snapshot == 0)
			return false;
		objects.resize(list.count);
		if(list.snapshot != seenSnapshot)
		{
			animations.clear(); // a new list starts the names again
			animationNames.clear();
		}
		wantedAnimations = list.animations;
		seenSnapshot = list.snapshot;
		seenSequence = list.sequence;
		resync = false;
		markersReset = true;
		changedIds.clear();
		spritesStale = true;
		spriteChanges.clear();
		return true;
	}

	/// one try: the records changed since the last fetch, applied in order
	bool fetchChanges()
	{
		VcmiObjectChanges changes;
		api->objectChanges(seenSnapshot, seenSequence, changeBuffer.data(), changeBuffer.size(), &changes);
		if(changes.resync)
			resync = true; // too many or gone: the whole list on the next update
		if(changes.sequence == 0)
			return false;
		for(uint32_t i = 0; i < changes.count; i++)
		{
			const VcmiObject & record = changeBuffer[i];
			if(record.id >= objects.size())
				objects.resize(record.id + 1);
			objects[record.id] = record;
			changedIds.push_back(record.id);
			spriteChanges.push_back(record.id);
		}
		if(spriteChanges.size() > 4096) // sprites not shown for long: the whole update is cheaper
		{
			spritesStale = true;
			spriteChanges.clear();
		}
		wantedAnimations = changes.animations;
		seenSequence = changes.sequence;
		return changes.count > 0;
	}

	/// the names the table gained; the rest on the next update when the game is writing
	void fetchAnimations()
	{
		char name[256];
		while(animations.size() < int64_t(wantedAnimations) && api->animation(animations.size(), name, sizeof(name)) > 0)
		{
			animations.push_back(String(name));
			animationNames.push_back(name);
		}
	}

	/// the minimap colour of each tile, the map levels side by side; null before the first update with a map
	Ref<Image> terrain_image() const { return terrain; }
	/// 1 (of 255) where the local team sees; x-major: terrain_image with the axes swapped
	Ref<Image> fog_image() const { return fogMap; }

	/// the frames of animation `name` (an animation_names entry) as the 2D map draws them (quest/MILESTONE_3B.md):
	/// {frames: [{group, frame, left, top, full_size, image (RGBA8, shadow in alpha), mask (L8 owner flag,
	/// or null), png (from a mod's PNG)}], bridge_us, bake_us}; empty frames when missing or no game is loaded. Reads the game's files: for a
	/// test, or from a worker thread
	Dictionary decode_animation(const String & name) const
	{
		Dictionary result;
		Array frames;
		result["frames"] = frames;
		if(!api)
			return result;
		using Clock = std::chrono::steady_clock;
		auto from = Clock::now();
		VcmiAnimationData anim{};
		api->decodeAnimation(name.utf8().get_data(), &anim);
		result["bridge_us"] = int64_t(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - from).count());
		from = Clock::now();
		for(const BakedFrame & b : bakeFrames(anim))
		{
			PackedByteArray px;
			px.resize(b.rgba.size());
			std::memcpy(px.ptrw(), b.rgba.data(), b.rgba.size());
			Ref<Image> mask;
			if(!b.mask.empty())
			{
				PackedByteArray flag;
				flag.resize(b.mask.size());
				std::memcpy(flag.ptrw(), b.mask.data(), b.mask.size());
				mask = Image::create_from_data(b.width, b.height, false, Image::FORMAT_L8, flag);
			}
			Dictionary frame;
			frame["group"] = b.group;
			frame["frame"] = b.frame;
			frame["left"] = b.left;
			frame["top"] = b.top;
			frame["full_size"] = Vector2i(b.fullWidth, b.fullHeight);
			frame["image"] = Image::create_from_data(b.width, b.height, false, Image::FORMAT_RGBA8, px);
			frame["mask"] = mask;
			frame["png"] = b.png;
			frames.push_back(frame);
		}
		result["bake_us"] = int64_t(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - from).count());
		return result;
	}

	/// asks the sprite atlas for the animations of the objects on `tiles` of map level `level` (quest/MILESTONE_3B.md,
	/// plan step 3), and the hero flags there; returns how many animations that is. The workers load the missing ones,
	/// update() uploads them.
	int64_t atlas_view(const Rect2i & tiles, int level)
	{
		if(!api)
			return 0;
		if(!atlas)
			atlas = std::make_unique<SpriteAtlas>(api);
		// an object is drawn up and left of its anchor tile, up to 8 tiles (H3 object templates are at most 8x6)
		const Rect2i anchors(tiles.position, tiles.size + Vector2i(8, 8));
		std::unordered_set<uint16_t> seen;
		std::unordered_set<int> flags;
		std::vector<std::string> names;
		for(const VcmiObject & o : objects)
		{
			if(!(o.flags & VCMI_OBJECT_PRESENT) || (o.flags & VCMI_OBJECT_HIDDEN) || o.z != level || !anchors.has_point(Vector2i(o.x, o.y)))
				continue;
			if(o.animation < animationNames.size() && seen.insert(o.animation).second)
				names.push_back(animationNames[o.animation]);
			// heroes fly a separate flag animation (MapRendererObjects::getFlagAnimation)
			if((o.flags & VCMI_OBJECT_HERO) && o.owner < 8 && flags.insert(o.owner).second)
				names.push_back("AF0" + std::to_string(o.owner));
		}
		atlas->want(names);
		atlasNames = std::set<std::string>(names.begin(), names.end());
		return names.size();
	}

	/// true while the atlas loads or uploads
	bool atlas_busy() const { return atlas && atlas->busyNow(); }

	Dictionary atlas_stats() const
	{
		Dictionary result;
		if(!atlas)
			return result;
		const SpriteAtlas::Stats s = atlas->statsNow();
		result["wanted"] = s.wanted;
		result["loaded"] = s.loaded;
		result["frames"] = s.frames;
		result["pixels"] = s.pixels;
		result["pages_used"] = s.pagesUsed;
		result["refills"] = s.refills;
		result["overflowed"] = s.overflowed;
		result["decode_us"] = s.decodeMicros;
		result["mipmap_us"] = s.mipmapMicros;
		result["batch_ms"] = s.batchMillis;
		result["create_us"] = s.createMicros;
		result["upload_us"] = s.uploadMicros;
		result["max_upload_us"] = s.maxUploadMicros;
		result["sprites_us"] = spriteMicros;
		result["changes_us"] = changeMicros;
		result["max_changes_us"] = maxChangeMicros;
		result["buffer_us"] = bufferMicros;
		return result;
	}

	/// page `layer` as packed, over grey with the owner mask in red; for a look
	Ref<Image> atlas_page(int layer) const { return atlas ? atlas->debugPage(layer) : Ref<Image>(); }

	/// [body, mask]: Texture2DArray of RGBA8 and of R8, SpriteAtlas::PAGES layers; empty before atlas_view
	Array atlas_textures() const
	{
		Array result;
		if(atlas)
		{
			result.push_back(atlas->bodyTexture());
			result.push_back(atlas->maskTexture());
		}
		return result;
	}

	/// the sprites of object `o` when it is in the sprite view: its animation and a hero's flag, appended to `out`.
	/// `missing` when one of its animations is not in the last atlas_view (the view must be asked for again)
	void spritesOf(const VcmiObject & o, std::vector<Sprite> & out, bool & missing)
	{
		if(!(o.flags & VCMI_OBJECT_PRESENT) || (o.flags & VCMI_OBJECT_HIDDEN) || o.z != spriteLevel || !spriteAnchors.has_point(Vector2i(o.x, o.y)))
			return;
		if(o.animation >= animationNames.size())
		{
			missing = true; // its name is not fetched yet
			return;
		}
		const float columns = float(map.width) * map.levels;
		const int vx = int(o.x) - (o.visit >> 4);
		const int vy = int(o.y) - (o.visit & 15);
		const float fog[4] = {(o.z * map.width + o.x + 0.5f) / columns, (o.y + 0.5f) / map.height,
			(o.z * map.width + vx + 0.5f) / columns, (vy + 0.5f) / map.height};
		// heroes draw their flag from a separate animation, not in the owner colour (MapRendererObjects::renderImage)
		const bool hero = o.flags & VCMI_OBJECT_HERO;
		const int owner = hero ? 9 : o.owner < 8 ? o.owner : o.owner == 255 ? 8 : 9;
		const auto add = [&](const std::string & name, uint8_t order, int ownerCode)
		{
			if(!atlasNames.count(name))
			{
				missing = true;
				return;
			}
			const std::array<int, 2> g = groupFrames(name, o.group);
			if((g[1] & 1023) == 0)
				return;
			// the full frame's bottom right sits on the anchor tile's bottom right (MapRendererObjects::renderImage).
			// Heroes and boats come after the other objects of their row, as the 2D map draws them last on a tile
			// (MapObjectDrawOrder::usesFixedDrawSlot). shortcut: special ground (clover field, cursed ground) is not
			// drawn first as renderGround does: the bridge has no flag for it yet; a hero on its upper row is covered
			out.push_back(Sprite{o.y, uint8_t((o.flags & (VCMI_OBJECT_HERO | VCMI_OBJECT_BOAT)) ? 1 : 0), o.x, o.id, order,
				{float(g[0]), float(g[1]), float(ownerCode), o.id + 0.5f},
				{float((o.z * map.width + o.x + 1) * 32), float((o.y + 1) * 32)}, {fog[0], fog[1], fog[2], fog[3]}});
		};
		add(animationNames[o.animation], 0, owner);
		// shortcut: a boat with a hero flies boat->flagAnimations[owner] with a wave overlay (MapRendererObjects::
		// getFlagAnimation, getOverlayAnimation); not published by the bridge yet, so boats have no flag
		if(hero && o.owner < 8)
			add("AF0" + std::to_string(o.owner), 1, 9);
	}

	/// the frames of group `wanted` of animation `name` in the frame table, added to it on first use: first, count
	/// (+ 1024 when mirrored)
	std::array<int, 2> groupFrames(const std::string & name, int wanted)
	{
		const auto key = std::make_pair(name, wanted);
		if(auto it = groups.find(key); it != groups.end())
			return it->second;
		// the 2D map mirrors these groups of heroes and boats (MapRendererObjects::getAnimation, createFlippedGroup)
		static const std::map<int, int> mirrored = {{13, 1}, {14, 2}, {15, 3}, {10, 6}, {11, 7}, {12, 8}};
		const std::vector<SpriteAtlas::Placed> placed = atlas->frames(name);
		const auto has = [&](int g) { return std::any_of(placed.begin(), placed.end(), [g](const auto & f) { return f.group == g; }); };
		int source = wanted;
		bool mirror = false;
		if(!has(wanted))
			if(auto m = mirrored.find(wanted); m != mirrored.end() && has(m->second))
			{
				source = m->second;
				mirror = true;
			}
		std::vector<SpriteAtlas::Placed> frames;
		for(const auto & f : placed)
			if(f.group == source)
				frames.push_back(f);
		std::sort(frames.begin(), frames.end(), [](const auto & l, const auto & r) { return l.frame < r.frame; });
		std::array<int, 2> entry{int(table.size() / 8), int(frames.size()) + (mirror ? 1024 : 0)};
		for(const auto & f : frames)
		{
			const float values[8] = {float(f.page), float(f.x), float(f.y), float(f.width), float(f.height),
				float(f.left - f.fullWidth), float(f.top - f.fullHeight), float(f.fullWidth)};
			table.insert(table.end(), values, values + 8);
		}
		groups[key] = entry;
		return entry;
	}

	/// sprite_table from the table: 512 texels a row, 2 per frame
	void writeTable()
	{
		const int64_t rows = std::max<int64_t>((int64_t(table.size() / 4) + 511) / 512, 1);
		PackedByteArray bytes;
		bytes.resize(rows * 512 * 4 * int64_t(sizeof(float)));
		std::memset(bytes.ptrw(), 0, bytes.size());
		std::memcpy(bytes.ptrw(), table.data(), table.size() * sizeof(float));
		spriteTable = Image::create_from_data(512, rows, false, Image::FORMAT_RGBAF, bytes);
	}

	static int64_t microsSince(std::chrono::steady_clock::time_point from)
	{
		return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
	}

	/// the sprites into `multimesh`, in their order
	void writeSprites(const Ref<MultiMesh> & multimesh)
	{
		const auto from = std::chrono::steady_clock::now();
		if(multimesh->get_instance_count() != int64_t(sprites.size()))
		{
			multimesh->set_instance_count(0);
			multimesh->set_use_colors(true);
			multimesh->set_use_custom_data(true);
			multimesh->set_transform_format(MultiMesh::TRANSFORM_3D);
			multimesh->set_instance_count(sprites.size());
		}
		if(sprites.empty())
			return;
		const float sx = 1.0f / (32.0f * float(map.width) * map.levels);
		const float sz = 1.0f / (32.0f * map.height);
		PackedFloat32Array buffer;
		buffer.resize(int64_t(sprites.size()) * 20);
		float * out = buffer.ptrw();
		for(const Sprite & sprite : sprites)
		{
			const float values[20] = {sx, 0, 0, sprite.origin[0] * sx - 0.5f, 0, 1, 0, 0.003f, 0, 0, sz, sprite.origin[1] * sz - 0.5f,
				sprite.fog[0], sprite.fog[1], sprite.fog[2], sprite.fog[3],
				sprite.custom[0], sprite.custom[1], sprite.custom[2], sprite.custom[3]};
			std::memcpy(out, values, sizeof(values));
			out += 20;
		}
		multimesh->set_buffer(buffer);
		bufferMicros = microsSince(from);
	}

	/// the sprites of the objects on `tiles` of level `level` whose frames are in the atlas (atlas_view, then wait for
	/// atlas_busy), as the 2D map draws them, into `multimesh` in the minimap's unit space (as update_markers): one
	/// instance per object and hero flag, in drawing order (the shader draws without depth, so the order is the
	/// instance order). Fills sprite_table, and sprite_names when `with_names`. Returns the instance count.
	/// Instance: transform pixels -> unit space at the anchor tile's bottom right; colour: the anchor and visitable tile
	/// in minimap UV (the fog test); custom: first frame in the table, frame count + 1024 when mirrored, owner colour
	/// (0-7 players, 8 neutral, 9 none), object id + 0.5 (the frame phase; the .5 checks the float precision).
	/// The table holds the atlas places of now: run this again when atlas_stats().refills rises (a refill moves the frames).
	/// Then update_sprite_changes keeps them up to date.
	int64_t update_sprites(const Ref<MultiMesh> & multimesh, const Rect2i & tiles, int level, bool with_names)
	{
		if(multimesh.is_null() || !atlas || map.width == 0)
			return 0;
		const auto from = std::chrono::steady_clock::now();
		// an object is drawn up and left of its anchor tile, up to 8 tiles (as atlas_view)
		spriteAnchors = Rect2i(tiles.position, tiles.size + Vector2i(8, 8));
		spriteLevel = level;
		sprites.clear();
		table.clear();
		groups.clear();
		spriteChanges.clear();
		bool missing = false;
		for(const VcmiObject & o : objects)
			spritesOf(o, sprites, missing);
		// objects that changed while the atlas loaded may need animations the view did not ask for: ask again
		spritesStale = missing;
		std::sort(sprites.begin(), sprites.end(), [](const Sprite & l, const Sprite & r) { return l.key() < r.key(); });
		writeTable();
		writeSprites(multimesh);
		spriteNames.clear();
		if(with_names)
			for(const Sprite & sprite : sprites)
			{
				const VcmiObject & o = objects[sprite.id];
				const std::string name = sprite.order ? "AF0" + std::to_string(o.owner) : animationNames[o.animation];
				spriteNames.push_back(String((name + " " + std::to_string(o.x) + "," + std::to_string(o.y) + " " + std::to_string(o.group)).c_str()));
			}
		spriteMicros = microsSince(from);
		return sprites.size();
	}

	/// the object changes since the last update_sprites applied to its sprites (quest/MILESTONE_3B.md, plan step 6):
	/// 0 no change, 1 the instances changed, 3 the frame table too (set sprite_table again), -1 the sprites need the
	/// whole update: a new object list, too many changes, or an animation not in the last atlas_view (atlas_view, wait,
	/// update_sprites). Only while the atlas is not busy: frames it just placed may not be on the GPU yet.
	int64_t update_sprite_changes(const Ref<MultiMesh> & multimesh)
	{
		if(spritesStale || multimesh.is_null() || !atlas)
			return -1;
		if(spriteChanges.empty())
			return 0;
		const auto from = std::chrono::steady_clock::now();
		std::sort(spriteChanges.begin(), spriteChanges.end());
		spriteChanges.erase(std::unique(spriteChanges.begin(), spriteChanges.end()), spriteChanges.end());
		sprites.erase(std::remove_if(sprites.begin(), sprites.end(), [this](const Sprite & sprite)
			{ return std::binary_search(spriteChanges.begin(), spriteChanges.end(), sprite.id); }), sprites.end());
		const size_t tableSize = table.size();
		std::vector<Sprite> added;
		bool missing = false;
		for(uint32_t id : spriteChanges)
			if(id < objects.size())
				spritesOf(objects[id], added, missing);
		spriteChanges.clear();
		if(missing)
		{
			spritesStale = true;
			return -1;
		}
		// merged, not inserted one by one: up to 4 096 changes wait while the table is not looked at
		const auto before = [](const Sprite & l, const Sprite & r) { return l.key() < r.key(); };
		std::sort(added.begin(), added.end(), before);
		sprites.insert(sprites.end(), added.begin(), added.end());
		std::inplace_merge(sprites.begin(), sprites.end() - added.size(), sprites.end(), before);
		writeSprites(multimesh);
		const bool newFrames = table.size() != tableSize;
		if(newFrames)
			writeTable();
		changeMicros = microsSince(from);
		maxChangeMicros = std::max(maxChangeMicros, changeMicros);
		return newFrames ? 3 : 1;
	}

	/// true: the game shows the map on the tabletop (VcmiBridgeApi.setTabletop): the 2D map stops drawing and animating,
	/// and the game waits for the tabletop's hero steps (animate_move)
	void set_tabletop(bool shown)
	{
		if(api)
			api->setTabletop(shown ? 1 : 0);
	}

	/// the heroes on the map: [{id, tile (anchor x, y, level), owner}]
	Array heroes() const
	{
		Array result;
		for(const VcmiObject & o : objects)
			if((o.flags & VCMI_OBJECT_PRESENT) && (o.flags & VCMI_OBJECT_HERO))
			{
				Dictionary hero;
				hero["id"] = o.id;
				hero["tile"] = Vector3i(o.x, o.y, o.z);
				hero["owner"] = o.owner;
				result.push_back(hero);
			}
		return result;
	}

	/// tile input from the tabletop: TILE_HOVER, TILE_CLICK, TILE_POPUP (grip down), TILE_POPUP_END (grip up), on tile
	/// x, y of level z; the game runs it as the 2D map's tile handlers (quest/PHASE4.md decision 1)
	void tile_input(const Vector3i & tile, int kind)
	{
		if(api && tile.x >= 0 && tile.y >= 0 && tile.z >= 0)
			api->tileInput(uint16_t(tile.x), uint16_t(tile.y), uint8_t(tile.z), uint8_t(kind));
	}

	/// each frame: a new hero step starts its clock; once its duration has passed the game is told and goes on, whether
	/// or not the sprites showed it (markers, another level)
	void updateMove()
	{
		VcmiMove latest{};
		api->move(&latest);
		const auto now = std::chrono::steady_clock::now();
		if(latest.sequence != move.sequence)
		{
			move = latest;
			moveStart = now;
			moveShown = false;
			moveDrawn = false;
		}
		if(!moveShown && now - moveStart >= std::chrono::milliseconds(move.durationMs))
		{
			api->confirmMove(move.sequence);
			moveShown = true;
		}
	}

	/// slides the sprites of the moving object from the step's start to its end, the game's record being at the end
	/// already; puts them back when the step is over. Each frame after update_sprite_changes. True while it moves.
	/// shortcut: markers jump; a step to another level (none from onHeroMoved) is not slid
	bool animate_move(const Ref<MultiMesh> & multimesh)
	{
		if(moveDrawn || multimesh.is_null() || multimesh->get_instance_count() != int64_t(sprites.size()) || map.width == 0)
			return false;
		// the step comes before the object's new record: until then its sprites are still at the start
		if(move.object >= objects.size() || objects[move.object].x != move.toX || objects[move.object].y != move.toY)
			return true;
		const float elapsed = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - moveStart).count();
		const float left = move.fromZ == move.toZ ? std::max(0.0f, 1.0f - elapsed / std::max<float>(move.durationMs, 1.0f)) : 0.0f;
		const float sx = 1.0f / (32.0f * float(map.width) * map.levels);
		const float sz = 1.0f / (32.0f * map.height);
		const Basis basis(sx, 0, 0, 0, 1, 0, 0, 0, sz);
		for(size_t i = 0; i < sprites.size(); i++)
			if(sprites[i].id == move.object)
			{
				const float x = sprites[i].origin[0] + (int(move.fromX) - int(move.toX)) * 32.0f * left;
				const float y = sprites[i].origin[1] + (int(move.fromY) - int(move.toY)) * 32.0f * left;
				multimesh->set_instance_transform(i, Transform3D(basis, Vector3(x * sx - 0.5f, 0.003f, y * sz - 0.5f)));
			}
		moveDrawn = left <= 0.0f;
		return !moveDrawn;
	}

	/// the frames of the last update_sprites and the changes since: RGBAF, 512 texels a row, 2 per frame (page, x, y, width; height, left and
	/// top from the full frame's bottom right, full width)
	Ref<Image> sprite_table() const { return spriteTable; }
	PackedStringArray sprite_names() const { return spriteNames; }

	/// the animation names the objects use, by index (VcmiObject.animation)
	PackedStringArray animation_names() const { return animations; }
	int64_t object_count() const { return objects.size(); }

	/// one marker per hero, town and flaggable object on the minimap, in the player's colour, `metres` wide on a panel of
	/// `panel_size`, in the panel's unit space (-0.5..0.5 on x and z). Fills the whole MultiMesh (3D transforms, colours,
	/// custom data) after a new list, else sets only the instances of changed objects. Custom data: the anchor and the
	/// visitable tile in minimap UV, for the fog test in the shader.
	void update_markers(const Ref<MultiMesh> & multimesh, Vector2 panel_size, double metres)
	{
		if(multimesh.is_null() || map.width == 0 || panel_size.x <= 0 || panel_size.y <= 0)
			return;
		float instance[20];
		if(markersReset || markerMap.width != map.width || markerMap.height != map.height || markerMap.levels != map.levels || markerPanel != panel_size)
		{
			markerMap = map;
			markerPanel = panel_size;
			markerSlot.assign(objects.size(), -1);
			int32_t count = 0;
			for(size_t id = 0; id < objects.size(); id++)
				if(isMarker(objects[id]))
					markerSlot[id] = count++;
			constexpr int32_t SPARE = 256; // for heroes recruited and objects flagged later, without reallocating
			PackedFloat32Array buffer;
			buffer.resize(int64_t(count + SPARE) * 20); // zero: the spare instances have no size
			float * out = buffer.ptrw();
			for(size_t id = 0; id < objects.size(); id++)
				if(markerSlot[id] >= 0)
				{
					markerInstance(objects[id], metres, instance);
					std::memcpy(out + int64_t(markerSlot[id]) * 20, instance, sizeof(instance));
				}
			freeSlots.clear();
			for(int32_t slot = count + SPARE - 1; slot >= count; slot--)
				freeSlots.push_back(slot);
			multimesh->set_instance_count(count + SPARE);
			multimesh->set_buffer(buffer);
			markersReset = false;
			changedIds.clear();
			return;
		}
		for(uint32_t id : changedIds)
		{
			const VcmiObject & o = objects[id];
			if(markerSlot.size() <= id)
				markerSlot.resize(id + 1, -1);
			int32_t & slot = markerSlot[id];
			if(isMarker(o))
			{
				if(slot < 0)
				{
					if(freeSlots.empty())
					{
						markersReset = true; // out of spare instances: all again
						return update_markers(multimesh, panel_size, metres);
					}
					slot = freeSlots.back();
					freeSlots.pop_back();
				}
				markerInstance(o, metres, instance);
				multimesh->set_instance_transform(slot, Transform3D(Basis(instance[0], instance[1], instance[2], instance[4], instance[5], instance[6], instance[8], instance[9], instance[10]), Vector3(instance[3], instance[7], instance[11])));
				multimesh->set_instance_color(slot, Color(instance[12], instance[13], instance[14], instance[15]));
				multimesh->set_instance_custom_data(slot, Color(instance[16], instance[17], instance[18], instance[19]));
			}
			else if(slot >= 0)
			{
				multimesh->set_instance_transform(slot, Transform3D(Basis(0, 0, 0, 0, 0, 0, 0, 0, 0), Vector3()));
				freeSlots.push_back(slot);
				slot = -1;
			}
		}
		changedIds.clear();
	}

	bool isMarker(const VcmiObject & o) const
	{
		// a boat with a hero (owner set) stands in for the hero, who is hidden in it
		return (o.flags & VCMI_OBJECT_PRESENT) && !(o.flags & VCMI_OBJECT_HIDDEN) && o.z < map.levels
			&& ((o.flags & (VCMI_OBJECT_HERO | VCMI_OBJECT_TOWN | VCMI_OBJECT_FLAGGABLE)) || ((o.flags & VCMI_OBJECT_BOAT) && o.owner < 8));
	}

	/// the 20 floats of one marker instance, in MultiMesh buffer order
	void markerInstance(const VcmiObject & o, double metres, float * out) const
	{
		const float columns = float(map.width) * map.levels;
		const int vx = int(o.x) - (o.visit >> 4);
		const int vy = int(o.y) - (o.visit & 15);
		const float u = (o.z * map.width + vx + 0.5f) / columns;
		const float v = (vy + 0.5f) / map.height;
		const float scale = o.flags & (VCMI_OBJECT_HERO | VCMI_OBJECT_BOAT) ? 1.5f : 1.0f;
		const float sx = float(metres / markerPanel.x) * scale;
		const float sz = float(metres / markerPanel.y) * scale;
		const float values[20] = {sx, 0, 0, u - 0.5f, 0, 1, 0, 0.002f, 0, 0, sz, v - 0.5f,
			0, 0, 0, 1,
			(o.z * map.width + o.x + 0.5f) / columns, (o.y + 0.5f) / map.height, u, v};
		std::memcpy(out, values, sizeof(values));
		for(int c = 0; c < 3; c++)
			out[12 + c] = PLAYER_COLOURS[o.owner < 8 ? o.owner : 8][c] / 255.0f;
	}
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

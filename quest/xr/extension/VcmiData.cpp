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

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
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
		ClassDB::bind_method(D_METHOD("animation_names"), &VcmiData::animation_names);
		ClassDB::bind_method(D_METHOD("object_count"), &VcmiData::object_count);
		ClassDB::bind_method(D_METHOD("update_markers", "multimesh", "panel_size", "metres"), &VcmiData::update_markers);
		ClassDB::bind_method(D_METHOD("decode_animation", "name"), &VcmiData::decode_animation);
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
			animations.clear(); // a new list starts the names again
		wantedAnimations = list.animations;
		seenSnapshot = list.snapshot;
		seenSequence = list.sequence;
		resync = false;
		markersReset = true;
		changedIds.clear();
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
		}
		wantedAnimations = changes.animations;
		seenSequence = changes.sequence;
		return changes.count > 0;
	}

	/// the names the table gained; the rest on the next update when the game is writing
	static Ref<Image> loadPng(const uint8_t * bytes, uint32_t size)
	{
		PackedByteArray buffer;
		buffer.resize(size);
		std::memcpy(buffer.ptrw(), bytes, size);
		Ref<Image> image;
		image.instantiate();
		if(image->load_png_from_buffer(buffer) != OK)
			return Ref<Image>();
		return image;
	}

	/// a .def palette as RGBA with the special entries the 2D map uses for map objects
	/// (ScalableImageParameters::setShadowTransparency, clientsdl3/render/ScalableImage.cpp:205-222): 0 clear, 1 and 4
	/// shadow at alpha 64 and 128, 2 and 3 the same when they hold H3's shadow colours. 5, the owner flag, keeps its
	/// colour: objects without an owner draw it so (WITH_SHADOW or ONLY_BODY_IGNORE_OVERLAY, MapRenderer.cpp:425-427);
	/// for owned ones the mask marks it for the owner colour
	static std::array<uint8_t, 1024> bakePalette(const uint8_t * rgb)
	{
		std::array<uint8_t, 1024> out{};
		if(!rgb)
			return out;
		for(int i = 0; i < 256; i++)
		{
			std::memcpy(&out[i * 4], &rgb[i * 3], 3);
			out[i * 4 + 3] = 255;
		}
		const auto similar = [rgb](int i, int r, int g, int b)
		{ return std::abs(rgb[i * 3] - r) < 8 && std::abs(rgb[i * 3 + 1] - g) < 8 && std::abs(rgb[i * 3 + 2] - b) < 8; };
		const auto shadow = [&out](int i, uint8_t alpha) { out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = 0; out[i * 4 + 3] = alpha; };
		shadow(0, 0);
		shadow(1, 64);
		shadow(4, 128);
		if(similar(2, 255, 100, 255))
			shadow(2, 64);
		if(similar(3, 255, 50, 255))
			shadow(3, 128);
		return out;
	}

	void fetchAnimations()
	{
		char name[256];
		while(animations.size() < int64_t(wantedAnimations) && api->animation(animations.size(), name, sizeof(name)) > 0)
			animations.push_back(String(name));
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
		const auto rgba = bakePalette(anim.palette);
		for(uint32_t i = 0; i < anim.frameCount; i++)
		{
			const VcmiFrame & f = anim.frames[i];
			if(f.offset + uint64_t(f.size) > anim.dataSize || f.overlayOffset + uint64_t(f.overlaySize) > anim.dataSize)
				continue;
			Ref<Image> image;
			Ref<Image> mask;
			if(f.format == VCMI_FRAME_PNG)
			{
				image = loadPng(anim.data + f.offset, f.size);
				if(image.is_null())
					continue;
				image->convert(Image::FORMAT_RGBA8);
				if(f.overlaySize)
					if(Ref<Image> overlay = loadPng(anim.data + f.overlayOffset, f.overlaySize);
						overlay.is_valid() && overlay->get_size() == image->get_size())
					{
						// the flag is where the overlay is opaque (its alpha), as the 2D map draws it in the owner colour
						overlay->convert(Image::FORMAT_RGBA8);
						const PackedByteArray px = overlay->get_data();
						PackedByteArray alpha;
						alpha.resize(px.size() / 4);
						const uint8_t * src = px.ptr();
						uint8_t * dst = alpha.ptrw();
						for(int64_t p = 0; p < alpha.size(); p++)
							dst[p] = src[p * 4 + 3];
						mask = Image::create_from_data(overlay->get_width(), overlay->get_height(), false, Image::FORMAT_L8, alpha);
					}
			}
			else
			{
				if(f.width == 0 || f.height == 0 || f.size != uint32_t(f.width) * f.height)
					continue;
				PackedByteArray px;
				px.resize(int64_t(f.size) * 4);
				PackedByteArray flag;
				flag.resize(f.size);
				uint8_t * out = px.ptrw();
				uint8_t * flagOut = flag.ptrw();
				bool flagged = false;
				for(uint32_t p = 0; p < f.size; p++)
				{
					const uint8_t index = anim.data[f.offset + p];
					std::memcpy(out + p * 4, &rgba[index * 4], 4);
					flagOut[p] = index == 5 ? 255 : 0;
					flagged |= index == 5;
				}
				image = Image::create_from_data(f.width, f.height, false, Image::FORMAT_RGBA8, px);
				if(flagged)
					mask = Image::create_from_data(f.width, f.height, false, Image::FORMAT_L8, flag);
			}
			Dictionary frame;
			frame["group"] = f.group;
			frame["frame"] = f.frame;
			frame["left"] = f.left;
			frame["top"] = f.top;
			frame["full_size"] = Vector2i(f.fullWidth, f.fullHeight);
			frame["image"] = image;
			frame["mask"] = mask;
			frame["png"] = f.format == VCMI_FRAME_PNG;
			frames.push_back(frame);
		}
		result["bake_us"] = int64_t(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - from).count());
		return result;
	}

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
		static const uint8_t playerColours[8][3] = {{0xff, 0, 0}, {0x31, 0x52, 0xff}, {0x9c, 0x73, 0x52}, {0x42, 0x94, 0x29},
			{0xff, 0x84, 0}, {0x8c, 0x29, 0xa5}, {0x09, 0x9c, 0xa5}, {0xc6, 0x7b, 0x8c}}; // Graphics.cpp
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
			out[12 + c] = (o.owner < 8 ? playerColours[o.owner][c] : 0x84) / 255.0f;
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

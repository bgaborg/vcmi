// VcmiData.cpp, Meta Quest build: the Godot side of the data bridge (quest/DATA_BRIDGE.md).
// Finds the table the game exports (quest/bridge/VcmiBridgeApi.h) and hands its data to GDScript.
// License: GNU General Public License v2.0 or later

#include "../../bridge/VcmiBridgeApi.h"

#include <dlfcn.h>

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
	}

public:
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
		return result;
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

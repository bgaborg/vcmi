/*
 * ObjectBench.cpp, Meta Quest build: times the bridge's object list (quest/bridge/ObjectScan) on the headset without
 * the game: loads a saved game with VCMI's library and runs the full list and the per-event updates on it.
 * Built by quest/tools/object-bench.sh, run through app_process by NativeMethods.java (no APK, no game start).
 *
 * License: GNU General Public License v2.0 or later
 */
#include "../../Global.h"

#include "../bridge/ObjectScan.h"

#include "../../lib/CAndroidVMHelper.h"
#include "../../lib/GameLibrary.h"
#include "../../lib/gameState/CGameState.h"
#include "../../lib/mapping/CMap.h"
#include "../../lib/serializer/CLoadFile.h"
#include "../../lib/serializer/CMemorySerializer.h"

#include <jni.h>

namespace
{
using Clock = std::chrono::steady_clock;

double microsSince(Clock::time_point from)
{
	return std::chrono::duration<double, std::micro>(Clock::now() - from).count();
}

// runs `work` `repeats` times; prints the best and the mean in microseconds
template<typename Work>
void timed(const char * name, int repeats, Work work)
{
	double best = 1e30;
	double total = 0;
	for(int i = 0; i < repeats; i++)
	{
		const auto from = Clock::now();
		work();
		const double micros = microsSince(from);
		best = std::min(best, micros);
		total += micros;
	}
	std::printf("%-34s best %9.1f us   mean %9.1f us   (%d runs)\n", name, best, total / repeats, repeats);
}
}

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM * vm, void *)
{
	JNIEnv * env = nullptr;
	vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
	// VCMIDirsAndroid asks eu.vcmi.vcmi.NativeMethods for the data folders
	CAndroidVMHelper::initClassloader(env);
	return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jint JNICALL Java_eu_vcmi_vcmi_NativeMethods_bench(JNIEnv * env, jclass, jstring saveName, jint repeats)
{
	// unbuffered: Java's System.exit does not flush the C library's stdout
	std::setvbuf(stdout, nullptr, _IONBF, 0);
	const char * chars = env->GetStringUTFChars(saveName, nullptr);
	const std::string save = chars;
	env->ReleaseStringUTFChars(saveName, chars);
	try
	{
		auto from = Clock::now();
		auto library = std::make_unique<GameLibrary>();
		library->initializeFilesystem(false);
		library->initializeLibrary();
		LIBRARY = library.release();
		std::printf("library ready in %.1f s\n", microsSince(from) / 1e6);

		from = Clock::now();
		// as CGameHandler::load (server/CGameHandler.cpp:1900-1905), without the server state
		auto state = std::make_shared<CGameState>();
		CLoadFile file(save);
		auto game = file.openChunk(SaveFileFormat::CHUNK_GAMESTATE, state.get());
		state->loadGame(game->iser);
		const CMap & map = state->getMap();
		std::printf("save loaded in %.1f s: %s, %zu object slots, %zu heroes on the map\n", microsSince(from) / 1e6, save.c_str(),
			map.objects.size(), map.getHeroesOnMap().size());

		ObjectScan scan;
		timed("full list (snapshot)", repeats, [&]() { scan.snapshot(map); });

		size_t present = 0;
		size_t hidden = 0;
		size_t markers = 0;
		size_t visitable = 0;
		for(const VcmiObject & o : scan.records())
		{
			present += (o.flags & VCMI_OBJECT_PRESENT) != 0;
			hidden += (o.flags & VCMI_OBJECT_HIDDEN) != 0;
			visitable += (o.flags & VCMI_OBJECT_VISITABLE) != 0;
			markers += (o.flags & VCMI_OBJECT_PRESENT) && !(o.flags & VCMI_OBJECT_HIDDEN) && (o.flags & (VCMI_OBJECT_HERO | VCMI_OBJECT_TOWN | VCMI_OBJECT_FLAGGABLE));
		}
		std::printf("records %zu: drawn %zu, hidden heroes %zu, visitable %zu, minimap markers %zu, animations %zu\n",
			scan.records().size(), present, hidden, visitable, markers, scan.animations().size());

		// the lifecycle tick encodes every hero on the map again (garrisons fire no event)
		timed("tick: all heroes again", repeats * 10, [&]()
		{
			for(const ObjectInstanceID & hero : map.getHeroesOnMap())
				scan.update(map, hero.getNum());
		});
		// one map event: one object (a hero step)
		const int32_t firstHero = map.getHeroesOnMap().empty() ? 0 : map.getHeroesOnMap().front().getNum();
		timed("event: one object", repeats * 100, [&]() { scan.update(map, firstHero); });
		// what a publish copies under the lock for a new list
		std::vector<VcmiObject> copy;
		timed("copy of the whole list", repeats, [&]() { copy = scan.records(); });

		// the same list twice must be equal: a snapshot is deterministic and an update of an unchanged object is no change
		ObjectScan again;
		again.snapshot(map);
		bool unchanged = again.records().size() == scan.records().size()
			&& std::memcmp(again.records().data(), scan.records().data(), scan.records().size() * sizeof(VcmiObject)) == 0;
		for(size_t id = 0; id < map.objects.size(); id++)
			unchanged = !again.update(map, id) && unchanged;
		std::printf("self-check: %s\n", unchanged ? "ok" : "FAILED, an unchanged map gave changed records");
		return unchanged ? 0 : 1;
	}
	catch(const std::exception & e)
	{
		std::printf("error: %s\n", e.what());
		return 2;
	}
}

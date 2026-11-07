/*
 * ObjectBench.cpp, Meta Quest build: times the bridge's object list (quest/bridge/ObjectScan) on the headset without
 * the game: loads a saved game with VCMI's library and runs the full list and the per-event updates on it.
 * Built by quest/tools/object-bench.sh, run through app_process by NativeMethods.java (no APK, no game start).
 *
 * License: GNU General Public License v2.0 or later
 */
#include "../../Global.h"

#include "../bridge/ObjectScan.h"
#include "../bridge/SpriteDecode.h"

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

// milestone 3b, plan step 1 (quest/MILESTONE_3B.md): decodes every animation of the map and packs the frames into
// 2048x2048 pages of palette indices; writes page 0 in colour into the benchmark folder for a look
void benchSprites(std::vector<std::string> names)
{
	for(int i = 0; i < 8; i++)
		names.push_back("AF0" + std::to_string(i)); // hero flags (MapRendererObjects::getFlagAnimation)

	auto from = Clock::now();
	std::vector<SpriteAnimation> anims;
	anims.reserve(names.size());
	for(const std::string & name : names)
		anims.push_back(decodeAnimation(name));
	const double decodeMicros = microsSince(from);

	// frames of one animation with the same pixels (same offset) are packed once
	struct Rect { uint32_t anim, offset; uint16_t w, h; };
	std::vector<Rect> rects;
	// per animation, for a look on the PC (object-bench.sh pulls it to quest/out/object-bench/): which have a mod JSON
	// layout, and how many pixels trimming the transparent border (index 0) would save; in the folder run from
	FILE * table = std::fopen("sprites.tsv", "w");
	if(table)
		std::fprintf(table, "name\tdef\tjson\tframes\tdistinct\tpixels\ttrimmed\n");
	size_t frames = 0, pixels = 0, trimmed = 0, noDef = 0, withJson = 0, jsonOnly = 0, overruns = 0;
	for(uint32_t a = 0; a < anims.size(); a++)
	{
		const SpriteAnimation & anim = anims[a];
		frames += anim.frames.size();
		pixels += anim.pixels.size();
		noDef += !anim.def;
		withJson += anim.def && anim.json;
		jsonOnly += !anim.def && anim.json;
		overruns += anim.overruns;
		std::unordered_set<uint32_t> offsets;
		size_t animTrimmed = 0;
		for(const SpriteFrame & f : anim.frames)
			if(f.width && f.height && offsets.insert(f.offset).second)
			{
				rects.push_back({a, f.offset, f.width, f.height});
				int x0 = f.width, y0 = f.height, x1 = -1, y1 = -1;
				for(int y = 0; y < f.height; y++)
					for(int x = 0; x < f.width; x++)
						if(anim.pixels[f.offset + size_t(y) * f.width + x])
						{
							x0 = std::min(x0, x);
							x1 = std::max(x1, x);
							y0 = std::min(y0, y);
							y1 = std::max(y1, y);
						}
				animTrimmed += x1 < 0 ? 0 : size_t(x1 - x0 + 1) * (y1 - y0 + 1);
			}
		trimmed += animTrimmed;
		if(table)
			std::fprintf(table, "%s\t%d\t%d\t%zu\t%zu\t%zu\t%zu\n", names[a].c_str(), anim.def, anim.json, anim.frames.size(), offsets.size(),
				anim.pixels.size(), animTrimmed);
	}
	if(table)
		std::fclose(table);
	std::printf("animations %zu: no .def %zu (JSON only %zu), .def with a JSON layout %zu\n", anims.size(), noDef, jsonOnly, withJson);
	std::printf("frames %zu, distinct %zu, pixels %.1f M (trimmed to the visible box %.1f M), rows cut %zu, decode %.0f ms on one thread\n",
		frames, rects.size(), pixels / 1e6, trimmed / 1e6, overruns, decodeMicros / 1e3);

	// shelf packing, tallest first, 1 px padding
	from = Clock::now();
	constexpr int PAGE = 2048;
	std::sort(rects.begin(), rects.end(), [](const Rect & l, const Rect & r) { return l.h != r.h ? l.h > r.h : l.w > r.w; });
	std::vector<std::vector<uint8_t>> pages;
	std::vector<uint32_t> owner0; // page 0: the animation of each pixel, for the colour dump
	int x = 0, y = 0, shelf = 0;
	size_t tooBig = 0, packed = 0;
	for(const Rect & r : rects)
	{
		if(r.w + 1 > PAGE || r.h + 1 > PAGE)
		{
			tooBig++;
			continue;
		}
		if(x + r.w + 1 > PAGE)
		{
			x = 0;
			y += shelf;
			shelf = 0;
		}
		if(pages.empty() || y + r.h + 1 > PAGE)
		{
			pages.emplace_back(size_t(PAGE) * PAGE, 0);
			x = y = shelf = 0;
		}
		shelf = std::max(shelf, r.h + 1);
		const uint8_t * src = anims[r.anim].pixels.data() + r.offset;
		for(int row = 0; row < r.h; row++)
			std::memcpy(pages.back().data() + size_t(y + row) * PAGE + x, src + size_t(row) * r.w, r.w);
		if(pages.size() == 1)
		{
			owner0.resize(size_t(PAGE) * PAGE, UINT32_MAX);
			for(int row = 0; row < r.h; row++)
				std::fill_n(owner0.data() + size_t(y + row) * PAGE + x, r.w, r.anim);
		}
		x += r.w + 1;
		packed += size_t(r.w) * r.h;
	}
	const double packMicros = microsSince(from);
	std::printf("pages %zu of %dx%d R8 (%.0f MB), distinct pixels %.1f M, fill %.0f%%, too big %zu, pack %.0f ms\n", pages.size(), PAGE,
		PAGE, pages.size() * double(PAGE) * PAGE / 1e6, packed / 1e6, pages.empty() ? 0 : 100.0 * packed / (pages.size() * double(PAGE) * PAGE),
		tooBig, packMicros / 1e3);
	std::printf("decode + pack %.0f ms\n", (decodeMicros + packMicros) / 1e3);

	if(pages.empty())
		return;
	// page 0 as a PPM in the .def palettes: free space and index 0 grey, shadow entries 1-4 dark (MILESTONE_3B.md section 2)
	FILE * file = std::fopen("page0.ppm", "wb");
	if(!file)
	{
		std::printf("page0.ppm: %s\n", std::strerror(errno));
		return;
	}
	std::fprintf(file, "P6 %d %d 255\n", PAGE, PAGE);
	std::vector<uint8_t> line(PAGE * 3);
	for(int row = 0; row < PAGE; row++)
	{
		for(int col = 0; col < PAGE; col++)
		{
			const size_t at = size_t(row) * PAGE + col;
			const uint8_t index = pages[0][at];
			uint8_t * rgb = &line[col * 3];
			if(owner0[at] == UINT32_MAX || index == 0)
				rgb[0] = rgb[1] = rgb[2] = 128;
			else if(index <= 4)
				rgb[0] = rgb[1] = rgb[2] = 40;
			else
				std::memcpy(rgb, &anims[owner0[at]].palette[index * 3], 3);
		}
		std::fwrite(line.data(), 1, line.size(), file);
	}
	std::fclose(file);
	std::printf("page 0 written to page0.ppm\n");
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
		benchSprites(scan.animations());
		return unchanged ? 0 : 1;
	}
	catch(const std::exception & e)
	{
		std::printf("error: %s\n", e.what());
		return 2;
	}
}

/*
 * Bridge.cpp, Meta Quest build: the game side of the data bridge to Godot (quest/DATA_BRIDGE.md).
 * Compiled into libvcmiclient by clientapp/CMakeLists.txt when quest/bridge exists.
 * Milestone 1: the exported table, the lifecycle task and one map observer per game.
 * Milestone 2: the tile snapshot per map and the local team's fog, for the minimap in Godot.
 *
 * License: GNU General Public License v2.0 or later
 */
#include "../../Global.h"

#include "VcmiBridgeApi.h"

#include "../../client/CPlayerInterface.h"
#include "../../client/GameEngine.h"
#include "../../client/GameInstance.h"
#include "../../client/adventureMap/AdventureMapInterface.h"
#include "../../client/mapView/IMapRendererObserver.h"
#include "../../client/mapView/mapHandler.h"
#include "../../lib/CPlayerState.h"
#include "../../lib/CThreadHelper.h"
#include "../../lib/GameLibrary.h"
#include "../../lib/TerrainHandler.h"
#include "../../lib/callback/CCallback.h"
#include "../../lib/int3.h"
#include "../../lib/mapping/TerrainTile.h"

namespace
{

// the game observes nothing yet; later milestones publish object state from these events
class BridgeObserver final : public IMapObjectObserver
{
public:
	bool hasOngoingAnimations() override { return false; }
	void onObjectFadeIn(const CGObjectInstance *, const PlayerColor &) override {}
	void onObjectFadeOut(const CGObjectInstance *, const PlayerColor &) override {}
	void onObjectInstantAdd(const CGObjectInstance *, const PlayerColor &) override {}
	void onObjectInstantRemove(const CGObjectInstance *, const PlayerColor &) override {}
	void onHeroMoved(const CGHeroInstance *, const int3 &, const int3 &) override {}
	void onBeforeHeroTeleported(const CGHeroInstance *, const int3 &, const int3 &) override {}
	void onAfterHeroTeleported(const CGHeroInstance *, const int3 &, const int3 &) override {}
	void onBeforeHeroEmbark(const CGHeroInstance *, const int3 &, const int3 &) override {}
	void onAfterHeroEmbark(const CGHeroInstance *, const int3 &, const int3 &) override {}
	void onBeforeHeroDisembark(const CGHeroInstance *, const int3 &, const int3 &) override {}
	void onAfterHeroDisembark(const CGHeroInstance *, const int3 &, const int3 &) override {}
};

std::atomic<uint32_t> ticks{0};
std::atomic<uint32_t> observers{0};
std::atomic<uint32_t> mapSize{0}; // width | height << 12 | levels << 24, one value so a reader never mixes two maps
std::atomic<bool> inGame{false};
// one tick queued at most: while the game is paused (Meta menu) or loading, posted ticks would pile up
std::atomic<bool> tickPending{false};
std::once_flag started;
std::atomic<uint32_t> tilesGeneration{0};
std::atomic<uint32_t> fogGeneration{0};
std::atomic<uint32_t> publishMicros{0};

// what Godot reads: written by the game thread under this lock, which Godot only try_locks, so it never waits
std::mutex publishedMutex;
std::vector<VcmiTile> publishedTiles;
std::array<uint32_t, VCMI_TERRAIN_COLOURS * 2> publishedColours{};
VcmiGrid tilesGrid{};
std::vector<uint8_t> publishedFog;
VcmiGrid fogGrid{};

// game thread only: the adventure map and size the tile snapshot was taken for
std::weak_ptr<AdventureMapInterface> tilesMap;
int3 tilesSize;

// game thread only: the adventure maps that have an observer. A replay puts the same adventure map back when
// it ends (GameplayReplayer.cpp:347-349), with its map handler and observer, so it must not get a second one.
std::vector<std::weak_ptr<AdventureMapInterface>> observedMaps;

VcmiGrid makeGrid(const int3 & size, uint32_t generation)
{
	VcmiGrid grid{};
	grid.generation = generation;
	grid.width = size.x;
	grid.height = size.y;
	grid.levels = size.z;
	return grid;
}

// game thread, interfaceMutex held: once per map, or when the map grows a level (CMap::addLevel)
void publishTiles(const CCallback & cb, const int3 & size)
{
	std::vector<VcmiTile> snapshot(static_cast<size_t>(size.x) * size.y * size.z);
	for(int z = 0; z < size.z; z++)
		for(int x = 0; x < size.x; x++)
			for(int y = 0; y < size.y; y++)
			{
				const TerrainTile * tile = cb.getTileUnchecked(int3(x, y, z));
				if(!tile)
					continue;
				VcmiTile & out = snapshot[(static_cast<size_t>(z) * size.x + x) * size.y + y];
				// ids past the colour table (mods) share the last slot, which stays black
				out.terrain = std::min<int>(tile->terrainType.getNum(), VCMI_TERRAIN_COLOURS - 1);
				out.terrainView = tile->terView;
				out.river = tile->riverType.getNum();
				out.riverDir = tile->riverDir;
				out.road = tile->roadType.getNum();
				out.roadDir = tile->roadDir;
				// shortcut: blocking as at map load; objects that appear or vanish later update it with the object buffer (milestone 3)
				out.flags = (tile->blocked() ? VCMI_TILE_BLOCKED : 0) | (tile->visitable() ? VCMI_TILE_VISITABLE : 0);
			}
	std::array<uint32_t, VCMI_TERRAIN_COLOURS * 2> colours{};
	for(const auto & terrain : LIBRARY->terrainTypeHandler->getObjects())
		if(terrain && terrain->getIndex() >= 0 && terrain->getIndex() < VCMI_TERRAIN_COLOURS - 1)
		{
			std::memcpy(&colours[2 * terrain->getIndex()], &terrain->minimapUnblocked, 4);
			std::memcpy(&colours[2 * terrain->getIndex() + 1], &terrain->minimapBlocked, 4);
		}
	std::lock_guard lock(publishedMutex);
	publishedTiles.swap(snapshot);
	publishedColours = colours;
	tilesGrid = makeGrid(size, ++tilesGeneration);
}

// game thread, interfaceMutex held: copies the local team's fog when it differs from the last copy
void publishFog(const CCallback & cb, const int3 & size)
{
	const TeamState * team = cb.getPlayerTeam(GAME->interface()->playerID);
	if(!team)
		return;
	const auto & fog = team->fogOfWarMap;
	const size_t count = static_cast<size_t>(size.x) * size.y * size.z;
	if(static_cast<size_t>(std::distance(fog.begin(), fog.end())) != count)
		return;
	std::lock_guard lock(publishedMutex);
	if(publishedFog.size() == count && std::equal(fog.begin(), fog.end(), publishedFog.begin()))
		return;
	publishedFog.assign(fog.begin(), fog.end());
	fogGrid = makeGrid(size, ++fogGeneration);
}

// on the game GUI thread, with interfaceMutex held
void tick()
{
	tickPending = false;
	ticks++;
	if(!adventureInt)
	{
		inGame = false;
		mapSize = 0;
		return;
	}
	inGame = true;
	const int3 size = GAME->interface() && GAME->interface()->cb ? GAME->interface()->cb->getMapSize() : int3();
	mapSize = static_cast<uint32_t>(size.x) | static_cast<uint32_t>(size.y) << 12 | static_cast<uint32_t>(size.z) << 24;
	if(size.x > 0 && size.y > 0 && size.z > 0)
	{
		const auto from = std::chrono::steady_clock::now();
		const CCallback & cb = *GAME->interface()->cb;
		// a replay shows its own map, and the live one comes back when it ends: a snapshot per adventure map
		const bool newTiles = tilesMap.lock() != adventureInt || tilesSize != size;
		if(newTiles)
		{
			publishTiles(cb, size);
			tilesMap = adventureInt;
			tilesSize = size;
		}
		const uint32_t fogBefore = fogGeneration;
		publishFog(cb, size);
		if(newTiles || fogGeneration != fogBefore)
			publishMicros = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
	}
	std::erase_if(observedMaps, [](const auto & map) { return map.expired(); });
	for(const auto & map : observedMaps)
		if(map.lock() == adventureInt)
			return;

	// observers are walked with interfaceMutex released while a map animation plays (mapHandler.cpp:37-43,
	// MapViewController.cpp:546,629): adding one then could reallocate the list under that loop
	if(GAME->map().hasOngoingAnimations())
		return;

	// a new game, load or replay pass: a map exists whenever adventureInt does
	observedMaps.push_back(adventureInt);
	// shortcut: never deleted. Deleting through a destroyed map throws (mapHandler.cpp:182-185) and a replay
	// restores the old map with it still registered; a few dozen bytes per game. Freed if they ever hold buffers.
	new BridgeObserver();
	observers++;

	logGlobal->info("Quest bridge: observing a new adventure map %dx%dx%d (observer %d)", size.x, size.y, size.z, observers.load());
}

void start()
{
	std::call_once(started, []()
	{
		// a thread posts the tick: a task that re-posts itself from dispatchMainThread could be run again in the
		// same event poll, and the game has no timer to post it later
		std::thread([]()
		{
			setThreadName("questBridge");
			// shortcut: ENGINE is set once on startup and reset on quit without a lock; a tick posted while the game
			// quits can find it null just before the process exits. A clean stop needs a quit hook in the game.
			while(!ENGINE || !GAME)
				std::this_thread::sleep_for(std::chrono::milliseconds(100));
			logGlobal->info("Quest bridge %d started", VCMI_BRIDGE_VERSION);
			auto postedAt = std::chrono::steady_clock::now();
			for(;;)
			{
				// dispatchMainThread pushes its event before its task, so the game can take the event too early and
				// drop it (InputHandler.cpp:522-547); a tick pending for a second gets another event
				const auto now = std::chrono::steady_clock::now();
				if(!tickPending.exchange(true) || now - postedAt > std::chrono::seconds(1))
				{
					ENGINE->dispatchMainThread(tick);
					postedAt = now;
				}
				std::this_thread::sleep_for(std::chrono::milliseconds(100));
			}
		}).detach();
	});
}

void stats(VcmiBridgeStats * out)
{
	const uint32_t size = mapSize;
	*out = {};
	out->ticks = ticks;
	out->observers = observers;
	out->mapWidth = size & 0xfff;
	out->mapHeight = size >> 12 & 0xfff;
	out->mapLevels = size >> 24;
	out->inGame = inGame;
	out->tilesGeneration = tilesGeneration;
	out->fogGeneration = fogGeneration;
	out->publishMicros = publishMicros;
}

void copyTiles(VcmiTile * out, uint32_t capacity, uint32_t * colours, VcmiGrid * grid)
{
	*grid = {};
	std::unique_lock lock(publishedMutex, std::try_to_lock);
	if(!lock)
		return;
	*grid = tilesGrid;
	if(capacity < publishedTiles.size())
	{
		grid->generation = 0; // the size tells the caller how much to allocate
		return;
	}
	std::copy(publishedTiles.begin(), publishedTiles.end(), out);
	std::copy(publishedColours.begin(), publishedColours.end(), colours);
}

void copyFog(uint8_t * out, uint32_t capacity, VcmiGrid * grid)
{
	*grid = {};
	std::unique_lock lock(publishedMutex, std::try_to_lock);
	if(!lock)
		return;
	*grid = fogGrid;
	if(capacity < publishedFog.size())
	{
		grid->generation = 0;
		return;
	}
	std::copy(publishedFog.begin(), publishedFog.end(), out);
}

}

extern "C" __attribute__((visibility("default"))) const VcmiBridgeApi vcmi_bridge_api = {
	VCMI_BRIDGE_VERSION,
	start,
	stats,
	copyTiles,
	copyFog,
};

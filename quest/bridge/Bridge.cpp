/*
 * Bridge.cpp, Meta Quest build: the game side of the data bridge to Godot (quest/DATA_BRIDGE.md).
 * Compiled into libvcmiclient by clientapp/CMakeLists.txt when quest/bridge exists.
 * Milestone 1: the exported table, the lifecycle task and one map observer per game.
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
#include "../../lib/CThreadHelper.h"
#include "../../lib/callback/CCallback.h"
#include "../../lib/int3.h"

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

// game thread only: the adventure maps that have an observer. A replay puts the same adventure map back when
// it ends (GameplayReplayer.cpp:347-349), with its map handler and observer, so it must not get a second one.
std::vector<std::weak_ptr<AdventureMapInterface>> observedMaps;

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
}

}

extern "C" __attribute__((visibility("default"))) const VcmiBridgeApi vcmi_bridge_api = {
	VCMI_BRIDGE_VERSION,
	start,
	stats,
};

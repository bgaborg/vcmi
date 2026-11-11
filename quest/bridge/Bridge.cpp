/*
 * Bridge.cpp, Meta Quest build: the game side of the data bridge to Godot (quest/DATA_BRIDGE.md).
 * Compiled into libvcmiclient by clientapp/CMakeLists.txt when quest/bridge exists.
 * Milestone 1: the exported table, the lifecycle task and one map observer per game.
 * Milestone 2: the tile snapshot per map and the local team's fog, for the minimap in Godot.
 * Milestone 3: the object list (ObjectScan), one full list per map and then the records the map events change;
 * the tabletop window over the adventure map and the hero steps the game waits for (3c).
 *
 * License: GNU General Public License v2.0 or later
 */
#include "../../Global.h"

#include "VcmiBridgeApi.h"
// compiled here, so clientapp/CMakeLists.txt adds one file; the object benchmark compiles it on its own
#include "ObjectScan.cpp"
#include "SpriteDecode.cpp"

#include "../../client/CPlayerInterface.h"
#include "../../client/GameEngine.h"
#include "../../client/GameInstance.h"
#include "../../client/PlayerLocalState.h"
#include "../../client/adventureMap/AdventureMapInterface.h"
#include "../../client/adventureMap/AdventureMapShortcuts.h"
#include "../../client/gui/CIntObject.h"
#include "../../client/gui/CursorHandler.h"
#include "../../client/gui/Shortcut.h"
#include "../../client/gui/WindowHandler.h"
#include "../../client/mapView/IMapRendererObserver.h"
#include "../../client/mapView/mapHandler.h"
#include "../../client/replay/GameplayReplayer.h"
#include "../../lib/CConfigHandler.h"
#include "../../lib/CPlayerState.h"
#include "../../lib/CThreadHelper.h"
#include "../../lib/GameLibrary.h"
#include "../../lib/IGameSettings.h"
#include "../../lib/RiverHandler.h"
#include "../../lib/RoadHandler.h"
#include "../../lib/StartInfo.h"
#include "../../lib/TerrainHandler.h"
#include "../../lib/UnlockGuard.h"
#include "../../lib/callback/CCallback.h"
#include "../../lib/entities/faction/CTown.h"
#include "../../lib/int3.h"
#include "../../lib/mapObjects/CGHeroInstance.h"
#include "../../lib/mapObjects/CGTownInstance.h"
#include "../../lib/mapObjects/MiscObjects.h"
#include "../../lib/mapping/CMap.h"
#include "../../lib/mapping/TerrainTile.h"
#include "../../lib/pathfinder/CGPathNode.h"
#include "../../lib/texts/CGeneralTextHandler.h"
#include "../../lib/texts/MetaString.h"
#include "render/IImage.h"

namespace
{

void markObject(const CGObjectInstance * obj);
void markRemoval(const CGObjectInstance * obj);
void flushObjects();
void showMove(const CGHeroInstance * hero, const int3 & from, const int3 & dest);
bool moveWaiting();
void waitForMove();
void endMoves();

// Every event marks its object; the events after a change also publish it at once (hero step timing, milestone 3c
// needs that), the others leave it to the next event or tick: before an erase or an owner change the old state is
// still there. Owner changes come as InstantRemove + InstantAdd (NetPacksClient.cpp:731-753).
class BridgeObserver final : public IMapObjectObserver
{
public:
	// a hero step the tabletop shows: the game waits for Godot as it waits for the 2D map's animation
	bool hasOngoingAnimations() override
	{
		return moveWaiting();
	}
	void waitForOngoingAnimations() override
	{
		waitForMove();
	}
	void endNetwork() override
	{
		endMoves();
	}
	void onObjectFadeIn(const CGObjectInstance * obj, const PlayerColor &) override
	{
		markObject(obj);
		flushObjects();
	}
	void onObjectFadeOut(const CGObjectInstance * obj, const PlayerColor &) override
	{
		markRemoval(obj);
	}
	void onObjectInstantAdd(const CGObjectInstance * obj, const PlayerColor &) override
	{
		markObject(obj);
		flushObjects();
	}
	void onObjectInstantRemove(const CGObjectInstance * obj, const PlayerColor &) override
	{
		markRemoval(obj);
	}
	void onHeroMoved(const CGHeroInstance * hero, const int3 & from, const int3 & dest) override
	{
		// the step before the record: the tabletop slides a hero whose record is at the destination, so it never sees
		// the hero there before the step
		showMove(hero, from, dest);
		markObject(hero);
		flushObjects();
	}
	void onBeforeHeroTeleported(const CGHeroInstance * hero, const int3 &, const int3 &) override
	{
		markObject(hero);
	}
	void onAfterHeroTeleported(const CGHeroInstance * hero, const int3 &, const int3 &) override
	{
		markObject(hero);
		flushObjects();
	}
	void onBeforeHeroEmbark(const CGHeroInstance * hero, const int3 &, const int3 &) override
	{
		markObject(hero);
	}
	void onAfterHeroEmbark(const CGHeroInstance * hero, const int3 &, const int3 &) override
	{
		markObject(hero);
		flushObjects();
	}
	// the hero still has the boat here, not after
	void onBeforeHeroDisembark(const CGHeroInstance * hero, const int3 &, const int3 &) override
	{
		markObject(hero);
	}
	void onAfterHeroDisembark(const CGHeroInstance * hero, const int3 &, const int3 &) override
	{
		markObject(hero);
		flushObjects();
	}
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
std::vector<VcmiObject> publishedObjects;
std::vector<std::string> publishedAnimations;
std::deque<std::pair<uint32_t, int32_t>> changeLog; // sequence, object id; the oldest dropped past CHANGE_LOG
constexpr size_t CHANGE_LOG = 4096;
std::atomic<uint32_t> objectsSnapshot{0};
std::atomic<uint32_t> objectsSequence{0};
std::atomic<uint32_t> objectsMicros{0};
std::atomic<uint32_t> changeMicros{0};

// game threads, interfaceMutex held: the list of the map below, and the ids marked since the last flush
ObjectScan scan;
const CMap * scannedMap = nullptr;
std::vector<int32_t> pendingIds;
// objects about to be erased or changed with no event after it: encoded again each tick for 2 s, because the wait for
// the 2D fade releases interfaceMutex before the erase (NetPacksClient.cpp:510-537), so a tick can see them unchanged
std::vector<std::pair<int32_t, int>> removals; // id, ticks left

// The tabletop window: empty, over the adventure map while Godot shows the tabletop. The adventure map is then not the
// top window, so it does not draw, tick or animate (MapViewController::isEventVisible), and its hotkeys come here.
class TabletopWindow final : public WindowBase
{
public:
	TabletopWindow() : WindowBase(KEYBOARD)
	{
		pos = Rect(Point(), ENGINE->screenDimensions());
	}

	// as AdventureOptions: the adventure map's enabled shortcut; AdventureMapInterface::keyPressed only scrolls. Not the
	// world view: the covered 2D map draws it, so it would show nothing (quest/PHASE4.md check 5)
	void keyPressed(EShortcut key) override
	{
		static const std::set<EShortcut> worldView = {
			EShortcut::ADVENTURE_VIEW_WORLD, EShortcut::ADVENTURE_VIEW_WORLD_X1, EShortcut::ADVENTURE_VIEW_WORLD_X2, EShortcut::ADVENTURE_VIEW_WORLD_X4
		};
		if(!adventureInt || worldView.count(key))
			return;
		for(const AdventureMapShortcutState & shortcut : adventureInt->getAdventureShortcuts().getShortcuts())
			if(shortcut.shortcut == key && shortcut.isEnabled)
			{
				shortcut.callback();
				return;
			}
	}
};

std::atomic<bool> tabletopWanted{false};
std::atomic<bool> tabletopShown{false};

// a hero step the tabletop shows: the network thread waits (moveConfirmed) until Godot confirms it or the deadline
std::mutex moveMutex;
std::condition_variable moveConfirmed;
VcmiMove currentMove{};
uint32_t confirmedMove = 0;
std::chrono::steady_clock::time_point moveDeadline;
std::atomic<bool> stepPending{false}; // from the step until its wait ends
std::atomic<uint32_t> waitMicros{0};
std::atomic<uint32_t> moveTimeouts{0};

bool moveWaiting()
{
	return stepPending;
}

// network thread, interfaceMutex held (CPlayerInterface::heroMoved): publishes the step when the tabletop shows it,
// with the 2D map's own rules for what is shown (MapViewController::isEventVisible, onHeroMoved)
void showMove(const CGHeroInstance * hero, const int3 & from, const int3 & dest)
{
	// the window itself, not tabletopShown: the game may have closed it since the last tick, and the 2D map animates then
	if(from == dest || ENGINE->windows().findWindows<TabletopWindow>().empty() || replayFollowedPlayer())
		return;
	const CPlayerInterface * player = GAME->interface();
	const bool own = hero->getOwner() == player->playerID;
	const double ms = settings["adventure"][own ? "heroMoveTime" : "enemyMoveTime"].Float();
	if(ms <= 1)
		return; // instant movement
	if(!own
	   && (player->makingTurn
		   || (player->cb->getStartInfo()->playerInfos.at(hero->getOwner()).isControlledByHuman() && !settings["session"]["adventureTrackHero"].Bool())))
		return;
	if(!player->cb->isVisible(hero->convertToVisitablePos(from)) && !player->cb->isVisible(hero->convertToVisitablePos(dest)))
		return;
	const CGObjectInstance * moving = hero->inBoat() ? static_cast<const CGObjectInstance *>(hero->getBoat()) : hero;
	std::lock_guard lock(moveMutex);
	currentMove = VcmiMove{
		currentMove.sequence + 1,
		static_cast<uint32_t>(moving->id.getNum()),
		static_cast<uint16_t>(from.x),
		static_cast<uint16_t>(from.y),
		static_cast<uint16_t>(dest.x),
		static_cast<uint16_t>(dest.y),
		static_cast<uint8_t>(from.z),
		static_cast<uint8_t>(dest.z),
		static_cast<uint16_t>(std::min(ms, 65535.0))
	};
	moveDeadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(currentMove.durationMs + 200);
	stepPending = true;
}

// network thread, interfaceMutex held: as MapViewController::waitForOngoingAnimations, with the lock released, so the
// game thread keeps running. The deadline keeps a stalled or paused Godot from stalling the game.
void waitForMove()
{
	const auto from = std::chrono::steady_clock::now();
	auto unlockInterface = vstd::makeUnlockGuard(ENGINE->interfaceMutex);
	std::unique_lock lock(moveMutex);
	if(!moveConfirmed.wait_until(
		   lock,
		   moveDeadline,
		   []()
		   {
			   return confirmedMove >= currentMove.sequence;
		   }
	   ))
		moveTimeouts++;
	stepPending = false;
	waitMicros = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
}

// before the map is destroyed (Client.cpp): a waiting network thread goes on
void endMoves()
{
	std::lock_guard lock(moveMutex);
	confirmedMove = currentMove.sequence;
	moveConfirmed.notify_all();
}

// game thread, interfaceMutex held: puts the tabletop window over the adventure map while Godot wants it, again after
// the game closes it with all dialogs at each turn start and end (CPlayerInterface::closeAllDialogs). Pushed only with
// the adventure map on top and no 2D step playing (pushing then would freeze that step, MapViewController.cpp:627-631),
// and not in a replay, which shows its own map; popped only when on top (popWindow throws otherwise)
void updateTabletop()
{
	WindowHandler & windows = ENGINE->windows();
	const auto shown = windows.findWindows<TabletopWindow>();
	const bool replay = replayFollowedPlayer().has_value();
	if(tabletopWanted && !replay)
	{
		if(shown.empty() && windows.isTopWindow(adventureInt) && !GAME->map().hasOngoingAnimations())
			windows.pushWindow(std::make_shared<TabletopWindow>());
	}
	else if(!shown.empty() && windows.isTopWindow(shown.front()))
		windows.popWindow(shown.front());
	tabletopShown = !windows.findWindows<TabletopWindow>().empty();
}

std::atomic<uint32_t> selected{VCMI_NONE};
std::atomic<uint32_t> pathGeneration{0};
std::mutex pathMutex;
std::vector<VcmiPathNode> publishedPath;

// game thread, interfaceMutex held: the selection and the selected hero's path, published when it changed. The game
// has no event for a new path, and the path shrinks with each step (HeroMovementController.cpp:149): read each tick
void publishSelection()
{
	const CPlayerInterface * player = GAME->interface();
	std::vector<VcmiPathNode> nodes;
	uint32_t army = VCMI_NONE;
	if(player && player->localState)
	{
		if(const CArmedInstance * current = player->localState->getCurrentArmy())
			army = current->id.getNum();
		const CGHeroInstance * hero = player->localState->getCurrentHero();
		// getPath asserts without a path (PlayerLocalState.cpp:43-47); nodes run from the end back to the hero's tile,
		// which is left out
		if(hero && player->localState->hasPath(hero))
		{
			const CGPath & path = player->localState->getPath(hero);
			for(size_t i = path.nodes.size(); i-- > 0;)
			{
				const CGPathNode & node = path.nodes[i];
				if(i + 1 < path.nodes.size())
					nodes.push_back(
						VcmiPathNode{
							static_cast<uint16_t>(node.coord.x), static_cast<uint16_t>(node.coord.y), static_cast<uint8_t>(node.coord.z), node.turns, 0
						}
					);
			}
		}
	}
	selected = army;
	std::lock_guard lock(pathMutex);
	if(nodes.size() != publishedPath.size()
	   || !std::equal(
		   nodes.begin(),
		   nodes.end(),
		   publishedPath.begin(),
		   [](const VcmiPathNode & a, const VcmiPathNode & b)
		   {
			   return std::memcmp(&a, &b, sizeof(a)) == 0;
		   }
	   ))
	{
		publishedPath = std::move(nodes);
		pathGeneration++;
	}
}

std::mutex panelMutex;
VcmiPanel publishedPanel{}; // generation 0 outside a game

// game thread, each tick: what the 2D side panel shows (CResDataBar, CHeroList, CTownList), for the table's panel
void publishPanel()
{
	VcmiPanel next{};
	CPlayerInterface * player = GAME->interface();
	if(player && player->cb && player->localState)
	{
		const ResourceSet resources = player->cb->getResourceAmount();
		for(int i = 0; i < VCMI_PANEL_RESOURCES; i++)
			next.resources[i] = resources[GameResID(i)];
		const auto calendar = player->cb->getCalendar();
		next.day = static_cast<uint16_t>(calendar.getDayOfWeek());
		next.week = static_cast<uint16_t>(calendar.getWeek());
		next.month = static_cast<uint16_t>(calendar.getMonth());
		// as CResDataBar::buildDateString
		MetaString date;
		date.appendTextID("vcmi.adventureMap.dateFormat");
		date.replaceTokenTextID("%MONTH", "core.genrltxt.62");
		date.replaceTokenNumber("%MONTHNUMBER", calendar.getMonth());
		date.replaceTokenTextID("%WEEK", "core.genrltxt.63");
		date.replaceTokenNumber("%WEEKNUMBER", calendar.getWeek());
		date.replaceTokenTextID("%DAY", "core.genrltxt.64");
		date.replaceTokenNumber("%DAYNUMBER", calendar.getDayOfWeek());
		const auto copyName = [](char * out, size_t capacity, const std::string & text)
		{
			// cut at a character boundary: no half UTF-8 sequence at the end
			size_t length = std::min(text.size(), capacity - 1);
			while(length > 0 && length < text.size() && (static_cast<uint8_t>(text[length]) & 0xc0) == 0x80)
				length--;
			std::memcpy(out, text.data(), length);
			out[length] = 0;
		};
		copyName(next.date, sizeof(next.date), date.toString(&GAME->translator()));
		for(const CGHeroInstance * hero : player->localState->getWanderingHeroes())
		{
			if(next.heroCount == VCMI_PANEL_HEROES)
				break;
			VcmiPanelHero & out = next.heroes[next.heroCount++];
			out.id = hero->id.getNum();
			out.portrait = static_cast<uint16_t>(hero->getIconIndex());
			out.movement = static_cast<uint16_t>(std::clamp(hero->movementPointsRemaining(), 0, 0xffff));
			out.maxMovement = static_cast<uint16_t>(std::clamp(hero->movementPointsLimit(), 0, 0xffff));
			out.mana = static_cast<uint16_t>(std::clamp(hero->mana, 0, 0xffff));
			out.maxMana = static_cast<uint16_t>(std::clamp(hero->manaLimit(), 0, 0xffff));
			out.sleeping = player->localState->isHeroSleeping(hero) ? 1 : 0;
			copyName(out.name, sizeof(out.name), GAME->translator().translate(hero->getNameTextID()));
		}
		const int buildCap = player->cb->getSettings().getInteger(EGameSettings::TOWNS_BUILDINGS_PER_TURN_CAP);
		for(const CGTownInstance * town : player->localState->getOwnedTowns())
		{
			if(next.townCount == VCMI_PANEL_TOWNS)
				break;
			VcmiPanelTown & out = next.towns[next.townCount++];
			out.id = town->id.getNum();
			// as CTownList::CTownItem::update
			out.icon = static_cast<uint16_t>(town->getTown()->clientInfo.icons[town->hasFort()][town->built >= buildCap] + 2);
			copyName(out.name, sizeof(out.name), GAME->translator().translate(town->getNameTextID()));
		}
	}
	std::lock_guard lock(panelMutex);
	next.generation = publishedPanel.generation;
	if(std::memcmp(&next, &publishedPanel, sizeof(next)) != 0 || next.generation == 0)
	{
		next.generation = publishedPanel.generation + 1 == 0 ? 1 : publishedPanel.generation + 1;
		publishedPanel = next;
	}
}

std::atomic<uint8_t> windowsAbove{0};
std::atomic<uint32_t> inputsRun{0};
std::atomic<uint32_t> inputsDropped{0};

// tile input from Godot: the latest hover, and the other inputs in order
struct TileInput
{
	int3 tile;
	uint8_t kind;
	uint32_t object = VCMI_NONE; // SELECT and OPEN: the hero or town
};
// panel selections in the tile input queue, after the tile kinds (selectObject)
constexpr uint8_t SELECT_OBJECT = 100;
constexpr uint8_t OPEN_OBJECT = 101;
std::mutex inputMutex;
std::optional<TileInput> pendingHover;
std::vector<TileInput> pendingInputs;

// game thread, interfaceMutex held, after updateTabletop: runs the queued tile inputs through the adventure map's own
// tile handlers (PHASE4.md decision 1). They check only the adventure state, not whether the map is covered, so the
// input is dropped while a window is over the tabletop window: a click would walk the hero away behind a dialog.
// game thread: the local player's hero or town `id`, as CHeroList::CHeroItem and CTownList::CTownItem select and open
// it; nothing for another player's object
void selectOwned(uint32_t id, bool open)
{
	CPlayerInterface * player = GAME->interface();
	for(const CGHeroInstance * hero : player->localState->getWanderingHeroes())
		if(hero->id.getNum() == static_cast<int32_t>(id))
		{
			if(open)
				player->openHeroWindow(hero);
			else
				player->localState->setSelection(hero);
			return;
		}
	for(const CGTownInstance * town : player->localState->getOwnedTowns())
		if(town->id.getNum() == static_cast<int32_t>(id))
		{
			if(open)
				player->openTownWindow(town);
			else
				player->localState->setSelection(town);
			return;
		}
}

void runTileInputs()
{
	std::vector<TileInput> inputs;
	{
		std::lock_guard lock(inputMutex);
		if(pendingHover)
			inputs.push_back(*pendingHover);
		inputs.insert(inputs.end(), pendingInputs.begin(), pendingInputs.end());
		pendingHover.reset();
		pendingInputs.clear();
	}
	WindowHandler & windows = ENGINE->windows();
	const auto stack = windows.findWindows<IShowActivatable>(); // bottom to top
	const auto tabletop = windows.findWindows<TabletopWindow>();
	const auto at = tabletop.empty() ? stack.end() : std::find(stack.begin(), stack.end(), tabletop.front());
	windowsAbove = at == stack.end() ? 0 : static_cast<uint8_t>(std::min<size_t>(stack.end() - at - 1, 255));
	for(const TileInput & input : inputs)
	{
		// the popup's end closes it, which is above the tabletop by then; as EventDispatcher::dispatchClosePopup, which
		// also covers the object popups (CInfoBoxPopup and others are not CRClickPopup)
		if(input.kind == VCMI_TILE_POPUP_END)
		{
			if(windows.isTopWindowPopup())
				windows.popWindows(1);
			continue;
		}
		const CPlayerInterface * player = GAME->interface();
		if(input.kind == SELECT_OBJECT || input.kind == OPEN_OBJECT)
		{
			// as the 2D lists: only in the player's own turn (AdventureMapShortcuts::optionSidePanelActive)
			if(tabletop.empty() || !windows.isTopWindow(tabletop.front()) || !player || !player->localState || !player->makingTurn)
				inputsDropped++;
			else
			{
				inputsRun++;
				selectOwned(input.object, input.kind == OPEN_OBJECT);
			}
			continue;
		}
		// per input: the click before may have opened a dialog in this same tick
		if(tabletop.empty() || !windows.isTopWindow(tabletop.front()) || !player || !player->cb || !player->cb->isInTheMap(input.tile)
		   || !player->localState->getCurrentArmy())
		{
			inputsDropped++;
			continue;
		}
		inputsRun++;
		switch(input.kind)
		{
			case VCMI_TILE_HOVER:
			{
				adventureInt->onTileHovered(input.tile);
				// check 2 of PHASE4.md: the cursor the hover set
				const auto image = ENGINE->cursor().getCurrentImage();
				logGlobal->debug(
					"Quest bridge: hover %s -> cursor %p %dx%d",
					input.tile.toString(),
					static_cast<const void *>(image.get()),
					image ? image->width() : 0,
					image ? image->height() : 0
				);
				break;
			}
			case VCMI_TILE_CLICK:
				adventureInt->onTileLeftClicked(input.tile);
				break;
			case VCMI_TILE_POPUP:
				adventureInt->onTileRightClicked(input.tile);
				break;
		}
	}
}

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
				out.flips = tile->extTileFlags;
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

void markObject(const CGObjectInstance * obj)
{
	if(!obj)
		return;
	pendingIds.push_back(obj->id.getNum());
	// a hero and its boat move and turn together
	if(obj->ID == Obj::HERO)
	{
		const auto * hero = static_cast<const CGHeroInstance *>(obj);
		if(hero->inBoat() && hero->getBoat())
			pendingIds.push_back(hero->getBoat()->id.getNum());
	}
	else if(obj->ID == Obj::BOAT)
		if(const auto * boat = dynamic_cast<const CGBoat *>(obj); boat && boat->getBoardedHero())
			pendingIds.push_back(boat->getBoardedHero()->id.getNum());
}

void markRemoval(const CGObjectInstance * obj)
{
	markObject(obj);
	if(obj)
		removals.emplace_back(obj->id.getNum(), 20);
	if(const auto * hero = dynamic_cast<const CGHeroInstance *>(obj); hero && hero->inBoat() && hero->getBoat())
		removals.emplace_back(hero->getBoat()->id.getNum(), 20);
}

// game threads, interfaceMutex held: encodes the marked objects and publishes the records that changed
void flushObjects()
{
	if(pendingIds.empty())
		return;
	const auto from = std::chrono::steady_clock::now();
	const CMap * map = GAME->map().getMap();
	if(map != scannedMap)
	{
		pendingIds.clear(); // the next tick takes the list of the new map
		return;
	}
	std::sort(pendingIds.begin(), pendingIds.end());
	pendingIds.erase(std::unique(pendingIds.begin(), pendingIds.end()), pendingIds.end());
	std::erase_if(
		pendingIds,
		[map](int32_t id)
		{
			return !scan.update(*map, id);
		}
	);
	if(!pendingIds.empty())
	{
		const auto & records = scan.records();
		std::lock_guard lock(publishedMutex);
		if(publishedObjects.size() < records.size())
			publishedObjects.resize(records.size());
		uint32_t sequence = objectsSequence;
		for(int32_t id : pendingIds)
		{
			publishedObjects[id] = records[id];
			changeLog.emplace_back(++sequence, id);
		}
		while(changeLog.size() > CHANGE_LOG)
			changeLog.pop_front();
		for(size_t i = publishedAnimations.size(); i < scan.animations().size(); i++)
			publishedAnimations.push_back(scan.animations()[i]);
		objectsSequence = sequence;
		changeMicros = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
	}
	pendingIds.clear();
}

// game thread, interfaceMutex held: the whole list, once per map (and for each new observer, which may have missed
// events)
void publishObjectSnapshot()
{
	const auto from = std::chrono::steady_clock::now();
	const CMap * map = GAME->map().getMap();
	scan.snapshot(*map);
	scannedMap = map;
	pendingIds.clear();
	removals.clear();
	{
		std::lock_guard lock(publishedMutex);
		publishedObjects = scan.records();
		publishedAnimations = scan.animations();
		changeLog.clear();
		++objectsSnapshot;
	}
	objectsMicros = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
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
		tabletopShown = false;
		selected = VCMI_NONE;
		windowsAbove = 0;
		{
			std::lock_guard panelLock(panelMutex);
			publishedPanel = {};
		}
		std::lock_guard lock(pathMutex);
		if(!publishedPath.empty())
		{
			publishedPath.clear();
			pathGeneration++;
		}
		return;
	}
	inGame = true;
	updateTabletop();
	runTileInputs();
	publishSelection();
	publishPanel();
	const int3 size = GAME->interface() && GAME->interface()->cb ? GAME->interface()->cb->getMapSize() : int3();
	mapSize = static_cast<uint32_t>(size.x) | static_cast<uint32_t>(size.y) << 12 | static_cast<uint32_t>(size.z) << 24;
	bool listTaken = false;
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
		listTaken = newTiles || scannedMap != GAME->map().getMap();
		if(listTaken)
			publishObjectSnapshot();
		else
		{
			// a hero entering or leaving a garrison fires no map event (NetPacksClient.cpp:664-683): heroes are
			// encoded again each tick, about 150 on a big map. Erased objects, marked by their FadeOut, flush here.
			for(const ObjectInstanceID & hero : scannedMap->getHeroesOnMap())
				pendingIds.push_back(hero.getNum());
			for(auto & [id, left] : removals)
			{
				pendingIds.push_back(id);
				left--;
			}
			std::erase_if(
				removals,
				[](const auto & removal)
				{
					return removal.second <= 0;
				}
			);
			flushObjects();
		}
	}
	std::erase_if(
		observedMaps,
		[](const auto & map)
		{
			return map.expired();
		}
	);
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
	if(!listTaken)
		publishObjectSnapshot();

	logGlobal->info("Quest bridge: observing a new adventure map %dx%dx%d (observer %d)", size.x, size.y, size.z, observers.load());
}

void start()
{
	std::call_once(
		started,
		[]()
		{
			// a thread posts the tick: a task that re-posts itself from dispatchMainThread could be run again in the
			// same event poll, and the game has no timer to post it later
			std::thread(
				[]()
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
				}
			).detach();
		}
	);
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
	out->objectsSnapshot = objectsSnapshot;
	out->objectsSequence = objectsSequence;
	out->objectsMicros = objectsMicros;
	out->changeMicros = changeMicros;
	out->tabletop = tabletopShown;
	out->windowsAbove = windowsAbove;
	out->inputsRun = inputsRun;
	out->inputsDropped = inputsDropped;
	out->selected = selected;
	out->pathGeneration = pathGeneration;
	out->waitMicros = waitMicros;
	out->moveTimeouts = moveTimeouts;
	std::lock_guard lock(moveMutex);
	out->moveSequence = currentMove.sequence;
}

void tileInput(uint16_t x, uint16_t y, uint8_t z, uint8_t kind)
{
	std::lock_guard lock(inputMutex);
	if(kind == VCMI_TILE_HOVER)
		pendingHover = TileInput{int3(x, y, z), kind};
	else if(pendingInputs.size() < 64) // shortcut: the tick drains them every 100 ms; more is a stuck game
		pendingInputs.push_back(TileInput{int3(x, y, z), kind});
}

void copyPanel(VcmiPanel * out)
{
	std::unique_lock lock(panelMutex, std::try_to_lock);
	if(!out)
		return;
	if(!lock)
	{
		out->generation = 0;
		return;
	}
	*out = publishedPanel;
}

void selectObject(uint32_t id, uint8_t open)
{
	std::lock_guard lock(inputMutex);
	if(pendingInputs.size() < 64)
		pendingInputs.push_back(TileInput{int3(), open ? OPEN_OBJECT : SELECT_OBJECT, id});
}

uint32_t copyPath(VcmiPathNode * out, uint32_t capacity)
{
	std::unique_lock lock(pathMutex, std::try_to_lock);
	if(!lock)
		return VCMI_NONE;
	if(capacity >= publishedPath.size())
		std::copy(publishedPath.begin(), publishedPath.end(), out);
	return static_cast<uint32_t>(publishedPath.size());
}

void setTabletop(uint8_t shown)
{
	tabletopWanted = shown != 0;
}

void copyMove(VcmiMove * out)
{
	std::lock_guard lock(moveMutex);
	*out = currentMove;
}

void confirmMove(uint32_t sequence)
{
	std::lock_guard lock(moveMutex);
	confirmedMove = std::max(confirmedMove, sequence);
	moveConfirmed.notify_all();
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

void copyObjects(VcmiObject * out, uint32_t capacity, VcmiObjectList * list)
{
	*list = {};
	std::unique_lock lock(publishedMutex, std::try_to_lock);
	if(!lock)
		return;
	list->count = publishedObjects.size();
	list->animations = publishedAnimations.size();
	if(capacity < publishedObjects.size())
		return; // the count tells the caller how much to allocate
	list->snapshot = objectsSnapshot;
	list->sequence = objectsSequence;
	std::copy(publishedObjects.begin(), publishedObjects.end(), out);
}

void copyObjectChanges(uint32_t snapshot, uint32_t since, VcmiObject * out, uint32_t capacity, VcmiObjectChanges * changes)
{
	*changes = {};
	std::unique_lock lock(publishedMutex, std::try_to_lock);
	if(!lock)
		return;
	const uint32_t sequence = objectsSequence;
	changes->animations = publishedAnimations.size();
	if(since == sequence && snapshot == objectsSnapshot)
	{
		changes->sequence = sequence;
		return;
	}
	// the log must still hold every change after `since`
	const auto first = std::upper_bound(
		changeLog.begin(),
		changeLog.end(),
		since,
		[](uint32_t value, const auto & entry)
		{
			return value < entry.first;
		}
	);
	const size_t count = changeLog.end() - first;
	if(snapshot != objectsSnapshot || since > sequence || changeLog.empty() || changeLog.front().first > since + 1 || count > capacity)
	{
		changes->resync = 1;
		return;
	}
	for(auto entry = first; entry != changeLog.end(); ++entry)
		*out++ = publishedObjects[entry->second];
	changes->count = count;
	changes->sequence = sequence;
}

uint32_t copyAnimation(uint32_t index, char * out, uint32_t capacity)
{
	std::unique_lock lock(publishedMutex, std::try_to_lock);
	if(!lock || index >= publishedAnimations.size() || capacity == 0)
		return 0;
	const std::string & name = publishedAnimations[index];
	const size_t length = std::min<size_t>(name.size(), capacity - 1);
	std::memcpy(out, name.data(), length);
	out[length] = 0;
	return length;
}

// as MapRendererTerrain, MapRendererRiver and MapRendererRoad load them (client/mapView/MapRenderer.cpp)
uint32_t tileAnimation(uint8_t layer, uint8_t id, char * out, uint32_t capacity)
{
	if(!inGame.load() || capacity == 0)
		return 0;
	std::string spec;
	const auto describe = [&spec](const AnimationPath & file, char mode, const auto & palette)
	{
		spec = file.getOriginalName() + "#" + mode;
		for(const auto & range : palette)
			spec += "," + std::to_string(range.start) + ":" + std::to_string(range.length);
	};
	// terrain ids past the colour table share its last slot (publishTiles): no animation for that one
	if(layer == VCMI_LAYER_TERRAIN && id < VCMI_TERRAIN_COLOURS - 1 && id < LIBRARY->terrainTypeHandler->size())
	{
		const auto * terrain = LIBRARY->terrainTypeHandler->getById(TerrainId(id));
		if(terrain)
			describe(terrain->tilesFilename, 'o', terrain->paletteAnimation);
	}
	else if(layer == VCMI_LAYER_RIVER && id != RiverId::NO_RIVER.getNum() && id < LIBRARY->riverTypeHandler->size())
	{
		const auto * river = LIBRARY->riverTypeHandler->getById(RiverId(id));
		if(river)
			describe(river->tilesFilename, 'k', river->paletteAnimation);
	}
	else if(layer == VCMI_LAYER_ROAD && id != RoadId::NO_ROAD.getNum() && id < LIBRARY->roadTypeHandler->size())
	{
		const auto * road = LIBRARY->roadTypeHandler->getById(RoadId(id));
		if(road)
			describe(road->tilesFilename, 'k', std::vector<RiverPaletteAnimation>());
	}
	if(spec.empty() || spec[0] == '#')
		return 0;
	const size_t length = std::min<size_t>(spec.size(), capacity - 1);
	std::memcpy(out, spec.data(), length);
	out[length] = 0;
	return length;
}

uint32_t decodeFrames(const char * name, VcmiAnimationData * out)
{
	// per calling thread, so Godot's workers decode side by side; valid until that thread's next call
	thread_local SpriteAnimation anim;
	anim = {};
	// the filesystem is set up before a game exists and stays until the process ends; no mod reload while in game
	if(name && inGame.load())
	{
		try
		{
			anim = decodeAnimation(name);
		}
		catch(const std::exception & e)
		{
			logGlobal->warn("Quest bridge: animation %s: %s", name, e.what());
			anim = {};
		}
	}
	if(out)
		*out = {anim.frames.data(), anim.data.data(), anim.palette.data(), static_cast<uint32_t>(anim.frames.size()), static_cast<uint32_t>(anim.data.size())};
	return static_cast<uint32_t>(anim.frames.size());
}

}

static_assert(sizeof(VcmiFrame) == 36, "VcmiFrame is part of the bridge ABI");
static_assert(sizeof(VcmiMove) == 20, "VcmiMove is part of the bridge ABI");
static_assert(sizeof(VcmiPathNode) == 8, "VcmiPathNode is part of the bridge ABI");
static_assert(sizeof(VcmiPanelHero) == 64, "VcmiPanelHero is part of the bridge ABI");
static_assert(sizeof(VcmiPanelTown) == 56, "VcmiPanelTown is part of the bridge ABI");

extern "C" __attribute__((visibility("default"))) const VcmiBridgeApi vcmi_bridge_api = {
	VCMI_BRIDGE_VERSION,
	start,
	stats,
	copyTiles,
	copyFog,
	copyObjects,
	copyObjectChanges,
	copyAnimation,
	decodeFrames,
	setTabletop,
	copyMove,
	confirmMove,
	tileInput,
	copyPath,
	tileAnimation,
	copyPanel,
	selectObject,
};

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

#include <fstream>
// compiled here, so clientapp/CMakeLists.txt adds one file; the object benchmark compiles it on its own
#include "ObjectScan.cpp"
#include "SpriteDecode.cpp"

#include "../../client/CPlayerInterface.h"
#include "../../client/CServerHandler.h"
#include "../../client/Client.h"
#include "../../client/GameEngine.h"
#include "../../client/GameInstance.h"
#include "../../client/PlayerLocalState.h"
#include "../../client/adventureMap/AdventureMapInterface.h"
#include "../../client/adventureMap/AdventureMapShortcuts.h"
#include "../../client/battle/BattleActionsController.h"
#include "../../client/battle/BattleFieldController.h"
#include "../../client/battle/BattleInterface.h"
#include "../../client/battle/BattleSiegeController.h"
#include "../../client/battle/BattleStacksController.h"
#include "../../client/battle/BattleWindow.h"
#include "../../client/gui/CIntObject.h"
#include "../../client/gui/CursorHandler.h"
#include "../../client/gui/EventDispatcher.h"
#include "../../client/gui/Shortcut.h"
#include "../../client/gui/WindowHandler.h"
#include "../../client/mapView/IMapRendererObserver.h"
#include "../../client/mapView/mapHandler.h"
#include "../../client/replay/GameplayReplayer.h"
#include "../../lib/BattleFieldHandler.h"
#include "../../lib/CConfigHandler.h"
#include "../../lib/CCreatureHandler.h"
#include "../../lib/CPlayerState.h"
#include "../../lib/CStack.h"
#include "../../lib/CThreadHelper.h"
#include "../../lib/GameLibrary.h"
#include "../../lib/IGameSettings.h"
#include "../../lib/RiverHandler.h"
#include "../../lib/RoadHandler.h"
#include "../../lib/StartInfo.h"
#include "../../lib/TerrainHandler.h"
#include "../../lib/UnlockGuard.h"
#include "../../lib/VCMIDirs.h"
#include "../../lib/battle/AccessibilityInfo.h"
#include "../../lib/battle/CPlayerBattleCallback.h"
#include "../../lib/callback/CCallback.h"
#include "../../lib/callback/IBattleEventsReceiver.h"
#include "../../lib/entities/faction/CTown.h"
#include "../../lib/entities/hero/CHero.h"
#include "../../lib/entities/hero/CHeroClass.h"
#include "../../lib/int3.h"
#include "../../lib/mapObjects/CGHeroInstance.h"
#include "../../lib/mapObjects/CGTownInstance.h"
#include "../../lib/mapObjects/MiscObjects.h"
#include "../../lib/mapping/CMap.h"
#include "../../lib/mapping/TerrainTile.h"
#include "../../lib/networkPacks/PacksForClientBattle.h"
#include "../../lib/pathfinder/CGPathNode.h"
#include "../../lib/spells/CSpell.h"
#include "../../lib/texts/CGeneralTextHandler.h"
#include "../../lib/texts/MetaString.h"
#include "media/ISoundPlayer.h"
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
std::atomic<bool> tableBattleWanted{false}; // setTableBattle
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

std::mutex battleMutex;
VcmiBattle publishedBattle{};

// the last attack or spell, for the table's animations (quest/PHASE5.md): written by the network thread
struct BattleAction
{
	uint32_t sequence = 0;
	uint32_t stack = VCMI_NONE;
	uint32_t target = VCMI_NONE;
	uint16_t hex = 0xffff;
	uint8_t kind = 0;
	uint8_t side = 255;
	std::string effect;
	std::vector<uint32_t> targets; // a spell's: every stack it affects
	bool onHex = false; // the effect is the spell's `hit` animation: once on its hex, not on each target
	std::vector<RayColor> ray; // a spell's ray from target to target (chain lightning: BattleInterface usesChainRay)
	std::string sound; // a spell's cast sound
};
std::mutex actionMutex;
BattleAction lastAction;

// a spell's ray colours from the outer lines to the middle, spread over its width as BattleProjectileController
// expandRayColors does (it is file-local there)
// shortcut: at most VCMI_RAY_LINES lines, half chain lightning's 16; widen the array if it looks thin
std::vector<RayColor> spreadRay(const std::vector<RayColor> & keys, int width)
{
	width = std::min(width, VCMI_RAY_LINES);
	if(keys.empty() || width <= static_cast<int>(keys.size()))
		return keys;
	std::vector<RayColor> out(width);
	const float centre = (width - 1) / 2.f;
	for(int k = 0; k < width; ++k)
	{
		const float at = (1.f - std::abs(k - centre) / centre) * (keys.size() - 1);
		const int i0 = static_cast<int>(at);
		const int i1 = std::min<int>(i0 + 1, keys.size() - 1);
		out[k].start = vstd::lerp(keys[i0].start, keys[i1].start, at - i0);
		out[k].end = vstd::lerp(keys[i0].end, keys[i1].end, at - i0);
	}
	return out;
}

// The game gives battle events to extra receivers after the 2D battle interface (NetPacksClient.cpp
// callOnlyThatBattleInterface). Only what the published state cannot tell is kept: who struck whom, and spells.
class BattleEvents final : public IBattleEventsReceiver
{
public:
	// battleStart itself goes to the 2D interface only (CClient::battleStarted)
	void battleStartBefore(const BattleID &, const CCreatureSet *, const CCreatureSet *, int3, const CGHeroInstance *, const CGHeroInstance *) override
	{
		std::lock_guard lock(actionMutex);
		lastAction = {};
	}
	void battleAttack(const BattleID &, const BattleAttack * attack) override
	{
		if(!attack)
			return;
		std::lock_guard lock(actionMutex);
		lastAction.sequence++;
		lastAction.kind = attack->shot() ? VCMI_ACTION_SHOT : VCMI_ACTION_ATTACK;
		lastAction.stack = attack->stackAttacking;
		lastAction.target = attack->bsa.empty() ? VCMI_NONE : attack->bsa.front().stackAttacked;
		lastAction.hex = 0xffff;
		lastAction.side = 255;
		lastAction.effect.clear();
		lastAction.targets.clear();
		lastAction.ray.clear();
		lastAction.sound.clear();
	}
	void battleSpellCast(const BattleID &, const BattleSpellCast * cast) override
	{
		if(!cast)
			return;
		std::lock_guard lock(actionMutex);
		lastAction.sequence++;
		lastAction.kind = VCMI_ACTION_SPELL;
		lastAction.stack = cast->casterStack >= 0 ? static_cast<uint32_t>(cast->casterStack) : VCMI_NONE;
		lastAction.target = cast->affectedCres.empty() ? VCMI_NONE : cast->affectedCres.front();
		lastAction.targets = cast->affectedCres;
		lastAction.hex = cast->tile.isValid() ? static_cast<uint16_t>(cast->tile.toInt()) : 0xffff;
		lastAction.side = cast->castByHero && cast->casterStack < 0 ? (cast->side == BattleSide::DEFENDER ? 1 : 0) : 255;
		// the first picture the 2D battle plays on what the spell affects, else on the hex it hits
		// as BattleInterface: `affect` plays on each stack it affects, `hit` once on the target hex or over the field
		lastAction.effect.clear();
		lastAction.onHex = false;
		lastAction.ray.clear();
		lastAction.sound.clear();
		if(const CSpell * spell = cast->spellID.toSpell())
		{
			lastAction.sound = spell->getCastSound().getOriginalName();
			if(cast->affectedCres.size() > 1)
				lastAction.ray = spreadRay(spell->animationInfo.ray, spell->animationInfo.rayWidth);
			for(const auto * queue : {&spell->animationInfo.affect, &spell->animationInfo.hit})
				for(const auto & item : *queue)
					if(lastAction.effect.empty() && !item.resourceName.empty())
					{
						lastAction.effect = item.resourceName.getOriginalName();
						lastAction.onHex = queue == &spell->animationInfo.hit;
					}
		}
	}
};

// game thread, each tick: the receiver is registered once for each client (a new one per game), for the local player.
// shortcut: one colour; in hot-seat the other human's battles show without attack events (the table guesses then).
// The client's list is read by the network thread without a lock: registered at a game's start, before any battle.
const CClient * battleEventsClient = nullptr; // forgotten between games: the next client may get the same address

void registerBattleEvents()
{
	const CClient *& registered = battleEventsClient;
	static const std::shared_ptr<BattleEvents> events = std::make_shared<BattleEvents>();
	CClient * client = GAME->server().client.get();
	if(!client || client == registered || !GAME->interface())
		return;
	client->registerBattleInterface(events, GAME->interface()->playerID);
	registered = client;
}
std::mutex hexMutex;
std::optional<uint16_t> pendingHexHover;
std::vector<uint16_t> pendingHexClicks;

// The pieces of the besieged town's walls as BattleSiegeController shows them now (its getWallPieceImageName,
// getWallPieceExistence, applyGateState and showWallPiece, which are private): the moat first, then the walls in
// their drawing order. A copy of that logic: check it against the controller when a siege looks wrong after a rebase.
void wallPieces(const BattleSiegeController & siege, const CPlayerBattleCallback & state, VcmiBattle & out)
{
	const CGTownInstance * town = siege.getSiegedTown();
	if(!town || !town->getTown())
		return;
	const auto & fort = town->fortificationsLevel();
	const auto & positions = town->getTown()->clientInfo.siegePositions;
	const auto add = [&](int visual, const std::string & name)
	{
		if(out.wallCount == VCMI_WALL_PIECES || visual >= static_cast<int>(positions.size()) || !positions[visual].isValid())
			return;
		VcmiWallPiece & piece = out.walls[out.wallCount++];
		std::memcpy(piece.name, name.data(), std::min(name.size(), sizeof(piece.name) - 1));
		piece.x = static_cast<int16_t>(positions[visual].x);
		piece.y = static_cast<int16_t>(positions[visual].y);
	};
	const auto health = [&](EWallPart part)
	{
		return static_cast<int>(state.battleGetWallState(part));
	};
	const auto tower = [&](EWallPart part)
	{
		return health(part) != 0 ? "1" : "2"; // a tower the town has not built (no state) is drawn whole, as in 2D
	};
	const auto wall = [&](EWallPart part)
	{
		return health(part) == fort.wallsHealth ? "1" : health(part) > 0 ? "2" : "3";
	};
	if(fort.hasMoat)
	{
		add(EWallVisual::MOAT, "MOAT");
		add(EWallVisual::MOAT_BANK, "MLIP");
	}
	const FactionID faction = town->getFactionID();
	const bool low = faction == ETownType::RAMPART || faction == ETownType::NECROPOLIS || faction == ETownType::DUNGEON || faction == ETownType::STRONGHOLD;
	// in the 2D battle's drawing order: by the row of the hex each piece is bound to (getWallPiecePosition), back to front
	add(EWallVisual::BACKGROUND_WALL, low ? "TPW1" : "TPWL");
	add(EWallVisual::UPPER_TOWER, std::string("TW2") + tower(EWallPart::UPPER_TOWER));
	// the closed gate is part of the static wall; lowered and destroyed it has its own pictures
	const EGateState gate = state.battleGetGateState();
	if(gate == EGateState::OPENED)
		add(EWallVisual::GATE, "DRW2");
	else if(gate == EGateState::DESTROYED)
		add(EWallVisual::GATE, "DRW3");
	if(fort.upperTowerHealth > 0 && health(EWallPart::UPPER_TOWER) > 0)
		add(EWallVisual::UPPER_BATTLEMENT, "TW2C");
	add(EWallVisual::UPPER_WALL, std::string("WA6") + wall(EWallPart::UPPER_WALL));
	add(EWallVisual::UPPER_STATIC_WALL, "WA5");
	add(EWallVisual::WALL_OVER_GATE, std::string("WA4") + wall(EWallPart::OVER_GATE));
	add(EWallVisual::GATE_ARCH, "ARCH");
	add(EWallVisual::WALL_BELLOW_GATE, std::string("WA3") + wall(EWallPart::BELOW_GATE));
	add(EWallVisual::KEEP, std::string("MAN") + tower(EWallPart::KEEP));
	if(fort.citadelHealth > 0 && health(EWallPart::KEEP) > 0)
		add(EWallVisual::KEEP_BATTLEMENT, "MANC");
	add(EWallVisual::BOTTOM_STATIC_WALL, "WA2");
	add(EWallVisual::BOTTOM_WALL, std::string("WA1") + wall(EWallPart::BOTTOM_WALL));
	add(EWallVisual::BOTTOM_TOWER, std::string("TW1") + tower(EWallPart::BOTTOM_TOWER));
	if(fort.lowerTowerHealth > 0 && health(EWallPart::BOTTOM_TOWER) > 0)
		add(EWallVisual::BOTTOM_BATTLEMENT, "TW1C");
}

// game thread, interfaceMutex held, each tick: the battle the game shows, for the table (quest/PHASE5.md 5b), and the
// hex inputs from the table, run as BattleFieldController::mouseMoved and activateHoveredHex run the mouse's
void publishBattle()
{
	std::optional<uint16_t> hover;
	std::vector<uint16_t> clicks;
	{
		std::lock_guard lock(hexMutex);
		hover.swap(pendingHexHover);
		clicks.swap(pendingHexClicks);
	}
	VcmiBattle next{};
	const std::shared_ptr<BattleInterface> battle = CPlayerInterface::battleInt;
	// the battle is gone from the client before its window is (the result window): getBattle throws then
	std::shared_ptr<CPlayerBattleCallback> state;
	try
	{
		if(battle && battle->curInt && battle->curInt->cb)
			state = battle->getBattle();
	}
	catch(const std::runtime_error &)
	{
	}
	if(state && battle->stacksController && battle->actionsController)
	{
		// input only while the battle window is the top one: not under its result, a spell book or a question
		if(battle->windowObject && ENGINE->windows().isTopWindow(battle->windowObject) && !battle->openingPlaying() && battle->curInt)
		{
			// The game's mouse goes to the hex, as a mouse move does (BattleFieldController::mouseMoved: the hovered hex,
			// the hover's cursor and status text). The 2D battle attacks from the legal hex nearest the mouse
			// (selectNearestDirection), so the mouse sits in the hex a little towards the active stack: the attack comes
			// from the attacker's side.
			const auto pointAt = [&battle](uint16_t hex)
			{
				const Point target = battle->fieldController->hexPositionAbsolute(BattleHex(hex)).center();
				const CStack * active = battle->stacksController->getActiveStack();
				if(!active || !active->getPosition().isValid())
					return target;
				const Point from = battle->fieldController->hexPositionAbsolute(active->getPosition()).center() - target;
				const double length = std::sqrt(static_cast<double>(from.x * from.x + from.y * from.y));
				// 12 pixels: inside the hex, whose sides are 22 from its middle
				return length < 1 ? target : target + Point(static_cast<int>(from.x * 12 / length), static_cast<int>(from.y * 12 / length));
			};
			if(hover && *hover < VCMI_BATTLE_HEXES && battle->fieldController)
			{
				ENGINE->events().dispatchMouseMoved(Point(), pointAt(*hover));
				// again: with a gamepad the mouse move hovers as the right button does (mouseMoved)
				battle->actionsController->onHexHovered(BattleHex(*hover));
			}
			for(const uint16_t hex : clicks)
			{
				// the click before may have opened a window (a stack's info) in this same tick
				if(hex >= VCMI_BATTLE_HEXES || !battle->fieldController || !ENGINE->windows().isTopWindow(battle->windowObject))
					continue;
				// a click on the battlefield ends auto-combat first, as in 2D
				if(battle->curInt->isAutoFightOn)
				{
					battle->curInt->isAutoFightOn = false;
					continue;
				}
				ENGINE->events().dispatchMouseMoved(Point(), pointAt(hex));
				battle->actionsController->onHexLeftClicked(BattleHex(hex));
			}
		}
		next.shown = 1;
		next.myTurn = battle->makingTurn() ? 1 : 0;
		next.soundVolume = static_cast<uint8_t>(std::clamp<int64_t>(settings["general"]["sound"].Integer(), 0, 100));
		const CStack * active = battle->stacksController->getActiveStack();
		const battle::Unit * turn = state->battleActiveUnit();
		for(const CStack * stack : state->battleGetAllStacks(false))
		{
			if(next.stackCount == VCMI_BATTLE_STACKS)
				break;
			// a tower's shooter stands on no hex: the siege controller knows its place (getStackPositionAtHex)
			const bool turret = stack && stack->initialPosition < 0 && battle->siegeController;
			if(!stack || stack->isGhost() || (!turret && !stack->getPosition().isValid()))
				continue;
			VcmiBattleStack & out = next.stacks[next.stackCount++];
			if(turret)
			{
				const Point at = battle->siegeController->getTurretCreaturePosition(stack->initialPosition);
				out.x = static_cast<int16_t>(at.x);
				out.y = static_cast<int16_t>(at.y);
			}
			out.id = stack->unitId();
			out.count = static_cast<uint32_t>(std::max(stack->getCount(), 0));
			out.hex = turret ? 0 : static_cast<uint16_t>(stack->getPosition().toInt());
			out.side = stack->unitSide() == BattleSide::DEFENDER ? 1 : 0;
			out.owner = static_cast<uint8_t>(stack->unitOwner().getNum());
			out.flags = (stack->doubleWide() ? VCMI_STACK_WIDE : 0) | (stack->alive() ? VCMI_STACK_ALIVE : 0) | (stack == active ? VCMI_STACK_ACTIVE : 0)
					  | (turn && turn->unitId() == stack->unitId() ? VCMI_STACK_TURN : 0) | (turret ? VCMI_STACK_TURRET : 0);
			out.creature = 0xffff;
			if(const CCreature * type = stack->unitType())
			{
				out.creature = static_cast<uint16_t>(type->getId().getNum());
				const std::string name = type->animDefName.getOriginalName();
				std::memcpy(out.animation, name.data(), std::min(name.size(), sizeof(out.animation) - 1));
				const std::string missile = type->animation.projectileImageName.getOriginalName();
				std::memcpy(out.missile, missile.data(), std::min(missile.size(), sizeof(out.missile) - 1));
			}
		}
		// as BattleFieldController chooses its background
		ImagePath picture;
		if(battle->siegeController)
		{
			picture = battle->siegeController->getBattleBackgroundName();
			wallPieces(*battle->siegeController, *state, next);
		}
		else if(state->battleGetBattlefieldType() != BattleField::NONE)
			picture = state->battleGetBattlefieldType().getInfo()->graphics;
		const std::string pictureName = picture.getName();
		std::memcpy(next.picture, pictureName.data(), std::min(pictureName.size(), sizeof(next.picture) - 1));
		// as BattleHero chooses its animation
		const CGHeroInstance * commanders[2] = {battle->attackingHeroInstance, battle->defendingHeroInstance};
		for(int side = 0; side < 2; side++)
		{
			const CGHeroInstance * hero = commanders[side];
			if(!hero || !hero->getHeroType() || !hero->getHeroClass())
				continue;
			const AnimationPath & image = !hero->getHeroType()->battleImage.empty() ? hero->getHeroType()->battleImage
										: hero->gender == EHeroGender::FEMALE       ? hero->getHeroClass()->imageBattleFemale
																					: hero->getHeroClass()->imageBattleMale;
			const std::string heroName = image.getOriginalName();
			std::memcpy(next.heroes[side], heroName.data(), std::min(heroName.size(), sizeof(next.heroes[side]) - 1));
		}
		const AccessibilityInfo accessibility = state->getAccessibility();
		for(int hex = 0; hex < VCMI_BATTLE_HEXES; hex++)
		{
			const EAccessibility state = accessibility[hex];
			if(state == EAccessibility::OBSTACLE || state == EAccessibility::DESTRUCTIBLE_WALL || state == EAccessibility::GATE
			   || state == EAccessibility::UNAVAILABLE)
				next.blocked[hex / 8] |= static_cast<uint8_t>(1 << (hex % 8));
		}
		if(active && next.myTurn)
			for(const BattleHex & hex : state->battleGetAvailableHexes(active, true))
				if(hex.isValid() && hex.toInt() < VCMI_BATTLE_HEXES)
					next.reach[hex.toInt() / 8] |= static_cast<uint8_t>(1 << (hex.toInt() % 8));
	}
	if(next.shown)
	{
		std::lock_guard actionLock(actionMutex);
		next.actionSequence = lastAction.sequence;
		next.actionStack = lastAction.stack;
		next.actionTarget = lastAction.target;
		next.actionHex = lastAction.hex;
		next.actionKind = lastAction.kind;
		next.actionSide = lastAction.side;
		next.actionOnHex = lastAction.onHex ? 1 : 0;
		next.actionTargetCount = static_cast<uint8_t>(std::min<size_t>(lastAction.targets.size(), VCMI_ACTION_TARGETS));
		std::copy_n(lastAction.targets.begin(), next.actionTargetCount, next.actionTargets);
		// a shot by a creature that shoots a ray, or a spell's ray: its lines' colours (BattleProjectileController
		// draws them)
		const CStack * shooter = next.actionKind == VCMI_ACTION_SHOT && state ? state->battleGetStackByID(lastAction.stack, false) : nullptr;
		const auto & ray = shooter && shooter->unitType() ? shooter->unitType()->animation.projectileRay : lastAction.ray;
		{
			next.actionRayCount = static_cast<uint8_t>(std::min<size_t>(ray.size(), VCMI_RAY_LINES));
			for(int i = 0; i < next.actionRayCount; i++)
			{
				const uint8_t line[8] = {
					ray[i].start.r, ray[i].start.g, ray[i].start.b, ray[i].start.a, ray[i].end.r, ray[i].end.g, ray[i].end.b, ray[i].end.a
				};
				std::memcpy(next.actionRay[i], line, sizeof(line));
			}
		}
		std::memcpy(next.actionEffect, lastAction.effect.data(), std::min(lastAction.effect.size(), sizeof(next.actionEffect) - 1));
		std::memcpy(next.actionSound, lastAction.sound.data(), std::min(lastAction.sound.size(), sizeof(next.actionSound) - 1));
	}
	std::lock_guard lock(battleMutex);
	next.generation = publishedBattle.generation;
	if(std::memcmp(&next, &publishedBattle, sizeof(next)) != 0 || next.generation == 0)
	{
		next.generation = publishedBattle.generation + 1 == 0 ? 1 : publishedBattle.generation + 1;
		publishedBattle = next;
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
// the table shows the battle (setTableBattle): the 2D battle at its fastest, its sound effects muted (quest/DATA_BRIDGE.md,
// "Battles"); the player's speed is kept in a file until the table lets the battle go, so a crash cannot lose it
// shortcut: a speed the player sets in the 2D options during a table battle (or a replay's, ReplayAbortOverlay) is
// replaced by the kept one when the battle ends
void updateTableBattle()
{
	static bool applied = false;
	static bool checked = false;
	const auto kept = VCMIDirs::get().userConfigPath() / "quest-battle-speed.txt";
	const bool wanted = tableBattleWanted && adventureInt;
	if(checked && wanted == applied)
	{
		// the chat's sound, the window's focus and the sound option unmute the game: muted again
		if(applied && ENGINE->sound().getVolume() != 0)
			ENGINE->sound().setVolume(0);
		return;
	}
	try
	{
		const bool keeping = boost::filesystem::exists(kept);
		if(wanted && !keeping)
		{
			std::ofstream file(kept.string());
			file << settings["battle"]["speedFactor"].Float();
			file.close();
			if(!file) // not kept: the player's speed stays
			{
				boost::system::error_code ignored;
				boost::filesystem::remove(kept, ignored);
				throw std::runtime_error("cannot write " + kept.string());
			}
			Settings fastest = settings.write["battle"]["speedFactor"];
			fastest->Float() = 18; // the fastest the 2D options offer
		}
		if(!wanted && keeping) // also at the first tick after a crash during a table battle
		{
			double speed = 2;
			std::ifstream(kept.string()) >> speed;
			Settings own = settings.write["battle"]["speedFactor"];
			own->Float() = speed;
			boost::filesystem::remove(kept);
		}
	}
	catch(const std::exception & e)
	{
		logGlobal->warn("Quest bridge: battle speed: %s", e.what());
	}
	ENGINE->sound().setVolume(wanted ? 0 : static_cast<ui32>(settings["general"]["sound"].Integer()));
	applied = wanted;
	checked = true;
}

void tick()
{
	tickPending = false;
	ticks++;
	updateTableBattle();
	if(!adventureInt)
	{
		inGame = false;
		mapSize = 0;
		tabletopShown = false;
		battleEventsClient = nullptr;
		selected = VCMI_NONE;
		windowsAbove = 0;
		{
			std::lock_guard panelLock(panelMutex);
			publishedPanel = {};
		}
		{
			// no battle outside a game; the generation goes on, so the table sees the change
			std::lock_guard battleLock(battleMutex);
			if(publishedBattle.shown)
			{
				const uint32_t generation = publishedBattle.generation + 1 == 0 ? 1 : publishedBattle.generation + 1;
				publishedBattle = {};
				publishedBattle.generation = generation;
			}
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
	registerBattleEvents();
	publishBattle();
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

void copyBattle(VcmiBattle * out)
{
	std::unique_lock lock(battleMutex, std::try_to_lock);
	if(!out)
		return;
	if(!lock)
	{
		out->generation = 0;
		return;
	}
	*out = publishedBattle;
}

void hexInput(uint16_t hex, uint8_t kind)
{
	std::lock_guard lock(hexMutex);
	if(kind == VCMI_TILE_HOVER)
		pendingHexHover = hex;
	else if(kind == VCMI_TILE_CLICK && pendingHexClicks.size() < 16)
		pendingHexClicks.push_back(hex);
}

// file `name` of type `type` as the game's files hold it, looked for under each of `prefixes`
uint32_t gameFile(const char * name, EResType type, std::initializer_list<const char *> prefixes, const uint8_t ** out)
{
	thread_local std::vector<uint8_t> bytes;
	bytes.clear();
	if(name && *name && inGame.load())
	{
		try
		{
			for(const char * prefix : prefixes)
			{
				const ResourcePath path(std::string(prefix) + name, type);
				if(!CResourceHandler::get()->existsResource(path))
					continue;
				const auto data = CResourceHandler::get()->load(path)->readAll();
				bytes.assign(data.first.get(), data.first.get() + data.second);
				break;
			}
		}
		catch(const std::exception & e)
		{
			logGlobal->warn("Quest bridge: file %s: %s", name, e.what());
			bytes.clear();
		}
	}
	if(out)
		*out = bytes.data();
	return static_cast<uint32_t>(bytes.size());
}

uint32_t imageFile(const char * name, const uint8_t ** out)
{
	// as the game looks for a picture: by its name, among the bitmaps, among the sprites
	return gameFile(name, EResType::IMAGE, {"", "DATA/", "SPRITES/"}, out);
}

uint32_t soundFile(const char * name, const uint8_t ** out)
{
	return gameFile(name, EResType::SOUND, {"", "SOUNDS/"}, out);
}

uint32_t creatureSounds(uint16_t creature, char * out, uint32_t capacity)
{
	if(!inGame.load() || !LIBRARY || creature >= LIBRARY->creh->size())
		return 0;
	const CCreature * type = (*LIBRARY->creh)[CreatureID(creature)];
	if(!type)
		return 0;
	const auto & s = type->sounds;
	std::string joined;
	for(const AudioPath * sound : {&s.attack, &s.defend, &s.killed, &s.move, &s.shoot, &s.cast, &s.wince, &s.startMoving, &s.endMoving})
		joined += sound->getOriginalName() + "|";
	joined.pop_back();
	if(!out || capacity <= joined.size())
		return 0;
	std::memcpy(out, joined.c_str(), joined.size() + 1);
	return static_cast<uint32_t>(joined.size());
}

void setTableBattle(uint8_t shown)
{
	tableBattleWanted = shown != 0;
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
static_assert(sizeof(VcmiObject) == 20, "VcmiObject is part of the bridge ABI");
static_assert(sizeof(VcmiBattleStack) == 76, "VcmiBattleStack is part of the bridge ABI");
static_assert(sizeof(VcmiPathNode) == 8, "VcmiPathNode is part of the bridge ABI");
static_assert(sizeof(VcmiPanelHero) == 64, "VcmiPanelHero is part of the bridge ABI");
static_assert(sizeof(VcmiPanelTown) == 56, "VcmiPanelTown is part of the bridge ABI");

#ifdef VCMI_WINDOWS
#	include "PcHost.cpp"
#	define BRIDGE_EXPORT __declspec(dllexport)
#	define PC_HOST pcMain, pcFrame, pcMouse, pcKey, pcButton, pcAxis, pcText
#else
#	define BRIDGE_EXPORT __attribute__((visibility("default")))
#	define PC_HOST nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr
#endif

extern "C" BRIDGE_EXPORT const VcmiBridgeApi vcmi_bridge_api = {
	VCMI_BRIDGE_VERSION, start,       stats,    copyTiles,   copyFog,   copyObjects,    copyObjectChanges, copyAnimation,
	decodeFrames,        setTabletop, copyMove, confirmMove, tileInput, copyPath,       tileAnimation,     copyPanel,
	selectObject,        copyBattle,  hexInput, imageFile,   soundFile, creatureSounds, setTableBattle,    PC_HOST,
};

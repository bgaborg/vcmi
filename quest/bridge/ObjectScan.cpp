/*
 * ObjectScan.cpp, Meta Quest build: see ObjectScan.h. Compiled as part of Bridge.cpp (which includes it, so
 * clientapp/CMakeLists.txt adds one file) and on its own by the object benchmark.
 *
 * License: GNU General Public License v2.0 or later
 */
#include "../../Global.h"

#include "ObjectScan.h"

#include "../../lib/mapObjects/CGHeroInstance.h"
#include "../../lib/mapObjects/MiscObjects.h"
#include "../../lib/mapObjects/ObjectTemplate.h"
#include "../../lib/mapping/CMap.h"

void ObjectScan::snapshot(const CMap & map)
{
	names.clear();
	byName.clear();
	byTemplate.clear();
	table.assign(map.objects.size(), VcmiObject{});
	for(size_t id = 0; id < map.objects.size(); id++)
	{
		table[id].id = id;
		if(map.objects[id])
			table[id] = encode(map.objects[id].get());
	}
}

bool ObjectScan::update(const CMap & map, int32_t id)
{
	if(id < 0)
		return false;
	const CGObjectInstance * obj = static_cast<size_t>(id) < map.objects.size() ? map.objects[id].get() : nullptr;
	VcmiObject record = obj ? encode(obj) : VcmiObject{};
	record.id = id; // an empty record too: readers apply changes by id
	if(static_cast<size_t>(id) >= table.size())
		table.resize(id + 1);
	if(std::memcmp(&table[id], &record, sizeof(record)) == 0)
		return false;
	table[id] = record;
	return true;
}

VcmiObject ObjectScan::encode(const CGObjectInstance * obj)
{
	VcmiObject out{};
	out.id = obj->id.getNum();
	// as the 2D map: events are invisible, objects without a sprite are not drawn
	if(obj->ID == Obj::EVENT || !obj->appearance || obj->appearance->animationFile.empty())
		return out;
	const int3 anchor = obj->anchorPos();
	const bool visitable = obj->isVisitable();
	// visitablePos logs (and formats a message) for scenery, which has no visitable tile: 8 us an object
	const int3 visit = visitable ? obj->visitablePos() : anchor;
	const PlayerColor owner = obj->getOwner();
	out.x = anchor.x;
	out.y = anchor.y;
	out.z = anchor.z;
	out.owner = static_cast<uint8_t>(owner.getNum());
	out.visit = std::clamp(anchor.x - visit.x, 0, 15) << 4 | std::clamp(anchor.y - visit.y, 0, 15);
	out.animation = animationOf(obj);
	out.flags = VCMI_OBJECT_PRESENT | (visitable ? VCMI_OBJECT_VISITABLE : 0);
	// idle groups of heroes and boats by facing (MapRendererBaseContext::objectGroupIndex)
	static const std::array<uint8_t, 9> idleGroups = {0, 13, 0, 1, 2, 3, 4, 15, 14};
	if(obj->ID == Obj::HERO)
	{
		const auto * hero = static_cast<const CGHeroInstance *>(obj);
		out.flags |= VCMI_OBJECT_HERO;
		out.group = idleGroups[std::min<size_t>(hero->moveDir, 8)];
		// the 2D map draws no hero in a garrison or a boat (MapRendererBaseContext::objectTransparency)
		if(hero->isGarrisoned() || hero->inBoat())
			out.flags |= VCMI_OBJECT_HIDDEN;
	}
	else if(obj->ID == Obj::BOAT)
	{
		const auto * boat = dynamic_cast<const CGBoat *>(obj);
		out.flags |= VCMI_OBJECT_BOAT;
		const CGHeroInstance * captain = boat ? boat->getBoardedHero() : nullptr;
		const uint8_t direction = captain ? captain->moveDir : boat ? boat->direction : 0;
		out.group = idleGroups[std::min<size_t>(direction, 8)];
		// a boat with a hero flies the hero's flag (MapRendererObjects::getFlagAnimation), and stands in for the hidden hero
		if(captain)
			out.owner = static_cast<uint8_t>(captain->getOwner().getNum());
	}
	else if(owner != PlayerColor::UNFLAGGABLE)
		out.flags |= VCMI_OBJECT_FLAGGABLE;
	if(obj->ID == Obj::TOWN)
		out.flags |= VCMI_OBJECT_TOWN;
	return out;
}

// the animation the 2D map draws an object's body with (MapRendererObjects::getBodyAnimation)
uint16_t ObjectScan::animationOf(const CGObjectInstance * obj)
{
	const CGBoat * boat = obj->ID == Obj::BOAT ? dynamic_cast<const CGBoat *>(obj) : nullptr;
	const bool ownAnimation = boat && !boat->actualAnimation.empty();
	if(!ownAnimation)
		if(auto known = byTemplate.find(obj->appearance); known != byTemplate.end())
			return known->second;
	const std::string name = ownAnimation ? boat->actualAnimation.getOriginalName() : obj->appearance->animationFile.getOriginalName();
	auto [entry, added] = byName.try_emplace(name, static_cast<uint16_t>(names.size()));
	if(added)
		names.push_back(name);
	if(!ownAnimation)
		byTemplate[obj->appearance] = entry->second;
	return entry->second;
}

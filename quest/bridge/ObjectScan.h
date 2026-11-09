/*
 * ObjectScan.h, Meta Quest build: the map objects as the 2D map draws them, one VcmiObject record per object id,
 * and the names of their animations (quest/DATA_BRIDGE.md, milestone 3). Uses only lib/, so the bridge and the
 * object benchmark (quest/bench) run the same code.
 *
 * License: GNU General Public License v2.0 or later
 */
#pragma once

#include "VcmiBridgeApi.h"

class CMap;
class CGObjectInstance;
class ObjectTemplate;

class ObjectScan
{
public:
	/// every object of `map`; starts the animation names again
	void snapshot(const CMap & map);
	/// encodes object `id` of `map` again (flags 0 when it is gone); true when its record changed
	bool update(const CMap & map, int32_t id);

	/// by object id; a record with flags 0 is no object
	const std::vector<VcmiObject> & records() const
	{
		return table;
	}
	/// VcmiObject.animation indexes this; names are only appended until the next snapshot
	const std::vector<std::string> & animations() const
	{
		return names;
	}

private:
	VcmiObject encode(const CGObjectInstance * obj);
	uint16_t animationOf(const CGObjectInstance * obj);

	std::vector<VcmiObject> table;
	std::vector<std::string> names;
	std::unordered_map<std::string, uint16_t> byName;
	// held, not raw: a template replaced in play (a town built up) must not hand its address to another
	std::unordered_map<std::shared_ptr<const ObjectTemplate>, uint16_t> byTemplate;
};

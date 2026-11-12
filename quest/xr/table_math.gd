## Map tiles and the war table's view: pure maths, tested on the PC (quest/xr/tests/table_math_test.gd,
## quest/tools/test-local.sh). Map UV runs over the minimap image, the map levels side by side along x.
## The table shows 1 / zoom of the map's width and `aspect` / zoom of its height (room.gd view_aspect): the table keeps
## its shape whatever the map's, and tiles stay square.
extends RefCounted

const NO_TILE := Vector3i(-1, -1, -1)


## the tile (x, y, level) at map UV `uv`, or NO_TILE off the map
static func uv_to_tile(uv: Vector2, map: Vector3i) -> Vector3i:
	if map.x <= 0 or map.y <= 0 or map.z <= 0 or uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return NO_TILE
	var column := mini(int(uv.x * map.x * map.z), map.x * map.z - 1)
	return Vector3i(column % map.x, mini(int(uv.y * map.y), map.y - 1), column / map.x)


## the map UV of a tile's centre
static func tile_uv(tile: Vector3i, map: Vector3i) -> Vector2:
	return Vector2((tile.z * map.x + tile.x + 0.5) / float(map.x * map.z), (tile.y + 0.5) / float(map.y))


## the zoom at which a tile is `tile_metres` wide on a minimap `panel_width` wide; at least the level count, so the
## view never shows two levels
static func zoom_for(tile_metres: float, panel_width: float, map: Vector3i) -> float:
	return maxf(tile_metres * map.x * map.z / panel_width, float(map.z))


## the view centre (map UV) at `zoom` that keeps the view inside map level `level`
static func on_level(centre: Vector2, zoom: float, level: int, levels: int, aspect := 1.0, reach := 0.0) -> Vector2:
	var half := 0.5 / zoom
	var low := float(level) / levels + half
	var high := maxf(float(level + 1) / levels - half, low)
	return Vector2(clampf(centre.x, low, high), clamp_v(centre.y, zoom, aspect, reach))


## the view centre's v that keeps the view on the map; the middle when the view is taller than the map.
## `reach` (of the panel's depth, from its middle towards the player) lets the view go past the map's far edge, so
## that the map's first row can come that near: the far part of the table is then blank page
static func clamp_v(v: float, zoom: float, aspect: float, reach := 0.0) -> float:
	var half := 0.5 * aspect / zoom
	var low := -reach * aspect / zoom if reach > 0.0 else half
	return 0.5 if half >= 0.5 else clampf(v, low, 1.0 - half)


## the view centre that shows `target` (map UV) at the table's point `focus` (panel UV; nearer the player than the
## middle, where it is easy to reach): the old centre while `target` is in the `keep` part of `view` around `focus`,
## else the one that puts it there, so the view does not move with every hero step
static func follow(view: Rect2, target: Vector2, keep: float, focus := Vector2(0.5, 0.5)) -> Vector2:
	var shift := (focus - Vector2(0.5, 0.5)) * view.size
	var margin := view.size * (1.0 - keep) * 0.5
	if Rect2(view.position + shift + margin, view.size - margin * 2.0).has_point(target):
		return view.get_center()
	return target - shift


## the view centre after a grab moved from panel point `from` to `to` (panel UV, 0..1 across the table): the map moves
## with the hand, so the map point under the hand stays under it
static func drag(centre: Vector2, from: Vector2, to: Vector2, zoom: float, aspect := 1.0) -> Vector2:
	return centre - (to - from) * Vector2(1.0, aspect) / zoom


## the view centre at `new_zoom` that keeps the map point under panel point `pivot` (panel UV) where it is
static func zoom_about(centre: Vector2, zoom: float, new_zoom: float, pivot: Vector2, aspect := 1.0) -> Vector2:
	var offset := (pivot - Vector2(0.5, 0.5)) * Vector2(1.0, aspect)
	return centre + offset / zoom - offset / new_zoom

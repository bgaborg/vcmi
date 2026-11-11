## The table's side panel (quest/PHASE4.md 4d): what the 2D side panel shows, on a strip along the war table's near
## edge: the date and the resources, the heroes with movement and mana, the towns (VcmiData.panel), and the end turn
## button. The strip lies in its own plane: x to the right, y up the strip, metres from its centre, facing +z.
## item_at and ray_item find the entry under a point; main.gd acts on it (select_object, the end turn key).
extends Node3D

const SIZE := Vector2(0.72, 0.17) ## metres; narrower than the map: the war table's corner figures stand there
const ROW := 0.02 ## metres per line
const ROWS := 8 ## lines per column: the date and 7 resources; heroes and towns past it are not shown
## the columns' left and right edges, in metres from the strip's centre
const INFO := Vector2(-0.355, -0.17)
const HEROES := Vector2(-0.16, 0.10)
const TOWNS := Vector2(0.11, 0.27)
const END_TURN := Rect2(0.28, -0.07, 0.075, 0.14)
## shown when the game's resource icons are not loaded (local tests); in GameResID order
const RESOURCE_NAMES := ["Wood", "Mercury", "Ore", "Sulfur", "Crystal", "Gems", "Gold"]
const COLOURS := {
	"background": Color(0.16, 0.11, 0.07), "item": Color(0.24, 0.17, 0.1), "hover": Color(0.85, 0.6, 0.15),
	"selected": Color(0.55, 0.38, 0.12),
}

## the entries a ray can pick, in the order of their quads: {rect (in the strip's plane), kind ("hero", "town",
## "end_turn"), id (object id; -1 for end turn)}
var items: Array[Dictionary] = []
var hover := -1 ## items index under the ray, or -1
var selected := -1 ## object id of the selected hero or town (VcmiData.selected_tile's object), or -1
var resource_icons: Array[Texture2D] = [] ## SMALRES frames, from main.gd once the game is loaded

var _data := {}
var _content: Node3D ## rebuilt by set_data
var _quads: Array[MeshInstance3D] = [] ## items' backgrounds, for the hover and selection colours


func _init() -> void:
	var background := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = SIZE
	quad.material = _flat(COLOURS["background"])
	background.mesh = quad
	background.position.z = -0.001
	add_child(background)


## New panel data (VcmiData.panel); the same layout again when only the selection changed
func set_data(data: Dictionary) -> void:
	_data = data
	_rebuild()


func set_selected(id: int) -> void:
	if id != selected:
		selected = id
		_paint()


func set_hover(index: int) -> void:
	if index != hover:
		hover = index
		_paint()


## The entry at `point` of the strip's plane (metres from its centre), -1 for none
func item_at(point: Vector2) -> int:
	for i in items.size():
		if (items[i]["rect"] as Rect2).has_point(point):
			return i
	return -1


## The entry a ray from `from` along `direction` (world) points at: [items index, world hit point], or [] when the ray
## misses the strip or points away from its face
func ray_item(from: Vector3, direction: Vector3) -> Array:
	if not is_visible_in_tree():
		return []
	var to_local := global_transform.affine_inverse()
	var start: Vector3 = to_local * from
	var along: Vector3 = to_local.basis * direction
	if along.z >= -0.0001 or start.z <= 0.0:
		return []
	var hit := start + along * (-start.z / along.z)
	var point := Vector2(hit.x, hit.y)
	if absf(point.x) > SIZE.x / 2.0 or absf(point.y) > SIZE.y / 2.0:
		return []
	return [item_at(point), global_transform * hit]


## The centre of line `row` of a column, from the strip's top
static func row_y(row: int) -> float:
	return SIZE.y / 2.0 - ROW * (row + 0.5) - 0.005


## The text of a hero's line: name, movement points left of a full turn's, mana; "zz" while asleep
static func hero_text(hero: Dictionary) -> String:
	var text := "%s  %d/%d  %d/%d" % [hero.get("name", ""), hero.get("movement", 0), hero.get("max_movement", 0),
			hero.get("mana", 0), hero.get("max_mana", 0)]
	return text + "  zz" if hero.get("sleeping", false) else text


func _rebuild() -> void:
	if _content != null:
		_content.queue_free()
		remove_child(_content)
	_content = Node3D.new()
	add_child(_content)
	items.clear()
	_quads.clear()
	hover = -1
	_label(str(_data.get("date", "")), Vector2(INFO.x, row_y(0)), 0.0)
	var resources: PackedInt32Array = _data.get("resources", PackedInt32Array())
	for i in mini(resources.size(), RESOURCE_NAMES.size()):
		var at := Vector2(INFO.x, row_y(i + 1))
		if i < resource_icons.size() and resource_icons[i] != null:
			_icon(resource_icons[i], at + Vector2(0.008, 0.0))
			_label(str(resources[i]), at + Vector2(0.02, 0.0), 0.0)
		else:
			_label("%s %d" % [RESOURCE_NAMES[i], resources[i]], at, 0.0)
	var heroes: Array = _data.get("heroes", [])
	for i in mini(heroes.size(), ROWS):
		_item("hero", int(heroes[i]["id"]), hero_text(heroes[i]), HEROES, i)
	var towns: Array = _data.get("towns", [])
	for i in mini(towns.size(), ROWS):
		_item("town", int(towns[i]["id"]), str(towns[i]["name"]), TOWNS, i)
	_add_item({"rect": END_TURN, "kind": "end_turn", "id": -1}, "End\nturn")
	_paint()


func _item(kind: String, id: int, text: String, column: Vector2, row: int) -> void:
	var rect := Rect2(column.x, row_y(row) - ROW / 2.0, column.y - column.x, ROW * 0.9)
	_add_item({"rect": rect, "kind": kind, "id": id}, text)


func _add_item(item: Dictionary, text: String) -> void:
	var rect: Rect2 = item["rect"]
	var quad := QuadMesh.new()
	quad.size = rect.size
	quad.material = _flat(COLOURS["item"])
	var background := MeshInstance3D.new()
	background.mesh = quad
	background.position = Vector3(rect.get_center().x, rect.get_center().y, 0.0)
	_content.add_child(background)
	_quads.append(background)
	items.append(item)
	var centred: bool = item["kind"] == "end_turn"
	_label(text, Vector2(rect.get_center().x if centred else rect.position.x + 0.004, rect.get_center().y),
			0.5 if centred else 0.0)


## Text at `at`, its left edge there (`align` 0) or its centre (0.5)
func _label(text: String, at: Vector2, align: float) -> void:
	var label := Label3D.new()
	label.text = text
	label.pixel_size = 0.00013
	label.font_size = 64
	label.outline_size = 0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if align > 0.0 else HORIZONTAL_ALIGNMENT_LEFT
	label.position = Vector3(at.x, at.y, 0.001)
	label.modulate = Color(0.95, 0.88, 0.7)
	_content.add_child(label)


func _icon(texture: Texture2D, at: Vector2) -> void:
	var sprite := Sprite3D.new()
	sprite.texture = texture
	sprite.pixel_size = ROW * 0.8 / maxf(texture.get_height(), 1.0)
	sprite.position = Vector3(at.x, at.y, 0.001)
	sprite.shaded = false
	_content.add_child(sprite)


func _paint() -> void:
	for i in _quads.size():
		var item: Dictionary = items[i]
		var colour: Color = COLOURS["item"]
		if i == hover:
			colour = COLOURS["hover"]
		elif item["kind"] != "end_turn" and int(item["id"]) == selected:
			colour = COLOURS["selected"]
		(_quads[i].mesh.material as StandardMaterial3D).albedo_color = colour


static func _flat(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	return material

## The war table's side panel (quest/PHASE4.md 4d), laid out as the phase 0 concept
## (quest/concept/screenshots/table.png), as real things in the war room: the resources and the date on a wooden bar
## along the map's near edge, the heroes (movement and mana bars) and the towns on a board in a brass rim standing left
## of the map, and the end turn hourglass right of it, which flips when the turn ends.
## Data from VcmiData.panel. The node sits at the map's centre (room.add_table_panel): x right, y up, z towards the
## player. The board lies in its own plane: x right, y up, metres from its centre, facing +z. item_at and ray_item find
## the entry under a point; main.gd acts on it (select_object, the end turn key).
extends Node3D

const BAR_SIZE := Vector2(0.72, 0.06)
const BAR_POSE := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-50.0)), Vector3(0.0, 0.025, 0.33))
const BOARD_SIZE := Vector2(0.27, 0.50)
## left of the map, between the corner figures, turned towards the chair and leaning back a little
const BOARD_POSE := Transform3D(Basis(Vector3.UP, 0.65) * Basis(Vector3.RIGHT, -0.2), Vector3(-0.58, 0.235, -0.17))
const HOURGLASS_AT := Vector3(0.6, -0.015, 0.22) ## its foot, on the table (15 mm under the map)
const DECOR := 8 ## room.gd DECOR: the render layer the room's reflections and lights reach, not the controller light
const HOURGLASS_PICK := 0.06 ## metres from its middle that a ray picks it
## heroes, and towns, the board shows; shortcut: no paging past 6 (2D scrolls); add it when a map needs it
const ROWS := 6
const HERO_ROW := 0.042
const TOWN_ROW := 0.032
const PAD := 0.014 ## board margin
## shown when the game's resource icons are not loaded (local tests); in GameResID order
const RESOURCE_NAMES := ["Wood", "Mercury", "Ore", "Sulfur", "Crystal", "Gems", "Gold"]
const RESOURCE_COLOURS := [Color("8a5a2b"), Color("c8c8d8"), Color("6a6a6a"), Color("e0c030"), Color("e03a3a"),
		Color("3a8ae0"), Color("f0c040")]
const COLOURS := {
	"frame": Color("c9a24a"), "title": Color("f3d48a"), "text": Color("f3e3b0"),
	"item": Color(0.3, 0.2, 0.11), "hover": Color(0.75, 0.52, 0.18), "selected": Color(0.52, 0.35, 0.13),
	"movement": Color("2a8f2a"), "mana": Color("2a5fd0"), "bar_back": Color(0.08, 0.05, 0.02),
}
## the hero squares' colours when the portraits are not shown: by portrait index
const HERO_COLOURS := [Color("4a6fb5"), Color("b5704a"), Color("7a4ab5"), Color("4aa57a"), Color("b54a5f"),
		Color("8f8a3a")]

## the entries a ray can pick: {kind ("hero", "town", "end_turn"), id (object id; -1 for end turn), rect (in the
## board's plane; none for the hourglass)}
var items: Array[Dictionary] = []
var hover := -1 ## items index under the ray, or -1
var selected := -1 ## object id of the selected hero or town (VcmiData.selected_object), or -1
var resource_icons: Array[Texture2D] = [] ## SMALRES frames by resource id, from main.gd once the game is loaded
var town_icons: Array[Texture2D] = [] ## ITPA frames by the panel's town icon index, from main.gd

var _data := {}
var _bar: Node3D
var _board: Node3D
var _bar_content: Node3D ## rebuilt by set_data
var _board_content: Node3D
var _quads: Array[MeshInstance3D] = [] ## board items' backgrounds, by items index, for the hover and selection
var _layout := "" ## what the last _rebuild laid out (_layout_of): the same again only changes the numbers in place
var _meters: Array[Array] = [] ## per hero: [movement fill, mana fill], each [quad, left x, full width]
var _sleep: Array[Label3D] = [] ## per hero: its "zz"
var _resource_labels: Array[Label3D] = []
var _date: Label3D
var _flip: Tween
var _hourglass: Node3D
var _glass_glow: StandardMaterial3D
var _font := SystemFont.new()
var _wood := _wood_material()
var _brass := _metal(Color(0.8, 0.6, 0.3))


func _init() -> void:
	_font.font_names = PackedStringArray(["Georgia", "Noto Serif", "serif"])
	_font.multichannel_signed_distance_field = true # sharp at any distance and size, no rasterised font sizes
	_bar = _framed(BAR_SIZE, BAR_POSE)
	_board = _framed(BOARD_SIZE, BOARD_POSE)
	_hourglass = _make_hourglass()
	_hourglass.position = HOURGLASS_AT
	add_child(_hourglass)


## New panel data (VcmiData.panel): laid out again when the heroes, towns or the numbers' widths changed, else the
## numbers, bars and the date change in place (a hero's every step changes its movement)
func set_data(data: Dictionary) -> void:
	_data = data
	var layout := _layout_of(data)
	if layout != _layout:
		_layout = layout
		_rebuild()
		return
	var resources: PackedInt32Array = data.get("resources", PackedInt32Array())
	for i in _resource_labels.size():
		_resource_labels[i].text = _number(resources[i])
	_date.text = str(data.get("date", ""))
	var heroes: Array = data.get("heroes", [])
	for i in _meters.size():
		_set_meter(_meters[i][0], heroes[i].get("movement", 0), heroes[i].get("max_movement", 0))
		_set_meter(_meters[i][1], heroes[i].get("mana", 0), heroes[i].get("max_mana", 0))
		_sleep[i].visible = heroes[i].get("sleeping", false)


## What decides the panel's layout: the heroes and towns shown, and the widths of the resource numbers
static func _layout_of(data: Dictionary) -> String:
	var parts := []
	for hero in data.get("heroes", []).slice(0, ROWS):
		parts.append([hero["id"], hero.get("name", ""), hero.get("portrait", 0)])
	for town in data.get("towns", []).slice(0, ROWS):
		parts.append([town["id"], town.get("name", ""), town.get("icon", -1)])
	for amount in data.get("resources", PackedInt32Array()):
		parts.append(_number(amount).length())
	return str(parts)


func set_selected(id: int) -> void:
	if id != selected:
		selected = id
		_paint()


func set_hover(index: int) -> void:
	if index != hover:
		hover = index
		_paint()


## The end turn hourglass turns over (main.gd, when the player ends the turn)
func flip_hourglass() -> void:
	var glass: Node3D = _hourglass.get_child(0)
	if _flip != null and _flip.is_valid():
		_flip.kill() # a second end turn during the flip: from the nearest upright
		glass.rotation.x = roundf(glass.rotation.x / PI) * PI
	_flip = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_flip.tween_property(glass, "rotation:x", glass.rotation.x + PI, 0.6)


## The board entry at `point` of the board's plane (metres from its centre), -1 for none
func item_at(point: Vector2) -> int:
	for i in items.size():
		if items[i].has("rect") and (items[i]["rect"] as Rect2).has_point(point):
			return i
	return -1


## The entry a ray from `from` along `direction` (world) points at: [items index (-1 on the board between entries),
## world hit point], or [] when it misses the board (or hits its back) and the hourglass
func ray_item(from: Vector3, direction: Vector3) -> Array:
	if not is_visible_in_tree():
		return []
	var to_board := _board.global_transform.affine_inverse()
	var start: Vector3 = to_board * from
	var along: Vector3 = to_board.basis * direction
	if along.z < -0.0001 and start.z > 0.0:
		var hit := start + along * (-start.z / along.z)
		var point := Vector2(hit.x, hit.y)
		if absf(point.x) <= BOARD_SIZE.x / 2.0 and absf(point.y) <= BOARD_SIZE.y / 2.0:
			return [item_at(point), _board.global_transform * hit]
	# the hourglass: the ray passing near its middle
	var middle: Vector3 = _hourglass.global_transform * Vector3(0.0, 0.08, 0.0)
	var unit := direction.normalized()
	var t := maxf((middle - from).dot(unit), 0.0)
	var closest := from + unit * t
	var radius := HOURGLASS_PICK * _hourglass.global_basis.get_scale().x
	if t > 0.0 and closest.distance_to(middle) <= radius:
		for i in items.size():
			if items[i]["kind"] == "end_turn":
				return [i, closest]
	return []


## The text of a hero's line under its name: movement points left of a full turn's, mana; "zz" while asleep
static func hero_text(hero: Dictionary) -> String:
	var text := "%d/%d  %d/%d" % [hero.get("movement", 0), hero.get("max_movement", 0), hero.get("mana", 0),
			hero.get("max_mana", 0)]
	return text + "  zz" if hero.get("sleeping", false) else text


## The top of row `row` of a list starting at `top`, rows of `height`
static func row_top(top: float, row: int, height: float) -> float:
	return top - height * row


## the top of the heroes' list and of the towns' on the board
static func heroes_top() -> float:
	return BOARD_SIZE.y / 2.0 - PAD - 0.04


static func towns_top() -> float:
	return heroes_top() - HERO_ROW * ROWS - 0.045


func _rebuild() -> void:
	for content in [_bar_content, _board_content]:
		if content != null:
			content.get_parent().remove_child(content)
			content.queue_free()
	_bar_content = Node3D.new()
	_bar.add_child(_bar_content)
	_board_content = Node3D.new()
	_board.add_child(_board_content)
	items.clear()
	_quads.clear()
	_meters.clear()
	_sleep.clear()
	_resource_labels.clear()
	hover = -1
	# the bar: the resources from the left, the date at the right
	var resources: PackedInt32Array = _data.get("resources", PackedInt32Array())
	var x := -BAR_SIZE.x / 2.0 + 0.02
	for i in mini(resources.size(), RESOURCE_NAMES.size()):
		if i < resource_icons.size() and resource_icons[i] != null:
			_icon(_bar_content, resource_icons[i], Vector2(x + 0.009, 0.0), 0.026)
		else:
			_quad(_bar_content, Vector2(x + 0.009, 0.0), Vector2(0.014, 0.014), RESOURCE_COLOURS[i])
		_resource_labels.append(_label(_bar_content, _number(resources[i]), Vector2(x + 0.022, 0.0), 0.0, 30,
				COLOURS["text"]))
		x += 0.03 + 0.0075 * _number(resources[i]).length() + 0.012
	_date = _label(_bar_content, str(_data.get("date", "")), Vector2(BAR_SIZE.x / 2.0 - 0.02, 0.0), 1.0, 30,
			COLOURS["title"])
	# the board: heroes, then towns
	var left := -BOARD_SIZE.x / 2.0 + PAD
	_label(_board_content, "Heroes", Vector2(left, BOARD_SIZE.y / 2.0 - PAD - 0.018), 0.0, 38, COLOURS["title"])
	var heroes: Array = _data.get("heroes", [])
	for i in mini(heroes.size(), ROWS):
		_hero_row(heroes[i], row_top(heroes_top(), i, HERO_ROW))
	_label(_board_content, "Towns", Vector2(left, towns_top() + 0.024), 0.0, 38, COLOURS["title"])
	var towns: Array = _data.get("towns", [])
	for i in mini(towns.size(), ROWS):
		_town_row(towns[i], row_top(towns_top(), i, TOWN_ROW))
	items.append({"kind": "end_turn", "id": -1})
	_paint()


func _hero_row(hero: Dictionary, top: float) -> void:
	var rect := Rect2(-BOARD_SIZE.x / 2.0 + PAD, top - HERO_ROW + 0.003, BOARD_SIZE.x - 2.0 * PAD, HERO_ROW - 0.004)
	_item({"kind": "hero", "id": int(hero["id"]), "rect": rect})
	var name := str(hero.get("name", ""))
	var square := Vector2(rect.position.x + 0.003 + 0.017, rect.get_center().y)
	var colour: Color = HERO_COLOURS[int(hero.get("portrait", 0)) % HERO_COLOURS.size()]
	_quad(_board_content, square, Vector2(0.038, 0.038), COLOURS["frame"], 0.001, 0.15)
	_quad(_board_content, square, Vector2(0.032, 0.032), colour, 0.0015, 0.35)
	_label(_board_content, name.left(1), square, 0.5, 48, Color.WHITE)
	var text_x := rect.position.x + 0.045
	_label(_board_content, name, Vector2(text_x, rect.end.y - 0.01), 0.0, 26, COLOURS["text"])
	var bar_width := rect.end.x - text_x - 0.004
	var movement := _meter(Vector2(text_x, rect.get_center().y - 0.003), bar_width, COLOURS["movement"])
	_set_meter(movement, hero.get("movement", 0), hero.get("max_movement", 0))
	var mana := _meter(Vector2(text_x, rect.get_center().y - 0.011), bar_width, COLOURS["mana"])
	_set_meter(mana, hero.get("mana", 0), hero.get("max_mana", 0))
	_meters.append([movement, mana])
	var sleep := _label(_board_content, "zz", Vector2(rect.end.x - 0.004, rect.end.y - 0.009), 1.0, 26, COLOURS["title"])
	sleep.visible = hero.get("sleeping", false)
	_sleep.append(sleep)


func _town_row(town: Dictionary, top: float) -> void:
	var rect := Rect2(-BOARD_SIZE.x / 2.0 + PAD, top - TOWN_ROW + 0.003, BOARD_SIZE.x - 2.0 * PAD, TOWN_ROW - 0.004)
	_item({"kind": "town", "id": int(town["id"]), "rect": rect})
	var icon := int(town.get("icon", -1))
	var at := Vector2(rect.position.x + 0.003 + 0.02, rect.get_center().y)
	if icon >= 0 and icon < town_icons.size() and town_icons[icon] != null:
		_icon(_board_content, town_icons[icon], at, 0.028)
	else:
		_quad(_board_content, at, Vector2(0.04, 0.028), Color(0.35, 0.27, 0.16))
	_label(_board_content, str(town.get("name", "")), Vector2(rect.position.x + 0.05, rect.get_center().y), 0.0, 26,
			COLOURS["text"])


func _item(item: Dictionary) -> void:
	var rect: Rect2 = item["rect"]
	_quads.append(_quad(_board_content, rect.get_center(), rect.size, COLOURS["item"], 0.0005))
	items.append(item)


## A movement or mana bar from `at`, `width` long: its groove and its fill, [fill quad, left x, width] for _set_meter
func _meter(at: Vector2, width: float, colour: Color) -> Array:
	_quad(_board_content, at + Vector2(width / 2.0, 0.0), Vector2(width, 0.006), COLOURS["bar_back"], 0.001)
	return [_quad(_board_content, at, Vector2(0.0, 0.006), colour, 0.0015, 0.5), at.x, width]


## The fill of a bar (_meter) `value` of `maximum`
static func _set_meter(meter: Array, value: int, maximum: int) -> void:
	var fill: MeshInstance3D = meter[0]
	var part: float = meter[2] * clampf(float(value) / maxf(maximum, 1), 0.0, 1.0)
	(fill.mesh as QuadMesh).size.x = part
	fill.position.x = meter[1] + part / 2.0
	fill.visible = part > 0.0


func _paint() -> void:
	for i in _quads.size():
		var item: Dictionary = items[i]
		var colour: Color = COLOURS["item"]
		if i == hover:
			colour = COLOURS["hover"]
		elif int(item["id"]) == selected:
			colour = COLOURS["selected"]
		var material := _quads[i].mesh.material as StandardMaterial3D
		material.albedo_color = colour
		material.emission = colour * 0.6 if i == hover else Color.BLACK # the hovered plate glows
	var on_hourglass: bool = hover >= 0 and hover < items.size() and items[hover]["kind"] == "end_turn"
	_glass_glow.emission_energy_multiplier = 1.5 if on_hourglass else 0.0


## A dark wooden board in a brass rim at `pose`, its face towards +z, and a strut behind that holds it on the table
func _framed(size: Vector2, pose: Transform3D) -> Node3D:
	var node := Node3D.new()
	node.transform = pose
	add_child(node)
	_box(node, Vector3(size.x, size.y, 0.014), Vector3(0.0, 0.0, -0.008), _wood)
	for side in [-1.0, 1.0]:
		_box(node, Vector3(size.x + 0.012, 0.006, 0.018), Vector3(0.0, side * (size.y + 0.006) / 2.0, -0.006), _brass)
		_box(node, Vector3(0.006, size.y, 0.018), Vector3(side * (size.x + 0.006) / 2.0, 0.0, -0.006), _brass)
	# the strut: from behind the board's top third down to the table
	var top := Vector3(0.0, size.y * 0.2, -0.016)
	# on the table (the map's height, 15 mm above it), behind the board
	var behind := -pose.basis.z
	behind.y = 0.0
	var foot := Vector3(pose.origin.x, -0.015, pose.origin.z) + behind.normalized() * 0.12
	var back: Vector3 = pose.affine_inverse() * foot
	var along := back - top
	var strut := _box(node, Vector3(0.024, along.length(), 0.012), (top + back) / 2.0, _wood)
	strut.rotation.x = atan2(along.z, along.y) # the box's length along `along`
	return node


## The end turn hourglass, as the concept's: two wooden discs on three rods around the glass with sand; the glass part
## (child 0) turns over in flip_hourglass
func _make_hourglass() -> Node3D:
	var wood := StandardMaterial3D.new() # turned walnut
	wood.albedo_color = Color(0.3, 0.16, 0.07)
	wood.roughness = 0.45
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.8, 0.88, 0.95, 0.4)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.roughness = 0.05
	glass.metallic_specular = 1.0
	glass.rim_enabled = true
	glass.rim = 0.6
	glass.emission_enabled = true
	glass.emission = Color(1.0, 0.8, 0.4)
	glass.emission_energy_multiplier = 0.0
	_glass_glow = glass
	var sand := StandardMaterial3D.new()
	sand.albedo_color = Color(0.85, 0.69, 0.38)
	var root := Node3D.new()
	var turning := Node3D.new() # around the middle, so it turns in place
	turning.position.y = 0.08
	root.add_child(turning)
	for y in [-0.075, 0.075]:
		_part(turning, _cylinder(0.045, 0.045, 0.01), Vector3(0.0, y, 0.0), wood)
	for i in 3:
		var a := TAU * i / 3.0
		_part(turning, _cylinder(0.004, 0.004, 0.15), Vector3(cos(a) * 0.038, 0.0, sin(a) * 0.038), wood)
	for side in [-1.0, 1.0]: # the two bulbs, narrow at the middle
		_part(turning, _cylinder(0.032 if side > 0.0 else 0.006, 0.006 if side > 0.0 else 0.032, 0.068),
				Vector3(0.0, side * 0.035, 0.0), glass)
	_part(turning, _cylinder(0.0, 0.02, 0.03), Vector3(0.0, 0.03, 0.0), sand).rotation.x = PI # the top's sand, running
	_part(turning, _cylinder(0.0, 0.024, 0.025), Vector3(0.0, -0.057, 0.0), sand)
	return root


func _box(parent: Node3D, size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	return _part(parent, box, at, material)


## the war room's dark wood (assets/room/textures, room.gd SETS "beam"), stained darker
static func _wood_material() -> BaseMaterial3D:
	var material := ORMMaterial3D.new()
	material.albedo_texture = load("res://assets/room/textures/medieval_wood_diff_2k.jpg")
	material.normal_enabled = true
	material.normal_texture = load("res://assets/room/textures/medieval_wood_nor_gl_2k.jpg")
	material.orm_texture = load("res://assets/room/textures/medieval_wood_arm_2k.jpg")
	material.albedo_color = Color(0.32, 0.2, 0.13)
	material.normal_scale = 0.25
	material.uv1_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.9
	return material


static func _metal(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.metallic = 1.0
	material.roughness = 0.35
	return material


static func _cylinder(top: float, bottom: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = 16
	mesh.rings = 1
	return mesh


static func _part(parent: Node3D, mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = at
	part.layers = DECOR
	part.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC # the lightmap's probes light it, as the room's figures
	parent.add_child(part)
	return part


## Text at `at` of `parent`'s plane: its left edge there (`align` 0), its centre (0.5) or its right edge (1)
func _label(parent: Node3D, text: String, at: Vector2, align: float, size: int, colour: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font = _font
	label.pixel_size = 0.0004
	label.font_size = size
	label.outline_size = 0
	label.horizontal_alignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER,
			HORIZONTAL_ALIGNMENT_RIGHT][int(round(align * 2.0))]
	label.position = Vector3(at.x, at.y, 0.002)
	label.modulate = colour
	label.layers = DECOR
	parent.add_child(label)
	return label


func _icon(parent: Node3D, texture: Texture2D, at: Vector2, height: float) -> void:
	var sprite := Sprite3D.new()
	sprite.texture = texture
	sprite.pixel_size = height / maxf(texture.get_height(), 1.0)
	sprite.position = Vector3(at.x, at.y, 0.001)
	sprite.shaded = false
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	sprite.layers = DECOR
	parent.add_child(sprite)


## A lit flat part of the board (enamel, inlay, a plate), so the candles light it as the wood
func _quad(parent: Node3D, centre: Vector2, size: Vector2, colour: Color, z := 0.0, glow := 0.0) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.45
	material.emission_enabled = true
	material.emission = colour * glow
	quad.material = material
	var mesh := MeshInstance3D.new()
	mesh.mesh = quad
	mesh.position = Vector3(centre.x, centre.y, z)
	mesh.layers = DECOR
	mesh.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	parent.add_child(mesh)
	return mesh


## 14500 as "14 500", as the concept's bar
static func _number(value: int) -> String:
	var text := str(absi(value))
	var out := ""
	while text.length() > 3:
		out = " " + text.right(3) + out
		text = text.left(text.length() - 3)
	return ("-" if value < 0 else "") + text + out

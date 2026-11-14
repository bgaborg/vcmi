extends Node3D
## The panel over the back of a controller, as a watch face: a page of the game's keys and a page of the Quest
## settings (the table's height, its tilt, the cards' angle, the wrist it is on, the room). main.gd shows it when the
## wrist turns to the eyes; the other hand's ray presses its buttons (ray_button), and main.gd acts on `action`.

const CELL := Vector2(0.08, 0.025) ## metres per button: two columns
const ROWS := 6 ## the tabs, then five rows
const STEP_WIDTH := 0.04 ## of a setting's - and + buttons, at the row's ends
## above the back of the controller, tilted towards the eyes like a watch face
const POSE := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-45.0)), Vector3(0.0, 0.05, 0.07))
const PAGES := ["Keys", "Settings"]
## label and Android KeyEvent.KEYCODE_*, the game's own keys from config/keyBindingsConfig.json "keyboard"; the labels
## name the key because other screens bind it to something else (in battle D is defend).
## -1: switches tabletop mode in Godot (also the right stick click)
const KEYS := [
	["End turn (E)", 33], ["Spells (C)", 31],
	["Kingdom (K)", 39], ["Quests (Q)", 45],
	["Sleep (Z)", 54], ["Dig (D)", 32],
	["Quick save (F8)", 138], ["Quick load (F9)", 139],
	["Table / screen", -1], ["Next hero (H)", 36],
]
## label and the setting's name: its text comes in `values`, its buttons' action is [name, -1 or 1]
const SETTINGS := [
	["Table", "height"], ["Board tilt", "tilt"], ["Cards", "cards"], ["Wrist", "wrist"], ["Room", "room"],
]
const IDLE := Color(0.2, 0.15, 0.1)
const LIT := Color(0.85, 0.6, 0.15)
const CHOSEN := Color(0.45, 0.3, 0.12) ## the shown page's tab

var page := 0
var buttons: Array[Dictionary] = [] ## of the shown page: at, size (Vector2, metres), label, action, mesh, colour


func _init() -> void:
	transform = POSE
	show_page(0, {})


## Builds page `new_page` (PAGES); `values`: the settings' texts by name
func show_page(new_page: int, values: Dictionary) -> void:
	page = clampi(new_page, 0, PAGES.size() - 1)
	for child in get_children():
		remove_child(child)
		child.queue_free()
	buttons.clear()
	for i in PAGES.size():
		_button(Vector2((i - 0.5) * CELL.x, _row(0)), CELL, PAGES[i], ["page", i], CHOSEN if i == page else IDLE)
	if page == 0:
		for i in KEYS.size():
			@warning_ignore("integer_division")
			_button(Vector2((i % 2 - 0.5) * CELL.x, _row(1 + i / 2)), CELL, KEYS[i][0], KEYS[i][1], IDLE)
		return
	for i in SETTINGS.size():
		var setting: String = SETTINGS[i][1]
		var y := _row(1 + i)
		var edge := CELL.x - STEP_WIDTH / 2.0
		_button(Vector2(-edge, y), Vector2(STEP_WIDTH, CELL.y), "-", [setting, -1], IDLE)
		_quad(Vector2(0.0, y), Vector2(2.0 * (CELL.x - STEP_WIDTH), CELL.y), "%s: %s" % [SETTINGS[i][0],
				values.get(setting, "")], IDLE)
		_button(Vector2(edge, y), Vector2(STEP_WIDTH, CELL.y), "+", [setting, 1], IDLE)


func set_hover(index: int) -> void:
	for i in buttons.size():
		var material: StandardMaterial3D = buttons[i]["mesh"].mesh.material
		material.albedo_color = LIT if i == index else buttons[i]["colour"]


## The button a world ray hits from the panel's front: [index in `buttons`, the hit in the world], or an empty array
func ray_button(from: Vector3, direction: Vector3) -> Array:
	var to_panel := global_transform.affine_inverse()
	var start := to_panel * from
	var along := to_panel.basis * direction
	if along.z > -0.0001 or start.z <= 0.0:
		return []
	var hit := start + along * (-start.z / along.z)
	for i in buttons.size():
		var offset: Vector2 = Vector2(hit.x, hit.y) - buttons[i]["at"]
		if absf(offset.x) <= buttons[i]["size"].x / 2.0 and absf(offset.y) <= buttons[i]["size"].y / 2.0:
			return [i, global_transform * hit]
	return []


func _row(row: int) -> float:
	return ((ROWS - 1) / 2.0 - row) * CELL.y


func _button(at: Vector2, size: Vector2, text: String, action: Variant, colour: Color) -> void:
	buttons.append({"at": at, "size": size, "label": text, "action": action, "colour": colour,
			"mesh": _quad(at, size, text, colour)})


func _quad(at: Vector2, size: Vector2, text: String, colour: Color) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = size - Vector2(0.002, 0.002)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	quad.material = material
	var mesh := MeshInstance3D.new()
	mesh.mesh = quad
	mesh.position = Vector3(at.x, at.y, 0.0)
	add_child(mesh)
	var label := Label3D.new()
	label.text = text
	label.pixel_size = 0.0002
	label.font_size = 40
	label.position.z = 0.001
	mesh.add_child(label)
	return mesh

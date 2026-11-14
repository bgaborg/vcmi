extends Node3D
## The stacks of a battle as cards on the battlefield (battle_field.gd, quest/PHASE5.md 5c and 5d). A stack whose
## creature's animation is loaded (set_creature) shows its frames, placed as the 2D battle places them
## (BattleStacksController::getStackPositionAtHex); until then, and without one, a marker in its side's colour.
## What a stack does is read from how it changed since the last set_stacks: it slides to a new hex, flinches when it
## lost creatures, and dies. The node's space is the field's: x right, y up, z towards the player.

## animation groups, as the game's ECreatureAnimType
enum Group { MOVING = 0, HOLDING = 2, HIT = 3, DEATH = 5, ATTACK = 12, SHOOT = 15 }

const BattleMath := preload("res://battle_math.gd")
const AREA := Vector2(1.5, 0.94) ## metres: room.gd MINIMAP_AREA
const PIXEL := AREA.y / BattleMath.FIELD.y ## metres of a field pixel
const LIFT := 0.0015 ## metres over the page
const MARKER := Vector2(0.055, 0.085) ## metres, a marker card; a two-hex stack's is twice as wide
const SIDES := [Color(0.25, 0.4, 0.8), Color(0.75, 0.2, 0.15)] ## attacker, defender, until the players' colours come
## The pixel of a creature's 450 x 400 frame that stands on its hex's middle, for a stack that faces right: the frame's
## corner is 203 - 29 left of and 225 above the hex's cell, whose middle is 22, 26 in. A stack that faces left is
## mirrored about it. The card stands on the frame's line FEET, a little before the hex's middle: lower pixels (the
## shadow on the ground) are under the page.
const ANCHOR := Vector2(196.0, 251.0)
const FEET := 263.0
const WIDE := 44.0 ## a two-hex stack's frame is this far back, towards its own side
const FPS := 10.0 ## frames a second, about the 2D battle's at its default speed
const SLIDE := 0.45 ## seconds a stack takes to a new hex

var creatures := {} ## animation name: {group: [{texture, rect (of the frame's pixels in the 450 x 400 frame)}]}
var _stacks := {} ## stack id: {node, sprite, marker, count, stack, group, loop, time, from, slide}
var _lean := deg_to_rad(82.0)
var _unit := QuadMesh.new()


func _init() -> void:
	_unit.size = Vector2.ONE


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	for card: Dictionary in _stacks.values():
		card["time"] += delta
		if card["slide"] < 1.0:
			card["slide"] = minf(card["slide"] + delta / SLIDE, 1.0)
			card["node"].position = (card["from"] as Vector3).lerp(_place(card["stack"]), card["slide"])
			if card["slide"] >= 1.0 and card["group"] == Group.MOVING:
				_play(card, Group.HOLDING, true)
		_show_frame(card)


## The frames of creature animation `name`, as VcmiData.decode_animation gives them ({frames: [{group, left, top,
## image}]}); an empty one keeps the marker for good
func set_creature(name_: String, decoded: Dictionary) -> void:
	var groups := {}
	for frame: Dictionary in decoded.get("frames", []):
		var image: Image = frame.get("image")
		if image == null or image.is_empty():
			continue
		if not groups.has(int(frame["group"])):
			groups[int(frame["group"])] = []
		groups[int(frame["group"])].append({"texture": ImageTexture.create_from_image(image),
				"rect": Rect2(frame["left"], frame["top"], image.get_width(), image.get_height())})
	creatures[name_] = groups


## The animations of the shown stacks that set_creature has not got yet
func missing_creatures() -> PackedStringArray:
	var missing := PackedStringArray()
	for card: Dictionary in _stacks.values():
		var creature: String = card["stack"].get("animation", "")
		if creature != "" and not creatures.has(creature) and not creature in missing:
			missing.append(creature)
	return missing


## The battle's stacks. Each: id, hex (of its front half), side (0 attacker), count, wide (a two-hex creature), alive
## (default true), animation (its creature's, or none for a marker)
func set_stacks(stacks: Array) -> void:
	var seen := {}
	for i in stacks.size():
		var stack: Dictionary = stacks[i]
		var id: int = stack.get("id", i)
		seen[id] = true
		if not _stacks.has(id):
			_stacks[id] = _new_card(stack)
			continue
		var card: Dictionary = _stacks[id]
		var before: Dictionary = card["stack"]
		card["stack"] = stack
		var alive: bool = stack.get("alive", true)
		if before.get("alive", true) and not alive:
			_play(card, Group.DEATH, false)
		elif alive and not before.get("alive", true): # raised again
			_play(card, Group.HOLDING, true)
		elif alive and stack.get("hex", 0) != before.get("hex", 0):
			card["from"] = card["node"].position
			card["slide"] = 0.0
			_play(card, Group.MOVING, true)
		elif alive and stack.get("count", 1) < before.get("count", 1) and card["group"] == Group.HOLDING:
			_play(card, Group.HIT, false)
		_dress(card)
	for id: int in _stacks.keys():
		if not seen.has(id):
			_stacks[id]["node"].queue_free()
			_stacks.erase(id)


## Stack `id` strikes (or with `shoot` shoots): its attack plays once (quest/PHASE5.md 5d)
func attack(id: int, shoot: bool) -> void:
	if _stacks.has(id) and _stacks[id]["stack"].get("alive", true):
		_play(_stacks[id], Group.SHOOT if shoot else Group.ATTACK, false)


## The cards' angle from the table, as the map's (room.gd set_card_lean)
func set_card_lean(degrees: float) -> void:
	_lean = deg_to_rad(degrees)
	for card: Dictionary in _stacks.values():
		_dress(card)


func card_count() -> int:
	return _stacks.size()


## For the tests: the card of stack `id` ({node, sprite, marker, stack, group, ...}), or an empty Dictionary
func card(id: int) -> Dictionary:
	return _stacks.get(id, {})


func _new_card(stack: Dictionary) -> Dictionary:
	var node := Node3D.new()
	add_child(node)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var marker := MeshInstance3D.new()
	marker.mesh = _unit
	marker.material_override = material
	node.add_child(marker)
	var art := StandardMaterial3D.new()
	art.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	art.cull_mode = BaseMaterial3D.CULL_DISABLED
	art.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var sprite := MeshInstance3D.new()
	sprite.mesh = _unit
	sprite.material_override = art
	sprite.visible = false
	node.add_child(sprite)
	var count := Label3D.new()
	count.pixel_size = 0.0005
	count.font_size = 40
	count.outline_size = 10
	count.position = Vector3(0.0, 0.014, 0.002)
	node.add_child(count)
	var alive: bool = stack.get("alive", true)
	var card := {"node": node, "sprite": sprite, "marker": marker, "count": count, "stack": stack, "time": 0.0,
			"group": Group.HOLDING if alive else Group.DEATH, "loop": alive, "from": Vector3.ZERO, "slide": 1.0}
	if not alive:
		card["time"] = 1000.0 # already dead: its last frame
	node.position = _place(stack)
	_dress(card)
	return card


## Where a stack's card stands: its hex's middle, at the feet's line
func _place(stack: Dictionary) -> Vector3:
	var at := BattleMath.field_to_page(BattleMath.hex_centre(stack.get("hex", 0)), AREA)
	return Vector3(at.x, LIFT, at.y + (FEET - ANCHOR.y) * PIXEL)


func _play(card: Dictionary, group: int, loop: bool) -> void:
	card["group"] = group
	card["loop"] = loop
	card["time"] = 0.0


## What does not change from frame to frame: the marker's shape and colour, the count, the card's angle
func _dress(card: Dictionary) -> void:
	var stack: Dictionary = card["stack"]
	var alive: bool = stack.get("alive", true)
	var side: int = clampi(stack.get("side", 0), 0, 1)
	var wide: bool = stack.get("wide", false)
	var marker: MeshInstance3D = card["marker"]
	var colour: Color = SIDES[side]
	(marker.material_override as StandardMaterial3D).albedo_color = colour if alive else colour.lerp(Color(0.35,
			0.33, 0.3), 0.75)
	marker.scale = Vector3(MARKER.x * (2.0 if wide else 1.0), MARKER.y, 1.0)
	# a two-hex stack's other half is behind it, towards its own side's edge; a dead marker lies over its hex
	marker.position = Vector3((-1.0 if side == 0 else 1.0) * (WIDE / 2.0 * PIXEL if wide else 0.0), MARKER.y / 2.0, 0.0)
	var has_art: bool = not creatures.get(stack.get("animation", ""), {}).is_empty()
	(card["node"] as Node3D).rotation.x = _lean - PI / 2.0 if alive or has_art else -PI / 2.0
	(card["count"] as Label3D).text = str(stack.get("count", 1))
	(card["count"] as Label3D).visible = alive
	if card["slide"] >= 1.0:
		(card["node"] as Node3D).position = _place(stack) + (Vector3.ZERO if alive or has_art else Vector3(0.0, 0.001,
				MARKER.y / 2.0 - (FEET - ANCHOR.y) * PIXEL))


## The frame of the card's group at its time on the sprite; the marker instead while the creature has no frames
func _show_frame(card: Dictionary) -> void:
	var stack: Dictionary = card["stack"]
	var groups: Dictionary = creatures.get(stack.get("animation", ""), {})
	var frames: Array = groups.get(card["group"], [])
	if frames.is_empty() and card["group"] != Group.DEATH: # a creature without this group stands
		frames = groups.get(Group.HOLDING, [])
	var sprite: MeshInstance3D = card["sprite"]
	if sprite.visible == frames.is_empty(): # the art came, or went
		sprite.visible = not frames.is_empty()
		(card["marker"] as MeshInstance3D).visible = frames.is_empty()
		_dress(card)
	if frames.is_empty():
		return
	var index := int(card["time"] * FPS)
	if index >= frames.size():
		if card["loop"]:
			index %= frames.size()
		elif card["group"] == Group.DEATH:
			index = frames.size() - 1
		else: # an action is over: the stack stands again
			_play(card, Group.HOLDING, true)
			_show_frame(card)
			return
	var frame: Dictionary = frames[index]
	var rect: Rect2 = frame["rect"]
	var facing := 1.0 if clampi(stack.get("side", 0), 0, 1) == 0 else -1.0
	var anchor := ANCHOR.x + (WIDE if stack.get("wide", false) else 0.0)
	(sprite.material_override as StandardMaterial3D).albedo_texture = frame["texture"]
	sprite.scale = Vector3(facing * rect.size.x * PIXEL, rect.size.y * PIXEL, 1.0)
	sprite.position = Vector3(facing * (rect.get_center().x - anchor) * PIXEL, (FEET - rect.get_center().y) * PIXEL, 0.0)

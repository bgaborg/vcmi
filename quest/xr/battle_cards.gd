extends Node3D
## The stacks of a battle as cards on the battlefield (battle_field.gd, quest/PHASE5.md 5c and 5d). A stack whose
## creature's animation is loaded (set_creature) shows its frames, placed as the 2D battle places them
## (BattleStacksController::getStackPositionAtHex); until then, and without one, a marker in its side's colour.
## What a stack does is read from how it changed since the last set_stacks: it slides to a new hex, flinches when it
## lost creatures, and dies. The game's battle events say who strikes or shoots whom (set_action); a shot flies as
## the shooter's own missile (a dart until that is read), a spell plays its own animation on its target (play_effect)
## and the casting hero raises its hand. Without events (another human's battle in hot-seat) the stack whose turn it
## was strikes when an enemy is hurt.
## The node's space is the field's: x right, y up, z towards the player.

## stack `stack` (its dictionary from set_stacks) starts `group` (moving, hit, death, attack, shoot) at `at`: its
## sound (battle_sounds.gd)
signal acted(stack: Dictionary, group: int, at: Vector3)

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
## A side's hero stands at its end of the field, as BattleHero places it: a 64 x 136 box in the field's corner, the
## 150 x 175 frame's middle on the box's. The card stands on the box's lower edge
const HERO_AT := Vector2(32.0, 136.0) ## field pixel of the attacker's hero's feet; the defender's is mirrored
const HERO_ANCHOR := Vector2(75.0, 155.0) ## the frame's pixel there
const HERO_ID := -10 ## the heroes' cards: HERO_ID - side
const FPS := 10.0 ## frames a second, about the 2D battle's at its default speed
const SLIDE := 0.45 ## seconds a stack takes to a new hex
const FLIGHT := 0.35 ## seconds a shot flies
const SHOT_DELAY := 0.4 ## seconds from the shooter's first frame to the shot's leaving
const RAY := 0.5 ## seconds a ray fades in after it is drawn
## a grid of field pixels a spell that covers the whole field plays its animation on (Armageddon: SCREEN_FILL)
const FILL_STEP := Vector2(200.0, 160.0)
## field pixels a spell's frame may stand at most (0.5 m): the tallest creature's frame stands about 260 above its feet;
## an effect as tall as the 2D battlefield (556) would stand 0.94 m over the table, so it is scaled down
const EFFECT_TALL := 300.0

## animation name: {group: [{image, texture (made from the image when the frame first shows), rect (of the frame's
## pixels in the 450 x 400 frame)}]}
var creatures := {}
var _stacks := {} ## stack id: {node, sprite, marker, count, stack, group, loop, time, from, slide}
var _lean := deg_to_rad(82.0)
var _turn := -1 ## the id of the stack whose turn it was at the last set_stacks
var _action := 0 ## the sequence of the last battle event shown (set_action); 0: none came, attacks are guessed
var _shots: Array[Dictionary] = [] ## flying: {node, from, to, time, missile (its animation, or none for a dart)}
var _effects: Array[Dictionary] = [] ## playing once: {node, name (the animation), at, time, waited}
var _rays: Array[Dictionary] = [] ## shown: {node, time}
var _dart := BoxMesh.new()
var _unit := QuadMesh.new()


func _init() -> void:
	_unit.size = Vector2.ONE
	_dart.size = Vector3(0.004, 0.004, 0.035)
	var ink := StandardMaterial3D.new()
	ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ink.albedo_color = Color(0.16, 0.11, 0.07)
	_dart.material = ink


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	for shot in _shots.duplicate():
		shot["time"] += delta
		var along: float = (shot["time"] - SHOT_DELAY) / FLIGHT
		var node: MeshInstance3D = shot["node"]
		node.visible = along >= 0.0
		if along >= 1.0:
			node.queue_free()
			_shots.erase(shot)
		elif along >= 0.0:
			# a flat arc from the shooter's chest to the target's
			var at: Vector3 = (shot["from"] as Vector3).lerp(shot["to"], along) + Vector3.UP * 0.06 * sin(along * PI)
			var ahead: Vector3 = (shot["to"] as Vector3) - shot["from"] + Vector3.UP * 0.06 * PI * cos(along * PI)
			node.position = at
			if ahead.length_squared() < 0.000001 or ahead.normalized().is_equal_approx(Vector3.UP):
				continue
			# the shooter's own missile once its frames are read: its level frame (the middle one of those drawn from
			# pointing up to pointing down), as a card along the flight. Until then a plain dart
			var frames: Array = creatures.get(shot["missile"], {}).get(0, [])
			if frames.is_empty():
				node.basis = Basis.looking_at(ahead.normalized(), Vector3.UP)
				continue
			@warning_ignore("integer_division")
			var frame: Dictionary = frames[frames.size() / 2]
			var across := ahead.normalized()
			var side := across.cross(Vector3.UP).normalized()
			node.mesh = _unit
			node.material_override = _art(frame)
			node.basis = Basis(across * frame["rect"].size.x * PIXEL, side.cross(across) * frame["rect"].size.y * PIXEL,
					side)
	for ray in _rays.duplicate():
		ray["time"] += delta
		var shown: float = 1.0 - clampf((ray["time"] - SHOT_DELAY) / RAY, 0.0, 1.0)
		(ray["node"] as MeshInstance3D).visible = ray["time"] >= SHOT_DELAY
		((ray["node"] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.a = shown
		if shown <= 0.0:
			ray["node"].queue_free()
			_rays.erase(ray)
	for effect in _effects.duplicate():
		var frames: Array = creatures.get(effect["name"], {}).get(0, [])
		var node: MeshInstance3D = effect["node"]
		if frames.is_empty(): # not read yet: it waits two seconds for its frames, then is given up
			effect["waited"] += delta
		else:
			effect["time"] += delta
		var index := int(effect["time"] * FPS)
		if index >= frames.size() and (not frames.is_empty() or effect["waited"] > 2.0):
			node.queue_free()
			_effects.erase(effect)
		elif not frames.is_empty():
			# as the 2D battle: the frame's middle over the hex's, its lower edge on the ground
			var frame: Dictionary = frames[index]
			var rect: Rect2 = frame["rect"]
			var full: Vector2 = frame["full"]
			node.visible = true
			node.material_override = _art(frame)
			# the screen's height on the 2D battlefield is a wall on the table: no taller than EFFECT_TALL
			var pixel := PIXEL * minf(1.0, EFFECT_TALL / maxf(full.y, 1.0))
			node.scale = Vector3(rect.size.x * pixel, rect.size.y * pixel, 1.0)
			node.position = (effect["at"] as Vector3) + node.basis.orthonormalized() * Vector3((rect.get_center().x
					- full.x / 2.0) * pixel, (full.y - rect.get_center().y) * pixel, 0.002) # along the leaning card
	for card: Dictionary in _stacks.values():
		card["time"] += delta
		if card["slide"] < 1.0:
			card["slide"] = minf(card["slide"] + delta / SLIDE, 1.0)
			card["node"].position = (card["from"] as Vector3).lerp(_place(card["stack"]), card["slide"])
			if card["slide"] >= 1.0 and card["group"] == Group.MOVING:
				_play(card, Group.HOLDING, true)
		_show_frame(card)


## The frames of creature animation `name`, as VcmiData.decode_animation_hd gives them ({frames: [{group, left, top,
## image, scale (the image's pixels per pixel of the frame, 1 when absent)}]}); an empty one keeps the marker for good
func set_creature(name_: String, decoded: Dictionary) -> void:
	var groups := {}
	for frame: Dictionary in decoded.get("frames", []):
		var image: Image = frame.get("image")
		if image == null or image.is_empty():
			continue
		if not groups.has(int(frame["group"])):
			groups[int(frame["group"])] = []
		var zoom: float = frame.get("scale", 1)
		var full: Variant = frame.get("full_size", Vector2i(450, 400)) # a Vector2i, or [w, h] from a JSON file
		groups[int(frame["group"])].append({"image": image, "texture": null, "rect": Rect2(frame["left"] / zoom,
				frame["top"] / zoom, image.get_width() / zoom, image.get_height() / zoom),
				"full": Vector2(full[0], full[1]) / zoom})
	creatures[name_] = groups


## The animations of the shown stacks that set_creature has not got yet
func missing_creatures() -> PackedStringArray:
	var missing := PackedStringArray()
	var wanted: Array = _effects.map(func(effect): return effect["name"])
	for card: Dictionary in _stacks.values():
		wanted.append(card["stack"].get("animation", ""))
		wanted.append(card["stack"].get("missile", ""))
	for creature: String in wanted:
		if creature != "" and not creatures.has(creature) and not creature in missing:
			missing.append(creature)
	return missing


## The stacks' list with a card for each side's hero: `heroes` are their battle animations (VcmiData.battle), empty
## for a side without one. A hero is a stack of its own kind: it stands in its corner in its animation's first group
static func with_heroes(stacks: Array, heroes: PackedStringArray) -> Array:
	var all := stacks.duplicate()
	for side in mini(heroes.size(), 2):
		if heroes[side] != "":
			all.append({"id": HERO_ID - side, "side": side, "hero": true, "animation": heroes[side]})
	return all


## The battle's stacks. Each: id, hex (of its front half), side (0 attacker), count, wide (a two-hex creature), alive
## (default true), turn (it is its turn), animation (its creature's, or none for a marker)
func set_stacks(stacks: Array) -> void:
	var seen := {}
	var hurt: Array[Dictionary] = [] # the stacks that lost creatures since the last call
	var turn := -1
	for i in stacks.size():
		var stack: Dictionary = stacks[i]
		var id: int = stack.get("id", i)
		seen[id] = true
		if stack.get("turn", false):
			turn = id
		if not _stacks.has(id):
			_stacks[id] = _new_card(stack)
			continue
		var card: Dictionary = _stacks[id]
		var before: Dictionary = card["stack"]
		card["stack"] = stack
		var alive: bool = stack.get("alive", true)
		if before.get("alive", true) and stack.get("count", 1) < before.get("count", 1):
			hurt.append(stack)
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
	# no battle event came yet: who struck is the stack whose turn it was, when an enemy of it is hurt (a retaliation
	# hurts its own side and shows only as the hit)
	if _action == 0 and _stacks.has(_turn):
		var striker: Dictionary = _stacks[_turn]["stack"]
		for victim in hurt:
			if victim.get("side", 0) != striker.get("side", 0):
				var apart := BattleMath.hex_centre(victim.get("hex", 0)).distance_to(BattleMath.hex_centre(striker.get(
						"hex", 0)))
				attack(_turn, apart > 2.5 * BattleMath.PITCH.x) # a neighbour, also of a two-hex stack, is nearer
				break
	_turn = turn


## The game's last battle event (VcmiData.battle: action, action_kind 1 attack, 2 shot, 3 spell, action_stack,
## action_target): the stack strikes, shoots (a dart flies to the target) or casts
func set_action(data: Dictionary) -> void:
	var sequence: int = data.get("action", 0)
	if sequence == _action:
		return
	_action = sequence
	var id: int = data.get("action_stack", -1)
	var kind: int = data.get("action_kind", 0)
	if kind == 3 and sequence != 0:
		# the casting hero raises its hand; the spell's own animation plays on its target stack, else on its hex
		var caster: int = HERO_ID - int(data.get("action_side", -1))
		if data.get("action_side", -1) >= 0 and _stacks.has(caster):
			_play(_stacks[caster], Group.ATTACK, false)
		# as the 2D battle: an `affect` animation on every stack it affects (a mass spell: all of them); a `hit` one
		# (action_on_hex) once on its hex, or without a hex over the whole field (Armageddon)
		var effect: String = data.get("action_effect", "")
		var struck: Array = Array(data.get("action_targets", PackedInt64Array())).filter(func(t): return _stacks.has(t))
		if struck.is_empty() and _stacks.has(data.get("action_target", -1)):
			struck = [data["action_target"]]
		# a spell's ray (chain lightning): from target to target in the order it jumps
		# shortcut: all hops at once, the 2D battle shows one after another (rayHopDelay)
		var bolt: Array = data.get("action_ray", [])
		for hop in range(1, struck.size() if not bolt.is_empty() else 0):
			play_ray(_stacks[struck[hop - 1]]["node"].position, _stacks[struck[hop]]["node"].position, bolt)
		if data.get("action_on_hex", false):
			struck = []
		if effect != "":
			for target: int in struck:
				play_effect(effect, _place(_stacks[target]["stack"]))
			if struck.is_empty() and data.get("action_hex", -1) >= 0:
				play_effect(effect, _place({"hex": data["action_hex"]}))
			elif struck.is_empty():
				for x in range(int(FILL_STEP.x / 2.0), int(BattleMath.FIELD.x), int(FILL_STEP.x)):
					for y in range(int(FILL_STEP.y), int(BattleMath.FIELD.y) + 1, int(FILL_STEP.y)):
						var at := BattleMath.field_to_page(Vector2(x, y), AREA)
						play_effect(effect, Vector3(at.x, LIFT, at.y))
	if sequence == 0 or not _stacks.has(id):
		return
	attack(id, kind == 2)
	var target: int = data.get("action_target", -1)
	var lines: Array = data.get("action_ray", [])
	if kind == 2 and _stacks.has(target) and not lines.is_empty():
		play_ray(_stacks[id]["node"].position, _stacks[target]["node"].position, lines)
	elif kind == 2 and _stacks.has(target):
		var dart := MeshInstance3D.new()
		dart.mesh = _dart
		dart.visible = false
		add_child(dart)
		var chest := Vector3(0.0, 0.05, 0.0)
		_shots.append({"node": dart, "time": 0.0, "from": _stacks[id]["node"].position + chest,
				"to": _stacks[target]["node"].position + chest, "missile": _stacks[id]["stack"].get("missile", "")})


## A ray from `from` to `to` (stack places), as BattleProjectileController draws one: each of `lines` ([colour at the
## shooter, colour at the target]) a field pixel wide, side by side, at chest height. One mesh, drawn once, fading
func play_ray(from: Vector3, to: Vector3, lines: Array) -> void:
	var chest := Vector3(0.0, 0.05, 0.0)
	var start := from + chest
	var along := to + chest - start
	if along.length_squared() < 0.000001:
		return
	# across the flight, in the plane that faces up: seen from above and from the chair
	var across := along.cross(Vector3.UP).normalized() * PIXEL
	if across.length_squared() < 0.0000001:
		across = Vector3.RIGHT * PIXEL
	var vertices := PackedVector3Array()
	var colours := PackedColorArray()
	for i in lines.size():
		var side := across * (i - lines.size() / 2.0)
		var near_colour: Color = lines[i][0]
		var far_colour: Color = lines[i][1]
		for corner in [[side, near_colour], [side + across, near_colour], [side + along, far_colour],
				[side + across, near_colour], [side + across + along, far_colour], [side + along, far_colour]]:
			vertices.append(start + corner[0])
			colours.append(corner[1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colours
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true # the game's colours
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.visible = false
	add_child(node)
	_rays.append({"node": node, "time": 0.0})


## Animation `effect` (a spell's own, read like a creature's) plays once, standing at `at` (as _place gives it)
func play_effect(effect: String, at: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.mesh = _unit
	node.visible = false
	node.rotation.x = _lean - PI / 2.0
	add_child(node)
	_effects.append({"node": node, "name": effect, "at": at, "time": 0.0, "waited": 0.0})


## The battle is over: no card and no creature's frames are kept for the next one
func clear() -> void:
	set_stacks([])
	_turn = -1
	_action = 0
	for flying in _shots + _effects + _rays:
		flying["node"].queue_free()
	_shots.clear()
	_effects.clear()
	_rays.clear()
	creatures.clear()


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
	if stack.has("turret"):
		# a tower's shooter, where the 2D battle draws its frame (it faces left: mirrored): on the tower's top in the
		# battlefield's picture
		var top := BattleMath.field_to_page(Vector2(stack["turret"]) + Vector2(450.0 - ANCHOR.x, FEET), AREA)
		return Vector3(top.x, LIFT, top.y)
	if stack.get("hero", false):
		var corner := Vector2(HERO_AT.x if stack.get("side", 0) == 0 else BattleMath.FIELD.x - HERO_AT.x, HERO_AT.y)
		var feet := BattleMath.field_to_page(corner, AREA)
		return Vector3(feet.x, LIFT, feet.y)
	var at := BattleMath.field_to_page(BattleMath.hex_centre(stack.get("hex", 0)), AREA)
	return Vector3(at.x, LIFT, at.y + (FEET - ANCHOR.y) * PIXEL)


func _play(card: Dictionary, group: int, loop: bool) -> void:
	if group != Group.HOLDING:
		acted.emit(card["stack"], group, card["node"].position)
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
	(card["count"] as Label3D).visible = alive and not stack.get("hero", false) and not stack.has("turret")
	# beside the feet, on the side the stack faces, as the 2D battle's count box
	(card["count"] as Label3D).position.x = (1.0 if side == 0 else -1.0) * 0.6 * BattleMath.PITCH.x * PIXEL
	if card["slide"] >= 1.0:
		(card["node"] as Node3D).position = _place(stack) + (Vector3.ZERO if alive or has_art else Vector3(0.0, 0.001,
				MARKER.y / 2.0 - (FEET - ANCHOR.y) * PIXEL))


## A frame's texture, made (and uploaded) when the frame first shows: a creature's hundred frames never in one tick
func _texture(frame: Dictionary) -> Texture2D:
	if frame["texture"] == null:
		frame["texture"] = ImageTexture.create_from_image(frame["image"])
		frame.erase("image")
	return frame["texture"]


## A material of its own with a frame's texture, for a missile or an effect (few, short-lived)
func _art(frame: Dictionary) -> StandardMaterial3D:
	if not frame.has("material"):
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_texture = _texture(frame)
		frame["material"] = material
	return frame["material"]


## The frame of the card's group at its time on the sprite; the marker instead while the creature has no frames
func _show_frame(card: Dictionary) -> void:
	var stack: Dictionary = card["stack"]
	var groups: Dictionary = creatures.get(stack.get("animation", ""), {})
	var hero: bool = stack.get("hero", false)
	# a hero has its own groups: 0 standing, 4 casting (EHeroAnimType), which its card plays as its attack
	var group: int = (4 if card["group"] == Group.ATTACK else 0) if hero else card["group"]
	var frames: Array = groups.get(group, [])
	if frames.is_empty() and card["group"] != Group.DEATH: # a creature without this group stands
		frames = groups.get(0 if hero else Group.HOLDING, [])
	var sprite: MeshInstance3D = card["sprite"]
	if sprite.visible == frames.is_empty(): # the art came, or went
		sprite.visible = not frames.is_empty()
		(card["marker"] as MeshInstance3D).visible = frames.is_empty()
		_dress(card)
	if frames.is_empty():
		if not card["loop"] and card["group"] != Group.DEATH and card["time"] > 0.5: # a marker's action is over
			_play(card, Group.HOLDING, true)
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
	if card.get("drawn") == frame: # the same frame as the last tick: 62 of 72 ticks a second
		return
	card["drawn"] = frame
	var rect: Rect2 = frame["rect"]
	var facing := 1.0 if clampi(stack.get("side", 0), 0, 1) == 0 else -1.0
	var anchor := HERO_ANCHOR.x if hero else ANCHOR.x + (WIDE if stack.get("wide", false) else 0.0)
	var feet := HERO_ANCHOR.y if hero else FEET
	_texture(frame)
	(sprite.material_override as StandardMaterial3D).albedo_texture = frame["texture"]
	sprite.scale = Vector3(facing * rect.size.x * PIXEL, rect.size.y * PIXEL, 1.0)
	sprite.position = Vector3(facing * (rect.get_center().x - anchor) * PIXEL, (feet - rect.get_center().y) * PIXEL, 0.0)

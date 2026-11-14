## Local check of the battlefield's hex maths (battle_math.gd) and its picking on the table (battle_field.gd): every
## hex's centre and points towards its corners find that hex, the 2D battle's pixel positions hold, and a ray from above
## lands on the hex under it. Run with quest/tools/test-local.sh.
extends SceneTree

const BattleMath := preload("res://battle_math.gd")

var failures := 0


func _initialize() -> void:
	# BattleFieldController::hexPositionLocal: x = 14 + (even row ? 22 : 0) + 44 * column, y = 86 + 42 * row; the cell
	# picture is 45 x 52, so its middle is 22, 26 further
	_expect("hex 0", BattleMath.hex_centre(0), Vector2(58.0, 112.0))
	_expect("first hex of row 1", BattleMath.hex_centre(17), Vector2(36.0, 154.0))
	_expect("last hex", BattleMath.hex_centre(186), Vector2(14.0 + 22.0 + 44.0 * 16 + 22.0, 86.0 + 420.0 + 26.0))
	var wrong := 0
	for hex in BattleMath.COLUMNS * BattleMath.ROWS:
		var centre := BattleMath.hex_centre(hex)
		# the middle, the flat sides' middles nearly, and towards the top and bottom corners
		for offset in [Vector2.ZERO, Vector2(20.0, 0.0), Vector2(-20.0, 0.0), Vector2(0.0, 24.0), Vector2(0.0, -24.0),
				Vector2(15.0, 14.0), Vector2(-15.0, -14.0)]:
			if BattleMath.hex_at(centre + offset) != hex:
				wrong += 1
	_expect("points inside every hex find it", wrong, 0)
	_expect("above the field", BattleMath.hex_at(Vector2(400.0, 40.0)), BattleMath.NO_HEX)
	_expect("left of an odd row", BattleMath.hex_at(Vector2(2.0, 154.0)), BattleMath.NO_HEX)
	_expect("below the field", BattleMath.hex_at(Vector2(400.0, 570.0)), BattleMath.NO_HEX)
	var area := Vector2(1.5, 0.94)
	_expect("the field's middle is the page's", BattleMath.field_to_page(BattleMath.FIELD / 2.0, area), Vector2.ZERO)
	_expect("there and back", BattleMath.page_to_field(BattleMath.field_to_page(Vector2(123.0, 45.0), area), area),
			Vector2(123.0, 45.0))

	var field: Node3D = preload("res://battle_field.gd").new()
	root.add_child(field)
	field.transform = Transform3D(Basis(Vector3.UP, 0.7) * Basis(Vector3.RIGHT, 0.2), Vector3(1.0, 0.84, -0.3))
	await process_frame
	var up: Vector3 = field.global_basis.y
	var hex := 5 * 17 + 9
	var point: Vector3 = field.global_transform * field.hex_position(hex)
	_expect("ray from above", field.ray_hex(point + up * 0.3, -up), hex)
	_expect("slanted ray", field.ray_hex(point + up * 0.3 + field.global_basis.z * 0.3, -up - field.global_basis.z), hex)
	_expect("ray from below", field.ray_hex(point - up * 0.3, up), BattleMath.NO_HEX)
	_expect("ray beside the page", field.ray_hex(point + up * 0.3 + field.global_basis.x * 2.0, -up), BattleMath.NO_HEX)
	# the game's battle (VcmiData.battle): the stacks' cards, the reach, the obstacles and the active stack's hex
	var reach := PackedByteArray()
	reach.resize(187)
	reach[40] = 1
	var blocked := PackedByteArray()
	blocked.resize(187)
	blocked[100] = 1
	var stacks := [{"id": 1, "hex": 39, "alive": true, "active": true, "count": 5, "animation": "TEST"},
			{"id": 2, "hex": 50, "alive": false, "count": 0}, {"id": 3, "hex": 60, "alive": true, "side": 1, "count": 9}]
	field.set_battle({"reach": reach, "blocked": blocked, "stacks": stacks})
	_expect("every stack has a card", field.cards.card_count(), 3)
	_expect("a dead marker lies flat", is_equal_approx(field.cards.card(2)["node"].rotation.x, -PI / 2.0), true)
	_expect("reach", field.states[40], field.State.REACH)
	_expect("the active stack's hex", field.states[39], field.State.ACTIVE)
	_expect("an obstacle", field.states[100], field.State.BLOCKED)
	_expect("other hexes are bare", field.states[41], field.State.NONE)

	# the cards (battle_cards.gd): a creature's frames replace the marker; the stack's changes play its groups
	var cards: Node3D = field.cards
	_expect("a creature to load", cards.missing_creatures(), PackedStringArray(["TEST"]))
	var frames := []
	for group in [cards.Group.HOLDING, cards.Group.MOVING, cards.Group.HIT, cards.Group.DEATH, cards.Group.ATTACK]:
		for i in 3:
			frames.append({"group": group, "frame": i, "left": 180, "top": 200, "image": Image.create(40, 60, false,
					Image.FORMAT_RGBA8)})
	cards.set_creature("TEST", {"frames": frames})
	_expect("loaded", cards.missing_creatures(), PackedStringArray())
	cards._process(0.01)
	var first: Dictionary = cards.card(1)
	_expect("the art shows instead of the marker", [first["sprite"].visible, first["marker"].visible], [true, false])
	# the frame's pixels 180..220 x 200..260 against the anchor 196, 251 and the feet's line 263
	_expect("the frame's place on the card", first["sprite"].position.is_equal_approx(Vector3(4.0 * cards.PIXEL,
			33.0 * cards.PIXEL, 0.0)), true)
	_expect("a stack without art keeps its marker", cards.card(3)["marker"].visible, true)
	var at: Vector3 = first["node"].position
	stacks[0] = stacks[0].merged({"hex": 41}, true)
	cards.set_stacks(stacks)
	_expect("a new hex: the stack moves", first["group"], cards.Group.MOVING)
	cards._process(cards.SLIDE / 2.0)
	_expect("half way there", first["node"].position.x > at.x and first["node"].position.x < at.x + 2.0
			* field.hex_metres(), true)
	cards._process(cards.SLIDE)
	_expect("arrived, standing", [first["group"], first["node"].position.is_equal_approx(at + Vector3(2.0
			* field.hex_metres(), 0.0, 0.0))], [cards.Group.HOLDING, true])
	stacks[0] = stacks[0].merged({"count": 3}, true)
	cards.set_stacks(stacks)
	_expect("fewer creatures: hit", first["group"], cards.Group.HIT)
	cards._process(1.0)
	_expect("then standing again", first["group"], cards.Group.HOLDING)
	# stack 3 (the other side) has the turn; then stack 1 loses creatures: stack 3 struck. It has no art, so its group
	# is all that shows
	stacks[2] = stacks[2].merged({"turn": true, "hex": 42}, true)
	cards.set_stacks(stacks)
	cards._process(1.0)
	stacks[0] = stacks[0].merged({"count": 2}, true)
	cards.set_stacks(stacks)
	_expect("the stack whose turn it was strikes its neighbour", cards.card(3)["group"], cards.Group.ATTACK)
	cards._process(2.0)
	stacks[2] = stacks[2].merged({"hex": 50}, true)
	cards.set_stacks(stacks)
	cards._process(1.0)
	stacks[0] = stacks[0].merged({"count": 1}, true)
	cards.set_stacks(stacks)
	_expect("from afar it shoots", cards.card(3)["group"], cards.Group.SHOOT)
	cards._process(2.0)
	stacks[0] = stacks[0].merged({"alive": false, "count": 0}, true)
	cards.set_stacks(stacks)
	cards._process(5.0)
	_expect("dead: the death's last frame stays, standing", [first["group"], first["sprite"].visible,
			is_equal_approx(first["node"].rotation.x, -PI / 2.0)], [cards.Group.DEATH, true, false])
	cards.set_stacks([stacks[2]])
	_expect("gone stacks lose their cards", cards.card_count(), 1)
	cards.clear()
	_expect("after the battle nothing is kept", [cards.card_count(), cards.creatures.size()], [0, 0])

	# a Heroes 3 PCX, as the bridge hands the battlefield's background over: 2 x 1 pixels by palette, and as BGR
	var pcx := PackedByteArray([2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0])
	pcx.resize(14 + 768)
	pcx[14 + 3] = 10 # palette entry 1: 10, 20, 30
	pcx[14 + 4] = 20
	pcx[14 + 5] = 30
	var picture: Image = field.decode_picture(pcx)
	_expect("a palette PCX", [picture.get_size(), picture.get_pixel(0, 0).r8, picture.get_pixel(0, 0).b8], [Vector2i(2,
			1), 10, 30])
	picture = field.decode_picture(PackedByteArray([3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 30, 20, 10]))
	_expect("a BGR PCX", [picture.get_pixel(0, 0).r8, picture.get_pixel(0, 0).b8], [10, 30])
	_expect("not a picture", field.decode_picture(PackedByteArray([1, 2, 3])), null)

	print("battle_math_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(name_: String, got: Variant, want: Variant) -> void:
	if got.distance_to(want) > 0.001 if got is Vector2 else typeof(got) != typeof(want) or got != want:
		failures += 1
		print("battle_math_test: FAIL ", name_, ": got ", got, ", want ", want)

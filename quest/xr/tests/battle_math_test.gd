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
	field.set_stacks([{"hex": hex, "side": 1, "count": 12}, {"hex": 18, "side": 0, "count": 3, "wide": true}])
	field.set_stacks([{"hex": hex, "side": 1, "count": 11}])
	_expect("the cards follow the stacks", field._cards.get_child_count(), 1)

	# the game's battle (VcmiData.battle): the living stacks' cards, the reach and the active stack's hex
	var reach := PackedByteArray()
	reach.resize(187)
	reach[40] = 1
	field.set_battle({"reach": reach, "stacks": [{"hex": 39, "alive": true, "active": true, "count": 5},
			{"hex": 50, "alive": false, "count": 0}, {"hex": 60, "alive": true, "side": 1, "count": 9}]})
	_expect("the living stacks have cards", field._cards.get_child_count(), 2)
	_expect("reach", field.states[40], field.State.REACH)
	_expect("the active stack's hex", field.states[39], field.State.ACTIVE)
	_expect("other hexes are bare", field.states[41], field.State.NONE)

	print("battle_math_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(name_: String, got: Variant, want: Variant) -> void:
	if got.distance_to(want) > 0.001 if got is Vector2 else got != want:
		failures += 1
		print("battle_math_test: FAIL ", name_, ": got ", got, ", want ", want)

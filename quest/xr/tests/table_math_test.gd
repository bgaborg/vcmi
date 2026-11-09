## Local check of table_math.gd (the war table's tiles and view). Run with quest/tools/test-local.sh.
extends SceneTree

const TableMath := preload("res://table_math.gd")

var failures := 0


func _initialize() -> void:
	var map := Vector3i(72, 72, 2) # the first scenario: 72 x 72, two levels side by side
	_expect("tile of the top left", TableMath.uv_to_tile(Vector2(0.0, 0.0), map), Vector3i(0, 0, 0))
	_expect("tile left of the level line", TableMath.uv_to_tile(Vector2(0.4999, 0.5), map), Vector3i(71, 36, 0))
	_expect("tile right of the level line", TableMath.uv_to_tile(Vector2(0.5, 0.5), map), Vector3i(0, 36, 1))
	_expect("tile of the far edge", TableMath.uv_to_tile(Vector2(1.0, 1.0), map), Vector3i(71, 71, 1))
	_expect("off the map", TableMath.uv_to_tile(Vector2(-0.1, 0.5), map), TableMath.NO_TILE)
	for tile in [Vector3i(0, 0, 0), Vector3i(15, 12, 0), Vector3i(71, 71, 1), Vector3i(3, 40, 1)]:
		_expect("round trip %s" % tile, TableMath.uv_to_tile(TableMath.tile_uv(tile, map), map), tile)

	# a 0.5 m minimap of 144 tiles across: 1.5 cm a tile needs zoom 4.32; a tiny map still shows one level only
	_expect_float("zoom for 1.5 cm", TableMath.zoom_for(0.015, 0.5, map), 4.32)
	_expect_float("zoom of a small map", TableMath.zoom_for(0.015, 0.5, Vector3i(36, 36, 2)), 2.16)
	_expect_float("zoom at least the levels", TableMath.zoom_for(0.001, 0.5, map), 2.0)

	# at zoom 4 the view is 0.25 wide: on level 0 its centre stays in 0.125..0.375
	_expect("centre on the level line moves into level 0", TableMath.on_level(Vector2(0.5, 0.5), 4.0, 0, 2),
			Vector2(0.375, 0.5))
	_expect("centre on the level line moves into level 1", TableMath.on_level(Vector2(0.5, 0.5), 4.0, 1, 2),
			Vector2(0.625, 0.5))
	_expect("centre at the top edge", TableMath.on_level(Vector2(0.2, 0.0), 4.0, 0, 2), Vector2(0.2, 0.125))
	_expect("zoom 2 on two levels", TableMath.on_level(Vector2(0.3, 0.5), 2.0, 0, 2), Vector2(0.25, 0.5))

	var view := Rect2(0.1, 0.1, 0.2, 0.2)
	_expect("hero in the middle: view stays", TableMath.follow(view, Vector2(0.2, 0.22), 0.6), Vector2(0.2, 0.2))
	_expect("hero near the edge: view moves", TableMath.follow(view, Vector2(0.28, 0.2), 0.6), Vector2(0.28, 0.2))

	print("table_math_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(name_: String, got: Variant, want: Variant) -> void:
	var same: bool = got.is_equal_approx(want) if got is Vector2 else got == want
	if not same:
		failures += 1
		print("table_math_test: FAIL ", name_, ": got ", got, ", want ", want)


func _expect_float(name_: String, got: float, want: float) -> void:
	if absf(got - want) > 0.0001:
		failures += 1
		print("table_math_test: FAIL ", name_, ": got ", got, ", want ", want)

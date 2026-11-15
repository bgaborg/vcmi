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

	# a map half as tall as the table's shape (aspect 2): at zoom 4 the view is 0.5 of the map's height
	_expect("aspect 2: centre at the top edge", TableMath.on_level(Vector2(0.2, 0.0), 4.0, 0, 2, 2.0), Vector2(0.2,
			0.25))
	_expect("aspect 2: a view taller than the map", TableMath.on_level(Vector2(0.3, 0.9), 2.0, 0, 2, 2.0),
			Vector2(0.25, 0.5))
	_expect("aspect 2: drag down", TableMath.drag(Vector2(0.3, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.75), 4.0, 2.0),
			Vector2(0.3, 0.375))

	var view := Rect2(0.1, 0.1, 0.2, 0.2)
	_expect("hero in the middle: view stays", TableMath.follow(view, Vector2(0.2, 0.22), 0.6), Vector2(0.2, 0.2))
	_expect("hero near the edge: view moves", TableMath.follow(view, Vector2(0.28, 0.2), 0.6), Vector2(0.28, 0.2))

	# the focus two thirds of the way to the player: a hero in the far part moves the view so that it lands there
	_expect("hero far from the focus: view moves", TableMath.follow(view, Vector2(0.2, 0.12), 0.6, Vector2(0.5, 0.75)),
			Vector2(0.2, 0.07))
	_expect("hero near the focus: view stays", TableMath.follow(view, Vector2(0.2, 0.25), 0.6, Vector2(0.5, 0.75)),
			Vector2(0.2, 0.2))

	# with a reach of 0.25 of the panel the view may go past the map's top: the first row comes near the player
	_expect("reach: centre past the top edge", TableMath.on_level(Vector2(0.2, -0.5), 4.0, 0, 2, 2.0, 0.25),
			Vector2(0.2, -0.125))

	# a grab: the hand moves a quarter of the table right at zoom 4: the view moves a sixteenth of the map left
	_expect("drag right", TableMath.drag(Vector2(0.3, 0.5), Vector2(0.5, 0.5), Vector2(0.75, 0.5), 4.0), Vector2(0.2375,
			0.5))
	_expect("drag back to the start", TableMath.drag(Vector2(0.3, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.5), 4.0),
			Vector2(0.3, 0.5))
	# zooming about the panel centre keeps the centre; about a corner keeps the map point under it
	_expect("zoom about the middle", TableMath.zoom_about(Vector2(0.3, 0.4), 4.0, 8.0, Vector2(0.5, 0.5)), Vector2(0.3,
			0.4))
	var pivot := Vector2(0.75, 0.25)
	var zoomed := TableMath.zoom_about(Vector2(0.3, 0.4), 4.0, 8.0, pivot)
	_expect("zoom keeps the point under the hands", zoomed + (pivot - Vector2(0.5, 0.5)) / 8.0,
			Vector2(0.3, 0.4) + (pivot - Vector2(0.5, 0.5)) / 4.0)

	var turned := [TableMath.turned_over(Vector3.UP, Vector3.UP.rotated(Vector3.FORWARD, deg_to_rad(90.0))),
			TableMath.turned_over(Vector3.UP, Vector3.UP.rotated(Vector3.FORWARD, deg_to_rad(150.0)))]
	if turned != [false, true]:
		failures += 1
		print("table_math_test: FAIL a hand turned a quarter and nearly over: got ", turned)

	# a real table 2 m to the right and 1 m behind the tracking origin, its edges along x, the player at its far (-z)
	# side: its top's middle comes to the map's middle, and the player's side to the chair's
	var placed := TableMath.on_real_table(Vector3(0.0, 0.84, 0.0), Vector3(0.0, 1.29, 0.82), Vector3(2.0, 0.75, 1.0),
			Vector3.RIGHT, Vector2(1.0, 1.0), Vector3(2.0, 1.2, 0.2))
	var head_at := placed * Vector3(2.0, 1.2, 0.2)
	_expect("a real table's top under the map", (placed * Vector3(2.0, 0.75, 1.0)).distance_to(Vector3(0.0, 0.84, 0.0))
			< 0.0001, true)
	_expect("its player's side at the chair's, the floor level", [head_at.z > 0.7, absf(head_at.x) < 0.0001,
			placed.basis.y.is_equal_approx(Vector3.UP)], [true, true, true])
	# a long table (2 x 0.6 m along x): a player at its long side near one end sits at that long side
	placed = TableMath.on_real_table(Vector3(0.0, 0.84, 0.0), Vector3(0.0, 1.29, 0.82), Vector3.ZERO, Vector3.RIGHT,
			Vector2(2.0, 0.6), Vector3(0.7, 1.2, 0.5))
	var at_seat := placed * Vector3(0.7, 1.2, 0.5)
	_expect("a long table's long side faces the player near its end", [at_seat.z > 0.4, absf(at_seat.x - 0.7)
			< 0.0001], [true, true])
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

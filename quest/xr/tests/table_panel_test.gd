## Local check of the table's side panel (table_panel.gd, quest/PHASE4.md 4d): the entries land where the layout puts
## them, a ray finds them from the board's front only and finds the hourglass, and the selection survives new data.
## Run with quest/tools/test-local.sh.
extends SceneTree

const TablePanel := preload("res://table_panel.gd")

var failures := 0


func _initialize() -> void:
	var panel: Node3D = TablePanel.new()
	root.add_child(panel)
	panel.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3(1.0, 0.85, -0.3))
	var heroes := []
	for i in 10: # more than a column shows
		heroes.append({"id": 100 + i, "name": "Hero %d" % i, "movement": 1500, "max_movement": 2000, "mana": 10,
				"max_mana": 20, "sleeping": i == 1})
	panel.set_data({"date": "Month: 1, Week: 1, Day: 1", "resources": PackedInt32Array([20, 10, 20, 10, 10, 10, 30000]),
			"heroes": heroes, "towns": [{"id": 7, "name": "Castle"}]})
	await process_frame

	var shown_heroes: int = panel.items.filter(func(i): return i["kind"] == "hero").size()
	_expect("heroes shown, cut to a column", shown_heroes, TablePanel.ROWS)
	_expect("towns", panel.items.filter(func(i): return i["kind"] == "town").size(), 1)
	var second_hero := Vector2(0.0, TablePanel.row_top(TablePanel.heroes_top(), 1, TablePanel.HERO_ROW) - 0.02)
	_expect("second hero's line", panel.items[panel.item_at(second_hero)]["id"], 101)
	var town := Vector2(0.0, TablePanel.row_top(TablePanel.towns_top(), 0, TablePanel.TOWN_ROW) - 0.015)
	_expect("town's line", panel.items[panel.item_at(town)]["id"], 7)
	_expect("the title is no entry", panel.item_at(Vector2(0.0, TablePanel.BOARD_SIZE.y / 2.0 - 0.02)), -1)
	_expect("a sleeping hero's line", TablePanel.hero_text(heroes[1]).ends_with("zz"), true)
	_expect("thousands spaced", TablePanel._number(14500), "14 500")

	# a ray from 20 cm in front of the second hero's line, from behind the board, and at the hourglass
	var board: Transform3D = panel.global_transform * TablePanel.BOARD_POSE
	var point: Vector3 = board * Vector3(second_hero.x, second_hero.y, 0.0)
	var normal: Vector3 = board.basis.z.normalized()
	var hit: Array = panel.ray_item(point + normal * 0.2, -normal)
	_expect("ray from the front", panel.items[hit[0]]["id"] if not hit.is_empty() else -1, 101)
	_expect("ray hit point", (hit[1] as Vector3).distance_to(point) < 0.0001 if not hit.is_empty() else false, true)
	_expect("ray from behind", panel.ray_item(point - normal * 0.2, normal), [])
	var glass: Vector3 = panel.global_transform * (TablePanel.HOURGLASS_AT + Vector3(0.0, 0.08, 0.0))
	var at_glass: Array = panel.ray_item(glass + Vector3(0.0, 0.3, 0.3), Vector3(0.0, -1.0, -1.0))
	_expect("ray at the hourglass", panel.items[at_glass[0]]["kind"] if not at_glass.is_empty() else "", "end_turn")
	_expect("ray past everything", panel.ray_item(glass + Vector3(0.0, 0.3, 0.3), Vector3(0.0, 1.0, 0.0)), [])

	# a hero's step from 1500 to 500 of 2000 movement: the same layout, the bar a third as long, in place
	var content: Node3D = panel._board_content
	var fill: MeshInstance3D = panel._meters[0][0][0]
	var full: float = (fill.mesh as QuadMesh).size.x
	var stepped: Array = heroes.duplicate(true)
	stepped[0]["movement"] = 500
	panel.set_data({"date": "Month: 1, Week: 1, Day: 1", "resources": PackedInt32Array([20, 10, 20, 10, 10, 10, 30000]),
			"heroes": stepped, "towns": [{"id": 7, "name": "Castle"}]})
	_expect("a step keeps the layout", panel._board_content == content, true)
	_expect("a step shortens the bar", is_equal_approx((fill.mesh as QuadMesh).size.x, full / 3.0), true)

	panel.set_selected(101)
	panel.set_data({"heroes": heroes})
	_expect("selection kept over new data", panel.selected, 101)
	panel.visible = false
	_expect("a hidden panel takes no ray", panel.ray_item(point + normal * 0.2, -normal), [])

	print("table_panel_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(what: String, got: Variant, wanted: Variant) -> void:
	if got != wanted:
		failures += 1
		print("table_panel_test: ", what, ": got ", got, ", wanted ", wanted)

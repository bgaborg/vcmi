## Local check of the table's side panel (table_panel.gd, quest/PHASE4.md 4d): the entries land where the layout puts
## them, a ray finds them from the panel's front only, and the selection survives new data. Run with
## quest/tools/test-local.sh.
extends SceneTree

const TablePanel := preload("res://table_panel.gd")

var failures := 0


func _initialize() -> void:
	var panel: Node3D = TablePanel.new()
	root.add_child(panel)
	panel.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-60.0)), Vector3(1.0, 0.85, -0.3))
	var heroes := []
	for i in 10: # more than a column shows
		heroes.append({"id": 100 + i, "name": "Hero %d" % i, "movement": 1500, "max_movement": 2000, "mana": 10,
				"max_mana": 20, "sleeping": i == 1})
	panel.set_data({"date": "Month: 1, Week: 1, Day: 1", "resources": PackedInt32Array([20, 10, 20, 10, 10, 10, 30000]),
			"heroes": heroes, "towns": [{"id": 7, "name": "Castle"}]})
	await process_frame

	_expect("heroes shown, cut to a column", panel.items.filter(func(i): return i["kind"] == "hero").size(), 8)
	_expect("towns", panel.items.filter(func(i): return i["kind"] == "town").size(), 1)
	var second_hero := Vector2(TablePanel.HEROES.x + 0.01, TablePanel.row_y(1))
	_expect("second hero's line", panel.items[panel.item_at(second_hero)]["id"], 101)
	_expect("town's line", panel.items[panel.item_at(Vector2(TablePanel.TOWNS.x + 0.01, TablePanel.row_y(0)))]["id"], 7)
	_expect("end turn", panel.items[panel.item_at(TablePanel.END_TURN.get_center())]["kind"], "end_turn")
	_expect("the resources are no entry", panel.item_at(Vector2(TablePanel.INFO.x + 0.01, TablePanel.row_y(3))), -1)
	_expect("a sleeping hero's line", TablePanel.hero_text(heroes[1]).ends_with("zz"), true)

	# a ray from 20 cm in front of the second hero's line, and from behind the panel
	var point: Vector3 = panel.global_transform * Vector3(second_hero.x, second_hero.y, 0.0)
	var normal: Vector3 = panel.global_basis.z.normalized()
	var hit: Array = panel.ray_item(point + normal * 0.2, -normal)
	_expect("ray from the front", panel.items[hit[0]]["id"] if not hit.is_empty() else -1, 101)
	_expect("ray hit point", (hit[1] as Vector3).distance_to(point) < 0.0001 if not hit.is_empty() else false, true)
	_expect("ray from behind", panel.ray_item(point - normal * 0.2, normal), [])
	_expect("ray past the strip", panel.ray_item(point + normal * 0.2 + panel.global_basis.x * 1.0, -normal), [])

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

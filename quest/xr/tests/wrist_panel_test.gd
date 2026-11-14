## Local check of the wrist panel (wrist_panel.gd): each page has its buttons, a ray finds them from the front only,
## and the settings' buttons carry their setting and step. Run with quest/tools/test-local.sh.
extends SceneTree

const WristPanel := preload("res://wrist_panel.gd")

var failures := 0


func _initialize() -> void:
	var panel: Node3D = WristPanel.new()
	root.add_child(panel)
	panel.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3(1.0, 1.2, -0.3))
	await process_frame
	_expect("keys page: tabs and keys", panel.buttons.size(), WristPanel.PAGES.size() + WristPanel.KEYS.size())
	var normal: Vector3 = panel.global_basis.z
	# a ray from 20 cm before a point of the panel
	var press := func(at: Vector2) -> Variant:
		var point: Vector3 = panel.global_transform * Vector3(at.x, at.y, 0.0)
		var hit: Array = panel.ray_button(point + normal * 0.2, -normal)
		return null if hit.is_empty() else panel.buttons[hit[0]]["action"]
	var row := func(r: int) -> float: return (2.5 - r) * WristPanel.CELL.y
	_expect("first key", press.call(Vector2(-0.04, row.call(1))), 33)
	_expect("last key", press.call(Vector2(0.04, row.call(5))), 36)
	_expect("the settings' tab", press.call(Vector2(0.04, row.call(0))), ["page", 1])
	_expect("beside the panel", press.call(Vector2(0.1, 0.0)), null)
	var centre: Vector3 = panel.global_position
	_expect("from behind", panel.ray_button(centre - normal * 0.2, normal), [])

	panel.show_page(1, {"height": "45 cm below"})
	_expect("settings page: tabs, - and +", panel.buttons.size(), WristPanel.PAGES.size() + 2 * WristPanel.SETTINGS.size())
	_expect("table lower", press.call(Vector2(-0.07, row.call(1))), ["height", -1])
	_expect("room, next", press.call(Vector2(0.07, row.call(5))), ["room", 1])
	_expect("a setting's text is no button", press.call(Vector2(0.0, row.call(2))), null)
	_expect("back to the keys", press.call(Vector2(-0.04, row.call(0))), ["page", 0])
	panel.set_hover(2)
	_expect("hover lights one button", panel.buttons.filter(func(b):
		return b["mesh"].mesh.material.albedo_color == WristPanel.LIT).size(), 1)

	print("wrist_panel_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(name_: String, got: Variant, want: Variant) -> void:
	if typeof(got) != typeof(want) or got != want:
		failures += 1
		print("wrist_panel_test: FAIL ", name_, ": got ", got, ", want ", want)

## Local check of the table picking math (room.gd table_uv, quest/PHASE4.md check 3): rays straight down onto known
## points of the minimap, at zoom 1 and zoomed, must land on the expected map UV. Run with quest/tools/test-local.sh.
extends SceneTree

var failures := 0


func _initialize() -> void:
	var room: Node3D = preload("res://room.gd").new()
	root.add_child(room)
	await process_frame
	var panel: Transform3D = room._minimap.global_transform
	var size: Vector2 = room.minimap_size()
	var down := -panel.basis.y.normalized()
	# a point of the panel at panel UV p, and a ray from 10 cm above it
	var ray_at := func(p: Vector2) -> Vector2:
		var point := panel * Vector3((p.x - 0.5) * size.x, 0.0, (p.y - 0.5) * size.y)
		return room.table_uv(point - down * 0.1, down)

	room.set_zoom(1.0, Vector2(0.5, 0.5))
	_expect("zoom 1, centre", ray_at.call(Vector2(0.5, 0.5)), Vector2(0.5, 0.5))
	_expect("zoom 1, a corner quarter", ray_at.call(Vector2(0.75, 0.25)), Vector2(0.75, 0.25))
	_expect("zoom 1, off the panel", ray_at.call(Vector2(1.2, 0.5)), Vector2(-1.0, -1.0))

	room.set_zoom(4.0, Vector2(0.25, 0.5))
	_expect("zoom 4, centre", ray_at.call(Vector2(0.5, 0.5)), Vector2(0.25, 0.5))
	_expect("zoom 4, panel 0.75, 0.25", ray_at.call(Vector2(0.75, 0.25)), Vector2(0.3125, 0.4375))

	# a centre near the edge is clamped, so the view stays on the map
	room.set_zoom(4.0, Vector2(0.0, 0.0))
	_expect("zoom 4, clamped centre", ray_at.call(Vector2(0.5, 0.5)), Vector2(0.125, 0.125))

	var centre: Vector3 = room.minimap_centre()
	_expect("ray along the table", room.table_uv(centre + panel.basis.y * 0.1, panel.basis.x), Vector2(-1.0, -1.0))
	_expect("ray away from the table", room.table_uv(centre + panel.basis.y * 0.1, -down), Vector2(-1.0, -1.0))

	print("table_uv_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(name_: String, got: Vector2, want: Vector2) -> void:
	if got.distance_to(want) > 0.0001:
		failures += 1
		print("table_uv_test: FAIL ", name_, ": got ", got, ", want ", want)

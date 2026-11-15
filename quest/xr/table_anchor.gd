extends Node3D
## The player's real table in passthrough (quest/PROJECT_PLAN.md phase 6, "snap the board to a real table"): the Meta
## scene's anchors (the room the player scanned in the headset's settings) come as instances of this node from an
## OpenXRFbSceneManager (godotopenxrvendors); one labelled TABLE joins the group "real_tables" with its top's middle and
## edge direction, and main.gd lays the map on it (TableMath.on_real_table). Without a scanned table nothing changes:
## the map lies at the wrist panel's height.

const PERMISSION := "com.oculus.permission.USE_SCENE"


## The scene manager under `origin` (the XROrigin3D: the anchors are placed in its space), or null where the plugin
## has none (the PC). It makes the anchors once the player allowed the headset to share the room (ask_permission)
static func make_manager(origin: Node3D) -> Node:
	if not ClassDB.class_exists("OpenXRFbSceneManager"):
		return null
	var manager: Node = ClassDB.instantiate("OpenXRFbSceneManager")
	var anchor := Node3D.new()
	anchor.set_script(load("res://table_anchor.gd"))
	var scene := PackedScene.new()
	scene.pack(anchor)
	anchor.free()
	manager.set("default_scene", scene)
	manager.set("auto_create", true)
	manager.connect("openxr_fb_scene_data_missing", func(): print("VCMI XR: no room scanned: the table stays put"))
	origin.add_child(manager)
	return manager


## Passthrough asks once for the room's data (a system dialog); granted, the manager makes the anchors
static func ask_permission(manager: Node) -> void:
	if manager == null or OS.get_name() != "Android" or PERMISSION in OS.get_granted_permissions():
		return
	manager.get_tree().on_request_permissions_result.connect(func(permission: String, granted: bool):
		if permission == PERMISSION and granted: # made again: a try before the permission found nothing
			manager.call("remove_scene_anchors")
			manager.call("create_scene_anchors"), CONNECT_ONE_SHOT)
	OS.request_permission(PERMISSION)


## The first real table: [its top's middle, a horizontal direction along an edge, its size along that edge and
## across] in `origin`'s space, or []
static func find(origin: Node3D) -> Array:
	for table: Node3D in origin.get_tree().get_nodes_in_group("real_tables"):
		var space := origin.global_transform.affine_inverse() * table.global_transform
		var middle: Vector2 = table.get_meta("top")
		var edge := space.basis.x
		edge.y = 0.0
		if edge.length_squared() < 0.0001:
			edge = space.basis.y # the plane's x stands upright: its y lies along the other edge
			edge.y = 0.0
		var size: Vector2 = table.get_meta("size")
		return [space * Vector3(middle.x, middle.y, 0.0), edge.normalized(), size if space.basis.x.y * space.basis.x.y
				< 0.5 else Vector2(size.y, size.x)]
	return []


## Called by the scene manager for each anchor of the scanned room
func setup_scene(entity: Object) -> void:
	var labels: PackedStringArray = entity.call("get_semantic_labels")
	if not ("TABLE" in labels or "table" in labels):
		return
	var box: Rect2 = entity.call("get_bounding_box_2d") # the top, in the anchor's x y plane
	set_meta("top", box.get_center())
	set_meta("size", box.size)
	print("VCMI XR: a real table, ", box.size, " m")
	# measured once the headset has placed its anchor (the parent), not at the origin before
	var anchor := get_parent() as XRNode3D
	if anchor == null or anchor.get_has_tracking_data():
		add_to_group("real_tables")
	else:
		anchor.tracking_changed.connect(_on_tracking)


func _on_tracking(tracking: bool) -> void:
	if tracking:
		add_to_group("real_tables")

@tool
extends Node3D
## Bakes the war room lightmap (room.gd LIGHTMAP) in the editor; run quest/tools/bake-room.sh.
## Opened in the editor without the --bake-room user argument, it only shows the room.

func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	var room: Node3D = load("res://room.gd").new()
	room.name = "Room"
	add_child(room)
	# the bake only walks nodes that belong to the edited scene
	for node in room.find_children("*", "", true, false):
		if node.owner == null:
			node.owner = self
	if "--bake-room" in OS.get_cmdline_user_args():
		print("room bake: started")
		_bake(room)


func _bake(room: Node3D) -> void:
	var lightmap: LightmapGI = room.get_node("Lightmap")
	var path: String = room.LIGHTMAP
	if lightmap.light_data == null:
		# the editor bakes into the file of the current data; without one it would ask for a file name
		ResourceSaver.save(LightmapGIData.new(), path)
		lightmap.light_data = load(path)
	await get_tree().create_timer(3.0).timeout
	EditorInterface.edit_node(lightmap)
	await get_tree().create_timer(1.0).timeout
	print("room bake: pressing Bake Lightmaps")
	var button := _find_button(EditorInterface.get_base_control())
	if button == null:
		printerr("room bake: no Bake Lightmaps button")
		get_tree().quit(1)
		return
	var started := Time.get_ticks_msec()
	button.pressed.emit() # bakes before it returns
	var data := lightmap.light_data
	var users := data.get_user_count() if data != null else 0
	print("room bake: ", users, " meshes into ", data.resource_path if data != null else "nothing", " in ",
			(Time.get_ticks_msec() - started) / 1000.0, " s")
	get_tree().quit(0 if users > 0 else 1)


func _find_button(node: Node) -> Button:
	if node is Button and node.text == "Bake Lightmaps":
		return node
	for child in node.get_children():
		var found := _find_button(child)
		if found != null:
			return found
	return null

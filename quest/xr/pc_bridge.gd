extends RefCounted
# gdlint: disable=function-name
## The game's bridge (the Android plugin VcmiBridge) where there is none: the PC, with Meta XR Simulator as the OpenXR
## runtime (quest/tools/xrsim.sh). The war room, the table and the controllers run; the game does not, so its input
## goes nowhere and its screen stays empty.
## With VCMI_XR_SCRIPT (a file of lines `<seconds> <command> [a] [b] [c]`, `#` comments), it plays the test commands
## the headset gets over adb (main.gd _on_test_command) at those times after start, plus `shot <name>` and `quit`.
## A shot renders the scene once from the headset's pose into $VCMI_XR_SHOTS/<name>.png: the eyes render into the
## runtime's swapchain, which Godot cannot read back, and the window's own image goes stale while it is covered.
## Composition layers (the game screen) are not in it.

signal test_command(command: String, a: float, b: float, c: float)


func _init() -> void:
	var script := OS.get_environment("VCMI_XR_SCRIPT")
	if script == "" or not FileAccess.file_exists(script):
		return
	var tree := Engine.get_main_loop() as SceneTree
	for line in FileAccess.get_file_as_string(script).split(String.chr(10)):
		var words := line.strip_edges().split(" ", false)
		if words.size() < 2 or words[0].begins_with("#"):
			continue
		var numbers := [0.0, 0.0, 0.0]
		for i in mini(words.size() - 2, 3):
			numbers[i] = float(words[i + 2])
		var shot := words[2] if words.size() > 2 else ""
		tree.create_timer(float(words[0])).timeout.connect(_play.bind(words[1], numbers, shot))


func _play(command: String, numbers: Array, shot: String) -> void:
	print("VCMI XR sim: ", command, " ", shot)
	var tree := Engine.get_main_loop() as SceneTree
	match command:
		"shot":
			_shot(tree, shot)
		"quit":
			tree.quit()
		_:
			test_command.emit(command, numbers[0], numbers[1], numbers[2])


func _shot(tree: SceneTree, name: String) -> void:
	var eyes := tree.root.find_children("*", "XRCamera3D", true, false)
	if eyes.is_empty():
		push_error("VCMI XR sim: no XR camera for shot ", name)
		return
	var view := SubViewport.new()
	view.size = Vector2i(1280, 720)
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	view.world_3d = (eyes[0] as Camera3D).get_world_3d()
	var camera := Camera3D.new()
	camera.fov = 90.0
	view.add_child(camera)
	tree.root.add_child(view)
	camera.global_transform = (eyes[0] as Camera3D).global_transform
	await RenderingServer.frame_post_draw
	view.get_texture().get_image().save_png(OS.get_environment("VCMI_XR_SHOTS").path_join(name + ".png"))
	view.queue_free()


func startGame(_surface: Variant, _width: int, _height: int) -> void:
	pass


func setSurface(_surface: Variant) -> void:
	pass


func pointerMove(_x: float, _y: float) -> void:
	pass


func pointerButton(_button: int, _pressed: bool) -> void:
	pass


func key(_code: int, _pressed: bool) -> void:
	pass


func gamepadButton(_button: int, _pressed: bool) -> void:
	pass


func gamepadAxis(_axis: int, _value: float) -> void:
	pass


func hapticFeedbackEnabled() -> bool:
	return true

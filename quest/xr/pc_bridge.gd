extends RefCounted
# gdlint: disable=function-name
## The game's bridge (the Android plugin VcmiBridge) on the PC, with Meta XR Simulator as the OpenXR runtime
## (quest/tools/xrsim.sh): the VcmiData extension loads the Windows build of the game (quest/tools/make-pc.sh) into this
## process and runs it offscreen, as the plugin runs it on a virtual display. Its frames fill `viewport`, which main.gd
## shows on the screen's composition layer; the pointer and the keys go to it as SDL events. Without the extension or
## the game (VCMI_PC_GAME, default the build in ~/vcmi-build) the room runs alone and the screen stays empty.
## With VCMI_XR_SCRIPT (a file of lines `<seconds> <command> [a] [b] [c]`, `#` comments), it plays the test commands
## the headset gets over adb (main.gd _on_test_command) at those times after start, plus `shot <name>`, `tap <x> <y>`
## (a left click at a game pixel) and `quit`.
## A shot renders the scene once from the headset's pose into $VCMI_XR_SHOTS/<name>.png: the eyes render into the
## runtime's swapchain, which Godot cannot read back, and the window's own image goes stale while it is covered.
## Composition layers are not in it, so the game's own frame goes into <name>-game.png beside it.

signal test_command(command: String, a: float, b: float, c: float)

var viewport := SubViewport.new() ## the game's frames, for the screen's composition layer
var _data: Object = ClassDB.instantiate("VcmiData") if ClassDB.class_exists("VcmiData") else null
var _frame := TextureRect.new()
var _pointer := Vector2.ZERO


func _init() -> void:
	viewport.add_child(_frame)
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
		"tap": # a left click at game pixel a, b, through the methods main.gd calls
			pointerMove(numbers[0], numbers[1])
			pointerButton(1, true)
			await tree.create_timer(0.1).timeout
			pointerButton(1, false)
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
	if _frame.texture != null:
		_frame.texture.get_image().save_png(OS.get_environment("VCMI_XR_SHOTS").path_join(name + "-game.png"))


func startGame(_surface: Variant, width: int, height: int) -> void:
	viewport.size = Vector2i(width, height)
	var dll := OS.get_environment("VCMI_PC_GAME")
	if dll == "":
		dll = OS.get_environment("USERPROFILE").path_join("vcmi-build/win/build/bin/Release/VCMI_client.dll")
	if _data == null or not FileAccess.file_exists(dll) or not _data.pc_start(dll, viewport.size):
		push_warning("VCMI XR: no game on the PC (", dll, "): quest/tools/make-pc.sh builds it")
		return
	var tree := Engine.get_main_loop() as SceneTree
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	tree.process_frame.connect(_show_frame)


## the newest frame on the screen
func _show_frame() -> void:
	var image: Image = _data.pc_frame()
	if image == null:
		return
	if _frame.texture == null or Vector2i(_frame.texture.get_size()) != image.get_size():
		_frame.texture = ImageTexture.create_from_image(image)
		_frame.size = viewport.size
	else:
		(_frame.texture as ImageTexture).update(image)


func setSurface(_surface: Variant) -> void:
	pass


func pointerMove(x: float, y: float) -> void:
	_pointer = Vector2(x, y)
	if _data != null:
		_data.pc_mouse(x, y, 0, false)


func pointerButton(button: int, pressed: bool) -> void:
	if _data != null:
		_data.pc_mouse(_pointer.x, _pointer.y, button, pressed)


func key(code: int, pressed: bool) -> void:
	if _data != null:
		_data.pc_key(code, pressed)


func gamepadButton(button: int, pressed: bool) -> void:
	if _data != null:
		_data.pc_button(button, pressed)


func gamepadAxis(axis: int, value: float) -> void:
	if _data != null:
		_data.pc_axis(axis, value)


func hapticFeedbackEnabled() -> bool:
	return true

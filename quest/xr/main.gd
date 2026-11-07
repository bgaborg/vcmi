extends Node3D
## Shows the VCMI game activity on a curved layer and passes the controller ray to it as a mouse.
## Test commands from adb (VcmiBridge `test_command`, quest/tools/quest.sh test) simulate the head, the aim and clicks.

const SCREEN_DISTANCE := Vector2(1.0, 4.0) ## metres from the head, min and max; the cylinder radius, so a nearer screen curves more
const SCREEN_WIDTH := Vector2(1.0, 4.0) ## metres of arc, min and max
const SCREEN_MAX_ANGLE := 2.0 ## radians of arc, about the headset field of view: a near screen does not wrap around the head
const SCREEN_SPEED := 0.8 ## metres per second at full left thumbstick
const SETTINGS_PATH := "user://screen.cfg"
const SURFACE_SIZE := Vector2i(2560, 1440) ## pixels of the game window
const BUTTON_LEFT := 1 ## MotionEvent.BUTTON_PRIMARY
const BUTTON_RIGHT := 2 ## MotionEvent.BUTTON_SECONDARY
const NO_HIT := Vector2(-1.0, -1.0)
## controller buttons to the SDL gamepad (KeyEvent.KEYCODE_BUTTON_*); the game binds them in config/keyBindingsConfig.json "joystickButtons"
const PAD_BUTTONS := {
	"1:ax_button": 96, # right A -> A: accept
	"1:by_button": 97, # right B -> B: cancel
	"0:ax_button": 102, # left X -> left shoulder: next hero
	"0:by_button": 103, # left Y -> right shoulder: next town
	"0:menu_button": 108, # left menu -> start: options
	"0:primary_click": 106, # left stick click -> left stick: map level
	"1:primary_click": 107, # right stick click -> right stick: grid
}
const MENU_HOLD_MS := 600 ## holding the left menu button this long switches the environment instead of opening the game options
## the wrist panel: label and Android KeyEvent.KEYCODE_*, the game's own keys from config/keyBindingsConfig.json "keyboard";
## the labels name the key because other screens bind it to something else (in battle D is defend)
const HOTKEYS := [
	["End turn (E)", 33], ["Spells (C)", 31],
	["Kingdom (K)", 39], ["Quests (Q)", 45],
	["Sleep (Z)", 54], ["Dig (D)", 32],
	["Quick save (F8)", 138], ["Quick load (F9)", 139],
]
const HOTKEY_SIZE := Vector2(0.08, 0.025) ## metres per button
## above the back of the left controller, tilted towards the eyes like a watch face
const HOTKEY_PANEL_POSE := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-45.0)), Vector3(0.0, 0.05, 0.07))
const PAD_RIGHT_X := 2 ## the right thumbstick is the gamepad right stick: the game scrolls the map with it ("mouseSwipe")
const PAD_RIGHT_Y := 3

var bridge: Object
var vcmi_data: RefCounted ## game data from the bridge in quest/bridge (quest/DATA_BRIDGE.md); null without the extension
var origin: XROrigin3D
var layer: OpenXRCompositionLayerCylinder
var aims: Array[XRController3D] = []
var grips: Array[XRController3D] = [] ## carry the controller models and the hotkey panel
var models: Array[Node3D] = []
var rays: Array[MeshInstance3D] = []
var pointer_dot: Node3D ## where the active ray hits the screen
var active_hand := 1
var screen_world := Transform3D() ## screen pose in the world; the layer node is under the origin, which a simulated head moves
var screen_placed := false
var game_started := false
var surface_pending := true ## the layer creates a new Android surface for each OpenXR session
var last_pointer := Vector2i(-1, -1) ## last pointer position sent to the game, in game pixels
var screen_distance := 2.0
var screen_width := 2.4
var screen_stick := Vector2.ZERO ## left thumbstick: y = distance, x = width
const ENVIRONMENTS := ["war room", "passthrough", "black"] ## around the screen; a long left menu press goes to the next
var environment_name: String = ENVIRONMENTS[0]
var room: Node3D
var screen_occluder: ShaderMaterial ## on the screen: writes depth and leaves the pixels transparent, so the game layer shows through
var menu_pressed_at := -1 ## Time.get_ticks_msec() of a left menu press not yet handled, or -1
var environment: Environment
var hotkey_panel: Node3D ## on the left controller, shown when it faces the head; the right ray presses its buttons
var hotkey_buttons: Array[MeshInstance3D] = []
var hotkey_hover := -1 ## HOTKEYS index the right ray points at, or -1
var hotkey_pressed := false ## the right trigger went down on the panel: its release goes there too
var test_wrist := false ## the panel held in front of the head instead of on the controller
var test_head: Variant = null ## Transform3D: simulated head pose in the world, null for the tracked head
var test_head_start: Variant = null ## Transform3D: tracked head when the simulated head was set
var test_aim: Variant = null ## Vector2: simulated aim of the active hand from the head, yaw and pitch in degrees from the screen centre


func _ready() -> void:
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr == null or not xr.is_initialized():
		push_error("VCMI XR: OpenXR is not initialised")
		get_tree().quit()
		return
	get_viewport().use_xr = true
	xr.pose_recentered.connect(func(): screen_placed = false)
	xr.session_begun.connect(func(): surface_pending = true)
	# the stick and the menu button may not report their release while the system menu has focus
	xr.session_visible.connect(func():
		_on_stick("primary", Vector2.ZERO, 0)
		menu_pressed_at = -1)

	# the controller models have lit glTF materials
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	add_child(light)
	room = preload("res://room.gd").new()
	add_child(room)
	# Godot's hole punch does not write depth, so the room behind the screen would draw over the game
	var shader := Shader.new()
	shader.code = "shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_disabled, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"
	screen_occluder = ShaderMaterial.new()
	screen_occluder.shader = shader
	screen_occluder.render_priority = -1 # before the room, which draws in the transparent pass (room.gd)
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	origin = XROrigin3D.new()
	add_child(origin)
	origin.add_child(XRCamera3D.new())

	layer = OpenXRCompositionLayerCylinder.new()
	bridge = Engine.get_singleton("VcmiBridge")
	layer.use_android_surface = true
	layer.android_surface_size = SURFACE_SIZE
	bridge.connect("test_command", _on_test_command)
	# the extension (quest/xr/extension) finds the game's bridge once the game library has loaded, after Godot
	if ClassDB.class_exists("VcmiData"):
		vcmi_data = ClassDB.instantiate("VcmiData")
		var bridge_timer := Timer.new()
		bridge_timer.timeout.connect(func():
			if vcmi_data.connect_bridge():
				bridge_timer.queue_free())
		add_child(bridge_timer)
		bridge_timer.start(1.0)
	else:
		push_error("VCMI XR: the VcmiData extension is missing, no game data")
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		_size_screen(settings.get_value("screen", "distance", screen_distance), settings.get_value("screen", "width", screen_width))
		_set_environment(settings.get_value("screen", "environment", ENVIRONMENTS[0]))
	else:
		_size_screen(screen_distance, screen_width)
	layer.aspect_ratio = float(SURFACE_SIZE.x) / SURFACE_SIZE.y # width / height, as in XrCompositionLayerCylinderKHR
	# behind the Godot frame, so the controllers and the ray draw over the game
	layer.sort_order = -1
	layer.enable_hole_punch = true
	origin.add_child(layer)

	var ray_material := StandardMaterial3D.new()
	ray_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ray_material.albedo_color = Color(0.35, 0.75, 1.0)
	for hand in 2:
		var tracker := "left_hand" if hand == 0 else "right_hand"
		var grip := XRController3D.new()
		grip.tracker = tracker
		grip.pose = "grip"
		origin.add_child(grip)
		var model := ClassDB.instantiate("OpenXRFbRenderModel") as Node3D
		model.set("render_model_type", hand)
		model.connect("openxr_fb_render_model_loaded", func(): print("VCMI XR: controller model loaded: ", tracker))
		grip.add_child(model)
		grips.append(grip)
		models.append(model)

		var aim := XRController3D.new()
		aim.tracker = tracker
		aim.pose = "aim"
		origin.add_child(aim)
		aim.button_pressed.connect(_on_button.bind(hand, true))
		aim.button_released.connect(_on_button.bind(hand, false))
		aim.input_vector2_changed.connect(_on_stick.bind(hand))
		aims.append(aim)

		# in world space, so a simulated aim draws the same way as a controller
		var ray := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.003, 0.003, 1.0)
		box.material = ray_material
		ray.mesh = box
		ray.visible = false
		add_child(ray)
		rays.append(ray)

	_build_hotkey_panel()

	# the game's own cursor is not drawn into the virtual display; a dot marks the pointer instead of changing VCMI
	pointer_dot = Node3D.new()
	pointer_dot.visible = false
	add_child(pointer_dot)
	for part in [[0.02, Color(0.05, 0.05, 0.05), 0], [0.013, Color.WHITE, 1]]:
		var sphere := SphereMesh.new()
		sphere.radius = part[0]
		sphere.height = part[0] * 2.0
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = part[1]
		material.no_depth_test = true
		material.render_priority = part[2]
		sphere.material = material
		var dot := MeshInstance3D.new()
		dot.mesh = sphere
		pointer_dot.add_child(dot)


func _process(delta: float) -> void:
	var tracked: Variant = _tracked_head()
	if test_head != null and tracked != null:
		if test_head_start == null:
			test_head_start = tracked
		elif _head_moved(test_head_start, tracked):
			# somebody wears the headset: a simulated head would lock the screen to the real head
			print("VCMI XR: the headset moved, simulated head off")
			_end_test_head()
	if test_head != null and tracked != null:
		origin.transform = test_head * tracked.affine_inverse()
	if screen_stick != Vector2.ZERO:
		var width := screen_width
		if screen_stick.x != 0.0:
			# widening stops at the arc limit; the width is kept when only the distance changes
			width = minf(width + screen_stick.x * SCREEN_SPEED * delta, maxf(screen_width, screen_distance * SCREEN_MAX_ANGLE))
		_size_screen(screen_distance + screen_stick.y * SCREEN_SPEED * delta, width)
	if menu_pressed_at >= 0 and Time.get_ticks_msec() - menu_pressed_at >= MENU_HOLD_MS:
		menu_pressed_at = -1
		_set_environment(ENVIRONMENTS[(ENVIRONMENTS.find(environment_name) + 1) % ENVIRONMENTS.size()])
		_save_screen()
		_pulse(0, 0.25)
	if not screen_placed:
		_place_screen()
	layer.transform = origin.transform.affine_inverse() * screen_world
	# shortcut: the layer's internal hole punch mesh (Godot 4.7.2) carries the occluder, as it already matches the screen; build an own cylinder mesh if Godot changes it
	var hole_punch := layer.get_child(0, true) as MeshInstance3D if layer.get_child_count(true) > 0 else null
	if hole_punch != null and hole_punch.material_override != screen_occluder:
		hole_punch.material_override = screen_occluder
	if surface_pending and layer.get_android_surface() != null:
		surface_pending = false
		if game_started:
			bridge.setSurface(layer.get_android_surface())
		else:
			game_started = true
			bridge.startGame(layer.get_android_surface(), SURFACE_SIZE.x, SURFACE_SIZE.y)

	for ray in rays:
		ray.visible = false
	_update_hotkey_panel()
	if hotkey_hover >= 0 and active_hand == 1:
		pointer_dot.visible = false
		return
	var hit := _pointer_hit(active_hand)
	pointer_dot.visible = hit != NO_HIT
	if hit != NO_HIT:
		_move_pointer(hit)


## Sends the pointer to the game when it moved by a pixel or more
func _move_pointer(hit: Vector2) -> void:
	var pixel := Vector2i(hit * Vector2(SURFACE_SIZE))
	if pixel == last_pointer:
		return
	last_pointer = pixel
	bridge.pointerMove(float(pixel.x), float(pixel.y))


func _head_moved(from: Transform3D, to: Transform3D) -> bool:
	return from.origin.distance_to(to.origin) > 0.15 or rad_to_deg(from.basis.get_rotation_quaternion().angle_to(to.basis.get_rotation_quaternion())) > 15.0


func _end_test_head() -> void:
	test_head = null
	test_head_start = null
	test_aim = null
	origin.transform = Transform3D()
	for model in models:
		model.visible = true
	screen_placed = false


## Head pose in the origin space from the head tracker, or null; not the XRCamera3D node, which moves after this _process
func _tracked_head() -> Variant:
	var head := XRServer.get_tracker("head") as XRPositionalTracker
	var pose := head.get_pose("default") if head != null else null
	if pose == null or not pose.has_tracking_data or pose.transform.origin.is_zero_approx():
		return null
	return pose.get_adjusted_transform()


## `choice` from the settings file may be anything: unknown names fall back to the war room
func _set_environment(choice: Variant) -> void:
	if not choice in ENVIRONMENTS:
		choice = ENVIRONMENTS[0]
	var passthrough: bool = choice == "passthrough"
	var xr := XRServer.find_interface("OpenXR")
	var mode := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND if passthrough else XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	if passthrough and not mode in xr.get_supported_environment_blend_modes():
		print("VCMI XR: passthrough not supported")
		choice = "black" # not the war room: the next long press must still reach black
		passthrough = false
		mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	xr.environment_blend_mode = mode
	# the clear colour shows where nothing is drawn: transparent lets the passthrough through
	get_viewport().transparent_bg = passthrough
	environment.background_mode = Environment.BG_CLEAR_COLOR if passthrough else Environment.BG_COLOR
	room.visible = choice == "war room"
	environment_name = choice
	print("VCMI XR: environment ", choice)


func _build_hotkey_panel() -> void:
	hotkey_panel = Node3D.new()
	hotkey_panel.transform = HOTKEY_PANEL_POSE
	hotkey_panel.visible = false
	grips[0].add_child(hotkey_panel)
	for i in HOTKEYS.size():
		var quad := QuadMesh.new()
		quad.size = HOTKEY_SIZE * 0.92
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		quad.material = material
		var button := MeshInstance3D.new()
		button.mesh = quad
		button.position = _hotkey_centre(i)
		hotkey_panel.add_child(button)
		hotkey_buttons.append(button)
		var label := Label3D.new()
		label.text = HOTKEYS[i][0]
		label.pixel_size = 0.0002
		label.font_size = 40
		label.position.z = 0.001
		button.add_child(label)


## Button `i` centre in the panel: two columns, rows from the top
@warning_ignore("integer_division")
func _hotkey_centre(i: int) -> Vector3:
	var rows := HOTKEYS.size() / 2
	return Vector3((i % 2 - 0.5) * HOTKEY_SIZE.x, ((rows - 1) / 2.0 - i / 2) * HOTKEY_SIZE.y, 0.0)


## Shows the panel when the left controller turns it to the head, and finds the button under the right ray
func _update_hotkey_panel() -> void:
	hotkey_hover = -1
	var tracked: Variant = _tracked_head()
	hotkey_panel.top_level = test_wrist
	if test_wrist and tracked != null:
		hotkey_panel.global_transform = origin.transform * tracked * Transform3D(Basis(), Vector3(0.0, -0.1, -0.35))
		hotkey_panel.visible = true
	else:
		if not test_wrist:
			hotkey_panel.transform = HOTKEY_PANEL_POSE
		# hidden with a simulated head, like the controller models: the real controller may lie in front of the eyes
		hotkey_panel.visible = test_head == null and grips[0].get_has_tracking_data() and tracked != null and 				hotkey_panel.global_basis.z.dot(((origin.transform * tracked).origin - hotkey_panel.global_position).normalized()) > 0.6
	if hotkey_panel.visible:
		var ray := _aim_ray(1)
		if not ray.is_empty():
			var to_panel := hotkey_panel.global_transform.affine_inverse()
			var from: Vector3 = to_panel * ray[0]
			var direction: Vector3 = to_panel.basis * ray[1]
			if direction.z < -0.0001 and from.z > 0.0:
				var hit := from + direction * (-from.z / direction.z)
				for i in HOTKEYS.size():
					var offset := hit - _hotkey_centre(i)
					if absf(offset.x) <= HOTKEY_SIZE.x / 2.0 and absf(offset.y) <= HOTKEY_SIZE.y / 2.0:
						hotkey_hover = i
				if hotkey_hover >= 0:
					_show_ray(1, ray[0], ray[1].normalized(), ray[0].distance_to(hotkey_panel.global_transform * hit))
	for i in hotkey_buttons.size():
		var material: StandardMaterial3D = hotkey_buttons[i].mesh.material
		material.albedo_color = Color(0.85, 0.6, 0.15) if i == hotkey_hover else Color(0.2, 0.15, 0.1)


## Draws the ray of `hand` from `from` along the unit vector `direction` for `length` metres
func _show_ray(hand: int, from: Vector3, direction: Vector3, length: float) -> void:
	rays[hand].visible = true
	rays[hand].global_transform = Transform3D(Basis.looking_at(direction, Vector3.UP), from + direction * length / 2.0)
	rays[hand].scale = Vector3(1.0, 1.0, length)


## Values from the settings file may be of any type or range
func _size_screen(distance: Variant, width: Variant) -> void:
	if typeof(distance) in [TYPE_FLOAT, TYPE_INT]:
		screen_distance = clampf(distance, SCREEN_DISTANCE.x, SCREEN_DISTANCE.y)
	if typeof(width) in [TYPE_FLOAT, TYPE_INT]:
		screen_width = clampf(width, SCREEN_WIDTH.x, SCREEN_WIDTH.y)
	layer.radius = screen_distance
	layer.central_angle = minf(screen_width / screen_distance, SCREEN_MAX_ANGLE)


## Centres the cylinder on the head, facing the head heading (yaw only)
func _place_screen() -> void:
	var tracked: Variant = _tracked_head()
	if tracked == null:
		return
	var head: Transform3D = origin.transform * tracked
	var forward := -head.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	screen_world = Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), head.origin)
	screen_placed = true
	# the room stands on the floor under the head, facing the screen
	room.transform = Transform3D(screen_world.basis, Vector3(head.origin.x, 0.0, head.origin.z))
	print("VCMI XR: screen placed at ", head.origin, " heading ", rad_to_deg(screen_world.basis.get_euler().y))


## World-space origin and direction of the aim ray of `hand`, or an empty array
func _aim_ray(hand: int) -> Array:
	if test_aim != null and hand == active_hand:
		var tracked: Variant = _tracked_head()
		if tracked == null:
			return []
		var from: Vector3 = (origin.transform * tracked).origin
		var turn := Basis.from_euler(Vector3(deg_to_rad(test_aim.y), deg_to_rad(test_aim.x), 0.0))
		return [from, screen_world.basis * turn * Vector3.FORWARD]
	var aim := aims[hand]
	if not aim.get_has_tracking_data():
		return []
	return [aim.global_position, -aim.global_basis.z]


## Layer UV where the aim ray of `hand` hits, or NO_HIT; shows the ray up to the hit
func _pointer_hit(hand: int) -> Vector2:
	var ray := _aim_ray(hand)
	if ray.is_empty():
		return NO_HIT
	# in screen space: the cylinder axis is Y, the screen centre lies at -Z
	# shortcut: own intersection because OpenXRCompositionLayerCylinder.intersects_ray in Godot 4.7.2 takes aspect_ratio as height / width; use it once that is fixed
	var to_screen := screen_world.affine_inverse()
	var from: Vector3 = to_screen * ray[0]
	var direction: Vector3 = (to_screen.basis * ray[1]).normalized()
	var a := direction.x * direction.x + direction.z * direction.z
	var b := 2.0 * (from.x * direction.x + from.z * direction.z)
	var c := from.x * from.x + from.z * from.z - layer.radius * layer.radius
	var discriminant := b * b - 4.0 * a * c
	if a < 0.000001 or discriminant < 0.0:
		return NO_HIT
	var length := (-b + sqrt(discriminant)) / (2.0 * a)
	if length <= 0.0:
		return NO_HIT
	var hit := from + direction * length
	var height := layer.radius * layer.central_angle / layer.aspect_ratio
	var uv := Vector2(0.5 + atan2(hit.x, -hit.z) / layer.central_angle, 0.5 - hit.y / height)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return NO_HIT

	var world_direction: Vector3 = ray[1].normalized()
	_show_ray(hand, ray[0], world_direction, length)
	if hand == active_hand:
		# a little in front of the screen, towards the ray origin
		pointer_dot.global_position = ray[0] + world_direction * (length - 0.02)
	return uv


func _on_button(button_name: String, hand: int, pressed: bool) -> void:
	match button_name:
		"trigger_click": _press(BUTTON_LEFT, hand, pressed)
		"grip_click": _press(BUTTON_RIGHT, hand, pressed)
		"menu_button" when hand == 0:
			# a short press is the game's options button, a long one switches the environment (in _process)
			if pressed:
				menu_pressed_at = Time.get_ticks_msec()
			elif menu_pressed_at >= 0:
				menu_pressed_at = -1
				var keycode: int = PAD_BUTTONS["0:menu_button"]
				bridge.gamepadButton(keycode, true)
				_pulse(hand, 0.25)
				await get_tree().create_timer(0.1).timeout
				bridge.gamepadButton(keycode, false)
		_:
			var keycode: int = PAD_BUTTONS.get("%d:%s" % [hand, button_name], 0)
			if keycode != 0:
				bridge.gamepadButton(keycode, pressed)
				if pressed:
					_pulse(hand, 0.25)


func _on_stick(input_name: String, value: Vector2, hand: int) -> void:
	if input_name != "primary":
		return
	if hand == 1:
		bridge.gamepadAxis(PAD_RIGHT_X, value.x)
		bridge.gamepadAxis(PAD_RIGHT_Y, -value.y)
		return
	# dead zone per axis: a resting stick does not drift, pushing up does not also change the width
	var stick := Vector2(value.x if absf(value.x) > 0.2 else 0.0, value.y if absf(value.y) > 0.2 else 0.0)
	if stick == Vector2.ZERO and screen_stick != Vector2.ZERO:
		_save_screen()
	screen_stick = stick


func _save_screen() -> void:
	var settings := ConfigFile.new()
	settings.set_value("screen", "distance", screen_distance)
	settings.set_value("screen", "width", screen_width)
	settings.set_value("screen", "environment", environment_name)
	settings.save(SETTINGS_PATH)
	print("VCMI XR: screen distance ", screen_distance, " width ", screen_width, " environment ", environment_name)


func _press(button: int, hand: int, pressed: bool) -> void:
	var on_panel := hotkey_hover >= 0 if pressed else hotkey_pressed
	if hand == 1 and button == BUTTON_LEFT and on_panel:
		# a press on the wrist panel sends its key instead of a click on the screen
		hotkey_pressed = pressed
		if pressed:
			active_hand = hand
			var keycode: int = HOTKEYS[hotkey_hover][1]
			print("VCMI XR: hotkey ", HOTKEYS[hotkey_hover][0])
			bridge.key(keycode, true)
			_pulse(hand, 0.25)
			await get_tree().create_timer(0.1).timeout
			bridge.key(keycode, false)
		return
	if pressed:
		active_hand = hand
		var hit := _pointer_hit(hand)
		if hit == NO_HIT:
			return
		_move_pointer(hit)
		_pulse(hand, 0.5)
	bridge.pointerButton(button, pressed)


## A short click on the controller of `hand`; the game's own hapticFeedback() is called for touch input only
func _pulse(hand: int, amplitude: float) -> void:
	# the game's "Haptic feedback" option; read on each pulse, so a change in the game applies at once
	if not bridge.hapticFeedbackEnabled():
		return
	aims[hand].trigger_haptic_pulse("haptic", 0.0, amplitude, 0.03, 0.0)
	print("VCMI XR: haptic pulse ", hand, " ", amplitude)


## head yaw pitch height | head_off | recenter | aim yaw pitch | aim_off | click | rclick | pad keycode | stick x y | lstick x y | screen distance width | env index | lmenu seconds | wrist 1/0 | probe;
## angles in degrees, height in metres, stick values -1..1 with y up, as the right (stick) and left (lstick) thumbstick
func _on_test_command(command: String, a: float, b: float, c: float) -> void:
	match command:
		"head":
			test_head = Transform3D(Basis.from_euler(Vector3(deg_to_rad(b), deg_to_rad(a), 0.0)), Vector3(0.0, c if c > 0.0 else 1.6, 0.0))
			test_head_start = null
			# the real controllers lie next to the real headset; moved with a simulated head they can end up in front of the eyes
			for model in models:
				model.visible = false
		"head_off":
			_end_test_head()
		"recenter":
			screen_placed = false
		"aim":
			test_aim = Vector2(a, b)
		"aim_off":
			test_aim = null
		"click", "rclick":
			var button := BUTTON_LEFT if command == "click" else BUTTON_RIGHT
			_press(button, active_hand, true)
			_press(button, active_hand, false)
		"pad":
			bridge.gamepadButton(int(a), true)
			await get_tree().create_timer(0.1).timeout
			bridge.gamepadButton(int(a), false)
		"stick":
			_on_stick("primary", Vector2(a, b), 1)
		"lstick":
			_on_stick("primary", Vector2(a, b), 0)
		"wrist":
			test_wrist = a != 0.0
		"lmenu":
			_on_button("menu_button", 0, true)
			await get_tree().create_timer(a).timeout
			_on_button("menu_button", 0, false)
		"screen", "env":
			# shortcut: not saved, so a test run keeps the user's choice for the next launch; a later stick release or long menu press saves the test values, reset by hand if that matters
			if command == "screen":
				_size_screen(a, b)
			else:
				_set_environment(ENVIRONMENTS[clampi(int(a), 0, ENVIRONMENTS.size() - 1)])
		"probe", "bridge":
			pass
		_:
			print("VCMI XR test: unknown command ", command)
			return
	# a frame later, so the head offset and the screen placement are applied
	await get_tree().process_frame
	await get_tree().process_frame
	var hit := _pointer_hit(active_hand)
	print("VCMI XR test: ", command, " -> screen ", screen_world.origin, " heading ", rad_to_deg(screen_world.basis.get_euler().y), " distance ", screen_distance, " width ", screen_width, " environment ", environment_name,
			", pointer ", Vector2i(hit * Vector2(SURFACE_SIZE)) if hit != NO_HIT else "off screen",
			", hotkey ", HOTKEYS[hotkey_hover][0] if hotkey_hover >= 0 else "none", ", controllers tracked ", aims.map(func(aim): return aim.get_has_tracking_data()),
			", bridge ", vcmi_data.stats() if vcmi_data else "no extension")

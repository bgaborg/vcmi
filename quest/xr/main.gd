extends Node3D
## Shows the VCMI game activity on a curved layer and passes the controller ray to it as a mouse.
## Test commands from adb (VcmiBridge `test_command`, quest/tools/quest.sh test) simulate the head, the aim and clicks.

## VcmiData.tile_input kinds and the update() flag of a new path (VcmiData's constants, VCMI_TILE_* of the bridge)
enum { TILE_HOVER, TILE_CLICK, TILE_POPUP, TILE_POPUP_END }

## metres from the head, min and max; the cylinder radius, so a nearer screen curves more
const SCREEN_DISTANCE := Vector2(1.0, 4.0)
const SCREEN_WIDTH := Vector2(1.0, 4.0) ## metres of arc, min and max
## radians of arc, about the headset field of view: a near screen does not wrap around the head
const SCREEN_MAX_ANGLE := 2.0
const SCREEN_SPEED := 0.8 ## metres per second at full left thumbstick
const SETTINGS_PATH := "user://screen.cfg"
const SURFACE_SIZE := Vector2i(2560, 1440) ## pixels of the game window
const TableMath := preload("res://table_math.gd")
const TablePanel := preload("res://table_panel.gd")
const END_TURN_KEY := 33 ## KEYCODE_E, as the wrist panel's "End turn (E)"
## a tile on the table in tabletop mode (quest/PHASE4.md decision D3). shortcut: check 3 (ray jitter against tile size)
## needs a person holding a controller; 1.5 cm is a safe guess until it is measured
const TABLE_TILE_METRES := 0.015
const PATH_CHANGED := 16
const TABLE_MAX_TILE_METRES := 0.06 ## the closest zoom: a tile 6 cm wide
const GRAB_MOVE_METRES := 0.015 ## a grip moved this far drags the map; held still...
const GRAB_POPUP_MS := 350 ## ...this long it shows the tile's popup instead
const TABLE_KEEP := 0.6 ## the view follows the selected hero once it leaves the middle 60 % of the table
const BUTTON_LEFT := 1 ## MotionEvent.BUTTON_PRIMARY
const BUTTON_RIGHT := 2 ## MotionEvent.BUTTON_SECONDARY
const NO_HIT := Vector2(-1.0, -1.0)
## controller buttons to the SDL gamepad (KeyEvent.KEYCODE_BUTTON_*); the game binds them in
## config/keyBindingsConfig.json "joystickButtons"
const PAD_BUTTONS := {
	"1:ax_button": 96, # right A -> A: accept
	"1:by_button": 97, # right B -> B: cancel
	"0:ax_button": 102, # left X -> left shoulder: next hero
	"0:by_button": 103, # left Y -> right shoulder: next town
	"0:menu_button": 108, # left menu -> start: options
	"0:primary_click": 106, # left stick click -> left stick: map level
}
## holding the left menu button this long switches the environment instead of opening the game options
const MENU_HOLD_MS := 600
## the wrist panel: label and Android KeyEvent.KEYCODE_*, the game's own keys from config/keyBindingsConfig.json
## "keyboard";
## the labels name the key because other screens bind it to something else (in battle D is defend)
const HOTKEYS := [
	["End turn (E)", 33], ["Spells (C)", 31],
	["Kingdom (K)", 39], ["Quests (Q)", 45],
	["Sleep (Z)", 54], ["Dig (D)", 32],
	["Quick save (F8)", 138], ["Quick load (F9)", 139],
	["Table / screen", -1], ["Next hero (H)", 36], # -1: switches tabletop mode in Godot (also the right stick click)
]
const HOTKEY_SIZE := Vector2(0.08, 0.025) ## metres per button
## above the back of the left controller, tilted towards the eyes like a watch face
const HOTKEY_PANEL_POSE := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-45.0)), Vector3(0.0, 0.05, 0.07))
## the right thumbstick is the gamepad right stick: the game scrolls the map with it ("mouseSwipe")
const PAD_RIGHT_X := 2
const PAD_RIGHT_Y := 3
const SPRITE_PIXELS := 12.0 ## sprites instead of markers from this many pixels per tile on screen (MILESTONE_3B.md 5)
const PIXELS_PER_RADIAN := 1150.0 ## Quest 3: about 2064 eye-buffer pixels over 104 degrees
const ENVIRONMENTS := ["war room", "passthrough", "black"] ## around the screen; a long left menu press goes to the next

var bridge: Object
## game data from the bridge in quest/bridge (quest/DATA_BRIDGE.md); null without the extension
var vcmi_data: RefCounted
var atlas_task := -1 ## the worker of the test command `atlas -1`, waited for before another one and at exit
var map_size := Vector3i.ZERO ## tiles of the map: width, height, levels (from the bridge stats at a new tile snapshot)
var sprite_rect := Rect2i() ## the tiles and level the atlas was last asked for
var sprite_level := -1
## the zoom whose view the atlas could not hold (VcmiData atlas_stats view_overflowed): markers there and further out,
## sprites again once zoomed in past it; 0 when none. shortcut: one value per map, so a sparse area at that zoom shows
## markers too; per area if players see it
var too_far_zoom := 0.0
var sprites_pending := false ## the atlas loads them; update_sprites when it is done
## the map is played on the war table (quest/PHASE4.md milestone 4a); the screen shows dialogs only
var tabletop := false
var table_tile := TableMath.NO_TILE ## the tile under the active ray on the table, sent to the game as a hover
var table_popup := false ## a still grip opened a tile's popup from the table: its release closes it
## grips held on the table by hand: {start: hand position, ms: press time, drag: moving the map}
var grabs := {}
var grab_view := {} ## the view when the current drag or two-hand zoom began: centre, zoom, at, spread
var followed_move := 0 ## the sequence of the last hero step the view followed
## the side panel at the table's near edge (quest/PHASE4.md 4d): resources, date, heroes, towns, end turn
var table_panel: Node3D
var table_icons_tried := false ## SMALRES decoded once, found or not
var shown_selection := Vector3i(-2, -2, -2) ## the selected hero's tile the table last followed and marked
var sprites_held := false ## the test command `sprites` set them: the view does not change them until `table_zoom`
var atlas_refills := 0 ## of the atlas, at the last view: a refill moves the frames, so the sprites wait for the rebuild
var origin: XROrigin3D
var layer: OpenXRCompositionLayerCylinder
var aims: Array[XRController3D] = []
var grips: Array[XRController3D] = [] ## carry the controller models and the hotkey panel
var models: Array[Node3D] = []
var rays: Array[MeshInstance3D] = []
var pointer_dot: Node3D ## where the active ray hits the screen
var active_hand := 1
## screen pose in the world; the layer node is under the origin, which a simulated head moves
var screen_world := Transform3D()
var screen_placed := false
var game_started := false
var surface_pending := true ## the layer creates a new Android surface for each OpenXR session
var last_pointer := Vector2i(-1, -1) ## last pointer position sent to the game, in game pixels
var screen_distance := 2.0
var screen_width := 2.4
var screen_stick := Vector2.ZERO ## left thumbstick: y = distance, x = width
var environment_name: String = ENVIRONMENTS[0]
var room: Node3D
## on the screen: writes depth and leaves the pixels transparent, so the game layer shows through
var screen_occluder: ShaderMaterial
var menu_pressed_at := -1 ## Time.get_ticks_msec() of a left menu press not yet handled, or -1
var environment: Environment ## around the screen when it is not the war room, which has its own
var world: WorldEnvironment
var hotkey_panel: Node3D ## on the left controller, shown when it faces the head; the right ray presses its buttons
var hotkey_buttons: Array[MeshInstance3D] = []
var hotkey_hover := -1 ## HOTKEYS index the right ray points at, or -1
var hotkey_pressed := false ## the right trigger went down on the panel: its release goes there too
var test_wrist := false ## the panel held in front of the head instead of on the controller
var test_head: Variant = null ## Transform3D: simulated head pose in the world, null for the tracked head
var test_head_start: Variant = null ## Transform3D: tracked head when the simulated head was set
## Vector2: simulated aim of the active hand from the head, yaw and pitch in degrees from the screen centre
var test_aim: Variant = null


func _ready() -> void:
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr == null or not xr.is_initialized():
		push_error("VCMI XR: OpenXR is not initialised")
		get_tree().quit()
		return
	get_viewport().use_xr = true
	get_viewport().vrs_mode = Viewport.VRS_XR # the foveation of project.godot, on the Mobile renderer
	xr.pose_recentered.connect(func(): screen_placed = false)
	xr.session_begun.connect(func(): surface_pending = true)
	# the stick and the menu button may not report their release while the system menu has focus
	xr.session_visible.connect(func():
		_on_stick("primary", Vector2.ZERO, 0)
		menu_pressed_at = -1)

	# the controller models have lit glTF materials
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	light.light_cull_mask = 1 # not the room (room.gd LAYER), which has baked light
	add_child(light)
	room = preload("res://room.gd").new()
	add_child(room)
	table_panel = TablePanel.new()
	table_panel.visible = false
	room.add_table_panel(table_panel)
	# Godot's hole punch does not write depth, so the room behind the screen would draw over the game.
	# Multiplying by 0 clears colour and alpha whatever the opaque room drew there; its depth keeps what is behind it
	# out later.
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_always, cull_disabled, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"""
	screen_occluder = ShaderMaterial.new()
	screen_occluder.shader = shader
	screen_occluder.render_priority = -1 # first of the transparent pass, after the opaque room, before the flames
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	world = WorldEnvironment.new()
	world.environment = room.environment
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
		_size_screen(settings.get_value("screen", "distance", screen_distance), settings.get_value("screen", "width",
				screen_width))
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


## the map tile (x, y, level) under the aim ray of `hand` on the table, or Vector3i(-1, -1, -1)
func _table_tile(hand: int) -> Vector3i:
	var ray := _aim_ray(hand)
	if ray.is_empty() or map_size.x == 0:
		return Vector3i(-1, -1, -1)
	return TableMath.uv_to_tile(room.table_uv(ray[0], ray[1]), map_size)


## the 2 texels of frame `index` in a sprite table (VcmiData.sprite_table), for the test command `sprites_check`
func _table_frame(table: Image, index: int) -> Array:
	return [table.get_pixel(2 * index % 512, 2 * index / 512), table.get_pixel((2 * index + 1) % 512,
			(2 * index + 1) / 512)]


## everything the sprites on the table are drawn from, for the preview on the PC (quest/tools/render-room.sh sprites):
## the minimap images, the atlas pages and masks, the frame table and the MultiMesh buffer, as one Variant file
func _save_sprites(path: String) -> void:
	var entry := func(image: Image) -> Array:
		return [image.get_width(), image.get_height(), image.get_format(), image.get_data(),
				image.has_mipmaps()] if image != null else []
	var textures: Array = vcmi_data.atlas_textures()
	var pages := []
	var masks := []
	for layer in (textures[0] as Texture2DArray).get_layers():
		var page: Image = textures[0].get_layer_data(layer)
		page.clear_mipmaps()
		pages.append(entry.call(page))
		var mask: Image = textures[1].get_layer_data(layer)
		mask.clear_mipmaps()
		masks.append(entry.call(mask))
	var multimesh: MultiMesh = room.sprite_multimesh()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_var({"terrain": entry.call(vcmi_data.terrain_image()), "fog": entry.call(vcmi_data.fog_image()),
			"pages": pages,
			"masks": masks, "table": entry.call(vcmi_data.sprite_table()), "count": multimesh.instance_count,
			"buffer": multimesh.buffer, "names": vcmi_data.sprite_names()})
	print("VCMI XR: sprites saved to ", path, ", ", file.get_length(), " bytes")


## Sprites or markers on the minimap by the size of a tile on screen (MILESTONE_3B.md section 5, LOD); the atlas
## follows the tiles the zoomed minimap shows, and the sprites are rebuilt once it has loaded them; between views only
## the changed objects' sprites are updated (plan step 6).
## shortcut: the size is taken at the minimap's centre, from the head's distance
func _update_sprite_view(head: Vector3) -> void:
	if map_size.x == 0:
		return
	var tile_metres: float = room.minimap_size().x / (map_size.x * map_size.z) * room.zoom
	var pixels := tile_metres / maxf(head.distance_to(room.minimap_centre()), 0.1) * PIXELS_PER_RADIAN
	var view: Rect2 = room.visible_uv()
	var level := clampi(int(view.get_center().x * map_size.z), 0, map_size.z - 1)
	# the levels lie side by side: sprites only when the view shows one of them
	var one_level := int(view.position.x * map_size.z) == int((view.end.x - 0.0001) * map_size.z)
	var near: bool = pixels >= SPRITE_PIXELS and one_level and room.zoom > too_far_zoom * 1.05
	if near:
		var x0 := int(floor(view.position.x * map_size.x * map_size.z)) - level * map_size.x
		var y0 := int(floor(view.position.y * map_size.y))
		# 2 tiles more on every side: the view is asked for again only after moving 2 tiles
		var tiles := Rect2i(x0 - 2, y0 - 2, int(ceil(view.size.x * map_size.x * map_size.z)) + 5,
				int(ceil(view.size.y * map_size.y)) + 5)
		tiles = tiles.intersection(Rect2i(0, 0, map_size.x, map_size.y))
		var changes: int = 0 if sprites_pending else vcmi_data.update_sprite_changes(room.sprite_multimesh())
		if changes == 3: # the changed objects use frames the table did not have
			room.set_sprites(vcmi_data.atlas_textures(), vcmi_data.sprite_table(), false)
		# a new request when the changes need it (a new list, a new animation), or the view moved a few tiles or
		# changed its size
		var moved := (tiles.position - sprite_rect.position).length() > 2.0
		if changes < 0 or level != sprite_level or tiles.size != sprite_rect.size or moved:
			vcmi_data.atlas_view(tiles, level)
			sprite_rect = tiles
			sprite_level = level
			sprites_pending = true
		if sprites_pending:
			# a refill (at the request, or when the pages are fragmented while loading) moves the frames the old
			# instances point at: markers until the rebuild
			var refills: int = vcmi_data.atlas_stats().get("refills", 0)
			if refills != atlas_refills:
				atlas_refills = refills
				room.sprite_multimesh().instance_count = 0
		if sprites_pending and not vcmi_data.atlas_busy():
			vcmi_data.update_sprites(room.sprite_multimesh(), sprite_rect, sprite_level)
			room.set_sprites(vcmi_data.atlas_textures(), vcmi_data.sprite_table(), false)
			sprites_pending = false
			if vcmi_data.atlas_stats().get("view_overflowed", false):
				too_far_zoom = room.zoom # some objects would have no sprite: markers until closer
				print("VCMI XR: the atlas cannot hold the view at zoom ", room.zoom, ": markers")
	room.show_sprites(near and (not sprites_pending or room.sprite_multimesh().instance_count > 0))
	vcmi_data.animate_move(room.sprite_multimesh())


func _exit_tree() -> void:
	if atlas_task >= 0:
		WorkerThreadPool.wait_for_task_completion(atlas_task)


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
			width = minf(width + screen_stick.x * SCREEN_SPEED * delta, maxf(screen_width,
					screen_distance * SCREEN_MAX_ANGLE))
		_size_screen(screen_distance + screen_stick.y * SCREEN_SPEED * delta, width)
	if menu_pressed_at >= 0 and Time.get_ticks_msec() - menu_pressed_at >= MENU_HOLD_MS:
		menu_pressed_at = -1
		_set_environment(ENVIRONMENTS[(ENVIRONMENTS.find(environment_name) + 1) % ENVIRONMENTS.size()])
		_save_screen()
		_pulse(0, 0.25)
	if not screen_placed:
		_place_screen()
	layer.transform = origin.transform.affine_inverse() * screen_world
	# shortcut: the layer's internal hole punch mesh (Godot 4.7.2) carries the occluder, as it already matches the
	# screen; build an own cylinder mesh if Godot changes it
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

	if vcmi_data != null:
		var changed: int = vcmi_data.update()
		room.set_minimap(vcmi_data.terrain_image() if changed & 1 else null,
				vcmi_data.fog_image() if changed & 2 else null, changed & 4 != 0)
		if changed & (1 | 8): # the markers are placed by the map size, so new tiles move them too
			vcmi_data.update_markers(room.marker_multimesh(), room.minimap_size(), room.MARKER_METRES)
		if changed & 1:
			map_size = vcmi_data.stats().get("map", Vector3i.ZERO)
			too_far_zoom = 0.0
		if changed & 4 and tracked != null and not sprites_held:
			_update_sprite_view((origin.transform * (tracked as Transform3D)).origin)
		_update_table(changed)
		if changed & 4 == 0 and not layer.visible: # out of the game (main menu, loading): always the screen
			layer.visible = true

	for ray in rays:
		ray.visible = false
	_update_hotkey_panel()
	if hotkey_hover >= 0 and active_hand == 1:
		pointer_dot.visible = false
		table_panel.set_hover(-1)
		return
	if tabletop and not layer.visible:
		_table_pointer()
		return
	table_panel.set_hover(-1)
	var hit := _pointer_hit(active_hand)
	pointer_dot.visible = hit != NO_HIT
	if hit != NO_HIT:
		_move_pointer(hit)


## Tabletop mode on or off (the wrist button, the right stick click, test command `tabletop`): the game keeps its
## tabletop window over the adventure map (milestone 3c), and the table zooms to a playable tile size around the
## selected hero
func _set_tabletop(on: bool) -> void:
	if vcmi_data == null or on == tabletop:
		return
	tabletop = on
	vcmi_data.set_tabletop(on)
	table_tile = TableMath.NO_TILE
	if table_popup: # its grip release would otherwise end up on the screen, or the screen's on the table
		table_popup = false
		vcmi_data.tile_input(Vector3i.ZERO, TILE_POPUP_END)
	grabs.clear()
	grab_view = {}
	shown_selection = Vector3i(-2, -2, -2) # zoom in, follow and mark the selected hero again (_update_table)
	if not on:
		layer.visible = true
	print("VCMI XR: tabletop ", on)


## Each frame in game: the path and the selected hero's mark, the view following it, and the screen only while a
## dialog is open over the tabletop window
func _update_table(changed: int) -> void:
	if map_size.x == 0:
		return
	var selected: Vector3i = vcmi_data.selected_tile()
	if tabletop and shown_selection == Vector3i(-2, -2, -2): # just switched on, or the map was not known then
		room.set_zoom(TableMath.zoom_for(TABLE_TILE_METRES, room.minimap_size().x, map_size), room.zoom_centre)
	if changed & PATH_CHANGED or selected != shown_selection:
		room.set_path(vcmi_data.path_nodes(), selected, map_size)
	if tabletop and selected.x >= 0 and selected != shown_selection:
		var centre := TableMath.follow(room.visible_uv(), TableMath.tile_uv(selected, map_size), TABLE_KEEP)
		room.set_zoom(room.zoom, TableMath.on_level(centre, room.zoom, selected.z, map_size.z))
	shown_selection = selected
	# the hero steps the table shows, enemies' too: the view follows them as the 2D map does, not while a hand holds it
	var move: Vector4i = vcmi_data.move_target()
	if tabletop and move.w != followed_move and grabs.is_empty():
		var target := TableMath.tile_uv(Vector3i(move.x, move.y, move.z), map_size)
		var centre := TableMath.follow(room.visible_uv(), target, TABLE_KEEP)
		room.set_zoom(room.zoom, TableMath.on_level(centre, room.zoom, move.z, map_size.z))
	followed_move = move.w
	table_panel.visible = tabletop and changed & 4 != 0
	if table_panel.visible:
		_update_table_panel()
	if tabletop:
		_update_grabs()
		# also without the tabletop window: at a turn's start the game shows its dialogs (new week, the next player)
		# before the bridge can put the window back, and replays run without it
		var dialog: bool = vcmi_data.windows_above() > 0 or not vcmi_data.tabletop_shown()
		if layer.visible != dialog:
			layer.visible = dialog
			table_tile = TableMath.NO_TILE


## The active ray on the table in tabletop mode: drawn to its hit, and the tile under it sent to the game as a hover
func _table_pointer() -> void:
	var ray := _aim_ray(active_hand)
	var on_panel: Array = table_panel.ray_item(ray[0], ray[1]) if not ray.is_empty() else []
	table_panel.set_hover(on_panel[0] if not on_panel.is_empty() else -1)
	if not on_panel.is_empty():
		_show_ray(active_hand, ray[0], ray[1].normalized(), ray[0].distance_to(on_panel[1]))
		pointer_dot.visible = true
		pointer_dot.global_position = on_panel[1]
		return
	var hit: Vector3 = room.table_hit(ray[0], ray[1]) if not ray.is_empty() else Vector3.INF
	var tile := _table_tile(active_hand) if hit != Vector3.INF else TableMath.NO_TILE
	pointer_dot.visible = tile.x >= 0
	if tile.x < 0:
		table_tile = tile
		return
	var direction: Vector3 = ray[1].normalized()
	_show_ray(active_hand, ray[0], direction, ray[0].distance_to(hit))
	pointer_dot.global_position = hit + Vector3.UP * 0.005
	if tile != table_tile:
		table_tile = tile
		vcmi_data.tile_input(tile, TILE_HOVER)


## Sends the pointer to the game when it moved by a pixel or more
func _move_pointer(hit: Vector2) -> void:
	var pixel := Vector2i(hit * Vector2(SURFACE_SIZE))
	if pixel == last_pointer:
		return
	last_pointer = pixel
	bridge.pointerMove(float(pixel.x), float(pixel.y))


func _head_moved(from: Transform3D, to: Transform3D) -> bool:
	var turned := from.basis.get_rotation_quaternion().angle_to(to.basis.get_rotation_quaternion())
	return from.origin.distance_to(to.origin) > 0.15 or rad_to_deg(turned) > 15.0


func _end_test_head() -> void:
	test_head = null
	test_head_start = null
	test_aim = null
	origin.transform = Transform3D()
	for model in models:
		model.visible = true
	screen_placed = false


## Head pose in the origin space from the head tracker, or null; not the XRCamera3D node, which moves after this
## _process
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
	world.environment = room.environment if room.visible else environment
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
	var rows := (HOTKEYS.size() + 1) / 2
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
		var facing := false
		if tracked != null:
			var to_eyes: Vector3 = ((origin.transform * tracked).origin - hotkey_panel.global_position).normalized()
			facing = hotkey_panel.global_basis.z.dot(to_eyes) > 0.6
		hotkey_panel.visible = test_head == null and grips[0].get_has_tracking_data() and facing
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
	room.set_zoom(room.zoom, room.zoom_centre) # the markers' and sprites' clip follows the moved minimap
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
	if ray.is_empty() or not layer.visible: # hidden in tabletop mode while no dialog is open
		return NO_HIT
	# in screen space: the cylinder axis is Y, the screen centre lies at -Z
	# shortcut: own intersection because OpenXRCompositionLayerCylinder.intersects_ray in Godot 4.7.2 takes aspect_ratio
	# as height / width; use it once that is fixed
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
		"primary_click" when hand == 1:
			if pressed:
				_set_tabletop(not tabletop)
				_pulse(hand, 0.25)
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
			if keycode < 0:
				_set_tabletop(not tabletop)
				_pulse(hand, 0.25)
				return
			bridge.key(keycode, true)
			_pulse(hand, 0.25)
			await get_tree().create_timer(0.1).timeout
			bridge.key(keycode, false)
		return
	if tabletop and (not layer.visible or (button == BUTTON_RIGHT and not pressed and grabs.has(hand))):
		_table_press(button, hand, pressed)
		return
	if pressed:
		active_hand = hand
		var hit := _pointer_hit(hand)
		if hit == NO_HIT:
			return
		_move_pointer(hit)
		_pulse(hand, 0.5)
	bridge.pointerButton(button, pressed)


## Trigger and grip on the table: the trigger clicks the tile under the ray; a grip grabs the table (_update_grabs)
func _table_press(button: int, hand: int, pressed: bool) -> void:
	if button == BUTTON_RIGHT:
		if pressed:
			grabs[hand] = {"start": grips[hand].global_position, "ms": Time.get_ticks_msec(), "drag": false}
			grab_view = {}
		else:
			grabs.erase(hand)
			grab_view = {} # the other hand, if still holding, drags from where it is now
			if table_popup and grabs.is_empty():
				table_popup = false
				vcmi_data.tile_input(Vector3i.ZERO, TILE_POPUP_END)
		return
	if not pressed:
		return
	active_hand = hand
	if await _table_panel_press(hand):
		return
	var tile := _table_tile(hand)
	if tile.x < 0:
		return
	if tile != table_tile: # the other hand's ray, or the first frame: the game hovers before it clicks, as in 2D
		table_tile = tile
		vcmi_data.tile_input(tile, TILE_HOVER)
	vcmi_data.tile_input(tile, TILE_CLICK)
	_pulse(hand, 0.5)


## The side panel's data when the game published new data, and the selection; the resource icons once
func _update_table_panel() -> void:
	var data: Dictionary = vcmi_data.panel()
	if not data.is_empty():
		if not table_icons_tried:
			table_icons_tried = true
			# the 2D map's small resource icons (SMALRES.def), frame by resource id; read once, a few ms
			for frame in vcmi_data.decode_animation("SMALRES").get("frames", []):
				if int(frame["group"]) == 0:
					table_panel.resource_icons.append(ImageTexture.create_from_image(frame["image"]))
		table_panel.set_data(data)
	table_panel.set_selected(vcmi_data.selected_object())


## A trigger on the side panel: selects a hero or town as the 2D lists do (the selected one opens its window), or ends
## the turn; true when the ray of `hand` was on the panel, so the click does not go to the map behind it
func _table_panel_press(hand: int) -> bool:
	var ray := _aim_ray(hand)
	var hit: Array = table_panel.ray_item(ray[0], ray[1]) if not ray.is_empty() else []
	if hit.is_empty():
		return false
	if hit[0] < 0:
		return true
	var item: Dictionary = table_panel.items[hit[0]]
	print("VCMI XR: table panel ", item["kind"], " ", item["id"])
	_pulse(hand, 0.25)
	if item["kind"] == "end_turn":
		bridge.key(END_TURN_KEY, true)
		await get_tree().create_timer(0.1).timeout
		bridge.key(END_TURN_KEY, false)
	else:
		vcmi_data.select_object(item["id"], int(item["id"]) == table_panel.selected)
	return true


## Each frame in tabletop mode, the grips held on the table: one moving hand drags the map with it, two hands zoom
## about their middle (and drag it), a still hand shows the tile's popup under its ray after GRAB_POPUP_MS
func _update_grabs() -> void:
	if grabs.is_empty() or map_size.x == 0:
		return
	var hands: Array = grabs.keys()
	for hand in hands:
		var grab: Dictionary = grabs[hand]
		if not grab["drag"] and grips[hand].global_position.distance_to(grab["start"]) > GRAB_MOVE_METRES:
			grab["drag"] = true
			grab_view = {}
	if hands.size() == 2: # a hand that was the pivot of a zoom opens no popup when the other lets go
		for hand in hands:
			grabs[hand]["drag"] = true
	var points: Array = hands.map(func(hand): return room.panel_point(grips[hand].global_position))
	var dragging: bool = hands.any(func(hand): return grabs[hand]["drag"])
	if hands.size() == 1 and not dragging:
		var hand: int = hands[0]
		if not table_popup and Time.get_ticks_msec() - int(grabs[hand]["ms"]) >= GRAB_POPUP_MS:
			var tile := _table_tile(hand)
			if tile.x >= 0:
				table_popup = true
				vcmi_data.tile_input(tile, TILE_HOVER)
				vcmi_data.tile_input(tile, TILE_POPUP)
				_pulse(hand, 0.5)
		return
	if table_popup:
		return
	var middle: Vector2 = points[0] if points.size() == 1 else (points[0] + points[1]) / 2.0
	var spread: float = 0.0 if points.size() == 1 else (points[0] as Vector2).distance_to(points[1])
	if grab_view.is_empty() or grab_view["hands"] != points.size():
		grab_view = {"centre": room.zoom_centre, "zoom": room.zoom, "at": middle, "spread": spread, "hands": points.size()}
	var zoom: float = grab_view["zoom"]
	if points.size() == 2 and grab_view["spread"] > 0.01:
		var closest := TableMath.zoom_for(TABLE_MAX_TILE_METRES, room.minimap_size().x, map_size)
		zoom = clampf(zoom * spread / grab_view["spread"], float(map_size.z), closest)
	var centre := TableMath.zoom_about(grab_view["centre"], grab_view["zoom"], zoom, grab_view["at"])
	centre = TableMath.drag(centre, grab_view["at"], middle, zoom)
	var level := clampi(int(room.zoom_centre.x * map_size.z), 0, map_size.z - 1)
	room.set_zoom(zoom, TableMath.on_level(centre, zoom, level, map_size.z))


## A short click on the controller of `hand`; the game's own hapticFeedback() is called for touch input only
func _pulse(hand: int, amplitude: float) -> void:
	# the game's "Haptic feedback" option; read on each pulse, so a change in the game applies at once
	if not bridge.hapticFeedbackEnabled():
		return
	aims[hand].trigger_haptic_pulse("haptic", 0.0, amplitude, 0.03, 0.0)
	print("VCMI XR: haptic pulse ", hand, " ", amplitude)


## head yaw pitch height | head_off | recenter | aim yaw pitch | aim_off | click | rclick | pad keycode | stick x y |
## lstick x y | screen distance width | env index | lmenu seconds | wrist 1/0 | gfx feature on | probe | bridge |
## minimap;
## angles in degrees, height in metres, stick values -1..1 with y up, as the right (stick) and left (lstick) thumbstick
# gdlint: disable=max-returns
func _on_test_command(command: String, a: float, b: float, c: float) -> void:
	if command.begins_with("decode:"): # decode:<animation>: its frames through the bridge (PHASE4.md check 6)
		var decoded: Dictionary = vcmi_data.decode_animation(command.substr(7)) if vcmi_data else {}
		var groups := {}
		for frame in decoded.get("frames", []):
			groups[frame["group"]] = groups.get(frame["group"], 0) + 1
		print("VCMI XR: decode ", command.substr(7), ": ", decoded.get("frames", []).size(), " frames, groups ", groups,
				", first ", (decoded["frames"][0]["image"] as Image).get_size() if not decoded.get("frames",
						[]).is_empty() else "none",
				", png ", decoded["frames"][0]["png"] if not decoded.get("frames",
						[]).is_empty() else false, ", ", decoded.get("bridge_us", 0), " us")
		return
	match command:
		# table_view: above the minimap, looking down at it; a the height above the table (default 0.45 m)
		"head", "table_view":
			if command == "head":
				test_head = Transform3D(Basis.from_euler(Vector3(deg_to_rad(b), deg_to_rad(a), 0.0)), Vector3(0.0,
						c if c > 0.0 else 1.6, 0.0))
			else:
				var minimap: Transform3D = room._table * Transform3D(Basis(), Vector3(0.0, room.TABLE_TOP, 0.0))
				var eye := minimap * Vector3(0.0, a if a > 0.0 else 0.45, 0.15)
				test_head = Transform3D(Basis(), eye).looking_at(minimap.origin, Vector3.UP)
			test_head_start = null
			# the real controllers lie next to the real headset; moved with a simulated head they can end up in front of
			# the eyes
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
			# shortcut: not saved, so a test run keeps the user's choice for the next launch; a later stick release or
			# long menu press saves the test values, reset by hand if that matters
			if command == "screen":
				_size_screen(a, b)
			else:
				_set_environment(ENVIRONMENTS[clampi(int(a), 0, ENVIRONMENTS.size() - 1)])
		"gfx": # 10: foveation level b (0 off .. 3 high), 11: dynamic foveation b; else room.gd set_feature
			if int(a) == 10:
				(XRServer.find_interface("OpenXR") as OpenXRInterface).foveation_level = int(b)
			elif int(a) == 11:
				(XRServer.find_interface("OpenXR") as OpenXRInterface).foveation_dynamic = b != 0.0
			else:
				room.set_feature(int(a), b != 0.0)
		"minimap": # saves the bridge images where adb can pull them
			if vcmi_data == null:
				return
			for image in [["terrain", vcmi_data.terrain_image()], ["fog", vcmi_data.fog_image()]]:
				if image[1] != null:
					var path := "/sdcard/Android/data/is.xyz.vcmi.quest/files/minimap-%s.png" % image[0]
					print("VCMI XR: minimap ", image[0], " ", image[1].get_size(), " saved ", image[1].save_png(path))
		# a >= 0: saves the frames of animation a (in full frames, the owner flag in red) where adb can pull them;
		"atlas":
				# a < 0: decodes every animation of the map and prints the times (quest/MILESTONE_3B.md)
			if vcmi_data == null:
				return
			var names: PackedStringArray = vcmi_data.animation_names()
			if a < 0.0:
				# on a worker, as the atlas will be filled: the main thread must keep rendering, or the system closes
				# the app
				if atlas_task >= 0:
					WorkerThreadPool.wait_for_task_completion(atlas_task)
				atlas_task = WorkerThreadPool.add_task(func():
					var totals := {"animations": 0, "frames": 0, "bridge_us": 0, "bake_us": 0, "slowest_us": 0,
							"slowest": "",
							# the first indices of each kind, to pick for `atlas <i>`
							"png": [], "def_flag": [], "png_flag": []}
					var from := Time.get_ticks_usec()
					for i in names.size():
						var decoded: Dictionary = vcmi_data.decode_animation(names[i])
						var spent: int = decoded.get("bridge_us", 0) + decoded.get("bake_us", 0)
						totals.animations += 1
						totals.frames += decoded.frames.size()
						totals.bridge_us += decoded.get("bridge_us", 0)
						totals.bake_us += decoded.get("bake_us", 0)
						for f in decoded.frames:
							var kind := ("png" if f.png else "def") + ("_flag" if f.mask != null else "")
							if totals.has(kind) and totals[kind].size() < 5 and not totals[kind].has(i):
								totals[kind].append(i)
						if spent > totals.slowest_us:
							totals.slowest_us = spent
							totals.slowest = names[i]
						if i % 200 == 199:
							print("VCMI XR: atlas progress ", i + 1, " in ", (Time.get_ticks_usec() - from) / 1000,
									" ms")
					totals.wall_ms = (Time.get_ticks_usec() - from) / 1000
					print("VCMI XR: atlas all ", totals))
			else:
				var i := int(a)
				var dir := "/sdcard/Android/data/is.xyz.vcmi.quest/files/atlas"
				DirAccess.make_dir_recursive_absolute(dir)
				var decoded: Dictionary = vcmi_data.decode_animation(names[i]) if i < names.size() else {"frames": []}
				print("VCMI XR: atlas ", i, " ", names[i] if i < names.size() else "?", ": ", decoded.frames.size(),
						" frames, bridge ", decoded.get("bridge_us", 0), " us, bake ", decoded.get("bake_us", 0), " us")
				for f in decoded.frames:
					var full := Image.create_empty(f.full_size.x, f.full_size.y, false, Image.FORMAT_RGBA8)
					full.fill(Color(0.5, 0.5, 0.5))
					var body: Image = f.image
					full.blend_rect(body, Rect2i(Vector2i.ZERO, body.get_size()), Vector2i(f.left, f.top))
					var flag: Image = f.mask
					if flag != null:
						for y in flag.get_height():
							for x in flag.get_width():
								if flag.get_pixel(x, y).r > 0.5:
									full.set_pixel(x + f.left, y + f.top, Color.RED)
					full.save_png("%s/%d_%d_%d.png" % [dir, i, f.group, f.frame])
		# the sprite atlas for a view (quest/MILESTONE_3B.md, plan step 3): a, b the top-left tile (a < 0: the
		"atlas-view":
				# map's centre), c the size in tiles (default 30), level 0; waits until loaded, prints the stats, saves
				# page 0
			if vcmi_data == null:
				return
			var size := int(c) if c > 0.0 else 30
			var map: Vector3i = vcmi_data.stats().get("map", Vector3i.ZERO)
			var at := Vector2i(int(a), int(b)) if a >= 0.0 else Vector2i(map.x / 2 - size / 2, map.y / 2 - size / 2)
			sprites_held = true # as `sprites`: the view's sprites wait until `table_zoom`
			var wanted: int = vcmi_data.atlas_view(Rect2i(at, Vector2i(size, size)), 0)
			var from := Time.get_ticks_msec()
			while vcmi_data.atlas_busy() and Time.get_ticks_msec() - from < 20000:
				await get_tree().process_frame
			print("VCMI XR: atlas view ", at, " size ", size, ": ", wanted, " animations, ", vcmi_data.atlas_stats())
			# the first 16 pages side by side, 4 x 4
			var sheet := Image.create_empty(4 * 512, 4 * 512, false, Image.FORMAT_RGBA8)
			for layer in 16:
				var page: Image = vcmi_data.atlas_page(layer)
				if page != null:
					sheet.blit_rect(page, Rect2i(Vector2i.ZERO, page.get_size()), Vector2i(layer % 4, layer / 4) * 512)
			sheet.save_png("/sdcard/Android/data/is.xyz.vcmi.quest/files/atlas-pages.png")
		# the object sprites on the minimap (quest/MILESTONE_3B.md, plan step 4): a, b the top-left tile, c the
		"sprites":
				# size in tiles (default: the whole map), level 0; loads the atlas, waits, fills the sprites, checks
				# precision
			if vcmi_data == null:
				return
			var map: Vector3i = vcmi_data.stats().get("map", Vector3i.ZERO)
			var tiles := Rect2i(int(a), int(b), int(c), int(c)) if c > 0.0 else Rect2i(0, 0, map.x, map.y)
			sprites_held = true # the view's sprites must not ask the atlas for their own view meanwhile
			var wanted: int = vcmi_data.atlas_view(tiles, 0)
			var from := Time.get_ticks_msec()
			while vcmi_data.atlas_busy() and Time.get_ticks_msec() - from < 20000:
				await get_tree().process_frame
			var started := Time.get_ticks_usec()
			var count: int = vcmi_data.update_sprites(room.sprite_multimesh(), tiles, 0, true)
			var fill_us := Time.get_ticks_usec() - started
			room.set_sprites(vcmi_data.atlas_textures(), vcmi_data.sprite_table(), true)
			room.show_sprites(true)
			print("VCMI XR: sprites ", tiles, ": ", wanted, " animations, ", count, " instances in ", fill_us, " us, ",
					vcmi_data.atlas_stats())
			_save_sprites("/sdcard/Android/data/is.xyz.vcmi.quest/files/sprites.bin")
		"sprites_check": # plan step 6: the view's sprites after its change updates match a whole update_sprites of it
			var shown: bool = room.sprite_multimesh().instance_count > 0
			if vcmi_data == null or vcmi_data.sprite_table() == null or sprites_held or sprites_pending or not shown:
				print("VCMI XR: sprites check skipped: no view's sprites, or they are held or loading")
			else:
				var mm: MultiMesh = room.sprite_multimesh()
				var kept: PackedFloat32Array = mm.buffer
				var kept_table: Image = vcmi_data.sprite_table()
				var stats: Dictionary = vcmi_data.atlas_stats()
				vcmi_data.update_sprites(mm, sprite_rect, sprite_level)
				var now: PackedFloat32Array = mm.buffer
				var differ := -1 if kept.size() == now.size() else 0
				for i in kept.size() if differ < 0 else 0:
					# the first frame indexes each table, which the changes extend in their own order: compare the frames
					var same := kept[i] == now[i] if i % 20 != 16 \
							else _table_frame(kept_table, int(kept[i])) == _table_frame(vcmi_data.sprite_table(),
									int(now[i]))
					if not same:
						differ = i / 20
						break
				room.set_sprites(vcmi_data.atlas_textures(), vcmi_data.sprite_table(), false)
				print("VCMI XR: sprites check ", "same" if differ < 0 else "DIFFERENT at instance %d" % differ, ", ",
						kept.size() / 20,
						" -> ", now.size() / 20, " instances, ", stats)
		# a 1: the game shows the map on the tabletop only (milestone 3c): the 2D map stops, hero steps wait for the
		# table; 0: back
		"tabletop":
			_set_tabletop(a > 0.0)
		# a, b the tile of level 0, c the kind (0 hover, 1 click, 2 popup, 3 popup end): through the bridge (PHASE4.md)
		"tile":
			if vcmi_data:
				vcmi_data.tile_input(Vector3i(int(a), int(b), 0), int(c))
		# for a seconds (default 5): the tile under the active hand's ray on the table each frame (PHASE4.md
		"table_pick":
				# check 3): how often it changes with the controller held still
			var tiles := {}
			var changes := 0
			var misses := 0
			var frames := 0
			var last := Vector3i(-2, -2, -2)
			var start := Time.get_ticks_msec()
			while Time.get_ticks_msec() - start < int((a if a > 0.0 else 5.0) * 1000.0):
				await get_tree().process_frame
				var tile := _table_tile(active_hand)
				frames += 1
				if tile.x < 0:
					misses += 1
				else:
					tiles[tile] = tiles.get(tile, 0) + 1
				if tile != last and last.x > -2:
					changes += 1
				last = tile
			var metres: float = room.minimap_size().x / (map_size.x * map_size.z) * room.zoom if map_size.x > 0 else 0.0
			print("VCMI XR: table pick ", frames, " frames, ", misses, " off the table, ", changes, " changes, tiles ",
					tiles,
					", tile ", snappedf(metres * 100.0, 0.01), " cm at zoom ", room.zoom)
		"heroes": # prints the heroes on the map
			print("VCMI XR: heroes ", vcmi_data.heroes() if vcmi_data else [])
		"screen_hide": # a 1: the game screen layer hidden (PHASE4.md check 4); 0: shown
			layer.visible = a <= 0.0
		"move_trace": # for a frames (default 120): the sprites whose place changed since the last frame, in tiles, with
				# the time; a hero step of the tabletop shows as a few small moves of the same instance
			var mm: MultiMesh = room.sprite_multimesh()
			var last: PackedFloat32Array = mm.buffer
			var start := Time.get_ticks_msec()
			for frame in int(a) if a > 0.0 else 120:
				await get_tree().process_frame
				var now: PackedFloat32Array = mm.buffer
				if now.size() == last.size():
					for i in now.size() / 20:
						if now[i * 20 + 3] != last[i * 20 + 3] or now[i * 20 + 11] != last[i * 20 + 11]:
							var x := (now[i * 20 + 3] + 0.5) * map_size.x * map_size.z
							var y := (now[i * 20 + 11] + 0.5) * map_size.y
							print("VCMI XR: move trace %d ms instance %d at %.2f, %.2f tiles" % [
									Time.get_ticks_msec() - start, i, x, y])
				last = now
		# moves the view by a, b of the map's UV, as a hand drag does (TableMath.drag), on the view's level
		"table_pan":
			var level := clampi(int(room.zoom_centre.x * map_size.z), 0, maxi(map_size.z - 1, 0))
			var panned := TableMath.drag(room.zoom_centre, Vector2.ZERO, -Vector2(a, b) * room.zoom, room.zoom)
			room.set_zoom(room.zoom, TableMath.on_level(panned, room.zoom, level, maxi(map_size.z, 1)))
		# the minimap shows 1 / a of the map around b, c (minimap UV, both levels side by side; 0: the centre)
		"table_zoom":
			room.set_zoom(a if a > 0.0 else 1.0, Vector2(b if b > 0.0 else 0.5, c if c > 0.0 else 0.5))
			sprites_held = false
			sprite_level = -1 # the view's own sprites again, instead of the test command's
		"probe", "bridge":
			pass
		_:
			print("VCMI XR test: unknown command ", command)
			return
	# a frame later, so the head offset and the screen placement are applied
	await get_tree().process_frame
	await get_tree().process_frame
	var hit := _pointer_hit(active_hand)
	print("VCMI XR test: ", command, " -> screen ", screen_world.origin, " heading ",
			rad_to_deg(screen_world.basis.get_euler().y), " distance ", screen_distance, " width ", screen_width,
			" environment ", environment_name,
			", pointer ", Vector2i(hit * Vector2(SURFACE_SIZE)) if hit != NO_HIT else "off screen",
			", hotkey ", HOTKEYS[hotkey_hover][0] if hotkey_hover >= 0 else "none",
			", controllers tracked ", aims.map(func(aim): return aim.get_has_tracking_data()),
			", bridge ", vcmi_data.stats() if vcmi_data else "no extension")
# gdlint: enable=max-returns

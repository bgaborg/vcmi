extends Node3D
## Offline preview of the war room (room.gd) without a headset: renders a few views to PNG and quits.
## Run with quest/tools/render-room.sh. Not exported (export_presets.cfg excludes preview/*).
## As in the headset, the game is a layer behind the eye buffer: the room is rendered with a transparent background
## and the screen occluder of main.gd, then laid over the game picture by its alpha.

const OUT := "res://../out/room-preview" ## quest/out/room-preview
## stand-in for the game layer: a headset screenshot cropped inside the (curved) game screen, so no wall shows;
## quest/out is not in git, so without it the screen is flat dark grey
const SHOT := "res://../out/perf-20261106-194305-auto/debug-zoom2.jpg"
const SHOT_RECT := Rect2i(125, 345, 1160, 535)
## the minimap on the war table: the terrain image the headset saved with the test command `minimap` (main.gd), when present
const MINIMAP := "res://../out/minimap-debug/minimap-%s.png"
## the sprites on the table as the headset drew them: the file the test command `sprites` saves (main.gd _save_sprites),
## pulled by `render-room.sh sprites`; with `-- sprites` only the views of the table are rendered
const SPRITES := "res://../out/sprites-dump/sprites.bin"
var ZOOM_TILE := Vector2(19.0, 13.0) ## the tile the view `sprites-zoom` looks at; `-- sprites zoom=x,y` sets it
const SIZE := Vector2i(1920, 1080)
const HEAD := Vector3(0.0, 1.6, 0.0)
const SEATED := Vector3(0.0, 1.2, 0.0)
const SCREEN_DISTANCE := 2.0 ## main.gd defaults
const SCREEN_WIDTH := 2.4
const ASPECT := 2560.0 / 1440.0
const SETTLE_FRAMES := 30 ## the reflection probe renders over a few frames
const SCREEN_LAYER := 4 ## render layer bit of the game picture, seen only by the layer camera
## as main.gd's screen_occluder
const OCCLUDER := "shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_always, cull_disabled, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"

## name: [camera position, point looked at]
var views := {
	"head": [HEAD, HEAD + Vector3.FORWARD],
	"left": [HEAD, HEAD + Vector3.LEFT],
	"right": [HEAD, HEAD + Vector3.RIGHT],
	"back": [HEAD, HEAD + Vector3.BACK],
	"seated": [SEATED, SEATED + Vector3.FORWARD],
	"table": [HEAD, HEAD + Vector3(1.0, -0.6, -0.15)],
	"overview": [Vector3(5.5, 4.2, 3.7), Vector3(0.0, 1.4, -3.0)],
}


func _ready() -> void:
	# as main.gd: the light for the controllers, the room, the environment
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	light.light_cull_mask = 1
	add_child(light)
	var room: Node3D = preload("res://room.gd").new()
	add_child(room)
	var world := WorldEnvironment.new()
	world.environment = room.environment
	add_child(world)
	_check_clear(room)
	if FileAccess.file_exists(MINIMAP % "terrain"):
		var terrain := Image.load_from_file(ProjectSettings.globalize_path(MINIMAP % "terrain"))
		var fog := Image.create(terrain.get_height(), terrain.get_width(), false, Image.FORMAT_L8)
		fog.fill(Color8(1, 1, 1)) # all visible, to check the terrain
		room.set_minimap(terrain, fog, true)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("table_zoom="): # table_zoom=factor,u,v: the minimap's own zoom (room.set_zoom)
			var v := arg.get_slice("=", 1).split(",")
			room.set_zoom(float(v[0]), Vector2(float(v[1]), float(v[2])))
		if arg.begins_with("zoom="):
			ZOOM_TILE = Vector2(float(arg.get_slice("=", 1).get_slice(",", 0)), float(arg.get_slice("=", 1).get_slice(",", 1)))
	if FileAccess.file_exists(SPRITES):
		_load_sprites(room)
	if "sprites" in OS.get_cmdline_user_args():
		for view in views.keys():
			if not view.begins_with("sprites"):
				views.erase(view)

	var eye := _viewport(true)
	var eye_camera := _camera(eye, 0xFFFFF & ~SCREEN_LAYER)
	var layer := _viewport(false)
	var layer_camera := _camera(layer, SCREEN_LAYER)
	layer_camera.environment = Environment.new() # the game layer is not tonemapped
	_add_screen()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for view: String in views:
		for camera in [eye_camera, layer_camera]:
			camera.look_at_from_position(views[view][0], views[view][1])
		for i in SETTLE_FRAMES:
			await RenderingServer.frame_post_draw
		if view == "head":
			for info in [["draw calls", Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME], ["primitives", Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME], ["objects", Viewport.RENDER_INFO_OBJECTS_IN_FRAME]]:
				print("room preview: head view ", info[0], " ", eye.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, info[1]))
		var picture := layer.get_texture().get_image()
		picture.convert(Image.FORMAT_RGBA8)
		var room_image := eye.get_texture().get_image()
		room_image.convert(Image.FORMAT_RGBA8)
		picture.blend_rect(room_image, Rect2i(Vector2i.ZERO, SIZE), Vector2i.ZERO)
		var path := ProjectSettings.globalize_path(OUT.path_join(view + ".png")).simplify_path()
		var error := picture.save_png(path)
		print("room preview: ", path, " ", error_string(error))
	get_tree().quit()


## the headset's sprite data (main.gd _save_sprites) into the room, and views from above the minimap, as the test
## command `table_view` (0.45 and 0.25 m above it)
func _load_sprites(room: Node3D) -> void:
	var data: Dictionary = FileAccess.open(SPRITES, FileAccess.READ).get_var()
	var image := func(entry: Array) -> Image:
		if entry.is_empty():
			return null
		# files saved before the mipmap flag: mipmaps when the data is larger than the base level
		var mipmaps: bool = entry[4] if entry.size() > 4 else entry[3].size() > Image.create_empty(entry[0], entry[1], false, entry[2]).get_data().size()
		return Image.create_from_data(entry[0], entry[1], mipmaps, entry[2], entry[3])
	room.set_minimap(image.call(data.terrain), image.call(data.fog), true)
	var layers := []
	for key in ["pages", "masks"]:
		var images: Array[Image] = []
		for entry in data[key]:
			var layer: Image = image.call(entry)
			layer.generate_mipmaps()
			images.append(layer)
		var texture := Texture2DArray.new()
		texture.create_from_images(images)
		layers.append(texture)
	var multimesh: MultiMesh = room.sprite_multimesh()
	multimesh.instance_count = data.count
	multimesh.buffer = data.buffer
	room.set_sprites(layers, image.call(data.table), true)
	room.show_sprites(true)
	var minimap: Transform3D = room._table * Transform3D(Basis(), Vector3(0.0, room.TABLE_TOP, 0.0))
	views["sprites"] = [minimap * Vector3(0.0, 0.45, 0.15), minimap.origin]
	views["sprites-close"] = [minimap * Vector3(0.0, 0.25, 0.08), minimap.origin]
	# close over one area of level 0, for a look next to the game's own view of it (the first scenario's start)
	var terrain: Image = image.call(data.terrain)
	var panel: Vector2 = room.minimap_size()
	var map_size := Vector2(terrain.get_width(), terrain.get_height()) # the levels side by side
	var at := Vector3((ZOOM_TILE.x / map_size.x - 0.5) * panel.x, 0.0, (ZOOM_TILE.y / map_size.y - 0.5) * panel.y)
	views["sprites-zoom"] = [minimap * (at + Vector3(0.0, 0.13, 0.04)), minimap * at]
	print("room preview: sprites ", data.count, " instances, ", layers[0].get_layers(), " pages")
	# with `-- sprites <name part>`: the frames the table gives the first instance of that animation, cut from the pages
	var args := OS.get_cmdline_user_args()
	var wanted := args[args.find("sprites") + 1] if args.find("sprites") >= 0 and args.size() > args.find("sprites") + 1 and not args[args.find("sprites") + 1].begins_with("zoom=") else ""
	var names: PackedStringArray = data.get("names", PackedStringArray())
	if wanted == "near": # frame 0 of every instance near the zoom tile
		var table: Image = image.call(data.table)
		for i in names.size():
			var anchor := names[i].get_slice(" ", 1).split(",")
			if absf(float(anchor[0]) - ZOOM_TILE.x) <= 4.0 and absf(float(anchor[1]) - ZOOM_TILE.y) <= 6.0:
				var first := int(data.buffer[i * 20 + 16] + 0.5)
				var a := table.get_pixel((2 * first) % 512, (2 * first) / 512)
				var b := table.get_pixel((2 * first + 1) % 512, (2 * first + 1) / 512)
				var page: Image = image.call(data.pages[int(a.r)])
				page.get_region(Rect2i(int(a.g), int(a.b), maxi(int(a.a), 1), maxi(int(b.r), 1))).save_png(ProjectSettings.globalize_path(OUT.path_join("near-%d-%s.png" % [i, names[i].get_slice(" ", 0).get_file()])))
	for i in names.size():
		if wanted != "" and wanted != "near" and wanted in names[i]:
			var table: Image = image.call(data.table)
			var first := int(data.buffer[i * 20 + 16] + 0.5)
			var count := int(data.buffer[i * 20 + 17] + 0.5) % 1024
			for f in count:
				var a := table.get_pixel((2 * (first + f)) % 512, (2 * (first + f)) / 512)
				var b := table.get_pixel((2 * (first + f) + 1) % 512, (2 * (first + f) + 1) / 512)
				print("room preview: ", names[i], " frame ", f, ": page ", a.r, " at ", Vector2(a.g, a.b), " size ", Vector2(a.a, b.r), " offset ", Vector2(b.g, b.b))
				var page: Image = image.call(data.pages[int(a.r)])
				page.get_region(Rect2i(int(a.g), int(a.b), int(a.a), int(b.r))).save_png(ProjectSettings.globalize_path(OUT.path_join("frame-%d.png" % f)))
			# and only that instance on the table
			multimesh.instance_count = 1
			multimesh.buffer = (data.buffer as PackedFloat32Array).slice(i * 20, i * 20 + 20)
			break
	# what is drawn near the zoom tile, by anchor: animation, anchor, group
	for name: String in data.get("names", PackedStringArray()):
		var anchor := name.get_slice(" ", 1).split(",")
		if absf(float(anchor[0]) - ZOOM_TILE.x) <= 4.0 and absf(float(anchor[1]) - ZOOM_TILE.y) <= 4.0:
			print("room preview: near the zoom tile: ", name)


func _viewport(transparent: bool) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = transparent
	viewport.use_debanding = ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_debanding")
	add_child(viewport)
	return viewport


func _camera(viewport: SubViewport, mask: int) -> Camera3D:
	var camera := Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_WIDTH # fov is horizontal, as the Quest's ~100 degrees
	camera.fov = 100.0
	camera.cull_mask = mask
	viewport.add_child(camera)
	return camera


## The game layer as main.gd sizes it: a cylinder around the head, radius = distance, arc = width; drawn once as the
## picture for the layer camera, once with the occluder for the room camera, as main.gd puts it on the hole punch.
func _add_screen() -> void:
	var picture: Image
	if FileAccess.file_exists(ProjectSettings.globalize_path(SHOT)):
		picture = Image.load_from_file(ProjectSettings.globalize_path(SHOT)).get_region(SHOT_RECT)
	else:
		picture = Image.create_empty(SHOT_RECT.size.x, SHOT_RECT.size.y, false, Image.FORMAT_RGB8)
		picture.fill(Color(0.15, 0.15, 0.15))
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = ImageTexture.create_from_image(picture)
	var angle := SCREEN_WIDTH / SCREEN_DISTANCE
	var height := SCREEN_WIDTH / ASPECT
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in 33:
		var u := i / 32.0
		var a := (u - 0.5) * angle
		for v in [0.0, 1.0]:
			surface.set_uv(Vector2(u, v))
			surface.add_vertex(HEAD + Vector3(sin(a) * SCREEN_DISTANCE, (0.5 - v) * height, -cos(a) * SCREEN_DISTANCE))
	var mesh := surface.commit()
	var screen := MeshInstance3D.new()
	screen.mesh = mesh
	screen.material_override = material
	screen.layers = SCREEN_LAYER
	add_child(screen)
	var occluder := ShaderMaterial.new()
	occluder.shader = Shader.new()
	occluder.shader.code = OCCLUDER
	occluder.render_priority = -1
	var hole := MeshInstance3D.new()
	hole.mesh = mesh
	hole.material_override = occluder
	add_child(hole)


## Warns about room geometry that could stand in front of the game screen at any size main.gd allows, seen from the
## standing and the seated head. The screen is a cylinder around the head: radius r 1-4 m, arc min(width / r, 2) rad for
## a width of 1-4 m, 16:9, so an arc A covers A / 2 to each side and A / (2 * 16:9) up and down (as tangents of the
## elevation). A point at distance d is in front of it when r > d; the widest arc then is at the nearest radius,
## A = min(4 / max(d, 1), 2). Samples each triangle on a grid of about 10 cm.
func _check_clear(room: Node3D) -> void:
	# self-check: straight ahead is covered, the floor below it and the side walls are not; the old shaft edge was
	assert(_in_front_of_screen(Vector3(0.0, 0.0, -2.0)) and _in_front_of_screen(Vector3(1.79, 0.41 - 1.2, -2.42)))
	assert(not _in_front_of_screen(Vector3(0.0, -1.6, -2.0)) and not _in_front_of_screen(Vector3(-6.0, 0.0, -1.0)))
	for node in room.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if instance.mesh == null:
			continue
		var faces := instance.mesh.get_faces()
		var xform := room.global_transform.affine_inverse() * instance.global_transform
		for head in [HEAD, SEATED]:
			for t in range(0, faces.size(), 3):
				var a: Vector3 = xform * faces[t]
				var b: Vector3 = xform * faces[t + 1]
				var c: Vector3 = xform * faces[t + 2]
				var n := clampi(ceili(maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a))) / 0.1), 1, 100)
				var hit: Variant = null
				for i in n + 1:
					for j in n + 1 - i:
						var p := a + (b - a) * (i / float(n)) + (c - a) * (j / float(n))
						if hit == null and _in_front_of_screen(p - head):
							hit = p
				if hit != null:
					print("room preview: WARNING ", room.get_path_to(instance), " may cover the screen at ", hit, " seen from ", head.y, " m")
					break


func _in_front_of_screen(p: Vector3) -> bool:
	var d := Vector2(p.x, p.z).length()
	if d >= 4.0 or d < 0.001:
		return false
	var arc := minf(4.0 / maxf(d, 1.0), 2.0)
	return absf(atan2(p.x, -p.z)) < arc / 2.0 and absf(p.y) / d < arc / (2.0 * ASPECT)

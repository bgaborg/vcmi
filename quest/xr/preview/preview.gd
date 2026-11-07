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

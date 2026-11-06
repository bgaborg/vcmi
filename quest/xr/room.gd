extends Node3D
## A low-poly war room around the game screen, built from primitives (no assets to license or download).
## Room space: the floor at y 0 under the head, the screen towards -Z; the screen can be up to 4 m away.

const SIZE := Vector3(12.0, 5.0, 10.0) ## width, height, depth in metres
const BACK := -6.0 ## z of the wall behind the screen
const STONE := Color(0.27, 0.23, 0.2)
const WALL := Color(0.33, 0.28, 0.23)
const BACK_WALL := Color(0.16, 0.13, 0.11) ## darker behind the screen, so the game stands out
const WOOD := Color(0.24, 0.15, 0.09)
const FLAME := Color(1.0, 0.55, 0.2)


func _ready() -> void:
	var front := BACK + SIZE.z
	var middle := (BACK + front) / 2.0
	_box(Vector3(SIZE.x, 0.1, SIZE.z), Vector3(0.0, -0.05, middle), STONE) # floor
	_box(Vector3(SIZE.x, 0.1, SIZE.z), Vector3(0.0, SIZE.y + 0.05, middle), WOOD) # ceiling
	_box(Vector3(SIZE.x, SIZE.y, 0.2), Vector3(0.0, SIZE.y / 2.0, BACK - 0.1), BACK_WALL)
	_box(Vector3(SIZE.x, SIZE.y, 0.2), Vector3(0.0, SIZE.y / 2.0, front + 0.1), WALL)
	for side in [-1.0, 1.0]:
		_box(Vector3(0.2, SIZE.y, SIZE.z), Vector3(side * (SIZE.x / 2.0 + 0.1), SIZE.y / 2.0, middle), WALL)
		# ceiling beams across the room
		_box(Vector3(SIZE.x, 0.25, 0.3), Vector3(0.0, SIZE.y - 0.12, middle + side * 2.5), WOOD)
		# banners on the back wall, beside a 4 m wide screen
		_box(Vector3(1.0, 2.4, 0.04), Vector3(side * 3.6, 2.9, BACK + 0.05), Color(0.45, 0.06, 0.05) if side < 0.0 else Color(0.08, 0.12, 0.4))
		# torches on the side walls, with the light they cast
		var torch := Vector3(side * (SIZE.x / 2.0 - 0.15), 2.4, BACK + 2.5)
		_box(Vector3(0.08, 0.35, 0.08), torch + Vector3(0.0, -0.2, 0.0), WOOD)
		_box(Vector3(0.12, 0.14, 0.12), torch, FLAME, true)
		var light := OmniLight3D.new()
		light.light_color = FLAME
		light.light_energy = 2.0
		light.omni_range = 8.0
		light.position = torch + Vector3(-side * 0.3, 0.1, 0.0)
		add_child(light)
	# a rug in front of the user: flat, so it never covers the screen
	_box(Vector3(3.0, 0.01, 4.0), Vector3(0.0, 0.005, -1.5), Color(0.35, 0.1, 0.08))


func _box(size: Vector3, position_: Vector3, color: Color, glowing := false) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	# drawn after the screen occluder (main.gd), which only the transparent pass can order before it
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	if glowing:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = material
	var box := MeshInstance3D.new()
	box.mesh = mesh
	box.position = position_
	add_child(box)

extends RefCounted
## The map objects that fade in or out on the war table, as the 2D map fades them (quest/PHASE4.md, "Fades"): an alpha
## per object id in a small texture that the sprite shader reads by the id each instance already carries
## (table_shaders.gd SPRITE, `fades`). No instance data changes, so a fade costs no sprite rebuild: only this texture
## is uploaded, and only in the frames while something fades. Tested by tests/map_fades_test.gd.

const SIDE := 256 ## texels a side: object ids up to 65 535 (the heaviest map has 64 743 objects)
const SECONDS := 0.5 ## a fade's length, about the 2D map's (MapViewController, fadingTime)

var texture := ImageTexture.new()
var _image := Image.create(SIDE, SIDE, false, Image.FORMAT_L8)
var _fading := {} ## id: {from (alpha), to, time (seconds since its start)}
var _changed := false
var _hidden := {} ## ids that faded out and whose sprites are still drawn (until forget): the texture must stay read


func _init() -> void:
	_image.fill(Color.WHITE) # everything shows
	texture.set_image(_image)


## Object `id` appears: from clear to whole; one that was fading out comes back from where it is
func fade_in(id: int) -> void:
	_start(id, alpha(id) if _fading.has(id) else 0.0, 1.0)


## Object `id` is gone: from whole to clear; `advance` returns it when it is clear, so its sprites can go
func fade_out(id: int) -> void:
	_start(id, alpha(id), 0.0)


## Shown at once again (a new map, a test): every object whole
func reset() -> void:
	_fading.clear()
	_hidden.clear()
	_image.fill(Color.WHITE)
	texture.update(_image)
	_changed = false


func alpha(id: int) -> float:
	return _image.get_pixel(id % SIDE, id / SIDE).r if id >= 0 and id < SIDE * SIDE else 1.0


func active() -> bool:
	return not _fading.is_empty()


## The shader must read the texture: something fades, or a faded-out object's sprites are still there
func needed() -> bool:
	return active() or not _hidden.is_empty()


## Object `id`'s sprites are gone (or it came back whole): its texel no longer matters
func forget(id: int) -> void:
	_hidden.erase(id)
	if id >= 0 and id < SIDE * SIDE:
		_write(id, 1.0)


## Each frame: the fades go on; returns the ids whose fade out ended
func advance(delta: float) -> PackedInt32Array:
	var gone := PackedInt32Array()
	for id: int in _fading.keys():
		var fade: Dictionary = _fading[id]
		fade["time"] += delta
		var along := clampf(fade["time"] / SECONDS, 0.0, 1.0)
		_write(id, lerpf(fade["from"], fade["to"], along))
		if along >= 1.0:
			_fading.erase(id)
			if fade["to"] == 0.0:
				gone.append(id)
				_hidden[id] = true
	if _changed:
		texture.update(_image) # 64 KB, in the frames while something fades
		_changed = false
	return gone


## The table's sprites (room.gd sprite_multimesh: both passes of its material) read this texture while `on`
func apply(sprites: MultiMesh, on: bool) -> void:
	var material: ShaderMaterial = sprites.mesh.material
	for shader_pass: ShaderMaterial in [material, material.next_pass]:
		shader_pass.set_shader_parameter("fades", texture)
		shader_pass.set_shader_parameter("fading", on)


func _start(id: int, from: float, to: float) -> void:
	if id < 0 or id >= SIDE * SIDE:
		return
	_hidden.erase(id)
	_fading[id] = {"from": from, "to": to, "time": 0.0}
	_write(id, from)


func _write(id: int, value: float) -> void:
	@warning_ignore("integer_division")
	_image.set_pixel(id % SIDE, id / SIDE, Color(value, value, value))
	_changed = true

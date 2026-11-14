extends Node3D
## The battle on the war table (phase 5, quest/PHASE5.md): the battlefield over the book's page, its hexes as inked
## lines, the hexes' states as washes of colour, and a card for each stack. A child of the map's panel (room.gd
## add_table_panel): x right, y up, z towards the player, the page's middle at the origin.
## The cards are battle_cards.gd's.

## what a hex shows (set_states): the values of the state texture
enum State { NONE, REACH, ACTIVE, HOVER, TARGET, BLOCKED }

const BattleMath := preload("res://battle_math.gd")
const BattleCards := preload("res://battle_cards.gd")
const AREA := Vector2(1.5, 0.94) ## metres: room.gd MINIMAP_AREA
const LIFT := 0.0015 ## metres over the page
const FIELD_SHADER := """shader_type spatial;
render_mode unshaded, shadows_disabled;
uniform sampler2D states : filter_nearest, repeat_disable; // 17 x 11, a hex's State / 255 in red
uniform sampler2D picture : source_color, filter_linear_mipmap, repeat_disable; // the 2D battlefield's background
uniform bool has_picture = false;
uniform vec3 paper : source_color = vec3(0.82, 0.76, 0.62);
uniform vec3 ink : source_color = vec3(0.16, 0.11, 0.07);
uniform vec2 page; // the quad in field pixels: the whole page, the field in its middle
uniform vec2 field = vec2(800.0, 556.0); // battle_math.gd FIELD, PITCH, FIRST, REGULAR
uniform vec2 pitch = vec2(44.0, 42.0);
uniform vec2 first = vec2(36.0, 112.0);
uniform float regular = 0.9072647;

void fragment() {
	vec2 at = (UV - 0.5) * page + field / 2.0;
	// the nearest two hex centres, valid or not: a regular hex is the cell of its centre
	float nearest = 1e9;
	float second = 1e9;
	ivec2 hex = ivec2(-1);
	bool second_valid = false;
	int guess = int(round((at.y - first.y) / pitch.y));
	for (int row = guess - 1; row <= guess + 1; row++) {
		float shift = (row & 1) == 0 ? pitch.x / 2.0 : 0.0;
		int middle = int(round((at.x - first.x - shift) / pitch.x));
		for (int column = middle - 1; column <= middle + 1; column++) {
			vec2 offset = at - first - vec2(pitch.x * float(column) + shift, pitch.y * float(row));
			float distance_ = length(vec2(offset.x, offset.y * regular));
			bool valid = row >= 0 && row < 11 && column >= 0 && column < 17;
			if (distance_ < nearest) {
				second = nearest;
				second_valid = hex.x >= 0;
				nearest = distance_;
				hex = valid ? ivec2(column, row) : ivec2(-1);
			} else if (distance_ < second) {
				second = distance_;
				second_valid = valid;
			}
		}
	}
	vec2 picture_uv = at / field;
	bool on_picture = has_picture && picture_uv == clamp(picture_uv, 0.0, 1.0);
	vec3 colour = on_picture ? texture(picture, picture_uv).rgb : paper;
	if (hex.x >= 0) {
		int state = int(texelFetch(states, hex, 0).r * 255.0 + 0.5);
		vec4 wash = state == 1 ? vec4(0.25, 0.45, 0.2, 0.3) : state == 2 ? vec4(0.95, 0.75, 0.2, 0.55)
				: state == 3 ? vec4(1.0, 1.0, 0.9, 0.45) : state == 4 ? vec4(0.8, 0.15, 0.1, 0.5)
				: state == 5 ? vec4(ink, 0.45) : vec4(0.0);
		colour = mix(colour, wash.rgb, wash.a);
	}
	// pixels from the border between the two cells; the line is antialiased over a screen pixel
	float edge = (second * second - nearest * nearest) / (2.0 * pitch.x);
	float line = 1.0 - smoothstep(0.6, 0.6 + fwidth(edge) + 0.4, edge);
	ALBEDO = mix(colour, ink, (hex.x >= 0 || second_valid) ? line * 0.75 : 0.0);
}
"""

var states := PackedByteArray() ## BattleMath.COLUMNS * ROWS of State
var hover := BattleMath.NO_HEX ## the hex under the player's ray (set_hover): shown as State.HOVER over its own state
var flashes := {} ## hex: seconds left of a spell's flash (State.TARGET over its own state)
var cards: Node3D = BattleCards.new() ## the stacks
var _spell := 0 ## the sequence of the last spell event flashed
var _field := MeshInstance3D.new()
var _states := ImageTexture.new()


func _init() -> void:
	var quad := PlaneMesh.new()
	quad.size = AREA # the whole map is covered
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = FIELD_SHADER
	material.set_shader_parameter("states", _states)
	material.set_shader_parameter("page", AREA * (BattleMath.FIELD.y / AREA.y))
	_field.mesh = quad
	_field.material_override = material
	_field.position.y = LIFT
	_field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_field)
	add_child(cards)
	set_states(PackedByteArray())


## The battlefield's own background (800 x 556, as the 2D battle draws it), or null for bare paper
func set_picture(picture: Texture2D) -> void:
	var material: ShaderMaterial = _field.material_override
	material.set_shader_parameter("picture", picture)
	material.set_shader_parameter("has_picture", picture != null)


## A picture's file as the game holds it (VcmiData.image_file) decoded: a PNG, a BMP, or a Heroes 3 PCX (its size in
## bytes, width and height, then palette indices with a palette after them, or BGR). Null when it is none of them
static func decode_picture(bytes: PackedByteArray) -> Image:
	var image := Image.new()
	if bytes.size() >= 8 and bytes.slice(0, 4) == PackedByteArray([0x89, 0x50, 0x4E, 0x47]):
		return image if image.load_png_from_buffer(bytes) == OK else null
	if bytes.size() >= 2 and bytes[0] == 0x42 and bytes[1] == 0x4D:
		return image if image.load_bmp_from_buffer(bytes) == OK else null
	if bytes.size() < 12:
		return null
	var size := bytes.decode_u32(0)
	var width := bytes.decode_u32(4)
	var height := bytes.decode_u32(8)
	if width == 0 or height == 0 or width > 4096 or height > 4096:
		return null
	var rgb := PackedByteArray()
	rgb.resize(width * height * 3)
	if size == width * height and bytes.size() >= 12 + size + 768:
		var palette := 12 + size
		for i in size:
			var colour := palette + 3 * bytes[12 + i]
			rgb[3 * i] = bytes[colour]
			rgb[3 * i + 1] = bytes[colour + 1]
			rgb[3 * i + 2] = bytes[colour + 2]
	elif size == width * height * 3 and bytes.size() >= 12 + size:
		for i in width * height:
			rgb[3 * i] = bytes[12 + 3 * i + 2]
			rgb[3 * i + 1] = bytes[12 + 3 * i + 1]
			rgb[3 * i + 2] = bytes[12 + 3 * i]
	else:
		return null
	return Image.create_from_data(width, height, false, Image.FORMAT_RGB8, rgb)


## A State for each hex, by hex index; missing ones are NONE
func set_states(new_states: PackedByteArray) -> void:
	states = new_states.duplicate()
	states.resize(BattleMath.COLUMNS * BattleMath.ROWS)
	var shown := states.duplicate()
	for hex: int in flashes:
		if hex >= 0 and hex < shown.size():
			shown[hex] = State.TARGET
	if hover >= 0 and hover < shown.size():
		shown[hover] = State.HOVER
	var image := Image.create_from_data(BattleMath.COLUMNS, BattleMath.ROWS, false, Image.FORMAT_R8, shown)
	if _states.get_image() == null:
		_states.set_image(image)
	else:
		_states.update(image)


func set_hover(hex: int) -> void:
	if hex != hover:
		hover = hex
		set_states(states)


## The game's battle (VcmiData.battle): a card for each stack, the obstacles, the active stack's hex and the hexes it
## reaches
func set_battle(data: Dictionary) -> void:
	var shown := PackedByteArray(data.get("reach", PackedByteArray()))
	var blocked := PackedByteArray(data.get("blocked", PackedByteArray()))
	shown.resize(BattleMath.COLUMNS * BattleMath.ROWS)
	blocked.resize(shown.size())
	for hex in shown.size():
		shown[hex] = State.BLOCKED if blocked[hex] else State.REACH if shown[hex] else State.NONE
	for stack: Dictionary in data.get("stacks", []):
		var hex: int = stack.get("hex", -1)
		if stack.get("active", false) and hex >= 0 and hex < shown.size():
			shown[hex] = State.ACTIVE
	cards.set_action(data) # first: with an event, set_stacks guesses no attack
	cards.set_stacks(data.get("stacks", []))
	# a spell: its target hex and the first stack it touched flash
	if data.get("action_kind", 0) == 3 and data.get("action", 0) != _spell:
		_spell = data.get("action", 0)
		flashes[data.get("action_hex", -1)] = 0.7
		for stack: Dictionary in data.get("stacks", []):
			if stack.get("id", -2) == data.get("action_target", -1):
				flashes[stack.get("hex", -1)] = 0.7
	set_states(shown)


## The battle is over: nothing of it is kept for the next one, whose stacks and events count from 0 again
func clear() -> void:
	cards.clear()
	flashes.clear()
	_spell = 0


func _process(delta: float) -> void:
	if flashes.is_empty():
		return
	for hex: int in flashes.keys():
		flashes[hex] -= delta
		if flashes[hex] <= 0.0:
			flashes.erase(hex)
	if flashes.is_empty():
		set_states(states)


## Two armies, the active stack and the hexes it reaches: for the PC preview and the test command `battle`
func show_sample() -> void:
	var creatures := ["CPKMAN", "CGRIFF", "CSKELE", "CBDRGN"] # pikemen, griffins, skeletons, black dragons
	var stacks := []
	for i in 6:
		stacks.append({"id": 2 * i, "hex": (2 * i) * 17 + 1, "side": 0, "count": [12, 40, 7, 3, 25, 1][i],
				"wide": i % 2 == 1, "animation": creatures[i % 2]})
		stacks.append({"id": 2 * i + 1, "hex": (2 * i) * 17 + 15, "side": 1, "count": [30, 9, 14, 2, 60, 5][i],
				"wide": i == 1, "animation": creatures[2 + int(i == 1)]})
	stacks[4]["hex"] = 4 * 17 + 6 # the active stack, out in the field
	stacks.append({"id": 20, "hex": 7 * 17 + 9, "side": 1, "count": 0, "alive": false, "animation": "CSKELE"})
	cards.set_stacks(stacks)
	var sample := PackedByteArray()
	sample.resize(BattleMath.COLUMNS * BattleMath.ROWS)
	for hex in sample.size():
		@warning_ignore("integer_division")
		if absi(hex % 17 - 6) + absi(hex / 17 - 4) <= 4:
			sample[hex] = State.REACH
	for hex in [5 * 17 + 11, 5 * 17 + 12, 6 * 17 + 12, 2 * 17 + 9]: # a rock and a stump
		sample[hex] = State.BLOCKED
	sample[4 * 17 + 6] = State.ACTIVE
	sample[4 * 17 + 15] = State.TARGET
	set_states(sample)


## The middle of `hex` on the page, in this node's space
func hex_position(hex: int) -> Vector3:
	var at := BattleMath.field_to_page(BattleMath.hex_centre(hex), AREA)
	return Vector3(at.x, 0.0, at.y)


## metres from a hex to the next one in its row
func hex_metres() -> float:
	return BattleMath.PITCH.x * AREA.y / BattleMath.FIELD.y


## The hex a world ray hits from above, or BattleMath.NO_HEX
func ray_hex(from: Vector3, direction: Vector3) -> int:
	var to_field := global_transform.affine_inverse()
	var start := to_field * from
	var along := to_field.basis * direction
	if along.y > -0.0001 or start.y <= 0.0:
		return BattleMath.NO_HEX
	var hit := start + along * (-start.y / along.y)
	return BattleMath.hex_at(BattleMath.page_to_field(Vector2(hit.x, hit.z), AREA))

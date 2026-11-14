extends Node3D
## The battle on the war table (phase 5, quest/PHASE5.md): the battlefield over the book's page, its hexes as inked
## lines, the hexes' states as washes of colour, and a card for each stack. A child of the map's panel (room.gd
## add_table_panel): x right, y up, z towards the player, the page's middle at the origin.
## The cards here are markers in the side's colour with the stack's count: the creatures' own animations come with the
## sprite atlas (milestone 5c).

## what a hex shows (set_states): the values of the state texture
enum State { NONE, REACH, ACTIVE, HOVER, TARGET, BLOCKED }

const BattleMath := preload("res://battle_math.gd")
const AREA := Vector2(1.5, 0.94) ## metres: room.gd MINIMAP_AREA
const LIFT := 0.0015 ## metres over the page
const CARD := Vector2(0.055, 0.085) ## metres, a marker card; a two-hex stack's is twice as wide
const SIDES := [Color(0.25, 0.4, 0.8), Color(0.75, 0.2, 0.15)] ## attacker, defender, until the players' colours come
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
var _field := MeshInstance3D.new()
var _states := ImageTexture.new()
var _cards := Node3D.new()
var _lean := deg_to_rad(82.0)


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
	add_child(_cards)
	set_states(PackedByteArray())


## The battlefield's own background (800 x 556, as the 2D battle draws it), or null for bare paper
func set_picture(picture: Texture2D) -> void:
	var material: ShaderMaterial = _field.material_override
	material.set_shader_parameter("picture", picture)
	material.set_shader_parameter("has_picture", picture != null)


## A State for each hex, by hex index; missing ones are NONE
func set_states(new_states: PackedByteArray) -> void:
	states = new_states.duplicate()
	states.resize(BattleMath.COLUMNS * BattleMath.ROWS)
	var shown := states.duplicate()
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
	set_stacks(data.get("stacks", []))
	set_states(shown)


## Two armies, the active stack and the hexes it reaches: for the PC preview and the test command `battle`
func show_sample() -> void:
	var stacks := []
	for i in 6:
		stacks.append({"hex": (2 * i) * 17 + 1, "side": 0, "count": [12, 40, 7, 3, 25, 1][i], "wide": i == 3})
		stacks.append({"hex": (2 * i) * 17 + 15, "side": 1, "count": [30, 9, 14, 2, 60, 5][i], "wide": i == 1})
	stacks[4]["hex"] = 4 * 17 + 6 # the active stack, out in the field
	var sample := PackedByteArray()
	sample.resize(BattleMath.COLUMNS * BattleMath.ROWS)
	for hex in sample.size():
		@warning_ignore("integer_division")
		if absi(hex % 17 - 6) + absi(hex / 17 - 4) <= 4:
			sample[hex] = State.REACH
	for hex in [5 * 17 + 11, 5 * 17 + 12, 6 * 17 + 12, 2 * 17 + 9]: # a rock and a stump
		sample[hex] = State.BLOCKED
	stacks.append({"hex": 7 * 17 + 9, "side": 1, "count": 0, "alive": false})
	set_stacks(stacks)
	sample[4 * 17 + 6] = State.ACTIVE
	sample[4 * 17 + 15] = State.TARGET
	set_states(sample)


## The stacks' marker cards. Each: hex (of its front half), side (0 attacker), count, wide (a two-hex creature), alive
## (default true; the dead lie flat and grey, without a count)
func set_stacks(stacks: Array) -> void:
	for card in _cards.get_children():
		_cards.remove_child(card)
		card.queue_free()
	for stack: Dictionary in stacks:
		var wide: bool = stack.get("wide", false)
		var side: int = clampi(stack.get("side", 0), 0, 1)
		var quad := QuadMesh.new()
		quad.size = Vector2(CARD.x * (2.0 if wide else 1.0), CARD.y)
		quad.center_offset = Vector3(0.0, CARD.y / 2.0, 0.0)
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var alive: bool = stack.get("alive", true)
		material.albedo_color = SIDES[side] if alive else SIDES[side].lerp(Color(0.35, 0.33, 0.3), 0.75)
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		quad.material = material
		var card := MeshInstance3D.new()
		card.mesh = quad
		# a two-hex stack's other half is behind it: towards its own side's edge
		var behind := Vector3((-1.0 if side == 0 else 1.0) * hex_metres() / 2.0, 0.0, 0.0) if wide else Vector3.ZERO
		card.position = hex_position(stack.get("hex", 0)) + behind + Vector3(0.0, LIFT, hex_metres() * 0.25)
		card.rotation.x = _lean - PI / 2.0 if alive else -PI / 2.0
		card.set_meta("alive", alive)
		_cards.add_child(card)
		if not alive:
			card.position += Vector3(0.0, 0.001, CARD.y / 2.0 - hex_metres() * 0.25) # lying over its hex
			continue
		var count := Label3D.new()
		count.text = str(stack.get("count", 1))
		count.pixel_size = 0.0005
		count.font_size = 40
		count.outline_size = 10
		count.position = Vector3(0.0, 0.014, 0.001)
		card.add_child(count)


## The cards' angle from the table, as the map's (room.gd set_card_lean)
func set_card_lean(degrees: float) -> void:
	_lean = deg_to_rad(degrees)
	for card: Node3D in _cards.get_children():
		if card.get_meta("alive", true):
			card.rotation.x = _lean - PI / 2.0


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

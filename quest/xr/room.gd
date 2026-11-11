@tool
extends Node3D
## The war room around the game screen: a torch-lit castle study with a fireplace, a war table and banners in the
## eight player colours, lit by a baked lightmap (assets/room/room.lmbake) only; the flames flicker in their shader.
## Room space: the floor at y 0 under the head (0, 1.6, 0), the screen towards -Z, 1-4 m away. Nothing stands between
## the head and the screen: furniture is at the side walls, behind the head, or low in front (preview.gd checks it).
## After changing anything that does not move, rebake: quest/tools/bake-room.sh. Every node has a fixed name, as the
## lightmap finds its meshes by node path. Assets and licences: assets/room/LICENSES.md.

const TableMath := preload("res://table_math.gd")
const SIZE := Vector3(12.0, 5.0, 10.0) ## width, height, depth in metres
const BACK := -6.0 ## z of the wall behind the screen
const FRONT := BACK + SIZE.z
const MIDDLE := (BACK + FRONT) / 2.0
const HALF := SIZE.x / 2.0
const LAYER := 2 ## render layer of the room; main.gd keeps its controller light off it, as the room has baked light
## render layer of the small decoration without lightmap (lit by the lightmap probes): the baked lights skip it, so each
## of its meshes stays within the Mobile renderer's 8 lights
const DECOR := 8
const LIGHTMAP := "res://assets/room/room.lmbake"
const ROOM := "res://assets/room/"
const TEX := ROOM + "textures/"
## albedo, normal, ORM (ambient occlusion, roughness, metallic; "" = flat), height ("" = none)
const SETS := {
	"stone": ["castle_wall_slates_diff_2k.jpg", "castle_wall_slates_nor_gl_2k.jpg", "castle_wall_slates_arm_2k.jpg",
			"castle_wall_slates_disp_2k.jpg"],
	"floor": ["monastery_stone_floor_diff_2k.jpg", "monastery_stone_floor_nor_gl_2k.jpg",
			"monastery_stone_floor_arm_2k.jpg", "monastery_stone_floor_disp_2k.jpg"],
	"planks": ["dark_wooden_planks_diff_2k.jpg", "dark_wooden_planks_nor_gl_2k.jpg", "dark_wooden_planks_arm_2k.jpg",
			""],
	"beam": ["medieval_wood_diff_2k.jpg", "medieval_wood_nor_gl_2k.jpg", "medieval_wood_arm_2k.jpg", ""],
	"fabric": ["quatrefoil_jacquard_fabric_grey_1k.jpg", "quatrefoil_jacquard_fabric_nor_gl_1k.jpg", "", ""],
	"carpet": ["Carpet015_1K-JPG_Color.jpg", "Carpet015_1K-JPG_NormalGL.jpg", "", ""],
}
## the eight player colours: red, blue, tan, green, orange, purple, teal, pink (linear, times the grey fabric)
const PLAYER_COLOURS := [Color(0.6, 0.03, 0.02), Color(0.03, 0.09, 0.55), Color(0.55, 0.38, 0.18), Color(0.04, 0.3,
		0.05),
	Color(0.8, 0.25, 0.02), Color(0.28, 0.04, 0.4), Color(0.02, 0.35, 0.35), Color(0.85, 0.28, 0.42)]
const FLAME := Color(1.0, 0.68, 0.42) ## torch and candle light: warm, not orange, so the moonlight reads as cool
## public-domain paintings (assets/room/LICENSES.md): file, centre, wall normal, width; the height follows the image
const PAINTINGS := [
	["uccello_battle_of_san_romano.jpg", Vector3(HALF - 0.03, 2.6, -1.25), Vector3.LEFT, 2.3],
	["bierstadt_among_the_sierra_nevada.jpg", Vector3(-3.5, 2.35, FRONT - 0.03), Vector3.FORWARD, 1.7],
	["cole_the_savage_state.jpg", Vector3(3.5, 2.35, FRONT - 0.03), Vector3.FORWARD, 1.7],
]
const FIRE_Z := -1.2 ## centre of the fireplace on the left wall
const WINDOW_X := 4.2 ## the two windows of the back wall, either side of the screen
const WINDOW := Rect2(-0.65, 1.3, 1.3, 2.6) ## x from the window centre, y from the floor
const REVEAL := 0.45 ## depth of the window openings
const TABLE_TOP := 0.8 ## height of the map on the war table (meshy war_table at its scale)
const TORCH_PLATE := 0.137 ## metres from the wall plate to the torch origin (meshy wall_torch at its scale)
const FLAME_SHADER := """shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled, skip_vertex_transform,
	fog_disabled;
// every flame is a quad of four vertices at its base; CUSTOM0 = width, height, phase, brightness
varying vec2 uv;
varying vec2 seed;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}
void vertex() {
	vec3 base = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 up = normalize((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 right = normalize(cross(up, -base)); // faces the eye, stays upright
	float sway = (noise(vec2(TIME * 1.7, CUSTOM0.z * 9.0)) - 0.5) * 0.25 * UV.y * UV.y;
	VERTEX = base + right * (UV.x - 0.5 + sway) * CUSTOM0.x + up * UV.y * CUSTOM0.y;
	uv = UV;
	seed = CUSTOM0.zw;
}
void fragment() {
	float t = TIME * 2.2 + seed.x * 17.0;
	float n = noise(vec2(uv.x * 4.0, uv.y * 3.0 - t)) * 0.65 + noise(vec2(uv.x * 9.0, uv.y * 7.0 - t * 1.7)) * 0.35;
	float x = (uv.x - 0.5) * 2.0 + (n - 0.5) * 0.5 * uv.y;
	float width = (1.0 - uv.y) * (0.45 + 0.55 * sqrt(uv.y)) + 0.02;
	float body = 1.0 - smoothstep(width * 0.35, width, abs(x));
	body *= smoothstep(0.0, 0.12, uv.y) * (1.0 - smoothstep(0.35 + 0.45 * n, 1.0, uv.y));
	float heat = clamp(body * (1.25 - uv.y), 0.0, 1.0);
	vec3 colour = mix(vec3(0.9, 0.18, 0.02), vec3(1.0, 0.62, 0.2), smoothstep(0.1, 0.6, heat));
	colour = mix(colour, vec3(1.0, 0.92, 0.7), smoothstep(0.7, 1.0, heat));
	float flicker = 0.85 + 0.15 * noise(vec2(TIME * 6.0, seed.x * 31.0));
	ALBEDO = colour * body * seed.y * flicker;
	ALPHA = 0.0; // adds light, leaves the eye buffer alpha alone: the game layer behind stays visible
}
"""
## the night sky behind the windows, at infinity (by the view direction in room space): stars, a moon, mountain ridges
const SKY_SHADER := """shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled, fog_disabled;
varying vec3 direction;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void vertex() {
	direction = VERTEX - (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}
void fragment() {
	vec3 d = normalize(direction);
	float elevation = asin(clamp(d.y, -1.0, 1.0));
	float azimuth = atan(d.x, -d.z);
	vec3 colour = mix(vec3(0.05, 0.08, 0.2), vec3(0.006, 0.01, 0.035), smoothstep(-0.05, 0.45, elevation));
	vec2 grid = vec2(azimuth, elevation) * 140.0;
	vec2 cell = floor(grid);
	float h = hash(cell);
	vec2 spot = vec2(hash(cell + 1.7), hash(cell + 3.1)) * 0.6 + 0.2;
	float star = step(0.9, h) * smoothstep(0.22, 0.0, length(fract(grid) - spot)) * (0.4 + 2.5 * fract(h * 37.0));
	colour += vec3(0.85, 0.9, 1.0) * star * (0.75 + 0.25 * sin(TIME * 2.3 + h * 60.0));
	vec3 moon = normalize(vec3(0.5, 0.24, -0.83));
	float m = dot(d, moon);
	colour += vec3(1.0, 0.97, 0.88) * smoothstep(0.99955, 0.9997, m) * 2.5
		+ vec3(0.12, 0.16, 0.3) * pow(max(m, 0.0), 300.0);
	float far = 0.07 + 0.045 * sin(azimuth * 7.0) + 0.025 * sin(azimuth * 17.0 + 1.0) + 0.012 * sin(azimuth * 43.0);
	float near = 0.015 + 0.03 * sin(azimuth * 4.0 + 2.0) + 0.012 * sin(azimuth * 23.0 + 0.5);
	colour = mix(colour, vec3(0.025, 0.035, 0.07), smoothstep(far + 0.002, far - 0.002, elevation));
	colour = mix(colour, vec3(0.006, 0.008, 0.016), smoothstep(near + 0.002, near - 0.002, elevation));
	ALBEDO = colour;
}
"""
## faint moonlight shafts: additive, soft at the sides, fading towards the floor, with slowly moving dust
const SHAFT_SHADER := """shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}
void fragment() {
	float edges = smoothstep(0.0, 0.25, UV.x) * smoothstep(1.0, 0.75, UV.x);
	float along = smoothstep(0.0, 0.08, UV.y) * (1.0 - UV.y);
	float shimmer = 0.75 + 0.25 * noise(vec2(UV.x * 6.0 + TIME * 0.05, UV.y * 3.0 - TIME * 0.08));
	ALBEDO = vec3(0.35, 0.45, 0.8) * 0.07 * edges * along * shimmer;
	ALPHA = 0.0; // additive, as the flames
}
"""
## embers and dust: soft dots facing the eye, additive like the flames (no alpha written)
const SPARK_SHADER := """shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 tint = vec4(1.0);
uniform sampler2D dot_texture : filter_linear;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	ALBEDO = tint.rgb * COLOR.rgb * texture(dot_texture, UV).a * COLOR.a;
	ALPHA = 0.0;
}
"""
const MINIMAP_AREA := Vector2(0.8, 0.5) ## metres on the table inside the corner figures
const MARKER_METRES := 0.012 ## width of an object marker on the minimap
## The war table as the phase 0 concept (quest/concept/screenshots/table.png): the map on the cream pages of a book in
## red leather, the minimap's tablet on an easel right of it (all of the map, the view framed), and the lord's chair at
## the near edge, where the player sits in tabletop mode (seat)
const BOOK_COVER := Color(0.3, 0.06, 0.045)
const BOOK_PAGES := Color(0.93, 0.88, 0.76)
const TABLET_POSE := Transform3D(Basis(Vector3.UP, -0.55) * Basis(Vector3.RIGHT, -0.35), Vector3(0.64, 0.12, -0.14))
const TABLET_WIDTH := 0.26
## the seated player's eyes in the table's space: over the chair, 0.45 m above the map, looking at the map's middle
const SEAT := Vector3(0.0, TABLE_TOP + 0.45, 0.82)
const CHAIR_Z := 1.0
## The sprites of the map objects from the atlas pages (VcmiData.update_sprites, quest/MILESTONE_3B.md): the quad of the
## current frame, built from the frame table; pixels -> panel by the instance transform. Premultiplied colour, drawn in
## instance order without depth (the order is the 2D map's). The owner colour goes on the mask of owned objects.
## Owner 10: a terrain, river or road tile (quest/PHASE4.md 4c), 11 a fog tile: sampled inside the frame so the atlas
## padding does not show between tiles. The fog tiles, last, cover what the local team does not see, as in 2D.
## Paper cards (quest/PHASE4.md 4e): an object whose anchor or visitable tile is seen stands up `stand` of the way,
## turned about its anchor tile's bottom edge to `lean` from the table, unless it is flat (cards.json). Its 2D shadow
## stays on the table (the first pass draws only the shadow of a card, flat). The cards draw in a second pass
## (`cards_pass`, the material's next_pass), after the fog tiles, which would cover them from behind; no pass writes
## depth. shortcut: the cards draw in map order, back to
## front from the table's near edge; seen from its far side a near card goes behind a far one. Depth or a sort by view
## when needed.
const SPRITE_SHADER := """shader_type spatial;
render_mode unshaded, shadows_disabled, blend_premul_alpha, depth_draw_never, cull_disabled;
// premultiplied in linear light, sRGB-encoded (SpriteAtlas.h)
uniform sampler2DArray atlas : source_color, filter_linear_mipmap;
uniform sampler2DArray masks : filter_linear_mipmap;
uniform sampler2D frames : filter_nearest;
uniform vec4 owner_colours[9];
uniform bool precision_check = false;
uniform mat4 world_to_panel; // the minimap's world transform, inverted: content outside the panel is cut
uniform vec2 panel_half = vec2(1000.0);
uniform sampler2D fog : filter_nearest; // x-major, as the minimap's
uniform float stand = 1.0; // 0 flat, 1 standing: the pop-up animation (show_sprites)
uniform float lean = 1.22; // radians from the table, cards.json
uniform bool cards_pass = false; // the second pass: the standing cards only; the first: all else, and cards' shadows
uniform float texel_scale = 1.0; // texels per 2D map pixel in the pages (SpriteAtlas scale: xBRZ HD)
uniform float PAGE = 1024.0; // texels a page side (SpriteAtlas::PAGE), from the texture (set_sprites)
varying vec2 panel_xz;
varying flat float shadow_only;
varying vec3 page_uv;
varying flat int owner;
varying flat float lost;
varying flat float card;
vec4 texel(int i) {
	return texelFetch(frames, ivec2(i % 512, i / 512), 0);
}
void vertex() {
	int id = int(floor(INSTANCE_CUSTOM.w));
	lost = precision_check && abs(fract(INSTANCE_CUSTOM.w) - 0.5) > 0.01 ? 1.0 : 0.0;
	int first = int(INSTANCE_CUSTOM.x + 0.5);
	int packed = int(INSTANCE_CUSTOM.y + 0.5);
	int count = max(packed % 1024, 1);
	bool mirror = (packed / 1024) % 2 == 1; // left-right
	bool flip = (packed / 2048) % 2 == 1; // top-bottom: tiles only, whose full frame is square (32 x 32)
	// as MapRendererAdventureContext::objectImageIndex: 180 ms a frame, the clock and the frame offset by the id
	int t = int(TIME * 1000.0);
	int frame = ((t + (id * 97) % 180) / 180 + id) % count;
	vec4 a = texel(2 * (first + frame)); // page, x, y, width
	vec4 b = texel(2 * (first + frame) + 1); // height, left and top from the full frame's bottom right, full width
	// the instance sits on the anchor tile's bottom right; mirrored, the frame's left edge is full width - left - width.
	// The table is in texels; the geometry in 2D map pixels
	float left = (mirror ? -(b.y + b.w) - a.w : b.y) / texel_scale;
	float top = (flip ? -(b.z + b.w) - b.x : b.z) / texel_scale;
	VERTEX = vec3(left + UV.x * a.w / texel_scale, 0.0, top + UV.y * b.x / texel_scale);
	vec2 source = vec2(mirror ? 1.0 - UV.x : UV.x, flip ? 1.0 - UV.y : UV.y);
	owner = int(INSTANCE_CUSTOM.z + 0.5);
	card = 0.0;
	if (owner < 10 && packed < 4096) { // an object, not flat (VcmiData.update_sprites)
		float seen = max(textureLod(fog, COLOR.yx, 0.0).r, textureLod(fog, COLOR.wz, 0.0).r);
		card = seen > 0.0 ? stand : 0.0;
	}
	if (card > 0.0 && cards_pass) {
		// pixels up from the anchor tile's bottom edge, turned up about it; local y is metres, local z pixels
		float up = -VERTEX.z;
		float angle = card * lean;
		VERTEX.z = -up * cos(angle);
		VERTEX.y = up * sin(angle) * length(MODEL_MATRIX[2].xyz) / length(MODEL_MATRIX[1].xyz);
	}
	if (cards_pass && card <= 0.0) {
		VERTEX = vec3(0.0); // drawn by the first pass
	}
	shadow_only = !cards_pass && card > 0.0 ? 1.0 : 0.0;
	// a tile's edge texels sampled at their centres: no blend with the clear padding around the frame
	vec2 inset = owner >= 10 ? vec2(0.5) : vec2(0.0);
	page_uv = vec3((a.yz + inset + source * (vec2(a.w, b.x) - 2.0 * inset)) / PAGE, a.x);
	panel_xz = (world_to_panel * (MODEL_MATRIX * vec4(VERTEX, 1.0))).xz;
}
void fragment() {
	if (abs(panel_xz.x) > panel_half.x || abs(panel_xz.y) > panel_half.y) {
		discard;
	}
	// tiles lie side by side: from mip 3 the 4 texels of padding between frames shrink below one texel and blend
	// neighbours into the edges (SpriteAtlas.h PAD, extrude), so they stop at mip 2
	vec2 texels = page_uv.xy * PAGE;
	float lod = log2(max(max(length(dFdx(texels)), length(dFdy(texels))), 1.0));
	vec4 c = owner >= 10 ? textureLod(atlas, page_uv, min(lod, 2.0)) : texture(atlas, page_uv);
	// a shadow texel: dark and half clear. A card's lie on the table (first pass); the card itself has none
	bool shade = c.a < 0.8 && max(c.r, max(c.g, c.b)) < 0.02;
	if (shadow_only > 0.5 && !shade) {
		discard;
	}
	if (cards_pass && shade) {
		c = vec4(0.0);
	}
	// most of a sprite's quad is clear: no blending there (MILESTONE_3B.md section 1e)
	if (c.a < 0.004) {
		discard;
	}
	if (owner < 9) {
		c.rgb = mix(c.rgb, owner_colours[owner].rgb * c.a, texture(masks, page_uv).r);
	}
	if (lost > 0.5) {
		c = vec4(c.a, 0.0, 0.0, c.a);
	}
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
"""
## markers sit in the fog unless their anchor or visitable tile is seen (INSTANCE_CUSTOM: both in minimap UV; the fog is
## x-major)
const MARKER_SHADER := """shader_type spatial;
render_mode unshaded, shadows_disabled;
uniform sampler2D fog : filter_nearest;
uniform mat4 world_to_panel; // the minimap's world transform, inverted: content outside the panel is cut
uniform vec2 panel_half = vec2(1000.0);
varying vec2 panel_xz;
void vertex() {
	float seen = max(textureLod(fog, INSTANCE_CUSTOM.yx, 0.0).r, textureLod(fog, INSTANCE_CUSTOM.wz, 0.0).r);
	if (seen == 0.0) {
		VERTEX = vec3(0.0);
	}
	panel_xz = (world_to_panel * (MODEL_MATRIX * vec4(VERTEX, 1.0))).xz;
}
void fragment() {
	if (abs(panel_xz.x) > panel_half.x || abs(panel_xz.y) > panel_half.y) {
		discard;
	}
	ALBEDO = COLOR.rgb;
}
"""
const MINIMAP_SHADER := """shader_type spatial;
render_mode unshaded, shadows_disabled;
uniform sampler2D terrain : source_color, filter_nearest_mipmap;
uniform sampler2D fog : filter_linear;
uniform float zoom = 1.0; // set_zoom: the panel shows 1 / zoom of the map around centre
uniform vec2 centre = vec2(0.5);
uniform bool framed = false; // the tablet: the whole map, the table's view in a white frame
uniform vec4 view = vec4(0.0, 0.0, 1.0, 1.0); // its corners in map UV
void fragment() {
	vec2 uv = (UV - 0.5) / zoom + centre;
	// the fog image is x-major (VcmiData.fog_image), 1 of 255 where visible
	ALBEDO = texture(terrain, uv).rgb * min(texture(fog, uv.yx).r * 255.0, 1.0) * 0.85;
	if (framed) {
		vec2 line = fwidth(uv) * 1.5;
		bool inside = all(greaterThan(uv, view.xy - line)) && all(lessThan(uv, view.zw + line));
		bool core = all(greaterThan(uv, view.xy + line)) && all(lessThan(uv, view.zw - line));
		if (inside && !core) {
			ALBEDO = vec3(1.0);
		}
	}
}
"""

var environment := _make_environment() ## main.gd shows the room with this environment
var zoom := 1.0 ## the minimap shows 1 / zoom of the map (set_zoom)
var zoom_centre := Vector2(0.5, 0.5) ## in minimap UV: both levels side by side
var map_cells := Vector2i.ZERO ## tiles of the terrain image: width * levels, height

var _spark_texture: GradientTexture2D ## made by _spark on first use
var _dirt_texture: NoiseTexture2D ## made by _dirt on first use
var _flames := [] ## [base position, width, height, brightness]
var _table_light := Vector3.ZERO ## where the candles on the war table light the map from
var _materials := [] ## the tiled surface materials, for set_feature
var _table := Transform3D() ## the war table, set in _build_props
var _minimap: MeshInstance3D ## the game's minimap on the war table, from the data bridge (main.gd)
var _markers: MultiMeshInstance3D ## heroes, towns and flaggable objects on the minimap, in unit space of the panel
## the selected hero's path as discs and its tile marked, in the markers' space (set_path)
var _path: MultiMeshInstance3D
## the objects' sprites from the atlas (quest/MILESTONE_3B.md), VcmiData.update_sprites
var _sprites: MultiMeshInstance3D
var _book_cover: MeshInstance3D ## under the minimap, sized with it (set_minimap)
var _book_pages: MeshInstance3D
var _tablet: MeshInstance3D ## the whole map beside the table


## Test command `gfx <feature> <0|1>` (main.gd): switches one costly part off or on, to measure its GPU time on the
## headset
## with `quest.sh sample`. 0 glow (off by default), 1 parallax, 2 normal maps, 3 dirt detail, 4 probe reflections on the
## walls and floor too (off by default), 6 reflection probe, 7 decor props, 8 effects (particles, flames, shafts)
func set_feature(feature: int, on: bool) -> void:
	match feature:
		0: environment.glow_enabled = on
		1, 2, 3:
			var flag: int = [BaseMaterial3D.FEATURE_HEIGHT_MAPPING, BaseMaterial3D.FEATURE_NORMAL_MAPPING,
					BaseMaterial3D.FEATURE_DETAIL][feature - 1]
			for material in _materials:
				material.set_feature(flag, on)
		4: get_node("Reflections").reflection_mask = LAYER | DECOR if on else DECOR
		6: get_node("Reflections").visible = on
		7:
			for node in find_children("*", "GeometryInstance3D", true, false):
				if node.layers == DECOR and not node is GPUParticles3D:
					node.visible = on
		8:
			for node in find_children("*", "GeometryInstance3D", true, false):
				if node is GPUParticles3D or node.name in ["Flames", "Shafts"]:
					node.visible = on
		_: push_warning("gfx: unknown feature %d" % feature)


func _ready() -> void:
	_build_shell()
	_build_windows()
	_build_fireplace()
	_build_banners()
	_build_props()
	_build_lights()
	_build_books()
	_build_paintings()
	_build_effects()
	_add_flames()
	for node in find_children("*", "GeometryInstance3D", true, false):
		node.layers = DECOR if node.gi_mode == GeometryInstance3D.GI_MODE_DYNAMIC else LAYER
	var probe := ReflectionProbe.new()
	probe.size = SIZE
	probe.position = Vector3(0.0, SIZE.y / 2.0, MIDDLE)
	probe.origin_offset = Vector3(0.0, 1.6 - SIZE.y / 2.0, -MIDDLE) # captured from the head
	probe.box_projection = true
	probe.interior = true
	probe.cull_mask = LAYER | DECOR
	# only the decor (frames, banner gold, candles, books, logs, table pieces): a box-projected lookup on every wall and
	# floor pixel costs ~1 ms on the Quest
	probe.reflection_mask = DECOR
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED # the lightmap gives the ambient light
	_add(probe, "Reflections")
	var lightmap := LightmapGI.new()
	lightmap.quality = LightmapGI.BAKE_QUALITY_HIGH
	lightmap.bounces = 4
	lightmap.bounce_indirect_energy = 1.7 # a softer, evenly lit room
	lightmap.interior = true
	lightmap.environment_mode = LightmapGI.ENVIRONMENT_MODE_DISABLED
	lightmap.texel_scale = 1.0
	lightmap.max_texture_size = 2048
	# light for the controllers and the small props
	lightmap.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_SUBDIV_8
	if ResourceLoader.exists(LIGHTMAP):
		lightmap.light_data = load(LIGHTMAP)
	_add(lightmap, "Lightmap") # last: it looks up the meshes when it enters the tree
	_minimap = MeshInstance3D.new()
	_minimap.mesh = PlaneMesh.new() # faces up, image top towards the chair, away from the player
	(_minimap.mesh as PlaneMesh).size = MINIMAP_AREA
	# the code before the shader goes into the material: set later, the material keeps drawing flat grey (Godot 4.7.2)
	var shader := Shader.new()
	shader.code = MINIMAP_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	_minimap.material_override = material
	_minimap.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_minimap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_minimap.transform = _table * Transform3D(Basis(), Vector3(0.0, TABLE_TOP + 0.015, 0.0))
	_minimap.visible = false
	_add(_minimap, "Minimap")
	_build_book()
	var marker_shader := Shader.new()
	marker_shader.code = MARKER_SHADER
	var marker_material := ShaderMaterial.new()
	marker_material.shader = marker_shader
	var marker_mesh := PlaneMesh.new()
	marker_mesh.size = Vector2.ONE
	marker_mesh.material = marker_material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = marker_mesh
	# known bounds: Godot then skips computing them over every instance on each change
	multimesh.custom_aabb = AABB(Vector3(-0.6, -0.1, -0.6), Vector3(1.2, 0.2, 1.2))
	_markers = MultiMeshInstance3D.new()
	_markers.multimesh = multimesh
	_markers.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_markers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_markers.name = "Markers"
	_minimap.add_child(_markers)

	# the path: discs with the markers' material (fog, clip at the panel's edge), a little above the sprites
	var disc := CylinderMesh.new()
	disc.top_radius = 0.5
	disc.bottom_radius = 0.5
	disc.height = 0.001
	disc.radial_segments = 16
	disc.rings = 1
	disc.material = marker_material
	var path_multimesh := MultiMesh.new()
	path_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	path_multimesh.use_colors = true
	path_multimesh.use_custom_data = true
	path_multimesh.mesh = disc
	path_multimesh.custom_aabb = multimesh.custom_aabb
	_path = MultiMeshInstance3D.new()
	_path.multimesh = path_multimesh
	_path.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_path.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_path.name = "Path"
	_minimap.add_child(_path)

	var sprite_shader := Shader.new()
	sprite_shader.code = SPRITE_SHADER
	var sprite_material := ShaderMaterial.new()
	sprite_material.shader = sprite_shader
	var colours := PackedVector4Array()
	for c in ["#ff0000", "#3152ff", "#9c7352", "#429429", "#ff8400", "#8c29a5", "#099ca5", "#c67b8c", "#848484"]:
		var linear := Color(c).srgb_to_linear() # Graphics.cpp:72-90; the shader works in linear colour
		colours.append(Vector4(linear.r, linear.g, linear.b, 1.0))
	sprite_material.set_shader_parameter("owner_colours", colours)
	var card_material: ShaderMaterial = sprite_material.duplicate()
	card_material.set_shader_parameter("cards_pass", true)
	card_material.render_priority = 1 # after the first pass, the fog included
	sprite_material.next_pass = card_material
	var sprite_mesh := PlaneMesh.new()
	sprite_mesh.size = Vector2.ONE
	sprite_mesh.material = sprite_material
	var sprite_multimesh := MultiMesh.new()
	sprite_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	sprite_multimesh.use_colors = true
	sprite_multimesh.use_custom_data = true
	sprite_multimesh.mesh = sprite_mesh
	sprite_multimesh.custom_aabb = multimesh.custom_aabb
	_sprites = MultiMeshInstance3D.new()
	_sprites.multimesh = sprite_multimesh
	_sprites.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_sprites.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sprites.name = "Sprites"
	_sprites.visible = false
	_minimap.add_child(_sprites)


## The minimap from main.gd: new images when the game published them (else null), hidden outside a game
func set_minimap(terrain: Image, fog: Image, in_game: bool) -> void:
	var material: ShaderMaterial = _minimap.material_override
	if terrain != null:
		material.set_shader_parameter("terrain", ImageTexture.create_from_image(terrain))
		_tablet.material_override.set_shader_parameter("terrain", material.get_shader_parameter("terrain"))
		var size := Vector2(terrain.get_size())
		(_minimap.mesh as PlaneMesh).size = size * minf(MINIMAP_AREA.x / size.x, MINIMAP_AREA.y / size.y)
		var panel := minimap_size()
		# the cover from the table up, the pages just under the map (which lies 15 mm above the table)
		(_book_cover.mesh as BoxMesh).size = Vector3(panel.x + 0.07, 0.011, panel.y + 0.07)
		_book_cover.position.y = -0.0095
		(_book_pages.mesh as BoxMesh).size = Vector3(panel.x + 0.03, 0.004, panel.y + 0.03)
		_book_pages.position.y = -0.0025
		var tablet_size := Vector2(TABLET_WIDTH, TABLET_WIDTH * size.y / size.x)
		(_tablet.mesh as QuadMesh).size = tablet_size
		var frame: MeshInstance3D = _tablet.get_child(0)
		frame.scale = Vector3(tablet_size.x + 0.024, tablet_size.y + 0.024, 1.0)
		var leg: MeshInstance3D = _tablet.get_child(1)
		leg.scale = Vector3(1.0, tablet_size.y + 0.1, 1.0)
		leg.position.y = -0.05
		leg.rotation.x = 0.5
		map_cells = Vector2i(terrain.get_size())
		set_zoom(zoom, zoom_centre)
	if fog != null:
		var texture: ImageTexture = material.get_shader_parameter("fog")
		if texture != null and texture.get_size() == Vector2(fog.get_size()):
			texture.update(fog)
		else:
			material.set_shader_parameter("fog", ImageTexture.create_from_image(fog))
	_minimap.visible = in_game and material.get_shader_parameter("terrain") != null
	for node_material in [_markers.multimesh.mesh.material, _tablet.material_override] + _sprite_materials():
		if node_material.get_shader_parameter("fog") != material.get_shader_parameter("fog"):
			node_material.set_shader_parameter("fog", material.get_shader_parameter("fog"))


## The minimap shows 1 / `factor` of the map around `centre` (minimap UV), clamped to the map: the terrain by its UV,
## the markers and sprites by their node's transform, cut at the panel's edge in their shaders. Test command
## `table_zoom` (main.gd); grab and pinch come with phase 4. shortcut: markers grow with the zoom (sprites replace
## them when close)
func set_zoom(factor: float, centre: Vector2) -> void:
	zoom = maxf(factor, 1.0)
	var half := 0.5 / zoom
	zoom_centre = Vector2(clampf(centre.x, half, 1.0 - half), clampf(centre.y, half, 1.0 - half))
	var material: ShaderMaterial = _minimap.material_override
	material.set_shader_parameter("zoom", zoom)
	material.set_shader_parameter("centre", zoom_centre)
	_tablet.material_override.set_shader_parameter("view", Vector4(zoom_centre.x - half, zoom_centre.y - half,
			zoom_centre.x + half, zoom_centre.y + half))
	var size := minimap_size()
	# a point at minimap UV u lands at (u - centre) * size * zoom
	var content := Transform3D(Basis.from_scale(Vector3(size.x * zoom, 1.0, size.y * zoom)),
			Vector3(-zoom_centre.x * size.x * zoom, 0.0, -zoom_centre.y * size.y * zoom))
	_markers.transform = content * Transform3D(Basis(), Vector3(0.5, 0.0, 0.5))
	_sprites.transform = _markers.transform
	_path.transform = _markers.transform
	for shader_material in [_markers.multimesh.mesh.material] + _sprite_materials():
		shader_material.set_shader_parameter("world_to_panel", Projection(_minimap.global_transform.affine_inverse()))
		shader_material.set_shader_parameter("panel_half", size * 0.5)


## the tiles the minimap shows now, in map UV: position and size
func visible_uv() -> Rect2:
	return Rect2(zoom_centre - Vector2.ONE * 0.5 / zoom, Vector2.ONE / zoom)


## Puts the table's side panel (table_panel.gd) on the war table, at the map's middle; it shows and hides with the
## minimap
func add_table_panel(panel: Node3D) -> void:
	_minimap.add_child(panel)


## Where the player's eyes are when seated in the lord's chair (main.gd, tabletop mode): world, looking at the map
func seat() -> Transform3D:
	var table: Transform3D = global_transform * _table # main.gd moves the room with the screen
	return Transform3D(Basis(), table * SEAT).looking_at(table * Vector3(0.0, TABLE_TOP, 0.0), Vector3.UP)


## The book under the minimap and the tablet beside it (the concept's pop-up book map and minimap)
func _build_book() -> void:
	var leather := StandardMaterial3D.new()
	leather.albedo_color = BOOK_COVER
	leather.roughness = 0.55
	leather.normal_enabled = true
	leather.normal_texture = load(TEX + SETS["fabric"][1])
	leather.normal_scale = 0.4
	leather.uv1_scale = Vector3(6.0, 6.0, 1.0)
	var pages := StandardMaterial3D.new()
	pages.albedo_color = BOOK_PAGES
	pages.roughness = 0.9
	_book_cover = _book_part("BookCover", leather)
	_book_pages = _book_part("BookPages", pages)
	var tablet_shader := Shader.new()
	tablet_shader.code = MINIMAP_SHADER
	var tablet_material := ShaderMaterial.new()
	tablet_material.shader = tablet_shader
	tablet_material.set_shader_parameter("framed", true)
	_tablet = MeshInstance3D.new()
	_tablet.mesh = QuadMesh.new()
	_tablet.material_override = tablet_material
	_tablet.transform = TABLET_POSE
	_tablet.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_tablet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_minimap.add_child(_tablet)
	# its wooden frame and the easel's back leg
	var wood := _material("beam", Vector2(2.0, 2.0))
	for part in [["TabletFrame", Vector3(1.0, 1.0, 0.012), Vector3(0.0, 0.0, -0.007)],
			["TabletLeg", Vector3(0.025, 1.0, 0.012), Vector3(0.0, -0.2, -0.06)]]:
		var mesh := MeshInstance3D.new()
		mesh.name = part[0]
		mesh.mesh = BoxMesh.new()
		(mesh.mesh as BoxMesh).size = part[1]
		mesh.material_override = wood
		mesh.position = part[2]
		mesh.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
		mesh.layers = DECOR
		_tablet.add_child(mesh)


func _book_part(name_: String, material: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = name_
	part.mesh = BoxMesh.new()
	part.material_override = material
	part.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	part.layers = DECOR # made after _ready's layer loop
	_minimap.add_child(part)
	return part


## the panel UV (0..1 across the minimap, not clamped) straight below or above a point in the world: where a hand
## grabs the table
func panel_point(world: Vector3) -> Vector2:
	var local := _minimap.global_transform.affine_inverse() * world
	return Vector2(local.x, local.z) / minimap_size() + Vector2(0.5, 0.5)


## where a ray from `from` along `direction` hits the minimap's plane, in the world; Vector3.INF when it does not
func table_hit(from: Vector3, direction: Vector3) -> Vector3:
	var to_panel := _minimap.global_transform.affine_inverse()
	var start := to_panel * from
	var along := to_panel.basis * direction
	if absf(along.y) < 0.000001 or -start.y / along.y <= 0.0:
		return Vector3.INF
	return _minimap.global_transform * (start + along * (-start.y / along.y))


## where a ray from `from` along `direction` hits the minimap, in map UV (both levels side by side, through the
## zoom); Vector2(-1, -1) when it misses
func table_uv(from: Vector3, direction: Vector3) -> Vector2:
	var world := table_hit(from, direction)
	if world == Vector3.INF:
		return Vector2(-1.0, -1.0)
	var hit := _minimap.global_transform.affine_inverse() * world
	var panel := Vector2(hit.x, hit.z) / minimap_size() + Vector2(0.5, 0.5)
	if panel.x < 0.0 or panel.x > 1.0 or panel.y < 0.0 or panel.y > 1.0:
		return Vector2(-1.0, -1.0)
	var view := visible_uv()
	return view.position + panel * view.size


## the selected hero's path (VcmiData.path_nodes: Vector4i x, y, level, turns) as discs, green for this turn and
## orange after, the end larger; `selected` (a tile, or x < 0 for none) gets a white disc under the hero's sprite
func set_path(nodes: Array, selected: Vector3i, map: Vector3i) -> void:
	var multimesh := _path.multimesh
	multimesh.instance_count = 0
	if map.x <= 0:
		return
	var tiles: Array = []
	if selected.x >= 0:
		tiles.append([selected, 0.8, Color(0.95, 0.95, 0.85)])
	for i in nodes.size():
		var node: Vector4i = nodes[i]
		tiles.append([Vector3i(node.x, node.y, node.z), 0.55 if i == nodes.size() - 1 else 0.3,
				Color(0.25, 0.85, 0.3) if node.w == 0 else Color(0.95, 0.55, 0.1)])
	multimesh.instance_count = tiles.size()
	var tile_size := Vector2(1.0 / (map.x * map.z), 1.0 / map.y) # in the markers' space, 1 per map width
	for i in tiles.size():
		var uv: Vector2 = TableMath.tile_uv(tiles[i][0], map)
		var scale: float = tiles[i][1]
		multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(tile_size.x * scale, 1.0,
				tile_size.y * scale)),
				# the selected hero's mark under the sprites (0.003), the path over them
				Vector3(uv.x - 0.5, 0.001 if i == 0 and selected.x >= 0 else 0.004, uv.y - 0.5)))
		multimesh.set_instance_color(i, tiles[i][2])
		multimesh.set_instance_custom_data(i, Color(uv.x, uv.y, uv.x, uv.y)) # the fog test, as the markers'


## the minimap's centre in the world
func minimap_centre() -> Vector3:
	return _minimap.global_position


## sprites instead of markers, or back (main.gd: by the size of a tile on screen)
## The sprites instead of the markers; `animate`: the cards pop up when the sprites appear
func show_sprites(on: bool, animate := true) -> void:
	if on and not _sprites.visible and animate:
		var tween := create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		for material in _sprite_materials():
			tween.tween_property(material, "shader_parameter/stand", 1.0, 0.45).from(0.0)
	_sprites.visible = on
	_markers.visible = not on


## metres of the minimap panel on the table
func minimap_size() -> Vector2:
	return (_minimap.mesh as PlaneMesh).size


## the object markers, which VcmiData.update_markers fills (main.gd)
func marker_multimesh() -> MultiMesh:
	return _markers.multimesh


## the cards' lean from the table (cards.json)
func set_card_lean(degrees: float) -> void:
	for material in _sprite_materials():
		material.set_shader_parameter("lean", deg_to_rad(degrees))


## the sprites' two passes: all but the standing cards, then the cards
func _sprite_materials() -> Array[ShaderMaterial]:
	var material: ShaderMaterial = _sprites.multimesh.mesh.material
	return [material, material.next_pass]


## the object sprites, which VcmiData.update_sprites fills (main.gd)
func sprite_multimesh() -> MultiMesh:
	return _sprites.multimesh


## the atlas pages and the frame table of VcmiData (atlas_textures, sprite_table); markers off while sprites show.
## precision_check tints sprites red whose instance data lost precision (MILESTONE_3B.md check 2)
func set_sprites(textures: Array, table: Image, texel_scale: int, precision_check: bool) -> void:
	var frames := ImageTexture.create_from_image(table)
	for material in _sprite_materials():
		material.set_shader_parameter("atlas", textures[0])
		material.set_shader_parameter("masks", textures[1])
		material.set_shader_parameter("frames", frames)
		material.set_shader_parameter("precision_check", precision_check)
		material.set_shader_parameter("texel_scale", float(texel_scale))
		material.set_shader_parameter("PAGE", float((textures[0] as Texture2DArray).get_width()))


func _make_environment() -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color.BLACK
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR # only where the lightmap probes do not reach
	e.ambient_light_color = Color(0.1, 0.08, 0.06)
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_exposure = 1.0
	# no glow: on the Quest it moves tonemapping into its own full-screen pass, which also turns foveation off
	return e


## Walls, floor, ceiling, beams and the wooden panelling
func _build_shell() -> void:
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(SIZE.x, SIZE.z)
	floor_mesh.material = _material("floor", Vector2(SIZE.x, SIZE.z) / 2.5)
	_mesh("Floor", floor_mesh, Transform3D(Basis(), Vector3(0.0, 0.0, MIDDLE)))
	var ceiling := PlaneMesh.new()
	ceiling.size = Vector2(SIZE.x, SIZE.z)
	ceiling.material = _material("planks", Vector2(SIZE.x, SIZE.z) / 2.0, Vector2.ZERO, Color(0.7, 0.62, 0.55))
	_mesh("Ceiling", ceiling, Transform3D(Basis(Vector3.RIGHT, PI), Vector3(0.0, SIZE.y, MIDDLE)))
	# side and front walls, each from its left end seen from inside
	_panel("WallLeft", Vector3(-HALF, 0.0, FRONT), Vector3.BACK * -1.0, Vector2(SIZE.z, SIZE.y), "stone", 3.2)
	_panel("WallRight", Vector3(HALF, 0.0, BACK), Vector3.BACK, Vector2(SIZE.z, SIZE.y), "stone", 3.2)
	_panel("WallFront", Vector3(HALF, 0.0, FRONT), Vector3.LEFT, Vector2(SIZE.x, SIZE.y), "stone", 3.2)
	# the back wall around the two windows
	var x0 := WINDOW_X + WINDOW.position.x
	var x1 := WINDOW_X + WINDOW.end.x
	var pieces := [Rect2(-HALF, 0.0, HALF - x1, SIZE.y), Rect2(-x0, 0.0, 2.0 * x0, SIZE.y), Rect2(x1, 0.0, HALF - x1,
			SIZE.y)]
	for side in [-1.0, 1.0]:
		var left := x0 if side > 0.0 else -x1
		pieces.append(Rect2(left, 0.0, WINDOW.size.x, WINDOW.position.y))
		pieces.append(Rect2(left, WINDOW.end.y, WINDOW.size.x, SIZE.y - WINDOW.end.y))
	for i in pieces.size():
		var piece: Rect2 = pieces[i]
		_panel("WallBack%d" % i, Vector3(piece.position.x, piece.position.y, BACK), Vector3.RIGHT, piece.size, "stone",
				3.2, Vector2(piece.position.x + HALF, piece.position.y))
	# dark oak panelling to 1.1 m with a rail, on the walls around the head
	var wood := Color(0.75, 0.6, 0.5)
	_panel("PanelLeft", Vector3(-HALF + 0.02, 0.0, FRONT), Vector3.FORWARD, Vector2(SIZE.z, 1.1), "beam", 1.4,
			Vector2.ZERO, wood)
	_panel("PanelRight", Vector3(HALF - 0.02, 0.0, BACK), Vector3.BACK, Vector2(SIZE.z, 1.1), "beam", 1.4, Vector2.ZERO,
			wood)
	_panel("PanelFront", Vector3(HALF, 0.0, FRONT - 0.02), Vector3.LEFT, Vector2(SIZE.x, 1.1), "beam", 1.4,
			Vector2.ZERO, wood)
	# a course of dressed stones where the back wall meets the floor
	_box("Plinth", Vector3(SIZE.x, 0.28, 0.1), Vector3(0.0, 0.14, BACK + 0.05), _material("stone", Vector2.ONE * 0.5,
			Vector2.ZERO, Color(0.8, 0.75, 0.7), true))
	var beam := _material("beam", Vector2.ONE * 0.6, Vector2.ZERO, Color(0.6, 0.48, 0.4), true)
	_box("RailLeft", Vector3(0.06, 0.08, SIZE.z), Vector3(-HALF + 0.03, 1.12, MIDDLE), beam)
	_box("RailRight", Vector3(0.06, 0.08, SIZE.z), Vector3(HALF - 0.03, 1.12, MIDDLE), beam)
	_box("RailFront", Vector3(SIZE.x, 0.08, 0.06), Vector3(0.0, 1.12, FRONT - 0.03), beam)
	# ceiling beams across the room and wall plates along the side walls
	for i in 5:
		_box("Beam%d" % i, Vector3(SIZE.x, 0.32, 0.28), Vector3(0.0, SIZE.y - 0.16, BACK + 1.0 + 2.0 * i), beam)
	for side in [-1.0, 1.0]:
		_box("WallPlate%d" % int(side), Vector3(0.3, 0.3, SIZE.z), Vector3(side * (HALF - 0.15), SIZE.y - 0.15, MIDDLE),
				beam)
	# a red rug with a golden border in front of the head, flat on the floor
	var rug := Rect2(-1.6, -3.0, 3.2, 4.2) # x, z
	var carpet := PlaneMesh.new()
	carpet.size = rug.size
	carpet.material = _material("carpet", rug.size / 1.2, Vector2.ZERO, Color(0.85, 0.75, 0.75))
	_mesh("Rug", carpet, Transform3D(Basis(), Vector3(rug.get_center().x, 0.006, rug.get_center().y)))
	var gold_cloth := _material("fabric", Vector2(8.0, 0.25), Vector2.ZERO, Color(0.75, 0.5, 0.16))
	for i in 4:
		var long := i < 2
		var border := PlaneMesh.new()
		border.size = Vector2(rug.size.x + 0.24, 0.12) if long else Vector2(0.12, rug.size.y)
		border.material = gold_cloth
		var at := Vector3(rug.get_center().x, 0.008, rug.position.y - 0.06 if i == 0 else rug.end.y + 0.06) if long \
			else Vector3(rug.position.x - 0.06 if i == 2 else rug.end.x + 0.06, 0.008, rug.get_center().y)
		_mesh("RugBorder%d" % i, border, Transform3D(Basis(), at))


## Two tall windows in the back wall with stone mullions and the night sky behind them
func _build_windows() -> void:
	var stone := _material("stone", Vector2.ONE * 0.4, Vector2.ZERO, Color(0.85, 0.8, 0.75), true)
	var sky := ShaderMaterial.new()
	sky.shader = Shader.new()
	sky.shader.code = SKY_SHADER
	for side in [-1, 1]:
		var cx: float = side * WINDOW_X
		var x0 := cx + WINDOW.position.x
		var x1 := cx + WINDOW.end.x
		var tag := "L" if side < 0 else "R"
		var depth := Vector2(REVEAL, WINDOW.size.y)
		_panel("Jamb%sA" % tag, Vector3(x0, WINDOW.position.y, BACK), Vector3.FORWARD, depth, "stone", 3.2)
		_panel("Jamb%sB" % tag, Vector3(x1, WINDOW.position.y, BACK - REVEAL), Vector3.BACK, depth, "stone", 3.2)
		var across := Vector2(WINDOW.size.x, REVEAL)
		_flat("Sill%s" % tag, Vector3(cx, WINDOW.position.y, BACK - REVEAL / 2.0), Vector3.UP, across, stone)
		_flat("Head%s" % tag, Vector3(cx, WINDOW.end.y, BACK - REVEAL / 2.0), Vector3.DOWN, across, stone)
		var glass := QuadMesh.new()
		glass.size = WINDOW.size
		glass.material = sky
		var pane := _mesh("Sky%s" % tag, glass, Transform3D(Basis(), Vector3(cx, WINDOW.get_center().y,
				BACK - REVEAL + 0.05)))
		pane.gi_mode = GeometryInstance3D.GI_MODE_DISABLED # not a wall to the bake: the moonlight comes through
		_box("Mullion%s" % tag, Vector3(0.09, WINDOW.size.y, 0.12), Vector3(cx, WINDOW.get_center().y,
				BACK - REVEAL + 0.15), stone)
		_box("Transom%s" % tag, Vector3(WINDOW.size.x, 0.09, 0.12), Vector3(cx,
				WINDOW.position.y + WINDOW.size.y * 0.62, BACK - REVEAL + 0.15), stone)
		_box("Lintel%s" % tag, Vector3(WINDOW.size.x + 0.3, 0.22, 0.12), Vector3(cx, WINDOW.end.y + 0.11, BACK + 0.06),
				stone)
		_box("SillStone%s" % tag, Vector3(WINDOW.size.x + 0.3, 0.1, 0.18), Vector3(cx, WINDOW.position.y - 0.05,
				BACK + 0.09), stone)


## The fireplace in the left wall: hearth, jambs, mantel, chimney breast, logs, embers and the fire
func _build_fireplace() -> void:
	var stone := _material("stone", Vector2.ONE * 0.45, Vector2.ZERO, Color(0.95, 0.88, 0.8), true)
	var soot := _material("stone", Vector2.ONE * 0.45, Vector2.ZERO, Color(0.18, 0.15, 0.13), true)
	var wall := -HALF
	_box("Hearth", Vector3(0.85, 0.12, 2.8), Vector3(wall + 0.425, 0.06, FIRE_Z), stone)
	for side in [-1.0, 1.0]:
		_box("Jamb%d" % int(side), Vector3(0.6, 1.3, 0.5), Vector3(wall + 0.3, 0.77, FIRE_Z + side * 0.85), stone)
	_box("FireLintel", Vector3(0.65, 0.3, 2.3), Vector3(wall + 0.325, 1.57, FIRE_Z), stone)
	_box("Mantel", Vector3(0.8, 0.08, 2.7), Vector3(wall + 0.4, 1.76, FIRE_Z), _material("beam", Vector2.ONE * 0.6,
			Vector2.ZERO, Color(0.5, 0.38, 0.3), true))
	_box("Chimney", Vector3(0.45, SIZE.y - 1.8, 2.1), Vector3(wall + 0.225, 1.8 + (SIZE.y - 1.8) / 2.0, FIRE_Z), stone)
	_box("Firebox", Vector3(0.08, 1.3, 1.2), Vector3(wall + 0.06, 0.77, FIRE_Z), soot)
	var embers := PlaneMesh.new()
	embers.size = Vector2(0.45, 0.95)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.05, 0.03, 0.02)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.32, 0.06)
	glow.emission_energy_multiplier = 2.5
	var noise := NoiseTexture2D.new()
	noise.width = 128
	noise.height = 256
	noise.noise = FastNoiseLite.new()
	noise.noise.frequency = 0.05
	glow.emission_texture = noise
	embers.material = glow
	_mesh("Embers", embers, Transform3D(Basis(), Vector3(wall + 0.33, 0.125, FIRE_Z)))
	# logs on the embers
	var bark := Color(0.16, 0.1, 0.06)
	var logs := []
	for i in 3:
		var log_mesh := CylinderMesh.new()
		log_mesh.top_radius = 0.065 - i * 0.008
		log_mesh.bottom_radius = log_mesh.top_radius
		log_mesh.height = 0.75 - i * 0.1
		log_mesh.radial_segments = 10
		var turn := Basis(Vector3.RIGHT, PI / 2.0).rotated(Vector3.UP, [0.15, -0.2, 0.05][i])
		logs.append([log_mesh, Transform3D(turn, Vector3(wall + 0.25 + i * 0.1, 0.19 + (0.1 if i == 2 else 0.0),
				FIRE_Z + [-0.1, 0.12, 0.0][i])), bark])
	var log_material := StandardMaterial3D.new()
	log_material.vertex_color_use_as_albedo = true
	log_material.roughness = 0.9
	_merged("Logs", logs, log_material)
	for flame in [[-0.32, 0.3, 0.55], [-0.1, 0.4, 0.75], [0.12, 0.38, 0.65], [0.32, 0.28, 0.5], [0.0, 0.5, 0.9]]:
		_flames.append([Vector3(wall + 0.3, 0.16, FIRE_Z + flame[0]), flame[1], flame[2], 1.6])
	# candles on the mantel, a shield and crossed weapons above it
	var wax := []
	for z in [-1.15, -0.95, 0.95, 1.15]:
		var height := 0.22 if absf(z) > 1.0 else 0.3
		var candle := CylinderMesh.new()
		candle.top_radius = 0.025
		candle.bottom_radius = 0.028
		candle.height = height
		candle.radial_segments = 10
		var at := Vector3(wall + 0.55, 1.8 + height / 2.0, FIRE_Z + z)
		wax.append([candle, Transform3D(Basis(), at), Color(0.9, 0.85, 0.72)])
		_flames.append([at + Vector3(0.0, height / 2.0, 0.0), 0.04, 0.11, 1.3])
	var wax_material := StandardMaterial3D.new()
	wax_material.vertex_color_use_as_albedo = true
	wax_material.roughness = 0.5
	_merged("Candles", wax, wax_material)
	var face := wall + 0.45
	_prop("Axe", "polyhaven/wooden_axe/wooden_axe.gltf", Vector3(face + 0.03, 2.25, FIRE_Z), Basis(Vector3.UP,
			PI / 2.0).rotated(Vector3.RIGHT, 0.6), 1.5)
	_prop("Mace", "polyhaven/ornate_medieval_mace/ornate_medieval_mace.gltf", Vector3(face + 0.03, 2.25, FIRE_Z),
			Basis(Vector3.UP, PI / 2.0).rotated(Vector3.RIGHT, -0.6), 1.5)
	_prop("Shield", "polyhaven/kite_shield/kite_shield.gltf", Vector3(face + 0.08, 2.15, FIRE_Z), Basis(Vector3.UP,
			PI / 2.0), 0.8)


## Banners in the eight player colours high on the side walls, and a tapestry above the screen
func _build_banners() -> void:
	var cloth := SurfaceTool.new()
	cloth.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trim := []
	var gold := Color(0.95, 0.7, 0.3)
	var spots := [] # [left end on the wall, along the wall, colour, size, tail]
	for i in 8:
		var side := -1.0 if i < 4 else 1.0
		var z: float = [-5.0, -3.4, 1.0, 2.6][i % 4]
		var along := Vector3.FORWARD if side < 0.0 else Vector3.BACK
		spots.append([Vector3(side * (HALF - 0.04), 4.45, z) - along * 0.45, along, PLAYER_COLOURS[i] * 1.5,
				Vector2(0.9, 2.1), 0.35])
	spots.append([Vector3(-1.5, 4.8, BACK + 0.04), Vector3.RIGHT, PLAYER_COLOURS[0] * 1.5, Vector2(3.0, 1.25), 0.0])
	for i in spots.size():
		var spot: Array = spots[i]
		var top: Vector3 = spot[0]
		var along: Vector3 = spot[1]
		var size: Vector2 = spot[3]
		var normal := along.cross(Vector3.UP)
		_banner(cloth, top, along, normal, size, spot[4], spot[2], Rect2((i % 3) / 3.0, (i / 3) / 3.0, 1.0 / 3.0,
				1.0 / 3.0))
		# the golden pole, its knobs and an emblem
		var pole := CylinderMesh.new()
		pole.top_radius = 0.022
		pole.bottom_radius = 0.022
		pole.height = size.x + 0.2
		pole.radial_segments = 8
		var centre := top + along * size.x / 2.0 + normal * 0.03
		# the cylinder axis along the wall
		trim.append([pole, Transform3D(Basis(along.cross(normal), along, normal), centre), gold])
		for end in [-1.0, 1.0]:
			var knob := SphereMesh.new()
			knob.radius = 0.045
			knob.height = 0.09
			knob.radial_segments = 8
			knob.rings = 4
			trim.append([knob, Transform3D(Basis(), centre + along * end * (size.x / 2.0 + 0.1)), gold])
		var emblem := BoxMesh.new()
		emblem.size = Vector3(0.22, 0.22, 0.012) * (2.2 if spot[4] == 0.0 else 1.0)
		var emblem_at := top + along * size.x / 2.0 + Vector3.DOWN * size.y * 0.4 + normal * 0.012
		trim.append([emblem, Transform3D(Basis(along, Vector3.UP, normal) * Basis(Vector3.FORWARD, PI / 4.0),
				emblem_at), gold])
		var stripe := BoxMesh.new()
		stripe.size = Vector3(size.x, 0.05, 0.01)
		trim.append([stripe, Transform3D(Basis(along, Vector3.UP, normal),
				top + along * size.x / 2.0 + Vector3.DOWN * 0.12 + normal * 0.01), gold])
	cloth.generate_tangents()
	var mesh := cloth.commit()
	mesh.lightmap_size_hint = Vector2i(384, 384)
	var fabric := _material("fabric", Vector2.ONE)
	fabric.vertex_color_use_as_albedo = true
	_mesh("Banners", mesh, Transform3D(), fabric)
	var metal := StandardMaterial3D.new()
	metal.vertex_color_use_as_albedo = true
	metal.metallic = 1.0
	metal.roughness = 0.35
	_merged("BannerGold", trim, metal)


## A banner of `size` hanging down from `top` along the wall, with a swallowtail of `tail` metres, into `cloth`
## with its lightmap UVs in `cell`
func _banner(cloth: SurfaceTool, top: Vector3, along: Vector3, normal: Vector3, size: Vector2, tail: float,
		colour: Color, cell: Rect2) -> void:
	var rows := 8
	var grid := []
	for r in rows + 1:
		var row := []
		for c in 3:
			var u := c / 2.0
			var v := r / float(rows)
			var drop := v * size.y
			if r == rows and c == 1:
				drop -= tail
			var ripple := sin(u * TAU * 1.5 + v * 2.0) * 0.025 * (0.3 + v)
			row.append([top + along * u * size.x + Vector3.DOWN * drop + normal * ripple, Vector2(u * size.x,
					drop) / 0.6, cell.position + Vector2(u, drop / size.y) * cell.size * 0.9])
		grid.append(row)
	for r in rows:
		for c in 2:
			for k in [[r, c], [r, c + 1], [r + 1, c + 1], [r, c], [r + 1, c + 1], [r + 1, c]]:
				var vertex: Array = grid[k[0]][k[1]]
				cloth.set_color(colour)
				cloth.set_normal(normal)
				cloth.set_uv(vertex[1])
				cloth.set_uv2(vertex[2])
				cloth.add_vertex(vertex[0])


## Furniture and props: war table, lord's chair, bookshelves, weapon rack, chest, barrels, door, chandelier, torches
func _build_props() -> void:
	# long side to the user, the nearest corner at 56 degrees: outside every screen size main.gd allows (preview.gd
	# checks)
	var table := Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3(2.6, 0.0, -0.3))
	_table = table
	_prop("WarTable", "meshy/war_table.gltf", table.origin, table.basis)
	# castles, towers and flags of four players on the corners of the campaign map (lit by the probes, too small to
	# bake)
	for piece in [["building_castle_red", Vector3(-0.66, 0.0, 0.36), 0.05, 0.0], ["building_castle_blue", Vector3(0.68,
			0.0, -0.34), 0.05, 2.6],
			["building_tower_A_green", Vector3(0.66, 0.0, 0.38), 0.08, 1.0], ["building_tower_A_yellow", Vector3(-0.64,
					0.0, -0.38), 0.08, 4.0],
			# the four players' flags in a row along the far edge, behind the map
			["flag_red", Vector3(-0.39, 0.0, -0.45), 0.55, 0.3], ["flag_blue", Vector3(0.13, 0.0, -0.45), 0.55, 2.0],
			["flag_green", Vector3(0.39, 0.0, -0.45), 0.55, 1.2], ["flag_yellow", Vector3(-0.13, 0.0, -0.45), 0.55, 3.5]]:
		# the tower model starts above its (left out) base
		var lift: float = -1.278 * piece[2] if "tower" in piece[0] else 0.0
		var at: Vector3 = table * (piece[1] + Vector3(0.0, TABLE_TOP + lift, 0.0))
		var figure := _prop(piece[0].capitalize().replace(" ", ""), "kaykit/%s.gltf" % piece[0], at,
				table.basis * Basis(Vector3.UP, piece[3]), piece[2])
		for mesh in figure.find_children("*", "GeometryInstance3D", true, false):
			mesh.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	# two candles on the map side next to the chair, and their light on the map
	var wax := []
	for corner in [Vector3(-0.78, 0.0, -0.52), Vector3(0.78, 0.0, -0.52)]:
		var candle := CylinderMesh.new()
		candle.top_radius = 0.03
		candle.bottom_radius = 0.035
		candle.height = 0.2
		candle.radial_segments = 10
		var at: Vector3 = table * (corner + Vector3(0.0, TABLE_TOP + 0.1, 0.0))
		wax.append([candle, Transform3D(Basis(), at), Color(0.9, 0.85, 0.72)])
		_flames.append([at + Vector3(0.0, 0.1, 0.0), 0.045, 0.12, 1.3])
	var wax_material := StandardMaterial3D.new()
	wax_material.vertex_color_use_as_albedo = true
	wax_material.roughness = 0.5
	_merged("TableCandles", wax, wax_material)
	_table_light = table * Vector3(0.0, TABLE_TOP + 0.6, -0.3)
	_prop("LordsChair", "meshy/lords_chair.gltf", table * Vector3(0.0, 0.0, CHAIR_Z), table.basis * Basis(Vector3.UP, PI))
	_prop("WeaponRack", "meshy/weapon_rack.gltf", Vector3(HALF - 0.35, 0.0, 0.3), Basis(Vector3.UP, -PI / 2.0))
	for i in 2:
		_prop("Bookshelf%d" % i, "polyhaven/wooden_bookshelf_worn/wooden_bookshelf_worn.gltf", _bookshelf(i).origin,
				_bookshelf(i).basis)
	_prop("Chest", "meshy/treasure_chest.gltf", Vector3(-2.3, 0.0, FRONT - 0.55), Basis(Vector3.UP, PI))
	_prop("Door", "polyhaven/large_castle_door/large_castle_door.gltf", Vector3(0.0, 0.0, FRONT - 0.02),
			Basis(Vector3.UP, PI))
	for barrel in [[Vector3(-HALF + 0.5, 0.0, FRONT - 0.55), 0.3], [Vector3(-HALF + 1.3, 0.0, FRONT - 0.5), 1.2],
			[Vector3(HALF - 0.55, 0.0, FRONT - 0.6), 2.0]]:
		_prop("Barrel%d" % int(barrel[1] * 10), "polyhaven/wine_barrel_01/wine_barrel_01.gltf", barrel[0],
				Basis(Vector3.UP, barrel[1]))
	_prop("Chandelier", "polyhaven/Chandelier_02/Chandelier_02.gltf", Vector3(0.0, SIZE.y - 1.15, -1.5), Basis(), 1.35)
	for torch in _torches():
		var side: float = signf(torch.x)
		_prop("Torch%d%d" % [int(side), int(torch.z)], "meshy/wall_torch.gltf", torch, Basis(Vector3.UP,
				-side * PI / 2.0))
		_flames.append([torch + Vector3(-side * 0.075, 0.43, 0.0), 0.13, 0.32, 1.5])


## Leather-bound books on the two bookshelves, merged into one mesh
func _build_books() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1803 # the same books on every run
	var boards := [0.11, 0.39, 0.67, 0.96, 1.28, 1.66, 2.02] # tops of the shelf boards (wooden_bookshelf_worn)
	var leather := [Color(0.3, 0.05, 0.03), Color(0.14, 0.08, 0.04), Color(0.05, 0.14, 0.07), Color(0.05, 0.07, 0.2),
		Color(0.35, 0.2, 0.08), Color(0.42, 0.3, 0.14), Color(0.2, 0.03, 0.09)]
	var parts := []
	for i in 2:
		var shelf := _bookshelf(i)
		for level in boards.size() - 1:
			var clearance: float = boards[level + 1] - boards[level] - 0.03
			var x := -0.62
			while true:
				if rng.randf() < 0.06:
					x += rng.randf_range(0.08, 0.25) # a gap
				var thickness := rng.randf_range(0.025, 0.065)
				if x + thickness > 0.62:
					break
				var height := minf(rng.randf_range(0.16, 0.27), clearance)
				var depth := rng.randf_range(0.15, 0.22)
				var book := BoxMesh.new()
				book.size = Vector3(thickness, height, depth)
				var at := Vector3(x + thickness / 2.0, boards[level] + height / 2.0, 0.26 - depth / 2.0)
				var colour: Color = leather[rng.randi() % leather.size()] * rng.randf_range(0.7, 1.3)
				parts.append([book, shelf * Transform3D(Basis(), at), colour])
				if rng.randf() < 0.5: # a gilt band across the spine
					var band := BoxMesh.new()
					band.size = Vector3(thickness + 0.002, 0.012, 0.004)
					parts.append([band, shelf * Transform3D(Basis(), at + Vector3(0.0, height * 0.3, depth / 2.0)),
							Color(0.55, 0.4, 0.12)])
				x += thickness + 0.002
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.6
	_merged("Books", parts, material)


func _bookshelf(i: int) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3(HALF - 0.3, 0.0, -4.9 + i * 1.4))


## Public-domain paintings in gilded frames
func _build_paintings() -> void:
	var frames := []
	for i in PAINTINGS.size():
		var painting: Array = PAINTINGS[i]
		var texture: Texture2D = load(ROOM + "paintings/" + painting[0])
		var size := Vector2(painting[3], painting[3] * texture.get_height() / float(texture.get_width()))
		var normal: Vector3 = painting[2]
		var basis := Basis(Vector3.UP.cross(normal), Vector3.UP, normal)
		var centre: Vector3 = painting[1]
		var canvas := QuadMesh.new()
		canvas.size = size
		var oil := StandardMaterial3D.new()
		oil.albedo_texture = texture
		oil.roughness = 0.5
		canvas.material = oil
		_mesh("Painting%d" % i, canvas, Transform3D(basis, centre))
		for ring in [[0.11, 0.06, Color(0.8, 0.58, 0.24)], [0.03, 0.075, Color(0.35, 0.22, 0.08)]]:
			var width: float = ring[0]
			var depth: float = ring[1]
			var inner := 0.0 if width > 0.05 else -0.03 # the thin dark lip sits just inside the gilt
			for side in 4:
				var vertical := side >= 2
				var bar := BoxMesh.new()
				# the gilt meets at the corners, the lip stays inside it
				var reach := 2.0 * width if inner == 0.0 else 0.0
				bar.size = Vector3(width, size.y + reach, depth) if vertical else Vector3(size.x + reach, width, depth)
				var offset := Vector3((size.x + width) / 2.0 + inner, 0.0, 0.0) if vertical else Vector3(0.0,
						(size.y + width) / 2.0 + inner, 0.0)
				if side % 2 == 1:
					offset = -offset
				frames.append([bar, Transform3D(basis, centre + basis * (offset + Vector3(0.0, 0.0,
						depth / 2.0 - 0.025))), ring[2]])
	var gilt := StandardMaterial3D.new()
	gilt.vertex_color_use_as_albedo = true
	gilt.metallic = 1.0
	gilt.roughness = 0.38
	_merged("Frames", frames, gilt)


## Living light: embers above the fire, dust in the moonlight, and faint light shafts from the windows
func _build_effects() -> void:
	var embers := _particles("EmberSparks", 64, 1.8, Vector3(-HALF + 0.35, 0.3, FIRE_Z), Vector3(0.12, 0.05, 0.4),
			Color(4.0, 1.5, 0.35), 0.022)
	var process: ParticleProcessMaterial = embers.process_material
	process.direction = Vector3(0.35, 1.0, 0.0)
	process.spread = 25.0
	process.initial_velocity_min = 0.25
	process.initial_velocity_max = 0.6
	process.gravity = Vector3(0.0, 0.12, 0.0)
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.4
	process.turbulence_noise_scale = 2.0
	for side in [-1.0, 1.0]:
		var dust := _particles("Dust%d" % int(side), 40, 9.0, Vector3(side * 3.6, 1.5, -4.3), Vector3(0.6, 1.2, 1.3),
				Color(0.6, 0.7, 1.0), 0.009)
		var drift: ParticleProcessMaterial = dust.process_material
		drift.gravity = Vector3(0.0, -0.004, 0.0)
		drift.initial_velocity_min = 0.0
		drift.initial_velocity_max = 0.02
		drift.spread = 180.0
		drift.turbulence_enabled = true
		drift.turbulence_noise_strength = 0.05
		drift.turbulence_noise_scale = 1.0
	# the shafts: from the top and bottom edge of each window down along the moonlight to the floor
	var shaft := ShaderMaterial.new()
	shaft.shader = Shader.new()
	shaft.shader.code = SHAFT_SHADER
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		var direction := (_moon_target(side) - _moon_position(side)).normalized()
		for edge_y in [WINDOW.end.y, WINDOW.position.y]:
			var corners := []
			for edge_x in [WINDOW.position.x, WINDOW.end.x]:
				var top := Vector3(side * WINDOW_X + edge_x, edge_y, BACK)
				var length := (top.y - 0.02) / -direction.y # to the floor
				while Vector2(top.x + direction.x * length, top.z + direction.z * length).length() < 4.3:
					length -= 0.05 # ends (faded out) before it could pass in front of a screen up to 4 m away
				corners.append([top, top + direction * length])
			var quad := [[corners[0][0], Vector2(0, 0)], [corners[1][0], Vector2(1, 0)], [corners[1][1], Vector2(1, 1)],
					[corners[0][1], Vector2(0, 1)]]
			for k in [0, 1, 2, 0, 2, 3]:
				surface.set_uv(quad[k][1])
				surface.add_vertex(quad[k][0])
	var shafts := _mesh("Shafts", surface.commit(), Transform3D(), shaft)
	shafts.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	shafts.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _moon_position(side: float) -> Vector3:
	return Vector3(side * WINDOW_X * 1.15, 4.6, BACK - 1.5)


func _moon_target(side: float) -> Vector3:
	return Vector3(side * WINDOW_X * 0.6, 0.0, -2.8)


## Small additive glowing particles rising or drifting in a box
func _particles(name_: String, amount: int, lifetime: float, at: Vector3, extents: Vector3, colour: Color,
		size: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.preprocess = lifetime
	particles.position = at
	particles.visibility_aabb = AABB(-extents - Vector3.ONE, 2.0 * extents + Vector3(2.0, 3.0, 2.0))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = extents
	process.scale_min = 0.5
	process.scale_max = 1.2
	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	fade.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	fade.add_point(0.15, Color.WHITE)
	fade.add_point(0.7, Color(1.0, 1.0, 1.0, 0.6))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	process.color_ramp = ramp
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * size
	var glow := ShaderMaterial.new()
	glow.shader = Shader.new()
	glow.shader.code = SPARK_SHADER
	glow.set_shader_parameter("tint", colour)
	glow.set_shader_parameter("dot_texture", _spark())
	quad.material = glow
	particles.draw_pass_1 = quad
	return _add(particles, name_)


## a soft round dot
func _spark() -> GradientTexture2D:
	if _spark_texture == null:
		_spark_texture = GradientTexture2D.new()
		_spark_texture.width = 32
		_spark_texture.height = 32
		_spark_texture.fill = GradientTexture2D.FILL_RADIAL
		_spark_texture.fill_from = Vector2(0.5, 0.5)
		_spark_texture.fill_to = Vector2(0.5, 0.0)
		var dot := Gradient.new()
		dot.set_color(0, Color.WHITE)
		dot.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		_spark_texture.gradient = dot
	return _spark_texture


## Wall torch positions (origin at the bottom of the bracket, on the wall plate)
func _torches() -> Array:
	var torches := []
	for z in [-4.2, 1.8]: # either side of the fireplace's banners
		torches.append(Vector3(-HALF + TORCH_PLATE, 1.75, z))
	for z in [-2.66, 1.8]: # between the bookshelves and the painting, and past it
		torches.append(Vector3(HALF - TORCH_PLATE, 1.75, z))
	for x in [-1.55, 1.55]:
		torches.append(Vector3(x, 1.75, FRONT - TORCH_PLATE))
	return torches


func _build_lights() -> void:
	# all baked: a dynamic light costs every lit pixel on the Quest (up to 1.8 ms for the former flicker lights); the
	# flames flicker in their shader
	_light("FireLight", Vector3(-HALF + 0.75, 0.6, FIRE_Z), Color(1.0, 0.5, 0.22), 5.0, 8.0, 0.4)
	for torch in _torches():
		var side := signf(torch.x) if absf(torch.x) > HALF - 1.0 else 0.0
		var out := Vector3(-side * 0.3, 0.5, -0.3 if side == 0.0 else 0.0)
		var tag := "%d%d" % [int(signf(torch.x)), int(torch.z)]
		_light("TorchLight" + tag, torch + out, FLAME, 2.0 if torch.z < -2.0 else 1.6, 6.0, 0.15)
	for side in [-1.0, 1.0]: # moonlight scattered into the room: cool fill in the shadows
		_light("MoonFill%d" % int(side), Vector3(side * WINDOW_X, 2.6, BACK + 1.2), Color(0.35, 0.45, 0.9), 0.6, 9.0,
				1.5)
	_light("TableLight", _table_light, FLAME, 0.9, 3.5, 0.3)
	# a reading candle over the near edge, where the player sits: lights the faces of the side panel, the book and the
	# figures (the baked lights stand behind them); real time, on the decor layer only
	var reading := OmniLight3D.new()
	reading.name = "ReadingLight"
	reading.light_color = FLAME
	reading.light_energy = 0.8
	reading.omni_range = 1.6
	reading.light_cull_mask = DECOR
	reading.light_bake_mode = Light3D.BAKE_DISABLED # not in the lightmap: the room's baked light is as before
	reading.position = _table * Vector3(0.0, TABLE_TOP + 0.55, 0.55)
	add_child(reading)
	# a soft wash, the screen stays brighter
	_light("TapestryLight", Vector3(0.0, 4.75, BACK + 0.9), FLAME, 0.7, 2.5, 0.3)
	_light("ChandelierLight", Vector3(0.0, SIZE.y - 1.25, -1.5), Color(1.0, 0.72, 0.45), 3.2, 8.0, 0.8)
	for side in [-1.0, 1.0]:
		var moon := SpotLight3D.new()
		moon.light_color = Color(0.4, 0.55, 1.0)
		moon.light_energy = 6.0
		moon.spot_range = 12.0
		moon.spot_angle = 18.0
		moon.shadow_enabled = Engine.is_editor_hint() # shadows only in the bake (bake_room.gd runs in the editor)
		moon.light_cull_mask = LAYER
		moon.light_size = 0.2
		moon.light_bake_mode = Light3D.BAKE_STATIC
		var from := _moon_position(side)
		moon.position = from
		_add(moon, "Moon%d" % int(side))
		moon.look_at_from_position(from, _moon_target(side))


## A baked light: static objects get it from the lightmap, the decor props from its probes
func _light(name_: String, at: Vector3, colour: Color, energy: float, range_: float, size: float) -> void:
	var light := OmniLight3D.new()
	light.light_color = colour
	light.light_energy = energy
	light.omni_range = range_
	light.omni_attenuation = 1.0
	light.position = at
	light.light_bake_mode = Light3D.BAKE_STATIC
	light.light_cull_mask = LAYER
	light.shadow_enabled = Engine.is_editor_hint() # shadows only in the bake (bake_room.gd runs in the editor)
	light.light_size = size
	_add(light, name_)


## All flames in one mesh, one draw call: four vertices at each flame base, spread by the flame shader
func _add_flames() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	for i in _flames.size():
		var flame: Array = _flames[i]
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
			surface.set_uv(corner)
			surface.set_custom(0, Color(flame[1], flame[2], i * 0.137, flame[3]))
			surface.add_vertex(flame[0])
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = FLAME_SHADER
	var flames := _mesh("Flames", surface.commit(), Transform3D(), material)
	flames.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	flames.extra_cull_margin = 1.0 # the shader moves the vertices up to a flame size away
	flames.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _add(node: Node, name_: String) -> Node:
	node.name = name_
	add_child(node)
	return node


func _mesh(name_: String, mesh: Mesh, at: Transform3D, material: Material = null) -> MeshInstance3D:
	if mesh is PrimitiveMesh:
		mesh.add_uv2 = true # for the lightmap
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.transform = at
	if material != null:
		instance.material_override = material
	return _add(instance, name_)


## A wall-like quad from `start` (its lower left corner seen from the front) along `along`, the texture continuous
## across pieces
func _panel(name_: String, start: Vector3, along: Vector3, size: Vector2, texture_set: String, tile: float,
		uv_start := Vector2.ZERO, tint := Color.WHITE) -> void:
	var quad := QuadMesh.new()
	quad.size = size
	quad.material = _material(texture_set, size / tile, Vector2(uv_start.x, -(uv_start.y + size.y)) / tile, tint)
	var normal := along.cross(Vector3.UP)
	_mesh(name_, quad, Transform3D(Basis(along, Vector3.UP, normal),
			start + along * size.x / 2.0 + Vector3.UP * size.y / 2.0))


## A horizontal quad centred at `at` facing `facing` (up or down)
func _flat(name_: String, at: Vector3, facing: Vector3, size: Vector2, material: Material) -> void:
	var quad := PlaneMesh.new()
	quad.size = size
	quad.material = material
	_mesh(name_, quad, Transform3D(Basis() if facing.y > 0.0 else Basis(Vector3.RIGHT, PI), at))


func _box(name_: String, size: Vector3, at: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	_mesh(name_, box, Transform3D(Basis(), at))


## Small decoration merged into one mesh of vertex colours; lit by the lightmap probes, not baked
func _merged(name_: String, parts: Array, material: Material) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		var arrays: Array = part[0].get_mesh_arrays()
		var xform: Transform3D = part[1]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for i: int in arrays[Mesh.ARRAY_INDEX]:
			surface.set_color(part[2])
			surface.set_normal((xform.basis * normals[i]).normalized())
			surface.set_uv(uvs[i])
			surface.add_vertex(xform * vertices[i])
	var instance := _mesh(name_, surface.commit(), Transform3D(), material)
	instance.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC


## An imported model (meshes with lightmap UVs from its import settings)
func _prop(name_: String, path: String, at: Vector3, basis: Basis, scale_ := 1.0) -> Node3D:
	var prop: Node3D = load(ROOM + path).instantiate()
	prop.transform = Transform3D(basis.scaled(Vector3.ONE * scale_), at)
	return _add(prop, name_)


## A tiling PBR material; `triplanar` maps it in object space at `uv_scale.x` repeats per metre.
## Large surfaces get a faint dirt variation over their lightmap UVs, so the tiling does not show.
func _material(texture_set: String, uv_scale: Vector2, uv_offset := Vector2.ZERO, tint := Color.WHITE,
		triplanar := false) -> BaseMaterial3D:
	var maps: Array = SETS[texture_set]
	# an ORM material without its texture would read occlusion 0: black under baked light
	var material: BaseMaterial3D = ORMMaterial3D.new() if maps[2] != "" else StandardMaterial3D.new()
	material.albedo_texture = load(TEX + maps[0])
	material.albedo_color = tint
	material.normal_enabled = true
	material.normal_texture = load(TEX + maps[1])
	if maps[2] != "":
		material.orm_texture = load(TEX + maps[2])
	else:
		material.roughness = 0.85
	if maps[3] != "" and not triplanar:
		material.heightmap_enabled = true # plain parallax, one extra sample: no deep parallax on the Quest
		material.heightmap_texture = load(TEX + maps[3])
		material.heightmap_scale = 1.5
	if triplanar:
		material.uv1_triplanar = true
		material.uv1_scale = Vector3.ONE * uv_scale.x
	else:
		material.uv1_scale = Vector3(uv_scale.x, uv_scale.y, 1.0)
		material.uv1_offset = Vector3(uv_offset.x, uv_offset.y, 0.0)
		material.detail_enabled = true
		material.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
		material.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		material.detail_albedo = _dirt()
	_materials.append(material)
	return material


func _dirt() -> NoiseTexture2D:
	if _dirt_texture == null:
		_dirt_texture = NoiseTexture2D.new()
		_dirt_texture.width = 256
		_dirt_texture.height = 256
		_dirt_texture.seamless = true
		var noise := FastNoiseLite.new()
		noise.frequency = 0.012
		noise.fractal_octaves = 4
		_dirt_texture.noise = noise
		var ramp := Gradient.new()
		ramp.set_color(0, Color(0.5, 0.46, 0.43))
		ramp.set_color(1, Color(1.0, 1.0, 1.0))
		_dirt_texture.color_ramp = ramp
	return _dirt_texture

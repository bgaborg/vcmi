## The war table's shaders (room.gd): the map objects' sprites, the minimap's markers, and the minimap itself.
extends RefCounted

## How much of the map is painted on the page at map UV `uv`: 1 where the tile is seen, 0 in the fog, blended over
## about a third of a tile with an uneven edge. `fog` is x-major, 1 of 255 where visible, read with a linear filter.
const PAINTED := """float painted(sampler2D fog_image, sampler2D grain_image, vec2 uv) {
	vec2 cells = vec2(textureSize(fog_image, 0).yx);
	float seen = texture(fog_image, uv.yx).r * 255.0 + (texture(grain_image, uv * cells / 6.0).r - 0.5) * 0.5;
	return smoothstep(0.34, 0.66, seen);
}"""
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
const SPRITE := """shader_type spatial;
render_mode unshaded, shadows_disabled, blend_premul_alpha, depth_draw_never, cull_disabled;
""" + PAINTED + """
// premultiplied in linear light, sRGB-encoded (SpriteAtlas.h)
uniform sampler2DArray atlas : source_color, filter_linear_mipmap;
uniform sampler2DArray masks : filter_linear_mipmap;
uniform sampler2D frames : filter_nearest;
uniform vec4 owner_colours[9];
uniform bool precision_check = false;
uniform mat4 world_to_panel; // the minimap's world transform, inverted: content outside the panel is cut
uniform vec2 panel_half = vec2(1000.0);
uniform sampler2D fog : filter_nearest; // x-major, as the minimap's
uniform sampler2D fog_soft : filter_linear, repeat_disable; // blended between tiles: the painted edge
uniform sampler2D grain : repeat_enable, filter_linear_mipmap; // makes that edge uneven
uniform vec4 view = vec4(0.0, 0.0, 1.0, 1.0); // the map UV the panel shows: position, size (set_zoom)
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
	if (owner == 11) {
		VERTEX = vec3(0.0); // no fog tiles: what is not seen is the blank page (quest/VISUALS.md)
	}
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
	// a card is cut at the panel's edge by where it stands, not by where its top leans to
	vec3 foot = cards_pass && card > 0.0 ? vec3(VERTEX.x, 0.0, 0.0) : VERTEX;
	shadow_only = !cards_pass && card > 0.0 ? 1.0 : 0.0;
	// a tile's edge texels sampled at their centres: no blend with the clear padding around the frame
	vec2 inset = owner >= 10 ? vec2(0.5) : vec2(0.0);
	page_uv = vec3((a.yz + inset + source * (vec2(a.w, b.x) - 2.0 * inset)) / PAGE, a.x);
	panel_xz = (world_to_panel * (MODEL_MATRIX * vec4(foot, 1.0))).xz;
}
void fragment() {
	if (abs(panel_xz.x) > panel_half.x || abs(panel_xz.y) > panel_half.y) {
		discard;
	}
	// painted on the page as far as the map is seen; the cards stand on seen tiles only. Nothing is read or blended
	// for the unseen map, most of it early in a game
	float paint = 1.0;
	if (!cards_pass) {
		vec2 map_uv = view.xy + (panel_xz / (2.0 * panel_half) + 0.5) * view.zw;
		paint = painted(fog_soft, grain, map_uv);
		if (paint <= 0.0) {
			discard;
		}
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
	c *= paint;
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
const MARKER := """shader_type spatial;
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
const MINIMAP := """shader_type spatial;
render_mode unshaded, shadows_disabled;
""" + PAINTED + """
uniform sampler2D terrain : source_color, filter_nearest_mipmap;
uniform sampler2D fog : filter_linear, repeat_disable;
uniform sampler2D grain : repeat_enable, filter_linear_mipmap;
uniform vec3 paper : source_color;
uniform float zoom = 1.0; // set_zoom: the panel shows 1 / zoom of the map around centre
uniform vec2 centre = vec2(0.5);
uniform float aspect = 1.0; // of the map's height, the panel shows aspect / zoom (view_aspect)
uniform bool framed = false; // the tablet: the whole map, the table's view in a white frame
uniform vec4 view = vec4(0.0, 0.0, 1.0, 1.0); // its corners in map UV
// the map's half size in the mesh's UV: the mesh is the book's page, the map with a margin around it (one layer: a
// page under the map would be drawn over the whole table a second time)
uniform vec2 plate = vec2(0.5);
void fragment() {
	vec2 panel = (UV - 0.5) / (2.0 * plate) + 0.5;
	vec2 uv = (panel - 0.5) * vec2(1.0, aspect) / zoom + centre;
	// the blank page, with a faint grain, darker away from the reading candle over the near edge; the map painted on
	// it where it is seen
	ALBEDO = paper * (0.93 + 0.14 * texture(grain, UV * 14.0).r);
	ALBEDO *= 1.0 - 0.3 * smoothstep(0.2, 1.0, distance(UV, vec2(0.5, 0.9)));
	vec2 edge = abs(panel - 0.5) - 0.5;
	float margin = max(edge.x, edge.y);
	if (margin > 0.0) {
		// a ruled line around the map, as a plate in a book
		ALBEDO *= abs(margin - 0.008) < 0.002 ? 0.55 : 1.0;
	} else {
		bool on_map = all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)));
		ALBEDO = mix(ALBEDO, texture(terrain, uv).rgb * 0.85, on_map ? painted(fog, grain, uv) : 0.0);
	}
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

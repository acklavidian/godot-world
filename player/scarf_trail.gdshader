shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

/// Base scarf colour. Alpha scales overall opacity.
uniform vec4  trail_color    : source_color  = vec4(0.70, 0.04, 0.04, 1.0);
/// How far back the scarf traces — set this to match the GDScript export.
/// (Visual only: controls nothing here, but useful as a shader note.)

/// Peak perpendicular displacement of the cloth flutter at the free end.
uniform float wave_amplitude : hint_range(0.0, 0.5)  = 0.08;
/// Speed of the cloth flutter cycle.
uniform float wave_speed     : hint_range(0.0, 20.0) = 3.5;
/// Spatial frequency of the cloth wave along the ribbon length.
uniform float wave_frequency : hint_range(1.0, 40.0) = 9.0;
/// How far inward from each ribbon edge the alpha softens (0 = hard edge).
uniform float edge_softness  : hint_range(0.01, 0.49) = 0.14;
/// HDR brightness at the base — values >1 trigger bloom on the character end.
uniform float emission_boost : hint_range(0.0, 3.0)  = 0.55;
/// Controls how steeply the scarf fades toward the tip (higher = sharper cutoff).
uniform float fade_power     : hint_range(0.5, 5.0)  = 1.8;

void vertex() {
	// UV.x: 0 = base (attached to character), 1 = tip (free end).
	float t = UV.x;

	// Cloth flutter — amplitude zero at the base, full at the free tip.
	// NORMAL points perpendicular to the ribbon surface (set in GDScript).
	float wave = sin(t * wave_frequency + TIME * wave_speed) * wave_amplitude * t;
	VERTEX += NORMAL * wave;
}

void fragment() {
	float t = UV.x; // 0 = base, 1 = tip
	float v = UV.y; // 0..1 across ribbon width

	// Trail fade: fully opaque at base, transparent at tip.
	float trail_alpha = pow(1.0 - t, fade_power);

	// Soft ribbon edges — avoids a hard geometric cutoff along the sides.
	float edge = smoothstep(0.0, edge_softness, v)
	           * smoothstep(1.0, 1.0 - edge_softness, v);

	// Subtle silk highlight along the centre ridge.
	float centre = 1.0 - abs(v * 2.0 - 1.0);

	// Colour: HDR bright (bloom-ready) near the character, deeper red at the tip.
	vec3 col = trail_color.rgb;
	col = mix(col * (1.0 + emission_boost * centre), col * 0.45, t);

	ALBEDO = col;
	ALPHA  = trail_alpha * edge * trail_color.a;
}

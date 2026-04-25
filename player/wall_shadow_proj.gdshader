shader_type spatial;
// Unlit alpha-blended overlay that paints a shadow silhouette on the wall.
render_mode unshaded, blend_mix, cull_back;

uniform sampler2D silhouette_tex : hint_default_black;
uniform float shadow_alpha    : hint_range(0.0, 1.0) = 0.0;
uniform float shadow_darkness : hint_range(0.0, 1.0) = 0.44;
uniform float edge_softness   : hint_range(0.01, 0.40) = 0.11;

void fragment() {
	vec2 uv = UV;

	// Red channel: 1 where the white proxy capsule rendered, 0 for transparent background.
	// Using .r is more reliable than .a in Godot's 3D render pipeline.
	float sil = texture(silhouette_tex, uv).r;

	// Fade toward all four edges so the quad boundary never shows a hard cut.
	float ex = min(uv.x, 1.0 - uv.x);
	float ey = min(uv.y, 1.0 - uv.y);
	float edge_fade = smoothstep(0.0, edge_softness, min(ex, ey));

	ALBEDO = vec3(0.0);
	ALPHA  = sil * shadow_alpha * shadow_darkness * edge_fade;
}

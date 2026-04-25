shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform vec4  albedo_color   : source_color = vec4(1.0);
uniform float dissolve       : hint_range(0.0, 1.1) = 0.0;
uniform float burn_width     : hint_range(0.01, 0.3) = 0.08;
uniform float smoke_speed    : hint_range(0.0, 3.0)  = 0.5;
uniform float smoke_scale    : hint_range(1.0, 10.0) = 4.0;
uniform vec3  smoke_dir = vec3(0.0, 0.0, -1.0);

// ── inline value noise — no async texture generation needed ───────────────

float _hash(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

float _vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(_hash(i),               _hash(i + vec2(1.0, 0.0)), f.x),
		mix(_hash(i + vec2(0.0, 1.0)), _hash(i + vec2(1.0, 1.0)), f.x),
		f.y);
}

float _fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v   += a * _vnoise(p);
		p    = p * 2.0 + vec2(1.7, 9.2);
		a   *= 0.5;
	}
	return v;
}

// ─────────────────────────────────────────────────────────────────────────

void fragment() {
	// Animated drift in the wall direction so smoke streams toward the wall.
	vec2 drift = vec2(smoke_dir.x, -smoke_dir.z) * TIME * smoke_speed;

	float n1 = _fbm(UV * smoke_scale + drift);
	float n2 = _fbm(UV * smoke_scale * 1.85 - drift * 0.55 + vec2(0.37, 0.61));
	float noise = clamp(n1 * 0.62 + n2 * 0.38, 0.0, 1.0);

	float lo = dissolve - burn_width;
	if (noise < lo) {
		discard;
	}

	// 0 at the dissolve edge → 1 on the untouched surface.
	float burn_t = smoothstep(lo, dissolve, noise);

	vec4 albedo    = texture(albedo_tex, UV) * albedo_color;
	vec3 burn_edge = vec3(0.025, 0.005, 0.0);

	ALBEDO   = mix(burn_edge, albedo.rgb, smoothstep(0.0, 0.55, burn_t));
	EMISSION = burn_edge * (1.0 - burn_t) * 1.8;
	ROUGHNESS = 1.0;
	METALLIC  = 0.0;
}

// The cumulus deck as a *world-space* volume: `sky.js`'s slab, drawn where it
// actually hangs instead of at the sky's infinite distance.
//
// Sky3D's clouds are painted by the sky stage, which is at infinity: a goat can
// climb through the altitude forever and never arrive at them. The scene's own
// slab is at `TUNING.sky.cloudBase`..`cloudTop` (44..50 m), and this is that slab
// as geometry -- a camera-centred box with only its far faces drawn (`cull_front`),
// whose fragment shader marches the same density field the reference sky does.
//
// Three properties make the box a volume rather than a sheet:
//
//   * Every ray that can see the deck hits exactly one far face, whether the eye
//     is below, inside or above the slab, so one fragment per pixel is enough.
//   * The depth test is the scene's own: terrain in front of the far face wins,
//     which is what puts the hills behind the deck instead of under it.
//   * Godot draws transparent geometry after the opaque pass, so the ground, the
//     water and the grass are already in the depth buffer when this composites.
//
// The noise, the coverage, the Beer-Lambert transmittance and the
// Henyey-Greenstein phase are `sky.gdshader`'s -- the scene's own cloud, not a
// second look for the port.
shader_type spatial;

// `depth_draw_never`: a transparent pass must not occlude what comes after it.
// `cull_front`: the box is seen from the inside (or from above/below it), so the
// faces worth rasterising are the far ones.
render_mode unshaded, cull_front, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 sun_dir;
uniform vec3 cam_pos;
uniform vec3 sun_color;
uniform vec3 cloud_lit;
uniform vec3 cloud_shadow;
uniform vec3 horizon_color;
uniform float cloudiness;
uniform vec2 wind;
uniform float sky_time;
uniform float cloud_base;
uniform float cloud_top;
uniform float cloud_scale;
uniform float cloud_detail;
uniform float cloud_absorb;
uniform int cloud_steps;

// `PI` is Godot's own shader constant. The march's cap is the scene's.
const float MAX_DIST = 450.0;

varying vec3 world_pos;

// ---- noise (`sky.gdshader`, verbatim) ----
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm3(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise2(p);
		p = p * 2.03 + 11.7;
		a *= 0.5;
	}
	return v;
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 2; i++) {
		v += a * vnoise2(p);
		p = p * 2.11 + 7.3;
		a *= 0.5;
	}
	return v;
}

// ---- the cumulus slab ----
float slab_y(vec3 p) {
	return (p.y - cloud_base) / max(cloud_top - cloud_base, 1e-3);
}

float cloud_density(vec3 p, vec2 drift, float detail_amt) {
	float y = slab_y(p);
	if (y < 0.0 || y > 1.0) {
		return 0.0;
	}
	vec2 q = p.xz * cloud_scale + drift + vec2(y * 0.85, y * -0.45);
	float warp = fbm2(q * 0.5);
	float base = fbm3(q + warp * 0.75);
	float shape = smoothstep(0.0, 0.22, y) * (1.0 - smoothstep(0.58, 1.0, y));
	float d = base * shape;
	float cover = mix(0.78, 0.14, cloudiness);
	d = max(0.0, d - cover) / max(1.0 - cover, 1e-3);
	if (detail_amt > 0.001 && d > 0.02 && d < 0.55) {
		d -= detail_amt * fbm2(q * 2.6 + 13.0) * (0.55 - d) * 1.6;
	}
	return clamp(d, 0.0, 1.0);
}

float sun_tau(vec3 p, vec2 drift) {
	float step_len = (cloud_top - cloud_base) * 0.28;
	vec3 step = sun_dir * step_len;
	float tau = 0.0;
	for (int i = 0; i < 3; i++) {
		p += step;
		tau += cloud_density(p, drift, 0.0);
	}
	return tau * step_len;
}

float hg(float cos_t, float g) {
	float g2 = g * g;
	float denom = 1.0 + g2 - 2.0 * g * cos_t;
	return (1.0 - g2) / (4.0 * PI * pow(max(denom, 1e-3), 1.5));
}

// The camera's position is a uniform rather than the built-in: a helper called
// from `fragment()` is compiled before the stage's built-ins are resolvable here.
vec3 cumulus(vec3 dir, out float trans) {
	trans = 1.0;
	vec3 origin = cam_pos;
	float dy = dir.y;
	if (abs(dy) < 1e-4) {
		return vec3(0.0);
	}
	float t0 = (cloud_base - origin.y) / dy;
	float t1 = (cloud_top - origin.y) / dy;
	if (t0 > t1) {
		float s = t0;
		t0 = t1;
		t1 = s;
	}
	t0 = max(t0, 0.0);
	if (t1 <= t0) {
		return vec3(0.0);
	}
	float span = min(t1 - t0, MAX_DIST);
	float growth = mix(1.0, 1.4, clamp(span / 120.0, 0.0, 1.0));
	float dt;
	if (growth > 1.0001) {
		dt = span * (growth - 1.0) / (pow(growth, float(cloud_steps)) - 1.0);
	} else {
		dt = span / float(cloud_steps);
	}
	vec2 drift = wind * sky_time * 0.01;
	float cos_t = dot(dir, sun_dir);
	float ph = hg(cos_t, 0.72) * 0.75 + hg(cos_t, -0.28) * 0.40;
	vec3 scatter = vec3(0.0);
	float t = t0 + dt * 0.5;
	for (int i = 0; i < cloud_steps; i++) {
		if (t > t0 + span || trans < 0.02) {
			break;
		}
		vec3 pos = origin + dir * t;
		float dens = cloud_density(pos, drift, cloud_detail / (1.0 + t * 0.05));
		if (dens > 0.01) {
			float tau = sun_tau(pos, drift);
			float sun_t = exp(-tau * cloud_absorb);
			float powder = 1.0 - exp(-tau * cloud_absorb * 2.0);
			float lum = sun_t * mix(0.55, 1.0, powder);
			vec3 c = mix(cloud_shadow, cloud_lit, clamp(lum, 0.0, 1.0));
			c += cloud_lit * sun_color * ph * sun_t * 1.3;
			c = mix(c, horizon_color, (1.0 - exp(-t * 0.0022)) * 0.55);
			float a = 1.0 - exp(-dens * cloud_absorb * dt);
			scatter += trans * a * c;
			trans *= 1.0 - a;
		}
		t += dt;
		dt *= growth;
	}
	return scatter;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 dir = normalize(world_pos - cam_pos);
	float trans = 1.0;
	vec3 scatter = cloudiness > 0.01 ? cumulus(dir, trans) : vec3(0.0);
	float alpha = 1.0 - trans;
	// Godot's `blend_mix` multiplies the source by its alpha, so the march's
	// premultiplied light is divided back out here. A clear ray (alpha 0) has no
	// colour to divide and is simply not drawn.
	ALBEDO = alpha > 0.002 ? scatter / alpha : vec3(0.0);
	ALPHA = alpha;
}

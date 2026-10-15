// The sky, drawn: `sky.js`'s `SKY_FS`, as a Godot sky shader.
//
// This is a transcription of the scene's sky fragment program down to the
// arithmetic, with two structural differences and nothing else:
//
//   * `EYEDIR` is the ray. `SKY_FS` rebuilds one per pixel from the camera basis
//     and `gl_FragCoord`; Godot hands the sky stage the same unit vector, in world
//     space, for free. The camera's *position* is still a uniform (`cam_pos`),
//     because the cloud slab is at a world height and where the eye is inside it
//     decides what the ray crosses -- an infinitely-far sky would lose that.
//   * The pass is one pass. The scene draws the air and the cloud separately, with
//     the sun and moon composited between them, so a cloud covers a disc; the port
//     has no discs yet (`PORT.md`), so it takes the single-pass path
//     (`SKY_LAYER_ALL`).
//
// The surface colours -- the zenith, the horizon and the cloud tints -- arrive
// already linear (see `SkyDome.apply`): `SKY_FS` writes a plain framebuffer, and Godot's
// pipeline is linear with an sRGB encode at the end, so the scene's display-space
// constants are converted once on the CPU rather than per pixel. The *light*
// colours (`sun_dir`, `sun_color`) are not: they are multipliers in both pipelines.
//
// The noise, the domain warp, the Beer-Lambert transmittance and the
// Henyey-Greenstein phase are the scene's, unchanged.
shader_type sky;

uniform vec3 cam_pos;
uniform vec3 sun_dir;
uniform vec3 sun_color;
uniform vec3 zenith_color;
uniform vec3 horizon_color;
uniform float cloudiness;
uniform vec2 wind;
uniform float sky_time;
uniform vec3 cloud_lit;
uniform vec3 cloud_shadow;
uniform float cloud_base;
uniform float cloud_top;
uniform float cloud_scale;
uniform float cloud_detail;
uniform float cloud_absorb;
uniform float cirrus;
uniform float cirrus_height;
uniform float night_dim;
uniform int cloud_steps;

// `PI` is Godot's own shader constant, so the only constant `SKY_FS` declares that
// has to be re-declared here is the march's distance cap.
const float MAX_DIST = 450.0;

// ---- noise ----
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

// The body uses three octaves, the warp and the detail two, to keep the
// per-sample cost down.
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
float slabY(vec3 p) {
	return (p.y - cloud_base) / max(cloud_top - cloud_base, 1e-3);
}

float cloudDensity(vec3 p, vec2 drift, float detailAmt) {
	float y = slabY(p);
	if (y < 0.0 || y > 1.0) {
		return 0.0;
	}
	// Shear with height (so it is not an extrusion) plus the wind drift.
	vec2 q = p.xz * cloud_scale + drift + vec2(y * 0.85, y * -0.45);
	// Domain warp: the cheap trick that turns blobby fBm into billows.
	float warp = fbm2(q * 0.5);
	float base = fbm3(q + warp * 0.75);
	// Soft base, rounded top.
	float shape = smoothstep(0.0, 0.22, y) * (1.0 - smoothstep(0.58, 1.0, y));
	float d = base * shape;
	// Coverage: the threshold falls as cloudiness rises, so the sky goes from a
	// few puffs to solid overcast.
	float cover = mix(0.78, 0.14, cloudiness);
	d = max(0.0, d - cover) / max(1.0 - cover, 1e-3);
	// Erode the edges, but only near a surface -- that is where it reads.
	if (detailAmt > 0.001 && d > 0.02 && d < 0.55) {
		d -= detailAmt * fbm2(q * 2.6 + 13.0) * (0.55 - d) * 1.6;
	}
	return clamp(d, 0.0, 1.0);
}

// Extinction between a point and the sun: the self-shadow term.
float sunTau(vec3 p, vec2 drift) {
	float stepLen = (cloud_top - cloud_base) * 0.28;
	vec3 step = sun_dir * stepLen;
	float tau = 0.0;
	for (int i = 0; i < 3; i++) {
		p += step;
		tau += cloudDensity(p, drift, 0.0);
	}
	return tau * stepLen;
}

// Henyey-Greenstein: a forward lobe is the bright rim on the sun's side, a small
// negative lobe softens the back.
float hg(float cosT, float g) {
	float g2 = g * g;
	float denom = 1.0 + g2 - 2.0 * g * cosT;
	return (1.0 - g2) / (4.0 * PI * pow(max(denom, 1e-3), 1.5));
}

// ---- atmosphere ----
vec3 skyBackground(vec3 dir) {
	float h = clamp(dir.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, zenith_color, pow(h, 0.45));
	float mu = max(dot(dir, sun_dir), 0.0);
	float low = 1.0 - clamp(sun_dir.y, 0.0, 1.0);
	// Forward-scattered glow, wide and warm when the sun is near the horizon.
	col += sun_color * pow(mu, mix(26.0, 3.0, low)) * (0.05 + 0.20 * low) * (1.0 - night_dim);
	// NOTE: the sun and moon discs themselves are drawn by `drawCelestial`
	// (world.js) as sprites over this pass, so the shader must not draw one too.
	// Haze hugging the horizon.
	col = mix(col, horizon_color, smoothstep(0.13, 0.0, dir.y) * 0.32);
	return col;
}

// Thin, stretched, wind-sheared high layer: two octaves, no march.
vec3 cirrusLayer(vec3 dir, vec3 behind) {
	if (cirrus < 0.02 || dir.y < 0.03) {
		return behind;
	}
	float t = (cirrus_height - cam_pos.y) / dir.y;
	if (t <= 0.0) {
		return behind;
	}
	vec2 p = (cam_pos.xz + dir.xz * t) * cloud_scale * 1.7 + wind * sky_time * 0.006;
	float n = fbm2(vec2(p.x * 0.24, p.y * 1.9));
	float cover = mix(0.82, 0.42, cirrus);
	float mask = smoothstep(cover, cover + 0.28, n);
	vec3 c = mix(cloud_shadow, cloud_lit, 0.55 + 0.45 * clamp(sun_dir.y, 0.0, 1.0));
	return mix(behind, c, mask * cirrus * exp(-t * 0.0035) * 0.85);
}

// ---- the march ----
vec3 cumulus(vec3 behind, vec3 dir, out float trans) {
	// The coverage on this ray, which a probe reads back. It has to be written on
	// every path out: an `out` parameter that a return leaves untouched is
	// undefined, and a clear ray is exactly the case that matters most.
	trans = 1.0;
	float dy = dir.y;
	if (abs(dy) < 1e-4) {
		return behind;
	}
	float t0 = (cloud_base - cam_pos.y) / dy;
	float t1 = (cloud_top - cam_pos.y) / dy;
	if (t0 > t1) {
		float s = t0;
		t0 = t1;
		t1 = s;
	}
	t0 = max(t0, 0.0);
	if (t1 <= t0) {
		return behind;
	}
	float span = min(t1 - t0, MAX_DIST);
	// Exponential stepping: samples stay dense near the camera and stretch with
	// distance, where a cloud covers fewer pixels. A uniform step pattern aliases
	// badly at grazing angles, and that aliasing *is* what reads as pixelated noise.
	float growth = mix(1.0, 1.4, clamp(span / 120.0, 0.0, 1.0));
	float dt;
	if (growth > 1.0001) {
		dt = span * (growth - 1.0) / (pow(growth, float(cloud_steps)) - 1.0);
	} else {
		dt = span / float(cloud_steps);
	}
	vec2 drift = wind * sky_time * 0.01;
	float cosT = dot(dir, sun_dir);
	float ph = hg(cosT, 0.72) * 0.75 + hg(cosT, -0.28) * 0.40;
	// No per-pixel jitter: randomising the start offset per pixel is exactly the
	// speckle it was meant to hide, and the exponential steps already stagger the
	// samples.
	vec3 scatter = vec3(0.0);
	float t = t0 + dt * 0.5;
	for (int i = 0; i < cloud_steps; i++) {
		if (t > t0 + span || trans < 0.02) {
			break;
		}
		vec3 pos = cam_pos + dir * t;
		// The erosion is the highest-frequency term, so it fades with distance
		// rather than aliasing.
		float dens = cloudDensity(pos, drift, cloud_detail / (1.0 + t * 0.05));
		if (dens > 0.01) {
			float tau = sunTau(pos, drift);
			// Beer-Lambert along the sun ray, plus the powder term that darkens
			// dense interiors instead of letting them glow.
			float sunT = exp(-tau * cloud_absorb);
			float powder = 1.0 - exp(-tau * cloud_absorb * 2.0);
			float lum = sunT * mix(0.55, 1.0, powder);
			vec3 c = mix(cloud_shadow, cloud_lit, clamp(lum, 0.0, 1.0));
			// Forward scattering tints the rim toward the sun colour.
			c += cloud_lit * sun_color * ph * sunT * 1.3;
			// Distance haze blends far cloud into the horizon.
			c = mix(c, horizon_color, (1.0 - exp(-t * 0.0022)) * 0.55);
			float a = 1.0 - exp(-dens * cloud_absorb * dt);
			scatter += trans * a * c;
			trans *= 1.0 - a;
		}
		t += dt;
		dt *= growth;
	}
	return behind * trans + scatter;
}

void sky() {
	vec3 dir = EYEDIR;
	float trans = 1.0;
	vec3 col = skyBackground(dir);
	col = cirrusLayer(dir, col);
	if (cloudiness > 0.01) {
		col = cumulus(col, dir, trans);
	}
	COLOR = clamp(col, vec3(0.0), vec3(1.0));
}

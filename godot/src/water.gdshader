// The water's surface: `lighting.js`'s `WATER_VS`/`WATER_FS`, re-authored for Godot.
//
// This is `sky.gdshader`'s counterpart and it strikes the same bargain `terrain_mesh.gd`
// does: the *rules* are the scene's and the *lighting* is Godot's. Two things are the
// scene's and are here as the scene wrote them --
//
//   * the vertex lift. The mesh's positions carry the *ground*, so the surface is the
//     table plus whatever stands on it: a vertex rises by its own depth
//     (`max(0, level - ground)`), which is what makes a pool a level sheet over a whole
//     basin instead of a skin over the dips. It is the one thing the shader owns rather
//     than the CPU, because the level moves with the rain and rewriting a 49x49 grid a
//     frame for a rising puddle is the cost this shape exists to avoid.
//   * the absorption. The tint runs shallow -> deep with the water's own *depth* (so a
//     puddle reads thin and a pool reads deep), and the alpha runs out over the shore
//     band with it, which is what makes the water's edge a fade rather than a drawn line.
//   * the chop (M20c). `waterNormal`, transcribed: two crossed wave trains whose gradient
//     tilts the surface per *fragment*, faded out where one pixel spans a crest. It is
//     not displaced -- the mesh is the terrain's 2 m grid and a wave is centimetres
//     across, which no quad that size can carry -- but a tilted normal is what the
//     reflection and the specular read, so it is the whole of what "a ripple" means here.
//     The wake's own rings (M20d) sum into the same gradient in `WATER_FS`; they are
//     absent here, which is exactly the zero-strength case, since a spent ring
//     contributes nothing.
//
// Everything `WATER_FS` spent its last third on is Godot's, exactly as the ground's
// lighting is: the sun, the ambient and the shadow map are the engine's, and the
// reflection is the *environment's*. This is a dielectric with `SPECULAR` set so that
// F0 is the scene's own `waterFresnel` -- Godot's 0.5 is F0 0.04, so 0.02 is a quarter
// of it -- which means the engine's Schlick term does the fresnel the scene mixed by
// hand, and its sky reflection does what the scene's own reflection tiers did. The
// colours are *not* `source_color`, for the reason section 9 gives about the ground:
// the scene authored them in display space and the port hands them over as they are.
//
// Not here, and each is its own slice in the ROADMAP: the wake and the splashes (M20d)
// and the reflection tiers (M20e: the bake and the mirrored pass, which Godot answers
// with the environment rather than with a second scene submission).
shader_type spatial;

// `TUNING.water.low`, until the frame's own level arrives.
uniform float water_level = -2.1;
// `water.js` `W_SHALLOW` / `W_DEEP`, and `TUNING.water.shore` / `fresnel`.
uniform vec4 water_shallow = vec4(0.40, 0.58, 0.53, 0.55);
uniform vec4 water_deep = vec4(0.05, 0.15, 0.19, 0.85);
uniform float water_shore = 0.08;
uniform float water_fresnel = 0.02;
// The chop's own numbers: `TUNING.water.wave` in `waterWave`, the wave clock, and the
// wind `waterWind` -- a unit direction and the share of the gust driving the amplitude.
uniform vec3 water_wave = vec3(0.03, 0.6, 1.2);
uniform float water_time = 0.0;
uniform vec3 water_wind = vec3(1.0, 0.0, 0.2);

// `WATER_VS`'s `fragDepth`: the water standing on this vertex, which the tint and the
// alpha are both read from.
varying float water_depth;
// ...and `fragWorldPos`, which the chop is a function of: the wave field is anchored to
// the world, not to the mesh, so a pool's ripples do not slide when the grid re-anchors.
varying vec3 water_world;

void vertex() {
	float ground = VERTEX.y;
	float depth = max(0.0, water_level - ground);
	water_depth = depth;
	VERTEX.y = ground + depth;
	water_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// `WATER_FS` `waterNormal`: the wave height field, differentiated.
//
// Two crossed directions, so the chop does not read as stripes, and an amplitude that
// falls away where the water is thin -- a puddle does not chop. The whole field is then
// faded out where one pixel spans a wave: every pool past a few metres is seen at a
// grazing angle, where a pixel covers many crests, and a normal field sampled that far
// below its own frequency reads as stripes and glitter *tearing* across the water rather
// than as chop. `fwidth` is exactly the phase one pixel covers, so the fade lands where
// the sampling does and the distance settles back into the flat mirror the chop averages
// to. (Nyquist is a phase step of pi; the fade starts well under it because the specular
// is a point sample of a tight lobe.)
vec3 water_normal(vec2 p, float depth) {
	float amp = water_wave.x * water_wind.z
		* clamp(depth / max(water_shore, 1e-4), 0.0, 1.0);
	float k = 6.2831853 / max(water_wave.y, 0.05);
	float t = water_time * water_wave.z;
	vec2 d1 = normalize(water_wind.xy + vec2(0.21, -0.13));
	vec2 d2 = normalize(vec2(-water_wind.y, water_wind.x) + vec2(-0.17, 0.23));
	float p1 = dot(d1, p) * k + t;
	float p2 = dot(d2, p) * k * 1.7 + t * 1.3;
	vec2 grad = d1 * (cos(p1) * k) + d2 * (cos(p2) * k * 1.7 * 0.6);
	float phase = max(fwidth(p1), fwidth(p2));
	grad *= 1.0 - smoothstep(0.5, 1.6, phase);
	return normalize(vec3(-grad.x * amp, 1.0, -grad.y * amp));
}

void fragment() {
	// `WATER_FS`'s `shore`: the share of the shore band the water's own depth fills.
	float shore = clamp(water_depth / max(water_shore, 1e-4), 0.0, 1.0);
	ALBEDO = mix(water_shallow.rgb, water_deep.rgb, shore);
	// `WATER_FS`: `waterDeep.a * shore` -- the shallow alpha is a colour's, and the
	// alpha is the deep one faded in with the depth.
	ALPHA = water_deep.a * shore;
	// The chop, in Godot's own terms: the scene writes a world-space normal and measures
	// the view, the light and the reflection against it, and a Godot fragment's `NORMAL`
	// is that same normal in *view* space -- which is the only difference between the two
	// lines.
	NORMAL = normalize((VIEW_MATRIX * vec4(water_normal(water_world.xz, water_depth),
		0.0)).xyz);
	// A sheet of water is a mirror at grazing angles and nearly clear from above, which
	// Godot says with F0 and a sharp lobe.
	SPECULAR = 0.5 * (water_fresnel / 0.04);
	ROUGHNESS = 0.08;
}

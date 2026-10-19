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
//   * the chop (M20c) and the wake (M20d). `waterNormal`, transcribed: two crossed wave
//     trains whose gradient tilts the surface per *fragment*, faded out where one pixel
//     spans a crest, and the wake's three rings summed into that *same* gradient so a hoof
//     in a pool tips the reflection and spreads the glitter exactly as a wave does. None of
//     it is displaced -- the mesh is the terrain's 2 m grid and a wave is centimetres
//     across, which no quad that size can carry -- but a tilted normal is what the
//     reflection and the specular read, so it is the whole of what a ripple means here.
//     The rings ride the chop's own amplitude and its own fade, which is why one in thin
//     water is as subtle as the water around it.
//
// Everything `WATER_FS` spent its last third on is Godot's, exactly as the ground's
// lighting is: the sun, the ambient and the shadow map are the engine's, and the reflection
// of the *sky* is the engine's specular with F0 set to the scene's own `waterFresnel`
// (Godot's 0.5 is F0 0.04, so 0.02 is a quarter of it). The colours are *not* `source_color`,
// for the reason section 9 gives about the ground: the scene authored them in display space
// and the port hands them over as they are.
//
// The reflection of the *world* (M20e) is `water_reflect.gd`'s setting and `water_mirror.gd`'s
// pass, and this is the half that reads it. `WATER_FS` is transcribed where it can be: the
// fresnel, the reflected direction, and `color = mix(color, sky, fres)` -- with the sample
// taken at the fragment's **own column**, flipped in the row, which is the whole reason
// `renderWaterMirror` mirrors the camera rather than projecting a ray: a reflected ray leaves
// the same column it entered, and the row is its equal distance on the other side of the
// waterline. What the scene seeded `sky` with is the engine's specular reflection, and the
// mirror **replaces** it wherever the pass drew something -- its clear is transparent, so its
// alpha is exactly the mask of what it drew, and a ray that met nothing leaves the sky
// standing, which is the scene's own rule.
//
// Not here, and its own slice in the ROADMAP: swimming (M20g). The *drops* a splash throws
// are not here either, and for a different reason: `water_splash.gd` draws them, because a
// drop is a ball rather than a fragment of this surface.
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

// The wake (M20d): three rings at once, each `(x, z, the front's radius in metres, its
// strength)`. Named rather than an array on purpose -- the scene's reason is that its
// shader surface takes a *name* rather than an index, and a fixed handful of uniforms is a
// question every renderer can answer. The strength arrives already decayed by the emitter,
// which is what keeps this stateless about time; a spent ring is pushed as a zero and
// contributes nothing.
uniform vec4 water_ripple0 = vec4(0.0);
uniform vec4 water_ripple1 = vec4(0.0);
uniform vec4 water_ripple2 = vec4(0.0);

// The reflection (M20e): the tier, and the pass's own image. `water_reflect` is 0 for the sky
// alone -- which samples nothing at all -- and 1 or 2 for the mirror, whose tiers differ in
// what `water_mirror.gd` draws rather than in how this reads it. The default is transparent,
// so a tier with no pass bound contributes nothing even before the guard.
uniform int water_reflect = 1;
uniform sampler2D water_mirror : hint_default_transparent, repeat_disable, filter_linear;

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

// One ring's gradient: an expanding front with a damped wave train behind it, which is what
// a hoof in water leaves. `WATER_FS` `rippleGrad`, transcribed.
vec2 ripple_grad(vec2 p, vec4 r, float w) {
	if (r.w <= 0.001) return vec2(0.0);
	vec2 d = p - r.xy;
	float dist = max(length(d), 1e-3);
	return (d / dist) * (cos((dist - r.z) * w) * w * exp(-dist * 1.2) * r.w);
}

// `WATER_FS` `waterNormal`: the wave height field, differentiated.
//
// Two crossed directions, so the chop does not read as stripes, and an amplitude that
// falls away where the water is thin -- a puddle does not chop. The whole field is then
// faded out where one pixel spans a wave: every pool past a few metres is seen at a
// grazing angle, where a pixel covers many crests, and a normal field sampled that far
// below its own frequency reads as stripes and glitter *tearing* across the water rather
// than as chop. `fwidth` is exactly the phase one pixel covers, so the fade lands where the
// sampling does and the distance settles back into the flat mirror the chop averages
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
	// The rings are summed into that gradient and ride the same amplitude, so one in thin
	// water is as subtle as the chop around it. Three crests per `water_wave.y`, which is
	// what a splash looks like.
	float rw = 6.2831853 / max(water_wave.y * 3.0, 0.05);
	grad += ripple_grad(p, water_ripple0, rw) + ripple_grad(p, water_ripple1, rw)
		+ ripple_grad(p, water_ripple2, rw);
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
	vec3 n_world = water_normal(water_world.xz, water_depth);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	// A sheet of water is a mirror at grazing angles and nearly clear from above, which
	// Godot says with F0 and a sharp lobe.
	SPECULAR = 0.5 * (water_fresnel / 0.04);
	ROUGHNESS = 0.08;
	// The reflection (M20e), and `WATER_FS`'s own three lines: the fresnel, the reflected
	// direction, and the mix. The mirror's own alpha is what it drew -- its clear is
	// transparent -- so a fragment the pass never touched keeps the engine's sky reflection
	// rather than being painted over, and the sky tier mixes nothing at all.
	//
	// The row is flipped. The pass's camera is an ordinary camera placed under the water, so
	// it renders the world *upright* -- the goat's head is above its feet in the target, as
	// it is in the main view. A reflection is the same image about the waterline, which means
	// a fragment below the line must read the target's row that is equally far *above* it.
	// Reading at the fragment's own row instead would put an upright copy under every object.
	vec3 view_dir = normalize(CAMERA_POSITION_WORLD - water_world);
	float ndv = max(dot(n_world, view_dir), 0.0);
	float fres = water_fresnel + (1.0 - water_fresnel) * pow(1.0 - ndv, 5.0);
	if (water_reflect >= 1) {
		vec4 mirror = texture(water_mirror, vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y));
		ALBEDO = mix(ALBEDO, mirror.rgb, fres * mirror.a);
	}
}

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
// Not here, and each is its own slice in the ROADMAP: the chop (M20c -- `waterNormal`,
// which is why this sheet is flat until it is not), the wake and the splashes (M20d),
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

// `WATER_VS`'s `fragDepth`: the water standing on this vertex, which the tint and the
// alpha are both read from.
varying float water_depth;

void vertex() {
	float ground = VERTEX.y;
	float depth = max(0.0, water_level - ground);
	water_depth = depth;
	VERTEX.y = ground + depth;
}

void fragment() {
	// `WATER_FS`'s `shore`: the share of the shore band the water's own depth fills.
	float shore = clamp(water_depth / max(water_shore, 1e-4), 0.0, 1.0);
	ALBEDO = mix(water_shallow.rgb, water_deep.rgb, shore);
	// `WATER_FS`: `waterDeep.a * shore` -- the shallow alpha is a colour's, and the
	// alpha is the deep one faded in with the depth.
	ALPHA = water_deep.a * shore;
	// A sheet of water is a mirror at grazing angles and nearly clear from above, which
	// Godot says with F0 and a sharp lobe.
	SPECULAR = 0.5 * (water_fresnel / 0.04);
	ROUGHNESS = 0.08;
}

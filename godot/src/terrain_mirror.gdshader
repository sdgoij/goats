// The ground's reflection (M20e): the terrain's own mesh, drawn the way the mirror's camera
// has to see it.
//
// `water_mirror.gd` renders the world from the camera the water's plane mirrors the player's
// into, and the ground is the one surface that needs a *second* way of being drawn to appear
// in it at all. Three things have to be different, and each is the scene's own:
//
//   * **its quads face away from that camera.** The mirrored eye sits under the terrain by
//     construction, so every triangle of a heightfield is a back face there and a normal
//     material culls the lot -- which is why the reflection this slice shipped first held the
//     goat and no ground. `cull_front` is that turned around: the faces the mirrored eye sees
//     are exactly the ones the main pass throws away, so one mesh serves both.
//   * **the normal has to stay the ground's.** An underside shaded with a *flipped* normal is
//     black, and that is worse than absent: a black slab drawn between the mirror's camera and
//     the goat hides the goat. It is what a double-sided Godot material produces -- measured,
//     not assumed, and the reason this is a `cull_front` shader that writes the normal rather
//     than a `cull_disabled` material. The scene never had the problem, because `LIT_FS` lights
//     a fragment from the normal it was *authored* with.
//   * **everything below the water has nothing to contribute.** Mirroring puts it above the
//     plane, where the sky belongs, and it is also the near slab that would otherwise occlude
//     the goat. That cut is `LIT_FS`'s `mirrorClip`: a `discard` on `y < level`, and the level
//     is the uniform `water_mirror.gd` pushes each frame.
//
// What is *not* re-authored is the look: the per-vertex material colour times the detail
// texture, no specular, and Godot's light and shadows doing what the scene's lit program and
// its hand-rolled shadow map do (`PORT.md` section 5). The twin shares one detail texture and
// one `ArrayMesh` with the ground itself, so the reflection costs one draw at half the viewport
// and no geometry.
shader_type spatial;
// The mirrored eye is *under* the terrain, so the ground's own quads are back faces there.
render_mode cull_front;

// The water's own plane, pushed by `water_mirror.gd` from `Water.level()`, and the ground's
// detail texture, handed over by `terrain_mesh.gd` so the two draws of one mesh cannot drift.
//
// `filter_linear_mipmap`, not `filter_linear`: the texture has a chain (`generate_mipmaps` in
// `terrain_mesh.gd`) and the main material samples it, but a shader uniform defaults to the
// nearest level, so the *reflection* was minifying the 8.3 m grain with no chain at half the
// viewport -- the moiré the client fades its detail out with distance to avoid. The grain itself
// is not re-authored here on purpose: it is a sub-pixel detail of the scene's ground at this
// resolution, read through a ripple, and it would cost the pass a noise per fragment.
uniform float water_level = -2.1;
uniform sampler2D detail_texture : hint_default_white, filter_linear_mipmap, repeat_enable;

// The three things `cull_front` costs a built-in: Godot's `NORMAL` is flipped for a fragment
// that is not front-facing, which is every fragment this material draws, so the authored
// normal is carried across rather than read back.
varying vec3 ground_world;
varying vec3 ground_normal;
varying vec4 ground_color;

void vertex() {
	ground_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ground_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	ground_color = COLOR;
}

void fragment() {
	// The scene's own cut: below the table there is nothing to reflect.
	if (ground_world.y < water_level) {
		discard;
	}
	ALBEDO = ground_color.rgb * texture(detail_texture, UV).rgb;
	ROUGHNESS = 1.0;
	// The ground is not shiny, and a specular highlight on a hillside reads as water.
	SPECULAR = 0.0;
	// The ground's own normal, in the view space `NORMAL` is written in. This is the line the
	// whole material exists for.
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(ground_normal), 0.0)).xyz);
}

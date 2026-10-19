# The sky gate: `sky.gd`'s day/night curve and light against the JavaScript's.
#
#   Godot --headless --path godot --script res://tools/verify_sky.gd
#
# The sky curve is what decides the colour of everything, so a transcription of it
# that is a little wrong is a whole scene that is a little wrong -- and the port's
# worst rendering bugs have been exactly this shape: every number agreeing and the
# picture dark. `tools/verify_terrain.gd` checks the heightfield against the
# JavaScript evaluated by **the embedded engine**; this does the same for `world.js`
# `skySample` / `updateAmbient` and `lighting.js` `updateLight`.
#
# The byte comparisons are exact on purpose. Both sides interpolate in the same
# order -- `a + (b - a) * t`, not `lerp` -- and then `Math.round`, so a keyframe
# midpoint lands on the same integer in both languages. Only the fields that go
# through `cos`/`sin` need a tolerance, and only because the two engines' libm are
# not the same libm.
#
# It uses only what already exists -- `eval_js` for the oracle, `poll_lines` to read
# the answers back -- so measuring this needed no production code.
extends SceneTree

## `world.js` / `lighting.js`, transcribed *from their sources*, with `TUNING.sky`
## not needed (the curve has no tuning) and `TUNING.world` not needed either.
const JS := """
const SKY_KEYS = [
    { h: 0.0, top: [8, 10, 28], bot: [16, 20, 44], light: 0.0 },
    { h: 4.5, top: [12, 14, 34], bot: [26, 28, 54], light: 0.0 },
    { h: 6.0, top: [70, 70, 120], bot: [190, 120, 90], light: 0.25 },
    { h: 7.5, top: [120, 165, 220], bot: [235, 190, 150], light: 0.8 },
    { h: 12.0, top: [110, 170, 240], bot: [175, 210, 245], light: 1.0 },
    { h: 17.0, top: [120, 165, 220], bot: [235, 200, 160], light: 0.85 },
    { h: 19.0, top: [90, 80, 130], bot: [225, 130, 90], light: 0.35 },
    { h: 20.5, top: [26, 28, 58], bot: [70, 60, 90], light: 0.08 },
    { h: 22.0, top: [10, 12, 30], bot: [18, 22, 46], light: 0.0 },
    { h: 24.0, top: [8, 10, 28], bot: [16, 20, 44], light: 0.0 },
];
function mix(a, b, t) { return a + (b - a) * t; }
function skySample(h) {
    let i = 0;
    while (i < SKY_KEYS.length - 2 && h > SKY_KEYS[i + 1].h) i += 1;
    const a = SKY_KEYS[i], b = SKY_KEYS[i + 1];
    const span = b.h - a.h;
    const t = span > 0 ? (h - a.h) / span : 0;
    return {
        top: [Math.round(mix(a.top[0], b.top[0], t)),
              Math.round(mix(a.top[1], b.top[1], t)),
              Math.round(mix(a.top[2], b.top[2], t))],
        bot: [Math.round(mix(a.bot[0], b.bot[0], t)),
              Math.round(mix(a.bot[1], b.bot[1], t)),
              Math.round(mix(a.bot[2], b.bot[2], t))],
        light: mix(a.light, b.light, t),
    };
}
function updateAmbient(t) {
    const warm = Math.max(0, Math.min(1, 1 - Math.abs(t - 0.3) / 0.34));
    return {
        warm: warm,
        r: Math.min(1, 0.40 + 0.60 * t + 0.14 * warm),
        g: Math.min(1, 0.44 + 0.56 * t + 0.02 * warm),
        b: Math.min(1, 0.62 + 0.38 * t - 0.14 * warm),
    };
}
function updateLight(hours, skyLight) {
    const a = ((hours - 6) / 12) * Math.PI;
    const sunX = Math.cos(a), sunY = Math.sin(a), tilt = 0.18;
    const len = Math.sqrt(sunX * sunX + sunY * sunY + tilt * tilt) || 1;
    const SUN = [sunX / len, sunY / len, tilt / len];
    const day = sunY > 0;
    const LIGHT = day ? [SUN[0], SUN[1], SUN[2]] : [-SUN[0], -SUN[1], -SUN[2]];
    const warm = Math.max(0, Math.min(1, 1 - Math.abs(sunY) / 0.45));
    const intense = day ? 0.30 + 0.70 * skyLight : 0.16;
    let LIGHT_COLOR;
    if (day) LIGHT_COLOR = [intense, intense * (1 - 0.22 * warm), intense * (1 - 0.55 * warm)];
    else LIGHT_COLOR = [intense * 0.72, intense * 0.80, intense];
    const AMBIENT = [0.10 + 0.12 * skyLight, 0.12 + 0.13 * skyLight, 0.18 + 0.16 * skyLight];
    return { sun: SUN, light: LIGHT, color: LIGHT_COLOR, ambient: AMBIENT, warm: warm };
}
// `sky.js` setSkyUniforms: the cloud tints, which follow the sky light and the warmth.
function cloudTints(skyLight, warm) {
    const lit = 0.12 + 0.88 * skyLight;
    const shadow = 0.09 + 0.40 * skyLight;
    return {
        lit: [Math.min(1, lit + 0.10 * warm), Math.min(1, lit + 0.02 * warm),
              Math.min(1, lit - 0.06 * warm)],
        shadow: [shadow * 0.95, shadow * 0.97, shadow * 1.06],
    };
}
const HOURS = [0.0, 3.1, 4.5, 6.0, 6.75, 7.5, 9.3, 12.0, 15.25, 17.0, 19.0, 20.5, 22.0,
               23.9, 24.0];
for (const h of HOURS) {
    const s = skySample(h);
    const amb = updateAmbient(s.light);
    const l = updateLight(h, s.light);
    const c = cloudTints(s.light, amb.warm);
    console.log('T ' + [h, s.top[0], s.top[1], s.top[2], s.bot[0], s.bot[1], s.bot[2],
        s.light, l.sun[0], l.sun[1], l.sun[2], l.light[0], l.light[1], l.light[2],
        l.color[0], l.color[1], l.color[2], l.ambient[0], l.ambient[1], l.ambient[2],
        amb.warm, amb.r, amb.g, amb.b, c.lit[0], c.lit[1], c.lit[2],
        c.shadow[0], c.shadow[1], c.shadow[2]].join(' '));
}
"""

## The hours the oracle answers for. The two ends of the table, the keyframes
## themselves, the midpoints of the segments around dawn and dusk (where a `.5` byte
## lands), and one hour in each open segment.
const HOURS := [
	0.0, 3.1, 4.5, 6.0, 6.75, 7.5, 9.3, 12.0, 15.25, 17.0, 19.0, 20.5, 22.0, 23.9, 24.0,
]

## The fields that go through `cos`/`sin` differ by the two engines' libm -- one
## ULP at worst, and `sin` here is evaluated at small arguments, so nowhere near the
## `value_hash` argument-reduction floor `verify_terrain.gd` documents. A tenth of a
## millionth is two orders above one ULP and four below a 1/255 byte step.
const TOLERANCE := 1e-6

## The bytes, on the other hand, must agree exactly: both sides interpolate in the
## same order and then round, so a keyframe midpoint is the same integer in both.
func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", JS)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	print("oracle answered ", answers.size(), " line(s)")

	var compared := 0
	var worst := 0.0
	var worst_at := ""
	var byte_mismatches := 0
	var first_byte_mismatch := ""
	for line in answers:
		if not line.begins_with("log T "):
			continue
		var parts: PackedStringArray = line.split(" ")
		if parts.size() != 32:
			continue
		var hours: float = float(parts[2])

		# The bytes first, and exactly: `top` then `bot`.
		var curve: Dictionary = SkyModel.sample(hours)
		var top: Color = curve["top"]
		var bot: Color = curve["bot"]
		var mine_bytes: Array[int] = [
			int(round(top.r * 255.0)), int(round(top.g * 255.0)), int(round(top.b * 255.0)),
			int(round(bot.r * 255.0)), int(round(bot.g * 255.0)), int(round(bot.b * 255.0)),
		]
		for k in mine_bytes.size():
			var wanted: int = int(float(parts[3 + k]))
			if mine_bytes[k] != wanted:
				byte_mismatches += 1
				if first_byte_mismatch == "":
					first_byte_mismatch = "h=%.3f %s channel %d: js %d, gd %d" % [
						hours, "sky-top" if k < 3 else "sky-bottom", k % 3, wanted, mine_bytes[k]]

		# Then the floats, which start after `h` and the six bytes.
		var j: int = 9
		var sky_light: float = curve["light"]
		var sun: Vector3 = SkyModel.sun_dir(hours)
		var light: Vector3 = SkyModel.light_dir(hours)
		var colour: Color = SkyModel.light_color(hours, sky_light)
		var ambient: Color = SkyModel.ambient(sky_light)
		var warm: float = SkyModel.warmth(sky_light)
		var tint: Vector3 = SkyModel.ambient_tint(sky_light)
		var lit: Color = SkyModel.cloud_lit(sky_light, warm)
		var shade: Color = SkyModel.cloud_shadow(sky_light)
		var mine: Array[float] = [
			sky_light,
			sun.x, sun.y, sun.z,
			light.x, light.y, light.z,
			colour.r, colour.g, colour.b,
			ambient.r, ambient.g, ambient.b,
			warm, tint.x, tint.y, tint.z,
			lit.r, lit.g, lit.b,
			shade.r, shade.g, shade.b,
		]
		for k in mine.size():
			var expected: float = float(parts[j + k])
			var difference: float = absf(mine[k] - expected)
			compared += 1
			if difference > worst:
				worst = difference
				worst_at = "h=%.3f field %d: js %.17f, gd %.17f" \
					% [hours, k, expected, mine[k]]

	print("compared ", compared, " field(s) over ", HOURS.size(), " hour(s)")
	print("largest disagreement: %.12f (tolerance %.12f)" % [worst, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)
	print("byte mismatches: ", byte_mismatches)
	if first_byte_mismatch != "":
		print("  first: ", first_byte_mismatch)

	host.free()

	if compared != HOURS.size() * 23:
		failures.append("the oracle answered %d field(s), expected %d"
			% [compared, HOURS.size() * 23])
	if byte_mismatches != 0:
		failures.append("the curve's bytes are not the scene's (%d mismatched)"
			% byte_mismatches)
	if worst > TOLERANCE:
		failures.append("the port disagrees with the scene by %f (limit %f)"
			% [worst, TOLERANCE])

	if failures.is_empty():
		print("OK: the GDScript sky is the scene's sky")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

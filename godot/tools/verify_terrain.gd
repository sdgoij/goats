# The terrain gate: the GDScript heightfield against the JavaScript one.
#
#   Godot --headless --path godot --script res://tools/verify_terrain.gd
#
# `world.js`'s `terrainHeight` is deterministic on purpose: the mine field and the
# craters are *derived* from the session seed rather than sent, so two peers that
# disagree about the ground by a bit disagree about where a device is. The port is
# therefore a transcription down to the arithmetic order -- and the way to check a
# transcription is against the original, not against a hand-computed table.
#
# The original here is the JavaScript itself, evaluated by **the embedded engine**
# (`ModHost` -> Slag), which is the engine the client runs it on. So this gate
# compares two independent implementations of the same function rather than
# checking one against a fixture: exactly the cross-engine determinism question
# `PORT.md` section 9 puts first.
#
# It uses only what already exists -- `eval_js` for the oracle, `poll_lines` to
# read the answers back -- so measuring this needed no production code.
extends SceneTree

## `world.js` / `weather.js` / `core.js`, transcribed *from their sources*, with
## `TUNING.terrain` inlined: `relief` 2.1, `flat` 6, `ramp` 16, `mountain` 38,
## `mountainFlat` 40, `mountainRamp` 120.
const JS := """
function hash(n) { const s = Math.sin(n * 127.1) * 43758.5453; return s - Math.floor(s); }
function vnoise2(x, y) {
    const xi = Math.floor(x), yi = Math.floor(y);
    const xf = x - xi, yf = y - yi;
    const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    const a = hash(xi * 57.0 + yi * 131.0);
    const b = hash((xi + 1) * 57.0 + yi * 131.0);
    const c = hash(xi * 57.0 + (yi + 1) * 131.0);
    const d = hash((xi + 1) * 57.0 + (yi + 1) * 131.0);
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v;
}
function smoothstep(lo, hi, v) {
    let t = (v - lo) / (hi - lo);
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return t * t * (3 - 2 * t);
}
function terrainShape(x, z) {
    return 0.58 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1) +
        0.25 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9) +
        0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3) +
        0.05 * vnoise2(x * 0.29 + 5.3, z * 0.29 + 33.7);
}
function terrainRidge(x, z) {
    const broad = 1 - Math.abs(2 * vnoise2(x * 0.0105 + 91.3, z * 0.0105 + 17.9) - 1);
    const fine = 1 - Math.abs(2 * vnoise2(x * 0.028 + 3.7, z * 0.028 + 55.1) - 1);
    const ridge = 0.72 * broad + 0.28 * fine;
    const mask = smoothstep(0.30, 0.70, vnoise2(x * 0.0062 + 7.3, z * 0.0062 + 41.7));
    return ridge * ridge * mask;
}
function terrainBaseHeight(x, z) {
    const d = Math.sqrt(x * x + z * z);
    let t = (d - 6) / 16;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    t = t * t * (3 - 2 * t);
    let tm = (d - 40) / 120;
    tm = tm < 0 ? 0 : tm > 1 ? 1 : tm;
    tm = tm * tm * (3 - 2 * tm);
    return (terrainShape(x, z) - 0.5) * 2 * 2.1 * t + terrainRidge(x, z) * 38 * tm;
}
"""

## Points covering the three regimes: inside the spawn bowl (height 0), through
## the ramp, and out in the open field. Several are real bot positions from a run,
## and several are chosen to land on or beside the bowl's edge and on negative
## coordinates, where a sign slip would show.
const SAMPLES := [
	[0.0, 0.0], [3.0, -4.0], [5.9, 0.0], [6.0, 0.0], [10.0, 0.0],
	[22.0, 0.0], [14.56, 4.5], [-9.47, 5.8], [4.29, -17.66], [6.42, 16.29],
	[-9.3, -4.78], [11.82, 3.3], [-7.66, 14.05],
	[48.0, 48.0], [-48.0, -48.0], [100.25, -7.75], [-30.0, 17.0],
]

## A disagreement this large is a real difference in the transcription rather
## than in `sin`. The measured residual is ~7e-10 (see below) on the mountain
## range, where a 700-millionths-of-a-sine error is multiplied by a metre of
## relief; this is still nine orders below a centimetre -- the wire quantizes a
## *device* to the centimetre, so nothing here can move one across a cell
## boundary.
##
## **Bit-exactness is not reachable**, and it is worth being precise about why:
## `value_hash` is `sin(n * 127.1) * 43758.5453` and `n` runs to tens of
## thousands, so the sine is evaluated at arguments in the millions. There, the
## answer depends on the argument-reduction algorithm -- Payne-Hanek, Cody-Waite,
## and how many bits of pi the implementation carries -- and Godot's `sin` is not
## Rust's, which is what the scene's `Math.sin` bottoms out in. The two agree to
## about ten significant digits and no closer.
##
## What that costs, measured rather than guessed: a sub-micrometre error in the
## ground, and -- for the one thing that is *derived* rather than sent, the device
## field -- a chance of a peer disagreeing that is the odds of a hash landing
## within that of a threshold. The devices that have gone off and the craters
## they left are on the wire (`spent`, `craters` in the world snapshot), so the
## divergence cannot accumulate.
const TOLERANCE := 1e-8

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")

	# The oracle: the scene's own functions, run by the scene's own engine.
	var source: String = JS + "\nconst S = " + JSON.stringify(SAMPLES) + ";\n" \
		+ "for (const p of S) console.log('T ' + p[0] + ' ' + p[1] + ' ' + terrainBaseHeight(p[0], p[1]));\n"
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	print("oracle answered ", answers.size(), " line(s)")

	var worst := 0.0
	var worst_at := ""
	var compared := 0
	for line in answers:
		if not line.begins_with("log T "):
			continue
		var parts: PackedStringArray = line.split(" ")
		if parts.size() != 5:
			continue
		var x := float(parts[2])
		var z := float(parts[3])
		var expected := float(parts[4])
		var got: float = Terrain.base_height(x, z)
		compared += 1
		var difference := absf(got - expected)
		if difference > worst:
			worst = difference
			worst_at = "(%.3f, %.3f): js %.17f, gd %.17f" % [x, z, expected, got]

	print("compared ", compared, " of ", SAMPLES.size(), " sample point(s)")
	print("largest disagreement: %.12f m (tolerance %.12f m)" % [worst, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)
	if worst == 0.0:
		print("the two implementations agree bit for bit")

	host.free()

	if compared != SAMPLES.size():
		failures.append("the oracle answered %d of %d points" % [compared, SAMPLES.size()])
	if worst > TOLERANCE:
		failures.append("the port disagrees with the scene by %f (limit %f)" % [worst, TOLERANCE])

	if failures.is_empty():
		print("OK: the GDScript heightfield is the scene's heightfield")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

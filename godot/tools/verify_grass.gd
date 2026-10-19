# The grass gate: `grass.gd`'s meadow against the JavaScript's.
#
#   Godot --headless --path godot --script res://tools/verify_grass.gd
#
# The meadow is *derived*, not stored: a tuft exists where a hash of its 2-unit cell
# says so, at a position the same hash jitters. So two peers that disagree about the
# hash disagree about where the grass is -- and the grass is where a goat eats, which
# is where the *devices* are (`explosions.js`: a share of the tufts are trapped). It
# is the same class of risk as the heightfield `verify_terrain.gd` covers, which is
# why it gets the same treatment: the oracle is the scene's own `tuftField`, run by
# the embedded engine the client runs it on.
#
# What this is really checking is the *emulated 32-bit arithmetic*. The scene's cell
# hash is `Math.imul` and `>>>` -- wrap-around integer mixing -- and GDScript's `int`
# is 64 bits, so the port re-implements the wrap. A subtly wrong `imul` is not a
# slightly wrong field, it is a different one, and it would still look like grass.
#
# The tuft *count* and the near/far flag are integers, and are compared exactly.
extends SceneTree

## `world.js` / `weather.js` / `food.js`, transcribed *from their sources*: the
## heightfield (`verify_terrain.gd` carries the same transcription, with
## `TUNING.terrain` inlined as `flat` 6, `ramp` 16, `relief` 2.1) and `tuftField`,
## verbatim, cache and all -- an empty `cellH` is the cache doing nothing.
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
function terrainShape(x, z) {
    return 0.62 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1) +
        0.26 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9) +
        0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3);
}
function terrainBaseHeight(x, z) {
    const d = Math.sqrt(x * x + z * z);
    let t = (d - 6) / 16;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    t = t * t * (3 - 2 * t);
    return (terrainShape(x, z) - 0.5) * 2 * 2.1 * t;
}
function tuftField(out, cellH, eaten, imul, sin, groundY,
                   cx0, cz0, cx1, cz1, gx, gz, cull2, detail2, swayTime, windSway) {
    let n = 0;
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) {
            let h = (cx * 374761393 + cz * 668265263) | 0;
            h = imul(h ^ (h >>> 13), 1274126177);
            h = (h ^ (h >>> 16)) >>> 0;
            const a = h / 4294967296;
            if (a < 0.45) continue;
            if (eaten.has((cx + 4096) * 8192 + (cz + 4096))) continue;
            let h2 = (cx * 1103515245 + cz * 12345) | 0;
            h2 = imul(h2 ^ (h2 >>> 15), 2246822519);
            h2 = (h2 ^ (h2 >>> 13)) >>> 0;
            let h3 = (cx * 2654435761 + cz * 40503) | 0;
            h3 = imul(h3 ^ (h3 >>> 16), 3266489917);
            h3 = (h3 ^ (h3 >>> 16)) >>> 0;
            const x = cx * 2 + (h2 / 4294967296 - 0.5) * 1.8;
            const z = cz * 2 + (a - 0.5) * 1.8;
            const tx = x - gx;
            const tz = z - gz;
            const d2 = tx * tx + tz * tz;
            if (d2 > cull2) continue;
            const off = sin(swayTime * 3.0 + (h3 / 4294967296) * 6.28) * 0.11 * windSway;
            const hkey = (cx + 4096) * 8192 + (cz + 4096);
            let gy = cellH.get(hkey);
            if (gy === undefined) {
                gy = groundY(x, z);
                if (cellH.size > 32768) cellH.clear();
                cellH.set(hkey, gy);
            }
            const t = out[n];
            t.ax = x + off;
            t.ay = gy + 0.06;
            t.az = z + off * 0.4;
            t.bx = x + off * 1.7;
            t.by = gy + 0.20;
            t.bz = z + off * 0.7;
            t.d = d2 < detail2 ? 1 : 0;
            n += 1;
        }
    }
    return n;
}
const CASES = __CASES__;
for (let c = 0; c < CASES.length; c++) {
    const k = CASES[c];
    const eaten = new Set();
    for (const cell of k.eaten) eaten.add((cell[0] + 4096) * 8192 + (cell[1] + 4096));
    const r = Math.sqrt(576);
    const cx0 = Math.floor((k.gx - r) * 0.5), cx1 = Math.ceil((k.gx + r) * 0.5);
    const cz0 = Math.floor((k.gz - r) * 0.5), cz1 = Math.ceil((k.gz + r) * 0.5);
    const cells = (cx1 - cx0 + 1) * (cz1 - cz0 + 1);
    const pool = [];
    while (pool.length < cells) pool.push({ ax: 0, ay: 0, az: 0, bx: 0, by: 0, bz: 0, d: 0 });
    const n = tuftField(pool, new Map(), eaten, Math.imul, Math.sin, terrainBaseHeight,
        cx0, cz0, cx1, cz1, k.gx, k.gz, 576, 180, k.sway, k.wind);
    console.log('count ' + c + ' ' + n);
    for (let i = 0; i < n; i++) {
        const t = pool[i];
        console.log('T ' + c + ' ' + t.ax + ' ' + t.ay + ' ' + t.az + ' ' +
            t.bx + ' ' + t.by + ' ' + t.bz + ' ' + t.d);
    }
}
"""

## `drawTufts(goat, TUFT, 576, 180)` (`goat.js` sceneFrame), so the gate asks with the
## same numbers the frame does.
const CULL2 := 576.0
const DETAIL2 := 180.0
## Floats per tuft, matching `Grass.STRIDE`.
const STRIDE := 7

## Where the herd is standing, how hard the wind is blowing, and what it has eaten.
## The first is the spawn bowl (the flattest ground there is, so the heights are all
## near zero and a sign slip in the height would not hide); the second is out in the
## field; the third is a negative anchor, where a floor into int32 has to round the
## right way; and the fourth is on eaten cells, including the anchor's own.
const CASES := [
	{"gx": 0.0, "gz": 0.0, "sway": 0.0, "wind": 0.0, "eaten": []},
	{"gx": 14.5, "gz": -3.2, "sway": 3.7, "wind": 1.2, "eaten": []},
	{"gx": -40.0, "gz": 25.0, "sway": 11.1, "wind": 0.4, "eaten": []},
	{"gx": 2.0, "gz": 2.0, "sway": 5.5, "wind": 0.9,
		"eaten": [[0, 0], [1, 1], [2, 0], [0, 2], [3, 3]]},
]

## The heightfield's own floor (`verify_terrain.gd`): `value_hash` takes `sin` at
## arguments in the millions, so the two engines' argument reduction differs and the
## agreement stops at about ten significant digits. The tuft *positions* inherit it
## through `terrainHeight`; the hash-derived ones would be exact on their own.
const TOLERANCE := 1e-9

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var source: String = JS.replace("__CASES__", JSON.stringify(CASES))
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var oracle := {}
	var counts := {}
	for line in answers:
		if line.begins_with("log count "):
			var count_parts: PackedStringArray = line.split(" ")
			if count_parts.size() == 4:
				counts[int(count_parts[2])] = int(count_parts[3])
			continue
		if not line.begins_with("log T "):
			continue
		var parts: PackedStringArray = line.split(" ")
		if parts.size() != 10:
			continue
		var case_index: int = int(parts[2])
		if not oracle.has(case_index):
			oracle[case_index] = PackedFloat64Array()
		for k in STRIDE:
			oracle[case_index].append(float(parts[3 + k]))

	print("oracle answered ", oracle.size(), " case(s)")

	var compared := 0
	var worst := 0.0
	var worst_at := ""
	var integer_mismatches := 0
	var first_integer_mismatch := ""
	for case_index in CASES.size():
		var c: Dictionary = CASES[case_index]
		var eaten := {}
		for cell: Array in c["eaten"]:
			eaten[(int(cell[0]) + 4096) * 8192 + (int(cell[1]) + 4096)] = true
		var mine: PackedFloat64Array = Grass.field(
			c["gx"], c["gz"], CULL2, DETAIL2, c["sway"], c["wind"], eaten)
		var expected: PackedFloat64Array = oracle.get(case_index, PackedFloat64Array())
		@warning_ignore("integer_division")
		var my_tufts: int = mine.size() / STRIDE
		@warning_ignore("integer_division")
		var js_tufts: int = expected.size() / STRIDE
		print("case %d at (%.1f, %.1f): gd %d tuft(s), js %d" % [
			case_index, c["gx"], c["gz"], my_tufts, js_tufts])
		if counts.get(case_index, -1) != js_tufts:
			failures.append("the oracle's own count for case %d disagrees with its tufts"
				% case_index)
		if my_tufts != js_tufts:
			integer_mismatches += 1
			if first_integer_mismatch == "":
				first_integer_mismatch = "case %d: gd %d tuft(s), js %d" % [
					case_index, my_tufts, js_tufts]
			continue
		for t in my_tufts:
			for k in STRIDE:
				var expected_value: float = expected[t * STRIDE + k]
				var difference: float = absf(mine[t * STRIDE + k] - expected_value)
				compared += 1
				# The near/far flag is an integer and has no tolerance.
				if k == 6 and difference != 0.0:
					integer_mismatches += 1
					if first_integer_mismatch == "":
						first_integer_mismatch = "case %d tuft %d: near/far gd %d, js %d" % [
							case_index, t, int(mine[t * STRIDE + k]), int(expected_value)]
				if difference > worst:
					worst = difference
					worst_at = "case %d tuft %d field %d: js %.17f, gd %.17f" % [
						case_index, t, k, expected_value, mine[t * STRIDE + k]]

	print("compared ", compared, " value(s)")
	print("largest disagreement: %.12f m (tolerance %.12f m)" % [worst, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)
	print("count/flag mismatches: ", integer_mismatches)
	if first_integer_mismatch != "":
		print("  first: ", first_integer_mismatch)

	host.free()

	if oracle.is_empty():
		failures.append("the oracle answered no case at all")
	if worst > TOLERANCE:
		failures.append("the port disagrees with the scene by %f (limit %f)"
			% [worst, TOLERANCE])
	if integer_mismatches != 0:
		failures.append("the meadow is not the scene's: %d integer mismatch(es)"
			% integer_mismatches)

	if failures.is_empty():
		print("OK: the GDScript meadow is the scene's meadow")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

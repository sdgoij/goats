# The meadow gate: `meadow.gd` against `food.js` and `weather.js`.
#
#   Godot --headless --path godot --script res://tools/verify_meadow.gd
#
# The grass a goat eats is *derived* from its cell, and the cell's hash is 32-bit
# wrap-around integer mixing (`Math.imul`, `>>>`, `| 0`) while GDScript's `int` is 64
# bits -- so the port re-implements the wrap, and a subtly wrong `imul` is not a
# slightly wrong meadow, it is a different one. `tools/verify_grass.gd` checks the
# same hash through the *drawing* path; this checks it through the *eating* path,
# plus the search, the bite and the countdown, which are `food.js`'s own.
#
# The oracle is the scene's JavaScript, run by the embedded engine, exactly as
# `verify_terrain.gd` and `verify_grass.gd` do it.
extends SceneTree

## `weather.js` / `food.js` / `core.js`, transcribed *from their sources*: the
## heightfield (as `verify_grass.gd` carries it, `TUNING.terrain` inlined) and
## `nearestTuft`, with the trap filter dropped -- a trap is `explosions.gd`'s and
## `verify_devices.gd` is its gate, so this asks the food question and only that.
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
// The cell hash, `weather.js` `tuftField` and `food.js` `nearestTuft` verbatim,
// as the raw uint32 bit patterns -- compared as integers, because a bit pattern is
// what the two engines either agree about or do not, and the `[0, 1)` derived from
// it is one division away from being a rendering question. Every use below divides
// from *these*, which is what `tuftField` does with the `h` in its hand.
function cellBits(cx, cz) {
    let h = (cx * 374761393 + cz * 668265263) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    h = (h ^ (h >>> 16)) >>> 0;
    let h2 = (cx * 1103515245 + cz * 12345) | 0;
    h2 = Math.imul(h2 ^ (h2 >>> 15), 2246822519);
    h2 = (h2 ^ (h2 >>> 13)) >>> 0;
    let h3 = (cx * 2654435761 + cz * 40503) | 0;
    h3 = Math.imul(h3 ^ (h3 >>> 16), 3266489917);
    h3 = (h3 ^ (h3 >>> 16)) >>> 0;
    return [h, h2, h3];
}
const TWO32 = 4294967296;
// The eaten cells the gate hands in, as `(cx, cz)` pairs, mapped the way the wire
// maps them -- the same `tuftKey` the port records a bite under.
function tuftKey(cx, cz) { return (cx + 4096) * 8192 + (cz + 4096); }
const EATEN = new Set();
for (const cell of __EATEN__) EATEN.add(tuftKey(cell[0], cell[1]));
function nearestTuft(x, z, range) {
    const r = Math.ceil(range / 2);
    const cx = Math.floor(x / 2);
    const cz = Math.floor(z / 2);
    let best = null;
    let bestD2 = range * range;
    for (let i = cx - r; i <= cx + r; i++) {
        for (let j = cz - r; j <= cz + r; j++) {
            const b = cellBits(i, j);
            const a = b[0] / TWO32;
            if (a < 0.45) continue;
            if (EATEN.has(tuftKey(i, j))) continue;
            const tx = i * 2 + (b[1] / TWO32 - 0.5) * 1.8;
            const tz = j * 2 + (a - 0.5) * 1.8;
            const dx = tx - x;
            const dz = tz - z;
            const d2 = dx * dx + dz * dz;
            if (d2 <= bestD2) { bestD2 = d2; best = { x: tx, z: tz, cx: i, cz: j, d2: d2 }; }
        }
    }
    return best;
}
// Every cell hash over a range, so the gate has the primitive itself and not only
// what `nearest` happens to reach.
for (let cx = -3; cx <= 3; cx++) {
    for (let cz = -3; cz <= 3; cz++) {
        const b = cellBits(cx, cz);
        console.log('H ' + cx + ' ' + cz + ' ' + b[0] + ' ' + b[1] + ' ' + b[2]);
    }
}
const SAMPLES = __SAMPLES__;
for (let i = 0; i < SAMPLES.length; i++) {
    const s = SAMPLES[i];
    const t = nearestTuft(s[0], s[1], 1.1);
    if (t === null) console.log('N ' + i + ' none');
    else console.log('N ' + i + ' ' + t.x + ' ' + t.z + ' ' + t.cx + ' ' + t.cz + ' ' + t.d2);
}
"""

## `TUNING.food.eatRange`, so the gate asks with the range a keypress does.
const EAT_RANGE := 1.1
## Cells the gate has grazed, on and beside the tufts the samples stand on. It is
## what makes the search's skip real rather than a branch nothing took.
const EATEN := [[0, 0], [1, 0], [-1, 0], [2, 2]]

## Where the goat is standing. The first is the spawn bowl, the second is a run of
## points through the field (tuft or not, near or far), the third is negative, where
## a floor into int32 has to round the right way.
const SAMPLES := [
	[0.0, 0.0], [2.0, 0.0], [0.0, 2.0], [1.0, 1.0], [-1.0, 0.0], [-2.0, -2.0],
	[4.0, 4.0], [5.0, 5.0], [14.5, -3.2], [-40.0, 25.0], [9.0, -9.0], [6.0, 0.0],
]

## `value_hash` takes `sin` at arguments in the millions, so the position of a tuft
## carries the heightfield's own floor -- 5e-11 m, measured by `verify_terrain.gd`.
## The hashes themselves are integer arithmetic and would be exact.
const TOLERANCE := 1e-9

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var source: String = JS.replace("__EATEN__", JSON.stringify(EATEN)) \
		.replace("__SAMPLES__", JSON.stringify(SAMPLES))
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var hashes := {}
	var nearest := {}
	for line in answers:
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log H ") and parts.size() == 7:
			hashes[Vector2i(int(parts[2]), int(parts[3]))] = Vector3i(
				int(parts[4]), int(parts[5]), int(parts[6]))
		elif line.begins_with("log N ") and parts.size() == 8:
			# `PackedFloat64Array` and not a `Vector4`, and that is the whole reason this
			# gate is worth reading twice: a Godot vector type is **float32**, so storing the
			# oracle's positions in one rounds the *oracle* to the port's own grid -- and the
			# two then agree perfectly about a mistake they are sharing. It passed that way
			# for as long as `meadow.gd` narrowed its tuft positions through a `Vector2`, and
			# only showed up once the port stopped. See `PORT.md` section 9.
			nearest[int(parts[2])] = PackedFloat64Array([
				float(parts[3]), float(parts[4]), float(parts[5]), float(parts[6])])
		elif line.begins_with("log N ") and parts.size() == 4 and parts[3] == "none":
			nearest[int(parts[2])] = PackedFloat64Array([INF, 0.0, 0.0, 0.0])

	print("oracle answered ", hashes.size(), " cell hash(es), ", nearest.size(), " search(es)")

	# The hash itself: three *bits* per cell over a range that includes the negative
	# cells, compared as integers because that is what the two engines either agree
	# about or do not -- a bit pattern has no rounding to hide behind, and the
	# `[0, 1)` the field divides it into is a separate question.
	var worst_hash := 0.0
	var hash_mismatches := 0
	var first_hash_mismatch := ""
	for cell: Vector2i in hashes:
		var wanted: Vector3i = hashes[cell]
		var got: Vector3i = Meadow.cell_hash(cell.x, cell.y)
		for axis in 3:
			var difference: float = absf(float(got[axis]) - float(wanted[axis]))
			if difference > worst_hash:
				worst_hash = difference
			if got[axis] != wanted[axis]:
				hash_mismatches += 1
				if first_hash_mismatch == "":
					first_hash_mismatch = "cell (%d, %d) axis %d: js %d, gd %d" % [
						cell.x, cell.y, axis, wanted[axis], got[axis]]

	# The search: the tuft, its cell and its distance, over a meadow with a few
	# cells already eaten.
	var meadow := Meadow.new()
	for cell: Array in EATEN:
		meadow.eaten[Meadow.key(int(cell[0]), int(cell[1]))] = 30.0
	var worst_search := 0.0
	var found := 0
	var not_found := 0
	var cell_mismatches := 0
	var first_cell_mismatch := ""
	for i in SAMPLES.size():
		var spot: Array = SAMPLES[i]
		var wanted: PackedFloat64Array = nearest[i]
		var got: Dictionary = meadow.nearest(spot[0], spot[1], EAT_RANGE)
		if wanted[0] == INF:
			# The oracle found nothing in reach: the port must not either.
			if not got.is_empty():
				not_found += 1
			continue
		found += 1
		if got.is_empty():
			not_found += 1
			continue
		worst_search = maxf(worst_search, absf(float(got["x"]) - wanted[0]))
		worst_search = maxf(worst_search, absf(float(got["z"]) - wanted[1]))
		if int(got["cx"]) != int(wanted[2]) or int(got["cz"]) != int(wanted[3]):
			cell_mismatches += 1
			if first_cell_mismatch == "":
				first_cell_mismatch = "sample %d: js cell (%d, %d), gd (%d, %d)" % [
					i, int(wanted[2]), int(wanted[3]), int(got["cx"]), int(got["cz"])]

	print("cell hashes disagreed by at most %d bit(s)" % int(worst_hash))
	print("cell hash mismatches: ", hash_mismatches)
	if first_hash_mismatch != "":
		print("  first: ", first_hash_mismatch)
	print("%d search(es) hit, %d missed (the oracle's own misses included)" % [found, not_found])
	print("nearest-tuft disagreement: %.12f m (tolerance %.12f m)" % [worst_search, TOLERANCE])
	print("cell mismatches: ", cell_mismatches)
	if first_cell_mismatch != "":
		print("  first: ", first_cell_mismatch)

	# The bite and the countdown: a tuft goes, its cell is recorded with a duration
	# in the tuning's window, and it comes back when the countdown runs out. This is
	# the half of the meadow no oracle can see, so it is checked as behaviour.
	var bites := Meadow.new()
	var eaten_ok := true
	var first_eaten := {}
	for cell: Vector2i in hashes:
		if Meadow.cell_exists(cell.x, cell.y) and first_eaten.is_empty():
			first_eaten = {"cx": cell.x, "cz": cell.y}
	if first_eaten.is_empty():
		failures.append("the meadow grows no tuft in the sampled cells at all")
	else:
		var cx: int = first_eaten["cx"]
		var cz: int = first_eaten["cz"]
		if not bites.consume(cx, cz):
			eaten_ok = false
		var left: float = float(bites.eaten.get(Meadow.key(cx, cz), -1.0))
		if left < 40.0 or left > 90.0:
			eaten_ok = false
		if bites.consume(cx, cz):
			eaten_ok = false          # a cell cannot be eaten twice
		# ...and it is back once the window has run, and not before.
		bites.update(left - 1.0, true)
		var early: bool = bites.has_tuft(cx, cz)
		bites.update(2.0, true)
		var late: bool = bites.has_tuft(cx, cz)
		if early or not late:
			eaten_ok = false
		# A day of the host's countdown must not pass in a client: `update` counts
		# down only where the scene is its own host, so the tuft is *still* gone.
		bites.consume(cx, cz)
		bites.update(1000.0, false)
		if bites.has_tuft(cx, cz):
			eaten_ok = false
		print("bite: %s (one tuft, hidden for %.1f s, then back)" % ["ok" if eaten_ok else "WRONG", left])

	# Round-tripping a key is what lets the wire's `eaten` list name a cell.
	var key_ok := true
	for cx in range(-5, 6):
		for cz in range(-5, 6):
			var cell: Vector2i = Meadow.cell_of(Meadow.key(cx, cz))
			if cell.x != cx or cell.y != cz:
				key_ok = false
	print("key <-> cell round trip: ", "ok" if key_ok else "WRONG")

	host.free()

	if hashes.size() != 49:
		failures.append("the oracle answered %d cell hash(es), expected 49" % hashes.size())
	if nearest.size() != SAMPLES.size():
		failures.append("the oracle answered %d search(es), expected %d"
			% [nearest.size(), SAMPLES.size()])
	if worst_hash > 0.0:
		failures.append("the cell hash differs from the scene's")
	if hash_mismatches != 0:
		failures.append("the cell hash mismatched in %d place(s)" % hash_mismatches)
	if worst_search > TOLERANCE:
		failures.append("the nearest tuft differs by %f (limit %f)"
			% [worst_search, TOLERANCE])
	if not_found != 0:
		failures.append("the search and the scene disagree about whether %d tuft(s) are in reach"
			% not_found)
	if cell_mismatches != 0:
		failures.append("the search returned the wrong cell %d time(s)" % cell_mismatches)
	if not eaten_ok:
		failures.append("the bite is not the scene's: a tuft did not go, stay gone, or return")
	if not key_ok:
		failures.append("a cell key does not round-trip, so the wire's `eaten` cannot name a cell")

	if failures.is_empty():
		print("OK: the GDScript meadow is the scene's meadow, and it can be eaten")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

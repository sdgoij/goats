# The water gate: `water.gd` against `water.js`.
#
#   Godot --headless --path godot --script res://tools/verify_water.gd
#
# The water is a *level* over a *ground*, so the two things it can get wrong are the
# level and the ground it reads. It is checked against the scene's own arithmetic for
# both:
#
#   1. **The level.** A scripted rain history -- a dry spell, a shower rising through
#      `seep` to a downpour, then a drain in 60-second bites (the easing) and one
#      `wetDown`-long step (the exact zero) -- is run through both sides, and the level,
#      the wetting, the wet-cell count, the volume and the deepest point are compared
#      after every step. The rise being *immediate* is what makes this a level rather
#      than a simulation, so it is also what makes it comparable at all.
#
#   2. **The ground it reads.** The scene's water is the table over the *terrain grid's
#      vertex heights*, not over the continuous field, so the depth a goat wades in is
#      the depth of the thing it is standing in. That grid is this gate's one shared
#      input: it is built once by `TerrainMesh` (the real one) and injected into the
#      oracle, so both sides read identical ground. *The grid's own correctness is
#      `verify_terrain_mesh.gd`'s* -- it checks every vertex against the double field --
#      and this gate takes it as a premise rather than re-deriving it, which is the one
#      place a shared input is honest: the alternative is two copies of a heightfield
#      that could disagree, and the depths below would then be comparing nothing.
#
# The `flood <h>` override and the `enabled` leaf are staged after the history, because
# a rain history cannot reach either -- and they are the bisect's two handles, so a
# gate that skipped them would not cover the system's off switch.
#
# The oracle is transcribed from `crates/goats/src/game/water.js` and never from the
# port (see `verify_goat.gd`'s note and `PORT.md` section 9). It is the same file
# `crates/harness/tests/water.rs` asserts against, so the two voices agree by
# construction rather than by coincidence.
extends SceneTree

## `water.js` (the field, the depth, the wading) and `core.js` (`TUNING.water`,
## `netRound3`), transcribed *from their sources*. Two deliberate re-parameterisations,
## both of them the port's own shape: `waterSpeedFactor`/`waterDrainFactor`/
## `waterHudText` take the goat's place as arguments rather than reading a global, and
## the grid and the anchor are injected.
const JS := """
const TUNING = { water: {
    enabled: 1, low: -2.1, high: 0, fill: 0.75, seep: 0.05, wetDown: 600,
    maxDepth: 0.6, drag: 0.35, dragEnergy: 0.25,
} };
const WATER_WET_CURVE = 0.5;
const WATER_DRY_EPS = 1e-4;
const WATER_HUD_MIN = 0.01;
const WATER_N = 49, WATER_CELL = 2, WATER_HALF = 48;
const T_H = __HEIGHTS__;
const AX = __ANCHOR_X__, AZ = __ANCHOR_Z__;
function netRound3(v) { return Math.round(v * 1000) / 1000; }

let waterReady = false, waterLevel = 0, waterWet = 0, waterGround = 0;
let waterForce = NaN, waterOn = false;
let rainAmount = 0;

function wetnessFor(rain) {
    const t = TUNING.water;
    const raw = (rain - t.seep) / (1 - t.seep);
    if (raw <= 0) return 0;
    return Math.pow(raw > 1 ? 1 : raw, WATER_WET_CURVE);
}
function waterStep(dt) {
    const target = wetnessFor(rainAmount);
    if (target < waterWet) {
        const down = TUNING.water.wetDown;
        const k = down > 1e-6 ? Math.min(1, dt / down) : 1;
        waterWet += (target - waterWet) * k;
        if (waterWet < WATER_DRY_EPS) waterWet = 0;
    }
    waterUpdate();
}
function waterUpdate() {
    if (!waterReady) return;
    const target = wetnessFor(rainAmount);
    if (target > waterWet) waterWet = target;
    const t = TUNING.water;
    if (t.enabled === 0) waterLevel = t.low;
    else if (isFinite(waterForce)) waterLevel = waterForce;
    else if (waterWet <= 0) waterLevel = t.low;
    else waterLevel = t.low + waterWet * t.fill * (t.high - t.low);
    waterOn = waterLevel > waterGround + 1e-6;
}
function waterRebuild() {
    let ground = Infinity;
    for (let k = 0; k < WATER_N * WATER_N; k++) {
        const g = T_H[k];
        if (g < ground) ground = g;
    }
    waterGround = ground;
    waterReady = true;
    waterUpdate();
}
function waterSetForce(level) { waterForce = isFinite(level) ? level : NaN; waterUpdate(); }
function waterForceOff() { waterForce = NaN; waterUpdate(); }
function waterVertexDepth(k) { const d = waterLevel - T_H[k]; return d > 0 ? d : 0; }
function waterDepthAt(x, z) {
    if (!waterReady || TUNING.water.enabled === 0) return 0;
    const fx = (x - (AX - WATER_HALF)) / WATER_CELL;
    const fz = (z - (AZ - WATER_HALF)) / WATER_CELL;
    const i = Math.floor(fx), j = Math.floor(fz);
    if (i < 0 || j < 0 || i >= WATER_N - 1 || j >= WATER_N - 1) return 0;
    const u = fx - i, v = fz - j;
    const k = j * WATER_N + i;
    const d00 = waterVertexDepth(k), d10 = waterVertexDepth(k + 1);
    const d01 = waterVertexDepth(k + WATER_N), d11 = waterVertexDepth(k + WATER_N + 1);
    const top = d00 + (d10 - d00) * u, bot = d01 + (d11 - d01) * u;
    return top + (bot - top) * v;
}
function waterDragFraction(x, z) {
    const depth = waterDepthAt(x, z);
    if (depth <= 0) return 0;
    const cap = TUNING.water.maxDepth;
    if (cap <= 0) return 1;
    return depth / cap > 1 ? 1 : depth / cap;
}
function waterSpeedFactor(x, z) { return 1 - TUNING.water.drag * waterDragFraction(x, z); }
function waterDrainFactor(x, z) { return 1 + TUNING.water.dragEnergy * waterDragFraction(x, z); }
function waterHudText(x, z) {
    const depth = waterDepthAt(x, z);
    if (depth < WATER_HUD_MIN) return "";
    return "water " + depth.toFixed(2) + " m   slowed " +
        Math.round(TUNING.water.drag * waterDragFraction(x, z) * 100) + "%";
}
function sceneWater(px, pz) {
    const count = WATER_N * WATER_N;
    const area = WATER_CELL * WATER_CELL;
    const level = waterLevel;
    let wet = 0, volume = 0, deepest = 0, di = 0, dj = 0;
    for (let k = 0; k < count; k++) {
        const d = level - T_H[k];
        if (d <= 0) continue;
        wet++;
        volume += d * area;
        if (d > deepest) {
            deepest = d;
            const i = k % WATER_N;
            di = i;
            dj = (k - i) / WATER_N;
        }
    }
    const x0 = AX - WATER_HALF, z0 = AZ - WATER_HALF;
    return {
        level: netRound3(isFinite(level) ? level : 0),
        enabled: TUNING.water.enabled !== 0,
        forced: isFinite(waterForce),
        on: waterOn,
        wetting: netRound3(waterWet),
        wet: wet,
        cells: count,
        volume: netRound3(volume),
        deepest: netRound3(deepest),
        deepX: netRound3(x0 + di * WATER_CELL),
        deepZ: netRound3(z0 + dj * WATER_CELL),
        goatDepth: netRound3(waterDepthAt(px, pz)),
        ground: netRound3(waterGround),
        floor: netRound3(TUNING.water.low),
        high: netRound3(TUNING.water.high),
        rise: netRound3(level - TUNING.water.low),
        drag: waterSpeedFactor(px, pz),
        drain: waterDrainFactor(px, pz),
    };
}

const GOAT_X = __GOAT_X__, GOAT_Z = __GOAT_Z__;
const PROBES = __PROBES__;
function emitState(tag) {
    const st = sceneWater(GOAT_X, GOAT_Z);
    console.log('S ' + tag + ' ' + [st.level, st.wetting, st.on ? 1 : 0, st.wet, st.volume,
        st.deepest, st.deepX, st.deepZ, st.ground, st.rise, st.goatDepth, st.drag,
        st.drain, st.enabled ? 1 : 0, st.forced ? 1 : 0].join(' '));
    for (const p of PROBES) {
        const depth = waterDepthAt(p[0], p[1]);
        console.log('D ' + tag + ' ' + p[0] + ' ' + p[1] + ' ' + depth + ' ' +
            waterSpeedFactor(p[0], p[1]) + ' ' + waterDrainFactor(p[0], p[1]) + ' ' +
            waterHudText(p[0], p[1]).replace(/ /g, '|'));
    }
}

waterRebuild();
emitState(-1);
const SCRIPT = __SCRIPT__;
for (let s = 0; s < SCRIPT.length; s++) {
    rainAmount = SCRIPT[s][1];
    waterStep(SCRIPT[s][0]);
    emitState(s);
}
// The two handles a rain history cannot reach: the `flood <h>` override (a level that
// is *not* the rain's) and the enabled leaf. A downpour is put back first, so the off
// switch has a level to switch off -- otherwise both would read the dry floor and the
// leaf would be tested by nothing.
rainAmount = 1.0;
waterStep(0);
emitState(899);
waterSetForce(0.5);
emitState(900);
waterForceOff();
emitState(901);
TUNING.water.enabled = 0;
waterUpdate();
emitState(902);
TUNING.water.enabled = 1;
waterUpdate();
emitState(903);
"""

## The rain history, as `[dt, rain]` pairs. It walks the four things the level depends
## on: the `seep` floor exactly (rain 0.05 is still dry, 0.06 is not), the concave rise,
## a downpour at the ceiling, the drain in 60-second bites (`k = dt / wetDown`), and one
## `wetDown`-long step, which snaps the wetting to a hard zero -- the dry spell that has
## to be *exactly* dry.
const SCRIPT := [
	[1.0, 0.0],
	[1.0, 0.02],
	[1.0, 0.05],
	[1.0, 0.06],
	[1.0, 0.15],
	[1.0, 0.40],
	[1.0, 0.75],
	[1.0, 1.0],
	[1.0, 1.0],
	[60.0, 0.40],
	[60.0, 0.40],
	[60.0, 0.40],
	[60.0, 0.0],
	[60.0, 0.0],
	[600.0, 0.0],
	[1.0 / 60.0, 0.0],
]

## Where the read-out is asked from: a point inside the field, used for `state`'s
## `goatDepth`/`drag`/`drain`.
const GOAT := Vector2(6.5, -2.5)
## The points the depth, the two factors and the HUD line are compared at: the field's
## centre, the middle of a row, a corner, a point outside the grid, and the goat's own.
const PROBES := [
	Vector2(0.0, 0.0),
	Vector2(10.0, 5.0),
	Vector2(-40.0, -40.0),
	Vector2(60.0, 60.0),
	Vector2(6.5, -2.5),
]

## The field is `pow` and division, so the two engines differ by an ULP or two of the
## libm and nothing else. A nanometre of water is nine orders above that and nothing at
## all in a table whose band is 2.1 m.
const TOLERANCE := 1e-9

func _initialize() -> void:
	var failures: Array[String] = []
	## What the wiring section finds, if anything: it is the one thing here that is not
	## this file's own arithmetic but `PlayerGoat`'s use of it.
	var wire_failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	# The grid, from the real mesh, so both sides read the same ground.
	var mesh := TerrainMesh.new()
	root.add_child(mesh)
	mesh.build(0.0, 0.0)
	var heights: PackedFloat64Array = mesh.heights()
	var anchor: Vector2 = mesh.anchor()
	if heights.size() != Water.N * Water.N:
		print("FAIL: the terrain grid is ", heights.size(), " vertices, expected ",
			Water.N * Water.N)
		quit(1)
		return
	var as_array: Array = []
	as_array.assign(heights)
	print("grid: %d vertices at anchor (%.0f, %.0f), lowest ground %.6f"
		% [heights.size(), anchor.x, anchor.y, _lowest(heights)])

	var probes: Array = []
	for p: Vector2 in PROBES:
		probes.append([p.x, p.y])

	var source: String = JS \
		.replace("__HEIGHTS__", JSON.stringify(as_array)) \
		.replace("__ANCHOR_X__", str(anchor.x)) \
		.replace("__ANCHOR_Z__", str(anchor.y)) \
		.replace("__GOAT_X__", str(GOAT.x)) \
		.replace("__GOAT_Z__", str(GOAT.y)) \
		.replace("__PROBES__", JSON.stringify(probes)) \
		.replace("__SCRIPT__", JSON.stringify(SCRIPT))
	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var states: Array[String] = []
	var depths: Array[String] = []
	for line in answers:
		if line.begins_with("log S "):
			states.append(line.substr(6))
		elif line.begins_with("log D "):
			depths.append(line.substr(6))
	print("oracle answered ", states.size(), " state(s), ", depths.size(), " probe(s)")

	var water := Water.new()
	water.rebuild(heights, anchor)
	var worst := 0.0
	var worst_at := ""
	var mismatches := 0
	var first_mismatch := ""
	var compared := 0

	# The oracle's own order: the initial state, one per script step, then the five
	# staged ones.
	var tags: Array[int] = [-1]
	for i in SCRIPT.size():
		tags.append(i)
	tags.append_array([899, 900, 901, 902, 903])

	for index in tags.size():
		var tag: int = tags[index]
		if tag == 899:
			water.step(0.0, 1.0)
		elif tag == 900:
			water.set_force(0.5)
		elif tag == 901:
			water.force_off()
		elif tag == 902:
			water.enabled = false
			water.update()
		elif tag == 903:
			water.enabled = true
			water.update()
		elif tag >= 0:
			water.step(float(SCRIPT[tag][0]), float(SCRIPT[tag][1]))

		if index >= states.size():
			mismatches += 1
			if first_mismatch == "":
				first_mismatch = "no oracle state for tag %d" % tag
			continue
		var parts: PackedStringArray = states[index].split(" ")
		if parts.size() != 16:
			mismatches += 1
			if first_mismatch == "":
				first_mismatch = "tag %d: the oracle line has %d field(s), expected 16" % [
					tag, parts.size()]
			continue
		var st: Dictionary = water.state(GOAT.x, GOAT.y)
		# The numbers, in the oracle's own order, with the three flags compared as
		# *flags* -- `on`, `enabled`, `forced` are booleans and a tolerance would hide a
		# wrong one behind a right number.
		var wanted: Array[float] = []
		for k in 13:
			wanted.append(float(parts[1 + k]))
		var got: Array[float] = [
			float(st["level"]), float(st["wetting"]), 1.0 if st["on"] else 0.0,
			float(st["wet"]), float(st["volume"]), float(st["deepest"]), float(st["deepX"]),
			float(st["deepZ"]), float(st["ground"]), float(st["rise"]),
			float(st["goatDepth"]), float(st["drag"]), float(st["drain"]),
		]
		for k in got.size():
			compared += 1
			var gap: float = absf(got[k] - wanted[k])
			if gap > worst:
				worst = gap
				worst_at = "tag %d field %d: scene %.17f, port %.17f" % [
					tag, k, wanted[k], got[k]]
			if gap > TOLERANCE:
				mismatches += 1
				if first_mismatch == "":
					first_mismatch = "tag %d field %d: scene %.17f, port %.17f" % [
						tag, k, wanted[k], got[k]]
		var flags: Array[bool] = [bool(st["enabled"]), bool(st["forced"])]
		var wanted_flags: Array[bool] = [parts[14] == "1", parts[15] == "1"]
		for k in 2:
			compared += 1
			if flags[k] != wanted_flags[k]:
				mismatches += 1
				if first_mismatch == "":
					first_mismatch = "tag %d flag %d: scene %s, port %s" % [
						tag, k, str(wanted_flags[k]), str(flags[k])]

		# ...and the depth, the two factors and the HUD line at each probe point.
		var base: int = index * PROBES.size()
		for j in PROBES.size():
			if base + j >= depths.size():
				mismatches += 1
				if first_mismatch == "":
					first_mismatch = "no oracle probe for tag %d point %d" % [tag, j]
				continue
			var dparts: PackedStringArray = depths[base + j].split(" ")
			if dparts.size() != 7:
				mismatches += 1
				if first_mismatch == "":
					first_mismatch = "tag %d point %d: %d field(s), expected 7" % [
						tag, j, dparts.size()]
				continue
			var probe: Vector2 = PROBES[j]
			var mine: Array[float] = [
				water.depth_at(probe.x, probe.y),
				water.speed_factor(probe.x, probe.y),
				water.drain_factor(probe.x, probe.y),
			]
			for k in 3:
				compared += 1
				var gap: float = absf(mine[k] - float(dparts[3 + k]))
				if gap > worst:
					worst = gap
					worst_at = "tag %d point %d field %d: scene %.17f, port %.17f" % [
						tag, j, k, float(dparts[3 + k]), mine[k]]
				if gap > TOLERANCE:
					mismatches += 1
					if first_mismatch == "":
						first_mismatch = "tag %d point %d field %d: scene %.17f, port %.17f" % [
							tag, j, k, float(dparts[3 + k]), mine[k]]
			# The HUD line, with its spaces stood in for so it survives a split: the
			# *threshold* and the wrapped numbers are the transcription, and a dry frame
			# has to read exactly as it always has.
			compared += 1
			var mine_text: String = water.hud_text(probe.x, probe.y).replace(" ", "|")
			var wanted_text: String = dparts[6]
			if mine_text != wanted_text:
				mismatches += 1
				if first_mismatch == "":
					first_mismatch = "tag %d point %d HUD: scene %s, port %s" % [
						tag, j, "\"%s\"" % wanted_text, "\"%s\"" % mine_text]

	# ---- the wiring ------------------------------------------------------------
	#
	# No number above can see whether the goat *uses* any of this. `player_goat.gd` takes
	# the two factors and multiplies them into the speed and the drain, and a gate that
	# checked the field and not the seam would pass with the multiplication deleted --
	# which is the failure mode this port has already been bitten by (see
	# `verify_goat.gd`'s note and `PORT.md` section 9).
	var dry := PlayerGoat.new()
	root.add_child(dry)
	dry.ready_up()
	var dry_speed: float = dry.ground_speed()
	dry.step(1.0 / 60.0, {}, 1.0, {}, null, Callable(), {"speed": 0.5, "drain": 1.0})
	var wading_speed: float = dry.ground_speed()
	print("wiring: dry %.6f m/s, at half the water's speed %.6f m/s, ratio %.6f"
		% [dry_speed, wading_speed, wading_speed / dry_speed])
	if dry_speed <= 0.0 or absf(wading_speed / dry_speed - 0.5) > 1e-9:
		wire_failures.append("the goat's speed does not take the water's factor")

	# The drain, the other half of the same wiring: sixty idle frames with the water's
	# `drain` doubled have to cost exactly twice the energy.
	var light := PlayerGoat.new()
	root.add_child(light)
	light.ready_up()
	light.energy = 50.0
	var heavy := PlayerGoat.new()
	root.add_child(heavy)
	heavy.ready_up()
	heavy.energy = 50.0
	for i in 60:
		light.step(1.0 / 60.0, {}, 1.0, {}, null)
		heavy.step(1.0 / 60.0, {}, 1.0, {}, null, Callable(), {"speed": 1.0, "drain": 2.0})
	var spent: float = 50.0 - light.energy
	var spent_heavy: float = 50.0 - heavy.energy
	print("wiring: 60 idle frames cost %.6f energy, and %.6f at double the water's drain"
		% [spent, spent_heavy])
	if spent <= 0.0 or absf(spent_heavy - spent * 2.0) > 1e-9:
		wire_failures.append("the goat's energy drain does not take the water's factor")
	dry.free()
	light.free()
	heavy.free()

	host.free()
	mesh.free()

	print("compared %d value(s) over %d state(s)" % [compared, tags.size()])
	print("largest disagreement: %.15f (tolerance %.15f)" % [worst, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)
	print("mismatches: ", mismatches)
	if first_mismatch != "":
		print("  first: ", first_mismatch)

	if states.size() != tags.size():
		failures.append("the oracle answered %d state(s), expected %d"
			% [states.size(), tags.size()])
	if depths.size() != tags.size() * PROBES.size():
		failures.append("the oracle answered %d probe(s), expected %d"
			% [depths.size(), tags.size() * PROBES.size()])
	if mismatches != 0:
		failures.append("the water is not the scene's: %d mismatch(es)" % mismatches)
	if worst > TOLERANCE:
		failures.append("the water disagrees with the scene by %f (limit %f)"
			% [worst, TOLERANCE])
	failures.append_array(wire_failures)

	if failures.is_empty():
		print("OK: the GDScript water is the scene's water")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

func _lowest(heights: PackedFloat64Array) -> float:
	var lowest: float = INF
	for h in heights:
		if h < lowest:
			lowest = h
	return lowest

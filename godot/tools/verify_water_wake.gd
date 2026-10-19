# The wake gate: `water.gd`'s wake, splashes and submerged grass against `water.js`'s.
#
#   Godot --headless --path godot --script res://tools/verify_water_wake.gd
#
# M20d is the water's *interactions*: the rings a hoof leaves, the drops it throws, and the
# tufts a pool hides. Three of them are rules and the fourth is plumbing:
#
#   1. **The wake is a pool of three rings**, laid in the *weakest* slot because a ring's
#      strength decays with its age, so the weakest is the oldest and there is no index to
#      keep. A ring is laid by **distance travelled from the last ring** -- not from the last
#      frame, which was the scene's own bug: a goat at a walk moves two centimetres a frame,
#      so a gate measured against one frame's travel never fired at all and only a teleport
#      could trip it.
#   2. **A splash is a pool of drops** whose direction comes off `value_hash`, so no two are
#      alike; the count is the strength's, the slots are a ring buffer, and the arc is a
#      shallow ballistic one under its own gravity.
#   3. **A step in is bigger than a stride**, a goat that is merely *standing* in a pool
#      throws nothing, and one in the air over it is not in it at all. The herd gets the
#      same edge and the same footfall and **no ring** -- `RIPPLE_MAX` is three slots and
#      seven walking bots would be the whole of the wake.
#   4. **Two water tests, and they are not the same question.** `in_water` is the HUD's own
#      line (a bilinear depth at the point against a centimetre) and it is what a rule
#      reads: a goat does not doze in it. `submerged_at` is the *grid vertex* nearest the
#      point, and it is what the grass cull asks. The gate asserts they *disagree* somewhere
#      in its probes, because a port that had collapsed them into one function would
#      otherwise pass every check here.
#
# The oracle is `water.js` -- the heightfield, the depth helpers, the two tests and the
# whole wake -- **not** the port. Two deliberate re-parameterisations, both this port's own
# shape already: `waterActorStep` takes the frame's actors as an argument rather than
# reading the scene's module globals, and the grid and the anchor are injected (built once
# by the real `TerrainMesh`, as `verify_water.gd` does), so both sides read identical
# ground. The grass cull is checked with `weather.js`'s `tuftField` plus `drawTufts`' own
# skip, which is where the scene does it.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
extends SceneTree

## `world.js`, `water.js` and `weather.js`, transcribed *from their sources*.
const JS := """
// ---- the ground, `world.js`'s -------------------------------------------------
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
    const broad = 0.62 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1);
    const middle = 0.26 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9);
    const fine = 0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3);
    return broad + middle + fine;
}
function terrainBaseHeight(x, z) {
    const d = Math.sqrt(x * x + z * z);
    let t = (d - 6) / 16;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    t = t * t * (3 - 2 * t);
    return (terrainShape(x, z) - 0.5) * 2 * 2.1 * t;
}

// ---- the field, `water.js`'s --------------------------------------------------
const TUNING = { water: {
    enabled: 1, low: -2.1, high: 0, fill: 0.75, seep: 0.05, wetDown: 600,
    maxDepth: 0.6, drag: 0.35, dragEnergy: 0.25,
} };
const WATER_HUD_MIN = 0.01;
const WATER_N = __N__, WATER_CELL = 2, WATER_HALF = 48;
const T_H = __HEIGHTS__;
const AX = __AX__, AZ = __AZ__;
// The level is *forced* by the tape rather than poured by the rain: M20d is about what the
// water does to a goat, and a level a test can name is what makes a depth a number.
let waterLevel = __LEVEL__;
let waterOn = true;

function waterVertexDepth(k) { const d = waterLevel - T_H[k]; return d > 0 ? d : 0; }
function waterDepthAt(x, z) {
    if (!waterOn || TUNING.water.enabled === 0) return 0;
    const fx = (x - (AX - WATER_HALF)) / WATER_CELL;
    const fz = (z - (AZ - WATER_HALF)) / WATER_CELL;
    const i = Math.floor(fx);
    const j = Math.floor(fz);
    if (i < 0 || j < 0 || i >= WATER_N - 1 || j >= WATER_N - 1) return 0;
    const u = fx - i;
    const v = fz - j;
    const k = j * WATER_N + i;
    const d00 = waterVertexDepth(k);
    const d10 = waterVertexDepth(k + 1);
    const d01 = waterVertexDepth(k + WATER_N);
    const d11 = waterVertexDepth(k + WATER_N + 1);
    const top = d00 + (d10 - d00) * u;
    const bot = d01 + (d11 - d01) * u;
    return top + (bot - top) * v;
}
function waterInWater(x, z) { return waterDepthAt(x, z) >= WATER_HUD_MIN; }
let waterCulled = 0;
function waterSubmergedAt(x, z) {
    if (!waterOn) return false;
    const i = Math.round((x - (AX - WATER_HALF)) / WATER_CELL);
    const j = Math.round((z - (AZ - WATER_HALF)) / WATER_CELL);
    if (i < 0 || j < 0 || i >= WATER_N || j >= WATER_N) return false;
    const k = j * WATER_N + i;
    if (T_H[k] >= waterLevel) return false;
    waterCulled += 1;
    return true;
}
// `waterUpdate`'s two lines that matter here: the count starts each frame, and *no water is
// also no wake* -- the goat cannot be standing in what is not there.
function setLevel(level, lowest) {
    waterLevel = level;
    waterOn = waterLevel > lowest + 1e-6;
    waterCulled = 0;
    if (!waterOn && MARKS.length > 0) MARKS[0].wet = false;
}

// ---- the wake and the splashes, `water.js`'s ---------------------------------
const RIPPLE_MAX = 3, RIPPLE_LIFE = 1.6, RIPPLE_SPEED = 1.1;
const RIPPLE_STEP = 0.45, RIPPLE_MIN_DEPTH = 0.04;
const SPLASH_MAX = 24, SPLASH_DROPS = 8, SPLASH_LIFE = 0.55, SPLASH_GRAVITY = 14;
const RIPPLE = [];
for (let i = 0; i < RIPPLE_MAX; i++) RIPPLE.push({ x: 0, z: 0, r: 0, s: 0 });
const SPLASH = [];
let splashTop = 0, waterThrown = 0;
// One mark an actor, the goat at 0 -- `goatWet`/`rippleLast` and each bot's own fields in
// the scene, one list here for the same reason the port has one.
const MARKS = [{ wet: false, x: 0, z: 0 }];

function waterRippleAdd(x, z, strength) {
    let at = 0;
    for (let i = 1; i < RIPPLE_MAX; i++) if (RIPPLE[i].s < RIPPLE[at].s) at = i;
    const slot = RIPPLE[at];
    slot.x = x;
    slot.z = z;
    slot.r = 0;
    slot.s = strength;
}
function waterRipplesLive() {
    let n = 0;
    for (let i = 0; i < RIPPLE_MAX; i++) if (RIPPLE[i].s > 0) n += 1;
    return n;
}
function waterSplash(x, z, strength) {
    const surface = terrainBaseHeight(x, z) + waterDepthAt(x, z);
    const count = Math.round(SPLASH_DROPS * strength);
    waterThrown += 1;
    for (let i = 0; i < count; i++) {
        if (splashTop >= SPLASH_MAX) splashTop = 0;
        let slot = SPLASH[splashTop];
        if (slot === undefined) {
            slot = { x: 0, y: 0, z: 0, vx: 0, vy: 0, vz: 0, life: 0 };
            SPLASH[splashTop] = slot;
        }
        splashTop += 1;
        const a = hash(x * 7.1 + z * 3.7 + i * 1.9) * 6.283185307179586;
        const out = 0.5 + hash(x * 4.7 + z * 8.3 + i * 3.1) * 0.9;
        const up = 1.4 + hash(x * 2.3 + z * 5.9 + i * 2.7) * 1.6;
        slot.x = x + Math.cos(a) * 0.18;
        slot.y = surface + 0.02;
        slot.z = z + Math.sin(a) * 0.18;
        slot.vx = Math.cos(a) * out;
        slot.vz = Math.sin(a) * out;
        slot.vy = up;
        slot.life = SPLASH_LIFE;
    }
}
function waterSplashLive() {
    let n = 0;
    for (let i = 0; i < SPLASH_MAX; i++) {
        const d = SPLASH[i];
        if (d !== undefined && d.life > 0) n += 1;
    }
    return n;
}
function waterSplashStep(dt) {
    for (let i = 0; i < SPLASH_MAX; i++) {
        const d = SPLASH[i];
        if (d === undefined || d.life <= 0) continue;
        d.life -= dt;
        d.x += d.vx * dt;
        d.z += d.vz * dt;
        d.vy -= SPLASH_GRAVITY * dt;
        d.y += d.vy * dt;
    }
}
function waterActorStep(dt, actors) {
    for (let i = 0; i < RIPPLE_MAX; i++) {
        const r = RIPPLE[i];
        if (r.s <= 0) continue;
        r.r += RIPPLE_SPEED * dt;
        r.s -= dt / RIPPLE_LIFE;
        if (r.s < 0) r.s = 0;
    }
    waterSplashStep(dt);
    const count = actors.length / 3;
    while (MARKS.length > count) MARKS.pop();
    while (MARKS.length < count) MARKS.push({ wet: false, x: 0, z: 0 });
    for (let at = 0; at < count; at++) {
        const x = actors[at * 3], z = actors[at * 3 + 1], py = actors[at * 3 + 2];
        const m = MARKS[at];
        const depth = waterDepthAt(x, z);
        const wet = depth > RIPPLE_MIN_DEPTH && py < depth;
        if (wet) {
            const rings = at === 0;
            if (!m.wet) {
                waterRippleAdd(x, z, rings ? 1.0 : 0.9);
                waterSplash(x, z, rings ? 0.7 : 0.6);
                m.x = x;
                m.z = z;
            } else {
                const dx = x - m.x, dz = z - m.z;
                if (!(dx * dx + dz * dz < RIPPLE_STEP * RIPPLE_STEP)) {
                    if (rings) waterRippleAdd(x, z, 0.6);
                    waterSplash(x, z, 0.3);
                    m.x = x;
                    m.z = z;
                }
            }
        }
        m.wet = wet;
    }
}

// ---- the grass, `weather.js`'s `tuftField` plus `drawTufts`' cull ------------
// The pool is built and the cull applied inside the build, which is where the port merges
// the two: the *kept* tufts are one function's answer, and the scene's order (build, then
// skip) cannot differ from it because the skip reads nothing the build did not write.
function tuftField(out, eaten, groundY, cx0, cz0, cx1, cz1, gx, gz, cull2, detail2,
                   swayTime, windSway) {
    let n = 0;
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) {
            let h = (cx * 374761393 + cz * 668265263) | 0;
            h = Math.imul(h ^ (h >>> 13), 1274126177);
            h = (h ^ (h >>> 16)) >>> 0;
            const a = h / 4294967296;
            if (a < 0.45) continue;
            if (eaten.has((cx + 4096) * 8192 + (cz + 4096))) continue;
            let h2 = (cx * 1103515245 + cz * 12345) | 0;
            h2 = Math.imul(h2 ^ (h2 >>> 15), 2246822519);
            h2 = (h2 ^ (h2 >>> 13)) >>> 0;
            let h3 = (cx * 2654435761 + cz * 40503) | 0;
            h3 = Math.imul(h3 ^ (h3 >>> 16), 3266489917);
            h3 = (h3 ^ (h3 >>> 16)) >>> 0;
            const x = cx * 2 + (h2 / 4294967296 - 0.5) * 1.8;
            const z = cz * 2 + (a - 0.5) * 1.8;
            const tx = x - gx;
            const tz = z - gz;
            const d2 = tx * tx + tz * tz;
            if (d2 > cull2) continue;
            const off = Math.sin(swayTime * 3.0 + (h3 / 4294967296) * 6.28) * 0.11 * windSway;
            // `drawTufts`: a tuft standing under the water is skipped, tested at its own
            // *swayed* place, and `waterSubmergedAt` is what counts what it skipped.
            if (waterSubmergedAt(x + off, z + off * 0.4)) continue;
            const gy = groundY(x, z);
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

// ---- the checks --------------------------------------------------------------
const DT = 1 / 60;
const TAPE = __TAPE__;
const LOWEST = __LOWEST__;
for (let f = 0; f < TAPE.length; f++) {
    const frame = TAPE[f];
    setLevel(frame.level, LOWEST);
    const actors = frame.actors;
    if (waterOn) waterActorStep(DT, actors);
    let line = 'F ' + f + ' ' + waterThrown + ' ' + waterRipplesLive() + ' ' +
        waterSplashLive();
    for (let i = 0; i < RIPPLE_MAX; i++) {
        line += ' ' + RIPPLE[i].x + ' ' + RIPPLE[i].z + ' ' + RIPPLE[i].r + ' ' + RIPPLE[i].s;
    }
    console.log(line);
    // One line a drop rather than one a frame: the embedded engine's `console.log` is not
    // unlimbered, and a frame's whole pool is a few thousand characters.
    for (let i = 0; i < SPLASH_MAX; i++) {
        const d = SPLASH[i];
        console.log('P ' + f + ' ' + i + ' ' + (d === undefined ? 0 : d.x) + ' ' +
            (d === undefined ? 0 : d.y) + ' ' + (d === undefined ? 0 : d.z) + ' ' +
            (d === undefined ? 0 : d.vx) + ' ' + (d === undefined ? 0 : d.vy) + ' ' +
            (d === undefined ? 0 : d.vz) + ' ' + (d === undefined ? 0 : d.life));
    }
}
const PROBES = __PROBES__;
const LEVELS = __LEVELS__;
for (let l = 0; l < LEVELS.length; l++) {
    setLevel(LEVELS[l], LOWEST);
    let line = 'W ' + l;
    for (let p = 0; p < PROBES.length; p++) {
        line += ' ' + (waterInWater(PROBES[p][0], PROBES[p][1]) ? 1 : 0);
    }
    for (let p = 0; p < PROBES.length; p++) {
        line += ' ' + (waterSubmergedAt(PROBES[p][0], PROBES[p][1]) ? 1 : 0);
    }
    console.log(line + ' ' + waterCulled);
}
const GRASS = __GRASS__;
for (let c = 0; c < GRASS.length; c++) {
    const k = GRASS[c];
    setLevel(k.level, LOWEST);
    const eaten = new Set();
    for (const cell of k.eaten) eaten.add((cell[0] + 4096) * 8192 + (cell[1] + 4096));
    const r = Math.sqrt(576);
    const cx0 = Math.floor((k.gx - r) * 0.5), cx1 = Math.ceil((k.gx + r) * 0.5);
    const cz0 = Math.floor((k.gz - r) * 0.5), cz1 = Math.ceil((k.gz + r) * 0.5);
    const cells = (cx1 - cx0 + 1) * (cz1 - cz0 + 1);
    const pool = [];
    while (pool.length < cells) pool.push({ ax: 0, ay: 0, az: 0, bx: 0, by: 0, bz: 0, d: 0 });
    const n = tuftField(pool, eaten, terrainBaseHeight, cx0, cz0, cx1, cz1, k.gx, k.gz,
        576, 180, k.sway, k.wind);
    console.log('C ' + c + ' ' + n + ' ' + waterCulled);
    // One line a tuft, as `verify_grass.gd` prints them, for the same reason.
    for (let i = 0; i < n; i++) {
        const t = pool[i];
        console.log('T ' + c + ' ' + i + ' ' + t.ax + ' ' + t.ay + ' ' + t.az + ' ' +
            t.bx + ' ' + t.by + ' ' + t.bz + ' ' + t.d);
    }
}
"""

## The level the wake's own act is played at: the spawn bowl's ground is a few centimetres
## either side of zero, so half a metre floods the bowl and leaves the field's rim dry --
## and the bowl is where the tape's goat walks.
const LEVEL := 0.5

## Where the two water tests are asked from: a sweep out along `x` from the middle of the
## bowl to dry ground at *half a cell*, so the grid's own vertex test and the bilinear one
## are asked about genuinely different places -- which is where they disagree -- and then a
## few points that are off the built grid entirely.
func _probe_points() -> Array:
	var points: Array = []
	var x: float = -25.0
	while x <= 25.0:
		points.append(Vector2(x, 0.0))
		x += 0.5
	points.append(Vector2(0.0, -30.0))
	points.append(Vector2(40.0, 40.0))
	points.append(Vector2(60.0, 60.0))
	return points

## The levels the pair are compared at: dry, the `seep`-and-under line, the bowl's own
## waterline, the act's own level, and a flood.
const PROBE_LEVELS := [-3.0, -0.5, 0.02, 0.5, 1.6]

## The grass cases: where the field is drawn from, its sway, and the level the pool is
## hiding tufts under. The first is dry (nothing culled), the second is the tape's own
## level, and the third is deep enough to take the bowl's whole meadow.
const GRASS_CASES := [
	{"gx": 0.0, "gz": 0.0, "sway": 0.0, "wind": 0.0, "level": -3.0, "eaten": []},
	{"gx": 0.0, "gz": 0.0, "sway": 0.0, "wind": 0.0, "level": 0.5, "eaten": []},
	{"gx": 0.0, "gz": 0.0, "sway": 3.7, "wind": 1.2, "level": 1.6, "eaten": []},
]

## The frame step the tape is run at, matching `DT` in the oracle.
const DT := 1.0 / 60.0

## The wake's own two floors, and each is a *different* one, which is why the check has
## three tolerances rather than one.
##
## `RING_TOLERANCE`: a ring is pushed to the shader as a `Vector4`, and every Godot vector
## type is **float32** -- so a ring's centre comes back good to ~1e-6 m at the field's rim.
## That is the same rounding `verify_water.gd`'s `WIND_TOLERANCE` records, it is not a
## transcription error, and the shader would round it again anyway.
const RING_TOLERANCE := 1e-5
## `DROP_TOLERANCE`: a drop's *direction* is `value_hash` taken through a second `sin`. The
## hash is `frac(sin(n * 127.1) * 43758.5453)` with `n` out in the tens, so the two engines'
## `sin` differ by an ULP at an argument in the thousands and the 43758 turns that into about
## 1e-8 -- and the direction is `sin` of *that*, so a drop lands ~1e-6 from where the scene's
## does. Section 9's heightfield floor is the same disagreement seen through a height
## (5e-11 m); this is what it looks like seen through an angle. A wrong slot, a wrong count
## or a wrong cone is O(0.1), which is what the check is for.
const DROP_TOLERANCE := 1e-4
## The drop's own *life* is arithmetic and nothing else -- `SPLASH_LIFE` less whole frame
## steps -- so it is compared at the field's own tolerance, and the two counts with it.
const TOLERANCE := 1e-9

## How many actors the tape drives: the player's goat, then two bots. A flat `(x, z, py)`
## run a frame, which is exactly what `wake_step` takes.
const ACTORS := 3

## The tape: 120 frames of a goat walking out of the spawn bowl and back, with a bot pacing
## it and a second standing still in the deep water, and a dry stretch in the middle. It is
## built to cross every edge the wake has -- the entry, the strides of a walk, standing
## still, a hop that lifts the feet out of the pool, the level going out entirely, and the
## *second* entry when it comes back, which is the one the "no water is also no wake" rule
## exists for.
##
## `dry_level` is under the window's lowest ground, so the pool is not merely shallow there,
## it is gone.
func _tape(dry_level: float) -> Array:
	var frames: Array = []
	for i in 120:
		var level: float = LEVEL
		var gx: float = 0.0
		var gz: float = 0.0
		var py: float = 0.0
		if i < 40:
			# Out of the bowl, up the slope: the waterline is somewhere in here.
			gx = float(i) * 0.32
			gz = float(i) * 0.05
		elif i < 60:
			# Standing still, in the water.
			gx = 12.5
			gz = 1.9
		elif i < 66:
			# A hop, so `py` is over the surface and the feet are not in it.
			gx = 12.5 + float(i - 60) * 0.2
			gz = 1.9
			py = 0.4
		elif i < 84:
			# The pool is gone: `waterOn` false is no wake either.
			level = dry_level
			gx = 13.1
			gz = 1.9
		else:
			# ...and it comes back where the goat is standing, which is a *second* entry.
			gx = 13.1 - float(i - 84) * 0.3
			gz = 1.9
		# The herd: one bot pacing the goat a little behind it, one standing still in the
		# bowl. Neither lays a ring -- the herd throws drops only.
		var actors: Array = [
			gx, gz, py,
			gx - 0.8, gz + 0.5, 0.0,
			1.0, -1.0, 0.0,
		]
		frames.append({"level": level, "actors": actors})
	return frames

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	# The grid, from the real mesh, so both sides read the same ground -- the premise
	# `verify_water.gd` takes, and `verify_terrain_mesh.gd` is where it is checked.
	var grid := TerrainMesh.new()
	root.add_child(grid)
	grid.build(0.0, 0.0)
	var heights: PackedFloat64Array = grid.heights()
	var anchor: Vector2 = grid.anchor()
	if heights.size() != Water.N * Water.N:
		print("FAIL: the terrain grid is ", heights.size(), " vertices, expected ",
			Water.N * Water.N)
		quit(1)
		return
	var as_array: Array = []
	as_array.assign(heights)
	var lowest: float = _lowest(heights)
	# Under the lowest ground there is no pool at all: `waterOn` false, which is the state
	# the wake has to survive.
	var dry_level: float = lowest - 0.1
	print("grid: %d vertices at anchor (%.0f, %.0f), lowest ground %.6f, dry level %.6f"
		% [heights.size(), anchor.x, anchor.y, lowest, dry_level])

	var tape: Array = _tape(dry_level)
	var points: Array = _probe_points()
	var probes: Array = []
	for p: Vector2 in points:
		probes.append([p.x, p.y])

	var source: String = JS.replace("__HEIGHTS__", JSON.stringify(as_array)) \
		.replace("__N__", str(Water.N)) \
		.replace("__AX__", str(anchor.x)) \
		.replace("__AZ__", str(anchor.y)) \
		.replace("__LEVEL__", str(LEVEL)) \
		.replace("__LOWEST__", str(lowest)) \
		.replace("__TAPE__", JSON.stringify(tape)) \
		.replace("__PROBES__", JSON.stringify(probes)) \
		.replace("__LEVELS__", JSON.stringify(PROBE_LEVELS)) \
		.replace("__GRASS__", JSON.stringify(GRASS_CASES))
	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var oracle_frames: Array = []
	## The drop pool, one Array of seven floats a slot, keyed by the frame's own index.
	var oracle_drops := {}
	var oracle_tests: Array = []
	var oracle_counts := {}
	var oracle_tufts := {}
	for line in answers:
		var parts: PackedStringArray = line.split(" ")
		# The wake's own two tags keep the whole line rather than a trimmed payload: their
		# numbers start at `parts[3]` and every other tag here starts at `parts[2]`, so one
		# base for all of them is worth more than a shorter string.
		if line.begins_with("log F "):
			oracle_frames.append(line)
		elif line.begins_with("log P ") and parts.size() == 11:
			var at: int = int(parts[2])
			if not oracle_drops.has(at):
				oracle_drops[at] = []
			(oracle_drops[at] as Array).append([
				float(parts[4]), float(parts[5]), float(parts[6]), float(parts[7]),
				float(parts[8]), float(parts[9]), float(parts[10])])
		elif line.begins_with("log W "):
			oracle_tests.append(line)
		elif line.begins_with("log C ") and parts.size() == 5:
			oracle_counts[int(parts[2])] = [int(parts[3]), int(parts[4])]
		elif line.begins_with("log T ") and parts.size() == 11:
			var case: int = int(parts[2])
			if not oracle_tufts.has(case):
				oracle_tufts[case] = []
			(oracle_tufts[case] as Array).append([
				float(parts[4]), float(parts[5]), float(parts[6]), float(parts[7]),
				float(parts[8]), float(parts[9]), float(parts[10])])
	print("oracle answered ", oracle_frames.size(), " frame(s), ", oracle_drops.size(),
		" drop table(s), ", oracle_tests.size(), " level(s), ", oracle_counts.size(),
		" grass case(s)")

	var water := Water.new()
	water.rebuild(heights, anchor)

	# 1. The tape: the rings, the drops and the counts, frame for frame.
	var compared := 0
	var worst := 0.0
	var worst_at := ""
	var mismatches := 0
	var first_mismatch := ""
	var thrown := 0
	var rings_laid := 0
	var dry_frames := 0
	for index in tape.size():
		var frame: Dictionary = tape[index]
		var level: float = float(frame["level"])
		var actors: Array = frame["actors"]
		var actor_values := PackedFloat64Array()
		for value: float in actors:
			actor_values.append(value)
		water.set_force(level)
		if level < lowest:
			dry_frames += 1
		water.wake_step(DT, actor_values)
		thrown = water.thrown
		rings_laid = maxi(rings_laid, water.ripples_live())
		if index >= oracle_frames.size():
			mismatches += 1
			if first_mismatch == "":
				first_mismatch = "no oracle line for frame %d" % index
			continue
		var parts: PackedStringArray = oracle_frames[index].split(" ")
		# `log F <frame> <thrown> <ripples> <splashes>` then three rings of four: the
		# numbers start at `parts[3]` and there are fifteen of them.
		var wanted: Array[float] = []
		for k in range(3, parts.size()):
			wanted.append(float(parts[k]))
		var mine: Array[float] = [
			float(water.thrown), float(water.ripples_live()), float(water.splashes_live()),
		]
		for slot in Water.RIPPLE_MAX:
			var ring: Vector4 = water.ripple_uniform(slot)
			# `ripple_uniform` is `(x, z, radius, strength)`, so the components read
			# `x, y, z, w` in that order -- which is what makes `ring.y` the world `z`.
			mine.append_array([ring.x, ring.y, ring.z, ring.w])
		for k in mine.size():
			var gap: float = absf(mine[k] - wanted[k])
			compared += 1
			if gap > worst:
				worst = gap
				worst_at = "frame %d field %d: scene %.17f, port %.17f" % [
					index, k, wanted[k], mine[k]]
			# The rings are the last twelve fields, so `k >= 3` is one.
			if gap > (RING_TOLERANCE if k >= 3 else TOLERANCE):
				mismatches += 1
				if first_mismatch == "":
					first_mismatch = "frame %d field %d: scene %.17f, port %.17f" % [
						index, k, wanted[k], mine[k]]
		# ...and the whole drop pool, one oracle line a slot.
		var drops: Variant = oracle_drops.get(index, null)
		if not (drops is Array) or (drops as Array).size() < Water.SPLASH_MAX:
			mismatches += 1
			if first_mismatch == "":
				first_mismatch = "frame %d: the oracle answered no drop table" % index
			continue
		for slot in Water.SPLASH_MAX:
			var got: PackedFloat64Array = water.drop_state(slot)
			var want: Array = (drops as Array)[slot]
			for k in 7:
				var gap: float = absf(got[k] - float(want[k]))
				compared += 1
				if gap > worst:
					worst = gap
					worst_at = "frame %d drop %d field %d: scene %.17f, port %.17f" % [
						index, slot, k, float(want[k]), got[k]]
				# The last field is the drop's life, which is arithmetic; the six before it
				# are the hash's own direction and carry its floor.
				if gap > (TOLERANCE if k == 6 else DROP_TOLERANCE):
					mismatches += 1
					if first_mismatch == "":
						first_mismatch = \
							"frame %d drop %d field %d: scene %.17f, port %.17f" % [
								index, slot, k, float(want[k]), got[k]]
	print("wake: %d frame(s), %d value(s), %d splash(es) thrown, up to %d ring(s) at once, %d dry"
		% [tape.size(), compared, thrown, rings_laid, dry_frames])
	# `%.17f` and not `%.0e`: Godot's `%` has no scientific specifier at all, and an
	# unsupported one does not raise -- it leaves the format string in the stream and
	# mangles the line after it. These tolerances are small enough to read in full.
	print("largest wake disagreement: %.17f (ring %.17f, drop %.17f, life %.17f)"
		% [worst, RING_TOLERANCE, DROP_TOLERANCE, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)
	if first_mismatch != "":
		print("  first: ", first_mismatch)

	# 2. The two tests, at five levels over ten points: the two answers, and whether they
	#    ever *differ* -- which is the whole reason both exist.
	var test_mismatches := 0
	var first_test := ""
	var disagreements := 0
	for index in PROBE_LEVELS.size():
		water.set_force(float(PROBE_LEVELS[index]))
		var mine: Array[float] = []
		for p: Vector2 in points:
			mine.append(1.0 if water.in_water(p.x, p.y) else 0.0)
		for p: Vector2 in points:
			mine.append(1.0 if water.submerged_at(p.x, p.y) else 0.0)
		mine.append(float(water.culled))
		for k in points.size():
			if mine[k] != mine[points.size() + k]:
				disagreements += 1
		if index >= oracle_tests.size():
			test_mismatches += 1
			continue
		var parts: PackedStringArray = oracle_tests[index].split(" ")
		var wanted: Array[float] = []
		for k in range(3, parts.size()):
			wanted.append(float(parts[k]))
		for k in mine.size():
			if absf(mine[k] - wanted[k]) > TOLERANCE:
				test_mismatches += 1
				if first_test == "":
					first_test = "level %d field %d: scene %.17f, port %.17f" % [
						index, k, wanted[k], mine[k]]
	print("water tests: %d level(s) x %d point(s), %d mismatch(es), %d disagreement(s) between the two"
		% [PROBE_LEVELS.size(), points.size(), test_mismatches, disagreements])
	if first_test != "":
		print("  first: ", first_test)

	# 3. The grass a pool hides: the tufts a frame *keeps*, against `tuftField` with
	#    `drawTufts`' own skip, and the count of what it skipped.
	var grass_mismatches := 0
	var first_grass := ""
	var culled_total := 0
	var kept_total := 0
	for index in GRASS_CASES.size():
		var case: Dictionary = GRASS_CASES[index]
		water.set_force(float(case["level"]))
		var eaten := {}
		for cell: Array in case["eaten"]:
			eaten[Meadow.key(int(cell[0]), int(cell[1]))] = true
		var cull: Callable = Callable(water, "submerged_at")
		var mine: PackedFloat64Array = Grass.field(
			float(case["gx"]), float(case["gz"]), 576.0, 180.0,
			float(case["sway"]), float(case["wind"]), eaten, cull)
		var culled: int = water.culled
		culled_total += culled
		@warning_ignore("integer_division")
		var kept: int = mine.size() / Grass.STRIDE
		kept_total += kept
		var parsed: int = 0
		if oracle_tufts.has(index):
			parsed = (oracle_tufts[index] as Array).size()
		print("  case %d: scene %s, port %d tuft(s) / %d culled, %d oracle line(s)"
			% [index, str(oracle_counts.get(index, "none")), kept,
				culled, parsed])
		var counts: Variant = oracle_counts.get(index, null)
		if not (counts is Array):
			grass_mismatches += 1
			if first_grass == "":
				first_grass = "case %d: the oracle answered no tuft count" % index
			continue
		var wanted_count: int = int((counts as Array)[0])
		var wanted_culled: int = int((counts as Array)[1])
		if wanted_count != kept or wanted_culled != culled:
			grass_mismatches += 1
			if first_grass == "":
				first_grass = "case %d: scene %d tuft(s) / %d culled, port %d / %d" % [
					index, wanted_count, wanted_culled, kept, culled]
		# A case that keeps *nothing* prints no `T` line at all, so its key is simply absent
		# -- a legitimate zero, not a short answer. The `C` line above it is the count, and a
		# case whose count is zero has no rows to compare either way.
		var tufts: Variant = oracle_tufts.get(index, [])
		if not (tufts is Array) or (tufts as Array).size() < wanted_count:
			grass_mismatches += 1
			if first_grass == "":
				first_grass = "case %d: the oracle answered fewer tuft(s) than it counted" % index
			continue
		for k in wanted_count * Grass.STRIDE:
			@warning_ignore("integer_division")
			var wanted: float = float((tufts as Array)[k / Grass.STRIDE][k % Grass.STRIDE])
			if absf(mine[k] - wanted) > TOLERANCE:
				grass_mismatches += 1
				if first_grass == "":
					first_grass = "case %d field %d: scene %.17f, port %.17f" % [
						index, k, wanted, mine[k]]
	print("submerged grass: %d case(s), %d tuft(s) kept, %d culled, %d mismatch(es)"
		% [GRASS_CASES.size(), kept_total, culled_total, grass_mismatches])
	if first_grass != "":
		print("  first: ", first_grass)

	# 4. The plumbing: the wake is three uniforms and a node, and a shader that did not
	#    declare `water_ripple0` would take the value and drop it without a word.
	var surface := WaterMesh.new()
	root.add_child(surface)
	surface.build(heights, anchor)
	surface.set_ripples(Vector4(1.0, 2.0, 3.0, 0.9), Vector4(4.0, 5.0, 6.0, 0.5),
		Vector4(7.0, 8.0, 9.0, 0.0))
	var pushed_ok := true
	if surface.material_override is ShaderMaterial:
		var material: ShaderMaterial = surface.material_override
		var first: Variant = material.get_shader_parameter("water_ripple0")
		var third: Variant = material.get_shader_parameter("water_ripple2")
		pushed_ok = first is Vector4 and third is Vector4 \
			and (first as Vector4).is_equal_approx(Vector4(1.0, 2.0, 3.0, 0.9)) \
			and (third as Vector4).is_equal_approx(Vector4(7.0, 8.0, 9.0, 0.0))
	print("ripples pushed: ", "ok" if pushed_ok else "WRONG")

	var splash_node := WaterSplash.new()
	root.add_child(splash_node)
	splash_node.water = water
	splash_node.update()
	var drawn: int = splash_node.count()
	var live: int = water.splashes_live()
	print("splash node drew %d of %d live drop(s)" % [drawn, live])
	surface.free()
	splash_node.free()

	# 5. The seams at the edges: no water at all, and a built field whose pool *goes away*.
	var bare := Water.new()
	var bare_ok := not bare.in_water(0.0, 0.0) and not bare.submerged_at(0.0, 0.0) \
		and absf(bare.depth_at(0.0, 0.0)) < TOLERANCE
	# A pool that drains and comes back: the mark is cleared while the water is gone, so the
	# goat standing exactly where it stood lays a *second* entering ring. A mark that had
	# survived would lay nothing, since it has not moved.
	bare.rebuild(heights, anchor)
	bare.set_force(LEVEL)
	var flat := PackedFloat64Array([0.0, 0.0, 0.0])
	bare.wake_step(DT, flat)
	var entered: int = bare.ripples_live()
	bare.set_force(dry_level)
	bare.wake_step(DT, flat)
	bare.set_force(LEVEL)
	bare.wake_step(DT, flat)
	var re_entered: int = bare.ripples_live()
	var edges_ok := bare_ok and entered == 1 and re_entered == 2
	print("edges: unbuilt quiet %s, entry %d ring(s), re-entry %d (want 1 then 2)"
		% ["ok" if bare_ok else "WRONG", entered, re_entered])
	grid.free()

	host.free()

	if oracle_frames.size() != tape.size():
		failures.append("the oracle answered %d wake frame(s), expected %d"
			% [oracle_frames.size(), tape.size()])
	if mismatches != 0:
		failures.append("the wake disagrees in %d of %d value(s)" % [mismatches, compared])
	if worst > DROP_TOLERANCE:
		failures.append("the largest wake disagreement is %f (limit %f)"
			% [worst, DROP_TOLERANCE])
	if thrown == 0:
		failures.append("the tape never threw a splash, so nothing here was checked")
	if rings_laid == 0:
		failures.append("the tape never laid a ring, so the wake was never checked")
	if dry_frames == 0:
		failures.append("the tape never drained the pool, so the no-water rule was never checked")
	if oracle_tests.size() != PROBE_LEVELS.size():
		failures.append("the oracle answered %d level(s), expected %d"
			% [oracle_tests.size(), PROBE_LEVELS.size()])
	if test_mismatches != 0:
		failures.append("the two water tests disagree with the scene in %d place(s)"
			% test_mismatches)
	if disagreements == 0:
		failures.append("the two water tests never disagreed, so one of them is not being asked")
	if grass_mismatches != 0:
		failures.append("the submerged grass disagrees in %d place(s)" % grass_mismatches)
	if culled_total == 0:
		failures.append("no tuft was ever culled, so the water hid nothing")
	if not pushed_ok:
		failures.append("the ripple uniforms do not reach the shader")
	if drawn != live:
		failures.append("the splash node drew %d drop(s) and the water had %d" % [drawn, live])
	if not bare_ok:
		failures.append("a water with no grid answered as if it had one")
	if not edges_ok:
		failures.append("the pool that came back did not lay a *second* entering ring")

	if failures.is_empty():
		print("OK: the GDScript wake is the scene's wake, and it throws what the scene throws")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

## The window's lowest ground, which is what a dry level has to clear.
func _lowest(heights: PackedFloat64Array) -> float:
	var lowest: float = INF
	for h in heights:
		if h < lowest:
			lowest = h
	return lowest

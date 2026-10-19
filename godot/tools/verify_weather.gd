# The weather gate: `weather.gd` against `weather.js`, and the two bodies against
# `world.js`.
#
#   Godot --headless --path godot --script res://tools/verify_weather.gd
#
# Three things are checked, and each is a different way the weather can be wrong:
#
#   1. **The state machine.** A seeded, stochastic process is exactly the kind of
#      thing a port gets *almost* right: one draw of the xorshift taken in the wrong
#      order, or the hold read before the state changes, and two peers running the
#      same seed disagree about when it starts to rain. So the machine is stepped
#      frame for frame against the JavaScript's own `updateWeather`, with `forceWeather`
#      spliced in at four points to exercise the `C` key's path too.
#
#   2. **The two bodies.** `celestialPlacement` / `celestialCover` / the tint are pure
#      functions of the hour and the cloudiness, which is what makes them checkable
#      without a GPU -- and they are the last piece of the sky, so a transcription that
#      is a little wrong is a sun in the wrong place. The oracle's `sunDir` is
#      `lighting.js`'s, transcribed again rather than borrowed from `sky.gd`, because a
#      gate that shares the thing it checks is no gate.
#
#   3. **The rain.** `rainFall` walks a pool of drops and *wraps* them, drawing a fresh
#      column each time from `rainSeed` -- so the pool is checked after enough frames
#      that every live drop has wrapped at least once, and the drawn column is checked
#      against the scene's `hash` rather than against the port's own `value_hash`.
#
# The oracles are transcribed from `crates/goats/src/game/` and never from the port:
# that is the mistake this project has already made once (see `verify_goat.gd`'s note
# and `PORT.md` section 9), and a gate whose oracle came from the code under test
# agrees with it perfectly and proves nothing.
extends SceneTree

## `weather.js` (the states, the transitions, `rnd`, `updateWeather`, `forceWeather`,
## `rainFall`, `buildRain`), `world.js` (the celestial constants and the placement) and
## `lighting.js` (`updateLight`'s `SUN_DIR`), transcribed *from their sources*. The
## tuning (`HOLD`, `RAIN_MAX`) is `core.js` `TUNING.weather`; `hash` is `core.js`'s.
const JS := """
const HOLD = { clear: [22, 45], cloudy: [16, 34], rain: [20, 40], clearing: [8, 16] };
const RAIN_MAX = 160;
const RAIN_CAPACITY = 1024;
function hash(n) { const s = Math.sin(n * 127.1) * 43758.5453; return s - Math.floor(s); }

const WEATHER_STATES = {
    clear: { cloud: 0.05, rain: 0.0 },
    cloudy: { cloud: 0.70, rain: 0.0 },
    rain: { cloud: 1.00, rain: 1.0 },
    clearing: { cloud: 0.40, rain: 0.12 },
};
const WEATHER_NEXT = {
    clear: ["cloudy"],
    cloudy: ["rain", "clear"],
    rain: ["clearing"],
    clearing: ["clear", "cloudy"],
};

let weatherKind = "clear";
let weatherTimer = 24;
let cloudiness = 0.05;
let rainAmount = 0.0;
let rngState = 0x9e3779b9;

function rnd() {
    rngState ^= rngState << 13;
    rngState >>>= 0;
    rngState ^= rngState >>> 17;
    rngState ^= rngState << 5;
    rngState >>>= 0;
    return rngState / 4294967296;
}
function updateWeather(dt) {
    weatherTimer -= dt;
    if (weatherTimer <= 0) {
        const opts = WEATHER_NEXT[weatherKind];
        weatherKind = opts[Math.floor(rnd() * opts.length) % opts.length];
        const hold = HOLD[weatherKind];
        weatherTimer = hold[0] + rnd() * (hold[1] - hold[0]);
    }
    const target = WEATHER_STATES[weatherKind];
    const k = Math.min(1, dt * 0.6);
    cloudiness += (target.cloud - cloudiness) * k;
    rainAmount += (target.rain - rainAmount) * k;
}
function forceWeather() {
    weatherKind = WEATHER_NEXT[weatherKind][0];
    weatherTimer = HOLD[weatherKind][0];
}

const DT = 1 / 60;
const FRAMES = __FRAMES__;
const FORCE_AT = __FORCE_AT__;
for (let f = 0; f < FRAMES; f++) {
    updateWeather(DT);
    if (FORCE_AT.indexOf(f) >= 0) forceWeather();
    console.log('W ' + f + ' ' + weatherKind + ' ' + weatherTimer + ' ' + cloudiness + ' ' + rainAmount);
}

// ---- the two bodies (world.js, lighting.js) ----
function sunDir(hours) {
    const a = ((hours - 6) / 12) * Math.PI;
    const sunX = Math.cos(a), sunY = Math.sin(a), tilt = 0.18;
    const len = Math.sqrt(sunX * sunX + sunY * sunY + tilt * tilt) || 1;
    return [sunX / len, sunY / len, tilt / len];
}
const CELESTIAL_R = 600, CELESTIAL_CLOUD_FADE = 0.55, CELESTIAL_HORIZON = 0.05;
const SUN_TINT = [255, 246, 214], MOON_TINT = [238, 234, 222];
function cover(c) { return 1 - CELESTIAL_CLOUD_FADE * c; }
function placement(side, cov, SUN, px, pz) {
    const up = SUN[1] * side;
    const fade = up <= 0 ? 0 : Math.min(1, up / CELESTIAL_HORIZON);
    return {
        x: px + SUN[0] * side * CELESTIAL_R,
        y: up * CELESTIAL_R,
        z: pz + SUN[2] * side * CELESTIAL_R,
        elevation: up,
        alpha: Math.round(255 * cov * fade),
    };
}
function tintOf(tint, elevation, shaded) {
    const warm = shaded === 0 ? Math.min(1, Math.max(0, elevation / 0.30)) : 1;
    return [tint[0], Math.round(tint[1] * (0.78 + 0.22 * warm)),
            Math.round(tint[2] * (0.42 + 0.58 * warm))];
}
const HOURS = __HOURS__;
const CLOUDS = __CLOUDS__;
const PX = __PX__, PZ = __PZ__;
for (const h of HOURS) {
    const SUN = sunDir(h);
    for (const c of CLOUDS) {
        const cov = cover(c);
        for (const body of [[1, SUN_TINT, 0], [-1, MOON_TINT, 1]]) {
            const p = placement(body[0], cov, SUN, PX, PZ);
            const t = tintOf(body[1], p.elevation, body[2]);
            console.log('C ' + body[0] + ' ' + h + ' ' + c + ' ' + p.x + ' ' + p.y + ' ' + p.z +
                ' ' + p.elevation + ' ' + p.alpha + ' ' + t[0] + ' ' + t[1] + ' ' + t[2]);
        }
    }
}

// ---- the rain (weather.js buildRain / updateRain / rainFall), at full rain ----
const RAIN = [];
for (let i = 0; i < RAIN_CAPACITY; i++) {
    RAIN.push({ x: hash(i * 1.7), y: hash(i * 2.9), speed: 0.6 + hash(i * 4.3) });
}
function rainFall(list, count, dt, wind, seed, hashFn) {
    const wx = wind * 0.02 * dt;
    for (let i = 0; i < count; i++) {
        const d = list[i];
        d.y += (0.7 + d.speed) * dt;
        d.x += wx;
        if (d.y > 1.05) {
            d.y = d.y - 1.1;
            seed ^= seed << 13;
            seed >>>= 0;
            seed ^= seed >>> 17;
            seed ^= seed << 5;
            seed >>>= 0;
            d.x = hashFn(i * 13.1 + seed * 0.0001);
        }
        if (d.x > 1.1) d.x = d.x - 1.2;
        else if (d.x < -0.1) d.x = d.x + 1.2;
    }
    return seed;
}
const WIND = __WIND__;
const RAIN_FRAMES = __RAIN_FRAMES__;
const RAIN_INDICES = __RAIN_INDICES__;
let rainSeed = 0x13579bdf;
let windX = WIND;
for (let f = 0; f < RAIN_FRAMES; f++) {
    const active = Math.min(RAIN.length, Math.round(RAIN_MAX * 1.0));
    rainSeed = rainFall(RAIN, active, DT, windX, rainSeed, hash);
    let line = 'P ' + f + ' ' + active;
    for (const i of RAIN_INDICES) line += ' ' + RAIN[i].x + ' ' + RAIN[i].y;
    console.log(line);
}
"""

## The frame step, matching the scene's own `dt` (`goat.js` `getFrameTime`).
const DT := 1.0 / 60.0
## How long the machine is run. Long enough for several natural transitions at the
## tuning's own holds (a `clear` is 22-45 s), and `FORCE_AT` splices the `C` key in.
const FRAMES := 5400
const FORCE_AT := [400, 1500, 3000, 4500]

## The celestial grid: the keyframes' ends, the horizon from both sides (where `fade`
## goes to zero and `sin(PI)`'s sign decides whether a body is up at all), and one hour
## in each open segment.
const HOURS := [0.0, 3.0, 5.5, 5.95, 6.0, 6.75, 9.0, 12.0, 15.0, 17.5, 18.0, 18.05, 19.5,
	21.0, 24.0]
const CLOUDS := [0.0, 0.05, 0.5, 1.0]
## Where the goat is when a body is placed: `celestialPlacement` is relative to it.
const PX := 12.5
const PZ := -3.25

## The rain run: a fixed crosswind, and enough frames that every live drop wraps.
const WIND := 3.0
const RAIN_FRAMES := 200
## The drops compared: four inside the pool's active head, and one past it -- which has
## never been stepped, so it checks `buildRain`'s derived columns on its own.
const RAIN_INDICES := [0, 37, 100, 159, 1023]

## The machine is pure arithmetic and one xorshift, so it has no `sin` in it and the two
## sides should agree to the last bit -- the tolerance is only here to keep a formatted
## print from being a failure.
const WEATHER_TOLERANCE := 1e-12
## The bodies' coordinates are about `Celestial.R` (600) large and float32 in both the
## direction `sun_dir` hands in and the node position that receives it, so they are
## compared *relative to that scale*: 1e-6 of it is 0.6 mm at 600 units, which is 1e-6 of
## a radian -- orders below anything visible, and still orders tighter than a wrong rule.
## The elevation, the alpha and the tint are small and are compared as they are.
const BODY_TOLERANCE := 1e-6
## The rain's columns are re-derived from `hash(i * 13.1 + rainSeed * 0.0001)`, whose
## argument runs to about 4.3e5 -- so `sin` is taken near 5.5e7, four orders past the
## heightfield's, where `value_hash`'s argument-reduction floor is a few parts in a
## million rather than 5e-11. A drop's `y` accumulates exactly; only the column a wrap
## draws carries this, and a few parts in a million of a viewport is a hundredth of a
## pixel, so this is a *documented* floor rather than a defect.
const RAIN_TOLERANCE := 1e-4

## What the mirror and the pin found, if anything; filled by `_check_weather_api` and
## read by `_initialize`.
var _api_failures: Array[String] = []

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var source: String = JS \
		.replace("__FRAMES__", str(FRAMES)) \
		.replace("__FORCE_AT__", JSON.stringify(FORCE_AT)) \
		.replace("__HOURS__", JSON.stringify(HOURS)) \
		.replace("__CLOUDS__", JSON.stringify(CLOUDS)) \
		.replace("__PX__", str(PX)) \
		.replace("__PZ__", str(PZ)) \
		.replace("__WIND__", str(WIND)) \
		.replace("__RAIN_FRAMES__", str(RAIN_FRAMES)) \
		.replace("__RAIN_INDICES__", JSON.stringify(RAIN_INDICES))
	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var w_lines: Array[String] = []
	var c_lines: Array[String] = []
	var p_lines: Array[String] = []
	for line in answers:
		if line.begins_with("log W "):
			w_lines.append(line.substr(6))
		elif line.begins_with("log C "):
			c_lines.append(line.substr(6))
		elif line.begins_with("log P "):
			p_lines.append(line.substr(6))
	print("oracle answered ", w_lines.size(), " weather frame(s), ", c_lines.size(),
		" celestial line(s), ", p_lines.size(), " rain frame(s)")

	var worst_weather := _check_machine(w_lines)
	var worst_body := _check_bodies(c_lines)
	var worst_rain := _check_rain(p_lines)
	_check_weather_api()

	host.free()

	print("largest weather disagreement: %.15f (tolerance %.15f)"
		% [worst_weather, WEATHER_TOLERANCE])
	print("largest body disagreement:    %.15f (tolerance %.15f, relative to scale)"
		% [worst_body, BODY_TOLERANCE])
	print("largest rain disagreement:    %.15f (tolerance %.15f)"
		% [worst_rain, RAIN_TOLERANCE])

	if w_lines.size() != FRAMES:
		failures.append("the oracle answered %d weather frame(s), expected %d"
			% [w_lines.size(), FRAMES])
	if worst_weather > WEATHER_TOLERANCE:
		failures.append("the weather machine disagrees with the scene by %f" % worst_weather)
	if worst_body > BODY_TOLERANCE:
		failures.append("the celestial bodies disagree with the scene by %f" % worst_body)
	if worst_rain > RAIN_TOLERANCE:
		failures.append("the rain disagrees with the scene by %f" % worst_rain)
	failures.append_array(_api_failures)

	if failures.is_empty():
		print("OK: the GDScript weather is the scene's weather, and so are the two bodies")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

## Step `weather.gd` through the same frames the oracle ran, and compare the state, the
## hold and the two eased amounts every frame. `kind` is compared exactly -- it is what
## a peer's rain schedule hangs on -- and it is reported separately from the numbers,
## because a machine that transitions a frame late shows up here first.
func _check_machine(lines: Array[String]) -> float:
	var machine: Weather = Weather.new()
	var worst := 0.0
	var worst_at := ""
	var kind_mismatches := 0
	var first_kind := ""
	for f in FRAMES:
		machine.update(DT)
		if f in FORCE_AT:
			machine.force()
		if f >= lines.size():
			continue
		var parts: PackedStringArray = lines[f].split(" ")
		if parts.size() != 5:
			continue
		var wanted_kind: String = parts[1]
		var wanted: Array[float] = [
			float(parts[2]), float(parts[3]), float(parts[4]),
		]
		var got: Array[float] = [machine.timer, machine.cloudiness, machine.rain_amount]
		if machine.kind != wanted_kind:
			kind_mismatches += 1
			if first_kind == "":
				first_kind = "frame %d: scene %s, port %s" % [f, wanted_kind, machine.kind]
		for k in got.size():
			var gap: float = absf(got[k] - wanted[k])
			if gap > worst:
				worst = gap
				worst_at = "frame %d field %d (%s): scene %.17f, port %.17f" % [
					f, k, wanted_kind, wanted[k], got[k]]
	print("weather machine: %d frame(s), %d kind mismatch(es)" % [FRAMES, kind_mismatches])
	if worst_at != "":
		print("  worst at ", worst_at)
	if first_kind != "":
		print("  first kind mismatch: ", first_kind)
	if kind_mismatches != 0:
		print("FAIL: the state machine diverged ", kind_mismatches, " time(s)")
	return worst

## Compare the two bodies over the oracle's own grid -- the hour and the cloudiness are
## read back off each line rather than assumed, so the two sides cannot silently be
## answering different questions.
func _check_bodies(lines: Array[String]) -> float:
	var worst := 0.0
	var worst_at := ""
	var compared := 0
	var alpha_mismatches := 0
	var first_alpha := ""
	for line in lines:
		var parts: PackedStringArray = line.split(" ")
		if parts.size() != 11:
			continue
		var side: float = float(parts[0])
		var hours: float = float(parts[1])
		var cloud: float = float(parts[2])
		var shaded: bool = side < 0.0
		var tint: Vector3 = Celestial.MOON_TINT if shaded else Celestial.SUN_TINT
		var sun: Vector3 = SkyModel.sun_dir(hours)
		var spot: Dictionary = Celestial.placement(side, Celestial.cover(cloud), sun, PX, PZ)
		var colour: Vector3 = Celestial.tint_of(tint, float(spot["elevation"]), shaded)
		var wanted: Array[float] = [
			float(parts[3]), float(parts[4]), float(parts[5]), float(parts[6]),
			float(parts[7]), float(parts[8]), float(parts[9]), float(parts[10]),
		]
		var got: Array[float] = [
			float(spot["x"]), float(spot["y"]), float(spot["z"]), float(spot["elevation"]),
			float(spot["alpha"]), colour.x, colour.y, colour.z,
		]
		# `alpha` is a whole byte in both, so it is compared exactly and counted; the
		# rest is float arithmetic and gets the tolerance.
		if int(got[4]) != int(wanted[4]):
			alpha_mismatches += 1
			if first_alpha == "":
				first_alpha = "h=%.3f cloud=%.2f side=%.0f: scene %d, port %d" % [
					hours, cloud, side, int(wanted[4]), int(got[4])]
		for k in got.size():
			# The three coordinates are ~`Celestial.R` (600) large, and every `Vector3`
			# in Godot is float32 -- both the direction `sun_dir` hands in and the node
			# position that receives it -- so 600 * 2^-24 is as close as the two engines
			# can get however right the rule is: about 3e-8 of a unit, which is 3e-8 of a
			# radian at 600. The other fields are small and are compared as they are, so
			# `worst` is the disagreement *relative to each field's own scale*.
			var scale: float = Celestial.R if k < 3 else 1.0
			var relative: float = absf(got[k] - wanted[k]) / scale
			compared += 1
			if relative > worst:
				worst = relative
				worst_at = "h=%.3f cloud=%.2f side=%.0f field %d: scene %.17f, port %.17f" % [
					hours, cloud, side, k, wanted[k], got[k]]
	print("bodies: compared %d field(s), %d alpha mismatch(es)" % [compared, alpha_mismatches])
	if worst_at != "":
		print("  worst at ", worst_at)
	if alpha_mismatches != 0:
		print("FAIL: the bodies' alpha is not the scene's")
	return worst

## Step the rain against the oracle's own pool movement. The drops are compared by
## index, including an index past the active head, so both the wrap and `buildRain`'s
## derived columns are read.
func _check_rain(lines: Array[String]) -> float:
	var machine: Weather = Weather.new()
	machine.rain_amount = 1.0
	machine.rain_seed = Weather.RAIN_SEED
	var worst := 0.0
	var worst_at := ""
	var active_mismatches := 0
	var first_active := ""
	for f in RAIN_FRAMES:
		var active: int = machine.update_rain(DT, WIND)
		if f >= lines.size():
			continue
		var parts: PackedStringArray = lines[f].split(" ")
		if parts.size() != 2 + RAIN_INDICES.size() * 2:
			continue
		var wanted_active: int = int(float(parts[1]))
		if active != wanted_active:
			active_mismatches += 1
			if first_active == "":
				first_active = "frame %d: scene %d, port %d" % [f, wanted_active, active]
		for j in RAIN_INDICES.size():
			var index: int = RAIN_INDICES[j]
			var drop: Dictionary = machine.drops[index]
			var mine: Array[float] = [float(drop["x"]), float(drop["y"])]
			for a in 2:
				var gap: float = absf(mine[a] - float(parts[2 + j * 2 + a]))
				if gap > worst:
					worst = gap
					worst_at = "frame %d drop %d %s: scene %.17f, port %.17f" % [
						f, index, "xy"[a], float(parts[2 + j * 2 + a]), mine[a]]
	print("rain: %d frame(s), %d active mismatch(es)" % [RAIN_FRAMES, active_mismatches])
	if worst_at != "":
		print("  worst at ", worst_at)
	if first_active != "":
		print("  first active mismatch: ", first_active)
	if active_mismatches != 0:
		print("FAIL: the drop count is not the scene's")
	return worst

## The two paths a *player* never reaches, and therefore the two the frame-by-frame
## checks above never touch. A client does not run the machine, it mirrors the host's
## values, so `apply_wire` is half the weather's contract; and `GOATS_WEATHER` pins a
## state through `hold` for the screenshots. Both are checked directly rather than
## through a session: the three fields the wire carries must land, an empty event (which
## is what a snapshot without weather looks like) must change nothing, and a pin must
## leave the machine *in* the state it names rather than on the way to it.
func _check_weather_api() -> void:
	var machine: Weather = Weather.new()
	machine.apply_wire({"kind": "rain", "cloudiness": 0.875, "rain_amount": 0.75})
	if machine.kind != "rain" or absf(machine.cloudiness - 0.875) > 1e-12 \
			or absf(machine.rain_amount - 0.75) > 1e-12:
		_api_failures.append("apply_wire did not adopt the host's weather: %s"
			% [machine.values(0.0, 0.0, 0.0, 0.0)])
	machine.apply_wire({})
	if machine.kind != "rain" or absf(machine.rain_amount - 0.75) > 1e-12:
		_api_failures.append("an empty weather event changed the mirror")

	var pinned: Weather = Weather.new()
	pinned.hold("rain")
	if pinned.kind != "rain" or absf(pinned.cloudiness - 1.0) > 1e-12 \
			or absf(pinned.rain_amount - 1.0) > 1e-12:
		_api_failures.append("hold(\"rain\") did not pin the state and its values: %s"
			% [pinned.values(0.0, 0.0, 0.0, 0.0)])
	# ...and it has to *stay* pinned: the machine must not ease out of it or run the
	# hold down, which is what makes it usable for a 30-frame screenshot.
	for i in 600:
		pinned.update(DT)
	if pinned.kind != "rain" or absf(pinned.rain_amount - 1.0) > 1e-9:
		_api_failures.append("hold(\"rain\") drifted over 10 s: %s"
			% [pinned.values(0.0, 0.0, 0.0, 0.0)])
	pinned.hold("sunshine")
	if pinned.kind != "rain":
		_api_failures.append("hold() accepted a state that does not exist")
	print("api: mirror and pin ", "ok" if _api_failures.is_empty() else "mismatched")

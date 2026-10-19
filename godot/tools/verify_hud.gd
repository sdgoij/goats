# The HUD gate (M23): `drawHud`'s words and its two drawn numbers, against `goat.js`'s own.
#
#   Godot --headless --path godot --script res://tools/verify_hud.gd
#
# The port drew its HUD as one `Label` whose words were the scene's and whose layout was not, and
# three of the words themselves had drifted: there was no `paused` case, "walking" stood where the
# scene says "walking forward" or "walking backward", and an `exhausted` case existed that the
# scene has never had (an exhausted goat is capped at a walk by a rule, so it reads as walking).
# What this holds is everything in the HUD that is a *rule* rather than a placement:
#
#   * the **state word**, over every combination of the frame's move axis, the goat's mode and the
#     pause -- which is the only place "forward" and "backward" are told apart;
#   * the **status line**, whose separators and order are the scene's;
#   * the **weather line**, including the `slowed N%` term the port was missing and the `0.98`
#     threshold that decides whether it shows;
#   * a **bar's fill** -- `Math.round((bw - 2) * fraction)` -- and the **damage pulse**'s two
#     numbers, the band's thickness and the tint's alpha.
#
# What is left is the layout, and that is a picture's question: a bar at twelve from the right
# edge, a prompt box in the corner and two lines at the bottom are geometry, and geometry is what
# `shot.png` is for. The one *structural* claim a headless run can make is that the scene boots
# with the HUD as a `Control` rather than a `Label`, and `interop.sh offline` is what says so.
#
# The oracle is `drawHud` and `updateWeatherEffects` transcribed from source, and the two halves
# are separate evaluations for the reason `verify_peers.gd` records.
extends SceneTree

## The words: the state word, the status line and the weather line. Every one of them has spaces
## in it, so each is joined with `~` on both sides and compared as one token.
const WORDS_JS := """
(function () {
function stateWord(move, mode, paused) {
    let state = "standing";
    if (mode === "dead") state = "dead - R to restart";
    else if (paused) state = "paused (P to resume)";
    else if (mode === "sleep") state = "sleeping (Z to wake)";
    else if (mode === "jump") state = "jumping";
    else if (mode === "eat") state = "eating";
    else if (move > 0 && mode === "run") state = "running";
    else if (move > 0 && mode === "trot") state = "trotting";
    else if (move > 0) state = "walking forward";
    else if (move < 0) state = "walking backward";
    return state;
}
function statusLine(t) {
    return t[0] + "   speed " + t[1].toFixed(2) + " m/s   phase " + t[2].toFixed(2) +
        "   fps " + t[3] + "   light " + t[4] + "   sky " + t[5] + "   clouds " + t[6] +
        "   audio " + t[7] + "   herd " + t[8];
}
function weatherText(t) {
    let text = t[0] + "   wind " + Math.sqrt(t[1] * t[1] + t[2] * t[2]).toFixed(1) + " m/s";
    if (t[3] > 0.02) text += "   rain " + Math.round(t[3] * 100) + "%";
    if (t[4] < 0.98) text += "   slowed " + Math.round((1 - t[4]) * 100) + "%";
    if (t[5] !== "") text += "   " + t[5];
    return text;
}
function pack(s) { return s.split(" ").join("~"); }
const MOVES = __MOVES__;
const MODES = __MODES__;
for (const move of MOVES) {
    for (const mode of MODES) {
        for (const paused of [0, 1]) {
            console.log('word ' + move + ' ' + mode + ' ' + paused + ' ' +
                pack(stateWord(move, mode, paused === 1)));
        }
    }
}
const STATUS = __STATUS__;
for (let i = 0; i < STATUS.length; i++) {
    console.log('status ' + i + ' ' + pack(statusLine(STATUS[i])));
}
const WEATHER = __WEATHER__;
for (let i = 0; i < WEATHER.length; i++) {
    console.log('weather ' + i + ' ' + pack(weatherText(WEATHER[i])));
}
})();
"""

## The two drawn numbers: a bar's fill in pixels, and the pulse's band and alpha.
const DRAWN_JS := """
(function () {
const FILLS = __FILLS__;
for (let i = 0; i < FILLS.length; i++) {
    console.log('fill ' + i + ' ' + FILLS[i] + ' ' + Math.round((160 - 2) * FILLS[i]));
}
const HURTS = __HURTS__;
for (let i = 0; i < HURTS.length; i++) {
    const a = HURTS[i] > 1 ? 1 : HURTS[i];
    console.log('pulse ' + i + ' ' + HURTS[i] + ' ' + a + ' ' + Math.round(24 + 46 * a));
}
})();
"""

## The goat's own mode vocabulary, which is the gait or one of the five locked modes.
const MODES := ["idle", "walk", "trot", "run", "jump", "sleep", "eat", "dead", "flung"]

## The moves the state word is asked about: forward, still and backward.
const MOVES := [-1, 0, 1]

const TOLERANCE := 1e-12

var _failures: Array[String] = []

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var oracle_word := {}
	var oracle_status := {}
	var oracle_weather := {}
	var oracle_fill := {}
	var oracle_pulse := {}

	var words_source: String = WORDS_JS.replace("__MOVES__", JSON.stringify(MOVES)) \
		.replace("__MODES__", JSON.stringify(MODES)) \
		.replace("__STATUS__", JSON.stringify(_statuses())) \
		.replace("__WEATHER__", JSON.stringify(_weathers()))
	for line in _oracle(host, words_source, "words"):
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log word ") and parts.size() == 6:
			oracle_word["%d %s %s" % [int(parts[2]), parts[3], parts[4]]] = parts[5]
		elif line.begins_with("log status ") and parts.size() == 4:
			oracle_status[int(parts[2])] = parts[3]
		elif line.begins_with("log weather ") and parts.size() == 4:
			oracle_weather[int(parts[2])] = parts[3]

	var drawn_source: String = DRAWN_JS.replace("__FILLS__", JSON.stringify(_fills())) \
		.replace("__HURTS__", JSON.stringify(_hurts()))
	for line in _oracle(host, drawn_source, "drawn"):
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log fill ") and parts.size() == 5:
			oracle_fill[int(parts[2])] = float(parts[4])
		elif line.begins_with("log pulse ") and parts.size() == 6:
			oracle_pulse[int(parts[2])] = PackedFloat64Array([float(parts[4]), float(parts[5])])

	print("oracle answered ", oracle_word.size(), " word(s), ", oracle_status.size(),
		" status line(s), ", oracle_weather.size(), " weather line(s), ",
		oracle_fill.size(), " fill(s), ", oracle_pulse.size(), " pulse(s)")
	host.free()

	# 1. The state word, over every combination the scene's chain can distinguish.
	var word_cases := 0
	var word_mismatches := 0
	var first_word := ""
	for mode in MODES:
		for move in MOVES:
			for paused_state in [0, 1]:
				word_cases += 1
				var mine: String = Hud.state_word(move, mode, paused_state == 1).replace(" ", "~")
				var wanted: String = String(oracle_word.get(
					"%d %s %d" % [move, mode, paused_state], "?"))
				if mine != wanted:
					word_mismatches += 1
					if first_word == "":
						first_word = "move %d, mode '%s', paused %d: scene '%s', port '%s'" % [
							move, mode, paused_state, wanted, mine]
	print("state words: %d case(s), %d mismatch(es)" % [word_cases, word_mismatches])
	if first_word != "":
		print("  first: ", first_word)

	# 2. The status line, whose separators and order are the scene's.
	var statuses: Array = _statuses()
	var status_mismatches := 0
	var first_status := ""
	for index in statuses.size():
		var t: Array = statuses[index]
		var mine: String = Hud.status_line(String(t[0]), float(t[1]), float(t[2]), int(t[3]),
			String(t[4]), String(t[5]), String(t[6]), String(t[7]), int(t[8])).replace(" ", "~")
		var wanted: String = String(oracle_status.get(index, "?"))
		if mine != wanted:
			status_mismatches += 1
			if first_status == "":
				first_status = "row %d: scene '%s', port '%s'" % [index, wanted, mine]
	print("status lines: %d row(s), %d mismatch(es)" % [statuses.size(), status_mismatches])
	if first_status != "":
		print("  first: ", first_status)

	# 3. The weather line, including the `slowed` term and its threshold.
	var weathers: Array = _weathers()
	var weather_mismatches := 0
	var first_weather := ""
	for index in weathers.size():
		var t: Array = weathers[index]
		var weather := {
			"kind": String(t[0]), "wind_x": float(t[1]), "wind_z": float(t[2]),
			"rain_amount": float(t[3]),
		}
		var mine: String = Hud.weather_text(weather, String(t[5]), float(t[4])).replace(" ", "~")
		var wanted: String = String(oracle_weather.get(index, "?"))
		if mine != wanted:
			weather_mismatches += 1
			if first_weather == "":
				first_weather = "row %d: scene '%s', port '%s'" % [index, wanted, mine]
	print("weather lines: %d row(s), %d mismatch(es)" % [weathers.size(), weather_mismatches])
	if first_weather != "":
		print("  first: ", first_weather)

	# 4. A bar's fill and the pulse's two numbers.
	var fills: Array = _fills()
	var fill_mismatches := 0
	var first_fill := ""
	for index in fills.size():
		var mine: float = Hud.bar_fill(float(fills[index]))
		# A row the oracle did not answer is a *failure*, not a skip: a missing number compared
		# against is `NaN`, and every comparison against `NaN` is false, so a parse that quietly
		# matches nothing passes every case. That is the same silence the chunking note in
		# `verify_peers.gd` is about, one layer down.
		if not oracle_fill.has(index):
			fill_mismatches += 1
			if first_fill == "":
				first_fill = "row %d has no oracle" % index
			continue
		var wanted: float = float(oracle_fill[index])
		if absf(mine - wanted) > TOLERANCE:
			fill_mismatches += 1
			if first_fill == "":
				first_fill = "fraction %.4f: scene %.0f, port %.0f" % [
					float(fills[index]), wanted, mine]
	print("fills: %d fraction(s), %d mismatch(es)" % [fills.size(), fill_mismatches])
	if first_fill != "":
		print("  first: ", first_fill)

	var hurts: Array = _hurts()
	var pulse_mismatches := 0
	var first_pulse := ""
	for index in hurts.size():
		var hurt: float = float(hurts[index])
		var mine := PackedFloat64Array([Hud.pulse_alpha(hurt), Hud.pulse_band(hurt)])
		var wanted: PackedFloat64Array = oracle_pulse.get(index, PackedFloat64Array())
		if wanted.size() != 2 or absf(mine[0] - wanted[0]) > TOLERANCE \
				or absf(mine[1] - wanted[1]) > TOLERANCE:
			pulse_mismatches += 1
			if first_pulse == "":
				first_pulse = "pulse %.2f: scene %s, port %s" % [hurt, wanted, mine]
	print("pulses: %d value(s), %d mismatch(es)" % [hurts.size(), pulse_mismatches])
	if first_pulse != "":
		print("  first: ", first_pulse)

	if word_mismatches != 0:
		_failures.append("the state word is not the scene's: %d of %d case(s)"
			% [word_mismatches, word_cases])
	if status_mismatches != 0:
		_failures.append("the status line is not the scene's: %d of %d row(s)"
			% [status_mismatches, statuses.size()])
	if weather_mismatches != 0:
		_failures.append("the weather line is not the scene's: %d of %d row(s)"
			% [weather_mismatches, weathers.size()])
	if fill_mismatches != 0:
		_failures.append("a bar's fill is not the scene's: %d of %d fraction(s)"
			% [fill_mismatches, fills.size()])
	if pulse_mismatches != 0:
		_failures.append("the pulse is not the scene's: %d of %d value(s)"
			% [pulse_mismatches, hurts.size()])

	if _failures.is_empty():
		print("OK: the port's HUD says what the scene says, word for word and pixel for pixel")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)

## The status lines the pair are asked about: a live one, a mid-rain one, a paused one, an
## exhausted-but-walking one, and the four read-outs the settings screen will drive at both ends
## of their ranges.
func _statuses() -> Array:
	var out: Array = []
	for speed: float in [0.0, 1.24, 3.5]:
		for phase: float in [0.0, 0.47, 1.0]:
			for words: Array in [["lit + shadow map", "shader", "medium", "on"],
					["lit", "billboards", "low", "muted"],
					["off", "shader", "high", "off"]]:
				out.append(["08:02", speed, phase, 60, words[0], words[1], words[2], words[3], 7])
	out.append(["00:00", 0.0, 0.0, 0, "lit", "shader", "low", "off", 0])
	out.append(["23:59", 9.99, 0.99, 240, "lit + planar shadow", "shader", "medium", "muted", 10])
	return out

## The weather lines: dry, drizzle, a downpour with wind, both sides of the `0.02` rain threshold
## and both sides of the `0.98` slowdown one, with and without the water's own line.
func _weathers() -> Array:
	var out: Array = []
	for kind: String in ["clear", "cloudy", "rain"]:
		for wind: Array in [[0.0, 0.0], [1.3, 0.0], [0.9, -0.9]]:
			for rain: float in [0.0, 0.019, 0.02, 0.021, 0.55, 1.0]:
				for speed: float in [1.0, 0.979, 0.98, 0.981, 0.62]:
					out.append([kind, wind[0], wind[1], rain, speed, ""])
	out.append(["rain", 1.0, 0.0, 0.8, 0.7, "water 0.70 m   slowed 35%"])
	out.append(["clear", 0.0, 0.0, 0.0, 1.0, "water 0.10 m"])
	return out

## The belly and the bars at every end of their ranges, including the pixel a round-half-up lands
## on.
func _fills() -> Array:
	return [0.0, 0.001, 0.25, 0.3333, 0.5, 0.6667, 0.75, 0.9999, 1.0]

## The pulse from nothing to past full, including the value `hurtBy` clamps at.
func _hurts() -> Array:
	return [0.0, 0.01, 0.25, 0.5, 0.75, 0.999, 1.0, 1.2]

## Run one oracle script and hand back its lines, `log ` included.
func _oracle(host: Object, source: String, which: String) -> PackedStringArray:
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle (", which, ") did not run: ", evaluated)
		quit(1)
		return PackedStringArray()
	var lines := PackedStringArray()
	for line in host.call("poll_lines"):
		lines.append(String(line))
	return lines

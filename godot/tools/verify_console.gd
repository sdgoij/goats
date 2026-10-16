# The console gate (M24): the shell's ring, line and wrap, and the dispatcher's vocabulary.
#
#   Godot --headless --path godot --script res://tools/verify_console.gd
#
# The console is two files with two different kinds of claim to hold, so this gate holds both
# in one run:
#
#   * the **shell** (`console.gd`) is a set of counters and a wrap, and every one of them is a
#     rule rather than a placement -- the 200-line ring and its `\n` split, the 512-character
#     line and the caret that edits it, the 32-entry history that refuses two identical lines
#     in a row, the paste sanitiser, and the reply protocol (`""` prints nothing, a `void`
#     reply is `ok`). Those are asserted directly, with no oracle, because they are this
#     language's own arithmetic;
#   * the **vocabulary** (`commands.gd`) is transcribed from `ctl.js`, so its *pure* pieces are
#     held against a JavaScript oracle transcribed from the same source: the `help` page, the
#     `Number.isFinite(Number(token))` argument rule, `Math.round(v * 100) / 100`, the
#     `consoleWrap` algorithm at the width the scene falls back to, and `drawConsole`'s panel
#     arithmetic. A table of dispatched lines then pins the reply each one gives -- the arity
#     errors, the unknown command, the `/verb` stripping, and the `error <system> unavailable`
#     verbs whose system is a later stage.
#
# What is deliberately *not* held is any verb that would read a world module: this gate builds
# a `Commands` with no scene and no modules, so `state`, `grass`, `traps`, `mute` and the rest
# are out of reach here and are a played session's question, not a headless one's. That is the
# same split `verify_hud.gd` makes between the words and the layout -- what a gate can hold is
# the rules, and what it cannot is whether they are *wired*.
#
# The oracle is `ctl.js`, `console.js` and `goat.js` transcribed from source. The two scripts
# are separate evaluations for the reason `verify_peers.gd` records: `eval_js` evaluates into
# one realm, so a top-level `const` is a `SyntaxError` the second time a script names it.
extends SceneTree

## The vocabulary's pure rules, transcribed from `ctl.js`.
const VOCAB_JS := """
(function () {
const HELP_GROUPS = __GROUPS__;
const rows = ["help - commands by topic"];
for (let i = 0; i < HELP_GROUPS.length; i++) {
    rows.push("  " + HELP_GROUPS[i][0].padEnd(8) + HELP_GROUPS[i][1]);
}
const HELP = rows.join("\\n");
function pack(s) { return s.split(" ").join("~"); }
const helpRows = HELP.split("\\n");
for (let i = 0; i < helpRows.length; i++) console.log('help ' + i + ' ' + pack(helpRows[i]));
// `ctlArg`: a token that is not a finite number is null.
function ctlArg(parts, index) {
    if (index >= parts.length) return null;
    const value = Number(parts[index]);
    return Number.isFinite(value) ? value : null;
}
const ARGS = __ARGS__;
for (let i = 0; i < ARGS.length; i++) {
    const got = ctlArg(ARGS[i][0], ARGS[i][1]);
    console.log('arg ' + i + ' ' + (got === null ? 'null' : String(got)));
}
// `ctlRound`.
const ROUNDS = __ROUNDS__;
for (let i = 0; i < ROUNDS.length; i++) {
    console.log('round ' + i + ' ' + String(Math.round(ROUNDS[i] * 100) / 100));
}
// `consoleWrap` at the fallback width (`consoleTextWidth` without `measureTextEx`).
function textWidth(text, size) { return String(text).length * size * 0.55; }
function wrap(text, maxWidth, size) {
    if (textWidth(text, size) <= maxWidth) return [text];
    const indent = (/^\\s*/.exec(text) || [""])[0];
    const words = text.slice(indent.length).split(" ");
    const rows = [];
    let row = "";
    for (let i = 0; i < words.length; i++) {
        const word = words[i];
        const candidate = row === "" ? word : row + " " + word;
        if (textWidth(indent + candidate, size) <= maxWidth) { row = candidate; continue; }
        if (row !== "") rows.push(row);
        let rest = word;
        while (textWidth(indent + rest, size) > maxWidth && rest.length > 1) {
            let cut = rest.length - 1;
            while (cut > 1 && textWidth(indent + rest.slice(0, cut), size) > maxWidth) cut -= 1;
            rows.push(rest.slice(0, cut));
            rest = rest.slice(cut);
        }
        row = rest;
    }
    if (row !== "") rows.push(row);
    for (let i = 0; i < rows.length; i++) rows[i] = indent + rows[i];
    return rows;
}
const WRAPS = __WRAPS__;
for (let i = 0; i < WRAPS.length; i++) {
    const got = wrap(WRAPS[i][0], WRAPS[i][1], WRAPS[i][2]);
    console.log('wrap ' + i + ' ' + got.join('\\u0001'));
}
// `drawConsole`'s panel arithmetic.
const BOXES = __BOXES__;
for (let i = 0; i < BOXES.length; i++) {
    const screen = BOXES[i][0];
    const count0 = BOXES[i][1];
    const lineH = 18;
    const pad = 10;
    const maxRows = Math.max(3, Math.floor((screen[1] * 0.5 - pad * 2 - lineH) / lineH));
    const maxWidth = Math.max(80, screen[0] - pad * 2);
    const count = Math.min(count0, maxRows);
    const first = count0 - count;
    const panelH = Math.min(screen[1], pad * 2 + (count + 1) * lineH);
    console.log('box ' + i + ' ' + maxRows + ' ' + maxWidth + ' ' + count + ' ' + first + ' ' + panelH);
}
})();
"""

## The dispatched lines and the reply each must give, with no scene and no world modules. It is
## every verb that answers before it reaches a module: the arity errors, the unknown command,
## the `/verb` stripping, the honest `unavailable` answers, and the handful whose effect is a
## `cmd_*` call the null scene swallows.
const TABLE := [
	["", "error empty command"],
	["   ", "error empty command"],
	["/", "error unknown command: /"],
	["/ping", "ok pong"],
	["ping", "ok pong"],
	["nope", "error unknown command: nope"],
	["tune", "error tune unavailable"],
	["tune water.reflection", "error tune unavailable"],
	["perf", "error perf unavailable"],
	["perf on", "error perf unavailable"],
	["mod", "error mod unavailable"],
	["mod list", "error mod unavailable"],
	# `host` is backed now, and its `cmd_*` call is swallowed by the null scene -- so it answers
	# its own fixed line here, like `camera reset` does. The *live* table does not run it: a host
	# binds a real endpoint, which is the net gate's business rather than the vocabulary's.
	["host", "ok host"],
	["host bob", "ok host"],
	["pools", "error pools unavailable"],
	["lighting", "ok lighting off"],
	["shadows map", "ok shadows map"],
	["shadows bogus", "error shadows expects off|map"],
	["shadows planar", "error planar shadow unavailable"],
	["sky on", "ok sky on"],
	["camera reset", "ok camera reset"],
	["camera a b c", "error camera expects <yawDeg> <pitchDeg> <dist>"],
	["camera 45 20 6", "ok camera 0.79 0.35 6"],
	["yaw abc", "error yaw expects degrees"],
	["pos 1", "error pos expects <x> <z>"],
	["health x", "error health expects a number"],
	["energy", "error energy expects a number"],
	["phase", "error phase expects a number"],
	["step 0", "error step expects a positive frame count"],
	["step -3", "error step expects a positive frame count"],
	["step x", "error step expects a positive frame count"],
	["ui bogus", "error ui expects hud|main|settings|keymap|mods"],
	["ui main", "ok ui main"],
	["ui settings", "ok ui settings"],
	["msg", "error msg expects a name"],
	["msg bob", "error msg expects a message"],
	["connect", "error connect expects a ticket"],
	["connect --pull", "error connect expects a ticket"],
	["leave", "error not in a session"],
	["disconnect", "error not in a session"],
	["who", "error not in a session"],
	["say hi", "error not in a session"],
	["msg bob hi", "error not in a session"],
	["net", 'ok {"mode":"off","name":"","ticket":"","roster":[]}'],
	["flood abc", "error flood: expects a number or 'off'"],
	["screenshot", "error screenshot expects a path"],
	["quit", "ok quit"],
	["walk", "ok walk"],
	["stop", "ok stop"],
	["turn", "ok turn stop"],
	["turn left", "ok turn left"],
	["turn sideways", "error turn expects left|right|stop"],
]

## The argument cases: `[parts, index]`. Every token is one the split can produce (so never the
## empty string, whose `Number("")` is 0 in JavaScript and which is why it is excluded).
const ARG_CASES := [
	[["0"], 0], [["1"], 0], [["-1"], 0], [["1.5"], 0], [["-2.25"], 0], [["007"], 0],
	[["1e3"], 0], [["abc"], 0], [["12abc"], 0], [["NaN"], 0], [["Infinity"], 0],
	[["who"], 1], [["pos", "1"], 1], [["pos", "1"], 2],
]

## The rounding cases, both signs and both sides of an exact `.5`.
const ROUND_CASES := [
	0.0, 0.125, -0.125, 1.2345, 123.456, -123.456, 2.5, -2.5, 0.005, 0.015, -0.005,
	-0.015, 100.005, 0.4999999999, 5.0, -5.0,
]

const TOLERANCE := 1e-9

## The lines run against the *live* scene, and how each reply is judged: `exact` for the ones
## with a fixed answer, `starts` and `contains` for the read-outs whose numbers depend on the
## world (a clock, a JSON object). This is the half the pure table above cannot hold -- whether
## the vocabulary is *wired* -- and it is here because the first version of this console had a
## blank panel that every pure case passed through: `_draw` called `wrap`, which is a global
## function in this language, and the class's own method was never reached (see `console.gd`).
const LIVE := [
	["ping", "exact", "ok pong"],
	["help", "starts", "ok help - commands by topic"],
	["nope", "exact", "error unknown command: nope"],
	["tune water.reflection", "exact", "error tune unavailable"],
	# `mod` is backed as of stage 1 (`mods.gd`): the live scene has a table, so the two readable
	# halves answer from it. The pure table above still says `unavailable`, because a `Commands`
	# with no modules has no table to print.
	["mod", "starts", "ok ["],
	["mod list", "starts", "ok ["],
	["mod key", "starts", "ok ["],
	["mod bogus", "exact", "error mod expects list|key|info|enable|disable"],
	["perf", "exact", "error perf unavailable"],
	# `host` is deliberately absent: it is backed, so running it here would bind a real session
	# endpoint inside a partly-pure gate. `verify_net.gd` is where a session is started.
	["pools", "starts", "ok ["],
	["lighting", "exact", "ok lighting off"],
	["lighting", "exact", "ok lighting on"],
	["who", "exact", "error not in a session"],
	["net", "starts", "ok {\"mode\":\"off\""],
	["time", "starts", "ok {\"hours\""],
	["time 12", "exact", "ok time 12"],
	["weather", "starts", "ok {\"kind\""],
	["weather rain", "exact", "ok weather rain"],
	["weather bogus", "contains", "error unknown weather: bogus"],
	["camera", "starts", "ok {\"yaw\""],
	["camera 90 20 6", "exact", "ok camera 1.57 0.35 6"],
	["camera reset", "exact", "ok camera reset"],
	["state", "contains", "\"mode\":\"idle\""],
	["stats", "contains", "\"exhausted\":false"],
	["features", "contains", "\"shadows\":\"map\""],
	["bots", "contains", "\"count\":7"],
	["fps", "starts", "ok "],
	["pos 3 4", "exact", "ok pos 3 4"],
	["phase 1.25", "exact", "ok phase 0.25"],
	["yaw 90", "exact", "ok yaw 1.57"],
	["health 42", "exact", "ok health 42"],
	["heal", "exact", "ok heal"],
	["energy 0", "exact", "ok energy 0"],
	["stats", "contains", "\"exhausted\":true"],
	["energy 100", "exact", "ok energy 100"],
	["flood -0.9", "exact", "ok flood -0.9"],
	["water", "contains", "\"forced\":true"],
	["water off", "exact", "ok water off"],
	["water on", "exact", "ok water on"],
	["flood off", "exact", "ok flood off"],
	["setting reflect sky", "exact", "ok setting reflect"],
	["settings", "contains", "\"reflect\":\"sky\""],
	["setting herd 3", "exact", "ok setting herd"],
	["settings", "contains", "\"herd\":3"],
	["setting cloud high", "exact", "ok setting cloud"],
	["settings", "contains", "\"cloud\":\"high\""],
	["setting bgm 50", "exact", "ok setting bgm"],
	["setting shadow map", "exact", "ok setting shadow"],
	["setting shadow planar", "exact", "error setting shadow expects off|map"],
	["mute on", "exact", "ok mute on"],
	["mute off", "exact", "ok mute off"],
	["ui", "exact", "ok hud"],
	["ui main", "exact", "ok ui main"],
	["ui hud", "exact", "ok ui hud"],
	["grass 60", "starts", "ok "],
	["traps 30", "starts", "ok {"],
	["craters 30", "starts", "ok {"],
	["console", "contains", "\"open\":false"],
	["console toggle", "exact", "ok console open"],
	["console", "contains", "\"open\":true"],
	["console close", "exact", "ok console close"],
	["walk", "exact", "ok walk"],
	["turn left", "exact", "ok turn left"],
	["turn stop", "exact", "ok turn stop"],
	["stop", "exact", "ok stop"],
	["jump", "exact", "ok jump"],
	["sleep", "exact", "ok sleep"],
	["sleep", "exact", "error already asleep"],
	["wake", "exact", "ok wake"],
	["kill", "exact", "ok kill"],
	["kill", "exact", "error already dead"],
	["jump", "exact", "error cannot jump while dead"],
	["restart", "exact", "ok restart"],
	["pause", "exact", "ok pause"],
	["resume", "exact", "ok resume"],
	["step 5", "exact", "ok step 5"],
	["screenshot", "exact", "error screenshot expects a path"],
]

var _failures: Array[String] = []
var _frames := 0
var _main: Node

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var oracle_help := {}
	var oracle_arg := {}
	var oracle_round := {}
	var oracle_wrap := {}
	var oracle_box := {}
	var source: String = VOCAB_JS \
		.replace("__GROUPS__", JSON.stringify(Commands.HELP_GROUPS)) \
		.replace("__ARGS__", JSON.stringify(ARG_CASES)) \
		.replace("__ROUNDS__", JSON.stringify(ROUND_CASES)) \
		.replace("__WRAPS__", JSON.stringify(_wraps())) \
		.replace("__BOXES__", JSON.stringify(_boxes()))
	for line in _oracle(host, source, "vocabulary"):
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log help ") and parts.size() >= 4:
			oracle_help[int(parts[2])] = parts[3]
		elif line.begins_with("log arg ") and parts.size() >= 4:
			oracle_arg[int(parts[2])] = parts[3]
		elif line.begins_with("log round ") and parts.size() >= 4:
			oracle_round[int(parts[2])] = float(parts[3])
		elif line.begins_with("log wrap ") and parts.size() >= 4:
			# A wrapped row can hold spaces, so the payload is everything after the prefix
			# rather than a token: the split is only good for finding the row's index.
			var index: int = int(parts[2])
			oracle_wrap[index] = line.substr(("log wrap %d " % index).length())
		elif line.begins_with("log box ") and parts.size() == 8:
			oracle_box[int(parts[2])] = PackedInt32Array([
				int(parts[3]), int(parts[4]), int(parts[5]), int(parts[6]), int(parts[7])])
	print("oracle answered ", oracle_help.size(), " help row(s), ", oracle_arg.size(),
		" arg(s), ", oracle_round.size(), " round(s), ", oracle_wrap.size(), " wrap(s), ",
		oracle_box.size(), " box(es)")
	host.free()

	_check_help(oracle_help)
	_check_args(oracle_arg)
	_check_rounds(oracle_round)
	_check_wraps(oracle_wrap)
	_check_boxes(oracle_box)
	_check_shell()
	_check_table()

	# The live half: the real scene, whose console and vocabulary are what a player actually
	# gets. `SceneTree.root` is not inside the tree while `_initialize` runs, so the scene is
	# instantiated here and *read* a few frames later in `_process` -- the trap that moved the
	# reflection gate's body, and the reason the live table is not run in `_initialize`.
	var packed := load("res://scenes/herd.tscn") as PackedScene
	_main = packed.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	_check_live()
	if _failures.is_empty():
		print("OK: the port's console is the scene's -- the ring, the line, the wrap and the "
			+ "vocabulary, pure and wired")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

## The live table: every line run against the scene's own vocabulary, judged `exact`,
## `starts` or `contains`. A blank reply from a command is a failure here too -- only chat is
## silent -- so an empty answer is caught whichever mode the row asked for.
func _check_live() -> void:
	var vocabulary: Commands = _main.get("commands")
	if vocabulary == null:
		_failures.append("the scene did not build a Commands")
		return
	print("live: the scene is up, running ", LIVE.size(), " line(s)")
	var mismatches: int = 0
	var first: String = ""
	for row: Array in LIVE:
		var line: String = String(row[0])
		var mode: String = String(row[1])
		var wanted: String = String(row[2])
		var mine: String = vocabulary.run(line)
		var ok: bool = false
		if mode == "exact":
			ok = mine == wanted
		elif mode == "starts":
			ok = mine.begins_with(wanted)
		else:
			ok = mine.contains(wanted)
		if not ok or mine == "":
			mismatches += 1
			if first == "":
				first = "'%s': wanted (%s) '%s', got '%s'" % [line, mode, wanted, mine]
	print("live dispatch: %d line(s), %d mismatch(es)" % [LIVE.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("the live vocabulary is not wired: %d of %d line(s)"
			% [mismatches, LIVE.size()])

## `help`: the header and one padded row per group, compared row for row.
func _check_help(oracle: Dictionary) -> void:
	var mine: PackedStringArray = Commands.help_text().split("\n")
	var mismatches: int = 0
	var first: String = ""
	for i in mine.size():
		var wanted: String = String(oracle.get(i, ""))
		var packed: String = mine[i].replace(" ", "~")
		if packed != wanted:
			mismatches += 1
			if first == "":
				first = "row %d: scene '%s', port '%s'" % [i, wanted, packed]
	print("help rows: %d row(s), %d mismatch(es)" % [mine.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0 or mine.size() != oracle.size():
		_failures.append("the help page is not the scene's: %d of %d row(s)"
			% [mismatches, mine.size()])

## `ctlArg`: the token a parts list names, or nothing.
func _check_args(oracle: Dictionary) -> void:
	var mismatches: int = 0
	var first: String = ""
	for i in ARG_CASES.size():
		var row: Array = ARG_CASES[i]
		var tokens := PackedStringArray()
		for token in row[0]:
			tokens.append(String(token))
		var mine: Variant = Commands.ctl_arg(tokens, int(row[1]))
		var wanted: String = String(oracle.get(i, "?"))
		if wanted == "?":
			mismatches += 1
			if first == "":
				first = "row %d has no oracle" % i
			continue
		var mine_word: String = "null" if mine == null else str(mine)
		var agree: bool = wanted == "null" and mine == null
		if not agree and wanted != "null" and mine != null:
			agree = absf(float(mine) - float(wanted)) <= TOLERANCE
		if not agree:
			mismatches += 1
			if first == "":
				first = "row %d: scene %s, port %s" % [i, wanted, mine_word]
	print("arguments: %d case(s), %d mismatch(es)" % [ARG_CASES.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("ctlArg is not the scene's: %d of %d case(s)"
			% [mismatches, ARG_CASES.size()])

## `ctlRound`: `Math.round(value * 100) / 100`, half toward +infinity and all.
func _check_rounds(oracle: Dictionary) -> void:
	var mismatches: int = 0
	var first: String = ""
	for i in ROUND_CASES.size():
		var mine: float = Commands.ctl_round(float(ROUND_CASES[i]))
		if not oracle.has(i):
			mismatches += 1
			if first == "":
				first = "row %d has no oracle" % i
			continue
		var wanted: float = float(oracle[i])
		if absf(mine - wanted) > TOLERANCE:
			mismatches += 1
			if first == "":
				first = "%.17f: scene %.17f, port %.17f" % [float(ROUND_CASES[i]), wanted, mine]
	print("rounds: %d case(s), %d mismatch(es)" % [ROUND_CASES.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("ctlRound is not the scene's: %d of %d case(s)"
			% [mismatches, ROUND_CASES.size()])

## `consoleWrap`: the same rows at the same width, joined with a separator neither side has.
func _check_wraps(oracle: Dictionary) -> void:
	var cases: Array = _wraps()
	var mismatches: int = 0
	var first: String = ""
	for i in cases.size():
		var row: Array = cases[i]
		var mine: String = "\u0001".join(Console.wrap_rows(String(row[0]), float(row[1]), int(row[2])))
		var wanted: String = String(oracle.get(i, "?")) if oracle.has(i) else "?"
		if mine != wanted:
			mismatches += 1
			if first == "":
				first = "case %d: scene '%s', port '%s'" % [i, wanted.replace("\u0001", " | "),
					mine.replace("\u0001", " | ")]
	print("wraps: %d case(s), %d mismatch(es)" % [cases.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("consoleWrap is not the scene's: %d of %d case(s)"
			% [mismatches, cases.size()])

## `drawConsole`'s panel arithmetic: the rows that fit, the width, and the panel's height.
func _check_boxes(oracle: Dictionary) -> void:
	var cases: Array = _boxes()
	var mismatches: int = 0
	var first: String = ""
	for i in cases.size():
		var row: Array = cases[i]
		var screen := Vector2(float(row[0][0]), float(row[0][1]))
		var box: Dictionary = Console.layout(screen, int(row[1]))
		var mine := PackedInt32Array([
			int(box["maxRows"]), int(box["maxWidth"]), int(box["count"]),
			int(box["first"]), int(box["panelH"])])
		if not oracle.has(i):
			mismatches += 1
			if first == "":
				first = "row %d has no oracle" % i
			continue
		var wanted: PackedInt32Array = oracle[i]
		if mine != wanted:
			mismatches += 1
			if first == "":
				first = "row %d: scene %s, port %s" % [i, wanted, mine]
	print("panels: %d case(s), %d mismatch(es)" % [cases.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("the panel's arithmetic is not the scene's: %d of %d case(s)"
			% [mismatches, cases.size()])

## The shell's own counters and its reply protocol. These have no oracle: they are this
## language's arithmetic, and what they are compared against is the *rule* `console.js` states.
func _check_shell() -> void:
	var shell := Console.new()

	# `consolePush`: one entry per row of a `\n`-split, and the ring drops the oldest at 200.
	shell.push("a\nb\nc", "net")
	_expect(shell.lines.size() == 3, "push splits on \\n into one entry per row")
	_expect(String(shell.lines[0]["text"]) == "a" and String(shell.lines[0]["kind"]) == "net",
		"a pushed row keeps its kind")
	for i in 300:
		shell.push("row %d" % i)
	_expect(shell.lines.size() == Console.MAX_LINES,
		"the ring holds %d rows" % Console.MAX_LINES)
	_expect(String(shell.lines[Console.MAX_LINES - 1]["text"]) == "row 299",
		"the ring drops the oldest and keeps the newest")

	# `consoleInsert` / `consoleBackspace` / the caret.
	var line := Console.new()
	line.insert("abc")
	_expect(line.input_text == "abc" and line.caret == 3, "a typed line lands at the caret")
	line.caret = 1
	line.insert("XY")
	_expect(line.input_text == "aXYbc" and line.caret == 3, "an insert goes *at* the caret")
	line.backspace()
	_expect(line.input_text == "aXbc" and line.caret == 2, "a backspace rubs out behind the caret")
	line.caret = 0
	line.backspace()
	_expect(line.input_text == "aXbc" and line.caret == 0, "a backspace at the start does nothing")
	var full := Console.new()
	full.insert("x".repeat(Console.MAX_INPUT + 50))
	_expect(full.input_text.length() == Console.MAX_INPUT,
		"the line is capped at %d characters" % Console.MAX_INPUT)
	var extra: int = full.input_text.length()
	full.insert("y")
	_expect(full.input_text.length() == extra, "a full line takes no more")

	# `consoleSanitizePaste`: no control characters, and trimmed.
	_expect(Console.sanitize_paste("  a\nb\tc\u007f ") == "abc",
		"a paste drops the control characters and trims")

	# The history: no consecutive duplicate, and 32 kept.
	var hist := Console.new()
	hist.submit("one", func(_l: String) -> String: return "")
	hist.submit("one", func(_l: String) -> String: return "")
	_expect(hist.history.size() == 1, "a repeated line is not put in the history twice")
	hist.submit("two", func(_l: String) -> String: return "")
	hist.submit("one", func(_l: String) -> String: return "")
	_expect(hist.history.size() == 3, "a line that is not the last is kept again")
	for i in 60:
		hist.submit("cmd%d" % i, func(_l: String) -> String: return "")
	_expect(hist.history.size() == Console.HISTORY,
		"the history holds %d lines" % Console.HISTORY)

	# The reply protocol: `""` prints nothing, and an empty line does nothing at all.
	var quiet := Console.new()
	quiet.submit("say hi", func(_l: String) -> String: return "")
	_expect(quiet.lines.size() == 1 and String(quiet.lines[0]["kind"]) == "echo",
		"an empty reply prints nothing but the echo")
	_expect(quiet.input_text == "" and quiet.caret == 0, "a submit clears the line")
	var empty := Console.new()
	empty.submit("   ", func(_l: String) -> String: return "ok never")
	_expect(empty.lines.is_empty() and empty.history.is_empty(),
		"an empty line is not echoed, run or remembered")
	# A void reply is `ok`, and a pending question consumes the line instead of dispatching it.
	var asked := Console.new()
	asked.submit("ping", func(_l: String) -> String: return "")
	asked.ask("Username?", func(answer: String) -> String: return "hello " + answer)
	asked.submit("bob", func(_l: String) -> String: return "ok dispatched")
	var last: String = String(asked.lines[asked.lines.size() - 1]["text"])
	_expect(last == "hello bob", "a pending question takes the next line as its answer")

	# A `Control` owns `CanvasItem` RIDs even outside the tree, so every shell this gate builds
	# is handed back -- a leak is a warning, and a warning in a passing gate is noise.
	for control: Console in [shell, line, full, hist, quiet, empty, asked]:
		control.free()

## The dispatch table: one line in, the reply it must give out.
func _check_table() -> void:
	var vocabulary := Commands.new()
	var mismatches: int = 0
	var first: String = ""
	for row: Array in TABLE:
		var line: String = String(row[0])
		var wanted: String = String(row[1])
		var mine: String = vocabulary.run(line)
		if mine != wanted:
			mismatches += 1
			if first == "":
				first = "'%s': wanted '%s', got '%s'" % [line, wanted, mine]
	print("dispatch: %d line(s), %d mismatch(es)" % [TABLE.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("the dispatcher is not the scene's: %d of %d line(s)"
			% [mismatches, TABLE.size()])
	# A `run` that can answer at all is the point; an empty reply from a *command* is not a
	# thing the vocabulary does (only chat is silent), so a blank answer would be a bug.
	var blank: int = 0
	for row: Array in TABLE:
		if vocabulary.run(String(row[0])) == "":
			blank += 1
	if blank != 0:
		_failures.append("%d dispatched line(s) answered with nothing" % blank)

## The wrap cases: whole words, a long token split by shrinking the cut, the indentation kept
## on every row, and both sides of the width boundary. `size` is the row height the scene
## draws at (18), so the fallback width is 9.9 px a character.
func _wraps() -> Array:
	var long_token: String = "x".repeat(30)
	return [
		["short line", 99.0, 18],
		["aaaaaaaaaa", 99.0, 18],
		[long_token, 99.0, 18],
		["hello world", 99.0, 18],
		["hello world again", 99.0, 18],
		["    indented words here", 99.0, 18],
		["\t\ttabbed and long enough to wrap", 99.0, 18],
		["", 99.0, 18],
		["a b c d e f g h i j k l m n o p", 160.0, 18],
		["one", 1.0, 18],
		[long_token + " tail", 120.0, 18],
		["mid token split: " + long_token, 150.0, 18],
	]

## The panel cases: the two test resolutions, and line counts on both sides of `maxRows`.
func _boxes() -> Array:
	return [
		[[1280.0, 720.0], 0],
		[[1280.0, 720.0], 5],
		[[1280.0, 720.0], 17],
		[[1280.0, 720.0], 18],
		[[1280.0, 720.0], 100],
		[[200.0, 100.0], 0],
		[[200.0, 100.0], 2],
		[[200.0, 100.0], 40],
		[[1920.0, 1080.0], 1000],
		[[320.0, 240.0], 30],
	]

## Hold one claim, and name it when it fails.
func _expect(condition: bool, claim: String) -> void:
	if not condition:
		_failures.append(claim)

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

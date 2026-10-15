# The peers gate (M21): `net.js`'s mirror of the *other players*, against its own source.
#
#   Godot --headless --path godot --script res://tools/verify_peers.gd
#
# The port has mirrored the host's *bots* since the herd landed (`herd.gd`), and it did not
# mirror the host's *people* at all: a `peer` event fell through `main.gd`'s dispatch unused, so
# two clients in one session could not see each other and a Godot client could not see a raylib
# one. What this holds is the whole of the rule that fixes it, and the rule is almost entirely
# *buffering* -- what a snapshot does to a goat's numbers before the goat is drawn:
#
#   * which gaits are one-shots (`netPeerShot`), because a one-shot is posed straight from the
#     snapshot's phase rather than eased into;
#   * the role table (`peerRole`), with its fallback chain -- `flung` to `jump`, everything to
#     `walk` -- asked against every model that could lack a clip, not only this one;
#   * and the three easing lines (`updatePeers`): a position eases by a fixed fraction, a yaw
#     takes the short way round, a looped phase wraps (`0.9 -> 0.1` is a tenth of a lap
#     forward, and a one-shot must never be read that way).
#
# The oracle is `net.js` transcribed *from the source*: a case that agreed with the port's
# implementation of these lines would prove nothing.
#
# **The easing grid is run in chunks.** One `eval_js` carrying all 384 rows -- a
# nineteen-kilobyte argument literal -- reported `ok` and logged nothing at all, so a case that
# reads "the oracle says nothing" as agreement reads a *silent* oracle as a pass. The same rows
# in chunks of `STEP_CHUNK` answer every one of them, and each row prints its own index so the
# order the chunks land in does not matter. The oracles are function-wrapped besides: `eval_js`
# evaluates into one realm, so a top-level `const` is a `SyntaxError` the second time a script
# names it.
#
# What no case can hold is what a peer *looks like* -- a goat posed from a 20 Hz snapshot is a
# picture's question, the same gap M20d and M20e shipped with -- and the live half below stops
# at the two things a frame cannot lie about: the first snapshot places a goat exactly rather
# than easing it in from the origin, and the flung height is applied rather than smoothed.
extends SceneTree

## `net.js`'s peer section, transcribed from `net.js` itself: the one-shot test and the role
## table, which is `peerRole` with its `CLIP` argument made explicit so a model can be asked
## about one its clips short.
##
## Both oracles are wrapped in a function, and that is not tidiness: `eval_js` evaluates into
## one realm, so a top-level `const` here is a `SyntaxError` the *second* time a script names
## it -- which is what the easing's chunks do.
const ROLES_JS := """
(function () {
function netPeerShot(gait) {
    return gait === "jump" || gait === "dead" || gait === "eat" || gait === "flung";
}
function peerRole(gait, clip) {
    if (gait === "dead" && clip.death) return "death";
    if (gait === "sleep" && clip.sleep) return "sleep";
    if (gait === "eat" && clip.eat) return "eat";
    if (gait === "flung") return clip.flung ? "flung" : "jump";
    if (gait === "jump" && clip.jump) return "jump";
    if (gait === "run" && clip.run) return "run";
    if (gait === "trot" && clip.trot) return "trot";
    if (gait === "walk" && clip.walk) return "walk";
    if (clip.idle) return "idle";
    return "walk";
}
const GAITS = __GAITS__;
for (const gait of GAITS) console.log('shot ' + gait + ' ' + (netPeerShot(gait) ? 1 : 0));
const CLIPS = __CLIPS__;
const SUBSETS = __SUBSETS__;
for (const mask of SUBSETS) {
    const clip = {};
    for (let i = 0; i < CLIPS.length; i++) clip[CLIPS[i]] = (mask & (1 << i)) !== 0;
    for (const gait of GAITS) console.log('role ' + gait + ' ' + mask + ' ' + peerRole(gait, clip));
}
})();
"""

## One slice of the easing: `updatePeers`'s body, row by row, with no session around it.
const STEPS_JS := """
(function () {
const NET_PEER_SMOOTH = 12;
function mod1(v) { return ((v % 1) + 1) % 1; }
const BASE = __BASE__;
const STEPS = __STEPS__;
for (let i = 0; i < STEPS.length; i++) {
    const s = STEPS[i];
    const k = Math.min(1, s[9] * NET_PEER_SMOOTH);
    let x = s[0], z = s[1], yaw = s[2], phase = s[3];
    const tx = s[4], tz = s[5], tyaw = s[6], tphase = s[7];
    const shot = s[8] === 1;
    x += (tx - x) * k;
    z += (tz - z) * k;
    let dy = tyaw - yaw;
    while (dy > Math.PI) dy -= 2 * Math.PI;
    while (dy < -Math.PI) dy += 2 * Math.PI;
    yaw += dy * k;
    if (shot) {
        phase = tphase;
    } else {
        let dp = tphase - phase;
        if (dp > 0.5) dp -= 1;
        else if (dp < -0.5) dp += 1;
        phase = mod1(phase + dp * k);
    }
    console.log('step ' + (BASE + i) + ' ' + x + ' ' + z + ' ' + yaw + ' ' + phase);
}
})();
"""

## The gaits the wire can name, which is `proto::Gait` and `net.js`'s own vocabulary.
const GAITS := ["walk", "trot", "run", "jump", "sleep", "eat", "death", "flung", "idle"]

## The roles a model can carry a clip for, in the bit order the subsets index.
const CLIPS := ["idle", "walk", "trot", "run", "jump", "sleep", "eat", "death", "flung"]

## The models the role table is asked about: this one, none, each single clip, every pair the
## fallback chain actually distinguishes, and each one-clip-short model. The chains that matter
## are `flung -> jump -> walk` and the last-resort `walk`, and a one-clip-short model is the
## only way to reach either.
const SUBSETS := [
	511, 0,
	1, 2, 4, 8, 16, 32, 64, 128, 256,
	272, 3,
	255, 495, 510, 383, 447, 479, 509, 507, 503, 270,
]

## How many easing rows go into one `eval_js`. See the header: the whole grid at once produces
## no output at all, quietly.
const STEP_CHUNK := 48

const TOLERANCE := 1e-12

var _failures: Array[String] = []
var _frames := 0
var _live: Peers
var _staged := {}

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var oracle_shot := {}
	var oracle_role := {}
	var oracle_step := {}

	var roles_source: String = ROLES_JS.replace("__GAITS__", JSON.stringify(GAITS)) \
		.replace("__CLIPS__", JSON.stringify(CLIPS)) \
		.replace("__SUBSETS__", JSON.stringify(SUBSETS))
	for line in _oracle(host, roles_source, "roles"):
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log shot ") and parts.size() == 4:
			oracle_shot[parts[2]] = int(parts[3])
		elif line.begins_with("log role ") and parts.size() == 5:
			oracle_role["%s %s" % [parts[2], parts[3]]] = parts[4]

	var steps: Array = _steps()
	for start in range(0, steps.size(), STEP_CHUNK):
		var chunk: Array = steps.slice(start, mini(steps.size(), start + STEP_CHUNK))
		var steps_source: String = STEPS_JS.replace("__BASE__", str(start)) \
			.replace("__STEPS__", JSON.stringify(chunk))
		for line in _oracle(host, steps_source, "steps"):
			var parts: PackedStringArray = line.split(" ")
			if line.begins_with("log step ") and parts.size() == 7:
				oracle_step[int(parts[2])] = PackedFloat64Array([
					float(parts[3]), float(parts[4]), float(parts[5]), float(parts[6])])

	print("oracle answered ", oracle_shot.size(), " gait(s), ", oracle_role.size(),
		" role(s), ", oracle_step.size(), " of ", steps.size(), " step(s)")
	host.free()

	# 1. The one-shots.
	var shot_mismatches := 0
	var first_shot := ""
	for gait in GAITS:
		var mine: bool = Peers.shot(gait)
		var wanted: bool = int(oracle_shot.get(gait, -1)) == 1
		if mine != wanted:
			shot_mismatches += 1
			if first_shot == "":
				first_shot = "'%s': scene %s, port %s" % [gait, wanted, mine]
	print("shots: %d gait(s), %d mismatch(es)" % [GAITS.size(), shot_mismatches])
	if first_shot != "":
		print("  first: ", first_shot)

	# 2. The role table, over every model in `SUBSETS`.
	var role_mismatches := 0
	var first_role := ""
	var role_cases := 0
	for mask in SUBSETS:
		var has: Callable = Callable(self, "_has_role").bind(mask)
		for gait in GAITS:
			role_cases += 1
			var mine: String = Peers.role(gait, has)
			var wanted: String = String(oracle_role.get("%s %d" % [gait, mask], "?"))
			if mine != wanted:
				role_mismatches += 1
				if first_role == "":
					first_role = "gait '%s' with clips 0x%03x: scene %s, port %s" % [
						gait, mask, wanted, mine]
	print("roles: %d value(s) over %d gait(s) x %d model(s), %d mismatch(es)"
		% [role_cases, GAITS.size(), SUBSETS.size(), role_mismatches])
	if first_role != "":
		print("  first: ", first_role)

	# 3. The easing: a position, a yaw, and a phase that may or may not wrap.
	var step_mismatches := 0
	var first_step := ""
	for index in steps.size():
		var s: Array = steps[index]
		var k: float = minf(1.0, float(s[9]) * Peers.SMOOTH)
		var mine := PackedFloat64Array([
			Peers.step_axis(float(s[0]), float(s[4]), k),
			Peers.step_axis(float(s[1]), float(s[5]), k),
			Peers.step_yaw(float(s[2]), float(s[6]), k),
			Peers.step_phase(float(s[3]), float(s[7]), int(s[8]) == 1, k),
		])
		var wanted: PackedFloat64Array = oracle_step.get(index, PackedFloat64Array())
		if wanted.size() != 4:
			step_mismatches += 1
			if first_step == "":
				first_step = "row %d has no oracle" % index
			continue
		# The yaw is compared as an *angle*: the scene leaves it unwrapped and Godot's `wrapf`
		# is half-open, so the two part by a whole turn only at exactly +/-PI, where the two
		# rotations are the same rotation.
		var angles: Array[float] = [
			absf(mine[0] - wanted[0]),
			absf(mine[1] - wanted[1]),
			absf(wrapf(mine[2] - wanted[2], -PI, PI)),
			absf(mine[3] - wanted[3]),
		]
		for axis in angles.size():
			if angles[axis] > TOLERANCE:
				step_mismatches += 1
				if first_step == "":
					first_step = "row %d axis %d: scene %.17f, port %.17f" % [
						index, axis, wanted[axis], mine[axis]]
				break
	print("steps: %d row(s) x 4 axis/axes, %d mismatch(es)" % [steps.size(), step_mismatches])
	if first_step != "":
		print("  first: ", first_step)

	# 4. The two directions the wrap has to get right, asserted rather than left to the grid: a
	#    phase past half a lap goes *forward*, and a yaw past PI goes the short way. A forward
	#    move is measured modulo one lap, because 0.9 + 0.1 *is* 0.0.
	var forward: float = Peers.step_phase(0.9, 0.1, false, 0.5)
	var backward: float = Peers.step_phase(0.1, 0.9, false, 0.5)
	var short_way: float = Peers.step_yaw(3.0, -3.0, 1.0)
	var forward_step: float = fposmod(forward - 0.9, 1.0)
	var backward_step: float = fposmod(backward - 0.1, 1.0)
	var direction_ok: bool = absf(forward_step - 0.1) < TOLERANCE \
		and absf(backward_step - 0.9) < TOLERANCE \
		and absf(short_way - 3.283185307179586) < 1e-12
	print("wraps: 0.9 -> 0.1 moves +%.4f of a lap, 0.1 -> 0.9 moves -%.4f, yaw 3.0 -> -3.0 is %.4f"
		% [forward_step, 1.0 - backward_step, short_way])

	if shot_mismatches != 0:
		_failures.append("the one-shots are not the scene's: %d place(s)" % shot_mismatches)
	if role_mismatches != 0:
		_failures.append("the role table is not the scene's: %d of %d value(s)"
			% [role_mismatches, role_cases])
	if step_mismatches != 0:
		_failures.append("the easing is not the scene's: %d of %d value(s)"
			% [step_mismatches, steps.size() * 4])
	if not direction_ok:
		_failures.append("a wrap goes the long way round")

	# The live half needs a tree, and a `SceneTree` script sees one only from `_process`.
	_live = Peers.new()
	root.add_child(_live)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_live_first()
		return false
	if _frames == 2:
		_live_second()
		_report()
		return true
	return false

## The first snapshot a name ever sends *places* the goat, and a one-shot gait snaps its phase
## on arrival -- both are things `apply` does outright, with no frame in between.
func _live_first() -> void:
	_live.apply("alice", {
		"x": 5.0, "z": -2.0, "yaw": 3.0, "phase": 0.5, "gait": "walk",
	})
	var placed: Dictionary = _live.report_of("alice")
	if _live.count() != 1 or not _live.has("alice"):
		_failures.append("the first snapshot did not create a peer")
		return
	if absf(float(placed["x"]) - 5.0) > TOLERANCE or absf(float(placed["z"]) + 2.0) > TOLERANCE:
		_failures.append("the first snapshot eased instead of placing: %s" % placed["position"])
	if absf(float(placed["yaw"]) - 3.0) > TOLERANCE:
		_failures.append("the first snapshot did not place the yaw")
	if String(placed["clip"]) != "GoatWalk":
		_failures.append("a walking peer did not pose the walk clip: %s" % placed["clip"])
	print("placed: %s yaw %.4f, clip %s" % [placed["position"], float(placed["yaw"]),
		placed["clip"]])

	# ...and then a shot gait, a flung height and a target it has to ease toward. The target is
	# deliberately far, so the gap at the end of this frame is the whole distance to it.
	_live.apply("alice", {
		"x": 9.0, "z": 6.0, "yaw": -3.0, "phase": 0.8, "gait": "jump", "py": 1.5,
	})
	var shot: Dictionary = _live.report_of("alice")
	if absf(float(shot["phase"]) - 0.8) > TOLERANCE:
		_failures.append("a one-shot did not snap its phase: %.4f" % float(shot["phase"]))
	_staged["gap"] = _live.worst_gap()
	print("one-shot: phase %.4f, gap %.4f m to the next snapshot"
		% [float(shot["phase"]), float(_staged["gap"])])

## After a frame: the flung height is *applied* rather than eased, the gait has posed its clip,
## and the position has started to converge.
func _live_second() -> void:
	var after: Dictionary = _live.report_of("alice")
	var position: Vector3 = after["position"]
	# `_place` reads the *eased* pair, which is the client's own order, so the height is checked
	# against the drawn x/z rather than the target's. The claim is exact: a height that had been
	# smoothed would sit between the two snapshots', not on the target's plus the lift.
	var drawn_y: float = Terrain.height_at(position.x, position.z) + _live.ground_offset() + 1.5
	if absf(position.y - drawn_y) > 1e-5:
		_failures.append("the flung height was eased rather than applied: y %.4f, want %.4f"
			% [position.y, drawn_y])
	if String(after["clip"]) != "GoatJump":
		_failures.append("a jumping peer did not pose the jump clip: %s" % after["clip"])
	if absf(float(after["phase"]) - 0.8) > TOLERANCE:
		_failures.append("a one-shot's phase drifted: %.4f" % float(after["phase"]))
	var gap: float = _live.worst_gap()
	if gap > float(_staged["gap"]):
		_failures.append("the peer moved *away* from its snapshot: %.4f -> %.4f"
			% [float(_staged["gap"]), gap])
	print("held: y %.4f (py 1.5 applied), clip %s, phase %.4f, gap %.4f -> %.4f m"
		% [position.y, after["clip"], float(after["phase"]), float(_staged["gap"]), gap])

	# ...and a `left` is the one thing that removes a peer.
	_live.remove("alice")
	if _live.has("alice"):
		_failures.append("a peer that left was not removed")
	# The same name arriving again is a *new* goat, placed exactly.
	_live.apply("alice", {"x": 1.0, "z": 2.0, "yaw": 0.0, "phase": 0.0, "gait": "idle"})
	var again: Dictionary = _live.report_of("alice")
	if _live.count() != 1 or absf(float(again["x"]) - 1.0) > TOLERANCE:
		_failures.append("a peer that rejoined was not placed")
	# A removal of somebody who was never there is not an error.
	_live.remove("nobody")
	print("removal: left and rejoined -> %d goat(s) at x %.1f, an unknown name is quiet"
		% [_live.count(), float(again["x"])])
	_live.queue_free()

func _report() -> void:
	if _failures.is_empty():
		print("OK: the port's peers are the scene's, on the port's own mirror")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)

## Run one oracle script and hand back the lines it logged, `log ` included so the parsers read
## exactly what the engine wrote. A failure to evaluate is a failure of the gate, not a case: an
## oracle that did not run has answered nothing.
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

## The easing grid: a value and a target per axis, crossed with a one-shot and a looping gait and
## four frame times -- one of which is long enough that `k` saturates at 1. The pairs are chosen
## for the wraps: a yaw gap wider than PI (so the short way is the *other* way), a negative move
## on a position, and a phase gap past half a lap in both directions.
func _steps() -> Array:
	var spans := [[0.0, 1.0], [5.0, -8.0], [12.5, 0.25]]
	var turns := [[3.0, -3.0], [-3.0, 3.0], [0.0, 1.0], [1.0, PI + 0.5]]
	var phases := [[0.9, 0.1], [0.1, 0.9], [0.5, 0.5], [0.2, 0.8]]
	var deltas := [0.0, 0.05, 0.2, 0.5]
	var out: Array = []
	for span: Array in spans:
		for turn: Array in turns:
			for pair: Array in phases:
				for once in [0, 1]:
					for dt: float in deltas:
						out.append([span[0], turn[0], turn[0], pair[0],
							span[1], turn[1], turn[1], pair[1], once, dt])
	return out

## Whether the model in `SUBSETS`'s mask has a clip for a role.
func _has_role(role_name: String, mask: int) -> bool:
	var index: int = CLIPS.find(role_name)
	return index >= 0 and (mask & (1 << index)) != 0

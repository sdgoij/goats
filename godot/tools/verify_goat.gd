# The goat gate: `player_goat.gd` against `goat.js`.
#
#   Godot --headless --path godot --script res://tools/verify_goat.gd
#
# Two things are checked, and they are the two things a gait state machine can get
# wrong:
#
#   1. **The speeds.** `walkSpeed` is `stride / (duty * clipDuration)` (`model.js`
#      `gaitSpeed`), so a goat's speed is whatever makes its feet not slide. The
#      durations are read off the *loaded model* -- the same numbers `verify_model.gd`
#      pins -- and handed to the JavaScript, which then does the division. A
#      transcription that swapped the stride for the duty, or divided by the cycle
#      instead of the duty's share of it, would produce a confident wrong speed.
#
#   2. **The frame.** A scripted input tape is run through both sides one frame at a
#      time -- idle, walk, run, a turn, a jump mid-run, back to a trot, a sleep and a
#      wake, a walk backwards, long enough at a run to exhaust the goat and long
#      enough idle afterwards for it to fall asleep on its own -- and the position,
#      yaw, phase, mode, energy, health and speed are compared every frame -- and so is the
#      phase the *wire* carries (`net.js` `netPeerPhase`), which is the loop's own phase for a
#      gait and the fraction through the clip for a one-shot. `phase` is frozen for the whole of
#      a jump, so publishing it sent a stale number and a remote goat held one pose right
#      through it; the tape's mid-run jump is the frame that catches a regression.
#
# The tape is expanded here and handed to both sides as one literal, so they are
# reacting to one script rather than to two generators that happen to agree.
extends SceneTree

## `goat.js` / `model.js` / `core.js`, transcribed *from their sources*, with the
## clip durations injected from the model Godot loaded.
const JS := """
// The model's clips, by role, as *lists* -- because a cycled variant is a different
// length and that length is a rule: `cyclePlayerVariant` moves the jump from
// `GoatJump` (1.167 s) to `GoatJump2` (1.333 s), and `jumpDuration` reads whichever
// is current. The durations are Godot's, off the loaded model.
const CLIPS = __CLIPS__;
const variant = {};
for (const role in CLIPS) variant[role] = 0;
function hasRole(role) { const l = CLIPS[role]; return !!l && l.length > 0; }
function clipDuration(role) { const l = CLIPS[role]; return l ? l[variant[role] % l.length] : 0; }
function cycleVariant(role) { const l = CLIPS[role]; if (l) variant[role] = (variant[role] + 1) % l.length; }
const TUNING = {
    stats: { max: 100, energyDrain: { idle: 0.4, walk: 1.0, trot: 2.0, run: 4.0 },
             jumpEnergyCost: 2.0, sleepEnergyRecover: 12, sleepHealthRecover: 2,
             idleHealthRecover: 0.1, exhaustHealthDrain: 3, restedEnergy: 20,
             autoSleepDelay: 2.0 },
    movement: { turnRate: 1.8 },
    gait: { walk: { stride: 0.40, duty: 0.50 }, trot: { stride: 0.46, duty: 0.50 },
            run: { stride: 0.50, duty: 0.34 } },
    world: { nightDrainMult: 1.6 },
};
function gaitSpeed(role) {
    const gait = TUNING.gait[role];
    const dur = clipDuration(role);
    if (gait === undefined || !(dur > 0)) return null;
    return gait.stride / (gait.duty * dur);
}
function walkSpeed() { const s = gaitSpeed("walk"); return s || (2 * 0.20) / 0.70; }
function trotSpeed() { const s = gaitSpeed("trot"); return s || walkSpeed() * 1.8; }
function runSpeed() { const s = gaitSpeed("run"); return s || walkSpeed() * 3.5; }
console.log('S walk ' + walkSpeed());
console.log('S trot ' + trotSpeed());
console.log('S run ' + runSpeed());

// The goat's own state, `goat.js`'s module scope.
const goat = { px: 0, pz: 0, py: 0, yaw: 0, phase: 0 };
const stats = { health: TUNING.stats.max, energy: TUNING.stats.max };
let mode = "idle", exhausted = false, satiety = 0, lastMode = "idle";
let jumpTime = 0, jumpSpeed = 0, jumpDir = 0, eatTime = 0, idleTimer = 0, deathTime = 0;
const skyLight = 1.0;            // the tape is run in daylight
const weatherDrain = 1.0;        // ...and in the clear, so the weather is neutral
function mod1(v) { return ((v % 1) + 1) % 1; }
// `goat.js` `clipRole`, verbatim -- including its shape, which is "the role the
// mode names, if the model has it, and the *walk* for any role it does not". It is
// written out here from the source and not from the port on purpose: the first
// version of this oracle was copied from the port, they shared the same inverted
// test, and they agreed with each other while the port played the walk clip on an
// idle goat.
function clipRole() {
    if (mode === "dead" && hasRole("death")) return "death";
    if (mode === "sleep" && hasRole("sleep")) return "sleep";
    if (mode === "eat" && hasRole("eat")) return "eat";
    if (mode === "flung") return hasRole("flung") ? "flung" : "jump";
    if (mode === "jump" && hasRole("jump")) return "jump";
    if (mode === "run" && hasRole("run")) return "run";
    if (mode === "trot" && hasRole("trot")) return "trot";
    if (mode === "idle" && hasRole("idle")) return "idle";
    return "walk";
}
function loopDuration() { return clipDuration(clipRole()); }
function jumpDuration() { const d = clipDuration("jump"); return d > 0 ? d : 0.6; }
// `net.js` `netPeerPhase`: the phase the wire carries. A one-shot is posed from its own clock
// while `goat.phase` stands still, so the loop phase there is a stale number -- publishing it
// left a remote goat holding one frozen pose right through the jump, which is this tape's
// mid-run jump. The flung branch needs `flingProgress`, which this oracle does not model (the
// tape never flings); a meal and a death are the same `min(timer / duration, 1)` shape.
function netPeerPhase() {
    if (mode === "jump" && hasRole("jump")) return Math.min(jumpTime / jumpDuration(), 1);
    if (mode === "dead" && hasRole("death")) return Math.min(deathTime / clipDuration("death"), 1);
    if (mode === "eat" && hasRole("eat")) return Math.min(eatTime / clipDuration("eat"), 1);
    return goat.phase;
}
function groundSpeed() {
    if (mode === "sleep" || mode === "dead") return 0;
    let base = walkSpeed();
    if (mode === "run") base = runSpeed();
    else if (mode === "trot") base = trotSpeed();
    return base;
}
function startJump(move, gait) {
    mode = "jump"; cycleVariant("jump"); jumpTime = 0; jumpDir = move;
    jumpSpeed = gait === "run" ? runSpeed() : gait === "trot" ? trotSpeed() : walkSpeed();
    stats.energy = Math.max(0, stats.energy - TUNING.stats.jumpEnergyCost);
}
function startSleep() { mode = "sleep"; cycleVariant("sleep"); idleTimer = 0; }
function wake() { mode = "idle"; }
function updateStats(dt) {
    if (mode === "dead") { deathTime += dt; return "dead"; }
    if (mode === "sleep") {
        stats.energy = Math.min(TUNING.stats.max, stats.energy + TUNING.stats.sleepEnergyRecover * dt);
        stats.health = Math.min(TUNING.stats.max, stats.health + TUNING.stats.sleepHealthRecover * dt);
        return "sleep";
    }
    let drain = TUNING.stats.energyDrain.idle;
    if (mode === "run") drain = TUNING.stats.energyDrain.run;
    else if (mode === "trot") drain = TUNING.stats.energyDrain.trot;
    else if (mode === "walk") drain = TUNING.stats.energyDrain.walk;
    if (skyLight < 0.25) drain *= TUNING.world.nightDrainMult;
    drain *= weatherDrain;
    stats.energy = Math.max(0, stats.energy - drain * dt);
    if (stats.energy <= 0) {
        exhausted = true;
        stats.health = Math.max(0, stats.health - TUNING.stats.exhaustHealthDrain * dt);
    } else {
        exhausted = false;
        if (mode === "idle" && stats.energy > TUNING.stats.restedEnergy) {
            stats.health = Math.min(TUNING.stats.max, stats.health + TUNING.stats.idleHealthRecover * dt);
        }
    }
    return stats.health <= 0 ? "die" : "awake";
}
const TAPE = __TAPE__;
const DT = 1 / 60;
for (let i = 0; i < TAPE.length; i++) {
    const f = TAPE[i];
    const move = f[0], turn = f[1], wanted = f[2], jumping = f[3], sleeping = f[4];
    let gait = wanted;
    if (exhausted) gait = "walk";
    if (mode !== "sleep" && mode !== "dead" && mode !== "eat") {
        goat.yaw += turn * TUNING.movement.turnRate * DT;
    }
    if (mode === "sleep") {
        if (sleeping || move !== 0 || stats.energy >= TUNING.stats.max) wake();
    } else if (mode === "jump") {
        jumpTime += DT;
        if (jumpTime >= jumpDuration()) mode = move !== 0 ? gait : "idle";
    } else if (sleeping) {
        startSleep();
    } else if (jumping) {
        startJump(move, gait);
    } else {
        mode = move !== 0 ? gait : "idle";
        if (exhausted && move === 0) {
            idleTimer += DT;
            if (idleTimer >= TUNING.stats.autoSleepDelay) startSleep();
        } else {
            idleTimer = 0;
        }
    }
    satiety = Math.max(0, satiety - 0.02 * DT);
    if (updateStats(DT) === "die") { mode = "dead"; deathTime = 0; }
    if (mode !== lastMode) {
        if (mode === "idle") cycleVariant("idle");
        lastMode = mode;
    }
    const speed = groundSpeed();
    if (mode === "jump") {
        if (jumpDir !== 0) {
            goat.px += Math.cos(goat.yaw) * jumpDir * jumpSpeed * DT;
            goat.pz += -Math.sin(goat.yaw) * jumpDir * jumpSpeed * DT;
        }
    } else if (mode !== "sleep" && mode !== "dead" && mode !== "eat") {
        goat.phase = mod1(goat.phase + DT / loopDuration());
        if (move !== 0) {
            goat.px += Math.cos(goat.yaw) * move * speed * DT;
            goat.pz += -Math.sin(goat.yaw) * move * speed * DT;
        }
    }
    goat.py = 0;
    console.log('F ' + i + ' ' + mode + ' ' + clipRole() + ' ' + goat.px + ' ' + goat.pz + ' ' +
        goat.yaw + ' ' + goat.phase + ' ' + stats.energy + ' ' + stats.health + ' ' + speed +
        ' ' + (exhausted ? 1 : 0) + ' ' + netPeerPhase());
}
"""

## The input tape, as segments: frames, move, turn, gait, jump, sleep. `move` is -1
## for walking backwards and `turn` +1 turns left (`goat.js`'s A/D). There is no
## `eat` segment: a bite needs a meadow and a tuft in reach, and the frame says
## nothing about either -- `verify_meadow.gd` is the bite's own gate.
##
## It is built to cross every edge the machine has: each gait, a turn, a jump taken
## at a trot and carried through the clip's own end, a sleep and a wake, a reverse,
## and a run long enough that the goat runs its energy down and -- idle and exhausted
## -- drops itself into sleep (`TUNING.stats.autoSleepDelay`).
const TAPE := [
	[30, 0, 0, "walk", false, false],
	[60, 1, 0, "walk", false, false],
	[60, 1, 0, "run", false, false],
	[10, 1, 1, "run", false, false],
	[1, 1, 0, "trot", true, false],
	[80, 1, 0, "trot", false, false],
	[40, 0, 0, "walk", false, false],
	[1, 0, 0, "walk", false, true],
	[120, 0, 0, "walk", false, false],
	[1, 0, 0, "walk", false, true],
	[60, -1, 0, "walk", false, false],
	[1500, 1, 0, "run", false, false],
	[240, 0, 0, "walk", false, false],
]

## The frame step the tape is run at, matching `DT` in the oracle.
const DT := 1.0 / 60.0

## Positions accumulate ~2000 floating-point steps of `cos`/`sin`, and the two
## engines' libm are not the same libm, so an exact match is not the goal: the goal
## is that the same script produces the same goat. A nanometre after two thousand
## frames is four orders above one ULP and eleven below a millimetre.
const TOLERANCE := 1e-9

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	# The goat, up and standing, so its clips can be read off the model.
	var goat := PlayerGoat.new()
	root.add_child(goat)
	goat.ready_up()
	if goat.clip_length("walk") <= 0.0:
		print("FAIL: the goat has no walk clip - the model did not load")
		quit(1)
		return
	print("model clips: walk %.4f s, trot %.4f s, run %.4f s, jump %.4f s"
		% [goat.clip_length("walk"), goat.clip_length("trot"), goat.clip_length("run"),
			goat.clip_length("jump")])

	var tape: Array = []
	for segment: Array in TAPE:
		for i in int(segment[0]):
			tape.append([segment[1], segment[2], segment[3], segment[4], segment[5]])

	# The variant tables, off the loaded model: every role's clips and their lengths.
	var clips := {}
	for role: String in PlayerGoat.ROLES:
		clips[role] = goat.clip_durations(role)
	for role: String in PlayerGoat.ROLES:
		print("clips %s: %s" % [role, clips[role]])

	# The oracle: the same tape, the scene's own arithmetic, and the durations Godot
	# read off the model.
	var source: String = JS.replace("__CLIPS__", JSON.stringify(clips)) \
		.replace("__TAPE__", JSON.stringify(tape))
	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var speeds := {}
	var oracle := []
	for line in answers:
		if line.begins_with("log S "):
			var parts: PackedStringArray = line.split(" ")
			if parts.size() == 4:
				speeds[parts[2]] = float(parts[3])
		elif line.begins_with("log F "):
			oracle.append(line.substr(6))
	print("oracle answered ", speeds.size(), " speed(s), ", oracle.size(), " frame(s)")

	# 1. The speeds, from the model's own clip durations.
	var speed_failures: Array[String] = []
	for role: String in speeds:
		var wanted: float = speeds[role]
		var got: float = 0.0
		if role == "walk":
			got = goat.walk_speed()
		elif role == "trot":
			got = goat.trot_speed()
		else:
			got = goat.run_speed()
		print("%s speed: scene %.9f m/s, port %.9f m/s" % [role, wanted, got])
		if absf(got - wanted) > TOLERANCE:
			speed_failures.append("%s speed: the scene says %.9f and the port %.9f"
				% [role, wanted, got])
	if speeds.size() != 3:
		speed_failures.append("the oracle answered %d speed(s), expected 3" % speeds.size())

	# 2. The tape, frame by frame.
	var compared := 0
	var worst := 0.0
	var worst_at := ""
	var mode_mismatches := 0
	var first_mode_mismatch := ""
	var frames := 0
	var role_mismatches := 0
	var first_role_mismatch := ""
	var wire_compared := 0
	var wire_mismatches := 0
	var first_wire_mismatch := ""
	for segment: Array in TAPE:
		for i in int(segment[0]):
			var controls := {
				"move": int(segment[1]),
				"turn": int(segment[2]),
				"gait": String(segment[3]),
				"jump": bool(segment[4]),
				"sleep": bool(segment[5]),
				"restart": false,
			}
			goat.step(DT, controls, 1.0, {}, null)
			if frames >= oracle.size():
				frames += 1
				continue
			var parts: PackedStringArray = String(oracle[frames]).split(" ")
			if parts.size() != 12:
				frames += 1
				continue
			var wanted_mode: String = parts[1]
			var wanted_role: String = parts[2]
			var wanted: Array[float] = [
				float(parts[3]), float(parts[4]), float(parts[5]), float(parts[6]),
				float(parts[7]), float(parts[8]), float(parts[9]), float(parts[10]),
			]
			var got: Array[float] = [
				goat.px, goat.pz, goat.yaw, goat.phase,
				goat.energy, goat.health, goat.speed, 1.0 if goat.exhausted else 0.0,
			]
			if goat.mode != wanted_mode:
				mode_mismatches += 1
				if first_mode_mismatch == "":
					first_mode_mismatch = "frame %d: scene %s, port %s" % [
						frames, wanted_mode, goat.mode]
			# Which *clip* is playing, not only which mode: a goat that poses the walk
			# while it is standing still is a mode machine that is right and a pose that
			# is wrong, and the numbers on their own do not see it.
			if goat.clip_role() != wanted_role:
				role_mismatches += 1
				if first_role_mismatch == "":
					first_role_mismatch = "frame %d (mode %s): scene poses %s, port poses %s" % [
						frames, wanted_mode, wanted_role, goat.clip_role()]
			# ...and the phase the *wire* carries (`net.js` `netPeerPhase`): the loop's own phase
			# for a gait, and the fraction through the clip for a one-shot. `goat.phase` is frozen
			# for the whole of a jump, so publishing it told every other client to hold one pose
			# right through it -- which is what this checks, on the tape's own mid-run jump.
			var wanted_wire: float = float(parts[11])
			var got_wire: float = goat.one_shot_fraction()
			wire_compared += 1
			if absf(got_wire - wanted_wire) > TOLERANCE:
				wire_mismatches += 1
				if first_wire_mismatch == "":
					first_wire_mismatch = "frame %d (mode %s): scene %.6f, port %.6f" % [
						frames, wanted_mode, wanted_wire, got_wire]
			for k in got.size():
				var difference: float = absf(got[k] - wanted[k])
				compared += 1
				if difference > worst:
					worst = difference
					worst_at = "frame %d field %d (%s): scene %.17f, port %.17f" % [
						frames, k, wanted_mode, wanted[k], got[k]]
			frames += 1

	print("the tape ran %d frame(s); compared %d value(s)" % [frames, compared])
	print("largest disagreement: %.12f (tolerance %.12f)" % [worst, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)
	print("mode mismatches: ", mode_mismatches)
	if first_mode_mismatch != "":
		print("  first: ", first_mode_mismatch)
	print("clip-role mismatches: ", role_mismatches)
	if first_role_mismatch != "":
		print("  first: ", first_role_mismatch)
	print("wire-phase comparisons: %d, mismatches: %d" % [wire_compared, wire_mismatches])
	if first_wire_mismatch != "":
		print("  first: ", first_wire_mismatch)
	print("the port's goat ended as: %s at (%.3f, %.3f), energy %.2f, health %.2f"
		% [goat.mode, goat.px, goat.pz, goat.energy, goat.health])

	host.free()
	goat.free()

	failures.append_array(speed_failures)
	if frames != tape.size():
		failures.append("the tape ran %d frame(s), expected %d" % [frames, tape.size()])
	if compared != tape.size() * 8:
		failures.append("compared %d value(s), expected %d" % [compared, tape.size() * 8])
	if mode_mismatches != 0:
		failures.append("the state machine diverged %d time(s)" % mode_mismatches)
	if role_mismatches != 0:
		failures.append("the goat posed the wrong clip %d time(s)" % role_mismatches)
	if wire_compared != tape.size():
		failures.append("compared the wire phase %d time(s), expected %d"
			% [wire_compared, tape.size()])
	if wire_mismatches != 0:
		failures.append("the goat published the wrong phase %d time(s)" % wire_mismatches)
	if worst > TOLERANCE:
		failures.append("the goat disagrees with the scene by %f (limit %f)"
			% [worst, TOLERANCE])

	if failures.is_empty():
		print("OK: the local goat is the scene's goat, frame for frame")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

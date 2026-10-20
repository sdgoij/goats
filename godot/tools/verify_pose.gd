# The pose gate: how a fraction becomes a frame.
#
#   Godot --headless --path godot --script res://tools/verify_pose.gd
#
# Four modules pose a goat -- `PlayerGoat._pose`, `Bots._place`, `Peers._pose` and `Herd._pose` --
# and each of them is a transcription of one line of `model.js` `poseModelOn`:
#
#     let frame = phase * last;
#     if (frame > last) frame = last;
#
# which is a **clamp**: a phase of 1.0 is the clip's *last* frame. The port had a `fmod` there
# instead, and a wrap is not a clamp at the one value the two disagree about -- `fmod(1.0, 1.0)` is
# 0.0. A death reaches that phase a few seconds in, well before `herd.deathLinger` gets the body up,
# so every corpse in the port snapped back to the *first* frame of its death clip and stood upright
# there until its respawn. The loop's own far edge is the same line: a phase of exactly 1.0 is the
# scene's rounded 0.9996, which the reference poses at the clip's end rather than as a lap back to
# its beginning.
#
# A clamp alone is not enough in Godot, which this gate proved on its own first attempt: a player
# sought to *exactly* `Animation.length` is treated as finished and **stopped**, and a stopped player
# poses nothing -- the goat drops back to its rest pose, standing again, which is the same report by
# a second route. So the last frame is asked for a hair short of the end, and a case fails either way
# round: a goat still standing upright is either on the wrong frame or on no clip at all.
#
# Every gate that came before stopped at the *clip name* and the *phase* -- `verify_bots` compares a
# bot's mode, phase and clip frame for frame, `verify_peers` the gait and the clip `peerRole` picks
# -- so nothing in the suite held what the `AnimationPlayer` was actually seeking to, which is where
# the four transcriptions could drift from each other and from the scene. That is what this gate
# holds, and it asks all four modules rather than the one that was reported because the rule has
# four copies.
extends SceneTree

## The phases a loop is posed at, and what `poseModelOn` makes of each: the clamp is one-sided at
## the top, so 1.0 and beyond are the last frame while 0.0 and 0.5 are themselves. A negative phase
## never reaches either end -- the wire carries a clamped one-shot fraction or a loop phase in
## `[0, 1)` -- which is why the reference needs only the upper clamp; the port's `clampf` is
## two-sided and agrees with it at every phase either end can carry.
const LOOPS := [0.0, 0.5, 1.0, 1.25]
const LOOP_WANT := [0.0, 0.5, 1.0, 1.0]
## A pose's fraction is exact to within this. It is not zero because the port asks for the last
## frame a hair short of the clip's end (`Pose.HELD`: Godot *stops* a player sought to exactly its
## length, and a stopped player poses nothing), so a phase of 1.0 lands on 0.9999 of the clip -- the
## last frame by any measure, and nowhere near the 0.0 a wrap gives.
const TOLERANCE := 1e-3
## How a death is stepped before its pose is read: seconds a step, and how many steps that may
## take. The death clip is a second or two and `herd.deathLinger` is eight, so this lands a corpse in
## the window the report was about -- lying there with its clip long over and its respawn still to
## come.
const STEP := 0.25
const DEATH_STEPS := 28

var _frames := 0
var _goat: PlayerGoat
var _meadow: Meadow
var _failures: Array[String] = []

func _initialize() -> void:
	# The goat: the model's clips, and the body the other three orbit.
	_goat = PlayerGoat.new()
	root.add_child(_goat)
	_goat.ready_up()
	_meadow = Meadow.new()

func _process(_delta: float) -> bool:
	# `SceneTree.root` is not inside the tree while `_initialize` runs, so the nodes it built are
	# read a few frames later -- the trap `verify_console.gd` names. The model is loaded by then or
	# it is not, and a clip of zero says so.
	_frames += 1
	if _frames < 3:
		return false
	if _goat.clip_length("death") <= 0.0 or _goat.clip_length("walk") <= 0.0:
		print("FAIL: the model has no death or walk clip - the model did not load")
		quit(1)
		return true
	_check_herd()
	_check_peers()
	_check_bots()
	_check_player()
	_check_flight()
	_finish()
	return true

## `Herd`: the loop's own phases (the wrap's edge) and a corpse holding the frame it fell in.
func _check_herd() -> void:
	var herd: Herd = Herd.new()
	root.add_child(herd)
	for at in LOOPS.size():
		herd.apply(_world("walk", float(LOOPS[at])))
		_expect_pose(_anim_of(herd, 0), "the herd's `walk` at phase %s" % LOOPS[at],
			float(LOOP_WANT[at]), "GoatWalk")
	herd.apply(_world("dead", 1.0))
	_expect_pose(_anim_of(herd, 0), "the herd's `dead` at phase 1.0", 1.0, "GoatDeath")
	root.remove_child(herd)
	herd.free()

## `Peers`: a remote goat on each gait, posed at the fraction the wire carried. One node per case,
## because a peer's *later* snapshots are posed by the frame loop rather than by `apply` -- and this
## gate holds the pose `apply` lands, which is the one a name's first snapshot gets.
func _check_peers() -> void:
	_expect_peers("dead", "a peer's `dead` at phase 1.0", 1.0, "GoatDeath")
	_expect_peers("walk", "a peer's `walk` at phase 1.0", 1.0, "GoatWalk")

func _expect_peers(gait: String, what: String, want: float, clip: String) -> void:
	var peers: Peers = Peers.new()
	root.add_child(peers)
	peers.apply("alice", {
		"x": 2.0, "z": 3.0, "yaw": 0.0, "phase": 1.0, "gait": gait, "py": 0.0,
	})
	_expect_pose(_anim_of(peers, 0), what, want, clip)
	root.remove_child(peers)
	peers.free()

## `Bots`: the host's own herd, killed and left lying long past its death clip -- the case the report
## saw, and the one a respawn eventually ends.
func _check_bots() -> void:
	var bots: Bots = Bots.new()
	root.add_child(bots)
	bots.goat = _goat
	bots.meadow = _meadow
	bots.set_herd_size(2)
	if bots.count() != 2:
		_failures.append("the herd did not build: %d bot(s)" % bots.count())
		return
	bots.kill_at(0)
	var clip: float = _goat.clip_length("death")
	var first: Bots.Bot = (bots.get("_bots") as Array)[0]
	var stepped := 0
	while float(first.get("death_time")) < clip and stepped < DEATH_STEPS:
		bots.update(STEP, {})
		stepped += 1
	print("bot:    `dead` for %.2f s after %d step(s), clip is %.2f s"
		% [float(first.get("death_time")), stepped, clip])
	# The window the report was about: the clip is over, the body is still on the floor, and the
	# respawn has not come. `herd.deathLinger` is eight seconds, which `DEATH_STEPS` of `STEP` does
	# not reach -- so a bot that is not `dead` here is a respawn that came early.
	if String((bots.call("report") as Array)[0].get("mode", "")) != "dead":
		_failures.append("the bot was back on its feet before its respawn was due")
	elif float(first.get("death_time")) < clip:
		_failures.append("the bot's death clip had not finished in %.2f s" % (DEATH_STEPS * STEP))
	else:
		_expect_pose(_anim_of(bots, 0), "a killed bot lying past its death clip", 1.0, "GoatDeath")
	root.remove_child(bots)
	bots.free()

## `PlayerGoat`: this client's own goat, the fourth transcription and the one a player sees from
## behind.
func _check_player() -> void:
	var goat: PlayerGoat = PlayerGoat.new()
	root.add_child(goat)
	goat.ready_up()
	goat.die()
	var stepped := 0
	while goat.one_shot_fraction() < 1.0 and stepped < DEATH_STEPS:
		goat.step(STEP, {}, 1.0, {}, _meadow)
		stepped += 1
	print("goat:   `dead` fraction %.3f after %d step(s)" % [goat.one_shot_fraction(), stepped])
	if goat.one_shot_fraction() < 1.0:
		_failures.append("this client's goat never reached the end of its death clip")
	elif String(goat.get("mode")) != "dead":
		_failures.append("this client's goat got up without a respawn")
	else:
		_expect_pose(goat.get("_anim"), "this client's own goat, dead past its clip", 1.0,
			"GoatDeath")
	root.remove_child(goat)
	goat.free()

## One world for the mirror, in the shape `NetBridge` hands over: one bot, one gait, one phase.
func _world(gait: String, phase: float) -> Dictionary:
	return {"bots": [{
		"index": 0, "x": 3.0, "z": 4.0, "yaw": 0.0, "phase": phase, "gait": gait, "py": 0,
	}]}

## The `AnimationPlayer` a module's first goat is posed by. Goat nodes are added in the order the
## wire or the index names them, so the first is unambiguous -- and a module with one goat in it is
## what `_expect_peers` builds.
func _anim_of(host: Node, at: int) -> AnimationPlayer:
	if host.get_child_count() <= at:
		return null
	return _find_animation(host.get_child(at))

func _find_animation(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation(child)
		if found != null:
			return found
	return null

## Where a pose landed: the fraction through the clip the goat is actually on, against the fraction
## `poseModelOn` would have chosen -- the clamp above, and never a wrap. A goat that is on no clip at
## all is the other half of it: a player stopped at the end of its clip poses nothing, which is a
## rest pose, which for this model is standing up.
func _expect_pose(anim: AnimationPlayer, what: String, want: float, clip: String) -> void:
	if anim == null or String(anim.current_animation).is_empty():
		_failures.append("%s is posed by nothing (a stopped player is a rest pose)" % what)
		return
	if String(anim.current_animation) != clip:
		_failures.append("%s posed %s, not %s" % [what, anim.current_animation, clip])
		return
	var length: float = anim.get_animation(clip).length
	var got: float = anim.current_animation_position / length if length > 0.0 else 0.0
	print("%-38s %5.3f of %s (%.3f s of %.3f)" % [what, got, clip,
		anim.current_animation_position, length])
	if absf(got - want) > TOLERANCE:
		_failures.append("%s posed the fraction %.4f, not %.4f" % [what, got, want])

## The flight pose: `crates/flight`'s quaternion, and the rider's seat it implies.
##
## A flyer is not posed by an `AnimationPlayer` -- the body is rotated as a whole -- so the
## rule this gate holds for the other four modules is here a *basis*: yaw about +Y, pitch
## about +Z and roll about +X, in that order, against the composition the crate documents.
## And the seat, because a rotation about the hooves and a rotation about the shoulders
## agree at zero attitude and nowhere else: the drawn body sits at `feet + pivot`, and the
## rider is the same rotation applied to `(0, perch - pivot, 0)`.
func _check_flight() -> void:
	if not ClassDB.class_exists("Flight"):
		_failures.append("Flight is not registered - the GDExtension did not load")
		return
	var plane: Object = ClassDB.instantiate("Flight")
	plane.call("configure", PlayerGoat.flight_config())
	var state := PackedFloat32Array([
		2.0, 3.0, 7.0, PI / 2.0, PI / 4.0, PI / 6.0, 9.0, 0.0, 0.0, 0.0, 0.0, 1.0])
	var got: Quaternion = plane.call("pose", state)
	var want := Quaternion(Vector3.UP, PI / 2.0) * Quaternion(Vector3.BACK, PI / 4.0) \
		* Quaternion(Vector3.RIGHT, PI / 6.0)
	print("flight pose: %s (want %s)" % [got, want])
	var got_parts := {"x": got.x, "y": got.y, "z": got.z, "w": got.w}
	var want_parts := {"x": want.x, "y": want.y, "z": want.z, "w": want.w}
	for axis: String in ["x", "y", "z", "w"]:
		if absf(float(got_parts[axis]) - float(want_parts[axis])) > TOLERANCE:
			_failures.append("the flight pose's %s is %f, not %f"
				% [axis, got_parts[axis], want_parts[axis]])
			break

	# The seat: the crate's back point, and the drawn body's own transform applied to the
	# same local offset. `state` is `[x, z, y, ...]`, so the feet are (2, 7, 3).
	var seat: Vector3 = plane.call("back_point", state, 1.15, PlayerGoat.FLIGHT_PIVOT)
	var body := Transform3D(Basis(got), Vector3(2.0, 7.0 + PlayerGoat.FLIGHT_PIVOT, 3.0))
	var drawn: Vector3 = body * Vector3(0.0, 1.15 - PlayerGoat.FLIGHT_PIVOT, 0.0)
	print("rider seat: %s (the crate says %s)" % [drawn, seat])
	if drawn.distance_to(seat) > 1e-3:
		_failures.append("the drawn seat %s is not the crate's back point %s" % [drawn, seat])

func _finish() -> void:
	if _failures.is_empty():
		print("OK: a fraction poses the clip's last frame at its end, and is never wrapped to its first")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)

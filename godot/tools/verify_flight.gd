# The flight gate: `crates/flight` behind its Godot class, and the goat's half of it.
#
#   Godot --headless --path godot --script res://tools/verify_flight.gd
#
# The mechanics are not transcribed twice. They are one Rust crate shared with the raylib
# client, reached here through the `Flight` class (`crates/godot/src/flight.rs`) and there
# through the `__flight` global (`crates/flight-js`). So this gate has two jobs, and the
# split is the point:
#
#   1. **The binding.** The positional arrays round-trip, the ground `Callable` is used, and
#      the pose and the rider's back point come back in Godot's own `Quaternion`/`Vector3`.
#      A conversion that dropped a field or transposed `x`/`z` would be invisible to the
#      crate's own tests, which never cross this boundary.
#
#   2. **The integration.** `PlayerGoat` owns the state and the rules around it: a running
#      jump with the capability takes off, W/S/A/D/Space/E mean what `FLIGHT.md` §2 says,
#      the energy and the fall damage are applied, a landing keeps the bird and a restart
#      clears it.
#
# The flight numbers are the crate's defaults, in `PlayerGoat.FLIGHT`. The cases assert
# *signs, consequences and order*, not the tuning values -- `FLIGHT.md` §9's rule.
extends SceneTree

## The frame step, the same fixed step the game uses.
const DT := 1.0 / 60.0

## How close a floating-point comparison has to be. Positions accumulate a few hundred
## steps of `sin`/`cos`, and the two engines' libm are not the same libm.
const TOLERANCE := 1e-4

var _goat: PlayerGoat
var _flight: Flight
var _failures: Array[String] = []

func _initialize() -> void:
	if not ClassDB.class_exists("Flight"):
		print("FAIL: Flight is not registered - the GDExtension did not load")
		quit(1)
		return
	_flight = ClassDB.instantiate("Flight")
	if _flight == null:
		print("FAIL: ClassDB could not instantiate Flight")
		quit(1)
		return
	# The goat: the model's clips and the node whose `_place` the pose case reads.
	_goat = PlayerGoat.new()
	root.add_child(_goat)
	_goat.ready_up()
	_goat.flight = _flight
	_flight.configure(PlayerGoat.flight_config())
	_check_binding()
	_check_tuning()
	_check_take_off()
	_check_controls()
	_check_release()
	_check_landing()
	_check_restart()
	_finish()

# ---- 1. the binding -------------------------------------------------------

func _check_binding() -> void:
	var ground_y := 3.0
	# A grounded state with the model's own rest height is not stepped at all: the crate
	# only ever moves a flyer, which is what the client's mode machine guarantees.
	var grounded := PackedFloat32Array([
		1.0, 2.0, 3.0, 0.4, 0.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var idle: PackedFloat32Array = _flight.step(grounded,
		PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 100.0]), DT, func(_x: float, _z: float): return ground_y)
	_expect_size(idle, 20, "a step answer")
	# The array layout is the contract both clients share: the state comes back in place.
	_expect_near(idle[0], 1.0, "a step keeps grounded x")
	_expect_near(idle[2], 3.0, "a step keeps grounded y")

	# Take-off: the state is Fly, the lift is the crate's, and the cost is at index 12.
	var started: PackedFloat32Array = _flight.start(grounded, 9.0)
	_expect_size(started, 13, "a start answer")
	_expect_near(started[11], 1.0, "a start is phase 1 (fly)")
	_expect_near(started[7], PlayerGoat.FLIGHT["takeoffLift"], "a start sets the take-off lift")
	_expect_near(started[12], PlayerGoat.FLIGHT["takeoffEnergy"], "a start carries its cost")

	# The ground callback: a fall from 1 m over ground at 5 m must land this frame, and the
	# impact and the damage come back as numbers the caller applies.
	var low := PackedFloat32Array([0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, -4.0, 0.0, 0.0, 0.0, 2.0])
	var landed: PackedFloat32Array = _flight.step(low,
		PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 100.0]), DT,
		func(_x: float, _z: float): return 5.0)
	_expect_size(landed, 20, "a landing answer")
	if landed[17] == 0.0:
		_failures.append("the ground callback was not used: a fall through the floor did not land")
	else:
		_expect_near(float(landed[18]), 4.0 + 32.0 / 60.0,
			"the landing impact is the downward speed after the frame's gravity")
		_expect_near(float(landed[19]), 0.0, "a 4.5 m/s impact is under safeFall")

	# The pose: yaw about +Y maps the model's forward (+X) to -Z, exactly as the raylib
	# side's axis-angle does. The quaternion is the neutral form both bindings derive from.
	var yawed := PackedFloat32Array([0.0, 0.0, 0.0, PI / 2.0, 0.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0, 1.0])
	var forward: Vector3 = _flight.pose(yawed) * Vector3(1.0, 0.0, 0.0)
	_expect_near(forward.x, 0.0, "a quarter yaw keeps x at 0")
	if forward.z > -0.999:
		_failures.append("a quarter yaw turned forward to %s, not -Z" % forward)

	# The rider's back point: at rest it is the feet plus the perch, and at a nose-up
	# quarter turn it swings forward about the pivot.
	var at_rest := _flight.back_point(grounded, 1.15, PlayerGoat.FLIGHT_PIVOT)
	_expect_near(at_rest.y, 3.0 + 1.15, "the rest back point is the perch above the feet")
	var pitched := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, PI / 2.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0, 1.0])
	var swung := _flight.back_point(pitched, 1.15, PlayerGoat.FLIGHT_PIVOT)
	_expect_near(swung.x, -0.45, "a nose-up pivot swings the rider forward")
	_expect_near(swung.y, PlayerGoat.FLIGHT_PIVOT, "a nose-up pivot keeps the rider at the pivot")

	# The damage formula and its floor are the crate's, so the goat cannot disagree.
	_expect_near(_flight.fall_damage(12.0), 0.0, "safeFall is free")
	_expect_near(_flight.fall_damage(22.0), 22.0, "damage is (impact - safeFall) * fallDamage")
	_expect_near(_flight.apply_fall_damage(10.0, 50.0), 0.0, "a lethal fall floors at 0")
	_expect_near(_flight.apply_fall_damage(100.0, 22.0), 78.0, "a fall takes its damage off health")

# ---- the tuning tree ------------------------------------------------------

## A write to a `flight.*` leaf lands in `PlayerGoat.FLIGHT`, which is what
## `flight_config` reads and what `configure` takes: the two ends of a tuning write.
func _check_tuning() -> void:
	var answer: Dictionary = Tuning.write("flight.takeoffLift", 7.0)
	if answer.has("err"):
		_failures.append("a flight tuning write was refused: %s" % answer["err"])
		return
	_expect_near(float(PlayerGoat.FLIGHT["takeoffLift"]), 7.0, "a tuning write reaches FLIGHT")
	_flight.configure(PlayerGoat.flight_config())
	var state := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var started: PackedFloat32Array = _flight.start(state, 9.0)
	_expect_near(started[7], 7.0, "a reconfigured start uses the written lift")
	# Back to the crate's default, so the rest of the gate is the shipped tuning.
	Tuning.write("flight.takeoffLift", 5.0)
	_flight.configure(PlayerGoat.flight_config())

# ---- 2. the integration ---------------------------------------------------

## Reset the goat to a known frame: on the ground, full, not flying.
func _reset() -> void:
	_goat.restart()
	_goat.flight = _flight

## One frame of the goat with the keys this case wants.
func _step(move: int = 0, turn: int = 0, gait: String = "walk", jump: bool = false,
		eat: bool = false) -> void:
	_goat.step(DT, {"move": move, "turn": turn, "gait": gait, "jump": jump, "eat": eat,
		"sleep": false, "restart": false}, 1.0, {}, null)

## `goat.js`'s take-off rule: the capability, and a *running* jump. A standing or walking
## jump is a jump, and the bird stays aboard.
func _check_take_off() -> void:
	_reset()
	_goat.set_flight(false)
	_step(1, 0, "run", true)
	if _goat.mode == "fly":
		_failures.append("a running jump took off with no captured bird")
	_reset()
	_goat.set_flight(true)
	_step(0, 0, "walk", true)
	if _goat.mode == "fly":
		_failures.append("a standing jump took off")
	_reset()
	_goat.set_flight(true)
	_step(1, 0, "walk", true)
	if _goat.mode == "fly":
		_failures.append("a walking jump took off")
	elif not _goat.flight_capable:
		_failures.append("a walking jump spent the captured bird")
	# The take-off itself: immediate, with the crate's energy cost paid up front.
	_reset()
	_goat.set_flight(true)
	var energy: float = _goat.energy
	_step(1, 0, "run", true)
	if _goat.mode != "fly":
		_failures.append("a running jump with a captured bird stayed %s, not fly" % _goat.mode)
		return
	print("take-off: mode %s, energy %.2f -> %.2f, py %.3f"
		% [_goat.mode, energy, _goat.energy, _goat.py])
	if energy - _goat.energy < 1.5:
		_failures.append("the take-off cost %.2f energy, not the take-off's"
			% (energy - _goat.energy))
	for i in 12:
		_step()
	if _goat.py <= 0.3:
		_failures.append("the goat did not climb off the ground: py %.3f" % _goat.py)
	if not _goat.airborne():
		_failures.append("a flying goat does not report airborne")

## W/S pitch, A/D bank, Space flaps and the cooldown, E releases.
func _check_controls() -> void:
	_reset()
	_goat.set_flight(true)
	if not _goat.fly():
		_failures.append("fly() did not start a flight")
		return
	# Room to dive, after the take-off's own upward impulse has had a few frames to
	# decay -- W has to out-climb it before the height tells the sign.
	for i in 10:
		_step()
	_goat.py = 24.0
	_step()
	var high: float = _goat.py

	# W noses down...
	for i in 50:
		_step(1)
	print("W: pitch %.3f, py %.2f -> %.2f" % [_goat.flight_pitch, high, _goat.py])
	if _goat.flight_pitch > -0.3:
		_failures.append("W did not nose down: pitch %.3f" % _goat.flight_pitch)
	var low: float = _goat.py
	if low > high - 0.3:
		_failures.append("W lost no height: %.2f -> %.2f" % [high, low])

	# ...S noses up. Two seconds: the pitch has to come from the dive's clamp to the
	# climb's, and the vertical speed follows it a beat later.
	for i in 120:
		_step(-1)
	print("S: pitch %.3f, py %.2f -> %.2f" % [_goat.flight_pitch, low, _goat.py])
	if _goat.flight_pitch < 0.3:
		_failures.append("S did not nose up: pitch %.3f" % _goat.flight_pitch)
	if _goat.py < low + 0.5:
		_failures.append("S gained no height: %.2f -> %.2f" % [low, _goat.py])

	# A banks left and raises the yaw; D does the opposite.
	var yaw: float = _goat.yaw
	for i in 40:
		_step(0, 1)
	print("A: roll %.3f, yaw %.3f -> %.3f" % [_goat.flight_roll, yaw, _goat.yaw])
	if _goat.flight_roll > -0.2:
		_failures.append("A did not bank left: roll %.3f" % _goat.flight_roll)
	var left: float = _goat.yaw
	if left < yaw + 0.1:
		_failures.append("A did not raise the yaw: %.3f -> %.3f" % [yaw, left])
	for i in 60:
		_step(0, -1)
	print("D: roll %.3f, yaw %.3f -> %.3f" % [_goat.flight_roll, left, _goat.yaw])
	if _goat.flight_roll < 0.2:
		_failures.append("D did not bank right: roll %.3f" % _goat.flight_roll)
	if _goat.yaw > left:
		_failures.append("D did not lower the yaw: %.3f -> %.3f" % [left, _goat.yaw])

	# While it is still flying, the draw is the crate's pose: the seat where `back_point`
	# says, which is the pivot correction and not a second rotation.
	_check_pose_placement()

	# Space flaps: height, count, cost, and a cooldown that refuses the next one.
	for i in 30:
		_step()
	var flaps: int = _goat.flight_flaps
	var energy: float = _goat.energy
	var height: float = _goat.py
	_step(0, 0, "walk", true)
	_step()
	print("flap: %d -> %d, py %.2f -> %.2f, energy %.2f -> %.2f"
		% [flaps, _goat.flight_flaps, height, _goat.py, energy, _goat.energy])
	if _goat.flight_flaps != flaps + 1:
		_failures.append("a flap did not count: %d -> %d" % [flaps, _goat.flight_flaps])
	if _goat.py <= height + 0.05:
		_failures.append("a flap did not lift the goat: %.2f -> %.2f" % [height, _goat.py])
	if _goat.energy > energy - 1.0:
		_failures.append("a flap cost %.2f energy" % (energy - _goat.energy))
	_step(0, 0, "walk", true)
	_step()
	if _goat.flight_flaps != flaps + 1:
		_failures.append("the flap cooldown did not refuse a second flap")
	for i in 28:
		_step()
	_step(0, 0, "walk", true)
	_step()
	if _goat.flight_flaps != flaps + 2:
		_failures.append("the next flap after the cooldown did not count")

	# The drain, and a flap the goat cannot pay for.
	var before: float = _goat.energy
	for i in 60:
		_step()
	print("drain: energy %.2f -> %.2f over 1 s" % [before, _goat.energy])
	if before - _goat.energy < 2.0:
		_failures.append("flying drained %.2f energy in a second" % (before - _goat.energy))
	_goat.energy = 0.0
	for i in 30:
		_step()
	var spent: int = _goat.flight_flaps
	_step(0, 0, "walk", true)
	_step()
	if _goat.flight_flaps != spent:
		_failures.append("a goat with no energy flapped anyway")

## E leaves the flight into a free fall. A low one is free, a long one hurts, and a lethal
## one becomes a death only when the feet touch.
func _check_release() -> void:
	_reset()
	_goat.set_flight(true)
	if not _goat.fly():
		_failures.append("fly() did not start the low release's flight")
		return
	for i in 6:
		_step()
	var health: float = _goat.health
	_step(0, 0, "walk", false, true)   # E
	if _goat.mode != "fall":
		_failures.append("E left the goat in %s, not fall" % _goat.mode)
	if _goat.flight_capable:
		_failures.append("a release kept the captured bird")
	for i in 120:
		_step()
	if _goat.mode == "fall" or _goat.mode == "dead":
		_failures.append("a short fall ended as %s" % _goat.mode)
	if absf(_goat.health - health) > TOLERANCE:
		_failures.append("a short fall cost %.2f health" % (health - _goat.health))

	# A long release, from 40 m: the damage is the landing's, never a per-frame drain.
	_reset()
	_goat.set_flight(true)
	_goat.fly()
	for i in 4:
		_step()
	_goat.py = 40.0
	health = _goat.health
	_goat.release()
	for i in 30:
		_step()
	if _goat.mode != "fall":
		_failures.append("a long release was not falling after half a second: %s" % _goat.mode)
	if absf(_goat.health - health) > TOLERANCE:
		_failures.append("a long fall hurt before it landed")
	for i in 300:
		if _goat.mode != "fall":
			break
		_step()
	print("long fall: health %.2f -> %.2f, mode %s" % [health, _goat.health, _goat.mode])
	if _goat.mode == "fall":
		_failures.append("a fall from 40 m never landed")
	if health - _goat.health < 10.0:
		_failures.append("a fall from 40 m cost %.2f health" % (health - _goat.health))

	# A lethal fall: health runs out on contact and not in the air.
	_reset()
	_goat.set_flight(true)
	_goat.fly()
	for i in 4:
		_step()
	_goat.py = 40.0
	_goat.health = 1.0
	_goat.release()
	for i in 30:
		_step()
	if _goat.mode != "fall":
		_failures.append("a lethal fall died in the air: mode %s" % _goat.mode)
	for i in 300:
		if _goat.mode != "fall":
			break
		_step()
	if _goat.mode != "dead":
		_failures.append("a lethal fall landed as %s, not dead" % _goat.mode)

## A flight that meets the ground keeps the bird: the next run + jump takes off again.
func _check_landing() -> void:
	_reset()
	_goat.set_flight(true)
	if not _goat.fly():
		_failures.append("fly() did not start the landing's flight")
		return
	# Nose down into the ground; no release, so the capability is untouched.
	var frames := 0
	while _goat.mode == "fly" and frames < 240:
		_step(1)
		frames += 1
	print("landing: %s after %d frame(s), capability %s"
		% [_goat.mode, frames, _goat.flight_capable])
	if _goat.mode == "fly":
		_failures.append("a dive never landed")
	if not _goat.flight_capable:
		_failures.append("a landing took the captured bird")
	# The pose on the ground is the level one again: no leftover pitch or roll.
	if absf(_goat.flight_pitch) > TOLERANCE or absf(_goat.flight_roll) > TOLERANCE:
		_failures.append("a landing left the goat at pitch %.3f / roll %.3f"
			% [_goat.flight_pitch, _goat.flight_roll])

## The model really is drawn from the crate's pose: the node sits at the pivot and the
## rider's seat is where `back_point` says it is.
func _check_pose_placement() -> void:
	if _goat.mode != "fly" and _goat.mode != "fall":
		return
	var state := PackedFloat32Array([
		_goat.px, _goat.pz, Terrain.height_at(_goat.px, _goat.pz) + _goat.py,
		_goat.yaw, _goat.flight_pitch, _goat.flight_roll, _goat.speed, 0.0, 0.0,
		float(_goat.flight_flaps), 0.0, 1.0])
	var seat: Vector3 = _flight.back_point(state, 1.15, PlayerGoat.FLIGHT_PIVOT)
	# The goat is a direct child of `root`, which is at the origin, and it is not in the tree
	# yet while `_initialize` runs -- so its own transform is the global one.
	var drawn: Vector3 = _goat.transform * Vector3(0.0, 1.15 - PlayerGoat.FLIGHT_PIVOT, 0.0)
	if seat.distance_to(drawn) > 1e-3:
		_failures.append("the drawn seat %s is not the crate's back point %s" % [drawn, seat])

## `restart` is a new life: no bird, and the flight numbers at rest.
func _check_restart() -> void:
	_reset()
	_goat.set_flight(true)
	_goat.fly()
	for i in 20:
		_step()
	_goat.restart()
	if _goat.flight_capable:
		_failures.append("restart kept the captured bird")
	if _goat.mode != "idle":
		_failures.append("restart left the goat in %s" % _goat.mode)
	if absf(_goat.flight_pitch) > TOLERANCE or absf(_goat.flight_roll) > TOLERANCE:
		_failures.append("restart left an attitude behind")

func _expect_size(values: PackedFloat32Array, size: int, what: String) -> void:
	if values.size() != size:
		_failures.append("%s has %d values, not %d" % [what, values.size(), size])

func _expect_near(got: float, want: float, what: String) -> void:
	if absf(got - want) > TOLERANCE:
		_failures.append("%s: got %.6f, expected %.6f" % [what, got, want])

func _finish() -> void:
	if _failures.is_empty():
		print("OK: the crate flies, and the goat is its client")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)

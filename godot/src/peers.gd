# The other players: one goat per peer the server is relaying.
#
# `Herd` mirrors the host's *bots*; this mirrors the host's *people*. They are two modules
# rather than one because they are two rules: a bot is addressed by index and its coat comes
# from a spec table both ends already have, while a peer is addressed by name, carries a gait
# the owner chose, and is buffered by a different set of easing rules. `net.js` keeps them in
# two arrays for the same reason.
#
# What is transcribed here is `net.js`'s peer half, and it is three rules plus a table:
#
#   * **a snapshot is a target, not a teleport** -- the render position eases toward it at a
#     fixed fraction per frame (`k = min(1, dt * NET_PEER_SMOOTH)`), so 10-20 Hz reads as
#     movement, and a lost snapshot costs nothing;
#   * **`yaw` takes the short way round**, so a goat crossing the +/-PI seam does not spin the
#     long way;
#   * **a one-shot gait is not eased at all.** A jump, a death, a meal and a fling are posed
#     straight from the snapshot's phase: the two phase spaces are not shared (a jump ends at
#     1, the loop it interrupts resumes wherever it was), so entering one and leaving it again
#     both *snap*. Easing a loop's phase also has to wrap -- `0.9 -> 0.1` is a tenth of a lap
#     forward, not nine tenths back -- and a shot would read that as a new leap.
#   * and the **flung height is applied directly**, never eased: the arc's shape is the owner's
#     simulation, and a smoothed copy of a parabola is a different, lower trajectory.
#
# Peers are **not** wake actors. `water.js` `waterActorStep` walks the local goat and `BOTS`
# and stops there, so a remote player does not throw rings -- which is why nothing here
# reports an actor the way `Herd.actors` does.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Peers
extends Node3D

## The goat, complete with its rig and clips -- the same model the player's and the herd's are.
const GOAT_SCENE := preload("res://assets/goat_animated.glb")

## How fast a peer converges on its snapshot, per second: the client's `NET_PEER_SMOOTH`.
const SMOOTH := 12.0

## The gaits `netPeerShot` calls one-shots. A gait on this list is posed at the fraction the
## snapshot carried and nothing else; everything off it loops and is wrapped. `fall` is one:
## a released goat's pose is its progress down, and `fly` is a loop (`FLIGHT.md` §6.2).
const SHOTS := ["jump", "dead", "eat", "flung", "fall"]

## The flight controller (`crates/flight`), handed in by `main.gd` for a mirrored flyer's
## pose -- the same instance the player's and the herd's use. Null in a gate that made none,
## and a flyer is then drawn level, which is the guard `Herd` has for the same reason.
var flight: Flight = null

var _goats := {}
## The client's `groundOffset` (`model.js` `loadGoat`), measured once off the first goat so a
## re-exported model cannot sink. Shared in spirit with `Herd`'s; measured here because these
## are different nodes and neither module owns the other.
var _ground_offset := 0.0
var _ground_measured := false

## Whether a gait plays once from its own clock rather than looping: `net.js` `netPeerShot`.
static func shot(gait: String) -> bool:
	return SHOTS.has(gait)

## The role a peer's gait plays, given whether the model has a clip for a role. `has_clip` is a
## `Callable(role) -> bool` rather than a table because the *fallback chain* is the rule:
## `flung` falls to `jump`, and every other miss falls to `walk` -- which is not the herd's
## table, and is why this is transcribed rather than shared with `Herd._clip_for`.
static func role(gait: String, has_clip: Callable) -> String:
	if gait == "dead" and bool(has_clip.call("death")):
		return "death"
	if gait == "sleep" and bool(has_clip.call("sleep")):
		return "sleep"
	if gait == "eat" and bool(has_clip.call("eat")):
		return "eat"
	if gait == "flung":
		return "flung" if bool(has_clip.call("flung")) else "jump"
	if gait == "fly":
		return "fly" if bool(has_clip.call("fly")) else "jump"
	if gait == "fall":
		return "fall" if bool(has_clip.call("fall")) else "jump"
	if gait == "jump" and bool(has_clip.call("jump")):
		return "jump"
	if gait == "run" and bool(has_clip.call("run")):
		return "run"
	if gait == "trot" and bool(has_clip.call("trot")):
		return "trot"
	if gait == "walk" and bool(has_clip.call("walk")):
		return "walk"
	if bool(has_clip.call("idle")):
		return "idle"
	return "walk"

## One frame of a *position* axis: a fixed fraction of the remaining gap. `updatePeers`'s own
## line, factored out so the gate can hold it without a live session.
static func step_axis(value: float, target: float, k: float) -> float:
	return value + (target - value) * k

## One frame of `yaw`, the short way round: the same ease, but the gap is first wrapped into
## +/-PI so a goat crossing the seam turns the way a person would.
static func step_yaw(yaw: float, target: float, k: float) -> float:
	return yaw + wrapf(target - yaw, -PI, PI) * k

## One frame of the phase. A one-shot takes its target outright -- there is nothing to ease
## toward. A loop eases, and its gap is wrapped into +/-0.5 so `0.9 -> 0.1` is a tenth of a lap
## forward rather than nine tenths back.
static func step_phase(phase: float, target: float, once: bool, k: float) -> float:
	if once:
		return target
	var gap: float = target - phase
	if gap > 0.5:
		gap -= 1.0
	elif gap < -0.5:
		gap += 1.0
	return fposmod(phase + gap * k, 1.0)

## Take a peer's snapshot: `net.js` `netPeerState`. `snapshot` is the wire's `PeerState` as the
## bridge hands it over -- `x`, `z`, `yaw`, `phase`, `gait` and `py`. Returns whether there
## was a goat to place, so a caller can tell "a new peer arrived" from "one moved".
##
## The first snapshot a name ever sends **places** the goat rather than starting it at the
## origin, which is the client's own rule and the reason a joiner does not see everybody slide
## in from the middle of the map.
func apply(peer_name: String, snapshot: Variant) -> bool:
	if peer_name.is_empty() or not (snapshot is Dictionary):
		return false
	var wire: Dictionary = snapshot
	if not wire.has("x"):
		return false
	var x: float = float(wire.get("x", 0.0))
	var z: float = float(wire.get("z", 0.0))
	var yaw: float = float(wire.get("yaw", 0.0))
	var phase: float = float(wire.get("phase", 0.0))
	var gait: String = String(wire.get("gait", "idle"))
	# The flight attitude (protocol 12), in degrees on the wire and radians here -- eased like
	# the yaw, because an angle is a look and not a trajectory.
	var tpitch: float = deg_to_rad(float(wire.get("pitch", 0.0)))
	var troll: float = deg_to_rad(float(wire.get("roll", 0.0)))
	# `netPeerHeight`: absent, or a goat that has never been airborne, is zero.
	var lift: float = maxf(float(wire.get("py", 0.0)), 0.0)
	var once: bool = shot(gait)

	if not _goats.has(peer_name):
		var fresh: Dictionary = _goat_for(peer_name)
		fresh["x"] = x
		fresh["z"] = z
		fresh["yaw"] = yaw
		fresh["phase"] = phase
		fresh["tx"] = x
		fresh["tz"] = z
		fresh["tyaw"] = yaw
		fresh["tphase"] = phase
		fresh["py"] = lift
		fresh["gait"] = gait
		fresh["shot"] = once
		fresh["pitch"] = tpitch
		fresh["roll"] = troll
		fresh["tpitch"] = tpitch
		fresh["troll"] = troll
		_place(fresh)
		return true

	var goat: Dictionary = _goats[peer_name]
	# A one-shot is stepped straight from the snapshot rather than eased into, and *entering*
	# or *leaving* one snaps too -- hence the test against the previous gait and not only the
	# new one.
	if once or once != bool(goat["shot"]):
		goat["phase"] = phase
	goat["shot"] = once
	goat["tx"] = x
	goat["tz"] = z
	goat["tyaw"] = yaw
	goat["tphase"] = phase
	goat["py"] = lift
	goat["gait"] = gait
	goat["tpitch"] = tpitch
	goat["troll"] = troll
	return true

## A peer left the session (`net.js` `netPeerRemove`). Leaving is the only thing that removes
## one: a snapshot that stops arriving leaves a goat standing, which is also what the client
## does, and is better than a herd that blinks.
func remove(peer_name: String) -> void:
	if not _goats.has(peer_name):
		return
	(_goats[peer_name]["node"] as Node3D).queue_free()
	_goats.erase(peer_name)

func _process(delta: float) -> void:
	if _goats.is_empty():
		return
	var k: float = minf(1.0, delta * SMOOTH)
	for goat: Dictionary in _goats.values():
		goat["x"] = step_axis(float(goat["x"]), float(goat["tx"]), k)
		goat["z"] = step_axis(float(goat["z"]), float(goat["tz"]), k)
		goat["yaw"] = step_yaw(float(goat["yaw"]), float(goat["tyaw"]), k)
		goat["phase"] = step_phase(float(goat["phase"]), float(goat["tphase"]),
			bool(goat["shot"]), k)
		goat["pitch"] = step_axis(float(goat["pitch"]), float(goat["tpitch"]), k)
		goat["roll"] = step_axis(float(goat["roll"]), float(goat["troll"]), k)
		_place(goat)

## How many peers are being mirrored.
func count() -> int:
	return _goats.size()

## The peers as a *world mod* reads them (`goats.peers.list`, `APIv1.md` section 4.21): the
## mirror's own numbers, in arrival order, with `y` the height above the ground under the goat
## and `mode` the wire's gait. A solo game has none; a client's own goat is not one of these.
func state() -> Array:
	var out: Array = []
	for peer_name in _goats:
		var goat: Dictionary = _goats[peer_name]
		out.append({
			"name": String(peer_name),
			"x": float(goat["x"]),
			"z": float(goat["z"]),
			"yaw": float(goat["yaw"]),
			"mode": String(goat["gait"]),
			"y": float(goat["py"]),
			"pitch": float(goat["pitch"]),
			"roll": float(goat["roll"]),
		})
	return out

## The model's own lowest point, negated: the client's `groundOffset`. A caller that wants to
## put something else on the ground the way a peer stands on it needs the same number.
func ground_offset() -> float:
	return _ground_offset

func has(peer_name: String) -> bool:
	return _goats.has(peer_name)

## The names being mirrored, in the order they arrived.
func names() -> Array:
	return _goats.keys()

## One line per peer, for a probe or a log.
func describe() -> Array:
	var lines: Array = []
	for peer_name in _goats:
		var goat: Dictionary = _goats[peer_name]
		lines.append("  peer %s  at %s  ->  %s  %s" % [
			peer_name,
			(goat["node"] as Node3D).position,
			Vector3(float(goat["tx"]), 0.0, float(goat["tz"])),
			goat["clip"],
		])
	return lines

## One peer's own numbers, read out rather than reached into: where it is drawn, where it is
## going, the gait, both phases and the clip it settled on. A probe prints it and a case asserts
## it, and neither should have to know the dictionary's shape.
func report_of(peer_name: String) -> Dictionary:
	if not _goats.has(peer_name):
		return {}
	var goat: Dictionary = _goats[peer_name]
	return {
		"x": float(goat["x"]),
		"z": float(goat["z"]),
		"yaw": float(goat["yaw"]),
		"phase": float(goat["phase"]),
		"target_phase": float(goat["tphase"]),
		"py": float(goat["py"]),
		"pitch": float(goat["pitch"]),
		"roll": float(goat["roll"]),
		"target_pitch": float(goat["tpitch"]),
		"target_roll": float(goat["troll"]),
		"gait": String(goat["gait"]),
		"shot": bool(goat["shot"]),
		"clip": String(goat["clip"]),
		"position": (goat["node"] as Node3D).position,
	}

## The worst remaining gap between a peer and where the host last said it was. A mirror that
## has converged reports ~0.
func worst_gap() -> float:
	var worst := 0.0
	for goat: Dictionary in _goats.values():
		var node: Node3D = goat["node"]
		var target := Vector3(float(goat["tx"]), node.position.y, float(goat["tz"]))
		worst = maxf(worst, node.position.distance_to(target))
	return worst

func _goat_for(peer_name: String) -> Dictionary:
	if _goats.has(peer_name):
		return _goats[peer_name]
	var node: Node3D = GOAT_SCENE.instantiate()
	add_child(node)
	if not _ground_measured:
		_measure_ground_offset(node)
	var goat := {
		"node": node,
		"anim": _find_animation(node),
		"clip": "",
		"x": 0.0,
		"z": 0.0,
		"yaw": 0.0,
		"phase": 0.0,
		"tx": 0.0,
		"tz": 0.0,
		"tyaw": 0.0,
		"tphase": 0.0,
		"py": 0.0,
		"pitch": 0.0,
		"roll": 0.0,
		"tpitch": 0.0,
		"troll": 0.0,
		"gait": "idle",
		"shot": false,
	}
	_goats[peer_name] = goat
	return goat

## Put the goat where its eased numbers say, and pose it. The client's own placement
## (`net.js` `drawPeers`): `terrainHeight(x, z) + groundOffset + py`. A flyer is drawn the way
## its owner drew it: the body rotates about `explosions.fling.pivot`, so the node goes at the
## crate's corrected origin and the basis is its quaternion (`net.js` `peerFlightDraw`).
func _place(goat: Dictionary) -> void:
	var node: Node3D = goat["node"]
	var x: float = goat["x"]
	var z: float = goat["z"]
	var gait: String = String(goat["gait"])
	var ground: float = Terrain.height_at(x, z)
	var model_scale: float = node.scale.x
	if (gait == "fly" or gait == "fall") and flight != null:
		# `py` is the height above the ground it is drawn at, the same number the owner's
		# state carries (`FLIGHT.md` §6.2). The ground offset is the model's own lowest point
		# and cancels out of the crate's feet, so it is added back on the way out.
		var flight_state := PackedFloat32Array([
			x, z, ground + float(goat["py"]),
			float(goat["yaw"]), float(goat["pitch"]), float(goat["roll"]),
			0.0, 0.0, 0.0, 0.0, 0.0, 2.0 if gait == "fall" else 1.0])
		var origin: Vector3 = flight.back_point(flight_state, 0.0,
			PlayerGoat.FLIGHT_PIVOT * model_scale)
		node.position = origin + Vector3(0.0, _ground_offset * model_scale, 0.0)
		node.quaternion = flight.pose(flight_state)
	else:
		node.position = Vector3(x, ground + _ground_offset + float(goat["py"]), z)
		node.rotation = Vector3(0.0, float(goat["yaw"]), 0.0)
	_pose(goat, gait, float(goat["phase"]))

## Play the clip for a gait and pose it at the snapshot's phase -- the port's `clipAt(role, 0)`
## plus `poseModelOn`. A peer's variant is always the first: the wire carries the owner's phase
## but not which idle it is in, which is the client's own compromise for a remote goat.
func _pose(goat: Dictionary, gait: String, phase: float) -> void:
	var anim: AnimationPlayer = goat["anim"]
	var which: String = role(gait, _has_clip.bind(anim))
	var clip: String = _clip_name(which)
	var at: float = phase
	if (gait == "fly" or gait == "fall") and which == "jump":
		# The jump stands in for a flight the model has no clip for, held at a leap's
		# fraction -- the same placeholder the player's own pose uses (`FLIGHT.md` §3).
		# Without this the fly phase would loop the jump's last half a dozen times a second.
		at = 0.35
	if clip != goat["clip"]:
		goat["clip"] = clip
		if anim != null and anim.has_animation(clip):
			anim.play(clip)
	if anim != null and anim.has_animation(clip):
		# The snapshot carries the fraction through the clip, which is the only thing that can
		# pose a one-shot gait -- a jump, the death, the fling -- and `Pose` is where it lands
		# (`model.js` `poseModelOn`): the last frame at 1.0 and never a wrap to the first, so a
		# remote goat on its death gait keeps the pose it fell in.
		Pose.on(anim, clip, at)

## Whether the model has a clip for a role. `role`'s own predicate, which is what makes the
## fallback chain testable with a model that is missing one.
func _has_clip(role_name: String, anim: AnimationPlayer) -> bool:
	return anim != null and anim.has_animation(_clip_name(role_name))

## A role's clip in this model. Two are not the name capitalised, and both are the client's:
## `death` poses `GoatDeath` and `walk` is `GoatWalk` like the rest.
func _clip_name(role_name: String) -> String:
	if role_name == "death":
		return "GoatDeath"
	return "Goat" + role_name.capitalize()

## The model's own lowest point, negated (`model.js` `loadGoat`).
func _measure_ground_offset(goat: Node3D) -> void:
	_ground_measured = true
	var mesh_instance := _find_mesh(goat)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	_ground_offset = -mesh_instance.mesh.get_aabb().position.y

func _find_animation(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation(child)
		if found != null:
			return found
	return null

func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null

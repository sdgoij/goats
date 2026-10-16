# The mirrored herd: one goat per bot the host simulates.
#
# This is the port's first piece of *world*, and it is deliberately the smallest
# one that can be right: a client that joined a session does not simulate the
# herd (`net.js`, "the server's world"), it mirrors what the host sends. The host
# owns the bot AI, the collision and the weather, so a joiner only ever needs to
# place what it is told where it is told.
#
# Three rules come straight from the client's own mirror (`net.js`
# `updatePeers`), and they are what make 10-20 Hz snapshots read as movement
# rather than as a stutter:
#
#   * a snapshot is a *target*, not a teleport -- the render position eases
#     toward it at a fixed rate per second;
#   * yaw takes the short way round, so a goat crossing the +/-PI seam does not
#     spin the long way;
#   * the gait picks the clip and the snapshot's phase poses it.
#
# What this does is the client's half: place a herd from the wire. Where a goat
# *stands* is `terrain.gd`'s -- the same heightfield the host simulates on,
# rebuilt from the session seed (see that file on why that has to be a
# transcription rather than a lookalike), craters included: they ride the world
# snapshot and are a term in the field, so a mirrored goat stands in the same holes
# the host has blown. What it does **not** take from the wire is bots' per-spec
# scale, which the client gets from its own seed-derived spec table.
class_name Herd
extends Node3D

## The goat, complete with its rig and clips. A mirrored goat is a real goat --
## the same model the player's is, skinned and animated -- because a joiner has
## no simulation to stand a placeholder in front of.
const GOAT_SCENE := preload("res://assets/goat_animated.glb")

## How fast a mirrored goat converges on its snapshot, per second. The client's
## `NET_PEER_SMOOTH`, so the feel matches the thing being ported.
const SMOOTH := 12.0

var _goats := {}
## The client's `groundOffset`: the model's own lowest point, negated, so its feet
## land on the ground rather than at the origin (`model.js` `loadGoat`: `groundOffset
## = -bounds.minY`). Measured once, off the first goat instantiated.
var _ground_offset := 0.0
var _ground_measured := false

## Place the herd where the host says it is. Called once per world snapshot.
func apply(world: Dictionary) -> void:
	var bots: Variant = world.get("bots", [])
	if not (bots is Array):
		return
	var seen := {}
	for entry in bots:
		if not (entry is Dictionary):
			continue
		var index: int = int(entry.get("index", 0))
		seen[index] = true
		var goat := _goat_for(index)
		var x: float = float(entry.get("x", 0.0))
		var z: float = float(entry.get("z", 0.0))
		# `BotState::py` is centimetres (M19f); every other length here is metres.
		# `sceneWorldBots` in `net.js` is the only place the two units meet, and
		# this is its mirror.
		var lift: float = float(entry.get("py", 0.0)) / 100.0
		# The client's own placement (`net.js` `drawPeers`):
		# `terrainHeight(x, z) + groundOffset + py`.
		goat["target"] = Vector3(x, Terrain.height_at(x, z) + _ground_offset + lift, z)
		goat["yaw"] = float(entry.get("yaw", 0.0))
		_pose(goat, String(entry.get("gait", "idle")), float(entry.get("phase", 0.0)))

	# A bot off the end of the snapshot has left the host's herd. There is no
	# reason for one to vanish today, but a mirror that cannot forget is a leak.
	for index in _goats.keys():
		if not seen.has(index):
			(_goats[index]["node"] as Node3D).queue_free()
			_goats.erase(index)

func _process(delta: float) -> void:
	if _goats.is_empty():
		return
	# The client's own easing: a fixed fraction of the remaining gap per frame,
	# so a lost snapshot costs nothing and a burst of them costs nothing either.
	var k: float = minf(1.0, delta * SMOOTH)
	for goat: Dictionary in _goats.values():
		var node: Node3D = goat["node"]
		node.position = node.position.lerp(goat["target"], k)
		var dyaw: float = wrapf(float(goat["yaw"]) - node.rotation.y, -PI, PI)
		node.rotation.y += dyaw * k

## The herd's centre: the terrain and the camera follow this. The origin when
## there is no herd, which is where the grid is built at startup.
func centre() -> Vector3:
	if _goats.is_empty():
		return Vector3.ZERO
	var total := Vector3.ZERO
	for goat: Dictionary in _goats.values():
		total += (goat["node"] as Node3D).position
	return total / float(_goats.size())

## How many goats the mirror is holding.
func count() -> int:
	return _goats.size()

## The mirrored herd as the console's `bots` verb reads it: one dictionary per goat, in
## index order, with the fields the wire carries rather than the ones a simulation would
## keep. There is no `mode` or `belly` to report -- the host owns those, and a snapshot
## carries a gait and a phase, so a reader wanting that reads `describe()`.
func report() -> Array:
	var indexes: Array = _goats.keys()
	indexes.sort()
	var out: Array = []
	for index in indexes:
		var node: Node3D = _goats[index]["node"]
		out.append({
			"index": int(index), "x": node.position.x, "z": node.position.z,
			"yaw": node.rotation.y,
		})
	return out

## The mirrored herd's wake actors: `(x, z, py)` a goat, in index order -- which is the
## order the scene's own `BOTS` array has, so `Water`'s wake marks and the host's bots stay
## paired. A client splashes the herd it mirrors, which is the one part of M20d that would
## otherwise need a simulation to see.
##
## It reports where a goat is *drawn* rather than where the snapshot put it, because the
## wake is a thing the eye follows, and the height above the ground is the arc lift the
## snapshot carried, read back off the same ground the host used.
func actors() -> PackedFloat64Array:
	var indexes: Array = _goats.keys()
	indexes.sort()
	var out := PackedFloat64Array()
	out.resize(indexes.size() * 3)
	var at: int = 0
	for index in indexes:
		var node: Node3D = _goats[index]["node"]
		var x: float = node.position.x
		var z: float = node.position.z
		out[at] = x
		out[at + 1] = z
		out[at + 2] = node.position.y - Terrain.height_at(x, z) - _ground_offset
		at += 3
	return out

## The worst remaining gap between a *grounded* goat and where the host last said
## it was. A mirror that has converged reports ~0; one that is not moving reports
## the distance it failed to cover.
##
## Airborne goats are left out, and not to make the number look better: a flung
## goat is a projectile whose target jumps as the host recomputes the arc, and the
## client's own mirror lags it identically. "Converged" is a claim about a goat
## that is standing on the ground, so that is what this measures.
func worst_gap() -> float:
	var worst := 0.0
	for goat: Dictionary in _goats.values():
		if airborne(goat):
			continue
		worst = maxf(worst, (goat["node"] as Node3D).position.distance_to(goat["target"]))
	return worst

## How many goats the host currently has off the ground. Reported rather than
## asserted: a herd with none in the air is a fact about the host's moment, not a
## property of the mirror.
func airborne_count() -> int:
	var total := 0
	for goat: Dictionary in _goats.values():
		if airborne(goat):
			total += 1
	return total

## Whether the host has this goat off the ground: the snapshot's target sits above
## the terrain under it. This reads the *target* rather than the rendered
## position, so a goat mid-ease is judged by where it is going.
func airborne(goat: Dictionary) -> bool:
	var target: Vector3 = goat["target"]
	var ground: float = Terrain.height_at(target.x, target.z) + _ground_offset
	return target.y > ground + 0.05

## One line per goat, for a probe or a log.
func describe() -> Array:
	var lines: Array = []
	var indexes: Array = _goats.keys()
	indexes.sort()
	for index in indexes:
		var goat: Dictionary = _goats[index]
		lines.append("  bot %d  at %s  ->  %s  %s" % [
			index,
			(goat["node"] as Node3D).position,
			goat["target"],
			goat["clip"],
		])
	return lines

func _goat_for(index: int) -> Dictionary:
	if _goats.has(index):
		return _goats[index]
	var node: Node3D = GOAT_SCENE.instantiate()
	add_child(node)
	if not _ground_measured:
		_measure_ground_offset(node)
	var goat := {
		"node": node,
		"anim": _find_animation(node),
		"target": node.position,
		"yaw": 0.0,
		"clip": "",
	}
	_goats[index] = goat
	return goat

## The model's own lowest point, negated. Godot's glTF import keeps the mesh's
## authored origin -- the feet -- at y = 0, so this is 0.0 for this model, which is
## what the client measures too (`loadGoat` logs `y 0.000..1.470`). Measuring it
## rather than assuming it is what keeps a re-exported model from sinking.
func _measure_ground_offset(goat: Node3D) -> void:
	_ground_measured = true
	var mesh_instance := _find_mesh(goat)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	_ground_offset = -mesh_instance.mesh.get_aabb().position.y

## The terrain height under each goat, as `[low, high]`. A herd standing entirely
## on the flat spawn bowl reports zeros, so the probe reads this to tell "the
## terrain is applied" from "the terrain is flat here".
func ground_range() -> Array:
	if _goats.is_empty():
		return [0.0, 0.0]
	var low := INF
	var high := -INF
	for goat: Dictionary in _goats.values():
		var node: Node3D = goat["node"]
		var y: float = Terrain.height_at(node.position.x, node.position.z)
		low = minf(low, y)
		high = maxf(high, y)
	return [low, high]

## Play the clip for a gait and pose it at the snapshot's phase. A gait name is
## the scene's (`net.js` publishes `mode`) and a clip name is the model's, so this
## is the one place the two vocabularies are joined.
func _pose(goat: Dictionary, gait: String, phase: float) -> void:
	var clip: String = _clip_for(gait)
	var anim: AnimationPlayer = goat["anim"]
	if clip != goat["clip"]:
		goat["clip"] = clip
		if anim != null:
			anim.play(clip)
	if anim != null and anim.has_animation(clip):
		# The snapshot carries the fraction through the clip, which is the only
		# thing that can pose a one-shot gait -- a jump, the death.
		var length: float = anim.get_animation(clip).length
		anim.seek(fmod(phase, 1.0) * length, true)

func _clip_for(gait: String) -> String:
	match gait:
		"walk": return "GoatWalk"
		"trot": return "GoatTrot"
		"run": return "GoatRun"
		"jump": return "GoatJump"
		"flung": return "GoatFlung"
		"sleep": return "GoatSleep"
		"eat": return "GoatEat"
		# `dead` is the one gait whose clip is not simply its name capitalised:
		# the model's is `GoatDeath`.
		"dead": return "GoatDeath"
		_: return "GoatIdle"

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

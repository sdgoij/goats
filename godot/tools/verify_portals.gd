# The swarm's rings: `portals.gd` against `net.js`'s `PORTALS`.
#
#   Godot --headless --path godot --script res://tools/verify_portals.gd
#
# Two clients have to agree about a ring's place without ever exchanging a coordinate, so
# the thing worth pinning is the *derivation*: the FNV-1a hash, the angle and radius drawn
# from it, and the fact that the scene and the port compute the same numbers. The oracle
# below is transcribed from `crates/goats/src/game/net.js` and never from the port.
#
# The walk-in rule is the other half, and it is a state machine rather than arithmetic:
#
#   * a goat inside a ring joins it once, not once a frame;
#   * a blocked step -- a session, a join in flight, a menu, a corpse -- joins nothing;
#   * a goat that steps out and back in tries again, which is what makes a refused join a
#     deliberate second attempt rather than a loop;
#   * a client in a session gets the amber exit at (0, 10) instead of the hosts' rings,
#     and walking into it leaves -- once, and not on the frame the session begins.
#
# The beads themselves are a draw call and are not asserted: `verify_water_wake.gd` and
# `verify_mod_gfx.gd` are where "the node exists per call" is checked, and a ring is the
# same bargain.
extends SceneTree

const PortalsScript := preload("res://src/portals.gd")

var _failures: Array[String] = []

func _initialize() -> void:
	_check_placement()
	_check_nearest()
	_check_step()
	_check_draw()
	if _failures.is_empty():
		print("OK: the rings derive the scene's places, the walk-in joins once, and the exit leaves")
		quit(0)
		return
	for failure: String in _failures:
		print("FAIL: ", failure)
	quit(1)

## `PORTALS`' `hash`: FNV-1a over UTF-16 code units, 32 bits. Transcribed from the scene.
func _hash(text: String) -> int:
	var value: int = 2166136261
	for i in text.length():
		value = value ^ text.unicode_at(i)
		value = (value * 16777619) & 0xFFFFFFFF
	return value

func _check_placement() -> void:
	# The hash is the whole of the agreement, so it is checked on vectors rather than on
	# the placement it feeds: a wrong hash would only look like "a different ring".
	if _hash("") != 2166136261:
		_failures.append("FNV-1a of the empty string is the offset basis")
	if _hash("a") != 3826002220:
		_failures.append("FNV-1a('a') is 3826002220, got %d" % _hash("a"))
	if _hash("foobar") != 3214735720:
		_failures.append("FNV-1a('foobar') is 3214735720, got %d" % _hash("foobar"))
	if PortalsScript.ticket_hash("foobar") != _hash("foobar"):
		_failures.append("the port's hash is the scene's")

	var a: Dictionary = PortalsScript.placement("ticket-a")
	var again: Dictionary = PortalsScript.placement("ticket-a")
	var b: Dictionary = PortalsScript.placement("ticket-b")
	if a != again:
		_failures.append("the same ticket lands in the same place")
	if a == b:
		_failures.append("different tickets land in different places")
	var radius: float = Vector2(float(a["x"]), float(a["z"])).length()
	if radius < 20.0 or radius > 30.0:
		_failures.append("a ring is 20-30 m out, not %.3f m" % radius)
	# The scene's own argument order: `angle` then `spread`, both off the one hash.
	var angle: float = (float(_hash("ticket-a")) / 4294967296.0) * PI * 2.0
	var spread: float = float(_hash("ticket-a#radius") % 1000) / 1000.0
	var want_radius: float = 20.0 + spread * 10.0
	if absf(float(a["x"]) - cos(angle) * want_radius) > 1e-6:
		_failures.append("the ring's x is the scene's")
	if absf(float(a["z"]) - sin(angle) * want_radius) > 1e-6:
		_failures.append("the ring's z is the scene's")
	if absf(float(a["tangentX"]) + sin(angle)) > 1e-6:
		_failures.append("the tangent runs along -sin(angle)")
	if absf(float(a["tangentZ"]) - cos(angle)) > 1e-6:
		_failures.append("the tangent runs along cos(angle)")

func _check_nearest() -> void:
	var hosts: Array = [
		{"ticket": "ticket-a", "name": "ann", "clients": 1, "protocol": 13},
		{"ticket": "ticket-b", "name": "ben", "clients": 2, "protocol": 13},
	]
	var near: Dictionary = PortalsScript.placement("ticket-b")
	var list: Array = PortalsScript.nearest(hosts, float(near["x"]), float(near["z"]))
	if list.size() != 2:
		_failures.append("both hosts are placed")
		return
	if String(list[0]["host"]["ticket"]) != "ticket-b":
		_failures.append("the nearest ring is first, whichever ticket it is")
	# A list long enough to cut: the scene draws only the nearest `DRAWN`.
	var many: Array = []
	for i in 32:
		many.append({"ticket": "ticket-%d" % i, "name": "h%d" % i, "clients": 1, "protocol": 13})
	if PortalsScript.nearest(many, 0.0, 0.0).size() != PortalsScript.DRAWN:
		_failures.append("only the nearest eight rings are drawn")

func _check_draw() -> void:
	# The beads are a draw call, but the node has to build: two layers of `SEGMENTS` beads
	# each, placed on the ground the scene's field gives. This is also the only execution of
	# `Terrain.height_at` from the portal code, which is the part a draw gate would miss.
	var portal: Portals = PortalsScript.new()
	root.add_child(portal)
	portal.hosts = [{"ticket": "ticket-a", "name": "ann", "clients": 1, "protocol": 13}]
	portal.update(0.0, 0.0, false)
	if portal.get_child_count() != 2:
		_failures.append("a ring is two layers: the haze and the glow")
	else:
		for layer: int in [0, 1]:
			var instance: MultiMeshInstance3D = portal.get_child(layer)
			if instance.multimesh == null \
					or instance.multimesh.visible_instance_count != PortalsScript.SEGMENTS:
				_failures.append("one ring is %d beads" % PortalsScript.SEGMENTS)
	portal.free()

func _check_step() -> void:
	var portal: Portals = PortalsScript.new()
	var joined: Array[String] = []
	portal.join = func(ticket: String) -> void: joined.append(ticket)
	portal.hosts = [{"ticket": "ticket-a", "name": "ann", "clients": 1, "protocol": 13}]
	var place: Dictionary = PortalsScript.placement("ticket-a")

	portal.step(float(place["x"]), float(place["z"]), false, false, false, false)
	if joined.size() != 1 or joined[0] != "ticket-a":
		_failures.append("walking into a ring joins it")
	portal.step(float(place["x"]), float(place["z"]), false, false, false, false)
	if joined.size() != 1:
		_failures.append("standing in a ring joins it once")
	# Out and back in is a second attempt, which is how a refused join is retried.
	portal.step(float(place["x"]) + 100.0, float(place["z"]), false, false, false, false)
	portal.step(float(place["x"]), float(place["z"]), false, false, false, false)
	if joined.size() != 2:
		_failures.append("stepping out and back in tries again")

	portal.step(float(place["x"]) + 100.0, float(place["z"]), false, false, false, false)
	portal.step(float(place["x"]), float(place["z"]), true, false, false, false)
	portal.step(float(place["x"]), float(place["z"]), false, false, false, true)
	if joined.size() != 2:
		_failures.append("a blocked step joins nothing")

	# The exit: a client has one at (0, 10), and arriving while already inside it does
	# not leave until the goat steps out and back in.
	var exits: Array[bool] = []
	portal.leave = func() -> void: exits.append(true)
	var exit: Dictionary = PortalsScript.exit_place()
	if float(exit["x"]) != 0.0 or float(exit["z"]) != 10.0:
		_failures.append("the exit is ten metres from spawn on the z axis")
	portal.step(float(exit["x"]), float(exit["z"]), true, true, false, false)
	if not exits.is_empty():
		_failures.append("joining inside the exit ring does not leave at once")
	portal.step(0.0, 0.0, true, true, false, false)
	portal.step(float(exit["x"]), float(exit["z"]), true, true, false, false)
	if exits.size() != 1:
		_failures.append("walking into the exit leaves the session")
	portal.step(float(exit["x"]), float(exit["z"]), true, true, false, false)
	if exits.size() != 1:
		_failures.append("standing in the exit leaves once")
	# A menu or a corpse keeps the exit from firing, the same as a join.
	portal.step(0.0, 0.0, true, true, false, false)
	portal.step(float(exit["x"]), float(exit["z"]), true, true, true, false)
	portal.step(float(exit["x"]), float(exit["z"]), true, true, false, true)
	if exits.size() != 1:
		_failures.append("a blocked exit leaves nothing")
	portal.free()

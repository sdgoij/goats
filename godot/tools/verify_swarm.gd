# The swarm gate: two `NetBridge` nodes discover each other over a real gossip topic.
#
#   Godot --headless --path godot --script res://tools/verify_swarm.gd
#
# The reference client's `a_swarm_finds_a_host_and_leaving_forgets_it`, as a second
# bridge: one joins the default topic, the other is seeded by its ticket, the first
# hosts, and the second's `discovered` list names that session. Leaving clears the list,
# which is what takes the portal down.
#
# The seed matters: gossip cannot find a topic nobody is in, so the first bridge's swarm
# ticket is the introduction -- the same way `goatsd` seeds a WAN deployment. It takes a
# few seconds for the mesh to form and an advert to cross.
extends SceneTree

var _host: Object
var _player: Object
var _buffers := {}

## The most recent line matching every needle, or "". Buffers are per instance so a line
## that arrives in the same batch as the one being waited for is not lost.
func _wait(bridge: Object, needles: Array, timeout_ms: int) -> String:
	var key: int = bridge.get_instance_id()
	if not _buffers.has(key):
		_buffers[key] = []
	var buffer: Array = _buffers[key]
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while true:
		for line in buffer:
			if _has_all(line, needles):
				return line
		if Time.get_ticks_msec() >= deadline:
			return ""
		for line in bridge.call("poll_events"):
			buffer.append(line)
		OS.delay_msec(20)
	return ""

func _has_all(line: String, needles: Array) -> bool:
	for needle: Variant in needles:
		if not line.contains(String(needle)):
			return false
	return true

func _initialize() -> void:
	if not ClassDB.class_exists("NetBridge"):
		print("FAIL: NetBridge is not registered - the GDExtension did not load")
		quit(1)
		return
	_host = ClassDB.instantiate("NetBridge")
	_player = ClassDB.instantiate("NetBridge")
	var failures: Array[String] = []

	# 1. The host joins the default topic. The reply carries the topic and this node's
	#    own swarm ticket, which is what seeds the second bridge.
	print("swarm join -> ", _host.call("swarm_join", "", ""))
	var joined: String = _wait(_host, ["\"type\":\"swarm\"", "\"joined\":true"], 60000)
	if joined.is_empty():
		print("FAIL: the host never joined a swarm within 60s")
		_host.call("shutdown")
		_host.free()
		_player.free()
		quit(1)
		return
	var swarm: Dictionary = JSON.parse_string(joined)
	var topic: String = String(swarm["topic"])
	var swarm_seed: String = String(swarm["ticket"])
	print("topic: ", topic.substr(0, 16), "...  seed: ", swarm_seed.substr(0, 16), "...")

	# 2. The player joins the same topic, seeded by the host. Joining is listen-only
	#    until someone else is on the topic, which is why the seed is not optional here.
	print("player join -> ", _player.call("swarm_join", topic, swarm_seed))
	var player_joined: String = _wait(_player, ["\"type\":\"swarm\"", "\"joined\":true"], 60000)
	if player_joined.is_empty():
		failures.append("the second bridge never joined the host's topic")

	# 3. Hosting publishes an advert on that topic: the session's own ticket, its name
	#    and this client's protocol.
	_host.call("host", "bob", "")
	var ticket_line: String = _wait(_host, ["\"type\":\"ticket\""], 60000)
	if ticket_line.is_empty():
		failures.append("the host never produced a session ticket")
	else:
		var session_ticket: String = String(JSON.parse_string(ticket_line)["ticket"])
		var discovered: String = _wait(_player, ["\"type\":\"discovered\"", session_ticket, "bob"], 60000)
		print("discovered: ", discovered)
		if discovered.is_empty():
			failures.append("the player never discovered the host's session")

	# 3b. Zero-config: two fresh bridges with auto-discovery on, and neither a seed nor a
	#     `swarm_join`. The LAN beacon is the whole introduction. This is the path a player
	#     takes by launching two windows, so it is the one worth pinning.
	var auto_a: Object = ClassDB.instantiate("NetBridge")
	var auto_b: Object = ClassDB.instantiate("NetBridge")
	auto_a.call("set_swarm_auto", true)
	auto_b.call("set_swarm_auto", true)
	var a_joined: String = _wait(auto_a, ["\"type\":\"swarm\"", "\"joined\":true"], 60000)
	var b_joined: String = _wait(auto_b, ["\"type\":\"swarm\"", "\"joined\":true"], 60000)
	if a_joined.is_empty() or b_joined.is_empty():
		failures.append("auto-join did not start the swarm")
	auto_a.call("host", "auto", "")
	var a_ticket_line: String = _wait(auto_a, ["\"type\":\"ticket\""], 60000)
	if a_ticket_line.is_empty():
		failures.append("the zero-config host never produced a ticket")
	else:
		var a_ticket: String = String(JSON.parse_string(a_ticket_line)["ticket"])
		var auto_found: String = _wait(auto_b, ["\"type\":\"discovered\"", a_ticket], 60000)
		print("zero-config discovered: ", auto_found)
		if auto_found.is_empty():
			failures.append("zero-config discovery found no host")

	# 4. Leaving takes the list down. A host that stops browsing the topic should not
	#    leave a ring standing for its TTL.
	_player.call("swarm_leave")
	var left: String = _wait(_player, ["\"type\":\"swarm\"", "\"joined\":false"], 30000)
	if left.is_empty():
		failures.append("leaving the swarm was not reported")
	var cleared: String = _wait(_player, ["\"type\":\"discovered\"", "\"sessions\":[]"], 30000)
	if cleared.is_empty():
		failures.append("leaving the swarm left a host in the list")

	# `shutdown` closes the channel and joins the runtime thread, which a process that
	# quits with a live endpoint does not do safely.
	_host.call("shutdown")
	_player.call("shutdown")
	auto_a.call("shutdown")
	auto_b.call("shutdown")
	_host.free()
	_player.free()
	auto_a.free()
	auto_b.free()

	if failures.is_empty():
		print("OK: a swarm finds a hosting Godot bridge -- seeded, and with no seed on the LAN")
		quit(0)
		return
	for failure: String in failures:
		print("FAIL: ", failure)
	quit(1)

# The networking gate: two `NetBridge` nodes, a real host, a real ticket, and a
# real joiner -- over iroh, on loopback, with no window. It is the automation of
# the two-window check, and it mirrors the raylib client's
# `two_bridges_meet_over_loopback` case in `crates/goats/src/net.rs`.
#
#   Godot --headless --path godot --script res://tools/verify_net.gd
#
# Because both ends are the *same* `session`/`proto` crates the client and
# `goatsd` use, what this proves is stronger than "the port talks to itself": it
# is the wire those peers speak. A non-zero exit makes it usable as a gate.
#
# The last four checks are M26/M14d2's: the world a host publishes and a client adopts
# (the snapshot `main.gd` `_publish_world` builds, parsed by the same
# `WorldIntent`), the **world mods**, on a datagram of their own, and the two
# directions of a bang -- a host's own device, and a client's *report* that the host
# relays, leaving the reporter out (M19e). That last one needs a third player, so
# one joins late.
#
# It takes twenty to thirty seconds: a host binds a real iroh endpoint.
extends SceneTree

const HOST_NAME := "bob"
const CLIENT_NAME := "alice"
const CAROL_NAME := "carol"
# A real packed cell key -- `Meadow.key(1, 2)` -- so the payload's meadow and
# device rows are the shape a scene actually sends rather than a round number.
const CELL_KEY := 33566722

var _host: Object
var _client: Object
var _carol: Object
# Every line each bridge has produced, per instance, so a line that arrives in
# the same batch as the one being waited for is not lost.
var _buffers := {}

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("NetBridge"):
		print("FAIL: NetBridge is not registered - the GDExtension did not load")
		quit(1)
		return

	_host = ClassDB.instantiate("NetBridge")
	_client = ClassDB.instantiate("NetBridge")
	_carol = ClassDB.instantiate("NetBridge")

	# 1. Host. The ticket is what a joiner needs, and it has to be a real one.
	print("host -> ", _host.call("host", HOST_NAME))
	var ticket_line: String = _wait(_host, ["\"type\":\"ticket\""], 60000)
	if ticket_line.is_empty():
		print("FAIL: no ticket within 60s; the host never came up")
		quit(1)
		return
	var ticket: String = JSON.parse_string(ticket_line)["ticket"]
	print("ticket: ", ticket.substr(0, 32), "...")

	# 2. Join with it. The name comes back canonical, which may differ from the
	#    one asked for -- names are first come, first served.
	print("join -> ", _client.call("join", ticket, CLIENT_NAME))
	var welcome: String = _wait(_client, ["\"type\":\"welcome\"", CLIENT_NAME], 60000)
	print("welcome:        ", welcome)
	if welcome.is_empty():
		failures.append("no welcome naming %s within 60s" % CLIENT_NAME)

	# 3. The host hears about the join, and both sides get the roster.
	var joined: String = _wait(_host, ["\"type\":\"joined\"", CLIENT_NAME], 30000)
	print("host joined:    ", joined)
	if joined.is_empty():
		failures.append("the host never heard the join")

	var host_roster: String = _wait(_host, ["\"type\":\"roster\"", CLIENT_NAME], 30000)
	print("host roster:    ", host_roster)
	if host_roster.is_empty():
		failures.append("the host's roster does not name %s" % CLIENT_NAME)

	var client_roster: String = _wait(_client, ["\"type\":\"roster\"", CLIENT_NAME], 30000)
	print("client roster:  ", client_roster)
	if client_roster.is_empty():
		failures.append("the client's roster does not name %s" % CLIENT_NAME)

	# 4. Chat crosses the bridge under the sender's name.
	_client.call("say", "hello")
	var heard: String = _wait(_host, ["\"type\":\"chat\"", "\"from\":\"%s\"" % CLIENT_NAME, "hello"], 30000)
	print("host heard:     ", heard)
	if heard.is_empty():
		failures.append("the host did not hear the client's chat")

	# 5. A whisper from the host reaches the client, marked direct.
	_host.call("say", "@%s psst" % CLIENT_NAME)
	var whisper: String = _wait(_client, ["\"direct\":true", "psst"], 30000)
	print("client heard:   ", whisper)
	if whisper.is_empty():
		failures.append("the whisper did not reach the client")

	# 6. A pose crosses on the datagram channel, not a stream. Datagrams are
	#    unreliable, so a small burst stands in for the stream a real client
	#    sends about twenty times a second.
	for i in 10:
		_client.call("pose", 1.5, -2.0, 0.25, 0.5, 2.0, "trot", 0.0)
		OS.delay_msec(20)
	var peer: String = _wait(_host, ["\"type\":\"peer\"", CLIENT_NAME, "trot"], 30000)
	print("host saw:       ", peer)
	if peer.is_empty():
		failures.append("the host did not see the client's goat")

	# 7. The world. A host publishes it and a client adopts the snapshot instead of
	#    simulating (`net.js` `netMaybePublishWorld`). The payload is `WorldState`'s own
	#    shape -- `sceneWorldBots`, `sceneWeatherState`, `sceneStreams`, `sceneEaten`,
	#    `netWorldCraters`, `netWorldSpent` -- and `world` answers `ok` only when it parses
	#    as one, which is the parse `main.gd`'s own `_publish_world` leans on.
	#
	#    The bots, the meadow and the craters are on the wire's quantization grid (1 cm,
	#    1/10000 turn, 255 phase steps, quarter seconds), so they are chosen on it; the sky
	#    and the streams travel as they stand and come back exact.
	var world := {
		"bots": [
			{"index": 0, "x": 1.5, "z": -2.5, "yaw": 0.75, "phase": 0.25, "gait": "trot",
				"variant": 3, "py": 0},
			{"index": 1, "x": -4.0, "z": 0.5, "yaw": -1.25, "phase": 0.5, "gait": "flung",
				"variant": 0, "py": 120},
		],
		"weather": {"kind": "rain", "cloudiness": 1.0, "rain_amount": 0.875,
			"wind_x": 0.25, "wind_z": -0.125, "wind_sway": 0.5, "world_time": 13.5},
		"streams": {"weather": 111, "bots": 222, "food": 333, "audio": 444},
		"eaten": [{"key": CELL_KEY, "left": 12.5}],
		"craters": [{"x": 3.0, "z": 4.0, "r": 2.5, "depth": 0.75}],
		"spent": [{"key": CELL_KEY, "trap": false}],
	}
	print("world ->        ", _host.call("world", JSON.stringify(world)))
	var snapshot: String = _wait(_client, ["\"type\":\"world\"", "\"kind\":\"rain\"", "\"streams\""], 30000)
	print("client world:   ", snapshot.substr(0, 150))
	if snapshot.is_empty():
		failures.append("the client never received the host's world")
	else:
		var received: Dictionary = JSON.parse_string(snapshot)
		var streams: Dictionary = received.get("streams", {})
		if int(streams.get("weather", 0)) != 111 or int(streams.get("audio", 0)) != 444:
			failures.append("the world's streams did not survive the wire: %s" % streams)
		var got_bots: Array = received.get("bots", [])
		if got_bots.size() != 2:
			failures.append("the snapshot carried %d bot(s), not 2" % got_bots.size())
		elif String(got_bots[0].get("gait", "")) != "trot" \
				or absf(float(got_bots[0].get("x", 0.0)) - 1.5) > 0.011 \
				or String(got_bots[1].get("gait", "")) != "flung" \
				or int(got_bots[1].get("py", 0)) != 120:
			failures.append("the snapshot's herd is not the one published: %s" % got_bots)

	# 7b. The world mods, on a datagram of their own (`APIv1.md` section 4.13). It is opaque to the
	#     transport -- what a mod publishes is its own business -- so the only thing to hold is that
	#     it arrives whole: the streams' states and the published data, unchanged, in the shape
	#     `sceneWorldMods` builds. `NetBridge::mods` refuses a payload that is not JSON at all,
	#     which is the one judgement this end makes; the *size* refusal is `proto`'s.
	var mods := {
		"streams": {"com.example.w:f": 4242},
		"data": {"com.example.w": [[1.0, 2.0, 3.0, 0.5, 1]]},
	}
	print("mods ->         ", _host.call("mods", JSON.stringify(mods)))
	var mods_line: String = _wait(_client, ["\"type\":\"mods\"", "\"com.example.w\""], 30000)
	print("client mods:    ", mods_line.substr(0, 150))
	if mods_line.is_empty():
		failures.append("the client never received the host's world mods")
	else:
		var got_mods: Dictionary = JSON.parse_string(mods_line).get("mods", {})
		var got_streams: Variant = got_mods.get("streams", null)
		if not (got_streams is Dictionary) \
				or int((got_streams as Dictionary).get("com.example.w:f", 0)) != 4242:
			failures.append("the mods streams did not survive the wire: %s" % got_mods)
		var got_data: Variant = got_mods.get("data", null)
		var got_rows: Variant = (got_data as Dictionary).get("com.example.w", null) \
			if got_data is Dictionary else null
		if not (got_rows is Array) or (got_rows as Array).size() != 1:
			failures.append("the published data did not survive the wire: %s" % got_mods)

	# 8. A bang (M19e): the host's own device goes off and every client hears it, with the
	#    host's own coordinates. An empty `by` is the client's way of saying "this is mine"
	#    -- and a client's coordinates are the host's to say, so they do not travel.
	print("host blast ->   ", _host.call("blast", "mine", CELL_KEY, 6.0, 7.0, ""))
	var bang: String = _wait(_client, ["\"type\":\"blast\"", "\"by\":\"bob\""], 30000)
	print("client bang:    ", bang)
	if bang.is_empty():
		failures.append("a host's bang never reached the client")

	# 9. A client's own device goes off: it *reports* the key, and the host hears a
	#    `blast_report` naming it. The world is not trusted to a reporter's coordinates, so
	#    the report carries none -- the host derives where the key is.
	print("client blast -> ", _client.call("blast", "trap", CELL_KEY, 8.0, 9.0, ""))
	var report: String = _wait(_host, ["\"type\":\"blast_report\"", "\"by\":\"alice\""], 30000)
	print("host report:    ", report)
	if report.is_empty():
		failures.append("the host did not hear the client's bang report")

	# ...and the host relays it to everybody *but* the reporter, who has already felt it.
	# That needs a third player, or the "everybody" is the reporter.
	print("join carol ->   ", _carol.call("join", ticket, CAROL_NAME))
	var carol_welcome: String = _wait(_carol, ["\"type\":\"welcome\"", CAROL_NAME], 60000)
	print("carol welcome:  ", carol_welcome)
	if carol_welcome.is_empty():
		failures.append("the third player never joined")
	print("relay ->        ", _host.call("blast", "trap", CELL_KEY, 8.0, 9.0, "alice"))
	var relayed: String = _wait(_carol, ["\"type\":\"blast\"", "\"by\":\"alice\""], 30000)
	print("carol heard:    ", relayed)
	if relayed.is_empty():
		failures.append("the relayed bang did not reach the third player")
	# The negative half: the reporter must not get it back. Only the relay names alice as
	# `by`, so a line that does is a second landing on the one goat that already felt it.
	OS.delay_msec(500)
	for line in _client.call("poll_events"):
		if String(line).contains("\"type\":\"blast\"") \
				and String(line).contains("\"by\":\"alice\""):
			failures.append("the relay reached the reporter, who had already felt it")

	# `shutdown` closes the channel and *joins* the runtime thread, which is what
	# makes the exit clean: without it the process ends while iroh is still
	# tearing an endpoint down and dies on the way out.
	_host.call("shutdown")
	_client.call("shutdown")
	_carol.call("shutdown")
	_host.free()
	_client.free()
	_carol.free()

	if failures.is_empty():
		print("OK: three Godot peers meet over the session crate's own wire, world and bangs included")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

# Poll a bridge until one line contains every needle, or the timeout passes.
#
# Lines are kept in a per-bridge buffer rather than dropped, which is what the
# client's own helper does and what made the roster assertion here fail: the
# roster arrives in the same poll batch as the `joined` that precedes it, so a
# search that returns on the first match throws it away.
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
		var lines: PackedStringArray = bridge.call("poll_events")
		for line in lines:
			buffer.append(line)
		OS.delay_msec(20)
	return ""

func _has_all(line: String, needles: Array) -> bool:
	for needle in needles:
		if not line.contains(needle):
			return false
	return true

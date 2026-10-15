# The interop gate: a Godot client joining the *shipping* host, `goatsd`.
#
#   GOATSD_TICKET=<ticket> GOATSD_EXPECT=join|refuse \
#     Godot --headless --path godot --script res://tools/verify_interop.gd
#
# `interop.sh` starts a real `goatsd` and runs this against it; the script itself
# only needs the ticket, so it can also be pointed at a server someone else is
# running. Two modes, because both outcomes are evidence:
#
#   join    -- `goatsd --no-mods` requires no world mods, so a client with none
#              joins: a welcome, the roster, a chat echo, and the server's world
#              arriving as datagrams.
#   refuse  -- `goatsd` run against the repository's `mods/` requires its world
#              mods, so a client presenting none is refused *by digest*. That
#              refusal crossing two independent implementations is the
#              compatibility handshake (`APIv1.md` section 6.3) working, and it
#              is the failure mode a player actually hits.
extends SceneTree

# Every line the bridge has produced, so nothing is lost between waits.
var _buffer: Array = []

func _initialize() -> void:
	var ticket: String = OS.get_environment("GOATSD_TICKET")
	var expect: String = OS.get_environment("GOATSD_EXPECT")
	if expect.is_empty():
		expect = "join"
	if ticket.is_empty():
		print("FAIL: GOATSD_TICKET is not set")
		quit(1)
		return

	var failures: Array[String] = []
	var bridge: Object = ClassDB.instantiate("NetBridge")
	print("mode: ", expect)
	print("join -> ", bridge.call("join", ticket, "godot"))

	if expect == "refuse":
		var refusal: String = _wait(bridge, ["\"type\":\"error\""], 60000)
		print("refusal: ", refusal)
		if refusal.is_empty():
			failures.append("a client with no world mods was not refused")
		elif not refusal.contains("mod"):
			failures.append("the refusal does not name mods: " + refusal)
		_shutdown(bridge)
		_report(failures, "the host refused the join by mod digest")
		return

	# 1. The joiner is welcomed under the name it asked for. `goatsd` stamps the
	#    canonical one, so a difference here would show a name collision.
	var welcome: String = _wait(bridge, ["\"type\":\"welcome\"", "godot"], 60000)
	print("welcome:        ", welcome)
	if welcome.is_empty():
		failures.append("no welcome naming godot within 60s")

	# 2. The roster names both ends: this player and the server's own player.
	var roster: String = _wait(bridge, ["\"type\":\"roster\"", "godot"], 30000)
	print("roster:         ", roster)
	if not roster.contains("godot-host"):
		failures.append("the roster does not name the server's player: " + roster)

	# 3. Chat is routed by the server and comes back to the sender, which is what
	#    makes the local transcript match everyone else's.
	bridge.call("say", "hello from godot")
	var heard: String = _wait(bridge, ["\"type\":\"chat\"", "hello from godot"], 30000)
	print("chat echo:      ", heard)
	if heard.is_empty():
		failures.append("the server did not route the chat back")

	# 4. The server's world arrives as datagrams, with its fields -- the shape the
	#    GDScript core will mirror, and the check that the high-rate channel works
	#    across the two engines. It waits for a world that actually *carries bots*,
	#    not merely for the first one: `goatsd` loads the shared JS scene one step
	#    per frame, and the snapshots it publishes while doing so are of a
	#    half-built world with no herd in it yet, which takes ten seconds or so.
	var world_line: String = _wait(bridge, ["\"type\":\"world\"", "\"bots\":[{"], 90000)
	if world_line.is_empty():
		# Report what did arrive, so the failure is diagnosable rather than bare.
		var bare: String = _search(["\"type\":\"world\""])
		if bare.is_empty():
			failures.append("no world datagrams arrived from the host")
		else:
			failures.append("the world datagrams carry no bots: " + bare)
	else:
		_pump(bridge, 1000)
		print("world datagrams: ", _count("\"type\":\"world\""))
		_check_world(world_line, failures)

	_shutdown(bridge)
	_report(failures, "a Godot client joined goatsd, chatted and mirrored its world")

# The fields matter, not just the arrival: a joiner with a bare `{"type":"world"}`
# mirrors nothing. This reads the event the way the core will -- as JSON, by path.
func _check_world(line: String, failures: Array) -> void:
	var world: Variant = JSON.parse_string(line)
	if not (world is Dictionary):
		failures.append("the world event is not JSON: " + line)
		return

	var bots: Variant = world["bots"]
	var weather: Variant = world["weather"]
	var streams: Variant = world["streams"]
	var eaten: Variant = world["eaten"]
	if bots is Array and bots.size() > 0:
		print("world bot 0:    ", bots[0])
	print("world weather:  ", weather["kind"] if weather is Dictionary else "?",
		" at hour ", weather["world_time"] if weather is Dictionary else "?")
	print("world streams:  ", streams)

	if not (bots is Array) or bots.size() == 0:
		failures.append("the world carries no bots: " + line)
	if not (weather is Dictionary) or not weather.has("world_time"):
		failures.append("the world carries no weather clock: " + line)
	if not (streams is Dictionary) or not streams.has("bots"):
		failures.append("the world carries no streams: " + line)
	# `eaten` is null when the host's snapshot had to shed the meadow to fit the
	# datagram, so its presence is not required -- only that the key is there.
	if not world.has("eaten"):
		failures.append("the world carries no eaten key: " + line)

func _report(failures: Array, ok_message: String) -> void:
	if failures.is_empty():
		print("OK: ", ok_message)
		quit(0)
		return
	# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
	# flushes, so a failure written there is never seen.
	for f in failures:
		print("FAIL: ", f)
	quit(1)

# Close the session and join its runtime thread before the process exits;
# ending mid-teardown is what segfaults on the way out.
func _shutdown(bridge: Object) -> void:
	bridge.call("shutdown")
	bridge.free()

func _wait(bridge: Object, needles: Array, timeout_ms: int) -> String:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while true:
		var found: String = _search(needles)
		if not found.is_empty():
			return found
		if Time.get_ticks_msec() >= deadline:
			return ""
		_pump(bridge, 50)
	return ""

func _pump(bridge: Object, ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		var lines: PackedStringArray = bridge.call("poll_events")
		for line in lines:
			_buffer.append(line)
		OS.delay_msec(20)

func _search(needles: Array) -> String:
	for line in _buffer:
		var all := true
		for needle in needles:
			if not line.contains(needle):
				all = false
				break
		if all:
			return line
	return ""

func _count(needle: String) -> int:
	var total := 0
	for line in _buffer:
		if line.contains(needle):
			total += 1
	return total

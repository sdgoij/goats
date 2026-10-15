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
# It takes twenty to thirty seconds: a host binds a real iroh endpoint.
extends SceneTree

const HOST_NAME := "bob"
const CLIENT_NAME := "alice"

var _host: Object
var _client: Object
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

	# `shutdown` closes the channel and *joins* the runtime thread, which is what
	# makes the exit clean: without it the process ends while iroh is still
	# tearing an endpoint down and dies on the way out.
	_host.call("shutdown")
	_client.call("shutdown")
	_host.free()
	_client.free()

	if failures.is_empty():
		print("OK: two Godot peers meet over the session crate's own wire")
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

# The voice gate (M13b): a tone in one host, out the other, decoded.
#
#   Godot --headless --path godot --script res://tools/verify_voice.gd
#
# A microphone cannot be gated, so this is the *codec and the wire* instead: the host hands
# `push_voice` a 440 Hz tone, the session carries the Opus frames the gate decided to send, and
# the client's `pull_voice` decodes them back. Because both ends are the same `session`/`proto`
# crates and the *same* `crates/voice` codec the raylib client uses, what this proves is the
# whole path a real word takes -- the gate, the coder, the datagram and the decoder -- minus the
# two sound cards, which are `voice.gd`'s and `audio.gd`'s and need hardware.
#
# Three things are held:
#
#   1. **The round trip.** A tone loud enough to open the gate encodes to at least one frame,
#      arrives, decodes, and is still a tone rather than silence.
#   2. **The counters.** `voice_state`'s `sent` on the host and `decoded` on the client are the
#      codec's own tallies, so they say the frames crossed rather than merely that no error was
#      raised.
#   3. **The mute.** With the client's gain at 0, the *same* tone still decodes (so the check is
#      not vacuous) and every sample handed back is zero -- which is `audio.js`'s `voice_gain`
#      intent doing what a mute should.
#
# It takes twenty to thirty seconds: a host binds a real iroh endpoint.
extends SceneTree

const HOST_NAME := "bob"
const CLIENT_NAME := "alice"
# The wire's frame, from `crates/voice`: 20 ms at 48 kHz.
const FRAME := 960
const RATE := 48000
# How many 20 ms frames of tone each phase sends. Ten is a fifth of a second, long enough that a
# single dropped datagram still leaves a tone rather than nothing.
const FRAMES := 12

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("NetBridge"):
		print("FAIL: NetBridge is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("NetBridge")
	var client: Object = ClassDB.instantiate("NetBridge")

	# 1. Host and join, exactly as `verify_net.gd` does: a real ticket, a real joiner, and the
	#    empty world-mod set both ends present (the digest is `interop.sh herd`'s subject).
	print("host -> ", host.call("host", HOST_NAME, ""))
	var ticket_line: String = _wait(host, ["\"type\":\"ticket\""], 60000)
	if ticket_line.is_empty():
		print("FAIL: no ticket within 60s; the host never came up")
		quit(1)
		return
	var ticket: String = JSON.parse_string(ticket_line)["ticket"]
	print("join -> ", client.call("join", ticket, CLIENT_NAME, ""))
	if _wait(client, ["\"type\":\"welcome\"", CLIENT_NAME], 60000).is_empty():
		failures.append("the client never joined")
	# A frame that reaches a client before it is welcomed has nobody's name to carry; waiting for
	# the host to hear the join is what makes the uplink send into a live session.
	if _wait(host, ["\"type\":\"joined\"", CLIENT_NAME], 30000).is_empty():
		failures.append("the host never heard the join")

	# 2. The round trip. The host speaks a tone; the gate, the coder, the wire and the decoder
	#    do the rest.
	var sent: int = _speak(host, FRAMES)
	print("host sent:      ", sent, " frame(s)")
	if sent < 1:
		failures.append("a loud tone opened no gate; %d frame(s) encoded" % sent)

	var received: PackedFloat32Array = _collect(client, sent * FRAME, 30000)
	var peak := 0.0
	for sample in received:
		peak = maxf(peak, absf(sample))
	print("client decoded: ", received.size(), " sample(s), peak ", peak)
	if received.size() == 0:
		failures.append("no voice reached the client")
	elif peak < 0.02:
		failures.append("the decoded voice is near-silent (peak %f)" % peak)

	# 3. The counters: the codec's own tallies, so the frames are known to have crossed rather
	#    than merely not to have errored.
	var host_state: Dictionary = JSON.parse_string(String(host.call("voice_state")))
	var client_state: Dictionary = JSON.parse_string(String(client.call("voice_state")))
	print("host state:     ", host_state)
	print("client state:   ", client_state)
	if int(host_state.get("sent", 0)) < sent:
		failures.append("the host's codec does not account for its own frames: %s" % host_state)
	if int(client_state.get("decoded", 0)) < 1:
		failures.append("the client's codec decoded nothing: %s" % client_state)

	# 4. The mute. The client's gain goes to 0, the host speaks again, and the *same* tone has to
	#    arrive and decode -- `decoded` must rise -- while every sample handed back is zero. That
	#    is what keeps this from passing on a client that simply heard nothing.
	client.call("set_voice_gain", 0.0)
	var before: int = int(JSON.parse_string(String(client.call("voice_state"))).get("decoded", 0))
	var muted_sent: int = _speak(host, FRAMES)
	var muted: PackedFloat32Array = _collect(client, muted_sent * FRAME, 30000)
	var after: int = int(JSON.parse_string(String(client.call("voice_state"))).get("decoded", 0))
	var leaked := 0
	for sample in muted:
		if absf(sample) > 1e-6:
			leaked += 1
	print("muted:          ", muted.size(), " sample(s), ", after - before, " frame(s) decoded")
	if after <= before:
		failures.append("the muted window decoded no frames, so the mute check proves nothing")
	if muted.size() == 0:
		failures.append("the muted window produced no samples to inspect")
	elif leaked != 0:
		failures.append("the mute let %d sample(s) through" % leaked)
	# ...and the gain is a *gain*: put it back, so a later frame is heard again.
	client.call("set_voice_gain", 1.0)
	var restored: float = float(JSON.parse_string(String(client.call("voice_state"))).get("gain", 0.0))
	if absf(restored - 1.0) > 1e-6:
		failures.append("the gain did not come back to 1.0 (it is %f)" % restored)

	host.call("shutdown")
	client.call("shutdown")
	host.free()
	client.free()

	if failures.is_empty():
		print("OK: a tone crossed the session crate's own wire as Opus, decoded, and a mute silenced it")
		quit(0)
	else:
		for f in failures:
			print("FAIL: ", f)
		quit(1)

# Hand the host `frames` 20 ms blocks of a continuous 440 Hz tone, and answer how many the codec
# encoded. A continuous phase across blocks keeps the tone a tone rather than a click train.
func _speak(host: Object, frames: int) -> int:
	var total := 0
	var phase := 0.0
	var step := TAU * 440.0 / float(RATE)
	for _i in frames:
		var block := PackedFloat32Array()
		block.resize(FRAME)
		for j in FRAME:
			block[j] = sin(phase) * 0.3
			phase += step
		total += int(host.call("push_voice", block, RATE))
	return total

# Drain the client's decoder until `want` samples have arrived or the timeout passes. The mix is
# at the wire's rate, so `want` is a sample count rather than a duration.
func _collect(client: Object, want: int, timeout_ms: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while out.size() < want and Time.get_ticks_msec() < deadline:
		out.append_array(client.call("pull_voice", FRAME * 8))
		OS.delay_msec(10)
	return out

# Poll a bridge until one line contains every needle, or the timeout passes. Copied from
# `verify_net.gd`: lines are buffered per bridge, because the one being waited for may share a
# poll batch with one that is not.
func _wait(bridge: Object, needles: Array, timeout_ms: int) -> String:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	var buffer: Array = []
	while true:
		for line in buffer:
			if _has_all(String(line), needles):
				return String(line)
		if Time.get_ticks_msec() >= deadline:
			return ""
		for line in bridge.call("poll_events"):
			buffer.append(line)
		OS.delay_msec(20)
	return ""

func _has_all(line: String, needles: Array) -> bool:
	for needle in needles:
		if not line.contains(needle):
			return false
	return true

# The interop gate: a Godot client joining the *shipping* host, `goatsd`.
#
#   GOATSD_TICKET=<ticket> GOATSD_EXPECT=join|refuse|pull \
#     Godot --headless --path godot --script res://tools/verify_interop.gd
#
# `interop.sh` starts a real `goatsd` and runs this against it; the script itself
# only needs the ticket, so it can also be pointed at a server someone else is
# running. Three modes, because all three outcomes are evidence:
#
#   join    -- `goatsd --no-mods` requires no world mods, so a client with none
#              joins: a welcome, the roster, a chat echo, and the server's world
#              arriving as datagrams.
#   refuse  -- `goatsd` run against the repository's `mods/` requires its world
#              mods, so a client presenting none is refused *by digest*. That
#              refusal crossing two independent implementations is the
#              compatibility handshake (`APIv1.md` section 6.3) working, and it
#              is the failure mode a player actually hits.
#   pull    -- the *same* modded host and the *same* modless client, but with the
#              fetch consented to (M18d): the client asks the host what it runs,
#              `crates/pull` verifies and installs the archive into a directory of
#              its own, and the retried join is accepted. The archive is hashed
#              back to the digest the host announced, so the retry's set is the
#              host's rather than a re-derived approximation (`APIv1.md` section
#              6.2). The pull directory is under `user://` and is wiped first, so a
#              previous run cannot make the fetch a no-op.
#
# The client is a bare `NetBridge` with no `ModHost` behind it, so it presents
# *nothing* -- which is precisely the case `refuse` and `pull` need.
extends SceneTree

## The prefix `crates/pull`'s `PREFIX` gives an installed archive, so a pulled file is recognised
## without a second copy of the loader's naming here.
const PULL_PREFIX := "pulled-"
## Where a `pull` mode installs: a Godot path, globalised before it reaches the bridge (which
## writes it with `std::fs`). Wiped at the start of the mode.
const PULL_URI := "user://interop-pull"

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
	# The third argument is the world-mod set this client presents. A bare `NetBridge` has no
	# `ModHost` behind it, so it presents *nothing* -- which is precisely the case `refuse` and
	# `pull` need, and the reason `join` runs a host that requires nothing (`interop.sh --no-mods`).
	# The scene is the one that presents the real set (`main.gd`'s verbs, `interop.sh herd`).

	if expect == "refuse":
		print("join -> ", bridge.call("join", ticket, "godot", "", false))
		var refusal: String = _wait(bridge, ["\"type\":\"error\""], 60000)
		print("refusal: ", refusal)
		if refusal.is_empty():
			failures.append("a client with no world mods was not refused")
		elif not refusal.contains("mod"):
			failures.append("the refusal does not name mods: " + refusal)
		_shutdown(bridge)
		_report(failures, "the host refused the join by mod digest")
		return

	# `pull`: the same modded host and the same modless client, plus the consent. The directory is
	# the bridge's to install into and this gate's to point at `user://`; the bridge re-derives its
	# world-mod set from what lands there, so the retry presents the host's own set.
	if expect == "pull":
		var dir: String = ProjectSettings.globalize_path(PULL_URI)
		_wipe(PULL_URI)
		DirAccess.make_dir_recursive_absolute(PULL_URI)
		bridge.call("set_pull", dir, true)
		print("pull dir: ", dir)
		print("join -> ", bridge.call("join", ticket, "godot", "", true))
		var pulled: String = _wait(bridge, ["\"type\":\"pulled\""], 90000)
		if pulled.is_empty():
			var failed: String = _search(["\"type\":\"error\""])
			failures.append("the refusal did not fetch and install the host's world mods: "
				+ (failed if not failed.is_empty() else "no pulled event in 90s"))
		else:
			print("pulled: ", pulled)
			_check_pull(pulled, PULL_URI, failures)
			# The retried join is accepted because the retry presents the *installed* set, which is
			# the host's -- the whole point of `pull::recover` re-deriving the digest off the disk.
			var welcome: String = _wait(bridge, ["\"type\":\"welcome\"", "godot"], 60000)
			print("welcome: ", welcome)
			if welcome.is_empty():
				failures.append("the retried join was not welcomed within 60s")
		_shutdown(bridge)
		_report(failures, "a client with no world mods fetched the host's, installed them and joined")
		return

	print("join -> ", bridge.call("join", ticket, "godot", "", false))

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

# `pull`'s check: the event named what arrived, and a verified archive is on disk. The archive
# is there only because `crates/pull` loaded it with the same loader the digest comes from and
# found its id, version and hash equal to the ones the host announced -- a mismatch is discarded,
# never installed -- so the *presence* of the file is the verification's own evidence.
func _check_pull(line: String, uri: String, failures: Array) -> void:
	var event: Variant = JSON.parse_string(line)
	if not (event is Dictionary):
		failures.append("the pulled event is not JSON: " + line)
		return
	var text: String = String((event as Dictionary).get("text", ""))
	var ids: Variant = (event as Dictionary).get("ids", [])
	print("pulled text: ", text)
	print("pulled ids:  ", ids)
	if not text.begins_with("pulled "):
		failures.append("the pulled event does not describe the fetch: " + text)
	if not (ids is Array) or (ids as Array).is_empty():
		failures.append("the pulled event names no mods: " + line)
		return
	var handle: DirAccess = DirAccess.open(uri)
	if handle == null:
		failures.append("the pull directory does not exist: " + uri)
		return
	var found: Array = []
	for name in handle.get_files():
		if String(name).begins_with(PULL_PREFIX):
			found.append(String(name))
	print("installed:   ", found)
	if found.size() != (ids as Array).size():
		failures.append("%d archive(s) for %d named mod(s)" % [found.size(), (ids as Array).size()])
	for id in ids:
		if not found.has(PULL_PREFIX + String(id) + ".zip"):
			failures.append("no verified archive landed for " + String(id))

# Remove a `user://` directory tree first, so a previous run's archive cannot make this run's
# fetch a no-op (a client that already has the host's set is not refused, so nothing would pull).
func _wipe(uri: String) -> void:
	var dir: DirAccess = DirAccess.open(uri)
	if dir == null:
		return
	for name in dir.get_directories():
		_wipe(uri.path_join(name))
	for name in dir.get_files():
		DirAccess.remove_absolute(uri.path_join(name))
	DirAccess.remove_absolute(uri)

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

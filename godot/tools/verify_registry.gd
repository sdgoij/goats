# The registry gate: two bridges, one catalogue, a share, a fetch and a mirror.
#
#   Godot --headless --path godot --script res://tools/verify_registry.gd
#
# The Rust `registry` tests cover the catalogue, the transfer and the mirror budget;
# this is the port's own surface. `set_registry` starts a catalogue once the loader
# has found the mods directory (the runtime thread is up before that), `mods_share`
# imports a tree and announces it, `mods_peer` seeds the second catalogue with the
# first's ticket, and `mods_fetch`/`mods_mirror` install and keep the package. The
# `mod registry` notice is the only list, so the gate reads the event lines.
#
# No swarm: the seed is handed over directly, so the gate is fast and deterministic.
# The swarm-carried ticket has its own Rust test (`session::swarm`), and the game
# path that uses it is wired in `run`'s `SwarmEvent::Registry` arm.
extends SceneTree

const MOD_ID := "com.example.registry"
const MOD_VERSION := "1.0.0"
const MOD_JSON := "{\"id\":\"com.example.registry\",\"name\":\"Registry\",\"version\":\"1.0.0\",\"api\":1,\"side\":\"world\",\"entry\":\"mod.js\"}"
const MOD_JS := "1;\n"

var _buffers := {}

## The most recent line matching every needle, or "". Buffers are per instance so a
## line that arrives in the same batch as the one being waited for is not lost.
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

## A clean `user://` mods directory. The registry's store lives under it as
## `.registry`, which discovery skips because it has no `mod.json` of its own.
func _mods_dir(name: String) -> String:
	var path: String = ProjectSettings.globalize_path("user://registry-gate-%s/mods" % name)
	_remove_tree(path)
	DirAccess.make_dir_recursive_absolute(path)
	return path

func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child: String = path.path_join(name)
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _initialize() -> void:
	if not ClassDB.class_exists("NetBridge"):
		print("FAIL: NetBridge is not registered - the GDExtension did not load")
		quit(1)
		return

	var failures: Array[String] = []
	var a_dir: String = _mods_dir("a")
	var b_dir: String = _mods_dir("b")
	# Discovery looks at immediate subdirectories with a `mod.json`, so the fixture
	# is a mod directory under the mods root, exactly as a real one is.
	var mod_dir: String = a_dir.path_join(MOD_ID)
	DirAccess.make_dir_recursive_absolute(mod_dir)
	_write(mod_dir.path_join("mod.json"), MOD_JSON)
	_write(mod_dir.path_join("mod.js"), MOD_JS)

	var a: Object = ClassDB.instantiate("NetBridge")
	var b: Object = ClassDB.instantiate("NetBridge")
	a.call("set_pull", a_dir, false)
	b.call("set_pull", b_dir, false)

	# 1. The first catalogue starts and prints its ticket; the fixture is shared.
	print("a registry -> ", a.call("set_registry", a_dir))
	var ticket_line: String = _wait(a, ["registry: ticket "], 30000)
	if ticket_line.is_empty():
		failures.append("the first registry never printed a ticket")
	var ticket: String = ""
	if not ticket_line.is_empty():
		var event: Dictionary = JSON.parse_string(ticket_line)
		var text: String = String(event.get("text", ""))
		var at: int = text.find("registry: ticket ")
		ticket = text.substr(at + "registry: ticket ".length())
		print("registry seed: ", ticket.substr(0, 16), "...")
	print("a share -> ", a.call("mods_share"))
	if _wait(a, ["registry: shared 1"], 30000).is_empty():
		failures.append("the fixture was not shared")

	# 2. The second catalogue starts, is seeded with the first's ticket, and lists the
	#    record. The first restates it on the new neighbour, so this is a second or two.
	print("b registry -> ", b.call("set_registry", b_dir))
	if _wait(b, ["registry: ticket "], 30000).is_empty():
		failures.append("the second registry never printed a ticket")
	print("b peer -> ", b.call("mods_peer", ticket))
	var found: String = ""
	var deadline: int = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		b.call("mods_registry")
		found = _wait(b, ["registry:", MOD_ID], 2000)
		if not found.is_empty():
			break
	if found.is_empty():
		failures.append("the second catalogue never listed the fixture")
	else:
		print("catalogue: ", found)

	# 3. Fetch: the package crosses iroh from the first bridge, is verified and lands as
	#    `pulled-<id>/` beside the second bridge's own mods.
	print("b fetch -> ", b.call("mods_fetch", MOD_ID, MOD_VERSION))
	var pulled: String = _wait(b, ["\"type\":\"pulled\""], 60000)
	if pulled.is_empty():
		failures.append("the fetch never installed the fixture")
	else:
		print("pulled: ", pulled)
		var installed: String = b_dir.path_join("pulled-" + MOD_ID).path_join("mod.json")
		if not FileAccess.file_exists(installed):
			failures.append("the fetched tree is missing its mod.json")

	# 4. Mirror: the bytes are already local, so this pins and announces them. The
	#    catalogue then reports the mirror, which is the console's `mod registry` view.
	print("b mirror -> ", b.call("mods_mirror", MOD_ID, MOD_VERSION))
	var mirrored: String = _wait(b, ["registry: mirroring " + MOD_ID], 30000)
	if mirrored.is_empty():
		failures.append("the mirror never reported the package")
	else:
		print("mirrored: ", mirrored)
	var status: String = ""
	deadline = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		b.call("mods_registry")
		status = _wait(b, ["mirroring 1"], 2000)
		if not status.is_empty():
			break
	if status.is_empty():
		failures.append("the catalogue does not report the mirror")
	else:
		print("mirror status: ", status)

	# `shutdown` closes the channel and joins the runtime thread, which a process that
	# quits with a live endpoint does not do safely.
	a.call("shutdown")
	b.call("shutdown")
	a.free()
	b.free()

	if failures.is_empty():
		print("OK: a catalogue is shared, fetched and mirrored through the port's own registry")
		quit(0)
		return
	for failure: String in failures:
		print("FAIL: ", failure)
	quit(1)

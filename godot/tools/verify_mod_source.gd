# The memory-source gate: a mod that never touches a filesystem is discovered,
# validated, run, edited and reloaded through the same `crates/mods` parser the
# desktop loader uses.
#
#   Godot --headless --path godot --script res://tools/verify_mod_source.gd
#
# This is the browser's and the editor's path: `mods.gd` reads `user://mods` and
# hands the host a dictionary of manifest-relative names to bytes. Running it
# natively is the point -- the parser is platform-independent, so a gate can hold
# it without a tab, and the wasm build then only has to move the bytes.
extends SceneTree

const ID := "com.example.memory"
const ASSET := "mod:com.example.memory:model.memory.bin"

var failures: Array[String] = []

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")

	# 1. Discovery from a dictionary. No directory, no zip, no path.
	var answer: String = host.call("load_mod_files", "memory", _files("ok memory one"))
	print("load_mod_files -> ", answer)
	if answer != "ok " + ID:
		failures.append("load_mod_files answered '%s'" % answer)

	# 2. The table carries the manifest the map declared, before the entry runs.
	var table: Variant = JSON.parse_string(host.call("mods_json"))
	if not (table is Array) or (table as Array).is_empty():
		failures.append("mods_json is not a non-empty array: " + str(table))
	else:
		var row: Dictionary = table[0]
		if String(row.get("id", "")) != ID:
			failures.append("the table names '%s'" % row.get("id", ""))
		if String(row.get("side", "")) != "client":
			failures.append("the table says side '%s'" % row.get("side", ""))
		var slots: Variant = row.get("assets", {})
		if not (slots is Dictionary) or String(slots.get("model.memory", "")) != ASSET:
			failures.append("the declared asset did not reach the table: " + str(slots))

	# 3. The entry runs in its own `goats.begin(id)` window and registers a verb.
	var loaded: String = host.call("load_all")
	print("load_all -> ", loaded)
	if not loaded.contains("loaded " + ID):
		failures.append("the entry did not load: " + loaded)
	var reply: String = host.call("run_command", "memory", "hello")
	print("memory -> ", reply)
	if reply != "ok memory one":
		failures.append("expected 'ok memory one', got '%s'" % reply)

	# 4. The declared asset is addressable by its opaque name, with its bytes.
	var names: PackedStringArray = host.call("asset_names")
	print("assets: ", names)
	if not names.has(ASSET):
		failures.append("the asset is not registered under '%s'" % ASSET)
	var bytes: PackedByteArray = host.call("asset_bytes", ASSET)
	if bytes != PackedByteArray([1, 2, 3, 4]):
		failures.append("the asset bytes did not survive the memory source")

	# 5. A live edit replaces the same id and re-runs the entry: the old verb is
	#    gone (the new one answers) and the old instance was torn down first.
	var reloaded: String = host.call("reload_mod_files", "memory", _files("ok memory two"))
	print("reload_mod_files -> ", reloaded)
	if not reloaded.begins_with("ok mod reload "):
		failures.append("reload_mod_files answered '%s'" % reloaded)
	var edited: String = host.call("run_command", "memory", "hello")
	print("memory after edit -> ", edited)
	if edited != "ok memory two":
		failures.append("expected 'ok memory two', got '%s'" % edited)
	var after: Variant = JSON.parse_string(host.call("mods_json"))
	if not (after is Array) or (after as Array).size() != 1:
		failures.append("an edit is not a second copy: " + str(after))

	# 6. A source that does not validate is refused *before* the running instance
	#    is touched, so a half-written edit keeps the mod that is already loaded.
	var bad: Dictionary = _files("ok memory three")
	bad.erase("mod.json")
	var refused: String = host.call("reload_mod_files", "memory", bad)
	print("refused -> ", refused)
	if not refused.begins_with("error "):
		failures.append("a source without mod.json was not refused: " + refused)
	var still: String = host.call("run_command", "memory", "hello")
	if still != "ok memory two":
		failures.append("a refused edit disturbed the running mod: '%s'" % still)

	host.free()

	if failures.is_empty():
		print("OK: a mod discovered from memory loads, runs, edits and reloads like a directory mod")
		quit(0)
	else:
		for failure in failures:
			print("FAIL: ", failure)
		quit(1)

## The same three files a `user://mods/memory/` directory would hold: the
## manifest, the entry and one binary asset. The entry's answer is JSON-quoted so
## the fixture cannot produce invalid JavaScript.
static func _files(reply: String) -> Dictionary:
	var manifest := JSON.stringify({
		"id": ID,
		"name": "Memory Mod",
		"version": "1.0.0",
		"api": 1,
		"side": "client",
		"description": "loaded from memory",
		"entry": "mod.js",
		"assets": {"model.memory": "asset.bin"},
	})
	var entry := (
		"goats.command(\"memory\", function () { return " + JSON.stringify(reply) + "; });\n"
	)
	return {
		"mod.json": manifest.to_utf8_buffer(),
		"mod.js": entry.to_utf8_buffer(),
		"asset.bin": PackedByteArray([1, 2, 3, 4]),
	}

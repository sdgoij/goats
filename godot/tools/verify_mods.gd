# The mod-runtime gate: proves the extension discovers, validates, orders and
# loads the repository's real mods through `crates/mods`, and that a loaded
# mod's calls reach back into Godot.
#
#   Godot --headless --path godot --script res://tools/verify_mods.gd
#
# It reads the actual `mods/` directory at the repository root -- the same one
# the raylib client loads -- and drives the checked-in example mod end to end.
# A non-zero exit makes it usable as a gate.
extends SceneTree

const EXAMPLE_ID := "com.github.sdgoij.goats.hello"

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var mods_dir: String = ProjectSettings.globalize_path("res://") \
		.path_join("../mods").simplify_path()
	print("mods dir: ", mods_dir)

	# 1. Discovery, by the loader crate. Nothing is executed yet.
	var found: String = host.call("load_mods", mods_dir)
	print("load_mods -> ", found)
	if not found.begins_with("5 mod(s)"):
		failures.append("expected 5 mods discovered, got: " + found)

	# 2. The metadata table the core would hand the scene, in load order.
	var table_json: String = host.call("mods_json")
	var table: Variant = JSON.parse_string(table_json)
	if not (table is Array):
		failures.append("mods_json is not a JSON array: " + table_json)
	else:
		var ids: Array = []
		for entry in table:
			ids.append(entry["id"])
		print("load order: ", ids)
		if ids.size() != 5:
			failures.append("expected 5 table entries, got %d" % ids.size())
		if not ids.has(EXAMPLE_ID):
			failures.append("the example mod is missing from the table")

	# 3. Load the example mod: its assets are taken, then its entry runs inside
	#    its own `goats.begin(id)` scope.
	var loaded: String = host.call("load_mod", EXAMPLE_ID)
	print("load_mod -> ", loaded)
	if not loaded.begins_with("loaded "):
		failures.append("the example mod did not load: " + loaded)
	elif not loaded.contains("2 asset(s)"):
		failures.append("expected the mod's 2 declared assets, got: " + loaded)

	# 4. The command it registered with `goats.command` runs, and its reply
	#    comes back through the host.
	var reply: String = host.call("run_command", "hello", "hello world")
	print("hello -> ", reply)
	if reply != "ok hello world":
		failures.append("expected 'ok hello world', got '%s'" % reply)

	# 5. An unknown command is absent, not an error.
	var missing: String = host.call("run_command", "no-such-command", "x")
	if missing != "":
		failures.append("an unknown command should answer '', got '%s'" % missing)

	# 6. The HUD hook reads the clock the core pushed and draws through `goats.draw`
	#    (`APIv1.md` section 4.18), which the extension queues as a *record* for the scene's
	#    `ModHud` to paint. The mod formats 14.5 as "14:30".
	host.call("set_world_time", 14.5)
	host.call("emit_hud", 1280.0, 720.0)
	var drawn: PackedStringArray = host.call("poll_draws")
	print("the HUD hook produced ", drawn.size(), " draw(s):")
	for line in drawn:
		print("  ", line)
	var saw_clock := false
	for line in drawn:
		var record: Variant = JSON.parse_string(String(line))
		if not (record is Dictionary):
			failures.append("a draw record is not JSON: " + String(line))
			continue
		if String(record.get("k", "")) != "text" \
				or not String(record.get("s", "")).contains("example mod") \
				or not String(record.get("s", "")).contains("14:30"):
			continue
		saw_clock = true
		# The colour is the API's own `{r, g, b, a}` in 0..255 -- opaque data a platform
		# is free to represent its own way, which is what lets one mod draw on both ends.
		var col: Variant = record.get("col", null)
		if not (col is Dictionary) or int(col.get("r", 0)) != 255:
			failures.append("the draw's colour did not cross as the API's own shape")
	if not saw_clock:
		failures.append("the HUD hook did not draw the clock through goats.draw")

	# 7. A mod's assets are addressed by an opaque name, never a path
	#    (`APIv1.md` section 0). The loader's names look like `mod:<id>:<file>`.
	var assets: PackedStringArray = host.call("asset_names")
	print("assets: ", assets)
	if assets.size() != 2:
		failures.append("expected 2 assets by opaque name, got %d" % assets.size())
	for name in assets:
		if not name.begins_with("mod:"):
			failures.append("an asset name is not opaque: " + name)
		if name.contains("/") or name.contains("\\"):
			failures.append("an asset name carries a path separator: " + name)

	host.free()

	if failures.is_empty():
		print("OK: the loader loads the repository's mods and the example runs end to end")
		quit(0)
	else:
		for f in failures:
			print("FAIL: ", f)
		quit(1)

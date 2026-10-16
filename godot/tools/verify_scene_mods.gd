# The scene's mod-runtime gate: what `verify_mods.gd` cannot reach because it drives the host
# directly -- that the *scene* runs the mods, tells the truth about the ones that threw, hands the
# Mods screen a list to draw, and gives a mod's own verb the console.
#
#   Godot --headless --path godot --script res://tools/verify_scene_mods.gd
#
# `verify_mods.gd` proves the extension's half against the repository's real `mods/` directory:
# discovery, manifests, ordering, assets, the example's entry, its command, its HUD hook and the
# opaque asset names. This gate is stage 1's other half -- `mods.gd` and the two seams `main.gd`
# wires (`commands.mods`, `menu.mods_list`) -- and it is the one that would catch a runtime loaded
# by nothing, which is exactly what the port had before this stage: every host check passed while
# a player's game loaded no mods at all.
#
# Four things are held, and each is a failure the direct host check cannot see:
#
#   1. **The scene owns a runtime**, read from the *live* scene rather than built here.
#   2. **The table is truthful.** `birds` is a world mod whose entry calls a surface member the
#      port has not built (`goats.mod`), so it throws; the host must mark it `failed` with the
#      error, and leave the four that loaded unmarked. A table that says five healthy mods is the
#      lie `mods.js`'s `sceneModResult` exists to prevent.
#   3. **The Mods screen draws it.** `menu.js`'s screen is a row per mod plus an Enable/Disable
#      button, and its "no mods found" line when the list is empty -- so the layout is asserted,
#      not the table: a screen fed a table it does not draw is a screen a player cannot read.
#   4. **The vocabulary reaches the mods both ways**: a mod's `hello` verb answers through the
#      console's own dispatch, and `mod list` / `mod key` answer from the host's table.
extends SceneTree

## The example mod's id and command, from `verify_mods.gd` -- the one mod in the repository whose
## entry both loads and registers a verb.
const EXAMPLE_ID := "com.github.sdgoij.goats.hello"
## The world mod in the repository: the one whose entry throws today, because it reads `goats.mod`
## (`mods/birds/mod.js:26`) and the port's `goats` handle has no `mod` member yet (stage 8).
const WORLD_ID := "com.github.sdgoij.goats.birds"
## How many mods the repository's `mods/` holds. Named so a directory that grows fails loudly
## rather than silently changing what this gate checked.
const MOD_COUNT := 5

var _failures: Array[String] = []
var _frames := 0
var _main: Node

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return
	# The scene is instantiated here and *read* a few frames later: `SceneTree.root` is not inside
	# the tree while `_initialize` runs (the trap `verify_console.gd` names).
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	_check()
	if _failures.is_empty():
		print("OK: the scene runs the mods, names the one that threw, and draws them")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	# 1. The runtime, as the scene built it.
	var mods: Object = _main.get("mods")
	if mods == null:
		_failures.append("the scene has no Mods runtime")
		return
	var host: Object = mods.get("host")
	if host == null:
		_failures.append("the scene's mod runtime has no host node")
		return

	var table: Array = mods.call("mod_table")
	print("mods dir: ", mods.get("dir"))
	print("table: ", table.size(), " row(s)")
	for meta: Dictionary in table:
		var note: String = ""
		if bool(meta.get("failed", false)):
			note = "  FAILED: " + String(meta.get("error", ""))
		print("  ", meta.get("id"), " v", meta.get("version"), " [", meta.get("side"), "]", note)
	if table.size() != MOD_COUNT:
		_failures.append("the table has %d row(s), the directory holds %d" % [table.size(), MOD_COUNT])

	# 2. The truth about the one that threw. A probe re-proves it rather than trusting the file
	#    system: the scene's own load is what the table describes.
	var failed := 0
	for meta: Dictionary in table:
		if not bool(meta.get("failed", false)):
			if String(meta.get("error", "")) != "":
				_failures.append("%s is not failed but carries an error" % meta.get("id"))
			continue
		failed += 1
		if String(meta.get("error", "")).is_empty():
			_failures.append("%s is failed with no error to show" % meta.get("id"))
	print("failed: ", failed, " of ", table.size())
	if not _has_id(table, WORLD_ID, true):
		_failures.append("%s should be listed as failed - its entry reads a surface member the port has not built" % WORLD_ID)
	if not _has_id(table, EXAMPLE_ID, false):
		_failures.append("%s should have loaded" % EXAMPLE_ID)

	# 3. The screen draws the list. The Mods panel is a row per mod plus a button each, and the
	#    failed row's label names the failure -- which is what a player actually reads.
	var menu: Object = _main.get("menu")
	menu.call("show_screen", "mods")
	var widgets: Array = menu.call("layout", Vector2(1280.0, 720.0))
	var labels := 0
	var buttons := 0
	var saw_failed := false
	var saw_empty := false
	for widget: Dictionary in widgets:
		var text: String = String(widget.get("text", ""))
		if String(widget.get("kind", "")) == "label":
			labels += 1
			if text.contains("FAILED"):
				saw_failed = true
			if text.contains("no mods found"):
				saw_empty = true
		elif String(widget.get("kind", "")) == "button":
			buttons += 1
	print("mods screen: ", labels, " label(s), ", buttons, " button(s)")
	if saw_empty:
		_failures.append("the Mods screen still draws \"no mods found\" with %d mod(s) loaded" % table.size())
	if not saw_failed:
		_failures.append("no Mods row names the failed mod")
	# One label and one button per mod, plus the note label, plus Back.
	if labels != table.size() + 1 or buttons != table.size() + 1:
		_failures.append("the Mods screen is %d label(s) and %d button(s) for %d mod(s)"
			% [labels, buttons, table.size()])
	menu.call("show_screen", "hud")

	# 4. The vocabulary, both ways. A mod's verb first refusal is the console's own dispatch.
	var vocabulary: Object = _main.get("commands")
	var modded: String = String(vocabulary.call("run", "hello world"))
	print("hello ->        ", modded)
	if modded != "ok hello world":
		_failures.append("the example mod's verb did not answer through the console: '%s'" % modded)
	var listed: String = String(vocabulary.call("run", "mod list"))
	print("mod list ->     ", listed.substr(0, 40), "...")
	if not listed.begins_with("ok ["):
		_failures.append("`mod list` did not answer the table: '%s'" % listed)
	var key: String = String(vocabulary.call("run", "mod key"))
	print("mod key ->      ", key)
	if not key.contains(WORLD_ID + "@"):
		_failures.append("`mod key` does not name the world mod's digest: '%s'" % key)

	# The HUD hook, driven explicitly: the frame's own call depends on the node's `_process`, and
	# a gate that relied on that would check the engine's scheduling rather than the mod.
	mods.call("frame", 14.5, Vector2(1280.0, 720.0), true, _main.get_node("Camera3D"))
	var draws: int = int(mods.get("draws"))
	print("hud hook draws: ", draws)
	if draws < 1:
		_failures.append("the example mod's HUD hook made no draws through goats.draw")

	# ...and the draws reached the control that paints them, in the API's own shape. This is the
	# half the old `rl` shim could not do: a mod's drawing is *painted*, not counted.
	var surface: Control = _main.get("mod_hud")
	var commands: Array = surface.get("commands")
	print("surface: ", commands.size(), " command(s), ", surface.get("paints"), " paint(s)")
	if commands.is_empty():
		_failures.append("the mod's draw never reached ModHud")
	else:
		var first: Dictionary = commands[0]
		if String(first.get("k", "")) != "text":
			_failures.append("ModHud's first command is not the text the mod drew: %s" % first)
		elif not String(first.get("s", "")).contains("example mod"):
			_failures.append("ModHud's text is not the mod's: %s" % first)
	if int(surface.get("paints")) < 1:
		_failures.append("ModHud adopted the mod's draws and never painted them")

	# And the load report reached the player's console, which is the only place a failed mod is
	# ever said out loud in a running game.
	var console: Object = _main.get("console")
	var said := false
	for line: Dictionary in console.get("lines"):
		if String(line.get("text", "")).contains("hello") \
				and String(line.get("text", "")).contains("asset"):
			said = true
	if not said:
		_failures.append("the load report never reached the console")

func _has_id(table: Array, id: String, failed: bool) -> bool:
	for meta: Dictionary in table:
		if String(meta.get("id", "")) == id:
			return bool(meta.get("failed", false)) == failed
	return false

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
# Five things are held, and each is a failure the direct host check cannot see:
#
#   1. **The scene owns a runtime**, read from the *live* scene rather than built here.
#   2. **The table is truthful**, which now means that *every* repository mod loads. `birds` used to
#      be the worked example of a named failure -- its entry read the engine's `rl`, which this build
#      has no copy of -- and the rework took that away, so a failed row is a regression here rather
#      than the expected state. The failure *path* is not dropped with it: step 5 stages a mod whose
#      entry throws and holds the host to naming it, because a table that called a broken mod fine
#      is the lie `mods.js`'s `sceneModResult` exists to prevent.
#   3. **The Mods screen draws it.** `menu.js`'s screen is a row per mod plus an Enable/Disable
#      button, and its "no mods found" line when the list is empty -- so the layout is asserted,
#      not the table: a screen fed a table it does not draw is a screen a player cannot read.
#   4. **The vocabulary reaches the mods both ways**: a mod's `hello` verb answers through the
#      console's own dispatch, and `mod list` / `mod key` answer from the host's table.
#   5. **A mod that throws is named**, on a fixture this gate writes at run time rather than ships --
#      see `_check_staged_failure`, which also records the one thing that surprises: the host is
#      Rust and reads with `std::fs`, so `user://` has to be globalised before it is handed over.
extends SceneTree

## The example mod's id and command, from `verify_mods.gd` -- the one mod in the repository whose
## entry both loads and registers a verb.
const EXAMPLE_ID := "com.github.sdgoij.goats.hello"
## The world mod in the repository. It is the one this gate used to expect to *fail*, because it read
## the engine's `rl`; it is now API-only and loads, which is why the expected count below is zero.
const WORLD_ID := "com.github.sdgoij.goats.birds"
## How many mods the repository's `mods/` holds. Named so a directory that grows fails loudly
## rather than silently changing what this gate checked.
const MOD_COUNT := 5
## When the flock is sent into the air, and when the gate looks at it: the difference is the sim
## time `TAKEOFF` needs (0.9 s at the engine's own 60 Hz, with room for a slow first frame), and it
## is frames of the *scene's* clock rather than a sleep. See `_process`.
const KICK_FRAME := 4
const FLY_FRAME := 150

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
	if _frames == KICK_FRAME:
		# The flock is sent into the air through its own console verb, and then the **scene's** frames
		# are left to run: `update` is fired by `main.gd`'s `_process`, so driving `mods.frame` from
		# here would prove the runtime's forwarding and not the scene's wiring. `TAKEOFF` runs 0.9 s,
		# which is why the wait below is `FLY_FRAME` frames rather than two.
		print("birds fly ->    ", String(_main.get("commands").call("run", "birds fly")))
		return false
	if _frames < FLY_FRAME:
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
	# Every one of the repository's own mods loads now, and that is worth asserting rather than
	# merely tolerating. `birds` used to be the worked example of a *named* failure -- it read the
	# engine's `rl`, which this build has no copy of -- and the rework took that away (`ROADMAP.md`
	# M14d's sixth pin move), so a failed row here is now a regression in one of the checked-in
	# mods rather than the expected state. The failure path itself is not dropped: step 6 stages a
	# mod that throws and holds the host to naming it.
	if failed != 0:
		_failures.append("%d of the repository's mod(s) failed to load, and they all load" % failed)
	if not _has_id(table, WORLD_ID, false):
		_failures.append("%s should have loaded" % WORLD_ID)
	if not _has_id(table, EXAMPLE_ID, false):
		_failures.append("%s should have loaded" % EXAMPLE_ID)

	# 3. The screen draws the list. The Mods panel is a row per mod plus a button each -- which is
	#    what a player actually reads -- and with every mod loading, no row says `FAILED`.
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
	if saw_failed:
		_failures.append("a Mods row says FAILED with every mod loaded")
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
	# 5. The events the examples live in, before the staged failure below replaces the loaded set.
	_check_events(vocabulary)
	# ...and what they *drew*, which is the half a headless run can still see and the half that was
	# wrong when they were first rewritten onto the API.
	_check_drawn(_main.get("mod_world"))

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

	# ...and the *example's* own `tuning.json` merged before its entry ran (`APIv1.md` section 3.4). Its
	# warning is the one thing about the merge a console line proves: `mods/example/tuning.json`
	# carries a deliberate typo, so a merge that ran *warned* about it -- and a merge that never ran
	# said nothing. Its declared `camera.dist` is the other half, and the boot camera reads it.
	var warned := false
	for line: Dictionary in console.get("lines"):
		if String(line.get("text", "")).contains("typo.notAThing"):
			warned = true
	if not warned:
		_failures.append("the example mod's declared tuning.json did not warn about its typo")
	if absf(Tuning.CAMERA_DIST - 6.5) > 1e-6:
		_failures.append("the example mod's tuning.json did not land: camera.dist is %s"
			% Tuning.CAMERA_DIST)
	if absf(float(_main.get("_cam_dist")) - 6.5) > 1e-6:
		_failures.append("the boot camera did not take the tree's camera.dist: %s"
			% _main.get("_cam_dist"))

	# 6. The failure path itself, on a mod the gate *stages*. Nothing in the repository fails any
	#    more, so the property this gate exists to hold -- a mod that throws is **named** rather than
	#    silently dropped, and the table the Mods screen draws carries the error -- would otherwise
	#    go unchecked. It goes through the host's own `load_mods`, which is the same door `mods.gd`
	#    uses at boot, and it is last because it replaces the loaded set.
	_check_staged_failure(host)
	_check_staged_reload(host)

## `APIv1.md` section 2.5: a mod read again from disk and run again -- `mod reload`, and the file
## watcher that does it on its own. Both need a mod whose *source* can change, so the gate stages
## one in its own directory (which replaces the set the staged failure left) and edits it between
## reloads. The entry answers with the version it was written with, which is what makes a re-read
## visible, and it declares a `tuning.json` that is merged again on the reload -- the one thing
## about a reload the *scene* owns rather than the host.
func _check_staged_reload(host: Object) -> void:
	var uri: String = "user://gates-hot/hot"
	DirAccess.make_dir_recursive_absolute(uri)
	var dir: String = ProjectSettings.globalize_path("user://gates-hot")
	var source := "goats.command(\"hot\", function () { return \"ok hot \" + V; });\n"
	var manifest: Dictionary = {
		"id": "com.example.hot", "name": "Hot", "version": "1", "api": 1,
		"side": "client", "entry": "mod.js", "tuning": "tuning.json",
	}
	if not _stage_file(uri + "/mod.json", JSON.stringify(manifest)):
		return
	# A `tuning.json` whose leaf is a whole number and nothing else touches, so the merge is visible
	# without moving the world under the checks above.
	if not _stage_file(uri + "/tuning.json", "{\"explosions\": {\"fx\": {\"debris\": {\"count\": 9}}}}"):
		return
	if not _stage_file(uri + "/mod.js", "const V = 1;\n" + source):
		return
	host.call("load_mods", dir)
	host.call("load_all")
	var mods: Object = _main.get("mods")
	# The scene's `table` is what its own `reload_mod` reads the id out of, and only `mods.gd`'s
	# boot path sets it -- so a host-side re-discovery has to hand it over.
	mods.set("table", Mods.parse_table(host.call("mods_json")))
	var first: String = str(host.call("run_command", "hot", "hot"))
	# 1. `mod reload`, through the scene's own path: its guard, its table read and its tuning merge.
	if not _stage_file(uri + "/mod.js", "const V = 2;\n" + source):
		return
	var reloaded: String = String(mods.call("reload_mod", "com.example.hot"))
	var second: String = str(host.call("run_command", "hot", "hot"))
	if not reloaded.begins_with("ok"):
		_failures.append("mod reload answered: " + reloaded)
	if first != "ok hot 1" or second != "ok hot 2":
		_failures.append("mod reload did not re-read the source: %s then %s" % [first, second])
	if Explosions.DEBRIS_COUNT != 9:
		_failures.append("mod reload did not merge the declared tuning: debris count is %s"
			% Explosions.DEBRIS_COUNT)
	# 2. The watcher (`GOATS_WATCH`'s own path, minus the knob): `notify` delivers on its own thread,
	#    and the host waits for the writes to settle, so this polls for as long as a save could take.
	if not String(host.call("watch_mods")).begins_with("ok"):
		_failures.append("watch_mods did not start")
	if not _stage_file(uri + "/mod.js", "const V = 3;\n" + source):
		return
	var fired := false
	for _i in range(30):
		OS.delay_msec(100)
		if not String(host.call("poll_watch")).is_empty():
			fired = true
			break
	var third: String = str(host.call("run_command", "hot", "hot"))
	if not fired:
		_failures.append("a watched change did not reload its mod")
	if third != "ok hot 3":
		_failures.append("the watcher's reload did not take: " + third)
	print("reload: ", first, " -> ", second, " -> ", third, "  (watch fired ", fired, ")")

## Write one staged file, or record the failure and answer `false`.
func _stage_file(path: String, text: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("could not stage " + path)
		return false
	file.store_string(text)
	file.close()
	return true

## The events the examples work through (`APIv1.md` section 6). `update` is the one both of them do
## everything in, and it is also the one a gate cannot prove by driving the runtime: `main.gd`'s
## `_process` fires it, so what this holds is the *scene's* wiring -- a flock sent into the air is
## only out of `takeoff` if the scene's own frames reached the handler, which is the difference
## between an event that arrived and one that ran.
func _check_events(vocabulary: Object) -> void:
	var flock: String = String(vocabulary.call("run", "birds"))
	print("birds ->        ", flock)
	var report: Variant = JSON.parse_string(flock.trim_prefix("ok "))
	if not (report is Dictionary):
		_failures.append("the flock did not report its state: '%s'" % flock)
		return
	var state: Dictionary = report
	if int(state.get("count", 0)) != 6:
		_failures.append("the flock is %s bird(s), and it seeds six" % state.get("count"))
	var counts: Dictionary = state.get("states", {})
	# `TAKEOFF` is 0.9 s of the flock's own clock, and only `update` advances it.
	if int(counts.get("fly", 0)) < 1:
		_failures.append("no bird left takeoff after %d frames (%s), so the `update` event did not reach the flock"
			% [_frames, counts])

## The two examples, **drawn** -- two things a headless run can still see, and both were wrong in
## the rework's first cut, in ways no other check here could catch because both leave the *simulation*
## working perfectly.
##
##   * A `mesh` record's handle is **any** handle (`APIv1.md` section 4.19): the flock's parts are
##     arrays it built, and the fat guy's body is a *model* it loaded. A client that asked only its
##     own mesh store for both drew no fat guy at all -- while he went on tripping devices.
##   * The axis-angle is **radians**. The flock handed its rotations over in degrees (raylib's unit,
##     which is what the engine call it replaced wanted), so every bird span like a rotor and not one
##     of them failed to fly.
func _check_drawn(world: Object) -> void:
	var fat := false
	var colours: Array[Color] = []
	for child in world.get_children():
		if not (child is Node3D):
			continue
		var node: Node3D = child
		# `has_meta` first, then `str`: `get_meta` reports an error for a key that is absent even when
		# it is handed a default, and `String(x)` is rejected outright for a `String` argument in
		# Godot 4.7 -- both are `_meta` in `mod_world.gd`, and both were found the hard way.
		if not node.has_meta("mod_kind") or str(node.get_meta("mod_kind")) != "model-mesh":
			continue
		if _meshes_under(node) > 0:
			fat = true
			colours = _surface_colours(node)
	# A rotation's canonical angle is at most a full turn, so a value past 2*PI is a unit error and
	# not a bird -- degrees are 57x, and six flying birds make it certain rather than likely.
	var worst := 0.0
	var records: Array = world.get("commands")
	for command: Dictionary in records:
		if not str(command.get("h", "")).begins_with("mesh:"):
			continue
		worst = maxf(worst, absf(float(command.get("angle", 0.0))))
	var shades: int = _distinct_colours(colours)
	print("drawn: fat guy ", fat, "  shades ", shades, "  flock records ", records.size(),
		"  largest angle ", worst)
	if not fat:
		_failures.append("the fat guy is not in the world: a `mesh` record with a model handle placed no meshes")
	# A model's look can *be* its materials, and the fat guy's is exactly that: his glTF has no
	# texture at all, only twelve `baseColorFactor`s, so a tint that replaced them with one flat
	# colour drew him white. Two distinct surface shades is the cheapest way to say the tint
	# multiplied into them (raylib's rule) instead of overwriting them.
	if fat and shades < 2:
		_failures.append("the fat guy's surfaces carry %d distinct shade(s), so the tint replaced his materials rather than multiplying into them" % shades)
	if worst > TAU + 1e-3:
		_failures.append("a mesh record's angle is %s, and an angle is at most a full turn (%s) -- degrees rather than radians?"
			% [worst, TAU])

## How many `MeshInstance3D` nodes an instance carries, at any depth. An imported model is a tree.
func _meshes_under(subtree: Node) -> int:
	var count := 0
	var stack: Array = [subtree]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			count += 1
	return count

## The albedo of every surface an instance's meshes have been tinted with, which is where
## `mod_world.gd`'s `_apply_tint` puts it (one override per surface).
func _surface_colours(subtree: Node) -> Array[Color]:
	var out: Array[Color] = []
	var stack: Array = [subtree]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mesh: MeshInstance3D = node
		var count: int = 0 if mesh.mesh == null else mesh.mesh.get_surface_count()
		for surface in count:
			var material: Material = mesh.get_surface_override_material(surface)
			if material is StandardMaterial3D:
				out.append((material as StandardMaterial3D).albedo_color)
	return out

## How many of a list's colours differ from each other, to within float32 -- the measure of
## whether a model kept its own shades.
func _distinct_colours(colours: Array[Color]) -> int:
	var seen: Array[Color] = []
	for colour in colours:
		var fresh := true
		for other in seen:
			if colour.is_equal_approx(other):
				fresh = false
				break
		if fresh:
			seen.append(colour)
	return seen.size()

## Two files written at run time into `user://`, and the host asked to load the directory: one mod
## whose entry throws on its first line. Staged rather than shipped because the repository's mods
## must all load, so a checked-in broken fixture would have to be *excluded* from the directory the
## game reads -- which is a worse lie than writing the two files here.
func _check_staged_failure(host: Object) -> void:
	var uri: String = "user://gates-broken/broken"
	DirAccess.make_dir_recursive_absolute(uri)
	# The *host* is Rust and reads the directory with `std::fs`, so it has to be handed a real path:
	# `user://` is Godot's own scheme and means nothing on that side of the boundary. (The error is
	# worth remembering -- it arrives as "cannot read the mods directory", not as a bad path.)
	var dir: String = ProjectSettings.globalize_path("user://gates-broken")
	var written: Array = [
		["mod.json", JSON.stringify({
			"id": "com.example.broken", "name": "Broken", "version": "1.0.0", "api": 1,
			"side": "client", "description": "staged by the gate: an entry that throws",
			"entry": "mod.js",
		})],
		["mod.js", "throw new Error(\"staged: this entry is meant to fail\");\n"],
	]
	for pair: Array in written:
		var file: FileAccess = FileAccess.open(uri + "/" + String(pair[0]), FileAccess.WRITE)
		if file == null:
			_failures.append("could not stage a broken mod (%s)" % pair[0])
			return
		file.store_string(String(pair[1]))
		file.close()
	print("staged: ", str(host.call("load_mods", dir)).strip_edges().replace("\n", "; "))
	print("staged: ", str(host.call("load_all")).strip_edges().replace("\n", "; "))
	var staged: Variant = JSON.parse_string(str(host.call("mods_json")))
	if not (staged is Array):
		_failures.append("the host's table did not answer after staging")
		return
	var named := false
	for meta: Dictionary in staged:
		if String(meta.get("id", "")) != "com.example.broken":
			continue
		if not bool(meta.get("failed", false)):
			_failures.append("a mod whose entry throws is not marked failed")
		elif String(meta.get("error", "")).is_empty():
			_failures.append("the failed mod carries no error to show")
		else:
			named = true
			print("staged failure: ", meta.get("error"))
	if not named:
		_failures.append("no staged mod was named as failed")

func _has_id(table: Array, id: String, failed: bool) -> bool:
	for meta: Dictionary in table:
		if String(meta.get("id", "")) == id:
			return bool(meta.get("failed", false)) == failed
	return false

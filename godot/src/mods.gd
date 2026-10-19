# The mod runtime, as the scene drives it: the extension's `ModHost` node, the directory its mods
# come from, and the things the rest of the scene asks of it.
#
# The split is `mods.js`'s, and it is the same split for the same reason. The *host* -- here the
# GDExtension over `crates/mods` and `crates/plugin`, and the embedded engine -- discovers,
# validates, orders, runs and drives; the *scene* owns the table the UI draws, the per-frame hooks
# a mod registered, the console's first refusal, and the one thing only it can know: whether there
# is a session. What the port does not have yet of `mods.js`'s other half is reload/watch and the
# asset-to-engine path. Those are stage 8 (`PORT.md` section 6, and section 10's third
# item); the writes the *scene* owns, and the enable/disable toggle (`set_enabled`, with its session
# guard), are in.
#
# The **readable surface** is this file's other job now (`APIv1.md` section 4.5-4.12): every frame
# the scene hands the host one JSON snapshot of the live world -- the goat, the camera, the
# weather and the wind, the herd, the settings, the session and the tuning tree -- and a mod reads
# those groups out of it. It is a *push*, not a callback, because `PORT.md` section 6 decision 3
# settled that a hot read should never touch the boundary: the scene already knows these values,
# so telling the extension once a frame is cheaper than answering per question and cannot invent a
# second copy of the world to drift from the first. The two things a push cannot carry -- a
# *function* of the world (`terrainHeight`) and a write -- go the other way, through the scene's
# own `Callable` (see `frame` and `_scene_call`).
#
# Three decisions worth naming, because each is a place the port deliberately stops short:
#
#   * **The table is the host's, and so is the failure.** A manifest is validated before anything
#     runs, so the *loader* cannot know that a mod's entry threw -- only the host that ran it can.
#     `ModHost::mods_json` therefore merges `failed`/`error` into the loader's table, which is
#     `mods.js`'s `sceneModResult` folded into `sceneMods`. Without it the Mods screen would draw
#     five healthy rows and the game would be lying about four of them.
#   * **A mod's `console.log` is a console line, and its draw is a record.** The two arrive on
#     different seams (`ModHost::poll_lines` and `ModHost::poll_draws`) because they are different
#     things: a log is text for the player and a draw is a primitive for the renderer, and keeping
#     them apart is what lets a mod's HUD be *painted* (`mod_hud.gd`) instead of printed as one
#     console line per draw per frame. `goats.draw` is the API's own surface (`APIv1.md` section
#     4.18), not the engine's -- the port has no raylib and says so.
#   * **The search is the client's**, because a player who installs a mod into the directory the
#     raylib client reads must find it loaded here too (`resolve_dir`).
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Mods
extends Node

## The browser's mods directory. Godot's `user://` is IndexedDB-backed, so an
## editor save survives a reload; the desktop keeps reading the reference
## client's `mods/` (`resolve_dir`).
const WEB_MODS := "user://mods"
## The build's own mods, staged as zips by `godot/tools/package_web.sh` and packed
## into the `.pck` by the Web preset's `bundled_mods/*` filter.
const BUNDLED_MODS := "res://bundled_mods"

## The `ModHost` node, or null when the extension did not load. A node and not a bare object
## because a mod may draw, and drawing is the frame's.
var host: Object
## The devices, for the one thing the frame owes them: the `blast` events a frame produced have to be
## *said* by the frame rather than inside the bang that made them. A bang a mod asked for runs in
## that mod's own JavaScript, where the extension is borrowed, and calling back into `ModHost` from
## there panics (`PORT.md` section 9) -- so `Explosions` records what happened and this says it,
## which is `gfx.unload`'s shape for `gfx.unload`'s reason. Set by `main.gd` beside `world`.
var devices: Object
## Where a mod's `console.log` and the load report go. Set by the frame *before* this node enters
## the tree, because the load report is produced in `_ready` and has nowhere else to land.
var console: Console
## The directory the mods were found in, or empty when there are none. Named on the console so a
## player can see which `mods/` was read -- the same question the raylib client's `[mods] scanning`
## line answers.
var dir := ""
## The metadata table the host handed over, parsed: one `{id, name, version, side, enabled, loaded,
## ...}` per mod in load order, plus `failed`/`error` on the ones whose entry threw. This is
## `menu.js`'s `goats.mods()` shape, so the Mods screen is a reader of it and not a second table.
## `set_enabled` refreshes it from the host after a toggle, which is why a field and not a read.
var table: Array = []
## The host's one-line report of the whole load, for the console. Empty until `load_all` has run.
var report := ""
## The **compiled** mods' HUD contribution, one frame old: `{id: fill}` from the host, which is
## exactly the map `mods.js`'s `sceneSetWasmHud` stores and `modWasmHudFill` reads (`ABIv1.md`
## section 3.4). The HUD draws a bar for the first fill it finds, so a build with no compiled client
## mod has an empty map and no bar -- never a built-in fallback a disabled mod left behind.
var wasm_hud := {}
## How many draws the mods have made through `goats.draw`. The surface counts them as it paints
## them, and this is the total -- the evidence a gate without a renderer can still check.
var draws := 0
## The control that paints them (`mod_hud.gd`), set by the frame. Without one the draws are
## still drained and counted, which is what a build with no `Ui` layer would see.
var surface: ModHud
## The node that places a mod's *world*-space draws (`mod_world.gd`), set by the frame. It is
## the other half of `goats.draw`: `draw` is pixels and this is metres.
var world: ModWorld
## The scene's entry point for the API's functional members -- `terrainHeight` today, the writes
## when they land -- handed in by the frame *before* this node enters the tree, because the host
## is built in `_ready` and needs it at once. A `Callable` and not a reference to the frame, for
## the reason `PlayerGoat.bleat` is one: this file does not link against the world modules.
var scene_call: Callable = Callable()
## The JavaScript callbacks the browser's mod editor calls. Kept so the
## `JavaScriptObject` functions are not collected while `window` holds them.
var _web_callbacks: Array = []
## The `window` object the callbacks were installed on, so each call can publish
## its answer for a caller that only has the property, not the return value.
var _web_window: Variant = null
## The last tuning write's answer (`{"ok": stored}` or `{"err": message}`), so
## the Tuning tab can report it on its next poll.
var _tuning_last: Dictionary = {}
## The frame's own `netInSession()`: true while this client is in a session, as host or joiner. A
## `Callable` for the reason `scene_call` is one -- this file does not link against the net module --
## and it is the guard `modSetEnabled` needs: a world mod's side is fixed at join, so changing one
## mid-session would desync a joiner.
var in_session: Callable = Callable()

## Instantiate the runtime and load whatever the platform has: `mods/` on disk,
## or `user://mods` in a tab. Discovery, every entry, and the table.
##
## A missing extension is not an error and not a crash: it is a build without the mod runtime,
## which is what `verify_mods` gates and what a probe without the library would see.
func _ready() -> void:
	if not ClassDB.class_exists("ModHost"):
		return
	var node: Object = ClassDB.instantiate("ModHost")
	add_child(node as Node)
	host = node
	_install_web_bridge()
	if not _discover():
		# Nothing to register, but the freeze is still the boot's shape: there is no entry left to
		# run, so registration has nothing to be open *for* (`APIv1.md` section 4.4).
		host.call("freeze")
		return
	_run()

## Find the mods the platform has. The desktop walks the directory the reference
## client walks; a tab reads `user://mods`, because a browser has no filesystem to
## hand the Rust loader.
func _discover() -> bool:
	if OS.has_feature("web"):
		return _discover_web()
	dir = resolve_dir()
	if dir == "":
		_line("mod: no mods directory found")
		return false
	_line("mod: scanning " + dir)
	# `load_mods` discovers and validates; `load_all` runs every entry, isolating the ones that
	# throw -- so a broken mod costs its own row and not the load (`APIv1.md` section 7).
	host.call("load_mods", dir)
	return true

## The browser's discovery: the build's own zips first, then `user://mods/<name>/`
## with `mod.json` at its root and every file beneath it. Each mod is handed to
## the host as a dictionary of manifest-relative names to bytes, which is the
## same parser a directory takes. A zip a user imports is extracted by the
## editor; this only unwraps the build's own bundles.
func _discover_web() -> bool:
	if not OS.get_environment("GOATS_NO_MODS").is_empty():
		return false
	dir = WEB_MODS
	# Bundled first, then user: the loader replaces an id, so an edited copy saved
	# under `user://mods` wins over the build's own copy on the next boot.
	var added := _load_bundled_mods()
	added = _load_user_mods() or added
	if not added:
		_line("mod: no mods in " + BUNDLED_MODS + " or " + WEB_MODS)
	return added

## The release's two mods, packed as zips in the project. `ZIPReader` gives back
## the same bytes the loader would read from a directory -- a raw `.glb`/`.mp3`
## under `res://` would have been imported by Godot instead.
func _load_bundled_mods() -> bool:
	if not DirAccess.dir_exists_absolute(BUNDLED_MODS):
		return false
	var zips: Array = []
	for file: String in DirAccess.get_files_at(BUNDLED_MODS):
		if file.get_extension().to_lower() == "zip":
			zips.append(file)
	zips.sort()
	if zips.is_empty():
		return false
	_line("mod: scanning " + BUNDLED_MODS)
	var added := false
	for file: String in zips:
		var files := _read_zip(BUNDLED_MODS.path_join(file))
		if files.is_empty():
			_line("mod: " + file + ": no files")
			continue
		var answer: String = String(host.call("load_mod_files", file.get_basename(), files))
		if answer.begins_with("ok "):
			added = true
		else:
			_line("mod: " + answer)
	return added

## The user's own mods, saved by the editor or imported into `user://mods`.
func _load_user_mods() -> bool:
	if not DirAccess.dir_exists_absolute(WEB_MODS):
		return false
	var names: Array = DirAccess.get_directories_at(WEB_MODS)
	names.sort()
	if names.is_empty():
		return false
	_line("mod: scanning " + WEB_MODS)
	var added := false
	for mod_name: String in names:
		var files := _read_memory_files(WEB_MODS.path_join(mod_name), "")
		if files.is_empty():
			continue
		var answer: String = String(host.call("load_mod_files", mod_name, files))
		if answer.begins_with("ok "):
			added = true
		else:
			_line("mod: " + answer)
	return added

## A bundled `.zip` as the dictionary `ModHost::load_mod_files` takes. The archive
## root is the mod root (`mod.json` at the top), the same layout the release ships.
static func _read_zip(path: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(path) != OK:
		return {}
	var files: Dictionary = {}
	for file_name: String in reader.get_files():
		if file_name.ends_with("/"):
			continue
		files[file_name] = reader.read_file(file_name)
	reader.close()
	return files

## Every file under `path`, keyed by its path relative to the mod's root -- the shape
## `ModHost::load_mod_files` takes. Binary assets ride as `PackedByteArray`.
static func _read_memory_files(path: String, prefix: String) -> Dictionary:
	var files: Dictionary = {}
	for file: String in DirAccess.get_files_at(path):
		var access := FileAccess.open(path.path_join(file), FileAccess.READ)
		if access == null:
			continue
		files[prefix + file] = access.get_buffer(access.get_length())
		access.close()
	for child: String in DirAccess.get_directories_at(path):
		files.merge(_read_memory_files(path.path_join(child), prefix + child + "/"))
	return files

## Run what `_discover` found: merge declared tuning, run every entry, freeze, and
## hand the table to the scene. The order is the boot's own whether the manifests
## came from disk or from memory.
func _run() -> void:
	# A mod's declared `tuning.json` merges *before* any entry runs (`APIv1.md` section 3.4). The table
	# is the host's and the tree is the scene's, so the scene does the merge -- here, between
	# discovery and the run. Its changes are dropped rather than queued, because no entry has
	# registered a `"tuning"` handler yet: the same nobody the reference's pre-entry notify reaches.
	_merge_declared_tuning(parse_table(host.call("mods_json")))
	Tuning.take_changed()
	report = String(host.call("load_all"))
	# Registration closes once every entry has run (`APIv1.md` section 4.4): a hook, a verb, a
	# registry or an asset override a mod asks for after this is refused, unless the entry is the
	# mod's *own* again -- a reload re-opens it. `goats.frozen()` answers with this from here on.
	host.call("freeze")
	for line in report.split("\n"):
		_line(line)
	# `GOATS_WATCH` (not empty): reload a mod when its files change on disk (`APIv1.md` section 2.5),
	# the port's `--watch`. A development aid, so it is a knob rather than a verb -- and a tab has
	# no directory to watch, so the web build skips it.
	if not OS.has_feature("web") and not OS.get_environment("GOATS_WATCH").is_empty():
		_line("mod: " + String(host.call("watch_mods")))
	table = parse_table(host.call("mods_json"))
	# The scene's own entry point for `goats` calls, registered once the host exists. An invalid
	# `Callable` -- a gate driving the runtime with no frame behind it -- is handed over as it is,
	# and the host answers a call with a clear error rather than panicking.
	host.call("set_scene_call", scene_call)

# ---------------------------------------------------------------------------
# The browser's editor bridge
# ---------------------------------------------------------------------------
#
# The shell page (`godot/web/index.html`) is a parent document; this scene is an
# iframe, and the mod editor lives in the parent. Same-origin makes the seam a
# few globals on `window`, installed here and called as
# `frame.contentWindow.goatsModsSave(...)`:
#
#   goatsModsSave(request)   write `<name>/...` under `user://mods`, then run it
#   goatsModsReload(request) run an unsaved buffer without writing it
#   goatsModsRead(name)      the saved files, JSON with base64 values
#   goatsModsState()         the mod table, exactly `mods_json`
#   goatsConsoleState()      the console ring, prompt and history, JSON
#   goatsConsoleRun(line)    run a line through the console's own submit
#   goatsTuningState()       the tree, bounds and last write, JSON
#   goatsTuningWrite(req)    `{path, value}` through `Tuning.write`
#
# A request is JSON (`JSON.stringify` on the page): `{name, files: {relative
# name: base64}}`. Base64 is the one representation both ends already have;
# `PackedByteArray` cannot cross the JavaScript bridge as an object. The host
# still parses and validates everything -- the bridge is storage and invocation,
# not a second manifest reader.

## Install the panel callbacks in a tab. On any other platform there is no
## JavaScriptBridge singleton and nothing to do.
func _install_web_bridge() -> void:
	if not OS.has_feature("web"):
		return
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return
	var window: Variant = bridge.call("get_interface", "window")
	if window == null:
		return
	_web_window = window
	_web_callbacks = [
		bridge.call("create_callback", Callable(self, "_web_save")),
		bridge.call("create_callback", Callable(self, "_web_reload")),
		bridge.call("create_callback", Callable(self, "_web_read")),
		bridge.call("create_callback", Callable(self, "_web_state")),
		bridge.call("create_callback", Callable(self, "_web_console_state")),
		bridge.call("create_callback", Callable(self, "_web_console_run")),
		bridge.call("create_callback", Callable(self, "_web_tuning_state")),
		bridge.call("create_callback", Callable(self, "_web_tuning_write")),
	]
	window.goatsModsSave = _web_callbacks[0]
	window.goatsModsReload = _web_callbacks[1]
	window.goatsModsRead = _web_callbacks[2]
	window.goatsModsState = _web_callbacks[3]
	window.goatsConsoleState = _web_callbacks[4]
	window.goatsConsoleRun = _web_callbacks[5]
	window.goatsTuningState = _web_callbacks[6]
	window.goatsTuningWrite = _web_callbacks[7]

## `goatsModsSave`: write the request's files under `user://mods/<name>/`, then
## insert/replace and run the mod. `user://` is IndexedDB-backed in a tab, so the
## next page load discovers it in `_discover_web`.
func _web_save(args: Array) -> String:
	var request := _web_request(args)
	if request.has("error"):
		return _web_respond(String(request["error"]))
	var mod_name: String = request["name"]
	var files: Dictionary = request["files"]
	var root: String = WEB_MODS.path_join(mod_name)
	for file: String in files:
		if not file.is_relative_path() or file.contains(".."):
			return _web_respond("error file '%s' is not a relative name" % file)
		var path: String = root.path_join(file)
		var parent := path.get_base_dir()
		DirAccess.make_dir_recursive_absolute(parent)
		if not DirAccess.dir_exists_absolute(parent):
			return _web_respond("error cannot create '%s'" % parent)
		var access := FileAccess.open(path, FileAccess.WRITE)
		if access == null:
			return _web_respond("error cannot write '%s'" % path)
		access.store_buffer(files[file])
		access.close()
	return _web_finish(String(host.call("reload_mod_files", mod_name, files)))

## `goatsModsReload`: run an unsaved buffer. The save path is the same call after
## the files have been written.
func _web_reload(args: Array) -> String:
	var request := _web_request(args)
	if request.has("error"):
		return _web_respond(String(request["error"]))
	return _web_finish(String(host.call(
		"reload_mod_files", request["name"], request["files"]
	)))

## `goatsModsRead`: the files of a saved mod, for the editor to open. Values are
## base64, the inverse of the save request.
func _web_read(args: Array) -> String:
	if args.is_empty():
		return _web_respond("error no mod name")
	var mod_name := String(args[0])
	if not _web_name_ok(mod_name):
		return _web_respond("error invalid mod name")
	var files: Dictionary = {}
	var root: String = WEB_MODS.path_join(mod_name)
	if DirAccess.dir_exists_absolute(root):
		files = _read_memory_files(root, "")
	else:
		# A bundled mod is a zip in the project; opening it here is what lets the
		# editor customize a mod the build shipped without saving a copy first.
		var zip: String = BUNDLED_MODS.path_join(mod_name + ".zip")
		if not FileAccess.file_exists(zip):
			return _web_respond("error no mod named '%s'" % mod_name)
		files = _read_zip(zip)
	var encoded: Dictionary = {}
	for file: String in files:
		encoded[file] = Marshalls.raw_to_base64(files[file])
	return _web_respond(JSON.stringify({"name": mod_name, "files": encoded}))

## `goatsModsState`: the table the Mods screen draws, so the editor's list and the
## game's list are one table.
func _web_state(_args: Array) -> String:
	return _web_respond(String(host.call("mods_json")))

## `goatsConsoleState`: the ring, the open flag and the pending question. The
## version is what the page polls; `lines` is only read when it moves.
func _web_console_state(_args: Array) -> String:
	if console == null:
		return _web_respond(JSON.stringify({"error": "console not ready"}))
	return _web_respond(JSON.stringify({
		"version": console.version,
		"open": console.open,
		"prompt": String(console.prompt.get("question", "")),
		"history": console.history,
		"lines": console.lines,
	}))

## `goatsConsoleRun`: run a line through the console's own `submit`, so the echo
## and the reply land in the scrollback the overlay draws as well.
func _web_console_run(args: Array) -> String:
	if console == null:
		return _web_respond("error console not ready")
	var line: String = "" if args.is_empty() else String(args[0])
	console.submit(line, console.dispatch)
	return _web_respond("ok")

## `goatsTuningState`: the tree, the clients' own bounds and integer flags, and
## the last write's answer. `tree()` is the live tree, so a leaf the menu moved
## reads its current value here too.
func _web_tuning_state(_args: Array) -> String:
	return _web_respond(JSON.stringify({
		"version": Tuning.version,
		"tree": Tuning.tree().duplicate(true),
		"clamp": Tuning.CLAMP,
		"int": Tuning.INT,
		"last": _tuning_last,
	}))

## `goatsTuningWrite`: `{path, value}` through `Tuning.write`, the same validated
## path a mod's `goats.tuning.set` uses. The answer is kept for the next poll.
func _web_tuning_write(args: Array) -> String:
	if args.is_empty():
		return _web_respond(JSON.stringify({"err": "no request"}))
	var parsed: Variant = JSON.parse_string(String(args[0]))
	if not (parsed is Dictionary):
		return _web_respond(JSON.stringify({"err": "the request is not a JSON object"}))
	var request: Dictionary = parsed
	var path := String(request.get("path", ""))
	if path.is_empty():
		return _web_respond(JSON.stringify({"err": "the request needs a path"}))
	var answer: Dictionary = Tuning.write(path, request.get("value", null))
	_tuning_last = answer
	return _web_respond(JSON.stringify(answer))

## Decode `{name, files: {relative: base64}}`. The request is JSON text because a
## JavaScript object's nested values do not cross the bridge as typed data.
func _web_request(args: Array) -> Dictionary:
	if args.is_empty():
		return {"error": "error no request"}
	var parsed: Variant = JSON.parse_string(String(args[0]))
	if not (parsed is Dictionary):
		return {"error": "error the request is not a JSON object"}
	var mod_name := String((parsed as Dictionary).get("name", ""))
	if not _web_name_ok(mod_name):
		return {"error": "error invalid mod name"}
	var encoded: Variant = (parsed as Dictionary).get("files", null)
	if not (encoded is Dictionary):
		return {"error": "error the request needs a files object"}
	var files: Dictionary = {}
	for file: String in encoded:
		var text: Variant = encoded[file]
		if not (text is String):
			return {"error": "error file '%s' is not base64 text" % file}
		files[file] = Marshalls.base64_to_raw(text)
	return {"name": mod_name, "files": files}

## A mod's folder name, which is not its manifest id: the id is validated by the
## loader, while this must stay a single path segment under `user://mods`.
static func _web_name_ok(mod_name: String) -> bool:
	return not mod_name.is_empty() and mod_name != "." and mod_name != ".." \
		and not mod_name.contains("/") and not mod_name.contains("\\")

## The scene's own table and tuning follow a saved or previewed mod, exactly as
## they follow a reload (`APIv1.md` section 3.4). The host has already run it.
func _web_finish(answer: String) -> String:
	table = parse_table(host.call("mods_json"))
	if answer.begins_with("ok mod reload "):
		_merge_one_tuning(answer.trim_prefix("ok mod reload "))
	return _web_respond(answer)

## Publish the answer on `window.goatsModsLast` as well as returning it. Godot's
## callback wrapper does pass a return value back, but a caller on the parent page
## can read this property regardless of how the wrapper was invoked, and it makes
## the bridge's contract explicit in one place.
func _web_respond(answer: String) -> String:
	if _web_window != null:
		_web_window.goatsModsLast = answer
	return answer

## Merge every discovered mod's declared `tuning.json` into the tree (`APIv1.md` section 3.4), in
## load order, before any entry runs. An unknown key is a warning, not a failure: the tree stops at
## the first bad leaf and the rest of that mod's tree is skipped, which is `sceneMods`' own
## `try`/`catch` shape.
func _merge_declared_tuning(discovered: Array) -> void:
	for meta: Dictionary in discovered:
		var declared: Variant = meta.get("tuning", null)
		if not (declared is Dictionary) or (declared as Dictionary).is_empty():
			continue
		var answer: Dictionary = Tuning.merge(declared)
		if answer.has("err"):
			_line("mod: %s: %s" % [meta.get("id", "?"), answer["err"]])

## One frame of the runtime. The clock is pushed every frame -- a mod may read it from any hook --
## and so is the world snapshot (`snapshot`), which is what `goats.player`, `goats.world`,
## `goats.bots`, `goats.settings`, `goats.tuning` and `goats.net` read. The `hud` hook fires only
## while the HUD is up, which is `sceneFrame`'s own gate: `modEmit("hud", ...)` sits in the
## `uiScreen === "hud"` branch, the same branch that draws the HUD. A menu replaces the HUD rather
## than covering it, so a mod's HUD drawing is not shown either.
##
## `hud` is therefore the frame's answer to "is the HUD up", passed in rather than asked for: this
## file knows about the mods and not about the UI. `snapshot` is the same shape -- the frame builds
## it, because the frame owns the world, and this file only hands it on.
func frame(hours: float, screen: Vector2, hud: bool, camera: Camera3D,
		snapshot: Dictionary = {}, dt: float = 0.0) -> void:
	if host == null:
		return
	host.call("set_world_time", hours)
	# The readable surface, pushed *before* the hooks run, so a `hud` or `draw3d` handler reads the
	# frame it is drawing. An empty dictionary -- a gate driving the runtime with no scene behind
	# it -- pushes nothing, so the last real snapshot stands rather than being replaced by nothing.
	if not snapshot.is_empty():
		host.call("push_world", JSON.stringify(snapshot))
	# ...and `update` **after** the push, which is the whole reason this is here rather than beside
	# the other emits: the first `update` of a session used to run before any world had been pushed,
	# so a handler that read a tuning leaf or a goat's position read *nothing* -- fatguy's
	# `tuning.get("explosions.mine.trigger")` answered "unknown path" once, on the first frame, and
	# the half-run frame it aborted left his `knock` a `NaN` for the rest of the session.
	#
	# The order is the reference's own (`modFrameTick`, then the drawing hooks): a handler that acts
	# on the world runs before the frame that shows it.
	host.call("emit_update", dt)
	if hud:
		host.call("emit_hud", screen.x, screen.y)
	# The world pass. Godot has no "the 3D pass" to hook -- a node in the tree is how a thing is
	# drawn -- so the `draw3d` hooks run here, with the camera, and what they draw becomes a node
	# per record for this frame (`mod_world.gd`).
	if world != null and camera != null:
		var eye: Vector3 = camera.global_position
		var look: Vector3 = eye - camera.global_transform.basis.z
		host.call("emit_draw3d", eye.x, eye.y, eye.z, look.x, look.y, look.z, camera.fov)
		world.adopt(host.call("poll_draw3d"))
	# The draws the hooks made, handed to the control that paints them. Drained whether or not
	# the HUD is up -- the hook only fires when it is, so a frame with no HUD has nothing here --
	# and counted either way, because a gate with no renderer still wants to know.
	var records: PackedStringArray = host.call("poll_draws")
	draws += records.size()
	if surface != null:
		surface.adopt(records)
	for line in host.call("poll_lines"):
		_drain(String(line))
	# ...and the `blast` events this frame produced, last of the frame's mod work and outside every
	# mod -- see `devices`. Drained whether or not anything is listening, so a bang nobody handles
	# does not pile up, and *said* a frame late at worst rather than inside the bang.
	if devices != null:
		for bang: Dictionary in devices.call("take_blast_events"):
			emit_blast(bang)
	# ...and the `tuning` events a write produced (`APIv1.md` section 4.2), for the blast events'
	# reason and in the same place: a write runs inside a mod's own JavaScript, so the leaf it moved
	# is *said* here, outside every hook, once it has landed in the tree. Drained whether or not
	# anything is listening, so a write nobody handles clears rather than piling up.
	for change: Array in Tuning.take_changed():
		emit_tuning(String(change[0]), change[1])
	# ...and the mods whose files changed on disk, when a watcher is running (`GOATS_WATCH`): the host
	# re-reads and re-runs each one and answers the ids, and the scene merges what each declared, so
	# a `tuning.json` edit lands with the entry -- `mods.js`'s `sceneModTuning`, driven from here.
	var watched: String = String(host.call("poll_watch"))
	if not watched.is_empty():
		table = parse_table(host.call("mods_json"))
		for id in watched.split("\n"):
			if String(id).is_empty():
				continue
			_line("mod: reloaded " + String(id))
			_merge_one_tuning(String(id))
	# ...and the **compiled** mods, after the world has moved and outside every JavaScript hook:
	# the reference's own order (its loop runs the scene's frame, then the Rust plugin host).
	_drive_wasm(dt, snapshot)

## The table, as `menu.gd`'s Mods screen and the console's `mod list` want it.
func mod_table() -> Array:
	return table

## Turn a mod on or off for this session (`APIv1.md` section 4.1; `mods.js`'s `modSetEnabled`).
##
## Two things are *this* file's rather than the host's. The **session guard** is the first: a world
## mod may not change mid-session, and only the scene knows whether there is one (`in_session`).
## The **table** is the second -- the host answers a fresh one and `table` is what the Mods screen
## and `mod list` read. The id is checked before the guard, in the reference's order, so
## `mod enable nope` is an unknown-mod error whether or not a session is up.
func set_enabled(id: String, enabled: bool) -> String:
	if host == null:
		return "error the mod runtime is not loaded"
	var meta: Variant = _meta(id)
	if not (meta is Dictionary):
		return "error unknown mod: " + id
	var live: bool = in_session.call() if self.in_session.is_valid() else false
	if live and String((meta as Dictionary).get("side", "")) == "world":
		return "error " + id + " is a world mod; leave the session first"
	var reply: String = String(host.call("set_enabled", id, enabled))
	table = parse_table(host.call("mods_json"))
	return reply

## One mod's declared `tuning.json`, merged and warned about (`APIv1.md` section 3.4):
## `_merge_declared_tuning`'s body for a single id, which is what a reload and the watcher need.
func _merge_one_tuning(id: String) -> void:
	var meta: Variant = _meta(id)
	if not (meta is Dictionary):
		return
	var declared: Variant = (meta as Dictionary).get("tuning", null)
	if not (declared is Dictionary) or (declared as Dictionary).is_empty():
		return
	var answer: Dictionary = Tuning.merge(declared)
	if answer.has("err"):
		_line("mod: %s: %s" % [id, answer["err"]])

## `mod reload <id>` (`APIv1.md` section 2.5): read the mod again from disk and run it again. It is
## `set_enabled`'s own guard and the host's own re-read (the host tears the live instance down,
## reads the source again and re-runs the entry) plus the one thing the scene owns: the mod's
## declared `tuning.json` is merged again, so a tuning edit on disk lands with the entry -- and the
## table, whose row may name a new version now.
func reload_mod(id: String) -> String:
	if host == null:
		return "error the mod runtime is not loaded"
	var meta: Variant = _meta(id)
	if not (meta is Dictionary):
		return "error unknown mod: " + id
	var live: bool = in_session.call() if self.in_session.is_valid() else false
	if live and String((meta as Dictionary).get("side", "")) == "world":
		return "error " + id + " is a world mod; leave the session first"
	var reply: String = String(host.call("reload_mod", id))
	table = parse_table(host.call("mods_json"))
	if reply.begins_with("ok"):
		_merge_one_tuning(id)
	return reply

## Add the mods a pull just installed, while the game is already running (M18d,
## `APIv1.md` section 2.7). This is `mods.js`'s `sceneModAdd` -- the half of it the scene owns.
##
## The *entry* is the host's: `ModHost::add_pulled` re-discovers the directory the pull wrote
## into, puts the new rows in its table, and runs each new mod's entry in its own
## `goats.begin(id)` window. What is left here is the three things `sceneModAdd` does around
## that: the table this node draws, the declared `tuning.json` merged (after the entry, as a
## reload's is -- the reference merges it first, but the port's `tuning` group is a per-frame
## push and an entry cannot read it mid-run either way), and -- back in `main.gd`, where the
## sound node lives -- the slot table re-read, because a mod that arrives after the boot
## `prepare` names sounds nobody has decoded. The asset slots need nothing here: the facade
## reads the host's table live (`slotTable`), so a refresh is all a new declaration needs.
##
## Returns the host's own report -- `loaded <id> (n asset(s))` per mod -- or `error ...`, which
## `main.gd` prints into the console beside the `pulled` line. An id the table already holds is
## refused before the host is asked, which is `sceneModAdd`'s `modFind` guard: nothing is re-run,
## because a second `goats.begin(id)` would reset a live mod's registrations.
func add_pulled(ids: Array) -> String:
	if host == null:
		return "error the mod runtime is not loaded"
	var wanted: Array = []
	for id in ids:
		var token: String = String(id)
		if _meta(token) != null:
			return "error already loaded: " + token
		wanted.append(token)
	var reply: String = String(host.call("add_pulled", JSON.stringify(wanted)))
	table = parse_table(host.call("mods_json"))
	for id in wanted:
		_merge_one_tuning(String(id))
	return reply

## Flip a mod, reading which way from the table -- `menu.js`'s Enable/Disable button, whose label
## follows `enabled` and whose callback is handed one argument.
func toggle_mod(id: String) -> String:
	var meta: Variant = _meta(id)
	if not (meta is Dictionary):
		return "error unknown mod: " + id
	return set_enabled(id, not bool((meta as Dictionary).get("enabled", true)))

## One row of the last table, by id, or `null`.
func _meta(id: String) -> Variant:
	for meta: Dictionary in table:
		if String(meta.get("id", "")) == id:
			return meta
	return null

## The first compiled client mod's HUD bar fill (0..1), or `-1.0` when none is running.
##
## `mods.js`'s `modWasmHudFill` returns the first finite value in the host's `{id: fill}` map and
## `null` when the map is empty. This returns a *float* with a sentinel instead of a nullable,
## because the HUD reads it every frame and a sentinel costs no type test -- and because the fill's
## own range is 0..1, so nothing a module can report collides with it.
func wasm_hud_fill() -> float:
	for id in wasm_hud:
		var value: float = float(wasm_hud[id])
		if is_finite(value):
			return value
	return -1.0

## One frame for the compiled mods (`ABIv1.md`, M17b). `tick_world` and the belly are read out of
## the frame's own snapshot rather than taken as further arguments: both are values the scene already
## pushes for the *readable* groups (`main.gd`'s `_mod_snapshot`), and reading them from there is
## what makes a compiled mod and a JavaScript one be told the same world in the same words.
## `localWorld` is the scene's own mirroring bit, and it is the one the reference's `netWorldLocal()`
## answers: a client that joined a host does not simulate the world's compiled mods either.
func _drive_wasm(dt: float, snapshot: Dictionary) -> void:
	if host == null:
		return
	var world_local := true
	var belly := 0.0
	if not snapshot.is_empty():
		world_local = bool(snapshot.get("localWorld", true))
		var player: Variant = snapshot.get("player", {})
		if player is Dictionary:
			belly = float((player as Dictionary).get("satiety", 0.0))
	var answer: String = String(host.call("drive_wasm", dt, world_local, belly))
	# An empty answer is "no compiled mod is loaded at all" -- `ModHost::drive_wasm`'s own contract,
	# which is what keeps a frame with none from costing a JSON round trip. That is *also* the case a
	# disable reaches, and it has to clear the map: the reference sets `rustModHud` from
	# `hud_json()` every frame (`{}` when there are none), so a disabled module's bar goes with it.
	# Leaving the last frame's map standing -- which this used to do -- kept a disabled mod's belly
	# bar on screen, because the bar lives here in the scene and not in the host that dropped it.
	if answer.is_empty():
		wasm_hud = {}
		return
	var parsed: Variant = JSON.parse_string(answer)
	if not (parsed is Dictionary):
		return
	var frame_report: Dictionary = parsed
	var hud: Variant = frame_report.get("hud", {})
	wasm_hud = hud if hud is Dictionary else {}

## Re-derive the world mods' streams from the session seed (`APIv1.md` section 4.13). It is
## `sceneUseSeed`'s last act in the reference client (`weather.js`), which is why it is an *event*
## and not part of the per-frame snapshot: the derivation advances on every call, so a joiner lands
## on the same stream the host is on rather than on one derived from a frame.
func use_seed(session_seed: int) -> void:
	if host != null:
		host.call("use_seed", session_seed)

## The world mods' state as one JSON object -- `{streams, data}` -- or **empty** when there is
## nothing to send: no registered stream, no extension that publishes, no compiled module with
## bytes. This is `sceneWorldMods()` as a *host* builds it, and the extension is what builds it
## because half of the object is Rust's: the facade holds a JavaScript world mod's streams and its
## `publish` results, while a compiled one's bytes live in its module (`crates/plugin`). The frame
## asks for this where it publishes the world, and sends nothing when the answer is empty -- which
## is what keeps a vanilla session from sending an empty datagram ten times a second.
func world_mods_json() -> String:
	if host == null:
		return ""
	return String(host.call("world_mods_json"))

## The world-mod set this client presents at a host or a join (`APIv1.md` section 6.2), as JSON:
## one `{id, version, hash}` per `side: "world"` mod, from the loader's own digest. The frame hands
## it to `NetBridge::host`/`join`, which is what carries it into the handshake -- a host refuses a
## set that differs, and "nothing" is not the set of a host that runs the flock. `[]` on a build
## with no mods (`GOATS_NO_MODS`, or an empty directory), which is what a vanilla session presents.
func world_mod_refs() -> String:
	if host == null:
		return "[]"
	return String(host.call("world_mod_refs"))

## Apply a host's world-mod state, from the `mods` event: the mods' streams are **adopted** rather
## than re-derived, and every world mod is handed what the host published under its id -- a
## JavaScript extension through its own `apply`, a compiled module through `goats_apply`. It is the
## mirroring half of `world_mods_json`, and the reason a joiner's flock is the host's flock rather
## than a second simulation of it (`APIv1.md` section 4.13).
func apply_world_mods(json: String) -> void:
	if host != null:
		host.call("apply_world_mods", json)

## One frame's `update` event, with the step. Called by `frame` *after* the world is pushed and
## before the drawing hooks -- see there -- rather than by the scene, because the order is the whole
## point. The scene sends `dt = 0` while the world is frozen, so this is not a gate: a frozen frame
## still reaches every handler, and a mod that keeps a clock of its own holds still with it.
func update(dt: float) -> void:
	if host != null:
		host.call("emit_update", dt)

## The `blast` event, once per bang (`APIv1.md` section 4.15). `state` is the nine fields the
## reference sends, and it arrives from the *devices* rather than from here because a bang is theirs.
func emit_blast(state: Dictionary) -> void:
	if host != null:
		host.call("emit_blast", JSON.stringify(state))

## The `"tuning"` event (`APIv1.md` section 4.2), once per changed leaf. `path` is the dotted leaf
## and `value` the coerced value it now holds. Fired from the frame and not from the write, for
## `blast`'s reason: the write ran inside a mod's own JavaScript, where the extension is borrowed.
func emit_tuning(path: String, value: Variant) -> void:
	if host != null:
		host.call("emit_tuning", path, JSON.stringify(value))

## The `shutdown` event, once, as the scene goes down. It is where a mod frees what it built -- the
## flock unloads its three meshes -- and it has to happen while the extension is still alive.
func shutdown() -> void:
	if host != null:
		host.call("emit_shutdown")

## First refusal for a console line: a mod's registered verb and its reply, or empty when no mod
## claims the word. This is `mods.js`'s `modCommand` for the part the host can answer, and it is
## what makes a mod's console verb work at all -- the extension's `run_command` is the lookup, and
## it answers `""` rather than an error when the word belongs to nobody, which is how the console
## tells a mod's verb from a typo without a second lookup of its own.
func run_command(mod_name: String, line: String) -> String:
	if host == null:
		return ""
	return String(host.call("run_command", mod_name, line))

## Where the mods come from. `GOATS_MODS` wins, then `mods/` beside the project (the source
## layout: `godot/../mods`), then `mods/` beside the executable (an exported build).
##
## The raylib client's order also tries the working directory; Godot exposes no working directory
## to GDScript, so that one candidate is absent rather than guessed -- and `GOATS_MODS` covers it.
## `GOATS_NO_MODS` skips the search entirely, which is that client's `--no-mods`.
static func resolve_dir() -> String:
	if not OS.get_environment("GOATS_NO_MODS").is_empty():
		return ""
	var explicit: String = OS.get_environment("GOATS_MODS")
	if not explicit.is_empty() and DirAccess.dir_exists_absolute(explicit):
		return explicit
	var beside_project: String = ProjectSettings.globalize_path("res://") \
		.path_join("../mods").simplify_path()
	if DirAccess.dir_exists_absolute(beside_project):
		return beside_project
	var beside_exe: String = OS.get_executable_path().get_base_dir().path_join("mods")
	if DirAccess.dir_exists_absolute(beside_exe):
		return beside_exe
	return ""

## The host's JSON table as an array. A table that does not parse is an empty one and a line,
## which is `mods.js`'s own "unreadable table" answer.
static func parse_table(json: Variant) -> Array:
	var parsed: Variant = JSON.parse_string(String(json))
	if parsed is Array:
		return parsed
	return []

## Route one logged line. The host marks the level (`log `/`warn `/`error `) so a player can tell
## the three apart, and only `log`'s marker comes off: a warning and an error keep their own word in
## front of the mod's text, because `goats.warn` is not the same thing to a reader as `goats.log`.
func _drain(line: String) -> void:
	_line(line.substr(4) if line.begins_with("log ") else line)

## One line to the console's own stream, if there is a console yet.
func _line(text: String) -> void:
	if console != null:
		console.system_line(text)

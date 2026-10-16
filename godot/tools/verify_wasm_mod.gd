# The compiled mods, through the scene's own driver (`ABIv1.md`, M17b): a mod that ships a `.wasm`
# module and no JavaScript at all.
#
#   Godot --headless --path godot --script res://tools/verify_wasm_mod.gd
#
# `verify_mods.gd` holds the *loader* half of a mod -- discovery, the manifest, the table -- and
# `verify_scene_mods.gd` holds the JavaScript half. This is the third path, and it is the one thing
# neither could reach: a module is not evaluated by Slag at all. `crates/plugin` decodes it,
# instantiates it against the capabilities its own import list asks for, and drives it from Rust, so
# a `.wasm` file never becomes a path or an `ArrayBuffer` anybody else holds.
#
# What is held, and why each is a failure nothing else would catch:
#
#   1. **The repository's compiled mod loads and is *driven by the scene*.** The load is
#      `load_all`'s, but the *drive* is `mods.gd`'s frame calling `drive_wasm` -- so a plugin host
#      that instantiated and never ticked would pass every host-level check and show a mod that
#      does nothing. The frame count is the evidence: it can only come from the scene's own frames.
#   2. **The module's own report** (`wasm_describe`, the ABI, the import list, the ready line it
#      logged through `goats.log`) -- the capability list read *off the module* rather than assumed,
#      which is what makes it a check on the ABI rather than on this host's beliefs about it.
#   3. **The HUD bar a client module contributes** (`goats_hud` -> `drive_wasm`'s `hud` map ->
#      `Mods.wasm_hud_fill`), and the console line that shows a player the same thing.
#   4. **A wrong-ABI module is refused, by name, before its code runs** (`ABIv1.md` section 3.6) --
#      staged at run time, because the repository's mods must all load.
#   5. **A world module publishes, and a mirroring client does not tick it** (`ABIv1.md` section 3.4:
#      `goats_update` runs where the world is authoritative and `goats_apply` is the mirror's way in).
#      This is the compiled half of `netWorldLocal()`.
extends SceneTree

## The repository's compiled fixture: a `side: "client"` mod whose module reads `goats.belly` and
## reports a HUD bar.
const ID := "com.github.sdgoij.goats.wasm"
## The module's own ready line, read back out of `goats.log`.
const READY := "wasm mod: ready"
## The capabilities the client fixture imports, in the order its module declares them.
const IMPORTS := ["goats.log", "goats.rng", "goats.belly", "goats.publish"]
## Enough frames for the scene to boot and for the scene's own drive to have ticked the module many
## times over. Named so a slow first frame cannot be mistaken for a wiring failure.
const MIN_FRAMES := 20
## When the checks run: late enough for the load and the drives, early enough to be quick.
const CHECK_FRAME := 45
## The two fixtures no repository mod uses: the same source built for an ABI this build does not
## know, and one built without the client-only visual surface. Read from the repository so the gate
## and a release test the same bytes (`fixtures/wasm/`).
const ABI2_MODULE := "fixtures/wasm/mod-abi2.wasm"
const WORLD_MODULE := "fixtures/wasm/world.wasm"
const WORLD_ID := "com.example.worldwasm"

var _failures: Array[String] = []
var _frames := 0
var _main: Node
## Set only at the very end of `_check`. A GDScript runtime error inside a `SceneTree` script's check
## aborts that function and leaves every failure after it unappended, so a run that did not reach the
## end has to be a failure whatever it asserted on the way (`PORT.md` section 9).
var _finished := false

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < CHECK_FRAME:
		return false
	_check()
	if not _finished:
		print("FAIL: the checks did not run to the end")
		quit(1)
		return true
	if _failures.is_empty():
		print("OK: a compiled mod loads, is driven by the scene, reports a HUD bar and is refused by ABI")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	var mods: Object = _main.get("mods")
	if mods == null:
		_failures.append("the scene has no Mods runtime")
		return
	var host: Object = mods.get("host")
	if host == null:
		_failures.append("the scene's mod runtime has no host node")
		return

	# 1. The repository's compiled mod, and the report of its module.
	var info: Variant = _describe(host, ID)
	if not (info is Dictionary):
		_failures.append("the compiled fixture has no module report: %s" % info)
		return
	var module: Dictionary = info
	print("module: abi ", module.get("abi"), "  imports ", module.get("imports"),
		"  frames ", module.get("frames"), "  log ", module.get("log"))
	if int(module.get("abi", 0)) != 1:
		_failures.append("the fixture negotiated ABI %s, and this build is ABI 1" % module.get("abi"))
	if not _same_list(module.get("imports"), IMPORTS):
		_failures.append("the module's own import list is %s, not %s" % [module.get("imports"), IMPORTS])
	if String(module.get("log", "")) != READY:
		_failures.append("the module's ready line is '%s', not '%s'"
			% [module.get("log"), READY])
	if not bool(module.get("ok", false)):
		_failures.append("the module is not running: %s" % module.get("error"))

	# 2. The *scene* drove it. This is the half a host-level check cannot see: `load_all` runs
	#    `goats_init`, and only `mods.gd`'s frame ever runs `goats_update`.
	var frames: int = int(module.get("frames", 0))
	print("compiled frames: ", frames, "  of ", CHECK_FRAME, " scene frame(s)")
	if frames < MIN_FRAMES:
		_failures.append("the scene drove the module %d time(s) in %d frame(s)"
			% [frames, CHECK_FRAME])

	# 3. The HUD bar: the module computes it from the belly the scene pushes, the host hands it over
	#    as a map, and `Mods` reads the first value out.
	var fill: float = float(mods.call("wasm_hud_fill"))
	print("wasm hud fill: ", fill)
	if fill < 0.0 or fill > 1.0:
		_failures.append("the compiled mod's HUD bar is %s, and a bar fill is 0..1" % fill)

	# ...and the console line that shows a player the same report. `mod info` is where the raylib
	# client's `modWasmInfo` lands, so this is the seam a player reads.
	var vocabulary: Object = _main.get("commands")
	var reply: String = String(vocabulary.call("run", "mod info " + ID))
	print("mod info ->     ", reply)
	var parsed: Variant = JSON.parse_string(reply.trim_prefix("ok "))
	var wasm: Variant = (parsed as Dictionary).get("wasm") if parsed is Dictionary else null
	if not (wasm is Dictionary):
		_failures.append("`mod info` carries no module report: '%s'" % reply)
	elif int((wasm as Dictionary).get("abi", 0)) != 1:
		_failures.append("`mod info` reports ABI %s, not 1" % (wasm as Dictionary).get("abi"))

	# 4 and 5. The two cases no repository mod covers, on modules this gate stages: an ABI this
	#    build does not know, and a world module that publishes.
	_check_staged(host)
	_finished = true

## A module's own report, or a printable reason it has none. `wasm_describe` answers the *string*
## `"null"` for a mod with no module -- one code path for both answers, and the reason this parses
## rather than tests.
func _describe(host: Object, id: String) -> Variant:
	return JSON.parse_string(String(host.call("wasm_describe", id)))

func _same_list(value: Variant, wanted: Array) -> bool:
	if not (value is Array):
		return false
	var list: Array = value
	if list.size() != wanted.size():
		return false
	for at in list.size():
		if String(list[at]) != String(wanted[at]):
			return false
	return true

## The ABI's failure path and its world path, on modules the gate writes into `user://` at run time.
##
## Staged rather than shipped because the repository's mods must all load: a checked-in wrong-ABI
## module would have to be excluded from the directory the game reads, and the exclusion would be the
## only thing making the fixture "work". Last, because `load_mods` replaces the loaded set.
func _check_staged(host: Object) -> void:
	var parent: String = _stage("com.example.wasmabi2", "client", ABI2_MODULE)
	_stage("com.example.worldwasm", "world", WORLD_MODULE, parent)
	print("staged: ", str(host.call("load_mods", parent)).strip_edges().replace("\n", "; "))
	print("staged: ", str(host.call("load_all")).strip_edges().replace("\n", "; "))

	var table: Variant = JSON.parse_string(String(host.call("mods_json")))
	if not (table is Array):
		_failures.append("the host's table did not answer after staging")
		return
	var refused := false
	for meta: Dictionary in table:
		if String(meta.get("id", "")) != "com.example.wasmabi2":
			continue
		if not bool(meta.get("failed", false)):
			_failures.append("a module built for another ABI was not marked failed")
		elif not String(meta.get("error", "")).contains("ABI 2"):
			_failures.append("the refusal does not name the ABI it found: %s" % meta.get("error"))
		else:
			refused = true
			print("staged refusal: ", meta.get("error"))
	if not refused:
		_failures.append("no wrong-ABI module was named as failed")

	# The world module: authoritative here, so it ticks and publishes. `goatsd` and a solo client
	# host are both this case (`crates/server/src/headless.rs` is the other one).
	var published := _drive_published(host, 30)
	print("published keys: ", published.keys())
	if not published.has(WORLD_ID):
		_failures.append("a world module ticked as the world's own published nothing: %s" % published)
	elif String(published[WORLD_ID]).is_empty():
		_failures.append("the world module's published state is empty")

	# ...and the mirroring rule: a client that joined a host does not simulate the world, so it must
	# not step the world's modules either. Its frame count is where that shows.
	var before: int = int(_stat(host, WORLD_ID, "frames"))
	_drive_published(host, 10, false)
	var after: int = int(_stat(host, WORLD_ID, "frames"))
	print("mirroring: frames ", before, " -> ", after)
	if after != before:
		_failures.append("a mirroring client stepped a world module: %d -> %d" % [before, after])

## Drive the host `frames` times and hand back the `published` map of the last one -- the host's own
## `{id: base64}`, which is what the mods datagram carries.
func _drive_published(host: Object, frames: int, world_local: bool = true) -> Dictionary:
	var out: Dictionary = {}
	for _tick in frames:
		var answer: String = String(host.call("drive_wasm", 1.0 / 60.0, world_local, 0.0))
		if answer.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(answer)
		if not (parsed is Dictionary):
			continue
		var published: Variant = (parsed as Dictionary).get("published", {})
		if published is Dictionary:
			out = published
	return out

func _stat(host: Object, id: String, key: String) -> Variant:
	var info: Variant = _describe(host, id)
	if not (info is Dictionary):
		return null
	return (info as Dictionary).get(key)

## One staged mod as two files: a manifest and the module, under `user://gates-wasm/<id>/`. Returns
## the *parent* directory `load_mods` walks, and reuses one when it is handed in so two mods land
## side by side. The host is Rust and reads with `std::fs`, so `user://` is globalised before it is
## handed over -- the trap `verify_scene_mods.gd` records: the error arrives as "cannot read the
## mods directory", not as a bad path.
func _stage(id: String, side: String, module: String, parent: String = "") -> String:
	var uri: String = "user://gates-wasm/" + id
	DirAccess.make_dir_recursive_absolute(uri)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(_repo_path(module))
	if bytes.is_empty():
		_failures.append("could not read the module fixture %s" % module)
	var manifest: FileAccess = FileAccess.open(uri + "/mod.json", FileAccess.WRITE)
	manifest.store_string(JSON.stringify({
		"id": id, "name": id.get_file(), "version": "1.0.0", "api": 1, "side": side,
		"description": "staged by the gate", "wasm": { "module": "plugin.wasm" },
	}))
	manifest.close()
	var file: FileAccess = FileAccess.open(uri + "/plugin.wasm", FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	if parent != "":
		return parent
	return ProjectSettings.globalize_path("user://gates-wasm")

## A repository file, from the project's own `res://` (which is `godot/`) up to the workspace root.
static func _repo_path(relative: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("../").path_join(relative).simplify_path()

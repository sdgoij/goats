# The fetched-mod gate (M18d): a world mod that arrives *after* the freeze, loaded while the game
# is already running.
#
#   Godot --headless --path godot --script res://tools/verify_pulled_mod.gd
#
# This is the scene-side half of `sceneModAdd` (`APIv1.md` section 2.7, `mods.js`). A pull installs
# a mod into the mods directory *mid-session*, and `Mods.add_pulled` is what turns those bytes into
# a loaded mod: the host re-discovers the directory and runs each entry in its own `goats.begin(id)`
# window, and the scene refreshes the table it draws and merges the tuning the entry declared. The
# wire half -- the refusal, the fetch, the retry -- is `NetBridge`'s and is held live by
# `interop.sh pull`; this gate holds the other half, where there is no host at all.
#
# Four things are held, and each is a place `sceneModAdd` could silently half-land:
#
#   1. **The metadata lands.** A mod that is not in the boot directory is in the table after
#      `add_pulled`, as a `side: "world"` row, *appended* after everything already loaded -- the
#      reference appends and never re-orders (`APIv1.md` section 2.7).
#   2. **Its declared asset slot registers.** The entry reads `goats.assets.get("model.pulled")` as
#      it runs and answers with the opaque name, which proves the slot was in the table *before* the
#      entry ran -- the boot order, and the half a table refresh alone cannot show.
#   3. **Its entry ran.** That same command is the proof: it exists only because the entry
#      evaluated, and its reply comes back through the host's dispatcher.
#   4. **Its tuning merges.** The pulled `tuning.json`'s leaf is where `Tuning` says it is after the
#      add -- the reference merges it *before* the entry, but the port's `tuning` group is a
#      per-frame push an entry cannot read mid-run either way, so this is the same ordering a
#      reload gets (`reload_mod`).
#
# The boot directory is staged in memory rather than using the repository's `mods/`: the point is a
# mod that was *not there at boot*, which a checked-in fixture cannot be. Both mods are written to
# `user://`, the same door `verify_scene_mods.gd` stages its reload fixture through, because the
# host reads with `std::fs` and needs a globalised path.
extends SceneTree

## The mod that is in the directory at boot: proof that a later add is *appended*, not the whole
## table. Client side, no entry -- it exists to be the row before the pulled one.
const BOOT_ID := "com.example.boot"
## The mod that arrives after the freeze, as a pull's would. World side -- the only side a pull
## ever fetches (`APIv1.md` section 2.7) -- with an entry, a declared asset slot and a tuning tree.
const PULLED_ID := "com.example.pulled"
## The slot the pulled mod fills, and the opaque name the entry should read back out of it.
const PULLED_SLOT := "model.pulled"
const PULLED_ASSET := "mod:com.example.pulled:model.pulled.glb"
## What the entry's command answers. The name is read *inside* the entry, so a reply that carries it
## is the slot registering before the entry ran.
const PULLED_REPLY := "ok " + PULLED_ASSET
## The pulled mod's declared `camera.dist`, and the leaf the merge moves -- within the tree's own
## clamp so the write is accepted.
const PULLED_DIST := 11.5
## Where both mods are staged, and the directory the runtime is pointed at.
const ROOT_URI := "user://gates-pulled"

## Frames to let the scene's `_ready` run before the checks. The `Mods` node builds its host and
## loads the boot mod in `_ready`, so a check must wait a frame -- `SceneTree.root` is not in the
## tree while `_initialize` runs (the trap `verify_console.gd` names).
const SETTLE_FRAMES := 4

var _failures: Array[String] = []
var _frames := 0
var _mods: Node
## Set only at the very end of `_check`, so a GDScript runtime error mid-check is a failure rather
## than a silent early success (`PORT.md` section 9's trap).
var _finished := false

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return
	# A clean directory, so a second run is the same run.
	_wipe(ProjectSettings.globalize_path(ROOT_URI))
	if not _stage():
		print("FAIL: could not stage the pulled-mod fixtures")
		quit(1)
		return
	# The runtime reads this for `resolve_dir`, before the node enters the tree.
	OS.set_environment("GOATS_MODS", ProjectSettings.globalize_path(ROOT_URI))
	OS.set_environment("GOATS_NO_MODS", "")
	_mods = load("res://src/mods.gd").new()
	root.add_child(_mods)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return false
	_check()
	if not _finished:
		print("FAIL: the checks did not run to the end")
		quit(1)
		return true
	if _failures.is_empty():
		print("OK: a mod pulled after the freeze lands in the table, registers its asset, runs its entry and merges its tuning")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	if _mods == null or _mods.get("host") == null:
		_failures.append("the runtime did not load a ModHost")
		return
	var host: Object = _mods.get("host")

	# 0. The boot state: the boot mod is the only row, and the pulled one is not in the directory
	#    yet -- so the add below is the *only* thing that can put it there.
	var before: Array = _mods.call("mod_table")
	print("at boot: ", _ids(before))
	if not _has(before, BOOT_ID):
		_failures.append("the boot mod is missing before the add")
	if _has(before, PULLED_ID):
		_failures.append("the pulled mod is in the table before it was added")
	if DirAccess.dir_exists_absolute(_dir("pulled")):
		_failures.append("the pulled mod's directory exists before the add")

	# 1. Stage the mod the way a pull installs it: a new directory in the mods dir. Nothing reads it
	#    until `add_pulled`, which is the point.
	if not _stage_file(ROOT_URI + "/pulled/mod.json", JSON.stringify({
		"id": PULLED_ID, "name": "Pulled", "version": "2.3.4", "api": 1, "side": "world",
		"description": "A world mod that arrived after the freeze.", "entry": "mod.js",
		"tuning": "tuning.json", "assets": {PULLED_SLOT: "assets/tiny.glb"},
	})):
		return
	if not _stage_file(ROOT_URI + "/pulled/mod.js",
		"const token = goats.assets.get(" + JSON.stringify(PULLED_SLOT) + ");\n"
		+ "goats.command(\"pulled-hello\", function () { return \"ok \" + String(token); });\n"):
		return
	if not _stage_file(ROOT_URI + "/pulled/tuning.json",
		"{\"camera\": {\"dist\": %s}}" % PULLED_DIST):
		return
	if not _stage_file(ROOT_URI + "/pulled/assets/tiny.glb", "glTF-ish bytes"):
		return

	# 2. The add. The report names the id and its asset count, which is the host's own line for the
	#    boot path too.
	var report: String = String(_mods.call("add_pulled", [PULLED_ID]))
	print("add_pulled -> ", report)
	if not report.begins_with("loaded " + PULLED_ID):
		_failures.append("add_pulled answered: " + report)

	# 3. The metadata landed, appended, and says what the manifest did.
	var table: Array = _mods.call("mod_table")
	print("after add: ", _ids(table))
	var row: Dictionary = _row(table, PULLED_ID)
	if row.is_empty():
		_failures.append("the pulled mod is not in the table after the add")
	else:
		if String(row.get("side", "")) != "world":
			_failures.append("the pulled row is side '%s', not world" % row.get("side"))
		if String(row.get("version", "")) != "2.3.4":
			_failures.append("the pulled row names version '%s'" % row.get("version"))
		if not bool(row.get("loaded", false)):
			_failures.append("the pulled row is not loaded after its entry ran")
		var assets: Variant = row.get("assets", {})
		if not (assets is Dictionary) or String((assets as Dictionary).get(PULLED_SLOT, "")) != PULLED_ASSET:
			_failures.append("the pulled row does not declare its asset slot: %s" % assets)
	# Appended, not interleaved: the reference appends a pull after everything already loaded.
	if table.size() != 2 or String(table[0].get("id", "")) != BOOT_ID:
		_failures.append("the pulled mod was not appended after the boot mod: %s" % _ids(table))

	# 4. The entry ran, and it read the slot it declared *before* it ran. One check, two halves:
	#    an unrun entry leaves no command, and a slot that registered too late leaves the name
	#    undefined in the reply.
	var reply: String = String(host.call("run_command", "pulled-hello", "pulled-hello"))
	print("pulled-hello -> ", reply)
	if reply != PULLED_REPLY:
		_failures.append("the pulled entry's command answered '%s', want '%s'" % [reply, PULLED_REPLY])

	# ...and the host really holds the bytes, not merely the name.
	var names: PackedStringArray = host.call("asset_names")
	if not names.has(PULLED_ASSET):
		_failures.append("the pulled asset is not registered by name: %s" % names)
	else:
		var bytes: PackedByteArray = host.call("asset_bytes", PULLED_ASSET)
		if bytes.is_empty():
			_failures.append("the pulled asset has no bytes behind its name")

	# 5. The declared tuning merged, at the leaf the tree knows.
	if absf(float(Tuning.CAMERA_DIST) - PULLED_DIST) > 1e-6:
		_failures.append("the pulled tuning.json did not land: camera.dist is %s" % Tuning.CAMERA_DIST)

	# 6. A second add of an id that is already loaded is refused, which is `sceneModAdd`'s own
	#    `modFind` guard -- and it is refused *before* the host is asked, so nothing is re-run.
	var again: String = String(_mods.call("add_pulled", [BOOT_ID]))
	print("re-add -> ", again)
	if again != "error already loaded: " + BOOT_ID:
		_failures.append("re-adding a loaded id answered: " + again)

	_finished = true

## Stage the mod that is present at boot: a manifest and no entry, so it is one clean row. The
## pulled mod's directory is *not* created here -- check 0 asserts it does not exist until the add.
func _stage() -> bool:
	return _stage_file(ROOT_URI + "/boot/mod.json", JSON.stringify({
		"id": BOOT_ID, "name": "Boot", "version": "1.0.0", "api": 1, "side": "client",
		"description": "The row the pulled mod is appended after.",
	}))

## The globalised path of a stage directory (the host reads with `std::fs`, so `user://` has to be
## resolved before it is handed over).
func _dir(name: String) -> String:
	return ProjectSettings.globalize_path(ROOT_URI + "/" + name)

func _row(table: Array, id: String) -> Dictionary:
	for meta: Dictionary in table:
		if String(meta.get("id", "")) == id:
			return meta
	return {}

func _has(table: Array, id: String) -> bool:
	return not _row(table, id).is_empty()

func _ids(table: Array) -> Array:
	var out: Array = []
	for meta: Dictionary in table:
		out.append(meta.get("id", "?"))
	return out

## Remove a staged directory tree so a second run is the same run. A missing directory is fine.
func _wipe(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for name in dir.get_directories():
		_wipe(path.path_join(name))
	for name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	DirAccess.remove_absolute(path)

## Write one staged file, creating its directory, or record the failure.
func _stage_file(path: String, text: String) -> bool:
	var dir: String = path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("could not stage " + path)
		return false
	file.store_string(text)
	file.close()
	return true

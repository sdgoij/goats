# The toggle gate (stage 8): `modSetEnabled` and the session guard it needs, on the live scene.
#
#   Godot --headless --path godot --script res://tools/verify_mod_toggle.gd
#
# `verify_scene_mods.gd` holds that the scene *runs* the mods. This holds the half a player reaches
# through the Mods screen's Enable/Disable button and the console's `mod enable`/`mod disable`:
# that a toggle turns a mod off and on again, that the table says so, that the vocabulary comes and
# goes with it, and that a *world* mod is refused mid-session. The teardown is `mods.js`'s
# `goatsEnd` -- the mod's own `shutdown` hook first, then everything it registered -- and the re-run
# is the host's `reload_and_eval`, so this stands on both sides of the same seam.
#
#   * **The verb follows the mod.** The example's `hello` is registered by its entry, so a disable
#     that dropped its handlers but not its command (or the reverse) would show here: the reply is
#     `ok hello world` before, empty between, and `ok hello world` again after.
#   * **The registrations follow the mod too.** `birds` is a world mod, so a disable that missed its
#     stream and its extension would leave a flock publishing for a mod that is off --
#     `world_mods_json` is exactly that answer, and it is `""` with the only world mod disabled.
#   * **A compiled bar clears.** The wasm mod's `goats_hud` bar is drawn from a value the scene holds
#     (`wasm_hud`), so a disable the host performed correctly still leaves the bar on screen unless
#     the scene reads the host's empty answer as an empty map. This is the failure a player saw.
#   * **The guard is the scene's.** A world mod's side is fixed at join, so changing one mid-session
#     would desync a joiner. The session is driven through the same `Callable` the frame sets, so the
#     guard is exercised without binding an endpoint -- and a *client* mod still toggles in it.
#   * **The button is wired.** `menu.js`'s Enable/Disable calls one callback with one argument; this
#     calls that same `Callable` (`menu.mod_toggle`), because a toggle that only the console can
#     reach is a button a player presses and nothing happens.
#
# Everything is read from the live scene, and nothing is staged: the repository's own mods are the
# fixtures, which is what makes this a gate on the port rather than on a copy of it.
extends SceneTree

## The example: the one client mod whose entry registers a console verb (`verify_mods.gd`).
const EXAMPLE_ID := "com.github.sdgoij.goats.hello"
## The world mod: the one with a seeded stream and a published flock, so the registrations a disable
## has to drop (`goats.world.registerStream`, `goats.world.extend`) are the ones `world_mods_json`
## answers.
const WORLD_ID := "com.github.sdgoij.goats.birds"
## The compiled client mod: the one whose `goats_hud` bar the scene paints (`wasm_hud` ->
## `hud.gd`). Its bar is the one thing a disable has to clear *in the scene*, because the host that
## drops the module cannot reach the value the scene drew last frame.
const WASM_ID := "com.github.sdgoij.goats.wasm"
## What the example's verb answers, from `verify_mods.gd`.
const HELLO_REPLY := "ok hello world"
## Frames to let the scene boot and the mods load before the checks.
const SETTLE_FRAMES := 6

var _failures: Array[String] = []
var _frames := 0
var _main: Node
## The session the guard sees, driven directly: a `Callable` stands in for the frame's own
## `_net_in_session`, so the guard can be exercised without binding a real endpoint.
var _session := false
## Set only at the very end of `_check`. A GDScript runtime error inside a `SceneTree` script's check
## aborts that function and leaves every failure after it unappended, so a run that did not reach the
## end has to be a failure whatever it asserted on the way (`PORT.md` section 9).
var _finished := false

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
	if _frames < SETTLE_FRAMES:
		return false
	_check()
	if not _finished:
		print("FAIL: the checks did not run to the end")
		quit(1)
		return true
	if _failures.is_empty():
		print("OK: a mod toggles off and on, its verb, stream and bar follow it, and a world mod is guarded")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

## The session the guard reads, so `_check` can turn it on and off around an assertion.
func _session_flag() -> bool:
	return _session

func _check() -> void:
	var mods: Object = _main.get("mods")
	if mods == null or mods.get("host") == null:
		_failures.append("the scene has no mod runtime")
		return
	var commands: Object = _main.get("commands")
	if commands == null:
		_failures.append("the scene has no console")
		return
	# The guard reads a `Callable` the frame set; this replaces the frame's own for the run, so the
	# session can be asserted without a session. It is the real code path -- `Mods.set_enabled` calls
	# whatever is here -- rather than a second guard written for the gate.
	mods.set("in_session", Callable(self, "_session_flag"))

	# 1. The starting state: the example is loaded, its verb answers, and the table says so.
	var hello_before: String = String(mods.call("run_command", "hello", "hello world"))
	print("hello ->           ", hello_before)
	_expect(hello_before == HELLO_REPLY, "the example's verb did not answer: '%s'" % hello_before)
	_expect(bool(_row(mods, EXAMPLE_ID).get("enabled", false)), "the example is not enabled at boot")
	_expect(bool(_row(mods, EXAMPLE_ID).get("loaded", false)), "the example is not loaded at boot")

	# 2. Disable it: the reply, the table, and the verb that goes with it. The command lives in the
	#    mod's own `__mods` entry, so this is the `goatsEnd` drop seen from the console.
	var off: String = String(mods.call("set_enabled", EXAMPLE_ID, false))
	print("disable ->         ", off)
	_expect(off == "ok mod disable " + EXAMPLE_ID, "disable answered '%s'" % off)
	var row: Dictionary = _row(mods, EXAMPLE_ID)
	_expect(not bool(row.get("enabled", true)), "the table still says the example is enabled")
	_expect(not bool(row.get("loaded", true)), "a disabled mod is still loaded in the table")
	var hello_off: String = String(mods.call("run_command", "hello", "hello world"))
	print("hello after disable -> '", hello_off, "'")
	_expect(hello_off == "", "the verb survived the disable: '%s'" % hello_off)

	# 3. Enable it: back, and the table with it. The host re-reads and re-evaluates, so this proves
	#    the second half of a toggle as well as the first.
	var on: String = String(mods.call("set_enabled", EXAMPLE_ID, true))
	print("enable ->          ", on)
	_expect(on == "ok mod enable " + EXAMPLE_ID, "enable answered '%s'" % on)
	_expect(bool(_row(mods, EXAMPLE_ID).get("enabled", false)),
		"the table does not say the example is enabled again")
	_expect(bool(_row(mods, EXAMPLE_ID).get("loaded", false)), "the re-enabled example is not loaded")
	var hello_on: String = String(mods.call("run_command", "hello", "hello world"))
	print("hello after enable -> ", hello_on)
	_expect(hello_on == HELLO_REPLY, "the verb did not come back: '%s'" % hello_on)

	# 4. A world mod's *registrations* go with it. `birds` registers a stream and an extension, and
	#    those are what the mods datagram carries -- so a disable that missed them would keep
	#    publishing for a mod that is off, which is the one thing `world_mods_json` can be asked.
	var world_before: String = String(mods.call("world_mods_json"))
	print("world mods before -> ", world_before.substr(0, 96))
	_expect(world_before.contains(WORLD_ID),
		"the flock is not in the world mods at boot: '%s'" % world_before)
	var woff: String = String(mods.call("set_enabled", WORLD_ID, false))
	print("disable world ->   ", woff)
	_expect(woff == "ok mod disable " + WORLD_ID, "disabling the world mod answered '%s'" % woff)
	var world_off: String = String(mods.call("world_mods_json"))
	print("world mods after -> '", world_off, "'")
	_expect(world_off == "", "the flock's state outlived its mod: '%s'" % world_off)
	_expect(String(mods.call("set_enabled", WORLD_ID, true)) == "ok mod enable " + WORLD_ID,
		"the world mod did not re-enable")
	_expect(String(mods.call("world_mods_json")).contains(WORLD_ID),
		"the flock did not come back with its mod")

	# 5. A compiled client mod's bar goes with it. The bar lives in the *scene* (`wasm_hud`, drawn by
	#    `hud.gd`), and the host answers the empty string once no compiled mod is left -- so the frame
	#    that reads that answer is what has to clear it. One `frame` call is one frame of the runtime,
	#    so the toggle and the bar are asserted inside one frame rather than across two.
	var bar_before: float = float(mods.call("wasm_hud_fill"))
	print("wasm bar before -> ", bar_before)
	_expect(bar_before >= 0.0 and bar_before <= 1.0,
		"the compiled mod's HUD bar was not up: %s" % bar_before)
	var woff2: String = String(mods.call("set_enabled", WASM_ID, false))
	print("disable wasm ->    ", woff2)
	_expect(woff2 == "ok mod disable " + WASM_ID, "disabling the compiled mod answered '%s'" % woff2)
	mods.call("frame", 8.0, Vector2(640.0, 480.0), false, null, {}, 0.0)
	var bar_after: float = float(mods.call("wasm_hud_fill"))
	print("wasm bar after ->  ", bar_after)
	_expect(bar_after == -1.0, "the compiled mod's bar outlived its mod: %s" % bar_after)
	_expect(String(mods.call("set_enabled", WASM_ID, true)) == "ok mod enable " + WASM_ID,
		"the compiled mod did not re-enable")
	mods.call("frame", 8.0, Vector2(640.0, 480.0), false, null, {}, 0.0)
	var bar_back: float = float(mods.call("wasm_hud_fill"))
	print("wasm bar back ->   ", bar_back)
	_expect(bar_back >= 0.0 and bar_back <= 1.0,
		"the compiled mod's bar did not come back: %s" % bar_back)

	# 6. An unknown id, and the console's two verbs -- the id is checked before the guard, in the
	#    reference's order, so a typo is an unknown-mod error with or without a session.
	_expect(String(mods.call("set_enabled", "nope", true)) == "error unknown mod: nope",
		"an unknown id was not refused")
	_expect(String(commands.call("run", "mod enable")) == "error mod enable expects an id",
		"`mod enable` with no id was not refused")
	_expect(String(commands.call("run", "mod disable")) == "error mod disable expects an id",
		"`mod disable` with no id was not refused")

	# 7. The session guard: a world mod may not change mid-session, and the flag is left alone; a
	#    client mod still toggles, because its side was never part of the compatibility set.
	_session = true
	var guarded: String = String(mods.call("set_enabled", WORLD_ID, false))
	print("guarded ->         ", guarded)
	_expect(guarded.begins_with("error") and guarded.contains("world"),
		"a world mod was toggled in a session: '%s'" % guarded)
	_expect(bool(_row(mods, WORLD_ID).get("enabled", false)),
		"the refused toggle moved the flag anyway")
	var client_live: String = String(mods.call("set_enabled", EXAMPLE_ID, false))
	_expect(client_live == "ok mod disable " + EXAMPLE_ID,
		"a client mod was refused in a session: '%s'" % client_live)
	mods.call("set_enabled", EXAMPLE_ID, true)
	_session = false

	# 8. The button's own wiring: `menu.js`'s Enable/Disable is one callback with one argument, which
	#    `main.gd` sets to the runtime's `toggle_mod` -- so this calls the same `Callable` a click does.
	var menu: Object = _main.get("menu")
	var toggle: Variant = menu.get("mod_toggle") if menu != null else null
	_expect(toggle is Callable and (toggle as Callable).is_valid(),
		"the Mods screen's Enable/Disable is not wired")
	if toggle is Callable and (toggle as Callable).is_valid():
		var flipped: String = String((toggle as Callable).call(EXAMPLE_ID))
		print("button ->          ", flipped)
		_expect(flipped == "ok mod disable " + EXAMPLE_ID, "the button did not disable: '%s'" % flipped)
		_expect(not bool(_row(mods, EXAMPLE_ID).get("enabled", true)),
			"the button's answer is not in the table")
		_expect(String((toggle as Callable).call(EXAMPLE_ID)) == "ok mod enable " + EXAMPLE_ID,
			"the button did not turn it back on")

	_finished = true

## One row of the runtime's table, by id, or an empty dictionary -- the table is the host's, so this
## reads the same object the Mods screen draws.
func _row(mods: Object, id: String) -> Dictionary:
	for meta: Dictionary in mods.call("mod_table"):
		if String(meta.get("id", "")) == id:
			return meta
	return {}

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

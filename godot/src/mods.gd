# The mod runtime, as the scene drives it: the extension's `ModHost` node, the directory its mods
# come from, and the three things the rest of the scene asks of it.
#
# The split is `mods.js`'s, and it is the same split for the same reason. The *host* -- here the
# GDExtension over `crates/mods` and the embedded engine -- discovers, validates, orders and runs;
# the *scene* owns the table the UI draws, the per-frame hooks a mod registered, and the console's
# first refusal. What the port does not have yet is `mods.js`'s other half: `modSetEnabled` and its
# session guard, the world-mod datagram, the tuning *merge* (a write), reload/watch and the
# asset-to-engine path. Those are stage 8 (`PORT.md` section 6, and section 10's third item); this
# file is stage 1's, and it stops at "the scene is running the mods and can see what happened".
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

## The `ModHost` node, or null when the extension did not load. A node and not a bare object
## because a mod may draw, and drawing is the frame's.
var host: Object
## Where a mod's `console.log` and the load report go. Set by the frame *before* this node enters
## the tree, because the load report is produced in `_ready` and has nowhere else to land.
var console: Console
## The directory the mods were found in, or empty when there are none. Named on the console so a
## player can see which `mods/` was read -- the same question the raylib client's `[mods] scanning`
## line answers.
var dir := ""
## The metadata table the host handed over, parsed: one `{id, name, version, side, enabled, ...}`
## per mod in load order, plus `failed`/`error` on the ones whose entry threw. This is
## `menu.js`'s `goats.mods()` shape, so the Mods screen is a reader of it and not a second table.
var table: Array = []
## The host's one-line report of the whole load, for the console. Empty until `load_all` has run.
var report := ""
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

## Instantiate the runtime and load whatever `mods/` holds. Discovery, every entry, and the table.
##
## A missing extension is not an error and not a crash: it is a build without the mod runtime,
## which is what `verify_mods` gates and what a probe without the library would see.
func _ready() -> void:
	if not ClassDB.class_exists("ModHost"):
		return
	var node: Object = ClassDB.instantiate("ModHost")
	add_child(node as Node)
	host = node
	dir = resolve_dir()
	if dir == "":
		_line("mod: no mods directory found")
		return
	_line("mod: scanning " + dir)
	# `load_mods` discovers and validates; `load_all` runs every entry, isolating the ones that
	# throw -- so a broken mod costs its own row and not the load (`APIv1.md` section 7).
	host.call("load_mods", dir)
	report = String(host.call("load_all"))
	for line in report.split("\n"):
		_line(line)
	table = parse_table(host.call("mods_json"))
	# The scene's own entry point for `goats` calls, registered once the host exists. An invalid
	# `Callable` -- a gate driving the runtime with no frame behind it -- is handed over as it is,
	# and the host answers a call with a clear error rather than panicking.
	host.call("set_scene_call", scene_call)

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
		snapshot: Dictionary = {}) -> void:
	if host == null:
		return
	host.call("set_world_time", hours)
	# The readable surface, pushed *before* the hooks run, so a `hud` or `draw3d` handler reads the
	# frame it is drawing. An empty dictionary -- a gate driving the runtime with no scene behind
	# it -- pushes nothing, so the last real snapshot stands rather than being replaced by nothing.
	if not snapshot.is_empty():
		host.call("push_world", JSON.stringify(snapshot))
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

## The table, as `menu.gd`'s Mods screen and the console's `mod list` want it.
func mod_table() -> Array:
	return table

## Re-derive the world mods' streams from the session seed (`APIv1.md` section 4.13). It is
## `sceneUseSeed`'s last act in the reference client (`weather.js`), which is why it is an *event*
## and not part of the per-frame snapshot: the derivation advances on every call, so a joiner lands
## on the same stream the host is on rather than on one derived from a frame.
func use_seed(seed: int) -> void:
	if host != null:
		host.call("use_seed", seed)

## First refusal for a console line: a mod's registered verb and its reply, or empty when no mod
## claims the word. This is `mods.js`'s `modCommand` for the part the host can answer, and it is
## what makes a mod's console verb work at all -- the extension's `run_command` is the lookup, and
## it answers `""` rather than an error when the word belongs to nobody, which is how the console
## tells a mod's verb from a typo without a second lookup of its own.
func run_command(name: String, line: String) -> String:
	if host == null:
		return ""
	return String(host.call("run_command", name, line))

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

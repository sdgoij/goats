# The mod runtime, as the scene drives it: the extension's `ModHost` node, the directory its mods
# come from, and the three things the rest of the scene asks of it.
#
# The split is `mods.js`'s, and it is the same split for the same reason. The *host* -- here the
# GDExtension over `crates/mods` and the embedded engine -- discovers, validates, orders and runs;
# the *scene* owns the table the UI draws, the per-frame hooks a mod registered, and the console's
# first refusal. What the port does not have yet is `mods.js`'s other half: the `goats` surface's
# sixteen unimplemented member groups, the eighteen events, `modSetEnabled` and its session guard,
# the world-mod datagram, the tuning merge, reload/watch and the asset-to-engine path. Those are
# stage 8 (`PORT.md` section 6, and section 10's third item); this file is stage 1's, and it stops
# at "the scene is running the mods and can see what happened".
#
# Three decisions worth naming, because each is a place the port deliberately stops short:
#
#   * **The table is the host's, and so is the failure.** A manifest is validated before anything
#     runs, so the *loader* cannot know that a mod's entry threw -- only the host that ran it can.
#     `ModHost::mods_json` therefore merges `failed`/`error` into the loader's table, which is
#     `mods.js`'s `sceneModResult` folded into `sceneMods`. Without it the Mods screen would draw
#     five healthy rows and the game would be lying about four of them.
#   * **A mod's `console.log` is a console line, and its draw is not.** A line the host queued is
#     either the mod talking or a call it made through the engine's `rl` -- and the `rl` half is
#     the Godot-backed drawing shim, whose *first* member (`drawText`) is queued as text today.
#     Printing that would be one console line per draw per frame, so this counts the draws and
#     renders none: rendering them is the shim proper (stage 8), and `_drain` says so.
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
## How many draws the mods have made through the engine's `rl`. Counted rather than printed (see
## the header): it is the evidence the HUD hook ran, and the frame's own HUD is stage 8's.
var draws := 0

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

## One frame of the runtime. The clock is pushed every frame -- a mod may read it from any hook --
## and the `hud` hook fires only while the HUD is up, which is `sceneFrame`'s own gate: `modEmit("hud",
## ...)` sits in the `uiScreen === "hud"` branch, the same branch that draws the HUD. A menu
## replaces the HUD rather than covering it, so a mod's HUD drawing is not shown either.
##
## `hud` is therefore the frame's answer to "is the HUD up", passed in rather than asked for: this
## file knows about the mods and not about the UI.
func frame(hours: float, screen: Vector2, hud: bool) -> void:
	if host == null:
		return
	host.call("set_world_time", hours)
	if hud:
		host.call("emit_hud", screen.x, screen.y)
	for line in host.call("poll_lines"):
		_drain(String(line))

## The table, as `menu.gd`'s Mods screen and the console's `mod list` want it.
func mod_table() -> Array:
	return table

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

## Route one queued line. `log ` is the mod talking; anything else is a draw it made through the
## engine's `rl`, which is counted rather than printed (see the header).
func _drain(line: String) -> void:
	if line.begins_with("log "):
		_line(line.substr(4))
		return
	draws += 1

## One line to the console's own stream, if there is a console yet.
func _line(text: String) -> void:
	if console != null:
		console.system_line(text)

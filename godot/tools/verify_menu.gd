# The menu gate (M25): `menu.js`'s four screens -- their geometry, their words, their walk, and
# what their controls really do.
#
#   Godot --headless --path godot --script res://tools/verify_menu.gd
#
# The scene builds its menus out of raygui at explicit pixel coordinates, so the *layout* is part
# of the specification and this holds it: for four viewport sizes and a fixed set of settings, a
# JavaScript oracle transcribed from `menu.js` computes every panel, group box, label, button,
# toggle, slider and combo -- kind, text and rectangle -- and the port's `Menu.layout` has to
# produce the same list. It also holds the keymap table row for row, the `Play`/`Continue` word,
# and Escape's walk (`hud -> main -> hud`, a sub-screen -> `main`).
#
# Then the live half, which is the part a layout cannot answer: **every control does something.**
# The four settings that are the port's own switches are asserted against the *world* rather than
# against the settings object -- the terrain's material goes unshaded and back, the sun's shadow
# toggle follows the mode, the environment's sky background comes and goes, the cloud march's step
# count moves, the herd resizes -- because "the value changed" is exactly the claim a broken
# `apply` would still satisfy.
#
# The oracle is `menu.js` transcribed from source. The two scripts are separate evaluations for the
# reason `verify_peers.gd` records: `eval_js` evaluates into one realm, so a top-level `const` is a
# `SyntaxError` the second time a script names it.
extends SceneTree

## `menu.js`'s layout arithmetic, for one screen at one size. The widget list is
## `kind|text|x|y|w|h`, one per line, in the order the scene draws them.
const LAYOUT_JS := """
(function () {
function pack(s) { return String(s).split(" ").join("~"); }
function r(v) { return Number(v).toFixed(1); }
const SIZES = __SIZES__;
const S = __SETTINGS__;
const ROWS = __ROWS__;
const WEB = __WEB__;
const SHADOW_LIST = ["None", "Shadow map"];
const CLOUD_LIST = ["Low", "Medium", "High"];
const REFLECT_LIST = ["Sky only", "Ground", "Mirror"];
const out = [];
function widget(kind, text, x, y, w, h) {
    out.push(kind + '|' + pack(text) + '|' + r(x) + '|' + r(y) + '|' + r(w) + '|' + r(h));
}
function mainMenu(sw, sh) {
    const w = 300, h = 350;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    widget('panel', 'Slag goat', x, y, w, h);
    const bx = x + 30, bw = w - 60, bh = 34;
    let by = y + 46;
    const labels = [S.frames > 0 ? 'Continue' : 'Play', 'Settings', 'Mods', 'Keymap', 'Console'];
    // A tab has no process to quit (`menu.js` tests `typeof web`); the desktop keeps it.
    if (!WEB) labels.push('Quit');
    for (let i = 0; i < labels.length; i++) {
        widget('button', labels[i], bx, by, bw, bh);
        by += bh + 10;
    }
}
function settingsMenu(sw, sh) {
    const w = 460, h = 460;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    widget('panel', 'Settings', x, y, w, h);
    const lx = x + 20, lw = w - 40;
    let cy = y + 44;
    widget('group', 'Audio', lx, cy, lw, 92);
    cy += 26;
    widget('slider', 'Music', lx + 10, cy, lw - 20, 24);
    cy += 30;
    widget('slider', 'SFX', lx + 10, cy, lw - 20, 24);
    cy += 46;
    widget('group', 'Graphics', lx, cy, lw, 208);
    cy += 26;
    widget('toggle', 'Light', lx + 10, cy, lw - 20, 24);
    cy += 30;
    widget('combo', SHADOW_LIST[S.shadow], lx + 10, cy, lw - 20, 24);
    cy += 30;
    widget('toggle', 'Sky shader', lx + 10, cy, lw - 20, 24);
    cy += 30;
    widget('combo', CLOUD_LIST[S.cloud], lx + 10, cy, lw - 20, 24);
    cy += 30;
    widget('combo', REFLECT_LIST[S.reflect], lx + 10, cy, lw - 20, 24);
    cy += 30;
    widget('toggle', 'Fullscreen', lx + 10, cy, lw - 20, 24);
    cy += 46;
    widget('group', 'Gameplay', lx, cy, lw, 66);
    cy += 26;
    widget('slider', 'Herd size', lx + 10, cy, lw - 20, 24);
    widget('button', 'Back', x + w / 2 - 60, y + h - 40, 120, 30);
}
function keymapMenu(sw, sh) {
    const w = 540, h = 500;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    widget('panel', 'Keymap', x, y, w, h);
    const kx = x + 24, ax = x + 200, rowH = 21;
    let ry = y + 44;
    for (let i = 0; i < ROWS.length; i++) {
        widget('label', ROWS[i][0], kx, ry, 168, rowH);
        widget('label', ROWS[i][1], ax, ry, w - 224, rowH);
        ry += rowH;
    }
    widget('button', 'Back', x + w / 2 - 60, y + h - 40, 120, 30);
}
function modsMenu(sw, sh) {
    const w = 600, h = 440;
    const x = Math.round((sw - w) / 2);
    const y = Math.round((sh - h) / 2);
    widget('panel', 'Mods', x, y, w, h);
    widget('label', 'this session only - a restart restores the mods/ directory', x + 20, y + 34, w - 40, 18);
    widget('label', 'no mods found - put them in mods/ next to the game', x + 20, y + 60, w - 40, 20);
    widget('button', 'Back', x + w / 2 - 60, y + h - 40, 120, 30);
}
for (let i = 0; i < SIZES.length; i++) {
    const size = SIZES[i];
    out.push('== ' + i);
    mainMenu(size[0], size[1]);
    settingsMenu(size[0], size[1]);
    keymapMenu(size[0], size[1]);
    modsMenu(size[0], size[1]);
}
for (let i = 0; i < out.length; i++) console.log('rect ' + i + ' ' + out[i]);
})();
"""

## The settings the layout is computed at. `shadow`/`cloud`/`reflect` are *indices* here because the
## oracle has no words for them; the port's are mapped to the same indices on its side.
const SETTINGS_FOR_LAYOUT := {
	"frames": 1, "bgm": 90, "sfx": 90, "light": true,
	"shadow": 1, "sky": true, "cloud": 1, "reflect": 1, "fullscreen": false, "herd": 0,
}

## The four viewports the layout is asked about: the two the harnesses use, a larger one, and one
## smaller than every panel -- where the scene's arithmetic goes negative and the port has to as
## well, because clamping would be a layout the scene does not have.
const SIZES := [[1280.0, 720.0], [1152.0, 648.0], [1920.0, 1080.0], [512.0, 300.0]]

## The live settings checks: run a console line, then assert something about the *world*. Each is
## `[line, what, expected]`, and `what` is a small selector the check below understands.
const EFFECTS := [
	["setting light off", "terrain_shading", "unshaded"],
	["setting light off", "grass_shading", "unshaded"],
	["setting light on", "terrain_shading", "lit"],
	["setting light on", "grass_shading", "lit"],
	["setting shadow off", "sun_shadow", "off"],
	["setting shadow map", "sun_shadow", "on"],
	["setting sky off", "sky_background", "off"],
	["setting sky on", "sky_background", "on"],
	["setting cloud low", "cloud_level", "0"],
	["setting cloud high", "cloud_level", "2"],
	["setting bgm 40", "bgm", "40"],
	["setting sfx 55", "sfx", "55"],
	["setting herd 4", "herd", "4"],
	["setting reflect mirror", "reflect_wish", "2"],
]

var _failures: Array[String] = []
var _frames := 0
var _main: Node

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var oracle := {}
	var source: String = LAYOUT_JS \
		.replace("__SIZES__", JSON.stringify(SIZES)) \
		.replace("__SETTINGS__", JSON.stringify(SETTINGS_FOR_LAYOUT)) \
		.replace("__ROWS__", JSON.stringify(_keymap_rows())) \
		.replace("__WEB__", JSON.stringify(OS.has_feature("web")))
	for line in _oracle(host, source, "layout"):
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log rect ") and parts.size() >= 4:
			var index: int = int(parts[2])
			# A widget's text can hold `|` or spaces, so the payload is everything after the
			# prefix rather than a token -- the split only finds the line's index.
			oracle[index] = line.substr(("log rect %d " % index).length())
	print("oracle answered ", oracle.size(), " widget line(s)")
	host.free()

	_check_layout(oracle)
	_check_keymap(_keymap_rows())
	_check_walk()
	_check_hits()
	_check_clicks()

	# The live half: the real scene, read a few frames later, for the reason `verify_console.gd`
	# records (`SceneTree.root` is not inside the tree while `_initialize` runs).
	var packed := load("res://scenes/herd.tscn") as PackedScene
	_main = packed.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	_check_effects()
	_check_audio_sliders()
	_check_shared()
	_check_routed()
	if _failures.is_empty():
		print("OK: the port's menu is the scene's -- four screens at four sizes, and every control "
			+ "reaches what it names")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

## The four screens at four sizes, kind for kind and pixel for pixel.
func _check_layout(oracle: Dictionary) -> void:
	var menu := _bare_menu()
	var lines: PackedStringArray = PackedStringArray()
	for i in SIZES.size():
		lines.append("== %d" % i)
		var size: Array = SIZES[i]
		for which: String in ["main", "settings", "keymap", "mods"]:
			menu.show_screen(which)
			for widget: Dictionary in menu.layout(Vector2(float(size[0]), float(size[1]))):
				lines.append(widget_line(widget))
	menu.free()
	var mismatches: int = 0
	var first: String = ""
	for i in lines.size():
		var wanted: String = String(oracle.get(i, "<no oracle>"))
		if lines[i] != wanted:
			mismatches += 1
			if first == "":
				first = "line %d: scene '%s', port '%s'" % [i, wanted, lines[i]]
	print("layout: %d line(s), %d mismatch(es)" % [lines.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("a menu screen is not the scene's: %d of %d widget line(s)"
			% [mismatches, lines.size()])

## A widget as the oracle writes one: `kind|text|x|y|w|h`, spaces packed and the rect to one place.
static func widget_line(widget: Dictionary) -> String:
	var rect: Rect2 = widget["rect"]
	return "%s|%s|%.1f|%.1f|%.1f|%.1f" % [String(widget["kind"]),
		String(widget["text"]).replace(" ", "~"), rect.position.x, rect.position.y,
		rect.size.x, rect.size.y]

## The keymap table, row for row and word for word.
func _check_keymap(oracle: Array) -> void:
	var mismatches: int = 0
	var first: String = ""
	if Menu.KEYMAP_ROWS.size() != oracle.size():
		first = "the scene has %d row(s) and the port %d" % [oracle.size(), Menu.KEYMAP_ROWS.size()]
		mismatches += 1
	for i in mini(Menu.KEYMAP_ROWS.size(), oracle.size()):
		var mine: Array = Menu.KEYMAP_ROWS[i]
		var wanted: Array = oracle[i]
		if String(mine[0]) != String(wanted[0]) or String(mine[1]) != String(wanted[1]):
			mismatches += 1
			if first == "":
				first = "row %d: scene %s, port %s" % [i, wanted, mine]
	print("keymap: %d row(s), %d mismatch(es)" % [Menu.KEYMAP_ROWS.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("the keymap table is not the scene's")

## The `Play`/`Continue` word and Escape's walk.
func _check_walk() -> void:
	var cases: Array = [
		[0, "Play"], [1, "Continue"], [240, "Continue"],
	]
	var mismatches: int = 0
	var first: String = ""
	for row: Array in cases:
		var mine: String = Menu.continue_label(int(row[0]))
		if mine != String(row[1]):
			mismatches += 1
			if first == "":
				first = "frames %d: scene '%s', port '%s'" % [row[0], row[1], mine]
	print("first button: %d case(s), %d mismatch(es)" % [cases.size(), mismatches])
	if first != "":
		print("  first: ", first)
	# `uiScreen === "hud" ? "main" : uiScreen === "main" ? "hud" : "main"`.
	var walk: Array = [["hud", "main"], ["main", "hud"], ["settings", "main"],
		["mods", "main"], ["keymap", "main"]]
	var walk_mismatches: int = 0
	var walk_first: String = ""
	for row: Array in walk:
		if Menu.next_screen(String(row[0])) != String(row[1]):
			walk_mismatches += 1
			if walk_first == "":
				walk_first = "'%s' -> scene '%s', port '%s'" % [row[0], row[1],
					Menu.next_screen(String(row[0]))]
	print("escape: %d case(s), %d mismatch(es)" % [walk.size(), walk_mismatches])
	if walk_first != "":
		print("  first: ", walk_first)
	if mismatches != 0:
		_failures.append("the first button's word is not the scene's: %d of %d case(s)"
			% [mismatches, cases.size()])
	if walk_mismatches != 0:
		_failures.append("the escape walk is not the scene's: %d of %d case(s)"
			% [walk_mismatches, walk.size()])

## The live half: every control, run through the console's own verb, asserted against the world.
func _check_effects() -> void:
	var vocabulary: Commands = _main.get("commands")
	if vocabulary == null:
		_failures.append("the scene did not build a Commands")
		return
	var mismatches: int = 0
	var first: String = ""
	for row: Array in EFFECTS:
		var line: String = String(row[0])
		var reply: String = vocabulary.run(line)
		var got: String = _witness(vocabulary, String(row[1]))
		var wanted: String = String(row[2])
		if got != wanted:
			mismatches += 1
			if first == "":
				first = "'%s' (%s): wanted '%s', got '%s' [reply '%s']" % [
					line, row[1], wanted, got, reply]
	print("settings effects: %d check(s), %d mismatch(es)" % [EFFECTS.size(), mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("a setting does not reach its system: %d of %d check(s)"
			% [mismatches, EFFECTS.size()])

## One setting's effect, read off the world rather than off the settings object.
func _witness(_vocabulary: Commands, what: String) -> String:
	match what:
		"terrain_shading":
			return _shading_word(_main.get("terrain"))
		"grass_shading":
			var grass: MultiMeshInstance3D = _main.get("grass")
			if grass == null or grass.multimesh == null or grass.multimesh.mesh == null:
				return "?"
			var material: BaseMaterial3D = grass.multimesh.mesh.material as BaseMaterial3D
			return _word_of(material)
		"sun_shadow":
			var sun: DirectionalLight3D = _main.get("sun")
			return "on" if sun != null and sun.shadow_enabled else "off"
		"sky_background":
			# Sky3D owns the sky material now, so the *material's presence* is no longer the
			# switch; the environment's background mode is. The flat fallback is `BG_COLOR`.
			var env: WorldEnvironment = _main.get("world_environment")
			if env == null or env.environment == null:
				return "?"
			return "on" if env.environment.background_mode == Environment.BG_SKY else "off"
		"cloud_level":
			return str(SkyModel.cloud_level)
		"bgm":
			return str(int(_main.get("audio").bgm))
		"sfx":
			return str(int(_main.get("audio").sfx))
		"herd":
			return str(_main.get("bots").count())
		"reflect_wish":
			return str(int(roundf(_main.get("water_reflect").wish)))
	return "?"

func _shading_word(terrain: Node) -> String:
	if terrain == null:
		return "?"
	var mesh: ArrayMesh = terrain.get("mesh")
	if mesh == null or mesh.get_surface_count() == 0:
		return "?"
	return _word_of(mesh.surface_get_material(0) as BaseMaterial3D)

static func _word_of(material: BaseMaterial3D) -> String:
	if material == null:
		return "?"
	return "lit" if material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL else "unshaded"

## The two audio sliders, which the `EFFECTS` list cannot reach on its own. `update` re-applies every
## bed each frame, so a `bgm` write looks right the moment the world is *running* -- and the settings
## screen is a *menu*, which freezes the very frame that would. So this opens the screen, clicks the
## Music slider, and reads the bed's own decibels with the world still frozen: the state a player is
## in when they drag it. The scene's slider pushes the change to the mixer as it moves
## (`applyAudioSettings`), which is the half a witness over `Audio.bgm` is blind to.
func _check_audio_sliders() -> void:
	var menu: Menu = _main.get("menu")
	var audio: Audio = _main.get("audio")
	if menu == null or audio == null:
		_failures.append("the scene did not build the menu and the sound")
		return
	# A headless root viewport comes up 64x64, so the settings panel is laid out off-screen and no
	# click could land on it -- the same sizing `_check_routed` does.
	_main.get_viewport().size = Vector2i(1280, 720)
	var size: Vector2 = _main.get_viewport().get_visible_rect().size
	menu.show_screen("settings")
	var music: Dictionary = _find(menu.layout(size), "bgm")
	var sfx: Dictionary = _find(menu.layout(size), "sfx")
	if music.is_empty() or sfx.is_empty():
		_failures.append("the settings screen has no audio slider")
		return
	var track: Rect2 = music["rect"]
	var sfx_track: Rect2 = sfx["rect"]
	# The left end is silence and the right end is full, and both are read *while the menu is up*.
	# The ends are inset by a hair: `Rect2.has_point` is half-open, so the far edge is not on the
	# slider at all -- a click exactly there would miss it and leave the value where it was.
	menu._press(Vector2(track.position.x, track.get_center().y), size)
	var quiet: float = _music_db(audio)
	menu._press(Vector2(track.position.x + track.size.x - 0.5, track.get_center().y), size)
	var loud: float = _music_db(audio)
	menu._press(Vector2(sfx_track.position.x, sfx_track.get_center().y), size)
	var sfx_at: int = int(audio.sfx)
	menu.show_screen("hud")
	print("audio sliders: music %.1f dB at bgm 0, %.1f dB at bgm 100, sfx %d (frozen frame)"
		% [quiet, loud, sfx_at])
	if quiet > -79.0:
		_failures.append("the Music slider did not silence the music bed on a frozen frame"
			+ " (it is at %.1f dB)" % quiet)
	if loud <= quiet:
		_failures.append("the Music slider did not raise the music bed again (%.1f -> %.1f dB)"
			% [quiet, loud])
	if sfx_at != 0:
		_failures.append("the SFX slider did not reach the sound it scales (sfx %d)" % sfx_at)

## The music bed's own level, in decibels (`Audio.state()["levels"]`). A bed's level is the one part
## of the sound a *frame* decides rather than an event, so it is the thing a settings change has to
## move.
static func _music_db(audio: Audio) -> float:
	var levels: Dictionary = audio.state()["levels"]
	return float(levels.get("sfx.music", 0.0))

## The console's `setting` verb and the menu's screen are one writer: the same `Settings` object.
func _check_shared() -> void:
	var vocabulary: Commands = _main.get("commands")
	var menu: Menu = _main.get("menu")
	if vocabulary == null or menu == null:
		_failures.append("the scene did not build the console and the menu")
		return
	if vocabulary.settings != menu.settings:
		_failures.append("the console and the menu hold different Settings objects")
		return
	# And a write through one is visible to the other, which is the whole reason they share it.
	vocabulary.run("setting cloud low")
	if menu.settings.cloud != "low":
		_failures.append("a setting written by the console did not reach the menu")
	print("shared settings: the console and the menu hold one object")

## The same click, pushed through the *viewport* rather than into `_press`: Godot's own GUI input
## path has to find the menu, and the menu has to be the control it finds. `_check_clicks` proves
## the logic answers a click; this proves the click arrives -- which is the half of the bug a
## logical case cannot see, because a menu that is never handed an event and a menu that mishandles
## one look identical from the inside.
func _check_routed() -> void:
	var menu: Menu = _main.get("menu")
	if menu == null:
		_failures.append("the scene did not build the menu")
		return
	var size: Vector2 = _main.get_viewport().get_visible_rect().size
	# A headless run has no window, and its root viewport comes up 64x64 -- so every panel is laid
	# out off-screen and no click can land on one. The routing is what this checks, so the viewport
	# is given a real size first; the *scene's own* menu is what gets clicked, `CanvasLayer` parent
	# and all, because that is the one difference a bare `Menu` in a `SubViewport` would not cover.
	_main.get_viewport().size = Vector2i(1280, 720)
	size = _main.get_viewport().get_visible_rect().size
	menu.show_screen("main")
	var widget: Dictionary = _find(menu.layout(size), "settings")
	if widget.is_empty():
		_failures.append("the scene's main screen has no settings button")
		return
	var at: Vector2 = (widget["rect"] as Rect2).get_center()
	# A *motion* first: Godot's GUI picking sets `mouse_over` on movement, and a button event is
	# routed to whatever `mouse_over` already holds. A click with no pointer at all is a click on
	# nothing, which is a fact about Godot's input and not about this menu -- but it is also what a
	# gate has to do to stand where a player stands, because a player has to point at a button
	# before they can press it, and pointing is a motion event.
	var motion := InputEventMouseMotion.new()
	motion.position = at
	_main.get_viewport().push_input(motion)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	_main.get_viewport().push_input(event)
	var landed: String = menu.screen
	# The click acts on press, so the release is only tidiness; but a menu that had swallowed the
	# press would still be on `main` here.
	event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = at
	_main.get_viewport().push_input(event)
	menu.show_screen("hud")
	print("routed click: the viewport delivered it to '", landed, "', pointer ", at)
	if landed != "settings":
		_failures.append("a click pushed through the viewport did not reach the menu"
			+ " (it left the screen at '%s')" % landed)

## A `Menu` with no scene, at the settings the oracle was given: enough to lay every screen out.
func _bare_menu() -> Menu:
	var menu := Menu.new()
	var settings := Settings.new()
	settings.bgm = float(SETTINGS_FOR_LAYOUT["bgm"])
	settings.sfx = float(SETTINGS_FOR_LAYOUT["sfx"])
	settings.light = bool(SETTINGS_FOR_LAYOUT["light"])
	settings.shadow = Settings.SHADOW_NAMES[int(SETTINGS_FOR_LAYOUT["shadow"])]
	settings.sky = bool(SETTINGS_FOR_LAYOUT["sky"])
	settings.cloud = Settings.CLOUD_NAMES[int(SETTINGS_FOR_LAYOUT["cloud"])]
	settings.fullscreen = bool(SETTINGS_FOR_LAYOUT["fullscreen"])
	menu.settings = settings
	menu.water_reflect = WaterReflect.new()
	menu.water_reflect.set_wish(float(SETTINGS_FOR_LAYOUT["reflect"]))
	menu.scene_frames = int(SETTINGS_FOR_LAYOUT["frames"])
	return menu

## Every *interactive* widget on every screen is reachable at its own centre, and a panel or a
## group box over it does not eat the click.
##
## This is the case that was missing when the menu first shipped, and its absence is what shipped a
## menu nothing could click: `_press` returned on the first widget whose rectangle held the point,
## which is the *panel*, and the panel covers every control on every screen. A layout case and a
## settings case both passed. A hit test is neither: it is the only thing that says the control a
## player sees is the control the click reaches.
func _check_hits() -> void:
	var menu := _bare_menu()
	var size := Vector2(1280.0, 720.0)
	var cases: int = 0
	var mismatches: int = 0
	var first: String = ""
	for which: String in ["main", "settings", "keymap", "mods"]:
		menu.show_screen(which)
		for widget: Dictionary in menu.layout(size):
			var kind: String = String(widget["kind"])
			if kind != "button" and kind != "toggle" and kind != "combo" and kind != "slider":
				continue
			cases += 1
			var centre: Vector2 = (widget["rect"] as Rect2).get_center()
			var hit: Dictionary = menu.widget_at(centre, size)
			var got: String = String(hit.get("id", ""))
			if got != String(widget["id"]):
				mismatches += 1
				if first == "":
					first = "%s/%s at its own centre hit '%s'" % [which, widget["id"], got]
	menu.free()
	print("hit tests: %d control(s), %d mismatch(es)" % [cases, mismatches])
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("a control is not where its own centre says it is: %d of %d"
			% [mismatches, cases])

## The clicks themselves: a button changes the screen, a toggle flips, a combo advances, a slider
## takes the position it was clicked at -- and a click on the panel's background does *nothing*,
## because `guiPanel` is not a control. The event translation is Godot's; `_press` is the whole of
## the logic, so that is what a headless gate can drive.
func _check_clicks() -> void:
	var menu := _bare_menu()
	var size := Vector2(1280.0, 720.0)
	var fired: Array = []
	menu.on_quit = func() -> void:
		fired.append("quit")
	menu.on_console = func() -> void:
		fired.append("console")
	var mismatches: int = 0
	var first: String = ""

	# The six buttons of the main screen, and the two that leave it.
	menu.show_screen("main")
	for id: String in ["settings", "mods", "keymap"]:
		menu.show_screen("main")
		_click(menu, size, id)
		if menu.screen != id:
			mismatches += 1
			if first == "":
				first = "'%s' left the screen at '%s'" % [id, menu.screen]
		_click(menu, size, "back")
		if menu.screen != "main":
			mismatches += 1
			if first == "":
				first = "'back' from %s left the screen at '%s'" % [id, menu.screen]
	menu.show_screen("main")
	_click(menu, size, "continue")
	if menu.screen != "hud":
		mismatches += 1
		if first == "":
			first = ">continue< left the screen at '%s'" % menu.screen
	menu.show_screen("main")
	_click(menu, size, "console")
	if menu.screen != "hud" or not fired.has("console"):
		mismatches += 1
		if first == "":
			first = "'console' left the screen at '%s' and fired %s" % [menu.screen, fired]
	menu.show_screen("main")
	_click(menu, size, "quit")
	if not fired.has("quit"):
		mismatches += 1
		if first == "":
			first = "'quit' did not fire"

	# A toggle flips, a combo advances, a slider takes the position.
	menu.show_screen("settings")
	var was_light: bool = menu.settings.light
	_click(menu, size, "light")
	if menu.settings.light == was_light:
		mismatches += 1
		if first == "":
			first = "'light' did not flip"
	var was_cloud: String = menu.settings.cloud
	_click(menu, size, "cloud")
	if menu.settings.cloud == was_cloud:
		mismatches += 1
		if first == "":
			first = "'cloud' did not advance"
	var was_wish: float = menu.water_reflect.wish
	_click(menu, size, "reflect")
	if menu.water_reflect.wish == was_wish:
		mismatches += 1
		if first == "":
			first = "'reflect' did not advance"
	var slider: Dictionary = _find(menu.layout(size), "bgm")
	var rect: Rect2 = slider["rect"]
	menu._press(Vector2(rect.position.x + rect.size.x * 0.5, rect.get_center().y), size)
	if absf(menu.settings.bgm - 50.0) > 1.0:
		mismatches += 1
		if first == "":
			first = "the mid-track click set bgm to %s" % menu.settings.bgm

	# A click on the panel's own background is not a click on anything.
	menu.show_screen("main")
	var before: int = menu.settings.bgm
	menu._press(Vector2(20.0, 20.0), size)
	if menu.screen != "main" or menu.settings.bgm != before:
		mismatches += 1
		if first == "":
			first = "a click on the dim changed something"

	menu.free()
	print("clicks: 12 check(s), %d mismatch(es)" % mismatches)
	if first != "":
		print("  first: ", first)
	if mismatches != 0:
		_failures.append("the controls do not answer a click: %d mismatch(es)" % mismatches)

## Click the centre of a named control on the current screen.
func _click(menu: Menu, size: Vector2, id: String) -> void:
	var widget: Dictionary = _find(menu.layout(size), id)
	if widget.is_empty():
		return
	menu._press((widget["rect"] as Rect2).get_center(), size)

static func _find(widgets: Array, id: String) -> Dictionary:
	for widget: Dictionary in widgets:
		if String(widget.get("id", "")) == id:
			return widget
	return {}

## `menu.js`'s `KEYMAP_ROWS`, retyped here so a drift on either side is a failure and not a
## mirrored edit. It is the one table in this gate the oracle does not compute.
func _keymap_rows() -> Array:
	return [
		["W / S", "walk forward / back"],
		["CTRL + W/S", "trot"],
		["SHIFT + W/S", "run"],
		["A / D", "turn left / right"],
		["SPACE", "jump"],
		["E", "eat the grass in reach"],
		["Z", "sleep / wake"],
		["R", "restart after death"],
		["T (hold)", "fast-forward the clock"],
		["C", "next weather"],
		["L", "toggle lighting"],
		["K", "cycle shadows"],
		["B", "toggle the sky shader"],
		["J", "toggle the water"],
		["M", "mute audio"],
		["F11", "toggle fullscreen"],
		["Mouse drag", "orbit the camera"],
		["Mouse wheel", "zoom"],
		["Arrow keys", "orbit the camera"],
		["P", "pause / resume"],
		["`", "open / close the console"],
		["ESC", "main menu / resume"],
	]

## Run one oracle script and hand back its lines, `log ` included.
func _oracle(host: Object, source: String, which: String) -> PackedStringArray:
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle (", which, ") did not run: ", evaluated)
		quit(1)
		return PackedStringArray()
	var lines := PackedStringArray()
	for line in host.call("poll_lines"):
		lines.append(String(line))
	return lines

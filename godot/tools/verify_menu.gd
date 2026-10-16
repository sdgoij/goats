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
# toggle follows the mode, the environment's sky material comes and goes, the cloud march's step
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
    const labels = [S.frames > 0 ? 'Continue' : 'Play', 'Settings', 'Mods', 'Keymap', 'Console', 'Quit'];
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
	["setting sky off", "sky_material", "off"],
	["setting sky on", "sky_material", "on"],
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
		.replace("__ROWS__", JSON.stringify(_keymap_rows()))
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
	_check_shared()
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
		"sky_material":
			var env: WorldEnvironment = _main.get("world_environment")
			if env == null or env.environment == null:
				return "?"
			return "on" if env.environment.sky.sky_material != null else "off"
		"cloud_level":
			return str(SkyDome.cloud_level)
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

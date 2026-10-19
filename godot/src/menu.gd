# The menu (M25): `menu.js`'s four screens, drawn.
#
# Where the console is an overlay that must *not* freeze the world, a menu is the opposite: it is
# a `uiScreen` value, and `sceneFrame` freezes the world by forcing the frame's `dt` to 0 while one
# is up. `main.gd` owns that gate; this file owns the screens -- `main`, `settings`, `mods` and
# `keymap` -- and the one rule that ties them together: **Escape from a sub-screen goes back to
# `main`, from `main` it returns to the game, and from the game it opens `main`**
# (`uiScreen = uiScreen === "hud" ? "main" : uiScreen === "main" ? "hud" : "main"`).
#
# It is a `Control` that *draws*, for the HUD's and the console's reason: the scene builds its
# menus out of raygui at explicit pixel coordinates, so the geometry -- a 300x350 panel centred on
# the screen, six 240x34 buttons from `y + 46` down in tens -- is part of the specification, and a
# panel drawn at the scene's own numbers is something a gate can hold. The layout is a *function
# of the screen size* returning a list of widgets, and `_draw` paints that list while `_gui_input`
# hits the same list, so what is drawn and what is clickable cannot drift.
#
# Three things are deliberately the port's rather than the scene's, and all three are chrome:
#
#   * **the palette.** raygui ships its own default theme; the port has no raygui, so the panel,
#     the controls and the title bars are drawn in a light grey theme of the same shape. The
#     *numbers* are the scene's; the bytes are a lookalike.
#   * **a slider's track.** raygui's `guiSlider` has its own inner padding and its own idea of
#     where the thumb is; the port maps a click's x across the control's own rect. The scene's
#     *rule* -- the value is the position, clamped to the range -- is the same.
#   * **the `Mods` screen's list and its button.** Both come from the runtime the frame hands in: the
#     list from `Mods.mod_table` (`mods_list`) and the Enable/Disable button from `Mods.toggle_mod`
#     (`mod_toggle`, wired by `main.gd`). So the screen is a reader of the runtime and not a second
#     table. A `Menu` with neither -- a gate's, or a build without the extension -- draws
#     `menu.js`'s own degradation, "no mods found", which is what `modsNote` is for.
#
# What the settings screen *does* is real, because M25 gave every control something to reach
# (`settings.gd` and the frame's `apply`): the two gains, the lit/unlit materials, the shadow map,
# the sky program, the cloud march's step count, the reflection tier, fullscreen and the herd's
# size. `PORT.md` section 5 has the two vocabulary notes (`off|map` for shadows, a windowed boot).
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Menu
extends Control

## `menu.js`'s `KEYMAP_ROWS`, verbatim: the key, then what it does.
const KEYMAP_ROWS := [
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

## `SHADOW_LIST`, `CLOUD_LIST` and `REFLECT_LIST`, the combos' own words. `SHADOW_LIST` is the
## scene's three less its `Planar` -- see `settings.gd`'s header.
const SHADOW_LIST: Array[String] = ["None", "Shadow map"]
const CLOUD_LIST: Array[String] = ["Low", "Medium", "High"]
const REFLECT_LIST: Array[String] = ["Sky only", "Ground", "Mirror"]

## `drawMainMenu`'s own numbers.
const MAIN_W := 300.0
const MAIN_H := 350.0
const MAIN_SIDE := 30.0
const MAIN_TOP := 46.0
const BUTTON_H := 34.0
const BUTTON_GAP := 10.0

## `drawSettings`'.
const SET_W := 460.0
const SET_H := 460.0
const SET_SIDE := 20.0
const GROUP_AUDIO_H := 92.0
const GROUP_GRAPHICS_H := 208.0
const GROUP_GAMEPLAY_H := 66.0
const GROUP_TITLE := 26.0
const ROW := 30.0
const ROW_GAP := 46.0
const CONTROL_INSET := 10.0

## `drawMods`'.
const MODS_W := 600.0
const MODS_H := 440.0
const MODS_NOTE_TOP := 34.0
const MODS_LIST_TOP := 60.0
const MODS_ROW := 34.0
const MODS_BUTTON_W := 130.0
const MODS_LABEL_RIGHT := 190.0

## `drawKeymap`'.
const KEY_W := 540.0
const KEY_H := 500.0
const KEY_LEFT := 24.0
const KEY_RIGHT_X := 200.0
const KEY_ROW := 21.0
const KEY_TOP := 44.0

## The one control every screen ends with: `guiButton(x + w / 2 - 60, y + h - 40, 120, 30, "Back")`.
const BACK_W := 120.0
const BACK_H := 30.0
const BACK_BOTTOM := 40.0

## The dim over the frozen world (`drawUi`'s own rectangle) and the chrome. The theme is a
## lookalike of raygui's default -- see the header -- in the port's own palette style.
const DIM := Color(0.0, 0.0, 0.0, 130.0 / 255.0)
const PANEL_BG := Color8(230, 230, 230)
const PANEL_BORDER := Color8(140, 140, 140)
const TITLE_BG := Color8(200, 200, 200)
const TEXT := Color8(60, 60, 60)
const TEXT_MUTED := Color8(110, 110, 110)
const CONTROL_BG := Color8(245, 245, 245)
const CONTROL_HOT := Color8(210, 220, 235)
const CONTROL_ON := Color8(190, 215, 190)

## The title bar raygui draws across the top of a panel, in pixels. raygui sizes it from the text;
## the port fixes it, which is the one place its chrome is a number of its own.
const TITLE_H := 24.0

## Which screen is up: `hud` is the game, and the other four are this file's. It is
## `menu.js`'s `uiScreen` and the frame reads it (`main.gd`'s `ui_screen` is this value).
var screen := "hud"

## The settings object the console also holds (M25). The frame hands in the shared one, so the
## console's `setting` verb and this screen's controls cannot disagree.
var settings := Settings.new()
## The water's reflection tier, which is a *tuning leaf* rather than a `SETTINGS` entry -- the
## scene's own split, and why this screen reaches it directly.
var water_reflect: WaterReflect
## The herd the Gameplay slider sizes.
var bots: Bots
## What the herd-size slider *shows*, which is the frame's answer and not the local herd's: a
## client owns no herd of its own (`main.gd` `_tuning_herd_count`). Invalid for a menu with no
## frame behind it, and then the slider reads the herd it was handed.
var herd_count: Callable = Callable()

## The `Mods` screen's list: a `Callable` answering `menu.js`'s `goats.mods()` shape, an array of
## `{id, name, version, side, enabled, loaded, failed, error}`. Empty for a menu with no runtime
## behind it.
var mods_list: Callable = Callable()
## What a mod's Enable/Disable button answers, or empty for a screen that only reads.
var mod_toggle: Callable = Callable()
## The main menu's action buttons, which the frame owns.
var on_console: Callable = Callable()
var on_quit: Callable = Callable()

## `drawMods`' `modsNote`: the error tail of the last toggle, or empty.
var mods_note := ""
## Frames the scene has run, which is `menu.js`'s `sceneFrames` and what decides the first
## button's word: `Play` before the world has a frame, `Continue` after.
var scene_frames := 0

var _hot := ""
var _dragging := ""

func _ready() -> void:
	# Anchors *and* offsets -- see the note in `hud.gd`. The menu covers the whole screen, takes
	# the mouse while it is up (it is a menu), and is invisible on the game screen.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

## Whether a menu is up, which is `uiIsOpen`. The frame freezes the world on this.
func is_open() -> bool:
	return screen != "hud"

## Show a screen. `hud` hides the menu; every other word is a panel.
func show_screen(which: String) -> void:
	screen = which
	visible = is_open()
	queue_redraw()

## `drawUi`, minus the drawing: the dim, then the active screen's panel.
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), DIM)
	if screen == "hud":
		return
	var font: Font = get_theme_default_font()
	var mouse := get_local_mouse_position()
	_hot = ""
	for widget: Dictionary in layout(get_viewport_rect().size):
		var rect: Rect2 = widget["rect"]
		var kind: String = String(widget["kind"])
		if kind != "panel" and kind != "group" and rect.has_point(mouse):
			_hot = String(widget.get("id", ""))
		_draw_widget(font, widget, rect.has_point(mouse))

## The click, on the widget under it. `menu.js`'s `rl.guiButton`/`guiToggle`/`guiComboBox` return
## their result here, one call at a time.
func _gui_input(event: InputEvent) -> void:
	var view_size: Vector2 = get_viewport_rect().size
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_press(button.position, view_size)
		else:
			_dragging = ""
	elif event is InputEventMouseMotion and _dragging != "":
		_slide(_dragging, (event as InputEventMouseMotion).position, view_size)

## Escape's walk (`menu.js` `sceneFrame`): from a sub-screen back to `main`, from `main` back to
## the game, and from the game to `main`. It is `static` and pure because it is a *rule* -- the
## frame calls it, and a gate holds it with no scene.
static func next_screen(from: String) -> String:
	if from == "hud":
		return "main"
	if from == "main":
		return "hud"
	return "main"

## Pump the redraw, for the console's reason: a retained `Control` paints only when something
## dirties it, and the scene's menu is immediate mode.
func _process(_delta: float) -> void:
	if is_open():
		queue_redraw()

## This screen's widgets, in screen coordinates, for a viewport of `size`. One function because
## `_draw` and `_gui_input` both read it -- the scene's layout is arithmetic on the screen size,
## and keeping it in one place is what stops the drawn button and the clickable button from being
## two rectangles. It takes the size rather than reading the viewport so a gate can lay a screen
## out at any resolution with no window at all.
func layout(view_size: Vector2) -> Array:
	match screen:
		"main":
			return _main_layout(view_size)
		"settings":
			return _settings_layout(view_size)
		"mods":
			return _mods_layout(view_size)
		"keymap":
			return _keymap_layout(view_size)
	return []

## The first button's word, which `menu.js` decides from `sceneFrames`.
static func continue_label(frames: int) -> String:
	return "Continue" if frames > 0 else "Play"

func _main_layout(view_size: Vector2) -> Array:
	var x: float = round((view_size.x - MAIN_W) / 2.0)
	var y: float = round((view_size.y - MAIN_H) / 2.0)
	var out: Array = [{"kind": "panel", "rect": Rect2(x, y, MAIN_W, MAIN_H), "text": "Slag goat"}]
	var bx: float = x + MAIN_SIDE
	var bw: float = MAIN_W - MAIN_SIDE * 2.0
	var by: float = y + MAIN_TOP
	for entry: Array in [
			["continue", continue_label(scene_frames)],
			["settings", "Settings"],
			["mods", "Mods"],
			["keymap", "Keymap"],
			["console", "Console"]]:
		out.append({"kind": "button", "rect": Rect2(bx, by, bw, BUTTON_H),
			"text": String(entry[1]), "id": String(entry[0])})
		by += BUTTON_H + BUTTON_GAP
	# A browser tab has no process to quit -- closing the page is the page's job. `menu.js`
	# says the same thing with `typeof web`; the desktop build keeps the button.
	if not OS.has_feature("web"):
		out.append({"kind": "button", "rect": Rect2(bx, by, bw, BUTTON_H),
			"text": "Quit", "id": "quit"})
	return out

func _settings_layout(view_size: Vector2) -> Array:
	var x: float = round((view_size.x - SET_W) / 2.0)
	var y: float = round((view_size.y - SET_H) / 2.0)
	var lx: float = x + SET_SIDE
	var lw: float = SET_W - SET_SIDE * 2.0
	var cx: float = lx + CONTROL_INSET
	var cw: float = lw - CONTROL_INSET * 2.0
	var cy: float = y + 44.0
	var out: Array = [{"kind": "panel", "rect": Rect2(x, y, SET_W, SET_H), "text": "Settings"}]

	out.append({"kind": "group", "rect": Rect2(lx, cy, lw, GROUP_AUDIO_H), "text": "Audio"})
	cy += GROUP_TITLE
	out.append({"kind": "slider", "rect": Rect2(cx, cy, cw, 24.0), "text": "Music", "id": "bgm",
		"value": settings.bgm, "min": 0.0, "max": 100.0})
	cy += ROW
	out.append({"kind": "slider", "rect": Rect2(cx, cy, cw, 24.0), "text": "SFX", "id": "sfx",
		"value": settings.sfx, "min": 0.0, "max": 100.0})
	cy += ROW_GAP

	out.append({"kind": "group", "rect": Rect2(lx, cy, lw, GROUP_GRAPHICS_H), "text": "Graphics"})
	cy += GROUP_TITLE
	out.append({"kind": "toggle", "rect": Rect2(cx, cy, cw, 24.0), "text": "Light", "id": "light",
		"value": settings.light})
	cy += ROW
	out.append({"kind": "combo", "rect": Rect2(cx, cy, cw, 24.0), "id": "shadow",
		"text": SHADOW_LIST[maxi(0, Settings.index_of(Settings.SHADOW_NAMES, settings.shadow))],
		"options": SHADOW_LIST,
		"selected": maxi(0, Settings.index_of(Settings.SHADOW_NAMES, settings.shadow))})
	cy += ROW
	out.append({"kind": "toggle", "rect": Rect2(cx, cy, cw, 24.0), "text": "Sky shader", "id": "sky",
		"value": settings.sky})
	cy += ROW
	var cloud_at: int = maxi(0, Settings.index_of(Settings.CLOUD_NAMES, settings.cloud))
	out.append({"kind": "combo", "rect": Rect2(cx, cy, cw, 24.0), "id": "cloud",
		"text": CLOUD_LIST[cloud_at], "options": CLOUD_LIST, "selected": cloud_at})
	cy += ROW
	out.append({"kind": "combo", "rect": Rect2(cx, cy, cw, 24.0), "id": "reflect",
		"text": REFLECT_LIST[_reflect_tier()], "options": REFLECT_LIST, "selected": _reflect_tier()})
	cy += ROW
	out.append({"kind": "toggle", "rect": Rect2(cx, cy, cw, 24.0), "text": "Fullscreen",
		"id": "fullscreen", "value": settings.fullscreen})
	cy += ROW_GAP

	out.append({"kind": "group", "rect": Rect2(lx, cy, lw, GROUP_GAMEPLAY_H), "text": "Gameplay"})
	cy += GROUP_TITLE
	out.append({"kind": "slider", "rect": Rect2(cx, cy, cw, 24.0), "text": "Herd size", "id": "herd",
		"value": float(_herd_size()), "min": 0.0, "max": float(Bots.MAX_HERD)})

	out.append(_back(x, y, SET_W, SET_H))
	return out

func _mods_layout(view_size: Vector2) -> Array:
	var x: float = round((view_size.x - MODS_W) / 2.0)
	var y: float = round((view_size.y - MODS_H) / 2.0)
	var out: Array = [{"kind": "panel", "rect": Rect2(x, y, MODS_W, MODS_H), "text": "Mods"}]
	out.append({"kind": "label", "rect": Rect2(x + SET_SIDE, y + MODS_NOTE_TOP,
		MODS_W - SET_SIDE * 2.0, 18.0),
		"text": "this session only - a restart restores the mods/ directory"})
	var mods: Array = mods_list.call() if mods_list.is_valid() else []
	if mods.is_empty():
		out.append({"kind": "label", "rect": Rect2(x + SET_SIDE, y + MODS_LIST_TOP,
			MODS_W - SET_SIDE * 2.0, 20.0),
			"text": "no mods found - put them in mods/ next to the game"})
	var cy: float = y + MODS_LIST_TOP
	for meta: Dictionary in mods:
		if cy >= y + MODS_H - MODS_LIST_TOP - 14.0:
			break
		var label: String = "%s v%s  (%s)" % [String(meta.get("name", "")),
			String(meta.get("version", "")), String(meta.get("side", ""))]
		if bool(meta.get("failed", false)):
			label += "  FAILED: " + String(meta.get("error", ""))
		out.append({"kind": "label", "rect": Rect2(x + SET_SIDE, cy + 5.0,
			MODS_W - MODS_LABEL_RIGHT, 20.0), "text": label})
		out.append({"kind": "button",
			"rect": Rect2(x + MODS_W - 150.0, cy, MODS_BUTTON_W, 28.0),
			"text": "Disable" if bool(meta.get("enabled", false)) else "Enable",
			"id": "mod:" + String(meta.get("id", ""))})
		cy += MODS_ROW
	if mods_note != "":
		out.append({"kind": "label", "rect": Rect2(x + SET_SIDE, y + MODS_H - 62.0,
			MODS_W - SET_SIDE * 2.0, 18.0), "text": mods_note})
	out.append(_back(x, y, MODS_W, MODS_H))
	return out

func _keymap_layout(view_size: Vector2) -> Array:
	var x: float = round((view_size.x - KEY_W) / 2.0)
	var y: float = round((view_size.y - KEY_H) / 2.0)
	var out: Array = [{"kind": "panel", "rect": Rect2(x, y, KEY_W, KEY_H), "text": "Keymap"}]
	var ry: float = y + KEY_TOP
	# The scene's own geometry, overflow and all: 22 rows at 21 px from `y + 44` is 462 px in a
	# 500-tall panel, so the last row sits six pixels past the panel's bottom edge and the Back
	# button is drawn over the two before it. It is what `drawKeymap` does, and a port that
	# "fixed" it would be drawing a different screen.
	for row: Array in KEYMAP_ROWS:
		out.append({"kind": "label", "rect": Rect2(x + KEY_LEFT, ry, 168.0, KEY_ROW),
			"text": String(row[0])})
		out.append({"kind": "label", "rect": Rect2(x + KEY_RIGHT_X, ry, KEY_W - 224.0, KEY_ROW),
			"text": String(row[1])})
		ry += KEY_ROW
	out.append(_back(x, y, KEY_W, KEY_H))
	return out

## Every screen's Back button, at the one position `menu.js` puts it.
func _back(x: float, y: float, w: float, h: float) -> Dictionary:
	return {"kind": "button", "rect": Rect2(x + w / 2.0 - BACK_W / 2.0, y + h - BACK_BOTTOM,
		BACK_W, BACK_H), "text": "Back", "id": "back"}

## The reflection tier the combo shows: `TUNING.water.reflection`, rounded, which is the scene's
## own `Math.round(TUNING.water.reflection)`.
func _reflect_tier() -> int:
	if water_reflect == null:
		return 0
	return clampi(int(roundf(water_reflect.wish)), 0, REFLECT_LIST.size() - 1)

## The herd size the Gameplay slider shows: the frame's own answer (`goats.tuning`'s read), because
## a client owns no herd and the number it can mean there is the one the player can *see* -- the
## flock it mirrors. Drawing `bots.count()` instead is a herd of zero on every client. `menu.js`
## reads `TUNING.herd.count` and the console and a mod read the same value, so one answer for all
## of them is the rule `settings.gd` keeps for every other control: two owners is how they drift.
func _herd_size() -> int:
	if herd_count.is_valid():
		return int(herd_count.call())
	return bots.count() if bots != null else 0

## The widget a click at `at` lands on, for a viewport of `size`: the topmost **interactive** one,
## skipping the panel, the group boxes and the labels.
##
## That skip is the whole point, and its absence was a real bug: `guiPanel`, `guiGroupBox` and
## `guiLabel` return nothing in the scene, so a click passes *through* them to whatever they cover
## -- and the panel covers every control on every screen. The first version of `_press` returned on
## the first widget whose rectangle held the point, which is the panel, so no button was ever
## reached on any screen. It looked right, and a picture of a menu cannot click.
##
## It takes the size rather than reading the viewport so a gate can ask "what is under this point"
## at any resolution with no window at all -- which is the case that would have caught the bug.
func widget_at(at: Vector2, view_size: Vector2) -> Dictionary:
	for widget: Dictionary in layout(view_size):
		match String(widget["kind"]):
			"button", "toggle", "combo", "slider":
				if (widget["rect"] as Rect2).has_point(at):
					return widget
			_:
				continue
	return {}

## A click: a button acts, a toggle flips, a combo advances, a slider takes the position.
func _press(at: Vector2, view_size: Vector2) -> void:
	var widget: Dictionary = widget_at(at, view_size)
	if widget.is_empty():
		return
	match String(widget["kind"]):
		"button":
			_act(String(widget["id"]))
		"toggle":
			_flip(String(widget["id"]))
		"combo":
			_cycle(widget)
		"slider":
			_dragging = String(widget["id"])
			_slide(_dragging, at, view_size)

func _slide(id: String, at: Vector2, view_size: Vector2) -> void:
	for widget: Dictionary in layout(view_size):
		if String(widget.get("id", "")) != id or String(widget["kind"]) != "slider":
			continue
		var rect: Rect2 = widget["rect"]
		var low: float = float(widget["min"])
		var high: float = float(widget["max"])
		var t: float = clampf((at.x - rect.position.x) / maxf(rect.size.x, 1.0), 0.0, 1.0)
		var value: float = low + (high - low) * t
		_set_slider(id, value)
		return

## Move a slider's own value to `value`, which is `guiSlider`'s return in the scene: the control
## reports the number and its reader decides what that means.
func _set_slider(id: String, value: float) -> void:
	match id:
		"bgm":
			settings.bgm = clampf(roundf(value), 0.0, 100.0)
		"sfx":
			settings.sfx = clampf(roundf(value), 0.0, 100.0)
		"herd":
			if bots != null:
				bots.set_herd_size(int(roundf(value)))
		_:
			return
	settings.push()
	queue_redraw()

func _flip(id: String) -> void:
	match id:
		"light":
			settings.light = not settings.light
		"sky":
			settings.sky = not settings.sky
		"fullscreen":
			settings.fullscreen = not settings.fullscreen
		_:
			return
	settings.push()
	queue_redraw()

## A combo advances to the next option and wraps, which is what clicking raygui's `guiComboBox`
## does -- the scene reads the returned `value` and writes the leaf.
func _cycle(widget: Dictionary) -> void:
	var id: String = String(widget["id"])
	var options: Array = widget["options"]
	var next: int = (int(widget["selected"]) + 1) % options.size()
	match id:
		"shadow":
			settings.shadow = Settings.SHADOW_NAMES[next]
		"cloud":
			settings.cloud = Settings.CLOUD_NAMES[next]
		"reflect":
			if water_reflect != null:
				water_reflect.set_wish(float(next))
		_:
			return
	settings.push()
	queue_redraw()

## A button: the four screens, the console, quitting, leaving a sub-screen, and a mod's toggle.
func _act(id: String) -> void:
	match id:
		"continue":
			show_screen("hud")
		"settings", "mods", "keymap":
			show_screen(id)
		"back":
			# A sub-screen goes back to `main`, never straight to the game -- `menu.js`'s own
			# Back button, and the same place Escape lands.
			show_screen("main")
		"console":
			# The console opens *from the HUD*: the menu's button closes the menu and opens it,
			# which is `drawMainMenu`'s own two lines.
			show_screen("hud")
			if on_console.is_valid():
				on_console.call()
		"quit":
			if on_quit.is_valid():
				on_quit.call()
		_:
			if id.begins_with("mod:"):
				_toggle_mod(id.substr(4))
	queue_redraw()

func _toggle_mod(mod_id: String) -> void:
	if not mod_toggle.is_valid():
		# A `Menu` with no runtime behind it -- a gate's, or a build without the extension -- says so
		# in `modsNote`, which is exactly what that label is for.
		mods_note = "mod enable is unavailable"
		return
	var reply: String = String(mod_toggle.call(mod_id))
	mods_note = reply.substr(6) if reply.begins_with("error ") else ""

## One widget, painted. The scene's chrome is raygui's; the shapes here are the same and the
## numbers are the scene's.
func _draw_widget(font: Font, widget: Dictionary, hot: bool) -> void:
	var rect: Rect2 = widget["rect"]
	var kind: String = String(widget["kind"])
	match kind:
		"panel":
			draw_rect(rect, PANEL_BG)
			draw_rect(rect, PANEL_BORDER, false, 1.0)
			draw_rect(Rect2(rect.position, Vector2(rect.size.x, TITLE_H)), TITLE_BG)
			_text(font, rect.position + Vector2(8.0, 4.0), String(widget["text"]), TEXT, 16)
		"group":
			draw_rect(rect, CONTROL_BG)
			draw_rect(rect, PANEL_BORDER, false, 1.0)
			_text(font, rect.position + Vector2(8.0, 2.0), String(widget["text"]), TEXT_MUTED, 14)
		"label":
			_text(font, rect.position + Vector2(0.0, 2.0), String(widget["text"]), TEXT, 14)
		"button":
			draw_rect(rect, CONTROL_HOT if hot else CONTROL_BG)
			draw_rect(rect, PANEL_BORDER, false, 1.0)
			_centred(font, rect, String(widget["text"]), 16)
		"toggle":
			var on: bool = bool(widget["value"])
			draw_rect(rect, CONTROL_ON if on else CONTROL_BG)
			draw_rect(rect, PANEL_BORDER, false, 1.0)
			_text(font, rect.position + Vector2(8.0, 4.0), String(widget["text"]), TEXT, 14)
			_text(font, rect.position + Vector2(rect.size.x - 30.0, 4.0),
				"ON" if on else "OFF", TEXT_MUTED, 14)
		"slider":
			draw_rect(rect, CONTROL_BG)
			draw_rect(rect, PANEL_BORDER, false, 1.0)
			var low: float = float(widget["min"])
			var high: float = float(widget["max"])
			var t: float = 0.0 if high <= low else clampf((float(widget["value"]) - low) / (high - low), 0.0, 1.0)
			draw_rect(Rect2(rect.position + Vector2(1.0, 1.0),
				Vector2((rect.size.x - 2.0) * t, rect.size.y - 2.0)), CONTROL_HOT)
			_text(font, rect.position + Vector2(6.0, 4.0), String(widget["text"]), TEXT, 14)
			_text(font, rect.position + Vector2(rect.size.x - 44.0, 4.0),
				str(num_word(float(widget["value"]))), TEXT_MUTED, 14)
		"combo":
			draw_rect(rect, CONTROL_HOT if hot else CONTROL_BG)
			draw_rect(rect, PANEL_BORDER, false, 1.0)
			_text(font, rect.position + Vector2(6.0, 4.0), String(widget["text"]), TEXT, 14)
			# The arrow raygui draws at a combo's right edge.
			_text(font, rect.position + Vector2(rect.size.x - 16.0, 4.0), "v", TEXT_MUTED, 14)

## A slider's read-out, and `ctl.js`'s `ctlRound` in spirit: `Math.round(v * 100) / 100` is what
## the console prints, and a slider's own value is a whole number in every control here.
static func num_word(value: float) -> int:
	return int(roundf(value))

func _centred(font: Font, rect: Rect2, text: String, font_size: int) -> void:
	if font == null:
		return
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	_text(font, rect.position + Vector2((rect.size.x - width) / 2.0, 8.0), text, TEXT, font_size)

## `rl.drawText` draws from a text's top left and `draw_string` from the baseline, so every call
## adds the ascent back -- the same helper `hud.gd` and `console.gd` need.
func _text(font: Font, at: Vector2, text: String, color: Color, font_size: int) -> void:
	if font == null:
		return
	draw_string(font, Vector2(at.x, at.y + font.get_ascent(font_size)), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)

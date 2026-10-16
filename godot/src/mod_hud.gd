# The mods' drawing, painted (stage 1's other half): the API's own `goats.draw` surface
# (`APIv1.md` section 4.18), which a mod calls from a hook and this puts on the screen.
#
# It exists because the port has no raylib. A mod's draws arrive as *records* the extension
# queued (`ModHost::poll_draws`), and something has to paint them; doing it here rather than in
# the extension is the same division as everywhere else in the port -- the extension knows
# JavaScript and Godot, the scripts know Godot -- and it keeps the drawing inside the frame the
# mod asked for, because the records are drained once and painted once.
#
# Two conventions come straight from the API and are the reason this file has any arithmetic in
# it at all: a colour is `{r, g, b, a}` in 0..255, and **`y` is the *top* of a line of text**
# rather than its baseline -- so `text` adds the font's ascent before handing the position to
# Godot, which measures from the baseline. Every length is a pixel of the surface the hook was
# handed, so nothing here converts anything else.
class_name ModHud
extends Control

## The records drained this frame, in call order: one `{k, ...}` per `goats.draw` call.
## `_draw` paints them, and a gate can read them -- the same split the layout gates make, where
## the list is data and the painting is Godot's.
var commands: Array = []
## Frames this control was handed something to paint. Evidence rather than a decision.
var frames := 0
## Paint passes `_draw` has run, since a frame's records are not proof they were drawn.
var paints := 0

func _ready() -> void:
	# Anchors *and* offsets -- a `Control` under a `CanvasLayer` gets anchors from
	# `set_anchors_preset` alone and keeps a size of nothing (see `hud.gd`).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The mods' drawing is looked at, never touched: the camera's drag has to reach
	# `main.gd`, exactly as the console's and the HUD's do.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

## Take one frame's records. Parsing here rather than in `_draw` keeps the paint path a plain
## loop, and a record that does not parse is dropped rather than failing the frame.
##
## The list *is* what is on screen, which is what makes this immediate mode: a mod that drew
## last frame and not this one is cleared, and a frame with nothing to draw is not painted.
func adopt(records: PackedStringArray) -> void:
	commands.clear()
	for record in records:
		var parsed: Variant = JSON.parse_string(String(record))
		if parsed is Dictionary:
			commands.append(parsed)
	visible = not commands.is_empty()
	if visible:
		frames += 1
	queue_redraw()

func _draw() -> void:
	paints += 1
	for command: Dictionary in commands:
		_paint(command)

## One record. An unknown kind draws nothing: the extension and this file are the two ends of
## one list, and a record from a newer provider is not a reason to fail a frame.
func _paint(command: Dictionary) -> void:
	var at := Vector2(float(command.get("x", 0.0)), float(command.get("y", 0.0)))
	var col: Color = _color(command.get("col", null))
	match String(command.get("k", "")):
		"text":
			var size: int = int(command.get("size", 20.0))
			var font: Font = get_theme_default_font()
			# The API's `y` is the top of the line; Godot's baseline is what it draws from.
			var baseline: float = at.y + font.get_ascent(size)
			draw_string(font, Vector2(at.x, baseline), String(command.get("s", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, col)
		"rect":
			draw_rect(Rect2(at, _size(command)), col)
		"rectLines":
			draw_rect(Rect2(at, _size(command)), col, false, 1.0)
		"line":
			var to := Vector2(float(command.get("x2", 0.0)), float(command.get("y2", 0.0)))
			draw_line(at, to, col, 1.0)
		"circle":
			draw_circle(at, float(command.get("r", 0.0)), col)
		"circleLines":
			draw_arc(at, float(command.get("r", 0.0)), 0.0, TAU, 48, col, 1.0)

static func _size(command: Dictionary) -> Vector2:
	return Vector2(float(command.get("w", 0.0)), float(command.get("h", 0.0)))

## A record's colour as a Godot `Color`. The API's is `{r, g, b, a}` in 0..255, and a record with
## nothing to say about its colour draws opaque white rather than not drawing -- a mod's mistake
## about a colour is not a reason to lose the primitive it was drawing.
static func _color(value: Variant) -> Color:
	if not (value is Dictionary):
		return Color.WHITE
	var datum: Dictionary = value
	return Color8(int(datum.get("r", 255.0)), int(datum.get("g", 255.0)),
		int(datum.get("b", 255.0)), int(datum.get("a", 255.0)))

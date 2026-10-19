# The names above the swarm's rings, and the session's exit: `PORTALS.labels` from the
# scene, drawn in screen space.
#
# A label is the one thing a portal needs that the world geometry cannot draw, and the
# scene has no 3D text either -- so it projects a point above the ring into pixels and
# draws there. `Camera3D.unproject_position` is that projection in Godot, which replaces
# the hand-rolled look-at and 55-degree perspective the reference has to do itself.
#
# Labels belong to the HUD branch: a menu replaces the HUD rather than covering it
# (`sceneFrame`), so this draws only when no menu is up. In a session as a client there is
# one amber "Exit session" label instead of the hosts'.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name PortalLabels
extends Control

const BACKGROUND := Color(8.0 / 255.0, 12.0 / 255.0, 16.0 / 255.0, 170.0 / 255.0)
const TEXT := Color(190.0 / 255.0, 248.0 / 255.0, 255.0 / 255.0, 240.0 / 255.0)
const EXIT_TEXT := Color(255.0 / 255.0, 228.0 / 255.0, 160.0 / 255.0, 240.0 / 255.0)
## `rl.drawText`'s own size in the scene's `PORTALS.labels`.
const SIZE := 18

## The swarm's hosts, kept in step by `main.gd`.
var hosts: Array = []
## The world camera, handed in once at boot.
var camera: Camera3D

var _px := 0.0
var _pz := 0.0
var _hidden := true
var _client := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## This frame's goat position, whether the labels are hidden (a menu, or hosting), and
## whether this client is inside a session. `main.gd` calls it once a frame, right after
## the rings are placed.
func refresh(px: float, pz: float, is_hidden: bool, client: bool) -> void:
	_px = px
	_pz = pz
	_hidden = is_hidden
	_client = client
	queue_redraw()

func _draw() -> void:
	if _hidden or camera == null:
		return
	var font: Font = get_theme_default_font()
	if font == null:
		return
	if _client:
		_label(font, Portals.exit_place(), "Exit session", EXIT_TEXT)
		return
	if hosts.is_empty():
		return
	for entry: Dictionary in Portals.nearest(hosts, _px, _pz):
		var host: Dictionary = entry["host"]
		var clients: int = int(host.get("clients", 0))
		var text: String = String(host.get("name", ""))
		if clients > 1:
			text += "  ·  %d goats" % clients
		_label(font, entry["place"], text, TEXT)

func _label(font: Font, place: Dictionary, text: String, colour: Color) -> void:
	var top: float = Terrain.height_at(float(place["x"]), float(place["z"])) \
		+ Portals.MIDDLE + Portals.RADIUS + 0.35
	var world := Vector3(float(place["x"]), top, float(place["z"]))
	if camera.is_position_behind(world):
		return
	var point: Vector2 = camera.unproject_position(world)
	var viewport_size: Vector2 = get_viewport_rect().size
	# Off the drawable by more than a label's width: the projection is still meaningful,
	# but nothing would land on screen.
	if point.x < -300.0 or point.x > viewport_size.x + 300.0 \
			or point.y < -100.0 or point.y > viewport_size.y + 100.0:
		return
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE).x
	var left: float = roundf(point.x - width * 0.5)
	var line: float = roundf(point.y - float(SIZE) * 0.5)
	draw_rect(Rect2(left - 7.0, line - 4.0, width + 14.0, float(SIZE) + 8.0), BACKGROUND)
	# `rl.drawText` draws from the text's *top left*; `draw_string` from the baseline.
	draw_string(font, Vector2(left, line + font.get_ascent(SIZE)), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, SIZE, colour)

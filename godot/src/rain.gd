# The rain overlay: `weather.js`'s `drawRain`, a screen-space 2D pass over the 3D
# scene.
#
# It is a `Control` on the same `CanvasLayer` as the HUD and *before* it, so the
# streaks land under the read-out the way the scene draws them (`drawRain` runs after
# `endMode3D()` and before `drawHud`). The drops themselves are not drawn here: the
# weather owns the pool and steps it (`Weather.update_rain`), and this only reads --
# which is what keeps drawing and simulation apart, and what lets a client, whose
# values came off the wire, draw the same rain.
#
# The geometry is the scene's. A drop's position is a *unit* coordinate scaled by the
# viewport, not a world position, so the overlay is resolution-independent: `x` and `y`
# in `0..1`, a length of `0.045 * h` scaled by the drop's own speed, and a slant that is
# the wind's x component times `0.035`. Nothing is clipped or binned -- at full rain
# that is `TUNING.weather.rainMax` one-pixel lines, which is cheap.
#
# `mouse_filter` is `IGNORE` and not Godot's default `STOP` for a `Control`: a
# full-viewport control that consumes the mouse would swallow the camera drag before
# `main.gd`'s `_unhandled_input` ever saw it.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Rain
extends Control

## `weather.js` `drawRain`'s `col` -- `rl.color(182, 202, 232, 150)`.
const COLOUR := Color(182.0 / 255.0, 202.0 / 255.0, 232.0 / 255.0, 150.0 / 255.0)
## `drawRain`'s `slant` factor and the streak's length factor.
const SLANT := 0.035
const LENGTH := 0.045
## `drawRain`'s `(0.6 + d.speed)`: the shortest a streak can be.
const SPEED_BIAS := 0.6

## The machine whose pool is drawn, and this frame's wind. Both are handed in
## (`show_for`) rather than reached for, because the weather is `main.gd`'s and the
## wind is the wire's or the scene's depending on whether there is a session.
var _weather: Weather
var _wind_x := 0.0

func _ready() -> void:
	# A `Control` defaults to `STOP`, which would eat the mouse the camera wants.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## The one call a frame: which weather, and the wind that slants it.
func show_for(weather: Weather, wind_x: float) -> void:
	_weather = weather
	_wind_x = wind_x
	queue_redraw()

## `drawRain`, one `draw_line` per live drop. A drop's `x`/`y` are fractions of the
## viewport, so the streak is placed in the same normalised space the update moves it
## in; the endpoints are rounded the way the scene rounds them, because raylib's
## `drawLine` takes whole pixels and a half-pixel line is a blurred one.
func _draw() -> void:
	if _weather == null:
		return
	var active: int = _weather.rain_active()
	if active <= 0:
		return
	var viewport: Vector2 = get_viewport_rect().size
	var slant: float = _wind_x * SLANT * viewport.x
	var drops: Array = _weather.drops
	for i in active:
		var drop: Dictionary = drops[i]
		var sx: float = roundf(float(drop["x"]) * viewport.x)
		var sy: float = roundf(float(drop["y"]) * viewport.y)
		var length: float = LENGTH * viewport.y * (SPEED_BIAS + float(drop["speed"]))
		draw_line(Vector2(sx, sy), Vector2(sx + slant, sy + length), COLOUR, 1.0)

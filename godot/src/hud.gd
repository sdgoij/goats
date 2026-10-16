# The HUD: `goat.js`'s `drawHud`, drawn.
#
# This replaces a one-`Label` stand-in whose words were the scene's and whose layout was not. The
# scene's HUD is *immediate mode* -- `rl.drawRectangle` and `rl.drawText` at pixel coordinates --
# so this is a `Control` that draws, rather than a tree of nested nodes: the geometry is part of
# the specification (a bar is 160 wide at twelve from the right edge, the action prompt is a
# 132x34 box in the corner) and a scene is easier to check against than a pile of anchors.
#
# Five things are drawn, and each is where the scene puts it:
#
#   * the **damage pulse**, four bands of red under everything (`explosions.gd`'s `hurt_pulse`,
#     which `drawDamagePulse` reads and `hurtBy` sets -- the strongest unrecovered hit wins, so a
#     second bang cannot make a bruise look like a scratch);
#   * the **health and energy bars**, top right, with the read-out line under them;
#   * the sleep cue, `Z z z`, where the bars' read-out would be;
#   * the **action prompt**, bottom right, when a tuft is in reach;
#   * and the **weather line** and the **status line**, bottom left.
#
# Everything the *rules* decide is a `static` function here rather than a line inside `_draw`:
# the state word (a chain over the mode, the frame's move axis and the pause), the status line's
# composition, the weather line's terms, a bar's fill and the pulse's two numbers. That is what a
# headless case can hold, and `verify_hud.gd` holds every one of them against `goat.js`, because
# the layout -- which is what is left -- is a picture's question.
#
# Two of the scene's words are *settings* read-outs rather than state: `light` (the lit shader and
# its shadow mode) and `sky`/`clouds`. The port has no settings screen yet, so they are the
# scene's defaults -- and there is no `belly (wasm)` bar, because a compiled client mod's
# `goats_hud` needs the wasm path that stages 1 and 8 still owe.
class_name Hud
extends Control

## `drawHud`'s own numbers.
const BAR_WIDTH := 160.0
const BAR_HEIGHT := 14.0
const BAR_MARGIN := 12.0
const BAR_PAD := 1.0
const INNER_HEIGHT := 12.0
const READOUT_Y := 50.0
const SLEEP_Y := 70.0
const ACTION_WIDTH := 132.0
const ACTION_HEIGHT := 34.0
const ACTION_MARGIN := 12.0
const WEATHER_Y := 44.0
const STATUS_Y := 24.0

## The colours, as the scene's `rl.color` calls give them.
const BAR_BG := Color(28.0 / 255.0, 28.0 / 255.0, 34.0 / 255.0, 220.0 / 255.0)
const HEALTH_FILL := Color(208.0 / 255.0, 62.0 / 255.0, 62.0 / 255.0)
const ENERGY_FILL := Color(222.0 / 255.0, 190.0 / 255.0, 62.0 / 255.0)
const ACTION_BG := Color(24.0 / 255.0, 26.0 / 255.0, 32.0 / 255.0, 220.0 / 255.0)
const WARM := Color(232.0 / 255.0, 201.0 / 255.0, 116.0 / 255.0)
const TEXT := Color(245.0 / 255.0, 245.0 / 255.0, 245.0 / 255.0)
const PULSE := Color(150.0 / 255.0, 20.0 / 255.0, 16.0 / 255.0)

## The four text sizes the HUD uses: the two lines, the sleep cue, and the prompt's two halves.
const SIZE_LINE := 14
const SIZE_SLEEP := 20
const SIZE_ACTION := 18
const SIZE_KEY := 16

## The three setting read-outs the status line carries. Stage 6's settings screen drives them;
## until then they are the scene's defaults -- and the lighting word is the scene's own `shadowMode`
## of 2, which is the map, because a Godot shadow map is what this port uses.
var light_word := "lit + shadow map"
var sky_word := "shader"
var cloud_word := "medium"

var _goat: PlayerGoat
var _hours := 0.0
var _speed := 0.0
var _phase := 0.0
var _weather := {}
var _water := ""
var _move := 0
var _paused := false
var _food_ready := false
var _herd := 0
var _fps := 0
var _audio := ""
var _hurt := 0.0

func _ready() -> void:
	# Anchors *and* offsets: `set_anchors_preset` alone leaves the offsets where they were, so a
	# control whose parent is a `CanvasLayer` keeps a size of nothing and draws off the left edge.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The HUD draws over everything and touches nothing: a `Control` that stopped the mouse would
	# eat the camera's drag before `main.gd` ever saw it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Refresh from the goat and the world, once a frame.
##
## `hours` is the clock `main.gd` owns, `weather` the session's snapshot or the local machine's
## values offline, `water` the water's own line (`water.gd`, already empty on dry ground), and
## `world` the few things only the frame knows: `move` (this frame's walk axis), `paused`, `herd`
## (how many goats the herd holds), `food_ready`, `hurt` (the damage pulse) and `audio` (the word
## `audio.gd` reports). Every one of them is a number a rule already decided.
func show_for(goat: PlayerGoat, hours: float, weather: Dictionary, water: String,
		world: Dictionary = {}) -> void:
	_goat = goat
	_hours = hours
	_speed = goat.speed
	_phase = goat.phase
	_weather = weather
	_water = water
	_move = int(world.get("move", 0))
	_paused = bool(world.get("paused", false))
	_food_ready = bool(world.get("food_ready", false))
	_herd = int(world.get("herd", 0))
	_fps = int(world.get("fps", Engine.get_frames_per_second()))
	_audio = String(world.get("audio", ""))
	_hurt = float(world.get("hurt", 0.0))
	queue_redraw()

## `drawHud`'s state word, transcribed. `move` is the frame's *axis*, which is the whole
## difference between "walking forward" and "walking backward" -- and there is no word for an
## exhausted goat, because an exhausted one is capped at a walk by a rule and reads as walking.
static func state_word(move: int, mode: String, paused: bool) -> String:
	if mode == "dead":
		return "dead - R to restart"
	if paused:
		return "paused (P to resume)"
	if mode == "sleep":
		return "sleeping (Z to wake)"
	if mode == "jump":
		return "jumping"
	if mode == "eat":
		return "eating"
	if move > 0 and mode == "run":
		return "running"
	if move > 0 and mode == "trot":
		return "trotting"
	if move > 0:
		return "walking forward"
	if move < 0:
		return "walking backward"
	return "standing"

## `drawHud`'s status line: the clock, the speed through the clip, the phase, the frame rate, and
## the four read-outs `sceneFrame` keeps track of.
static func status_line(clock: String, speed: float, phase: float, fps: int, light: String,
		sky: String, clouds: String, audio: String, herd: int) -> String:
	return "%s   speed %.2f m/s   phase %.2f   fps %d   light %s   sky %s   clouds %s   audio %s   herd %d" \
		% [clock, speed, phase, fps, light, sky, clouds, audio, herd]

## `weather.js` `updateWeatherEffects`'s `weatherText`: the state, the wind, and the rain, the
## slowdown and the water only when there is any of each to report -- so a `clear` frame on dry
## ground reads exactly as it always has. `speed` is the goat's own weather factor, which is where
## the `slowed` term comes from: `weatherSpeed < 0.98` is the scene's own threshold.
static func weather_text(weather: Dictionary, water: String = "", speed: float = 1.0) -> String:
	var text: String = String(weather.get("kind", "clear"))
	var wx: float = float(weather.get("wind_x", 0.0))
	var wz: float = float(weather.get("wind_z", 0.0))
	text += "   wind %.1f m/s" % sqrt(wx * wx + wz * wz)
	var rain: float = float(weather.get("rain_amount", 0.0))
	if rain > 0.02:
		text += "   rain %d%%" % int(round(rain * 100.0))
	if speed < 0.98:
		text += "   slowed %d%%" % int(round((1.0 - speed) * 100.0))
	if water != "":
		text += "   " + water
	return text

## `drawHud`: `HH:MM`, zero-padded, from the hour of the day.
static func clock_text(hours: float) -> String:
	var hh: int = int(floor(hours))
	var mm: int = int(floor((hours - float(hh)) * 60.0))
	return "%02d:%02d" % [hh, mm]

## How wide a bar's fill is, in pixels: `Math.round((bw - 2) * value / max)`. The scene hands the
## fraction in directly, so this takes one too -- the rules keep health, energy and the belly
## inside their own ranges.
static func bar_fill(fraction: float) -> float:
	return round((BAR_WIDTH - 2.0 * BAR_PAD) * fraction)

## `drawDamagePulse`'s two numbers, both functions of the pulse: the bands' thickness and the
## tint's alpha. A pulse above one is drawn as one, which is what `a = hurtPulse > 1 ? 1 : hurtPulse`
## is for -- `hurtBy` clamps on the way in, so this only guards the arithmetic.
static func pulse_band(hurt: float) -> float:
	return round(24.0 + 46.0 * pulse_alpha(hurt))

static func pulse_alpha(hurt: float) -> float:
	return minf(hurt, 1.0)

func _draw() -> void:
	if _goat == null:
		return
	var font: Font = get_theme_default_font()
	# The scene's own `rl.getScreenWidth()`/`getScreenHeight()`, which is the viewport rather than
	# this control -- the HUD is an overlay and its corners are the screen's.
	var screen: Vector2 = get_viewport_rect().size
	var wide: float = screen.x
	var tall: float = screen.y
	var bx: float = wide - BAR_WIDTH - BAR_MARGIN

	_draw_pulse(wide, tall)
	_draw_bar(bx, 10.0, float(_goat.health) / PlayerGoat.STATS_MAX, HEALTH_FILL)
	_draw_bar(bx, 30.0, float(_goat.energy) / PlayerGoat.STATS_MAX, ENERGY_FILL)
	_text(font, bx, READOUT_Y, SIZE_LINE, "health %d   energy %d   belly %d%%" % [
		int(round(_goat.health)), int(round(_goat.energy)),
		int(round(_goat.satiety * 100.0))])
	if _goat.mode == "sleep":
		_text(font, bx, SLEEP_Y, SIZE_SLEEP, "Z z z")
	if _food_ready:
		_draw_action(font, wide, tall)
	_text(font, 10.0, tall - WEATHER_Y, SIZE_LINE,
		weather_text(_weather, _water, _goat.weather_speed_now()))
	_text(font, 10.0, tall - STATUS_Y, SIZE_LINE, "%s   %s" % [_status(), _state()])

## A bar: the trough, then the fill one pixel in, which is the scene's own inset.
func _draw_bar(x: float, y: float, fraction: float, fill: Color) -> void:
	draw_rect(Rect2(x, y, BAR_WIDTH, BAR_HEIGHT), BAR_BG)
	draw_rect(Rect2(x + BAR_PAD, y + BAR_PAD, bar_fill(fraction), INNER_HEIGHT), fill)

## The action menu: a tuft is in reach, so offer the Eat action.
func _draw_action(font: Font, wide: float, tall: float) -> void:
	var mx: float = wide - ACTION_WIDTH - ACTION_MARGIN
	var my: float = tall - ACTION_HEIGHT - ACTION_MARGIN
	draw_rect(Rect2(mx, my, ACTION_WIDTH, ACTION_HEIGHT), ACTION_BG)
	draw_rect(Rect2(mx, my, ACTION_WIDTH, ACTION_HEIGHT), WARM, false, 1.0)
	_text(font, mx + 12.0, my + 9.0, SIZE_ACTION, "Eat")
	_text(font, mx + ACTION_WIDTH - 34.0, my + 11.0, SIZE_KEY, "(E)", WARM)

## The red frame: four bands rather than a screenful of tint, which is the scene's own choice and
## reads the same.
func _draw_pulse(wide: float, tall: float) -> void:
	if _hurt <= 0.0:
		return
	var alpha: float = pulse_alpha(_hurt)
	var band: float = pulse_band(_hurt)
	var tint := Color(PULSE.r, PULSE.g, PULSE.b, round(120.0 * alpha) / 255.0)
	draw_rect(Rect2(0.0, 0.0, wide, band), tint)
	draw_rect(Rect2(0.0, tall - band, wide, band), tint)
	draw_rect(Rect2(0.0, 0.0, band, tall), tint)
	draw_rect(Rect2(wide - band, 0.0, band, tall), tint)

## The one line's two halves, from the frame's own values.
func _status() -> String:
	return status_line(clock_text(_hours), _speed, _phase, _fps, light_word, sky_word,
		cloud_word, _audio, _herd)

func _state() -> String:
	return state_word(_move, String(_goat.mode), _paused)

## `rl.drawText` draws from the text's *top left*; `draw_string` draws from the baseline, so every
## call here adds the ascent back. It is the one place the two graphics APIs differ and the reason
## this is a helper rather than a call.
func _text(font: Font, x: float, y: float, font_size: int, text: String,
		color: Color = TEXT) -> void:
	if font == null:
		return
	draw_string(font, Vector2(x, y + font.get_ascent(font_size)), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)

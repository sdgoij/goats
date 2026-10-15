# The HUD: the goat's state, its health and energy, and the clock.
#
# `goat.js`'s `drawHud` is the real thing -- bars, the action menu the console
# drives, the weather line, the FPS -- and it is stage 6, which is a `Control` tree
# with a font and a layout. This is the *words* half of it and only the words: one
# `Label`, so the local goat has some feedback while the UI stage does not exist.
# The formats are the scene's (`clockText`, `weatherText`); the placement is not.
class_name Hud
extends Label

## Top-left, with a margin, and an outline so it reads over bright ground. The
## scene draws its HUD at the same corner.
const MARGIN := Vector2(12.0, 10.0)

func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = MARGIN
	add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	add_theme_constant_override("outline_size", 4)
	text = ""

## Refresh from the goat and the world, once a frame.
##
## `hours` is the clock `main.gd` owns, `weather` the session's own snapshot or the
## local machine's values offline, and `tuning` is none of its business: every number
## here is one a rule already decided.
func show_for(goat: PlayerGoat, hours: float, weather: Dictionary) -> void:
	var lines: Array[String] = [
		goat.status(),
		"health %3d   energy %3d%s" % [
			int(round(goat.health)), int(round(goat.energy)),
			"   exhausted" if goat.exhausted else ""],
		"belly %.2f   speed %.2f m/s" % [goat.satiety, goat.speed],
		"%s   %s" % [clock_text(hours), weather_text(weather)],
	]
	text = "\n".join(lines)

## `sceneFrame`'s clock: `HH:MM`, zero-padded, from the hour of the day.
static func clock_text(hours: float) -> String:
	var hh: int = int(floor(hours))
	var mm: int = int(floor((hours - float(hh)) * 60.0))
	return "%02d:%02d" % [hh, mm]

## `weather.js` `updateWeatherEffects`'s `weatherText`: the state, the wind, and the
## rain and the slowdown only when there is any to report -- so a clear frame reads
## exactly as it always has.
##
## The state travels *with* the dictionary: a session's wire snapshot, or the local
## machine's own values offline (`main.gd` `_weather_now`). So this reads the real state
## in both cases rather than being pinned to `clear`.
static func weather_text(weather: Dictionary) -> String:
	var text: String = String(weather.get("kind", "clear"))
	var wx: float = float(weather.get("wind_x", 0.0))
	var wz: float = float(weather.get("wind_z", 0.0))
	text += "   wind %.1f m/s" % sqrt(wx * wx + wz * wz)
	var rain: float = float(weather.get("rain_amount", 0.0))
	if rain > 0.02:
		text += "   rain %d%%" % int(round(rain * 100.0))
	return text

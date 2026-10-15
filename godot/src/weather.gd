# The weather: `weather.js`'s state machine, the values a client mirrors and the
# rain's own integration.
#
# It is a *stochastic* process driven by one seeded PRNG (`rngState`), which is what
# makes it gateable the same way the goat's frame is: two processes that start from
# the same seed and step the same number of frames must agree on every value. Offline
# and on the host it runs; a client takes the host's `cloudiness`, `rain_amount` and
# `kind` off the wire instead (`weather.js` `netWeatherLocal`) and only recomputes
# what is its own -- how much the rain slows *this* goat and how much it drains it,
# which `PlayerGoat` already does from the values.
#
# What the machine decides is wired everywhere it goes: `cloudiness` drives the sky
# shader's cumulus and the overcast grey wash, `wind_sway` scales the grass's sway, and
# `rain_amount` and the wind are what slow the goat and make its energy run out faster.
# This file is the middle of that -- it is what moves `rain_amount` off zero, and until
# it landed the scene was permanently `clear`.
#
# Not ported, and it is a *visible* simplification: the cloud *billboards*
# (`drawClouds`). They are the fallback for a build without the sky shader
# (`goat.js`: `if (!skyShaderOn) drawClouds()`), and the port always has one, so its
# clouds are the raymarched ones in `sky.gdshader` and this file only has to move the
# number they are drawn from.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
class_name Weather
extends RefCounted

## `weather.js` `WEATHER_STATES`: the cloudiness and rain each state eases toward.
const STATES := {
	"clear": {"cloud": 0.05, "rain": 0.0},
	"cloudy": {"cloud": 0.70, "rain": 0.0},
	"rain": {"cloud": 1.00, "rain": 1.0},
	"clearing": {"cloud": 0.40, "rain": 0.12},
}
## `weather.js` `WEATHER_NEXT`: where a state can go next. A list, drawn from.
const NEXT := {
	"clear": ["cloudy"],
	"cloudy": ["rain", "clear"],
	"rain": ["clearing"],
	"clearing": ["clear", "cloudy"],
}
## `TUNING.weather.hold`: seconds a state is held, `[least, most]`.
const HOLD := {
	"clear": [22.0, 45.0],
	"cloudy": [16.0, 34.0],
	"rain": [20.0, 40.0],
	"clearing": [8.0, 16.0],
}
## The ease rate, and `TUNING.weather.rainMax`: how many streaks a downpour is.
const EASE := 0.6
const RAIN_MAX := 160
## `weather.js`'s initial `rngState` -- the weather stream the session seed replaces.
const SEED := 0x9e3779b9
## The rain's own stream, `weather.js` `rainSeed`, kept separate so the weather's and
## the rain's draws cannot move each other.
const RAIN_SEED := 0x13579bdf
## `weather.js` `RAIN_CAPACITY`: the pool is built with headroom so a mod can raise
## `rainMax` without rebuilding it.
const RAIN_CAPACITY := 1024

var kind := "clear"
var timer := 24.0
var cloudiness := 0.05
var rain_amount := 0.0
var rng := SEED
var rain_seed := RAIN_SEED
## The rain's drops, in screen space: `x` and `y` in `0..1` of the viewport, and how
## fast this one falls.
var drops: Array = []

func _init() -> void:
	# `weather.js` `buildRain`: the pool is *derived*, not random, so two processes
	# with the same build have their rain in the same places.
	for i in RAIN_CAPACITY:
		drops.append({
			"x": Terrain.value_hash(float(i) * 1.7),
			"y": Terrain.value_hash(float(i) * 2.9),
			"speed": 0.6 + Terrain.value_hash(float(i) * 4.3),
		})

## Take the weather stream from the session seed. `weather.js` `sceneUseSeed` draws
## this first of the four streams.
func use_seed(seed: int) -> void:
	var s: int = _i32(seed)
	if s == 0:
		s = 1
	rng = _step(s)
	if rng == 0:
		rng = 1

## One frame of the state machine: run the hold down, draw the next state when it
## expires, and ease this frame's cloudiness and rain toward that state's own.
func update(delta: float) -> void:
	timer -= delta
	if timer <= 0.0:
		var options: Array = NEXT[kind]
		kind = String(options[int(floor(rnd() * float(options.size()))) % options.size()])
		var hold: Array = HOLD[kind]
		timer = float(hold[0]) + rnd() * (float(hold[1]) - float(hold[0]))
	var target: Dictionary = STATES[kind]
	var k: float = minf(1.0, delta * EASE)
	cloudiness += (float(target["cloud"]) - cloudiness) * k
	rain_amount += (float(target["rain"]) - rain_amount) * k

## `weather.js` `forceWeather`, the `C` key: jump to the next state now, for
## previewing the cycle.
func force() -> void:
	kind = String((NEXT[kind] as Array)[0])
	timer = float((HOLD[kind] as Array)[0])

## Pin a named state and its own values, and hold them there. It is the one method here
## a player never reaches: `GOATS_WEATHER` calls it at boot so a downpour or an overcast
## can be *looked* at (`tools/screenshot.gd`), which is the same reason `GOATS_CLOUD`
## exists. It snaps the two eased amounts rather than letting the machine ease in,
## because the point of the knob is a steady picture -- the *easing* is what the gate
## measures instead.
func hold(state: String) -> void:
	if not STATES.has(state):
		return
	kind = state
	timer = 1.0e9
	cloudiness = float((STATES[state] as Dictionary)["cloud"])
	rain_amount = float((STATES[state] as Dictionary)["rain"])

## Adopt the host's weather. A client mirrors the *values* and keeps its own kind
## only for the HUD's line, because what a state is *doing* is the values.
func apply_wire(weather: Dictionary) -> void:
	if weather.is_empty():
		return
	kind = String(weather.get("kind", kind))
	cloudiness = float(weather.get("cloudiness", cloudiness))
	rain_amount = float(weather.get("rain_amount", rain_amount))

## The weather as the wire and the HUD carry it. The wind and the clock are the
## caller's -- they are not the machine's -- so they are handed in.
func values(wind_x: float, wind_z: float, wind_sway: float, hours: float) -> Dictionary:
	return {
		"kind": kind,
		"cloudiness": cloudiness,
		"rain_amount": rain_amount,
		"wind_x": wind_x,
		"wind_z": wind_z,
		"wind_sway": wind_sway,
		"world_time": hours,
	}

## How many drops are falling: `TUNING.weather.rainMax` of the pool at full rain.
func rain_active() -> int:
	return mini(drops.size(), int(round(float(RAIN_MAX) * rain_amount)))

## Step the rain and answer how many drops are live. `weather.js` `updateRain` and
## `rainFall`, transcribed: a drop falls, drifts with the wind, and wraps from the
## bottom back to the top at a freshly drawn column -- so a downpour does not read as
## the same streak falling twice.
func update_rain(delta: float, wind_x: float) -> int:
	var active: int = rain_active()
	var wx: float = wind_x * 0.02 * delta
	for i in active:
		var drop: Dictionary = drops[i]
		drop["y"] = float(drop["y"]) + (0.7 + float(drop["speed"])) * delta
		drop["x"] = float(drop["x"]) + wx
		if float(drop["y"]) > 1.05:
			drop["y"] = float(drop["y"]) - 1.1
			rain_seed = _step(rain_seed)
			drop["x"] = Terrain.value_hash(float(i) * 13.1 + float(rain_seed) * 0.0001)
		if float(drop["x"]) > 1.1:
			drop["x"] = float(drop["x"]) - 1.2
		elif float(drop["x"]) < -0.1:
			drop["x"] = float(drop["x"]) + 1.2
	return active

## `weather.js` `rnd`: one xorshift draw from the weather stream.
func rnd() -> float:
	rng = _step(rng)
	return float(rng) / 4294967296.0

## One xorshift32 step, the same three lines `weather.js`'s `next`/`rnd` use.
static func _step(state: int) -> int:
	var s: int = _i32(state)
	s = _ushr(s ^ _i32(s << 13), 0)
	s = _ushr(s ^ _ushr(s, 17), 0)
	s = _ushr(s ^ _i32(s << 5), 0)
	return s

## `| 0`: wrap to int32.
static func _i32(value: int) -> int:
	var low: int = value & 0xFFFFFFFF
	if low >= 0x80000000:
		return low - 0x100000000
	return low

## `>>>`: a right shift of the value read as unsigned.
static func _ushr(value: int, bits: int) -> int:
	return (value & 0xFFFFFFFF) >> bits

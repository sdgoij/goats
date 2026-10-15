# The sky: `world.js`'s day/night curve and `lighting.js`'s light, drawn by
# `sky.gdshader` (`sky.js`'s `SKY_FS`).
#
# Named `SkyDome` and not `Sky` because `Sky` is already a Godot resource, and a
# script class that hides a native one is a trap: `Environment.sky` and the scene's
# `[sub_resource type="Sky"]` both mean the engine's, and a global class of the same
# name makes which one is meant a matter of where you are standing.
#
# Godot draws the sky here rather than the scene's own full-screen pass. A
# `shader_type sky` material gets the same maths for free -- `EYEDIR` stands in for
# the view ray `SKY_FS` rebuilds from the camera basis, and Godot's sky stage
# re-renders every frame -- but what decides the *colour of everything* is not the
# shader, it is this file: the keyframed curve, the sun's arc and the ambient the
# light and the environment are set from.
#
# Those are transcriptions, and `tools/verify_sky.gd` checks them against the
# JavaScript itself -- the scene's own engine -- the way `tools/verify_terrain.gd`
# checks the heightfield. The numbers are the scene's numbers because a sky that is
# a little wrong is a whole scene that is a little wrong.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd` for why a `var x := <call to a static function of this class>` is
# not survivable.
class_name SkyDome
extends RefCounted

const SHADER: Shader = preload("res://src/sky.gdshader")

## Sky keyframes by hour: sky-top and horizon colours plus a 0..1 light factor used
## to tint the whole scene. Hour 24 repeats hour 0. `world.js` `SKY_KEYS`, verbatim.
const SKY_KEYS := [
	{"h": 0.0, "top": [8, 10, 28], "bot": [16, 20, 44], "light": 0.0},
	{"h": 4.5, "top": [12, 14, 34], "bot": [26, 28, 54], "light": 0.0},
	{"h": 6.0, "top": [70, 70, 120], "bot": [190, 120, 90], "light": 0.25},
	{"h": 7.5, "top": [120, 165, 220], "bot": [235, 190, 150], "light": 0.8},
	{"h": 12.0, "top": [110, 170, 240], "bot": [175, 210, 245], "light": 1.0},
	{"h": 17.0, "top": [120, 165, 220], "bot": [235, 200, 160], "light": 0.85},
	{"h": 19.0, "top": [90, 80, 130], "bot": [225, 130, 90], "light": 0.35},
	{"h": 20.5, "top": [26, 28, 58], "bot": [70, 60, 90], "light": 0.08},
	{"h": 22.0, "top": [10, 12, 30], "bot": [18, 22, 46], "light": 0.0},
	{"h": 24.0, "top": [8, 10, 28], "bot": [16, 20, 44], "light": 0.0},
]

## Overcast skies wash the gradient toward grey (`goat.js` sceneFrame).
const OVERCAST_TOP := [96, 102, 116]
const OVERCAST_BOT := [150, 154, 162]

## `TUNING.world.dayLength`: real seconds for one 24 h day.
const DAY_LENGTH := 240.0
## `TUNING.sky`, the slab geometry the shader marches.
const CLOUD_BASE := 5.0
const CLOUD_TOP := 9.5
const CLOUD_SCALE := 0.055
const CLOUD_DETAIL := 0.35
const CLOUD_ABSORB := 1.35
const CIRRUS_LEVEL := 15.0
const CLOUD_SPEED := 0.55
## `TUNING.sky.steps`, indexed by `SETTINGS.cloud` (default 1, "medium").
const CLOUD_STEPS := [6, 12, 22]
const CLOUD_LEVEL := 1

## `weather.js`'s `WEATHER_STATES`, the cloudiness a state eases toward. The state
## machine itself is not ported yet (see `PORT.md`), so offline the scene stays in
## the state it boots in: `clear`.
const CLOUDINESS_CLEAR := 0.05
## `TUNING.weather.windBase` and `windNorm`, which `updateWind` reads.
const WIND_BASE := 1.6
const WIND_NORM := 1.4

## The default the scene boots with (`world.js` `worldTime`).
const DEFAULT_HOUR := 8.0

## `world.js` `mix`: `a + (b - a) * t`, not `lerp`. Godot's `lerpf` is the other
## association (`a * (1 - t) + b * t`), which rounds differently -- invisible in a
## float, but `sample` rounds to whole bytes and a .5 boundary would land on the
## other side of it.
static func mix_of(a: float, b: float, t: float) -> float:
	return a + (b - a) * t

## `world.js` `mod24`: the hour wrapped into `[0, 24)`.
static func mod24(hours: float) -> float:
	return fposmod(hours, 24.0)

## Sample the sky curve at `hours`: the rounded top and horizon colours as `Color`
## (so `Color8` bytes, exactly as the scene's `rl.color` packs them -- display
## space: `apply` converts them for Godot's pipeline) and the 0..1 light factor,
## interpolated between the two surrounding keyframes.
static func sample(hours: float) -> Dictionary:
	var i: int = 0
	while i < SKY_KEYS.size() - 2 and hours > float(SKY_KEYS[i + 1]["h"]):
		i += 1
	var a: Dictionary = SKY_KEYS[i]
	var b: Dictionary = SKY_KEYS[i + 1]
	var span: float = float(b["h"]) - float(a["h"])
	var t: float = 0.0
	if span > 0.0:
		t = (hours - float(a["h"])) / span
	var at: Array = a["top"]
	var bt: Array = b["top"]
	var ab: Array = a["bot"]
	var bb: Array = b["bot"]
	return {
		"top": Color8(
			int(round(mix_of(at[0], bt[0], t))),
			int(round(mix_of(at[1], bt[1], t))),
			int(round(mix_of(at[2], bt[2], t)))),
		"bot": Color8(
			int(round(mix_of(ab[0], bb[0], t))),
			int(round(mix_of(ab[1], bb[1], t))),
			int(round(mix_of(ab[2], bb[2], t)))),
		"light": mix_of(float(a["light"]), float(b["light"]), t),
	}

## Overcast greys the gradient: `lerpColor(sky.top, OVERCAST_TOP, min(0.75,
## cloudiness * 0.75))`, as `goat.js` does before the sky shader sees it. Channel
## interpolation here *is* `rl.color`'s, which rounds the same way as the mix above.
static func overcast(colour: Color, over: Array, cloudiness: float) -> Color:
	var grey: float = minf(0.75, cloudiness * 0.75)
	var r: float = colour.r * 255.0
	var g: float = colour.g * 255.0
	var b: float = colour.b * 255.0
	return Color8(
		int(round(mix_of(r, over[0], grey))),
		int(round(mix_of(g, over[1], grey))),
		int(round(mix_of(b, over[2], grey))))

## `lighting.js` `updateLight`'s `SUN_DIR`: the sun's own direction, a unit vector
## from the scene toward the body. `0` at 06:00, `PI` at 18:00, tilted off the XZ
## plane so the arc is not flat.
static func sun_dir(hours: float) -> Vector3:
	var a: float = ((hours - 6.0) / 12.0) * PI
	var sun_x: float = cos(a)
	var sun_y: float = sin(a)
	var tilt: float = 0.18
	var length: float = sqrt(sun_x * sun_x + sun_y * sun_y + tilt * tilt)
	if length == 0.0:
		length = 1.0
	return Vector3(sun_x / length, sun_y / length, tilt / length)

## `lighting.js` `updateLight`'s `LIGHT_DIR`: whichever body is up -- the sun by
## day, the moon by night, which is the same line negated. The flip is exactly at
## the horizon, so a visible disc and the light never disagree.
static func light_dir(hours: float) -> Vector3:
	var sun: Vector3 = sun_dir(hours)
	if sun.y > 0.0:
		return sun
	return -sun

## `lighting.js` `updateLight`'s `LIGHT_COLOR`: rgb already scaled by intensity, so
## a Godot light takes it as its colour with an energy of one.
##
## The warmth here reads the **raw** `sin(a)`, not the normalised `SUN_DIR[1]` --
## `updateLight` computes `warm` from the local `sunY` before it is divided by the
## arc's length, and that is a different number (the tilt lengthens the vector by
## about 1.6%, which moves the horizon's warm band by about a hundredth). The gate
## caught exactly this; a tidier port that reused `sun_dir` would have been subtly
## and permanently wrong about dawn.
static func light_color(hours: float, sky_light: float) -> Color:
	var a: float = ((hours - 6.0) / 12.0) * PI
	var raw_y: float = sin(a)
	var warm: float = clampf(1.0 - absf(raw_y) / 0.45, 0.0, 1.0)
	if raw_y > 0.0:
		var intense: float = 0.30 + 0.70 * sky_light
		return Color(intense, intense * (1.0 - 0.22 * warm), intense * (1.0 - 0.55 * warm))
	# The moon's light is dim and cold, and does not warm at the horizon.
	var moon: float = 0.16
	return Color(moon * 0.72, moon * 0.80, moon)

## `lighting.js` `updateLight`'s `LIGHT_AMBIENT`: the ambient the lit program adds
## under the sun. This is the environment's `ambient_light_color` here.
static func ambient(sky_light: float) -> Color:
	return Color(0.10 + 0.12 * sky_light, 0.12 + 0.13 * sky_light, 0.18 + 0.16 * sky_light)

## `world.js` `updateAmbient`'s `warm`: how much the light is warmed toward dawn and
## dusk, which the clouds take and so does the canvas tint.
static func warmth(sky_light: float) -> float:
	return clampf(1.0 - absf(sky_light - 0.3) / 0.34, 0.0, 1.0)

## `world.js` `updateAmbient`'s `ambR/ambG/ambB`: a dim, blue-shifted daylight, and
## the palette the scene's *unlit* path (the cube goat, the tuft fallback) is drawn
## with. The port routes the world through Godot's lit materials and takes the
## ambient from `ambient` above, so this is not applied to the scene -- it is kept
## because a mod surface and the cube fallback will want it, and because
## `verify_sky.gd` checks it.
static func ambient_tint(sky_light: float) -> Vector3:
	var warm: float = warmth(sky_light)
	return Vector3(
		minf(1.0, 0.40 + 0.60 * sky_light + 0.14 * warm),
		minf(1.0, 0.44 + 0.56 * sky_light + 0.02 * warm),
		minf(1.0, 0.62 + 0.38 * sky_light - 0.14 * warm))

## `sky.js` `setSkyUniforms`'s `cloudLit`: overcast greys the clouds, night darkens
## them, and dawn/dusk warms them.
static func cloud_lit(sky_light: float, warm: float) -> Color:
	var lit: float = 0.12 + 0.88 * sky_light
	return Color(
		minf(1.0, lit + 0.10 * warm),
		minf(1.0, lit + 0.02 * warm),
		minf(1.0, lit - 0.06 * warm))

## `sky.js` `setSkyUniforms`'s `cloudShadow`, which is the lit value scaled down and
## very slightly blue.
static func cloud_shadow(sky_light: float) -> Color:
	var shadow: float = 0.09 + 0.40 * sky_light
	return Color(shadow * 0.95, shadow * 0.97, shadow * 1.06)

## `sky.js` `setSkyUniforms`'s `cirrus`: the thin high layer only shows up once the
## sky is broken or overcast.
static func cirrus_of(cloudiness: float) -> float:
	return clampf((cloudiness - 0.25) * 1.2, 0.0, 0.85)

## The sky material, built once. `process_mode` is set to `REALTIME` by `main.gd` so
## the shader runs every frame: the sun moves and the wind drifts the clouds, and a
## static bake would freeze both.
static func make_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	return material

## `weather.js` `updateWind`, for a scene with no session: the local gust model the
## client runs when it is not a client. Returns `{ x, z, sway }`.
##
## `sway_time` is the wind's own clock, and `cloudiness` is the state the weather
## machine would be in -- `clear` today, because the machine is not ported yet.
static func wind(sway_time: float, cloudiness: float) -> Dictionary:
	var gust: float = 0.55 + 0.35 * sin(sway_time * 0.7) + 0.2 * sin(sway_time * 1.9 + 1.3)
	var direction: float = 0.5 * sin(sway_time * 0.23)
	var speed: float = WIND_BASE * maxf(0.2, gust)
	return {
		"x": cos(direction) * speed,
		"z": sin(direction) * speed,
		"sway": minf(1.4, speed / WIND_BASE) * (0.55 + 0.45 * cloudiness),
	}

## The one place the port's *pipeline* differs from the scene's beyond the ray
## basis: `sky.js` writes a plain framebuffer, and Godot renders in linear with an
## sRGB encode at the end. So every colour the scene authored in display space -- the
## curve, the overcast greys, the cloud tints -- is converted here once, on the CPU,
## rather than per pixel. `LIGHT_COLOR` and `LIGHT_AMBIENT` are *not* converted: they
## are multipliers in both pipelines, and `light_color`'s output is also what the
## Godot light takes as its own colour.
static func _linear(colour: Color) -> Vector3:
	var linear: Color = colour.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)

## Aim the light and set the environment they read, for one frame.
##
## `cam` is the sky shader's `cam_pos`: Godot's sky stage is at infinity, but the
## cloud slab is at a world height, so where the eye is inside it decides what a ray
## crosses.
##
## `sun`'s transform is the light's *direction*, not a position: Godot's directional
## light propagates along its local `-Z`, so pointing `-Z` away from
## `light_dir` (which points at the body) puts the light where the sky says it is.
##
## `sky_time` drives the cloud drift, and is the scene's own accumulator rather than
## Godot's `TIME` built-in so it holds the same number `sky.js`'s `skyTime` does.
static func apply(material: ShaderMaterial, env: Environment, sun: DirectionalLight3D,
		cam: Vector3, hours: float, sky_light: float, cloudiness: float,
		wind_x: float, wind_z: float, sky_time: float) -> void:
	var curve: Dictionary = sample(hours)
	var top: Color = overcast(curve["top"], OVERCAST_TOP, cloudiness)
	var bot: Color = overcast(curve["bot"], OVERCAST_BOT, cloudiness)
	var warm: float = warmth(sky_light)

	material.set_shader_parameter("cam_pos", cam)
	material.set_shader_parameter("zenith_color", _linear(top))
	material.set_shader_parameter("horizon_color", _linear(bot))
	var light: Vector3 = light_dir(hours)
	material.set_shader_parameter("sun_dir", light)
	var sun_colour: Color = light_color(hours, sky_light)
	material.set_shader_parameter("sun_color", Vector3(sun_colour.r, sun_colour.g, sun_colour.b))
	material.set_shader_parameter("cloudiness", cloudiness)
	material.set_shader_parameter("wind", Vector2(wind_x * CLOUD_SPEED, wind_z * CLOUD_SPEED))
	material.set_shader_parameter("sky_time", sky_time)
	material.set_shader_parameter("cloud_lit", _linear(cloud_lit(sky_light, warm)))
	material.set_shader_parameter("cloud_shadow", _linear(cloud_shadow(sky_light)))
	material.set_shader_parameter("cloud_base", CLOUD_BASE)
	material.set_shader_parameter("cloud_top", CLOUD_TOP)
	material.set_shader_parameter("cloud_scale", CLOUD_SCALE)
	material.set_shader_parameter("cloud_detail", CLOUD_DETAIL)
	material.set_shader_parameter("cloud_absorb", CLOUD_ABSORB)
	material.set_shader_parameter("cirrus", cirrus_of(cloudiness))
	material.set_shader_parameter("cirrus_height", CIRRUS_LEVEL)
	material.set_shader_parameter("night_dim", 1.0 - sky_light)
	material.set_shader_parameter("cloud_steps", int(CLOUD_STEPS[CLOUD_LEVEL]))

	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient(sky_light)
	env.ambient_light_energy = 1.0

	if sun == null:
		return
	sun.light_color = sun_colour
	sun.light_energy = 1.0
	# `look_at` points `-Z` at its target, so the target is the light's *far* side.
	sun.global_position = Vector3.ZERO
	sun.look_at(-light)

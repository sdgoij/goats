# The ground: a port of `world.js`'s heightfield.
#
# `terrainHeight` is the single source of truth for the ground in the client --
# the goat, the herd, the grass and both shadows all read it, so nothing floats
# or sinks as the field rises -- and it is **deterministic on purpose**: the mine
# field and the craters are *derived* from the session seed rather than sent
# (`README.md`, "Landmines and boobytraps"), so two peers that disagree about the
# ground by a bit disagree about where a device is. That is why this file is a
# transcription down to the constants and the order of the arithmetic, and not a
# tidier equivalent.
#
# The oracle is the JavaScript itself: `tools/verify_terrain.gd` runs this file's
# functions against the same functions evaluated by the embedded engine -- the
# engine the client runs them on -- and reports the largest disagreement. See
# `PORT.md` section 9 on why determinism is the port's sharpest risk.
#
# ## The `:=` trap (Godot 4.7)
#
# Every local here is annotated (`var u: float = ...`) instead of inferred
# (`var u := ...`), and that is not a style choice. `var x := <call to a static
# function of this same class>` makes GDScript's analyser spin forever: the class
# never finishes compiling and *any* call into it hangs the process, with no
# error, no stack, and nothing on stderr. It is not a wrong answer, it is no
# answer, which is far worse to diagnose -- `verify_terrain.gd` has to be run
# under a timeout for exactly this reason.
#
# Two other naming traps are worth knowing beside it: `hash` shadows
# `Object.hash()`, and a GDExtension method named `connect` shadows
# `Node.connect()` -- both resolve by static type at the call site rather than by
# name. A language with neither a compiler nor a name resolver to tell you is one
# where a naming mistake is a silent behaviour change.
#
# The craters are a *term* in `height_at` rather than geometry of their own, so they
# live in `craters.gd` and this file only adds them (see `height_at` for why that
# shape is the point).
class_name Terrain
extends RefCounted

## World units per grid cell (matches the grass).
const CELL := 2.0
## Quads per side: a field of +/- 48 units.
const QUADS := 48
## Peak displacement of the rolling hills, in metres -- `TUNING.terrain.relief`.
static var RELIEF: float = 2.1
## The spawn bowl's radius, in units, that stays level.
static var FLAT: float = 6.0
## The units over which the bowl reaches full relief.
static var RAMP: float = 16.0
## A full ridge's height above the hills -- `TUNING.terrain.mountain`.
static var MOUNTAIN: float = 38.0
## The radius that stays foothills, and the units over which the range reaches
## full height (`TUNING.terrain.mountainFlat` / `mountainRamp`).
static var MOUNTAIN_FLAT: float = 40.0
static var MOUNTAIN_RAMP: float = 120.0
## Rebuild the mesh when the goat has moved this far -- `TUNING.terrain.snap`.
static var SNAP: float = 32.0

## The hash the whole field is built from: `core.js`'s, verbatim.
static func value_hash(n: float) -> float:
	var s: float = sin(n * 127.1) * 43758.5453
	return s - floor(s)

## Value noise: `weather.js`'s `vnoise2`, verbatim. Three octaves of it are
## layered in `shape` below.
static func vnoise2(x: float, y: float) -> float:
	var xi: float = floor(x)
	var yi: float = floor(y)
	var xf: float = x - xi
	var yf: float = y - yi
	var u: float = xf * xf * (3.0 - 2.0 * xf)
	var v: float = yf * yf * (3.0 - 2.0 * yf)
	var a: float = value_hash(xi * 57.0 + yi * 131.0)
	var b: float = value_hash((xi + 1.0) * 57.0 + yi * 131.0)
	var c: float = value_hash(xi * 57.0 + (yi + 1.0) * 131.0)
	var d: float = value_hash((xi + 1.0) * 57.0 + (yi + 1.0) * 131.0)
	return (a * (1.0 - u) + b * u) * (1.0 - v) + (c * (1.0 - u) + d * u) * v

## GLSL's `smoothstep`, for the scene's own eased terms (the bowl and the mountain
## ramp). `t` is clamped before the cubic so an out-of-range value lands on an edge.
static func smoothstep(lo: float, hi: float, v: float) -> float:
	var t: float = (v - lo) / (hi - lo)
	t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
	return t * t * (3.0 - 2.0 * t)

## Four octaves: broad hills with smaller bumps on top. The last one is the detail
## the near grid's 2 m cells can resolve. `world.js` `terrainShape`, verbatim.
static func shape(x: float, z: float) -> float:
	var broad: float = 0.58 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1)
	var middle: float = 0.25 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9)
	var fine: float = 0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3)
	var grain: float = 0.05 * vnoise2(x * 0.29 + 5.3, z * 0.29 + 33.7)
	return broad + middle + fine + grain

## The mountains: two folded noise octaves under a low-frequency mask. A ridge is
## `1 - |2n - 1|`, which is what turns blobs into crests; the square sharpens the
## crests and flattens the passes. `world.js` `terrainRidge`, verbatim.
static func ridge(x: float, z: float) -> float:
	var broad: float = 1.0 - absf(2.0 * vnoise2(x * 0.0105 + 91.3, z * 0.0105 + 17.9) - 1.0)
	var fine: float = 1.0 - absf(2.0 * vnoise2(x * 0.028 + 3.7, z * 0.028 + 55.1) - 1.0)
	var crest: float = 0.72 * broad + 0.28 * fine
	var mask: float = smoothstep(0.30, 0.70, vnoise2(x * 0.0062 + 7.3, z * 0.0062 + 41.7))
	return crest * crest * mask

## The ground before craters: a level bowl around the origin, easing into the
## hills over `RAMP`, plus the mountain range ramping in over its own, wider
## radius. `world.js` `terrainBaseHeight`, verbatim.
static func base_height(x: float, z: float) -> float:
	var d: float = sqrt(x * x + z * z)
	var t: float = (d - FLAT) / RAMP
	t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
	t = t * t * (3.0 - 2.0 * t)
	var tm: float = (d - MOUNTAIN_FLAT) / MOUNTAIN_RAMP
	tm = 0.0 if tm < 0.0 else (1.0 if tm > 1.0 else tm)
	tm = tm * tm * (3.0 - 2.0 * tm)
	var relief: float = (shape(x, z) - 0.5) * 2.0 * RELIEF * t
	return relief + ridge(x, z) * MOUNTAIN * tm

## The ground at a point, which is what every reader wants: the field, plus whatever
## has been blown out of it. This is the function the client calls `terrainHeight`.
##
## The craters are a **term in here** rather than geometry of their own, which is what
## makes a bang's hole free for everything that reads the ground: the goat, the herd,
## the grass and the drawn mesh all ask this one function.
static func height_at(x: float, z: float) -> float:
	var y: float = base_height(x, z) + Craters.dip_at(x, z)
	return y

## Ground material from the height, the slope (0 flat .. 1 steep) and the
## low-frequency patchiness noise. `world.js` `terrainMaterial`, and the structure
## matters: every line is a *band*, not a threshold, mixed in the order the old
## thresholds implied (snow over rock over mud over sand over hill over grass). A
## hard palette flip is what turns the 14 m patchiness into 14 m tiles, and what two
## sample rates put in different places.
##
## The blend is in the scene's sRGB bytes and only the *result* is converted to
## linear (`_rgb`): converting first would mix in a different space than the
## reference does (`PORT.md` section 9).
static func material(y: float, slope: float, m: float) -> Color:
	# Grass to dark grass over the patchiness: the same hue at two lightnesses.
	var g: float = smoothstep(0.35, 0.65, m)
	var r: float = lerpf(98.0, 78.0, g)
	var gr: float = lerpf(150.0, 126.0, g)
	var b: float = lerpf(84.0, 66.0, g)

	var hill_y: float = 0.35 + (m - 0.5) * 0.3
	var w: float = smoothstep(hill_y - 0.3, hill_y + 0.3, y)
	r = lerpf(r, 126.0, w)
	gr = lerpf(gr, 146.0, w)
	b = lerpf(b, 74.0, w)

	# Sand on the flat, dry patches.
	w = (1.0 - smoothstep(0.05, 0.14, slope)) * smoothstep(0.52, 0.68, m)
	r = lerpf(r, 198.0, w)
	gr = lerpf(gr, 178.0, w)
	b = lerpf(b, 130.0, w)

	# Mud in the hollows.
	w = (1.0 - smoothstep(-0.9, -0.35, y)) * (1.0 - smoothstep(0.5, 0.7, m))
	r = lerpf(r, 104.0, w)
	gr = lerpf(gr, 84.0, w)
	b = lerpf(b, 62.0, w)

	# Rock on the scarps and above the hill line: one band, two routes in.
	var rock_y: float = 1.15 + (m - 0.5) * 0.6
	w = maxf(smoothstep(0.40, 0.62, slope), smoothstep(rock_y - 0.45, rock_y + 0.45, y))
	r = lerpf(r, 128.0, w)
	gr = lerpf(gr, 122.0, w)
	b = lerpf(b, 112.0, w)

	# Snow above the snow line, which the patchiness also moves.
	var snow_y: float = 26.0 + (m - 0.5) * 3.0
	w = smoothstep(snow_y - 1.2, snow_y + 1.2, y)
	r = lerpf(r, 232.0, w)
	gr = lerpf(gr, 238.0, w)
	b = lerpf(b, 245.0, w)

	return _rgb(r, gr, b)

## The scene's palette is sRGB bytes and Godot's pipeline is linear. `Color8` does
## not convert, so the conversion is explicit here -- this is the ground's half of
## the display-space/linear split (`PORT.md` section 9). The blend happens in sRGB
## bytes, so this takes the blended floats rather than integers.
static func _rgb(r: float, g: float, b: float) -> Color:
	return Color(r / 255.0, g / 255.0, b / 255.0).srgb_to_linear()

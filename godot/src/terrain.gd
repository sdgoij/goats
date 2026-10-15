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
## Peak displacement, in metres -- `TUNING.terrain.relief`.
const RELIEF := 2.1
## The spawn bowl's radius, in units, that stays level.
const FLAT := 6.0
## The units over which the bowl reaches full relief.
const RAMP := 16.0
## Rebuild the mesh when the goat has moved this far -- `TUNING.terrain.snap`.
const SNAP := 24.0

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

## Three octaves: broad hills with smaller bumps on top. `world.js`
## `terrainShape`, verbatim.
static func shape(x: float, z: float) -> float:
	var broad: float = 0.62 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1)
	var middle: float = 0.26 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9)
	var fine: float = 0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3)
	return broad + middle + fine

## The ground before craters: a level bowl around the origin, easing into the
## noise over `RAMP` so there is no cliff at the bowl's edge. `world.js`
## `terrainBaseHeight`, verbatim.
static func base_height(x: float, z: float) -> float:
	var d: float = sqrt(x * x + z * z)
	var t: float = (d - FLAT) / RAMP
	t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
	t = t * t * (3.0 - 2.0 * t)
	var relief: float = (shape(x, z) - 0.5) * 2.0 * RELIEF * t
	return relief

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
## low-frequency patchiness noise. `world.js` `terrainMaterial`, verbatim; the
## colours are sRGB bytes, as the mesh carries them.
static func material(y: float, slope: float, m: float) -> Color:
	if slope > 0.5 or y > 1.15:
		return _rgb(128, 122, 112)   # rock: peaks and scarps
	if y < -0.55 and m < 0.6:
		return _rgb(104, 84, 62)     # mud: the hollows
	if slope < 0.09 and m > 0.6:
		return _rgb(198, 178, 130)   # sand: dry flat patches
	if y > 0.35:
		return _rgb(126, 146, 74)    # hill
	return _rgb(98, 150, 84) if m < 0.5 else _rgb(78, 126, 66)

static func _rgb(r: int, g: int, b: int) -> Color:
	return Color8(r, g, b)

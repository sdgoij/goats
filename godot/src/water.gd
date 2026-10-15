# The water: `water.js`'s hydrostatic table (M20a) and the wading it does to a goat
# (M20d's share of it).
#
# Rain does not run downhill here. A pool's surface is *level*, so the whole of the
# model is
#
#     depth(x, z)   = max(0, W - ground(x, z))
#     surface(x, z) = ground(x, z) + depth(x, z)
#
# and that one expression is the whole of "water pools in the lowest parts": a cell is
# under water exactly when the table stands over its ground, so pools merge wherever
# they meet and a crater is simply ground that is lower. `W` is the *only* state -- the
# wetting, driven by the rain and draining slowly -- and the two ends of its band are
# declared world constants rather than read off the loaded grid. That is a fix rather
# than a preference (see `TUNING.water`): a level taken from the window the goat is
# standing in is a different level in the next window, over ground that has not moved,
# so a pool 0.11 m deep one step away was dry at the next.
#
# Two things follow from that, and they are why this is gateable at all. The *rise* is
# immediate -- `update` snaps the wetting up to whatever the rain can reach -- so a
# client that joins mid-shower is right on its first frame rather than integrating from
# nothing, and the only thing that ages is the drain, which is a single decaying number.
# And nothing about the water travels on the wire: the rain is already shared (the
# weather machine's, or the host's on the wire), the ground is derived, and the band's
# ends are declared, so two peers handed the same rain agree to the last bit.
#
# The ground it reads is the *terrain grid's own vertex heights* (`T_H` in the scene),
# not the continuous heightfield: the drawn surface is that grid, so the depth a goat
# wades in has to be the depth of the thing it is standing in. `TerrainMesh` hands its
# grid over in double precision for exactly that reason.
#
# Not ported, and each is a slice of its own rather than an omission: the surface
# (M20b -- the mesh, and the `WATER_VS`/`WATER_FS` shader that lifts it to the table),
# the chop (M20c), the wake, the splashes and the grass cull under water (M20d), and
# the reflection tiers (M20e, which in Godot is a `ReflectionProbe` or the sky rather
# than the scene's own mirrored pass). What *is* here is the half a goat can feel: the
# level the rain makes, and the drag and the drain that come of standing in it.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Water
extends RefCounted

## `TUNING.water`, verbatim. `LOW`/`HIGH` are the table's own ends in metres (`low` is
## the terrain's floor at `-terrain.relief`, so a dry spell is exactly dry at every
## point of the field), `FILL` the share of that band the heaviest rain reaches, `SEEP`
## the rain below which the ground stays dry, `WET_DOWN` the seconds the table takes to
## drain, and `MAX_DEPTH` the *wading* cap (M20g lifts it for swimming).
const LOW := -2.1
const HIGH := 0.0
const FILL := 0.75
const SEEP := 0.05
const WET_DOWN := 600.0
const MAX_DEPTH := 0.6
## `TUNING.water.drag` / `dragEnergy`: the share of its speed a goat loses at the cap,
## and the extra energy wading burns.
const DRAG := 0.35
const DRAG_ENERGY := 0.25
## `water.js`'s three structural numbers beside the tuning: the wetting curve's own
## exponent, the point where a draining table is called dry, and the depth below which
## the HUD says nothing.
const WET_CURVE := 0.5
const DRY_EPS := 1e-4
const HUD_MIN := 0.01
## `WATER_N` / `WATER_CELL` / `WATER_HALF`: the field is the terrain grid's own, so
## these are that grid's numbers rather than second copies of them.
const N := TerrainMesh.N
const CELL := Terrain.CELL
const HALF := TerrainMesh.HALF

## `TUNING.water.enabled`: the system off is one leaf, which the console and the menu
## write (`J` in the scene) and the frame-cost bisect uses. Nothing in the port reaches
## it yet -- the console is stage 6 -- so it is here for the gate and for that stage.
var enabled := true

## The wetting, `W`'s own memory: 0 dry, 1 at the heaviest rain.
var _wet := 0.0
## The level this frame, and whether it clears the window's ground.
var _level := LOW
var _on := false
## The window's lowest ground -- a *test*, never a level (see the header).
var _ground := INF
## `flood <h>`: a level set by hand. Not a number means "from the rain".
var _force := NAN
## The grid this field is built over, and its centre.
var _heights := PackedFloat64Array()
var _anchor := Vector2(0.0, 0.0)
var _ready := false
## The rain the last `step` handed in, which `update` reads -- the scene's `rainAmount`
## is a module global there and this keeps the same shape without the global.
var _rain := 0.0

## Rebuild the field from the ground, at a new anchor or after the ground moved.
##
## The one thing a rebuild still *measures* is the window's lowest ground: `update`'s
## "is anything wet" test, and nothing in the window is lower than it.
func rebuild(heights: PackedFloat64Array, anchor: Vector2) -> void:
	_heights = heights
	_anchor = anchor
	var lowest: float = INF
	for h in _heights:
		if h < lowest:
			lowest = h
	_ground = lowest
	_ready = true
	update()

## The rain, as the share of the table's own band it can reach. Nothing below `SEEP` --
## the ground drinks the first of it, and a dry spell stays exactly dry -- and above it
## a *concave* curve, so the first of a shower is most of what pools.
static func wetness_for(rain: float) -> float:
	var raw: float = (rain - SEEP) / (1.0 - SEEP)
	if raw <= 0.0:
		return 0.0
	return pow(minf(raw, 1.0), WET_CURVE)

## One frame of the water's *drain*: the one half of its clock that ages, so a pool
## stands for `WET_DOWN` seconds after the rain that filled it has gone. The rise is
## not here -- it is `update`'s, because there is no lag in it to age.
func step(delta: float, rain: float) -> void:
	_rain = rain
	var target: float = wetness_for(rain)
	if target < _wet:
		var k: float = minf(1.0, delta / WET_DOWN) if WET_DOWN > 1e-6 else 1.0
		_wet += (target - _wet) * k
		if _wet < DRY_EPS:
			_wet = 0.0
	update()

## The level for this frame, and whether there is water at all.
##
## The rise is immediate: `_wet` snaps up to whatever the rain reaches, with no
## memory to age and nothing to clamp it, so the ceiling is `HIGH` because the band
## ends there rather than because something holds it down.
func update() -> void:
	if not _ready:
		return
	var target: float = wetness_for(_rain)
	if target > _wet:
		_wet = target
	if not enabled:
		_level = LOW
	elif not is_nan(_force):
		_level = _force
	elif _wet <= 0.0:
		_level = LOW
	else:
		_level = LOW + _wet * FILL * (HIGH - LOW)
	# There is water to draw when the table clears the window's lowest ground, which is
	# the same statement as "the deepest pool in the window has a depth": nothing in it
	# is lower than that, so something is wet exactly when the table is above it.
	_on = _level > _ground + 1e-6

## The `flood <h>` override, for a demo or a bisect. A *level* is any finite number:
## this field's water lives below zero -- the ground is a metre or two of relief either
## side of it -- so a sign cannot double as the off switch.
func set_force(level: float) -> void:
	_force = level if is_finite(level) else NAN
	update()

func force_off() -> void:
	_force = NAN
	update()

## The water's own depth at a grid vertex. A basin whose rim the table has passed is
## simply submerged, and `MAX_DEPTH` is the *wading* cap, which lives where wading is
## decided and not wrapped around a depth here.
func vertex_depth(k: int) -> float:
	var d: float = _level - _heights[k]
	return d if d > 0.0 else 0.0

## The depth at a world point, bilinear over the grid so a wading goat reads a smooth
## number rather than whichever vertex it happens to stand nearest. Off the built grid
## there is no water: the field only spans `+/-HALF` and follows the goat, as the ground
## does.
func depth_at(x: float, z: float) -> float:
	if not _ready or not enabled:
		return 0.0
	var fx: float = (x - (_anchor.x - HALF)) / CELL
	var fz: float = (z - (_anchor.y - HALF)) / CELL
	var i: int = int(floor(fx))
	var j: int = int(floor(fz))
	if i < 0 or j < 0 or i >= N - 1 or j >= N - 1:
		return 0.0
	var u: float = fx - float(i)
	var v: float = fz - float(j)
	var k: int = j * N + i
	var d00: float = vertex_depth(k)
	var d10: float = vertex_depth(k + 1)
	var d01: float = vertex_depth(k + N)
	var d11: float = vertex_depth(k + N + 1)
	var top: float = d00 + (d10 - d00) * u
	var bot: float = d01 + (d11 - d01) * u
	return top + (bot - top) * v

## How much of the wading cap the goat is under: 0 out of water and 1 at `MAX_DEPTH`.
## It is a *wading* cap, so a deeper pool does not slow it further.
func drag_fraction(x: float, z: float) -> float:
	var depth: float = depth_at(x, z)
	if depth <= 0.0:
		return 0.0
	if MAX_DEPTH <= 0.0:
		return 1.0
	return minf(1.0, depth / MAX_DEPTH)

## The share of its speed the water leaves a goat -- `goat.js` `groundSpeed`'s third
## factor, beside the weather's. Exactly 1 out of water, so dry ground is untouched.
func speed_factor(x: float, z: float) -> float:
	return 1.0 - DRAG * drag_fraction(x, z)

## How much faster wading tires it (`goat.js` `updateStats`).
func drain_factor(x: float, z: float) -> float:
	return 1.0 + DRAG_ENERGY * drag_fraction(x, z)

## The HUD's water read-out, for the weather line it belongs beside: whether the goat
## is standing in water, how deep, and what it costs it. Empty when it is dry, and empty
## under a centimetre -- the drain leaves a film that thin for minutes after the rain
## has gone, and a pool nobody can see should not have a read-out.
func hud_text(x: float, z: float) -> String:
	var depth: float = depth_at(x, z)
	if depth < HUD_MIN:
		return ""
	var slowed: int = int(round(DRAG * drag_fraction(x, z) * 100.0))
	return "water %.2f m   slowed %d%%" % [depth, slowed]

## The seam a console and a mod read, and the gate's own view of the field: the level,
## how much of it the table covers, where the deepest point is and how deep it is under
## the goat. It reports the numbers the frame uses rather than a second derivation of
## them.
##
## What `sceneWater` also carries and this does not is M20b's mesh, M20c's chop, M20d's
## wake and M20e's reflection -- the slices not ported yet.
func state(px: float, pz: float) -> Dictionary:
	var count: int = N * N
	var area: float = CELL * CELL
	var wet: int = 0
	var volume: float = 0.0
	var deepest: float = 0.0
	var di: int = 0
	var dj: int = 0
	for k in count:
		var d: float = _level - _heights[k]
		if d <= 0.0:
			continue
		wet += 1
		volume += d * area
		if d > deepest:
			deepest = d
			di = k % N
			dj = (k - di) / N
	var x0: float = _anchor.x - HALF
	var z0: float = _anchor.y - HALF
	return {
		"level": _round3(_level if is_finite(_level) else 0.0),
		"enabled": enabled,
		"forced": not is_nan(_force),
		"on": _on,
		"wetting": _round3(_wet),
		"wet": wet,
		"cells": count,
		"volume": _round3(volume),
		"deepest": _round3(deepest),
		"deepX": _round3(x0 + float(di) * CELL),
		"deepZ": _round3(z0 + float(dj) * CELL),
		"goatDepth": _round3(depth_at(px, pz)),
		"ground": _round3(_ground),
		"floor": _round3(LOW),
		"high": _round3(HIGH),
		"rise": _round3(_level - LOW),
		"drag": speed_factor(px, pz),
		"drain": drain_factor(px, pz),
	}

## `core.js` `netRound3`, with *JavaScript's* rounding: `Math.round` is `floor(x + 0.5)`
## and GDScript's `round` breaks a tie away from zero instead, which differs at exactly
## -.5 -- and this field's level is negative by design, since its floor is `LOW`.
static func _round3(value: float) -> float:
	return floor(value * 1000.0 + 0.5) / 1000.0

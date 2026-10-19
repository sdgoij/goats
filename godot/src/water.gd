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
# What is here is the half a goat can feel and the half a camera sees: the level the rain
# makes, the drag and the drain that come of standing in it, the surface over the terrain
# grid (`water_mesh.gd` + `water.gdshader`, M20b), the chop (M20c), and the wake, the
# splashes and the grass a pool hides (M20d). The wake is the one part of it that is
# neither on the wire nor in the simulation: it is cosmetic and local, so it lives beside
# the draw and a client gets it for the herd it mirrors.
#
# Two water tests live here and they are *not* the same question, which is worth knowing
# before reading either. `in_water` is the HUD's own line -- the bilinear depth at a point
# against `HUD_MIN` -- and it is what "standing in the water" means to a rule: a goat does
# not doze in it. `submerged_at` is the *grid vertex* nearest a point, and it is what the
# grass cull asks: a tuft is skipped when the ground under it stands below the table.
#
# Not ported, and each is a slice of its own rather than an omission: the reflection tiers
# (M20e, which in Godot is the environment rather than the scene's own bake and mirrored
# pass) and swimming, buoyancy and drinking (M20g).
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Water
extends RefCounted

## `TUNING.water`, verbatim. `LOW`/`HIGH` are the table's own ends in metres (`low` is
## the terrain's floor at `-terrain.relief`, so a dry spell is exactly dry at every
## point of the field), `FILL` the share of that band the heaviest rain reaches, `SEEP`
## the rain below which the ground stays dry, `WET_DOWN` the seconds the table takes to
## drain, and `MAX_DEPTH` the *wading* cap (M20g lifts it for swimming).
static var LOW: float = -2.1
static var HIGH: float = 0.0
static var FILL: float = 0.75
static var SEEP: float = 0.05
static var WET_DOWN: float = 600.0
static var MAX_DEPTH: float = 0.6
## `TUNING.water.drag` / `dragEnergy`: the share of its speed a goat loses at the cap,
## and the extra energy wading burns.
static var DRAG: float = 0.35
static var DRAG_ENERGY: float = 0.25
## `TUNING.water.wave`: the chop's own numbers -- a 3 cm crest every 60 cm, and the share
## of the gust that drives it. `TUNING.water.fresnel` is the shader's, since `SPECULAR`
## carries it there.
static var WAVE_HEIGHT: float = 0.03
static var WAVE_SCALE: float = 0.6
static var WAVE_SPEED: float = 1.2
static var WAVE_WIND: float = 0.8
## `TUNING.weather.windNorm` is read from its one owner (`SkyModel.WIND_NORM`) rather than a
## second copy here, for the gust's share below.
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

## The wake and the splashes (M20d), every one a `const` in `water.js` rather than a
## `TUNING.water` leaf: they are the *shape* of the effect rather than a feel knob. Three
## rings at once, a ring living `RIPPLE_LIFE` seconds and travelling `RIPPLE_SPEED` m/s, a
## new one every `RIPPLE_STEP` metres of travel, and nothing at all under
## `RIPPLE_MIN_DEPTH` -- a hoof in a film does not leave a ring.
const RIPPLE_MAX := 3
const RIPPLE_LIFE := 1.6
const RIPPLE_SPEED := 1.1
const RIPPLE_STEP := 0.45
const RIPPLE_MIN_DEPTH := 0.04
## A splash is a pool of `SPLASH_MAX` drops, `SPLASH_DROPS` of them thrown by a full
## strength, each living `SPLASH_LIFE` seconds under `SPLASH_GRAVITY` -- so a drop is gone
## before it is a puddle.
const SPLASH_MAX := 24
const SPLASH_DROPS := 8
const SPLASH_LIFE := 0.55
const SPLASH_GRAVITY := 14.0
## `waterSplashDraw`'s sphere, and its colour: the scene's `rl.color(232, 244, 248, ...)`,
## display-space bytes as the port hands them over everywhere else, with the alpha the
## drop's remaining life.
const SPLASH_RADIUS := 0.035
const SPLASH_COLOUR := Color8(232, 244, 248)
const SPLASH_ALPHA := 200.0

## One ring of the wake: where its centre is, how far its front has travelled, and the
## strength the emitter set and the frame decays. The scene's `RIPPLE[i]`.
class Ripple:
	extends RefCounted
	var x := 0.0
	var z := 0.0
	var radius := 0.0
	var strength := 0.0

## One drop of a splash: where it is, how it is going, and the seconds it has left. The
## scene's `SPLASH[i]`, a pooled slot rather than an allocation.
class Drop:
	extends RefCounted
	var x := 0.0
	var y := 0.0
	var z := 0.0
	var vx := 0.0
	var vy := 0.0
	var vz := 0.0
	var life := 0.0

## One actor's wake mark: whether its feet were under the surface *last* frame, and where
## it last laid a ring or threw a drop. The scene keeps the player's in its module scope
## (`goatWet`, `rippleLastX/Z`) and each bot's on the bot itself; here they are one list,
## the goat first and the herd after it, because the order the actors arrive in is the
## order the scene's own `BOTS` array has.
class Mark:
	extends RefCounted
	var wet := false
	var x := 0.0
	var z := 0.0

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
## The pools' flood fill, allocated once and reused -- `water.js`'s `W_POOL`/`W_QUEUE`, and for the
## same reason: `pools()` is on demand (a console verb and a mod's read, never the frame), so the
## walk allocates nothing.
var _pool_marks := PackedInt32Array()
var _pool_queue := PackedInt32Array()
## The waves' own seconds, and *only* while there is water to draw -- `water.js`
## `waterDraw`: the clock advances where the surface does, so a phase that ran on through
## a dry spell would have a fresh pool already mid-cycle. It is deliberately not
## `worldTime`, which wraps at midnight.
var _clock := 0.0
## The rain the last `step` handed in, which `update` reads -- the scene's `rainAmount`
## is a module global there and this keeps the same shape without the global.
var _rain := 0.0
## The wake: three rings and a pool of drops, `RIPPLE_MAX` and `SPLASH_MAX` slots that are
## built once and reused rather than allocated on a splash.
var _ripples: Array[Ripple] = []
var _drops: Array[Drop] = []
## `splashTop`: the pool is a ring buffer, so a full pool loses its oldest drop.
var _drop_top := 0
## One mark per actor, the goat at 0 (see `Mark`). Sized to the actors each frame.
var _marks: Array[Mark] = []
## Tufts the grass field skipped under the water this frame, and splashes thrown ever.
## `state` reports both -- the first is reset by `update`, which is `waterUpdate`'s line.
var culled := 0
var thrown := 0

func _init() -> void:
	# The rings and the drop pool are built once, `weather.gd`'s rain pool's shape: fixed
	# slots, so a splash allocates nothing. The goat's own mark is always actor 0.
	for i in RIPPLE_MAX:
		_ripples.append(Ripple.new())
	for i in SPLASH_MAX:
		_drops.append(Drop.new())
	_marks.append(Mark.new())

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
	# The grass field counts its own skips for the frame about to be drawn, so the count
	# starts here (`waterUpdate`).
	culled = 0
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
	# No water is also no wake: the goat cannot be standing in what is not there, and the
	# step that would notice is only reached when there is a surface to draw. The *herd's*
	# marks are deliberately left alone -- the scene clears `goatWet` and nothing else --
	# so a bot that stood in the last pool and stands in the next lays no entering ring.
	if not _on:
		_marks[0].wet = false

## The `flood <h>` override, for a demo or a bisect. A *level* is any finite number:
## this field's water lives below zero -- the ground is a metre or two of relief either
## side of it -- so a sign cannot double as the off switch.
func set_force(force_level: float) -> void:
	_force = force_level if is_finite(force_level) else NAN
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

## The pools in the field, as *regions* (M20f): a flood fill over the water grid, four-neighbour
## because two cells that only touch at a corner are two pools with a corner in common rather than
## one. A pool is the centroid of its cells, the radius of the circle with their area, how many
## cells it is, and where it is deepest -- the question a player asks of the water ("is that one
## lake or two?"), answered from the table alone.
##
## `water.js`'s `sceneWaterPools`, including its rounding: this is a mod-facing member and a console
## list, so the numbers are quantized the way they are there. The walk is over the grid twice at
## worst and allocates nothing (`_pool_marks`/`_pool_queue`).
func pools() -> Array:
	if not _ready:
		return []
	var count: int = N * N
	if _pool_marks.size() != count:
		_pool_marks.resize(count)
		_pool_queue.resize(count)
	for k in count:
		_pool_marks[k] = 0
	var area: float = CELL * CELL
	var x0: float = _anchor.x - HALF
	var z0: float = _anchor.y - HALF
	var found: Array = []
	for start in count:
		if _pool_marks[start] != 0 or _heights[start] >= _level:
			continue
		var id: int = found.size() + 1
		var head: int = 0
		var tail: int = 0
		var cells: int = 0
		var sum_i: int = 0
		var sum_j: int = 0
		var deepest: float = 0.0
		var deep_i: int = 0
		var deep_j: int = 0
		_pool_marks[start] = id
		_pool_queue[tail] = start
		tail += 1
		while head < tail:
			var k: int = _pool_queue[head]
			head += 1
			var i: int = k % N
			@warning_ignore("integer_division")
			var j: int = (k - i) / N
			var d: float = _level - _heights[k]
			cells += 1
			sum_i += i
			sum_j += j
			if d > deepest:
				deepest = d
				deep_i = i
				deep_j = j
			# Four-neighbour: a corner is two pools with a corner in common.
			if i > 0 and _pool_marks[k - 1] == 0 and _heights[k - 1] < _level:
				_pool_marks[k - 1] = id
				_pool_queue[tail] = k - 1
				tail += 1
			if i < N - 1 and _pool_marks[k + 1] == 0 and _heights[k + 1] < _level:
				_pool_marks[k + 1] = id
				_pool_queue[tail] = k + 1
				tail += 1
			if j > 0 and _pool_marks[k - N] == 0 and _heights[k - N] < _level:
				_pool_marks[k - N] = id
				_pool_queue[tail] = k - N
				tail += 1
			if j < N - 1 and _pool_marks[k + N] == 0 and _heights[k + N] < _level:
				_pool_marks[k + N] = id
				_pool_queue[tail] = k + N
				tail += 1
		found.append({
			"x": _round3(x0 + (float(sum_i) / float(cells)) * CELL),
			"z": _round3(z0 + (float(sum_j) / float(cells)) * CELL),
			"r": _round3(sqrt((float(cells) * area) / PI)),
			"cells": cells,
			"deepest": _round3(deepest),
			"deepX": _round3(x0 + float(deep_i) * CELL),
			"deepZ": _round3(z0 + float(deep_j) * CELL),
		})
	return found

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

## The table's level this frame, which is what the surface is lifted to (`water.gdshader`)
## and what `state` reports rounded.
func level() -> float:
	return _level

## The wave clock, advanced one frame while the table is above the ground.
func advance_clock(delta: float) -> void:
	if _on:
		_clock += delta

## The wave clock's own seconds, which the chop's phase rides.
func clock() -> float:
	return _clock

## Whether the ground under a point stands below the table -- `water.js` `waterSubmergedAt`,
## the whole of what "this ground is under the water" means. It reads the *grid*, so it
## answers for the vertex nearest the point rather than for an interpolation of it, and that
## is the right question for the thing it is asked: a *tuft* stands at a point, and the
## surface is drawn over the ground it stands on.
##
## It is not the sleep rule's test -- that is `in_water` -- and the two differ near a pool's
## edge, where the interpolation is a centimetre deep over a dry vertex.
##
## The count of what it skipped belongs here rather than in the caller because the grass
## field is its one caller and the scene keeps it here (`waterCulled`): a second caller
## would double the number `state` reports.
func submerged_at(x: float, z: float) -> bool:
	if not _on:
		return false
	var i: int = int(round((x - (_anchor.x - HALF)) / CELL))
	var j: int = int(round((z - (_anchor.y - HALF)) / CELL))
	if i < 0 or j < 0 or i >= N or j >= N:
		return false
	if _heights[j * N + i] >= _level:
		return false
	culled += 1
	return true

## Whether a point is *in* the water rather than on a damp film: `water.js` `waterInWater`,
## which is `depth_at >= HUD_MIN` -- the depth the HUD starts reporting at. It is the HUD's
## own line, so the read-out and the rules that read it cannot disagree about what "in the
## water" means: a goat does not doze in it, and a sleeping one is woken when the table
## reaches it.
##
## The *drag* is deliberately not on this test. It is a curve that starts at zero depth,
## because a film does slow a goat a little.
func in_water(x: float, z: float) -> bool:
	return depth_at(x, z) >= HUD_MIN

# ---- the wake and the splashes (M20d) --------------------------------------

## One frame of the wake and the splashes: `water.js` `waterActorStep`.
##
## `actors` is a flat run of `(x, z, py)` triples -- the player's goat first, then the herd
## in bot order, which is the order the scene's own `BOTS` array has. The goat is the actor
## that lays **rings** and the herd gets the edge and the drops and no ring, because
## `RIPPLE_MAX` is three slots and seven walking bots would be the whole of the wake; and
## the goat's step in is the bigger of the two, `1.0` against `0.9`.
##
## The rings are laid by **distance travelled from the last one**, so they are evenly spaced
## however fast a goat walks -- and from the last *ring* rather than from the last frame,
## without which a goat at a walk (two centimetres a frame) never reaches the gate at all.
## That was a bug in the scene, found by a play-through, and both marks below carry it.
func wake_step(delta: float, actors: PackedFloat64Array) -> void:
	if not _on:
		return
	for ring: Ripple in _ripples:
		if ring.strength <= 0.0:
			continue
		ring.radius += RIPPLE_SPEED * delta
		ring.strength -= delta / RIPPLE_LIFE
		if ring.strength < 0.0:
			ring.strength = 0.0
	_splash_step(delta)

	@warning_ignore("integer_division")
	var count: int = actors.size() / 3
	_resize_marks(count)
	for at in count:
		var x: float = actors[at * 3]
		var z: float = actors[at * 3 + 1]
		var py: float = actors[at * 3 + 2]
		var mark: Mark = _marks[at]
		var depth: float = depth_at(x, z)
		# A *footfall* in water is a ring and the drops it throws; a goat merely standing in
		# a pool throws nothing, which is what keeps a wading goat from snowing drops while
		# it grazes. A jump clears it too: `py` is the height above the ground, so a goat in
		# the air over a pool is not in it.
		var wet: bool = depth > RIPPLE_MIN_DEPTH and py < depth
		if wet:
			var rings: bool = at == 0
			if not mark.wet:
				# A step in, a landing, the edge that matters.
				ripple(x, z, 1.0 if rings else 0.9)
				splash(x, z, 0.7 if rings else 0.6)
				mark.x = x
				mark.z = z
			else:
				var dx: float = x - mark.x
				var dz: float = z - mark.z
				if not (dx * dx + dz * dz < RIPPLE_STEP * RIPPLE_STEP):
					# Smaller than a step in -- a stride is not an arrival.
					if rings:
						ripple(x, z, 0.6)
					splash(x, z, 0.3)
					mark.x = x
					mark.z = z
		mark.wet = wet

## Lay a ring, in the **weakest** slot: a ring's strength decays with its age, so the
## weakest is the oldest and there is no index to keep. `waterRippleAdd`.
func ripple(x: float, z: float, strength: float) -> void:
	var at: int = 0
	for i in range(1, _ripples.size()):
		if _ripples[i].strength < _ripples[at].strength:
			at = i
	var slot: Ripple = _ripples[at]
	slot.x = x
	slot.z = z
	slot.radius = 0.0
	slot.strength = strength

## A splash: a few drops leaving the surface in a shallow cone, each one's direction off the
## same `value_hash` the rest of the scene varies itself with, so no two are alike and
## nothing is stored per drop beyond the slot it is in. `waterSplash`.
func splash(x: float, z: float, strength: float) -> void:
	var surface: float = Terrain.height_at(x, z) + depth_at(x, z)
	var count: int = int(round(SPLASH_DROPS * strength))
	thrown += 1
	for i in count:
		if _drop_top >= SPLASH_MAX:
			_drop_top = 0
		var drop: Drop = _drops[_drop_top]
		_drop_top += 1
		var angle: float = Terrain.value_hash(x * 7.1 + z * 3.7 + i * 1.9) * TAU
		var out: float = 0.5 + Terrain.value_hash(x * 4.7 + z * 8.3 + i * 3.1) * 0.9
		var up: float = 1.4 + Terrain.value_hash(x * 2.3 + z * 5.9 + i * 2.7) * 1.6
		drop.x = x + cos(angle) * 0.18
		drop.y = surface + 0.02
		drop.z = z + sin(angle) * 0.18
		drop.vx = cos(angle) * out
		drop.vz = sin(angle) * out
		drop.vy = up
		drop.life = SPLASH_LIFE

## The drops' own physics: a shallow ballistic arc and a life that drains. `waterSplashStep`.
func _splash_step(delta: float) -> void:
	for drop: Drop in _drops:
		if drop.life <= 0.0:
			continue
		drop.life -= delta
		drop.x += drop.vx * delta
		drop.z += drop.vz * delta
		drop.vy -= SPLASH_GRAVITY * delta
		drop.y += drop.vy * delta

## Size the mark list to the actors the frame has, adding a fresh mark for an actor that has
## just appeared and dropping the ones past the end. That is what the scene does by
## construction -- a bot that leaves takes its own mark with it, and one that arrives has
## none, so its first wet frame is an *entry* that lays the ring and the step in rather than
## being read as a goat already walking.
##
## The herd only ever loses its last actors (`set_herd_size` pops from the end), so a mark
## and a bot stay paired; a mirrored herd that loses one from the *middle* would shift the
## marks, which is a wake that is one ring wrong rather than a rule that is.
func _resize_marks(want: int) -> void:
	while _marks.size() > want:
		_marks.pop_back()
	while _marks.size() < want:
		_marks.append(Mark.new())

## One ring as the shader's own `vec4`: its centre, the front's radius in metres, and the
## strength the emitter has already decayed -- which is what keeps the shader stateless
## about time. Every slot is pushed, a spent one as nothing, so a ring cannot linger in the
## shader after its strength reached zero.
func ripple_uniform(index: int) -> Vector4:
	var ring: Ripple = _ripples[index]
	return Vector4(ring.x, ring.z, ring.radius, ring.strength)

## One drop of the pool as `(x, y, z, fade)`, `fade` being its share of `SPLASH_LIFE` still
## to run. A slot holding nothing reports a fade of zero, which is `waterSplashDraw`'s own
## test and what the node drawing them skips on.
func splash_drop(slot: int) -> Vector4:
	var drop: Drop = _drops[slot]
	return Vector4(drop.x, drop.y, drop.z, drop.life / SPLASH_LIFE)

## One drop in full, for a probe or a gate: `(x, y, z, vx, vy, vz, life)`. The *drawn*
## answer is `splash_drop`; this is the water's own state, which is what the next frame's
## integration is a function of and so what a gate has to compare.
func drop_state(slot: int) -> PackedFloat64Array:
	var drop: Drop = _drops[slot]
	return PackedFloat64Array([drop.x, drop.y, drop.z, drop.vx, drop.vy, drop.vz, drop.life])

## How many rings are still going and how many drops are still alive. `state` reports both
## beside `thrown`, because "how many now" and "how many ever" are different questions.
func ripples_live() -> int:
	var n: int = 0
	for ring: Ripple in _ripples:
		if ring.strength > 0.0:
			n += 1
	return n

func splashes_live() -> int:
	var n: int = 0
	for drop: Drop in _drops:
		if drop.life > 0.0:
			n += 1
	return n

## The chop's wind: the wind as a *unit* direction whatever it is doing, and the share of
## the amplitude the gust drives. `water.js` `waterSetUniforms`, and the direction is a
## unit even in a dead calm -- a still pool still chops, and the shader normalises it
## again anyway. Returns `(dx, dz, the gust's share)`, which is the shader's `waterWind`.
func wave_wind(wind_x: float, wind_z: float, wind_sway: float) -> Vector3:
	var length: float = sqrt(wind_x * wind_x + wind_z * wind_z)
	var dx: float = wind_x / length if length > 1e-3 else 1.0
	var dz: float = wind_z / length if length > 1e-3 else 0.0
	var gust: float = clampf(wind_sway / SkyModel.WIND_NORM, 0.0, 1.0)
	return Vector3(dx, dz, (1.0 - WAVE_WIND) + WAVE_WIND * gust)

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
			@warning_ignore("integer_division")
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
		# What the wake did this frame and what it has ever done: a tuft the grass skipped
		# under the water, the drops and rings still going, and the splashes thrown. The
		# scene's `sceneWater` carries the same four.
		"culled": culled,
		"splashes": splashes_live(),
		"thrown": thrown,
		"ripples": ripples_live(),
	}

## `core.js` `netRound3`, with *JavaScript's* rounding: `Math.round` is `floor(x + 0.5)`
## and GDScript's `round` breaks a tie away from zero instead, which differs at exactly
## -.5 -- and this field's level is negative by design, since its floor is `LOW`.
static func _round3(value: float) -> float:
	return floor(value * 1000.0 + 0.5) / 1000.0

# The meadow as food: `food.js`, where grass becomes something a goat can eat.
#
# The canopy itself is `grass.gd` -- the tufts, drawn. This is the *cell* half of
# the same hash, and the port keeps it in one place: a cell's existence and its
# jitter are `cell_hash`, so the grass a goat can see and the grass it can eat
# cannot drift apart. (The scene carries that arithmetic twice, in `food.js` and
# `weather.js`, deliberately, to keep the per-frame call depth down; the port keeps
# the *hash* in one function and inlines only the arithmetic around it, which is
# what `food.js`'s own `nearestTuft` does with the hash itself.)
#
# A tuft's position is returned as **two doubles in a dictionary**, never as a
# `Vector2`, and that cost a gate: every Godot vector type is float32 (see
# `cell_hash`), so `Vector2(tx, tz)` is out by ~2e-6 m at the field's rim. Invisible
# to draw, and not invisible to a rule -- `bots.gd` turns a goat with
# `atan2(-dz, dx)` onto exactly this point, and the herd's tape came apart on a yaw
# that was 4e-7 off. The scene never has the problem because `food.js` hands its
# callers plain numbers.
#
# Eating records the cell and schedules its return (`TUNING.food.regrowMin` to
# `regrowMax`, jittered per cell off a private PRNG so the weather's and the herd's
# streams stay where the scene's cases pin them), so the meadow visibly thins as
# the goat grazes and thickens again patchily.
#
# In a session the meadow is the *host's*: `apply_wire` replaces it from the world
# snapshot's `eaten` list, and `update` counts down only where the scene is its own
# host -- `food.js` `updateFood`'s `netWorldLocal` gate, which is what keeps two
# peers from disagreeing about when a tuft comes back.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
class_name Meadow
extends RefCounted

## `TUNING.food.eatRange`: a tuft closer than this is in reach.
const EAT_RANGE := 1.1
## `TUNING.food.eatEnergy` / `eatSatiety`: what a meal gives.
const EAT_ENERGY := 8.0
const EAT_SATIETY := 0.55
## `TUNING.food.fullBelly` / `fullBellyHeal` / `satietyDecay`.
const FULL_BELLY := 0.85
const FULL_BELLY_HEAL := 3.0
const SATIETY_DECAY := 0.02
## `TUNING.food.regrowMin` / `regrowMax`: the window an eaten tuft comes back in.
const REGROW_MIN := 40.0
const REGROW_MAX := 90.0

## `food.js` `foodRngState`: the meadow's own stream, seeded so a fresh meadow
## regrows in the same order in every process.
const RNG_SEED := 0x1f2e3d4c

## The eaten cells: `tuftKey` -> seconds left before the tuft returns.
var eaten := {}
## How many tufts have been eaten, ever. The scene reports it; a probe reads it.
var eaten_count := 0

var _rng := RNG_SEED

## A cell's three hashes as **uint32 bit patterns**, one per axis of a `Vector3i`.
## Integer, and not the three `[0, 1)` values the field wants, for a reason that cost
## a gate: every Godot vector type stores **float32**, and a `Vector3` of the divided
## values is only good to ~4e-9 -- which is fine for a jitter of +-0.9 m and *not*
## fine for anything that compares one, which is exactly what a cull and a reach test
## do. So the raw bits come back and `unit` does the division in double precision.
##
## `weather.js` `tuftField`, verbatim: `x` decides existence (and the z jitter), `y`
## the x jitter, `z` the sway's phase. The top bit is the sign, because uint32 does
## not fit an int32 -- `unit` reads it as unsigned again.
static func cell_hash(cx: int, cz: int) -> Vector3i:
	var h: int = _i32(cx * 374761393 + cz * 668265263)
	h = _imul(h ^ _ushr(h, 13), 1274126177)
	h = _i32(_ushr(h ^ _ushr(h, 16), 0))
	var h2: int = _i32(cx * 1103515245 + cz * 12345)
	h2 = _imul(h2 ^ _ushr(h2, 15), 2246822519)
	h2 = _i32(_ushr(h2 ^ _ushr(h2, 13), 0))
	var h3: int = _i32(cx * 2654435761 + cz * 40503)
	h3 = _imul(h3 ^ _ushr(h3, 16), 3266489917)
	h3 = _i32(_ushr(h3 ^ _ushr(h3, 16), 0))
	return Vector3i(h, h2, h3)

## One of `cell_hash`'s bit patterns as the `[0, 1)` the field wants. `h / 2**32`,
## read as unsigned -- exact in double precision, which is the point of the split.
static func unit(bits: int) -> float:
	return float(_ushr(bits, 0)) / 4294967296.0

## Whether the meadow grows a tuft in this cell at all: 45% of them, from the hash.
## The threshold is `tuftField`'s, so a cell the grass skips is a cell nothing can
## eat.
static func cell_exists(cx: int, cz: int) -> bool:
	return unit(cell_hash(cx, cz).x) >= 0.45

## Where the cell's tuft stands, in metres: jittered +-0.9 m about the cell's own
## even corner (`cx * TUNING.terrain.cell`). The jitter is the cell's own hash, so
## it is the position the grass draws and the position a goat walks to.
##
## Two plain numbers and not a `Vector2` -- see the header on what that cost.
static func tuft_x(cx: int, cz: int, bits: Vector3i) -> float:
	return cx * Terrain.CELL + (unit(bits.y) - 0.5) * 1.8

static func tuft_z(cx: int, cz: int, bits: Vector3i) -> float:
	return cz * Terrain.CELL + (unit(bits.x) - 0.5) * 1.8

## A cell's identity as one number, unique for the cell range the field spans.
## `food.js` `tuftKey`, and the form the wire's `eaten` list uses.
static func key(cx: int, cz: int) -> int:
	return (cx + 4096) * 8192 + (cz + 4096)

## The cell a key names, as `(cx, cz)`. `food.js` `tuftCell`, the inverse of `key`.
static func cell_of(key_value: int) -> Vector2i:
	return Vector2i(key_value / 8192 - 4096, key_value % 8192 - 4096)

## The cell a world position is in.
static func cell_at(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / Terrain.CELL)), int(floor(z / Terrain.CELL)))

## The nearest *edible* tuft within `range` of `(x, z)`, as
## `{x, z, cx, cz, d2}`, or an empty dictionary.
##
## `filter` sees each candidate cell `(cx, cz)` and answers whether it counts. The
## scene has two callers: everything (`nearestTuft` with no filter) and *only trapped
## tufts* (the walk-over trigger), and the second is `explosions.trap_at` -- so what
## "trapped" means stays the device system's business and this stays the meadow's.
## The scene's own `trappedOnly` flag is that filter, spelled as a flag because it had
## one caller; a `Callable` is how GDScript says the same thing without the meadow
## having to link against the devices.
##
## The search walks every cell in range and keeps the closest, rather than stopping
## at the first: the jitter is +-0.9 m and a neighbour's tuft can be nearer than
## the goat's own cell's.
func nearest(x: float, z: float, reach: float = EAT_RANGE,
		filter: Callable = Callable()) -> Dictionary:
	var r: int = int(ceil(reach / Terrain.CELL))
	var centre: Vector2i = cell_at(x, z)
	var best := {}
	var best_d2: float = reach * reach
	for i in range(centre.x - r, centre.x + r + 1):
		for j in range(centre.y - r, centre.y + r + 1):
			if not cell_exists(i, j):
				continue
			if eaten.has(key(i, j)):
				continue
			if filter.is_valid() and not bool(filter.call(i, j)):
				continue
			var bits: Vector3i = cell_hash(i, j)
			var tx: float = tuft_x(i, j, bits)
			var tz: float = tuft_z(i, j, bits)
			var dx: float = tx - x
			var dz: float = tz - z
			var d2: float = dx * dx + dz * dz
			if d2 <= best_d2:
				best_d2 = d2
				best = {"x": tx, "z": tz, "cx": i, "cz": j, "d2": d2}
	return best

## The tuft in this cell, as `nearest` would describe it, whether or not it is
## still standing. `explosions.js` `tuftInCell`'s shape -- it exists so a caller
## holding a *cell* (a device's, a bite's) does not have to search for it.
func tuft_in(cx: int, cz: int) -> Dictionary:
	if not cell_exists(cx, cz):
		return {}
	var bits: Vector3i = cell_hash(cx, cz)
	return {"x": tuft_x(cx, cz, bits), "z": tuft_z(cx, cz, bits), "cx": cx, "cz": cz,
		"d2": 0.0}

## Whether a tuft is standing in this cell right now -- the meadow as it is, not as
## it is derived. `food.js` `EATEN.has`, for the one caller that needs to ask.
func has_tuft(cx: int, cz: int) -> bool:
	return cell_exists(cx, cz) and not eaten.has(key(cx, cz))

## Eat the tuft in a cell: it disappears and its return is scheduled. Returns false
## when there was nothing there, which is what makes a bite safe to attempt.
func consume(cx: int, cz: int) -> bool:
	if not has_tuft(cx, cz):
		return false
	_assign_regrow(key(cx, cz))
	return true

## Record a cell the *host* reported eaten. The host owns the meadow, so this is
## where a client's bite becomes real; a cell already gone is ignored.
func consume_key(key_value: int) -> void:
	if eaten.has(key_value):
		return
	_assign_regrow(key_value)

## Replace the meadow with the server's, wholesale. Joining adopts the server's
## world rather than merging it with the one this scene had already generated.
##
## A snapshot that could not carry the meadow -- the world was over its datagram
## budget, so the meadow was the part that went -- sends `null` instead, and that
## means "keep the one you have". Clearing it would put back every tuft the host
## has eaten, and a goat that believes a tuft is there cannot eat it.
func apply_wire(list: Variant) -> void:
	if not (list is Array):
		return
	eaten.clear()
	for entry in list:
		if entry is Dictionary:
			eaten[int(entry.get("key", 0))] = float(entry.get("left", 0.0))

## The meadow as the wire sees it: the eaten cells and their remaining seconds.
func wire() -> Array:
	var out: Array = []
	for key_value in eaten:
		out.append({"key": key_value, "left": eaten[key_value]})
	return out

## Once per frame: let eaten tufts grow back. Skipped in a session, where the host's
## countdown is the only one that exists (`updateFood`).
func update(delta: float, local: bool) -> void:
	if not local:
		return
	if eaten.is_empty():
		return
	for key_value in eaten.keys():
		var left: float = float(eaten[key_value]) - delta
		if left <= 0.0:
			eaten.erase(key_value)
		else:
			eaten[key_value] = left

## A meal's second helping: a goat whose belly is already nearly full has nothing
## left to *fill*, so the grass goes into the goat instead. Read *before* the meal,
## because what decides is the state the goat ate in. Returns 0 below the line, so
## a call site reads as one addition.
static func sated_heal(belly: float) -> float:
	if belly < FULL_BELLY:
		return 0.0
	return FULL_BELLY_HEAL

## Draw a regrow time for a cell and record it. `food.js` `assignRegrow`: an
## xorshift32, so the jitter is reproducible and off the weather's stream.
func _assign_regrow(key_value: int) -> void:
	_rng = _ushr(_rng ^ _i32(_rng << 13), 0)
	_rng = _ushr(_rng ^ _ushr(_rng, 17), 0)
	_rng = _ushr(_rng ^ _i32(_rng << 5), 0)
	eaten[key_value] = REGROW_MIN + (float(_rng) / 4294967296.0) * (REGROW_MAX - REGROW_MIN)
	eaten_count += 1

## `| 0`: wrap to int32.
static func _i32(value: int) -> int:
	var low: int = value & 0xFFFFFFFF
	if low >= 0x80000000:
		return low - 0x100000000
	return low

## `Math.imul`: the low 32 bits of a product, as a signed int32. GDScript's `int` is
## 64-bit and its multiply wraps modulo 2**64, which preserves the low 32 bits.
static func _imul(a: int, b: int) -> int:
	return _i32(a * b)

## `>>>`: a right shift of the value read as unsigned.
static func _ushr(value: int, bits: int) -> int:
	return (value & 0xFFFFFFFF) >> bits

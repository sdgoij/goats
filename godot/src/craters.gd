# The craters: `explosions.js`'s M19d half, which is where a bang does something to
# the *ground*.
#
# A crater is not geometry. It is a **term in `Terrain.height_at`** — a bowl with a
# raised rim, eased back to flat as it heals — so everything that reads the ground
# stands in it for free: the goat, the mirrored herd, the grass, the shadow casters
# and the drawn mesh, with nothing added anywhere. That is the whole reason the
# scene put it in the heightfield rather than in a model, and it is why this is a
# *static* class: `height_at` is a static function read by classes that have no node
# to ask (`Herd`, `Grass`, `PlayerGoat`, `TerrainMesh`), and the scene's own
# `terrainHeight` reads a module-global list the same way.
#
# The list is the only state. It is capped at `crater.max` with the oldest retired
# first — a bang with no hole is a promise broken, a far-away crater closing over is
# not — and it heals over `crater.heal`, which is what keeps it bounded.
#
# Not ported, and each is a deliberate hole: the scorch tint (`scorch`/`scorchRange`,
# a camera-facing alpha quad, and the one part of this system that was fill rate
# rather than geometry), and `markCraterTufts`'s book-keeping beyond what the meadow
# already does. The *shape* of the ground, which is what everything stands on, is the
# scene's.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
class_name Craters
extends RefCounted

## `TUNING.explosions.crater` -- `static var` so the tuning tree can write each.
static var RADIUS: float = 1.6
static var DEPTH: float = 0.45
static var LIP: float = 0.12
static var HEAL: float = 240.0
static var MAX: int = 24
## `CRATER_LIP_OUT`: metres outside the dish's radius where the raised lip has fallen
## back to nothing.
const LIP_OUT := 1.45
## `CRATER_STEP`: how far the dish eases before the ground's caches are told to catch
## up -- and so the size of the step a goat standing in a healing crater feels, and
## the resolution of a rebuild. Ten centimetres is under a hoof fall.
const STEP := 0.1

## `explosions.js` `CRATERS`: `{ x, z, r, reach2, depth, dip, lip, seed, age, heal, drop }`.
static var list: Array = []
## Set when the ground has moved far enough that the drawn mesh is wrong. `main.gd`
## reads it, clears it and rebuilds -- the port's `terrainDirty`.
static var dirty := false
## Cell -> the craters whose reach box holds that cell. The scene uses a 1024-slot
## array indexed by a hash of the cell (a query must not allocate, and it is read
## thousands of times a frame); a `Dictionary` keyed by the ground's own cell is the
## same narrowing with one hash lookup, and it cannot collide two craters into a slot
## they do not both belong to. The reach test still runs, so a miss is only slower.
static var _bucket := {}

## Dig one. The radius varies a little per bang -- a minefield of identical holes
## reads as a pattern -- and the depth is the tuning's.
static func add(x: float, z: float, bang_seed: float) -> void:
	if RADIUS <= 0.0 or DEPTH <= 0.0 or MAX <= 0:
		return
	# The cap retires the oldest rather than refusing the newest.
	while list.size() >= MAX and not list.is_empty():
		_retire(list[0])
		list.remove_at(0)
	var r: float = RADIUS * (0.85 + Terrain.value_hash(bang_seed) * 0.3)
	list.append(_crater(x, z, r, DEPTH, bang_seed, HEAL))
	_reindex()
	dirty = true

## Forget every crater: the ground comes back and the mesh is told. What a scene
## resets the field with, and what the new-life case needs.
static func clear() -> void:
	for crater: Dictionary in list:
		crater["dip"] = 0.0
	list.clear()
	_reindex()
	dirty = true

## Age the craters: the dish eases back to flat over `heal`, and the mesh is told
## when it has moved far enough to matter. This runs whether or not the devices are
## armed: the ground is not an effect, and a crater that never healed would be a hole
## in the world left by a debug switch.
##
## The step is *quantized*, so the dip this returns and the dip the mesh was built
## from are the same number: one rebuild per step, and no drift between the ground
## the goat walks on and the ground it can see.
static func update(delta: float) -> void:
	if list.is_empty():
		return
	var changed := false
	var i: int = list.size() - 1
	while i >= 0:
		var crater: Dictionary = list[i]
		crater["age"] = float(crater["age"]) + delta
		if float(crater["age"]) >= float(crater["heal"]):
			crater["dip"] = 0.0
			list.remove_at(i)
			changed = true
			i -= 1
			continue
		var next: float = float(crater["depth"]) \
			* (1.0 - float(crater["age"]) / float(crater["heal"]))
		if float(crater["drop"]) - next >= STEP:
			crater["drop"] = floor(next / STEP) * STEP
			crater["dip"] = crater["drop"]
			dirty = true
		i -= 1
	if changed:
		_reindex()
		dirty = true

## The craters' own contribution to the ground at a point: the bowl with its raised
## rim. Called from `height_at` for every goat, every tuft cell and every vertex of a
## rebuild, so the shape is: nothing at all when there are no craters, and one bucket
## lookup plus the handful of craters whose reach box holds the point.
static func dip_at(x: float, z: float) -> float:
	if list.is_empty():
		return 0.0
	var here: Variant = _bucket.get(cell_at(x, z), null)
	if here == null:
		return 0.0
	var craters: Array = here
	var dip: float = 0.0
	for crater: Dictionary in craters:
		var dx: float = x - float(crater["x"])
		var dz: float = z - float(crater["z"])
		var d2: float = dx * dx + dz * dz
		if d2 > float(crater["reach2"]):
			continue
		var t: float = sqrt(d2) / float(crater["r"])
		if t < 1.0:
			# The bowl: -dip at the centre, flat at the rim.
			var s: float = 1.0 - t
			dip -= float(crater["dip"]) * s * s * (3.0 - 2.0 * s)
		else:
			# The lip: raised at the rim, nothing at `LIP_OUT`.
			var lip: float = (t - 1.0) / (LIP_OUT - 1.0)
			if lip > 1.0:
				continue
			lip = 1.0 - lip
			dip += float(crater["lip"]) * lip * lip * (3.0 - 2.0 * lip)
	return dip

## How many craters the ground is carrying, and the deepest one's depth -- what a
## probe reports rather than asserts.
static func count() -> int:
	return list.size()

## One line per crater, for a probe or a log.
static func describe() -> Array:
	var lines: Array = []
	for crater: Dictionary in list:
		lines.append("  crater at (%.2f, %.2f) r %.3f, dip %.3f of %.3f, age %.1f s" % [
			crater["x"], crater["z"], crater["r"], crater["dip"], crater["depth"],
			crater["age"]])
	return lines

## `explosions.js` `sceneCraters`: the live craters as the wire carries them -- the four fields
## `proto::Crater` has, and no more. The age and the heal clock are deliberately absent: a client
## mirrors the *ground* rather than the hole's clock, so the depth it is told is the live one and
## the seconds it has left are the host's business (see `apply_wire`).
static func wire() -> Array:
	var out: Array = []
	for crater: Dictionary in list:
		out.append({
			"x": crater["x"],
			"z": crater["z"],
			"r": crater["r"],
			"depth": crater["dip"],
		})
	return out

## The host's craters: state rather than events, because a joiner has to see the
## ground as it is. `null` keeps what we have -- the snapshot could not carry them --
## and a list is adopted whole.
##
## Reconciled in place rather than rebuilt: the world arrives ten times a second, and
## retiring and re-adding every crater each time would rebuild the mesh with it, which
## is exactly the cost the scene spent its time removing. So a crater is matched to
## the host's by position, adopted if it is there and retired if it is not.
##
## A mirrored crater **does not heal**: the host heals and this end mirrors, so a dish
## that aged here would disagree with the ground the host is telling everyone about.
## The snapshot that drops it is what retires it.
static func apply_wire(entries: Variant) -> void:
	if not (entries is Array):
		return
	var host: Array = entries
	var matched := {}
	for entry: Variant in host:
		if not (entry is Dictionary):
			continue
		var spot: Dictionary = entry
		var found: int = _nearest_index(float(spot.get("x", 0.0)), float(spot.get("z", 0.0)))
		if found < 0:
			var r: float = float(spot.get("r", RADIUS))
			var depth: float = float(spot.get("depth", DEPTH))
			list.append(_crater(float(spot.get("x", 0.0)), float(spot.get("z", 0.0)), r,
				depth, 0.0, INF))
			matched[list.size() - 1] = true
		else:
			var crater: Dictionary = list[found]
			crater["depth"] = float(spot.get("depth", DEPTH))
			crater["dip"] = crater["depth"]
			crater["drop"] = floor(float(crater["depth"]) / STEP) * STEP
			matched[found] = true
	# Whatever the host no longer has is gone -- it healed, or the cap retired it.
	var i: int = list.size() - 1
	while i >= 0:
		if not matched.has(i):
			list[i]["dip"] = 0.0
			list.remove_at(i)
		i -= 1
	_reindex()
	dirty = true

## The cell a world position is in, on the ground's own grid (`TERRAIN_CELL`), which
## is what the bucket is keyed by.
static func cell_at(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / Terrain.CELL)), int(floor(z / Terrain.CELL)))

static func _crater(x: float, z: float, r: float, depth: float, bang_seed: float,
		heal: float) -> Dictionary:
	var reach: float = r * LIP_OUT
	return {
		"x": x,
		"z": z,
		"r": r,
		"reach2": reach * reach,
		"depth": depth,
		"dip": depth,
		"lip": LIP,
		"seed": bang_seed,
		"age": 0.0,
		"heal": heal,
		"drop": depth,
	}

## The index of a crater at (about) this position, or -1. The tolerance is the
## host's own precision: the wire carries floats and a bang's own centre does not
## move, so a match is a match and a near-miss is a different hole.
static func _nearest_index(x: float, z: float) -> int:
	for i in list.size():
		var dx: float = x - float(list[i]["x"])
		var dz: float = z - float(list[i]["z"])
		if dx * dx + dz * dz <= 0.0625:
			return i
	return -1

static func _retire(crater: Dictionary) -> void:
	crater["dip"] = 0.0

## Rebuild the whole index. It is at most 24 craters over at most nine cells each and
## it happens on events rather than per frame -- and a bucket that is merely rebuilt
## cannot drift out of step with the list it indexes.
static func _reindex() -> void:
	_bucket = {}
	for crater: Dictionary in list:
		var reach: float = sqrt(float(crater["reach2"]))
		var i0: int = int(floor((float(crater["x"]) - reach) / Terrain.CELL))
		var i1: int = int(floor((float(crater["x"]) + reach) / Terrain.CELL))
		var j0: int = int(floor((float(crater["z"]) - reach) / Terrain.CELL))
		var j1: int = int(floor((float(crater["z"]) + reach) / Terrain.CELL))
		for cx in range(i0, i1 + 1):
			for cz in range(j0, j1 + 1):
				var cell := Vector2i(cx, cz)
				if not _bucket.has(cell):
					_bucket[cell] = []
				(_bucket[cell] as Array).append(crater)

# The devices: `explosions.js` — the mines, the trapped tufts, the bangs they make
# and everything a bang does to the world.
#
# Two devices, both **derived** rather than placed: a 2-unit cell either holds a mine
# or does not, and a share of the tufts are trapped, from a hash of the cell salted
# per session. Nothing is stored and nothing travels at boot, so every process that
# knows the session seed computes the same field — which is also what makes a mine
# detector a *mod* rather than a core feature, and why the layout needs no room on
# the wire. `tools/verify_devices.gd` checks that derivation against `explosions.js`
# itself, the way every other gate here checks its own system.
#
# The only state is where the devices *are*: which cells have already gone off and
# which cells a replacement moved into (`spent`/`moved` and their trap twins), what is
# waiting on a fuse, and the craters the ground is carrying (`craters.gd`). A device
# does not blow up where it was tripped: the trigger starts a fuse, the device leaves
# the world immediately — so it cannot be tripped twice while it waits — and its
# *replacement* is placed elsewhere. Where the replacement goes is drawn from the cell
# that fired, so the move needs no word on the wire either.
#
# What this file is not: the sound (`audio.js`; there is none yet) and the mods' own
# `blast` event, which needs an event seam in `ModHost` that does not exist. And the
# *look* is the port's: the rules below are transcribed, and the fireball and the
# smoke column are Godot sprites driven by the tuning's times and scales rather than
# `fxAtlasPixels`'s generated flipbook. The debris ballistics, the light and the
# camera knock are the scene's numbers.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
class_name Explosions
extends Node3D

## `TUNING.explosions`, verbatim.
const SAFE := 8.0
const FUSE := 0.18
const MAX_ACTIVE := 24
const MINE_DENSITY := 0.012
const MINE_TRIGGER := 0.6
const MINE_CLEARANCE := 0.45
const TRAP_CHANCE := 0.04
const RELOCATE_MIN := 8.0
const RELOCATE_MAX := 24.0
const RELOCATE_TRIES := 12
const BLAST_RADIUS := 3.2
const BLAST_DAMAGE := 45.0
const BLAST_HEALTH_FLOOR := 1.0
const BLAST_PUSH := 13.0
const BLAST_LIFT := 34.0
const CHAIN_DELAY := 0.15
const CHAIN_DEPTH := 1
const FLASH_TIME := 0.3
const FLASH_ENERGY := 1.5
const FLASH_LIFT := 0.9
const SHAKE_ENERGY := 0.26
const SHAKE_RANGE := 12.0
const SHAKE_DECAY := 1.5
const SHAKE_SPEED := 26.0
const FX_BLAST_TIME := 0.5
const FX_BLAST_SCALE := 4.2
const FX_BLAST_LIFT := 1.1
const FX_SMOKE_TIME := 1.2
const FX_SMOKE_SCALE := 5.6
const FX_SMOKE_LIFT := 2.2
const DEBRIS_COUNT := 7
const DEBRIS_TIME := 0.9
const DEBRIS_SPEED := 7.5
const DEBRIS_UP := 5.5
const DEBRIS_GRAVITY := 22.0
const DEBRIS_SIZE := 0.16

## `weather.js` `trapSalt`: the session salt, deliberately not one of the four
## streams and never on the wire -- the layout is derived and never advances, so a
## peer needs the seed and not a mid-session value.
const DEFAULT_SALT := 0x2f6e2b1d

## Where the devices are. `tuftKey` values, exactly as the meadow's `eaten` uses.
var spent := {}
var moved := {}
var trap_spent := {}
var trap_moved := {}
## Fuses: `{ kind, key, x, z, seed, depth, left }`.
var pending: Array = []
var salt := DEFAULT_SALT
## Counters a probe reads rather than asserts.
var trips := 0
var blasts := 0
## Whether the *core* devices are in the field at all (`APIv1.md` section 4.15's
## `goats.explosions.armed`). It is the mirror of the facade's own set of mods that have taken the
## field away -- the request belongs to the mod that made it, so the set is the mods' and this is
## one answer derived from it. Both derivations read it (`mine_armed`, `trap_at`), which is what
## makes a "clear the field" tool a mod rather than a second device system.
var core_armed := true

## The player's own reaction to a bang it was inside: metres of camera knock and
## where the knock is in its oscillation. Both are this process's, and nothing on the
## wire -- they are about *this* goat being hit.
var shake_energy := 0.0
var shake_phase := 0.0
var shake_dir := Vector2.ZERO

## The HUD's red frame (`explosions.js` `hurtPulse`), as a fraction of a full-strength hit. The
## strongest *unrecovered* hit wins, so a second bang cannot make a bruise look like a scratch.
var hurt_pulse := 0.0

## The live effect bursts. Fixed pool, built once: nothing allocates on a bang.
var _fire: Array = []
var _smoke: Array = []
var _burst := []
var _live := 0
var _light: OmniLight3D
var _flash_energy := 0.0
var _flash_left := 0.0
var _debris: MultiMeshInstance3D

## The two things a bang has to reach: the goat (to hurt and to throw) and the
## meadow (a trap has to land in a cell that grows a tuft, and a trigger is a walk
## over one). `main.gd` hands them in; either may be null, and a bang still lands.
var goat: PlayerGoat
var meadow: Meadow
var terrain: TerrainMesh
## ...and the third: the herd a bang throws and kills (M19a). It is `bots.js`'s own
## `netWorldLocal()` gate -- offline and on the host the herd is ours to move and takes the
## blast, and a client's is empty because it only mirrors what the host sends.
var bots: Bots

## The two sound seams (`audio.js` `playTrigger` and `playBlast`): `Callable`s rather than an
## audio reference, for the reason `Meadow.nearest`'s filter is one -- this file does not link
## against the audio module. A bang is *heard* wherever the goat is, so it is the devices that
## know one happened and the scene that decides what that sounds like.
var trigger_sound: Callable = Callable()
var bang_sound: Callable = Callable()
var net_fired: Callable = Callable()
## The `blast` *events* a frame has produced, waiting to be said. **Queued rather than raised**, and
## that is a rule about where the work can happen rather than a preference (`PORT.md` section 9): a
## bang a *mod* asked for runs inside that mod's own JavaScript, where the extension is borrowed, so
## a call back into `ModHost` from there panics (`Gd<T>::bind_mut() failed, already bound`). The same
## shape `gfx.unload` takes for the same reason: the bang records what happened and the frame says
## it, outside every mod.
##
## The array is drained by `take_blast_events` once per frame, and a handler that sets off another
## bang appends to the *next* frame's list rather than recursing through this one.
var blast_events: Array = []

func _ready() -> void:
	_build_fx()
	_build_light()

## Derive the session salt from the session seed. `weather.js` `sceneUseSeed`, with
## the four streams drawn first so the salt is the *fifth* draw: the port does not use
## those four values (the meadow takes its own from the wire), but the draw order is
## what makes this number the scene's.
func use_seed(seed: int) -> void:
	var s: int = _i32(seed)
	if s == 0:
		s = 1
	# Five draws: the scene's four streams take the first four and the salt is the
	# fifth. Each one is guarded, because the scene stores `next() || 1` and a stored
	# zero would change every draw after it.
	var value: int = 1
	for draw in 5:
		s = _ushr(s ^ _i32(s << 13), 0)
		s = _ushr(s ^ _ushr(s, 17), 0)
		s = _ushr(s ^ _i32(s << 5), 0)
		if s == 0:
			s = 1
		value = s
	salt = value

## The devices that have gone off, as the wire carries them (`net.js` `netWorldSpent`): the mines
## first, then the trapped tufts, each as its packed cell key and which kind it was. Where a
## device *moved to* is deliberately absent -- the destination is derived from the key that fired,
## so a client that has the key has the whole field.
func wire_spent() -> Array:
	var out: Array = []
	for key_value in spent:
		out.append({"key": key_value, "trap": false})
	for key_value in trap_spent:
		out.append({"key": key_value, "trap": true})
	return out

## The pulse's fade, in fractions a second, and the damage a full-strength flash is
## (`TUNING.explosions.pulse`).
const PULSE_DECAY := 2.4
const PULSE_DAMAGE := 25.0

## One frame: the ground heals, the fuses run down, the effects age, the knock
## decays. Runs whether or not the devices are armed -- a crater that never healed
## would be a hole in the world left by a debug switch.
func update(delta: float) -> void:
	Craters.update(delta)
	_update_bursts(delta)
	if _flash_left > 0.0:
		_flash_left = maxf(0.0, _flash_left - delta)
		_flash_energy = FLASH_ENERGY * pow(_flash_left / FLASH_TIME, 2.0)
		if _light != null:
			_light.light_energy = _flash_energy * 3.0
			_light.visible = _flash_left > 0.0
	# The knock, on the scene's own rule: a metre and a half a second given back.
	if shake_energy > 0.0:
		shake_phase += delta * SHAKE_SPEED
		shake_energy = maxf(0.0, shake_energy - SHAKE_DECAY * delta)
	# ...and the HUD's flash, fading at `pulse.decay` a second until it is gone.
	if hurt_pulse > 0.0:
		hurt_pulse = maxf(0.0, hurt_pulse - delta * PULSE_DECAY)
	# Fuses last, so a bang that lands this frame can still chain.
	var i: int = pending.size() - 1
	while i >= 0:
		var fuse: Dictionary = pending[i]
		fuse["left"] = float(fuse["left"]) - delta
		if float(fuse["left"]) > 0.0:
			i -= 1
			continue
		pending.remove_at(i)
		blast(String(fuse["kind"]), float(fuse["x"]), float(fuse["z"]),
			float(fuse["seed"]), int(fuse["depth"]), int(fuse["key"]))
		i -= 1

## Where the camera is knocked to, in metres. `sceneFrame` moves the camera *and*
## what it looks at by the same offset, so the world shifts rather than the view
## swinging -- `main.gd` does the same.
func shake_offset() -> Vector3:
	if shake_energy <= 0.0:
		return Vector3.ZERO
	var wobble: float = sin(shake_phase) * shake_energy
	return Vector3(shake_dir.x * wobble, 0.0, shake_dir.y * wobble)

# ---- the field --------------------------------------------------------------

## A cell's trap value in `0..1`: the same integer mixing the meadow's cell hash uses,
## with the session salt mixed in. `explosions.js` `trapNoise`.
##
## The first sum is done in **double precision**, not in `int`, and that is not a style
## choice. `trap_at` calls this with `cx ^ 0x5bf03635`, so `cx` is about 1.5e9 and
## `cx * 374761393` is about 5.6e17 — past 2**53, where a JavaScript number stops being
## able to hold an integer exactly. The scene's own sum is therefore *rounded* before
## `| 0` takes the low 32 bits, and an exact 64-bit multiply takes different bits: the
## port's mines were right and its **traps** were wrong in 8% of cells, which is what
## `verify_devices.gd` found. The gates that only ever pass small cells (the meadow's)
## see no difference at all — those products stay under 2**53.
func trap_noise(cx: int, cz: int, with_salt: int) -> float:
	var wide: float = float(cx) * 374761393.0 + float(cz) * 668265263.0 + float(with_salt)
	var h: int = _i32(int(wide))
	h = _imul(h ^ _ushr(h, 13), 1274126177)
	return float(_ushr(h ^ _ushr(h, 16), 0)) / 4294967296.0

## Whether the derived field puts a mine in this cell: a share of the cells, outside
## the spawn's safe disc. The disc is measured to the cell's nearest edge rather than
## to its centre, so it is a guarantee about the ground rather than about points.
func mine_at(cx: int, cz: int) -> bool:
	var x: int = cx * 2 + 1
	var z: int = cz * 2 + 1
	var ax: int = -x if x < 0 else x
	var az: int = -z if z < 0 else z
	var dx: int = (ax - 1) if ax > 1 else 0
	var dz: int = (az - 1) if az > 1 else 0
	if float(dx * dx + dz * dz) < SAFE * SAFE:
		return false
	return trap_noise(cx, cz, salt) < MINE_DENSITY

## Whether cell `(cx, cz)` holds an armed mine *now*: the derived field, minus the
## mines that have gone off, plus the replacements that have moved in.
func mine_armed(cx: int, cz: int) -> bool:
	# `explosions.js`'s own first line: while any mod has the field away, nothing in it is armed.
	# A bang already in flight still lands -- this is the *derivation*, and `pending` is not asked.
	if not core_armed:
		return false
	var key: int = Meadow.key(cx, cz)
	if spent.has(key):
		return false
	return moved.has(key) or mine_at(cx, cz)

## Whether the tuft in this cell is trapped now, on the same rule.
func trap_at(cx: int, cz: int) -> bool:
	if not core_armed:
		return false
	var key: int = Meadow.key(cx, cz)
	if trap_spent.has(key):
		return false
	return trap_moved.has(key) \
		or trap_noise(cx ^ 0x5bf03635, cz ^ 0x27d4eb2f, salt) < TRAP_CHANCE

## `goats.explosions.armed(on)`: whether the core devices are in the field. The *set* of requests
## is the facade's (it is the mods' own ids), so this is the one bit they derive to; `true` hands
## the field back. Answers the new state, which is what the reference's `modCoreArmed` does.
func set_core_armed(on: bool) -> bool:
	core_armed = on
	return core_armed

## The armed mine within `trigger` of `(x, z)`, as `{ cx, cz, x, z }`, or empty.
##
## The goat's *own* cell only, because that is the only cell a mine's trigger disc can
## reach: the disc is `trigger` around a 2 m cell's centre, so it never comes within
## `trigger` of a neighbour's centre. One cell per goat per arrival, not a box.
func mine_in_cell(x: float, z: float, cx: int, cz: int) -> Dictionary:
	if not mine_armed(cx, cz):
		return {}
	var mx: float = cx * 2 + 1
	var mz: float = cz * 2 + 1
	var dx: float = mx - x
	var dz: float = mz - z
	if dx * dx + dz * dz > MINE_TRIGGER * MINE_TRIGGER:
		return {}
	return {"cx": cx, "cz": cz, "x": mx, "z": mz}

## Where the device in a cell is, or empty when the cell holds none. A mine sits at
## its cell's centre and a trap on the tuft it trapped, which the meadow already
## derives -- so this is the one place the two vocabularies meet, and it is what a
## console or a mod asks to turn a cell into a place.
func device_at(kind: String, cx: int, cz: int) -> Dictionary:
	if kind == "trap":
		if not trap_at(cx, cz):
			return {}
		if not meadow.has_tuft(cx, cz):
			return {}
		return meadow.tuft_in(cx, cz)
	if not mine_armed(cx, cz):
		return {}
	return {"cx": cx, "cz": cz, "x": cx * 2 + 1, "z": cz * 2 + 1, "d2": 0.0}

## The devices near `(x, z)`, which is `sceneTraps` (`explosions.js`) transcribed -- and it is the
## *same* derivation the `traps` console verb prints and the trigger question the goat's own step
## asks, which is the whole point of exposing it: a mine detector is a mod, and a "clear the field"
## tool is another.
##
## The two devices are judged differently and deliberately. A mine sits at its cell's centre, so
## that centre *is* its position and filtering the cell by the distance is right for it; a trapped
## tuft sits at the tuft -- up to 1.4 m from the centre above -- so it is reported and judged at the
## tuft, and a cell the centre keeps out of range can hold a tuft that is in it. A tuft that has
## been eaten is not a device any more.
##
## Raw numbers, not rounded ones: a console line is prose and rounds, while
## `goats.explosions.traps` hands a mod the scene's own values (`APIv1.md` section 4.15). The
## parameter is `reach` rather than the reference's `range`, because `range` is a GDScript built-in.
func traps_near(x: float, z: float, reach: float) -> Dictionary:
	var out: Dictionary = {"mines": [], "traps": []}
	var range2: float = reach * reach
	var r: int = int(ceilf(reach / 2.0)) + 1
	var centre: Vector2i = Meadow.cell_at(x, z)
	for cx: int in range(centre.x - r, centre.x + r + 1):
		for cz: int in range(centre.y - r, centre.y + r + 1):
			var key_value: int = Meadow.key(cx, cz)
			var mx: float = float(cx * 2 + 1)
			var mz: float = float(cz * 2 + 1)
			var dx: float = mx - x
			var dz: float = mz - z
			if dx * dx + dz * dz <= range2 and mine_armed(cx, cz):
				out["mines"].append({
					"x": mx, "z": mz, "key": key_value,
					"dist": sqrt(dx * dx + dz * dz), "moved": moved.has(key_value),
				})
			if not trap_at(cx, cz):
				continue
			if meadow.eaten.has(key_value):
				continue
			var t: Dictionary = meadow.tuft_in(cx, cz)
			if t.is_empty():
				continue
			var tdx: float = float(t["x"]) - x
			var tdz: float = float(t["z"]) - z
			if tdx * tdx + tdz * tdz > range2:
				continue
			out["traps"].append({
				"x": float(t["x"]), "z": float(t["z"]), "key": key_value,
				"dist": sqrt(tdx * tdx + tdz * tdz), "moved": trap_moved.has(key_value),
			})
	return out

## A bang a mod asked for (`goats.explosions.blast`, `APIv1.md` section 4.15), which is `modBlast`
## transcribed: the device in the cell is spent **here** as well as on every other process, and then
## the bang goes through the scene's own path -- the crater, the damage, the flash, the camera knock,
## the sound, the `blast` event and, in a session, the report (`net_fired`) -- so a world mod's bang
## is the host's and everybody sees it.
##
## Spending it here is what keeps the cell armed *nowhere*: every other process spends it from the
## key in the report, so an origin that skipped this would leave the device standing where the bang
## happened and whatever the mod sent over it would trip the same device on the way back.
##
## The **kind** is the core's own enum -- `"mine"` or `"trap"` -- and it is only which core
## behaviour the bang follows: anything else a mod's own device *is* belongs on `world.extend`,
## which is where a world mod already publishes its own state.
func mod_blast(kind: String, x: float, z: float) -> bool:
	var what: String = "trap" if kind == "trap" else "mine"
	var cell: Vector2i = Meadow.cell_at(x, z)
	spend(what, cell.x, cell.y)
	blast(what, x, z, Terrain.value_hash(x * 7.1 + z * 3.3), 0, Meadow.key(cell.x, cell.y))
	return true

## Take a device out of the field: it has gone off, so it is spent -- a derived cell
## stays empty for the session -- and a replacement is placed elsewhere. False when
## there is nothing armed there, which is what makes it safe to call for a device that
## has already gone off, and what makes a device fired by somebody else cost nothing.
##
## This is the whole of what a process has to do when it hears a key fired: the move
## follows from the cell that fired, so the wire carries the key and nothing about
## where the device went.
func spend(kind: String, cx: int, cz: int) -> bool:
	var key: int = Meadow.key(cx, cz)
	if kind != "trap":
		if not mine_armed(cx, cz):
			return false
		# A replacement that goes off is simply removed; a derived mine leaves its
		# cell spent, which is what keeps that cell empty for the session.
		if not moved.has(key):
			spent[key] = true
		moved.erase(key)
	else:
		if not trap_at(cx, cz):
			return false
		if not trap_moved.has(key):
			trap_spent[key] = true
		trap_moved.erase(key)
	trips += 1
	relocate(kind, cx, cz)
	return true

## Where a device goes when it has gone off: a ring `relocate.min`..`relocate.max`
## around the cell it left, with the radius and the angle both drawn from that cell's
## own key and the try index -- so every process that knows which cell fired computes
## the same destination without being told where.
##
## The ring never reaches inside `blast.radius`: a bang must not set off a mine it has
## just placed, or one blast would chain forever. `tries` draws before the device is
## simply not replaced. A trap has one more condition -- it has to land in a cell the
## meadow grows a tuft in *and* whose grass is currently standing, because a trap
## nobody can see or trip is not a device.
func relocate(kind: String, fcx: int, fcz: int) -> bool:
	var low: float = RELOCATE_MIN if RELOCATE_MIN > BLAST_RADIUS else BLAST_RADIUS
	var fx: float = fcx * 2 + 1
	var fz: float = fcz * 2 + 1
	var is_mine: bool = kind != "trap"
	for tries in RELOCATE_TRIES:
		var d: float = low + (RELOCATE_MAX - low) * trap_noise(fcx, fcz, salt + tries)
		var a: float = TAU * trap_noise(fcz ^ tries, fcx + tries, salt ^ 0x27d4eb2f)
		var cx: int = int(floor((fx + cos(a) * d) / 2.0))
		var cz: int = int(floor((fz + sin(a) * d) / 2.0))
		var x: int = cx * 2 + 1
		var z: int = cz * 2 + 1
		var ax: int = -x if x < 0 else x
		var az: int = -z if z < 0 else z
		var sx: int = (ax - 1) if ax > 1 else 0
		var sz: int = (az - 1) if az > 1 else 0
		if float(sx * sx + sz * sz) < SAFE * SAFE:
			continue
		var key: int = Meadow.key(cx, cz)
		if is_mine:
			# `mine_armed` is false both for a cell that already holds one *and* for a
			# cell whose mine has already gone off, and the second must stay empty for
			# the session -- so the spent set is its own test here.
			if spent.has(key) or mine_armed(cx, cz):
				continue
			moved[key] = true
			return true
		if trap_spent.has(key) or trap_at(cx, cz):
			continue
		if meadow == null or not meadow.has_tuft(cx, cz):
			continue
		trap_moved[key] = true
		return true
	return false

## Put a device on a fuse: it leaves the world from this moment and the bang lands
## when the fuse runs out.
func trip(kind: String, cx: int, cz: int, x: float, z: float, depth: int) -> bool:
	if not spend(kind, cx, cz):
		return false
	# The click between the trigger and the bang (M19g), at the device rather than at the goat: a
	# mine underfoot ticks, and one the goat walks away from ticks behind it.
	if trigger_sound.is_valid():
		trigger_sound.call(kind, x, z)
	pending.append({
		"kind": kind,
		"key": Meadow.key(cx, cz),
		"x": x,
		"z": z,
		"seed": Terrain.value_hash(Meadow.key(cx, cz) * 0.0001),
		"depth": depth,
		"left": FUSE,
	})
	return true

## Walk onto something. Called once per arrival rather than once per frame: the stamp
## is a half-metre bucket with the airborne bit packed beside it, so a goat standing
## still is one compare and a goat that steps over a mine's 0.6 m disc cannot skip it.
##
## Returns the new stamp, because the unit owns it (`goat.trip` in the scene) and this
## has no business holding another node's state.
func check_triggers(x: float, z: float, airborne: bool, stamp: int) -> int:
	var here: int = ((_i32(x * 2.0) + 4096) * 8192 + (_i32(z * 2.0) + 4096)) * 2 \
		+ (1 if airborne else 0)
	if stamp == here:
		return stamp
	if airborne:
		return here
	var cx: int = int(floor(x / 2.0))
	var cz: int = int(floor(z / 2.0))
	var mine: Dictionary = mine_in_cell(x, z, cx, cz)
	if not mine.is_empty():
		trip("mine", int(mine["cx"]), int(mine["cz"]), float(mine["x"]), float(mine["z"]), 0)
	# Walking over a trap is the same test at the tuft's own position. The meadow
	# finds it, and the filter is what keeps this from firing on the grass around it --
	# `trappedOnly` in the scene, which asks `trapAt` for exactly this.
	if meadow != null:
		var tuft: Dictionary = meadow.nearest(
			x, z, MINE_TRIGGER, Callable(self, "trap_at"))
		if not tuft.is_empty():
			trip("trap", int(tuft["cx"]), int(tuft["cz"]), float(tuft["x"]), float(tuft["z"]), 0)
	return here

## Whether the tuft in this cell is trapped, and if it is, set it off.
##
## It is `food.js` `startEat`'s `trapAt` + `tripDevice` pair, in one call, and it is one
## call on purpose: it lets the *goat* ask without linking against the devices, the way
## `Meadow.nearest`'s filter lets the meadow answer without linking against them.
##
## Walking onto a trap is `check_triggers`' job and this is the bite's, and they are not
## the same reach: the trigger is 0.6 m and the eat range is 1.1 m, so a tuft eaten from
## the outside is still a tuft that goes off -- which is the joke the scene tells
## (`food.js`: "the goat did eat a mine").
func trip_trap_at(cx: int, cz: int, x: float, z: float) -> bool:
	if not trap_at(cx, cz):
		return false
	trip("trap", cx, cz, x, z, 0)
	return true

# ---- the bang ---------------------------------------------------------------

## The bangs the frame has to say out loud, and the list is emptied as it is handed over: a handler
## that sets another bang off appends to the *next* frame's, which is what keeps the recursion of
## "a blast makes a blast" bounded by frames rather than by the stack.
func take_blast_events() -> Array:
	var out: Array = blast_events
	blast_events = []
	return out

## A bang. The hole it digs is the *ground*, so every process that applies a blast
## digs one; the goat takes the damage and the throw on the scene's own curve, under the
## `healthFloor` promise that a mine cannot end *this* player's run; the herd takes the
## same curve *without* that floor, which is what makes a minefield a thing the herd
## remembers; and the light, the effects and the knock are this process's alone.
##
## `key` is the device that made it, and only a bang a *device* made has one (M19e): a chained
## bang is another device going off and reports itself when its own fuse ends, while a staged
## bang (`GOATS_BOOM`), the `blast` a remote device arrives through and a bang a mod asked for
## pass none and are never handed back out. `-1` is "no key", which no packed cell key can be.
func blast(kind: String, x: float, z: float, seed: float, depth: int, key: int = -1) -> void:
	blasts += 1
	Craters.add(x, z, seed)
	var dx: float = 0.0
	var dz: float = 0.0
	if goat != null:
		dx = goat.px - x
		dz = goat.pz - z
	var d2: float = dx * dx + dz * dz
	var took: float = 0.0
	var touched: int = 0
	var killed: int = 0
	if goat != null and d2 <= BLAST_RADIUS * BLAST_RADIUS:
		var d: float = sqrt(d2)
		var falloff: float = 1.0 - d / BLAST_RADIUS
		took = BLAST_DAMAGE * falloff * falloff
		# The floor is the promise that a mine cannot end *this* player's run.
		goat.health = maxf(BLAST_HEALTH_FLOOR, goat.health - took)
		# ...and the HUD's flash, scaled by what the blast actually took (`explosions.js`).
		if took > 0.0:
			hurt_by(took)
		# Away from the blast, up, and scaled by the same falloff as the damage: the
		# rim is a shove and the centre is a launch.
		var u: Vector2 = fling_direction(dx, dz, d, seed)
		goat.start_fling(u.x * BLAST_PUSH * falloff, u.y * BLAST_PUSH * falloff,
			BLAST_LIFT * falloff)
	# The herd takes it too, on the player's own curve and off the player's own radius --
	# but *not* the player's floor. Three bangs on the centre kill a bot and one at the rim
	# is a bruise, which is the whole of why `botDie` exists. A lethal bang kills *instead
	# of* throwing, and a bot killed in the air keeps the arc it already had, so a chain on
	# a flung bot drops a corpse rather than teleporting one to the ground.
	if bots != null:
		for index in bots.count():
			var state: Dictionary = bots.state(index)
			if String(state["mode"]) == "dead":
				continue                      # a corpse takes no second bang
			var bx: float = float(state["x"]) - x
			var bz: float = float(state["z"]) - z
			var bd2: float = bx * bx + bz * bz
			if bd2 > BLAST_RADIUS * BLAST_RADIUS:
				continue
			var bd: float = sqrt(bd2)
			var bfalloff: float = 1.0 - bd / BLAST_RADIUS
			var bu: Vector2 = fling_direction(bx, bz, bd, seed)
			# `blast_at` answers `false` when the bot *died* -- it kills instead of throwing -- so
			# the two counts the event carries come from one call each rather than a second walk.
			if not bots.blast_at(index, BLAST_DAMAGE * bfalloff * bfalloff,
					BLAST_PUSH * bfalloff, BLAST_LIFT * bfalloff, bu):
				killed += 1
			touched += 1
	spawn_burst(x, z, seed)
	flash_at(x, z)
	knock(x, z)
	# Heard wherever the goat is, in or out of the radius (`audio.js` `playBlast`). Last of the
	# things a bang *is*, and before the chain, so the bang the player hears is the one they set
	# off rather than the neighbour it woke.
	if bang_sound.is_valid():
		bang_sound.call(x, z, depth)
	# ...and recorded for the `blast` event, before the chain: the reference emits here, so a handler
	# sees the bang it was told about and the chained ones arrive as their own events rather than as
	# one object that changed shape. The nine fields are the reference's own, and `player` is what the
	# goat lost rather than what the bang was worth -- a goat at the rim takes a bruise. The frame
	# says it (see `blast_events`); this only writes it down.
	blast_events.append({
		"kind": kind, "x": x, "z": z, "seed": seed,
		"radius": BLAST_RADIUS, "depth": depth,
		"player": took, "bots": touched, "killed": killed,
	})
	if depth < CHAIN_DEPTH:
		chain_from(x, z, depth + 1)
	# And told to the others, by the process that fired it -- the reporter does not wait for the
	# host to fire it back (`explosions.js` `netBlastFired`). A staged or remote bang has no key
	# and nothing to report.
	if key >= 0 and net_fired.is_valid():
		net_fired.call(kind, key, x, z)

## The devices a bang sets off in turn, along the same chain rule the scene uses:
## `chain` seconds before a neighbour goes, and `chainDepth` bounds the cascade so a
## minefield is a bang and not a wall of them.
func chain_from(x: float, z: float, depth: int) -> void:
	var cx0: int = int(floor((x - BLAST_RADIUS) / 2.0))
	var cx1: int = int(floor((x + BLAST_RADIUS) / 2.0))
	var cz0: int = int(floor((z - BLAST_RADIUS) / 2.0))
	var cz1: int = int(floor((z + BLAST_RADIUS) / 2.0))
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			if not mine_armed(cx, cz):
				continue
			var mx: float = cx * 2 + 1
			var mz: float = cz * 2 + 1
			var dx: float = mx - x
			var dz: float = mz - z
			if dx * dx + dz * dz > BLAST_RADIUS * BLAST_RADIUS:
				continue
			if spend("mine", cx, cz):
				pending.append({
					"kind": "mine",
					"key": Meadow.key(cx, cz),
					"x": mx,
					"z": mz,
					"seed": Terrain.value_hash(Meadow.key(cx, cz) * 0.0001),
					"depth": depth,
					"left": CHAIN_DELAY,
				})

## `explosions.js` `flingDirection`: away from the blast, with a little off-axis
## jitter, or a drawn direction when the goat is at the blast's own centre (where
## "away" is not defined).
func fling_direction(ox: float, oz: float, d: float, seed: float) -> Vector2:
	var ux: float = 0.0
	var uz: float = 0.0
	if d > 1e-3:
		ux = ox / d
		uz = oz / d
	else:
		var a: float = Terrain.value_hash(seed * 9.7) * TAU
		ux = cos(a)
		uz = sin(a)
	var turn: float = (Terrain.value_hash(seed * 3.7 + 1.3) - 0.5) * 0.6
	var c: float = cos(turn)
	var s: float = sin(turn)
	return Vector2(ux * c - uz * s, ux * s + uz * c)

## A hit of `damage` as a share of a full-strength flash, keeping the strongest unrecovered one
## (`explosions.js` `hurtBy`). The HUD reads it back and draws the red frame.
func hurt_by(damage: float) -> void:
	var share: float = damage / PULSE_DAMAGE if PULSE_DAMAGE > 0.0 else 0.0
	if share > hurt_pulse:
		hurt_pulse = minf(share, 1.0)

## How strong the flash still is, for the HUD. Zero when nothing has landed recently.
func hurt() -> float:
	return hurt_pulse

## The knock, which is the part the player does: the camera is pushed away from the
## bang and the push decays. It is outside the damage radius on purpose -- a bang
## just past the goat's feet is a shove with no bruise -- which is why this is called
## for every bang and the damage only for one the goat was inside.
##
## The scene also flashes a red frame for `pulse.damage`-worth of damage; that is not
## drawn, because the HUD is one `Label` until stage 6.
func knock(x: float, z: float) -> void:
	if goat == null:
		return
	var dx: float = goat.px - x
	var dz: float = goat.pz - z
	var d2: float = dx * dx + dz * dz
	var r2: float = SHAKE_RANGE * SHAKE_RANGE
	var d: float = sqrt(d2)
	if d > 0.01:
		shake_dir = Vector2(dx / d, dz / d)
	var falloff: float = maxf(0.0, 1.0 - d2 / r2)
	shake_energy = maxf(shake_energy, SHAKE_ENERGY * falloff * falloff)

# ---- the wire ---------------------------------------------------------------

## The devices the host has seen go off: world state, beside the meadow, so a joiner
## sees the field as it stands. `null` keeps the field we have -- the meadow's own
## contract -- and spending is idempotent, so a device this process fired itself is
## already spent and costs nothing here.
func apply_spent(entries: Variant) -> void:
	if not (entries is Array):
		return
	for entry: Variant in entries:
		if not (entry is Dictionary):
			continue
		var cell: Vector2i = Meadow.cell_of(int(entry.get("key", 0)))
		var kind: String = "trap" if bool(entry.get("trap", false)) else "mine"
		if kind == "trap":
			if trap_at(cell.x, cell.y):
				spend("trap", cell.x, cell.y)
		elif mine_armed(cell.x, cell.y):
			spend("mine", cell.x, cell.y)

## A bang somebody else's process fired (M19e): ours to see and ours to feel, but not ours to
## fire again. The device leaves the field from the key alone, and the bang is the same `blast`
## with the same seed -- it is derived from the key, so a chained crater is the same size here as
## there. The chain stops at this depth: the devices a chain sets off are the origin's to report,
## and each of them fires exactly once (`explosions.js` `applyRemoteBlast`).
##
## The key is spent first, so a device that arrives twice -- a repeated relay, or one this
## process already fired itself -- costs nothing the second time (`spend` is idempotent).
func apply_remote_blast(kind: String, key: int, x: float, z: float) -> void:
	var cell: Vector2i = Meadow.cell_of(key)
	spend(kind, cell.x, cell.y)
	blast(kind, x, z, Terrain.value_hash(key * 0.0001), CHAIN_DEPTH)

## A client's device went off (M19e), on the host: spend the device -- the neighbours must not
## trip it -- and apply the bang here, because the ground is everyone's and this host's own next
## crater list is the state every client adopts (`sceneBlastReport`).
##
## The return is the *answer*, not an input: where the device actually was, from this scene's own
## layout. Empty when the cell holds no device here -- a key that is not a device in this field --
## and then nothing is relayed. The console seam turns an answer into the relay (`main.gd`).
func scene_blast_report(kind: String, key: int) -> Dictionary:
	var cell: Vector2i = Meadow.cell_of(key)
	var at: Dictionary = device_at(kind, cell.x, cell.y)
	if at.is_empty():
		return {}
	apply_remote_blast(kind, key, float(at["x"]), float(at["z"]))
	return {"x": float(at["x"]), "z": float(at["z"])}

# ---- the look ---------------------------------------------------------------

## A pool of bursts, a multi-mesh of debris and one light: nothing allocates on a
## bang. The pool is `maxActive` because the scene's is -- each instance is a draw
## call -- and a burst past it is simply not shown.
func _build_fx() -> void:
	var puff: Texture2D = _puff_texture()
	for i in MAX_ACTIVE:
		var fire := Sprite3D.new()
		fire.texture = puff
		fire.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		fire.material_override = _fx_material(BaseMaterial3D.BLEND_MODE_ADD, puff)
		fire.visible = false
		add_child(fire)
		var smoke := Sprite3D.new()
		smoke.texture = puff
		smoke.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		smoke.material_override = _fx_material(BaseMaterial3D.BLEND_MODE_MIX, puff)
		smoke.visible = false
		add_child(smoke)
		_fire.append(fire)
		_smoke.append(smoke)
		_burst.append({"live": false, "x": 0.0, "z": 0.0, "y": 0.0, "t": 0.0,
			"seed": 0.0})
	_debris = MultiMeshInstance3D.new()
	var debris_mesh := MultiMesh.new()
	debris_mesh.transform_format = MultiMesh.TRANSFORM_3D
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var grit := StandardMaterial3D.new()
	grit.albedo_color = Color(0.24, 0.20, 0.16)
	grit.roughness = 1.0
	grit.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	box.material = grit
	debris_mesh.mesh = box
	debris_mesh.instance_count = MAX_ACTIVE * DEBRIS_COUNT
	_debris.multimesh = debris_mesh
	_debris.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_debris)

func _build_light() -> void:
	_light = OmniLight3D.new()
	_light.omni_range = BLAST_RADIUS * 3.0
	_light.light_color = Color(1.0, 0.82, 0.55)
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)

## The blast's own light, at the fireball: `flash.time` from full to nothing, squared
## off, `flash.lift` above the ground the bang came from. The lit shader's `blast*`
## uniforms are the scene's; this is a Godot light, so the *scale* is the port's and
## the timing is the scene's.
func flash_at(x: float, z: float) -> void:
	_flash_left = FLASH_TIME
	_flash_energy = FLASH_ENERGY
	if _light != null:
		_light.position = Vector3(x, Terrain.height_at(x, z) + FLASH_LIFT, z)
		_light.light_energy = _flash_energy * 3.0
		_light.visible = true

## Start a fireball and a smoke column at a bang: the tuning's times, scales and
## lifts, with the sprite's own ramp (white-hot to orange for the fire, grey and
## growing for the smoke). The pool is the limit rather than `maxActive`, so a bang
## draws nothing at all on an `Explosions` that was never added to the tree -- which
## is how the gates use it.
func spawn_burst(x: float, z: float, seed: float) -> void:
	if _live >= _burst.size():
		return
	var spot: int = _live
	_live += 1
	var burst: Dictionary = _burst[spot]
	burst["live"] = true
	burst["x"] = x
	burst["z"] = z
	burst["y"] = Terrain.height_at(x, z)
	burst["t"] = 0.0
	burst["seed"] = seed
	(_fire[spot] as Sprite3D).visible = true
	(_smoke[spot] as Sprite3D).visible = true

func _update_bursts(delta: float) -> void:
	var instances: int = 0
	for i in _burst.size():
		var burst: Dictionary = _burst[i]
		var fire := _fire[i] as Sprite3D
		var smoke := _smoke[i] as Sprite3D
		if not bool(burst["live"]):
			continue
		burst["t"] = float(burst["t"]) + delta
		var t: float = float(burst["t"])
		if t >= FX_SMOKE_TIME:
			burst["live"] = false
			fire.visible = false
			smoke.visible = false
			continue
		var x: float = float(burst["x"])
		var z: float = float(burst["z"])
		var y: float = float(burst["y"])
		# The fireball: a fast grow and a hard fade, lifting as it goes.
		var fire_t: float = minf(t / FX_BLAST_TIME, 1.0)
		fire.position = Vector3(x, y + FX_BLAST_LIFT * fire_t + 0.5, z)
		var fire_size: float = FX_BLAST_SCALE * (0.45 + 0.55 * fire_t)
		fire.pixel_size = fire_size / maxf(fire.texture.get_width(), 1.0)
		fire.modulate = Color(1.0, 0.72 + 0.28 * (1.0 - fire_t), 0.42 + 0.5 * (1.0 - fire_t),
			pow(1.0 - fire_t, 1.6))
		# The column: slower, longer, and still there when the fire is gone.
		var smoke_t: float = minf(t / FX_SMOKE_TIME, 1.0)
		smoke.position = Vector3(x, y + FX_SMOKE_LIFT * smoke_t + 0.6, z)
		var smoke_size: float = FX_SMOKE_SCALE * (0.5 + 0.5 * smoke_t)
		smoke.pixel_size = smoke_size / maxf(smoke.texture.get_width(), 1.0)
		smoke.modulate = Color(0.62, 0.60, 0.58, pow(1.0 - smoke_t, 1.3) * 0.8)
		# The grit, on the scene's own ballistics.
		var debris: MultiMesh = _debris.multimesh
		for body in DEBRIS_COUNT:
			var jitter: float = Terrain.value_hash(float(burst["seed"]) * 7.3 + float(body))
			var angle: float = TAU * jitter
			var speed: float = DEBRIS_SPEED * (0.45 + 0.55 * jitter)
			var px: float = x + cos(angle) * speed * t
			var pz: float = z + sin(angle) * speed * t
			var py: float = y + DEBRIS_UP * t - 0.5 * DEBRIS_GRAVITY * t * t
			if instances < debris.instance_count:
				debris.set_instance_transform(instances, Transform3D(
					Basis.from_scale(Vector3.ONE * DEBRIS_SIZE),
					Vector3(px, maxf(py, Terrain.height_at(px, pz)), pz)))
				instances += 1
	if _debris != null:
		_debris.multimesh.visible_instance_count = instances

## A puff: the scene generates its fire and smoke atlases from noise at boot, so this
## is the same idea in one texture -- a radial falloff mottled by value noise -- used
## for both kinds and told apart by the tint and the ramp. A mod that replaces the art
## is a later stage (the asset table does not reach here yet).
func _puff_texture() -> ImageTexture:
	var size := 64
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u: float = (float(x) + 0.5) / float(size) - 0.5
			var v: float = (float(y) + 0.5) / float(size) - 0.5
			var d: float = sqrt(u * u + v * v) / 0.5
			var alpha: float = 0.0
			if d < 1.0:
				var mottle: float = 0.55 * Terrain.vnoise2(float(x) * 0.18, float(y) * 0.18) \
					+ 0.30 * Terrain.vnoise2(float(x) * 0.36 + 11.0, float(y) * 0.36 + 7.0) \
					+ 0.15 * Terrain.vnoise2(float(x) * 0.72 + 3.0, float(y) * 0.72 + 19.0)
				alpha = clampf((1.0 - d) * 1.6 - 0.25, 0.0, 1.0) * (0.45 + 0.75 * mottle)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0)))
	return ImageTexture.create_from_image(image)

## The sprite's material. `albedo_texture` is set here and not left to the sprite's
## own: a `material_override` *replaces* the material Godot builds from `texture`, so
## an override without it samples nothing — which is a solid white quad, and it is
## what the first version of this file drew. (An unshaded Godot material with no
## albedo texture is white with an alpha of one.)
func _fx_material(mode: BaseMaterial3D.BlendMode, texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = mode
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	return material

## `| 0`: wrap to int32.
static func _i32(value: int) -> int:
	var low: int = value & 0xFFFFFFFF
	if low >= 0x80000000:
		return low - 0x100000000
	return low

## `Math.imul`: the low 32 bits of a product, as a signed int32.
static func _imul(a: int, b: int) -> int:
	return _i32(a * b)

## `>>>`: a right shift of the value read as unsigned.
static func _ushr(value: int, bits: int) -> int:
	return (value & 0xFFFFFFFF) >> bits

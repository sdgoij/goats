# The devices gate: `explosions.gd` and `craters.gd` against `explosions.js`.
#
#   Godot --headless --path godot --script res://tools/verify_devices.gd
#
# The minefield is the port's sharpest determinism question, sharper than the
# heightfield: the devices are **derived** from the session seed and *nothing about
# where they are travels at boot*. A peer that computes a different field has mines
# where this one has grass, and the first either finds out is a bang the other cannot
# explain. So the gate checks the derivation itself:
#
#   * the cell hashes, as **bits** -- the one part of this that can be compared
#     exactly, because it is integer arithmetic with no `sin` in it;
#   * `mineAt`/`trapAt` over a range of cells and two salts, which is the field;
#   * `relocateDevice`'s destination for a cell that fired, which is the *move* -- the
#     other half of "the wire carries the key and nothing about where the device
#     went";
#   * `craterDipAt` at a ring of points around three craters, which is the shape of
#     the ground everything stands on.
#
# The oracle is the scene's JavaScript, run by the embedded engine, exactly as every
# other gate here does it.
extends SceneTree

## `explosions.js` / `weather.js` / `food.js`, transcribed *from their sources*: the
## device derivation, the relocation ring and the crater dish. `trapSalt` is injected
## rather than defaulted, so both sides are asked about the *same* session.
const JS := """
const TUNING = {
    explosions: {
        safe: 8, fuse: 0.18,
        mine: { density: 0.012, trigger: 0.6 },
        trap: { chance: 0.04 },
        relocate: { min: 8, max: 24, tries: 12 },
        blast: { radius: 3.2 },
        crater: { radius: 1.6, depth: 0.45, lip: 0.12, heal: 240, max: 24 },
    },
};
const CRATER_LIP_OUT = 1.45;
function hash(n) { const s = Math.sin(n * 127.1) * 43758.5453; return s - Math.floor(s); }
function tuftKey(cx, cz) { return (cx + 4096) * 8192 + (cz + 4096); }
function tuftCell(key) { return { cx: Math.floor(key / 8192) - 4096, cz: key % 8192 - 4096 }; }
function trapNoiseBits(cx, cz, salt) {
    let h = (cx * 374761393 + cz * 668265263 + salt) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return (h ^ (h >>> 16)) >>> 0;
}
function trapNoise(cx, cz, salt) { return trapNoiseBits(cx, cz, salt) / 4294967296; }
function mineAt(cx, cz, salt) {
    const x = cx * 2 + 1;
    const z = cz * 2 + 1;
    const ax = x < 0 ? -x : x;
    const az = z < 0 ? -z : z;
    const dx = ax > 1 ? ax - 1 : 0;
    const dz = az > 1 ? az - 1 : 0;
    const safe = TUNING.explosions.safe;
    if (dx * dx + dz * dz < safe * safe) return false;
    return trapNoise(cx, cz, salt) < TUNING.explosions.mine.density;
}
function trapAt(cx, cz, salt) {
    return trapNoise(cx ^ 0x5bf03635, cz ^ 0x27d4eb2f, salt) < TUNING.explosions.trap.chance;
}
// The meadow's own cell hash, for the trap's relocation condition.
function tuftInCell(cx, cz) {
    let h = (cx * 374761393 + cz * 668265263) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    h = (h ^ (h >>> 16)) >>> 0;
    const a = h / 4294967296;
    if (a < 0.45) return null;
    return { cx: cx, cz: cz };
}
const SPENT = new Set(__SPENT__);
const MOVED = new Set(__MOVED__);
const TRAP_SPENT = new Set();
const TRAP_MOVED = new Set();
function mineArmed(cx, cz, salt) {
    const key = tuftKey(cx, cz);
    if (SPENT.has(key)) return false;
    return MOVED.has(key) || mineAt(cx, cz, salt);
}
// `relocateDevice`, verbatim. It answers true or false -- *where* the device went is
// only observable through the set it wrote to -- so the caller below reads it back
// out, which is the same way a peer knows.
function relocateDevice(kind, fcx, fcz, salt) {
    const e = TUNING.explosions;
    const r = e.relocate;
    const lo = r.min > e.blast.radius ? r.min : e.blast.radius;
    const fx = fcx * 2 + 1;
    const fz = fcz * 2 + 1;
    const mine = kind !== "trap";
    for (let tries = 0; tries < r.tries; tries++) {
        const d = lo + (r.max - lo) * trapNoise(fcx, fcz, salt + tries);
        const a = 6.283185307179586 * trapNoise(fcz ^ tries, fcx + tries, salt ^ 0x27d4eb2f);
        const cx = Math.floor((fx + Math.cos(a) * d) / 2);
        const cz = Math.floor((fz + Math.sin(a) * d) / 2);
        const x = cx * 2 + 1;
        const z = cz * 2 + 1;
        const ax = x < 0 ? -x : x;
        const az = z < 0 ? -z : z;
        const sx = ax > 1 ? ax - 1 : 0;
        const sz = az > 1 ? az - 1 : 0;
        if (sx * sx + sz * sz < e.safe * e.safe) continue;
        const key = tuftKey(cx, cz);
        if (mine) {
            if (SPENT.has(key) || mineArmed(cx, cz, salt)) continue;
            MOVED.add(key);
            return true;
        }
        if (TRAP_SPENT.has(key) || trapAt(cx, cz, salt)) continue;
        if (tuftInCell(cx, cz) === null) continue;
        TRAP_MOVED.add(key);
        return true;
    }
    return false;
}
// Where it landed: the one key the call added.
function relocatedTo(set, before) {
    for (const key of set) if (!before.has(key)) return tuftCell(key);
    return { cx: -99999, cz: -99999 };
}
// `craterDipAt`'s arithmetic for one crater, which is what a point query resolves to.
function craterDip(craters, x, z) {
    let dip = 0;
    for (const c of craters) {
        const dx = x - c.x;
        const dz = z - c.z;
        const d2 = dx * dx + dz * dz;
        if (d2 > c.reach2) continue;
        const t = Math.sqrt(d2) / c.r;
        if (t < 1) {
            const s = 1 - t;
            dip -= c.dip * s * s * (3 - 2 * s);
        } else {
            let s = (t - 1) / (CRATER_LIP_OUT - 1);
            if (s > 1) continue;
            s = 1 - s;
            dip += c.lip * s * s * (3 - 2 * s);
        }
    }
    return dip;
}

const SALTS = __SALTS__;
// 1. The hashes, as bits.
for (const salt of SALTS) {
    for (let cx = -4; cx <= 4; cx++) {
        for (let cz = -4; cz <= 4; cz++) {
            console.log('H ' + salt + ' ' + cx + ' ' + cz + ' ' + trapNoiseBits(cx, cz, salt));
        }
    }
}
// 2. The field: a wider sweep, as booleans.
let mines = 0, traps = 0;
for (const salt of SALTS) {
    for (let cx = -25; cx <= 25; cx++) {
        for (let cz = -25; cz <= 25; cz++) {
            const m = mineAt(cx, cz, salt) ? 1 : 0;
            const t = trapAt(cx, cz, salt) ? 1 : 0;
            mines += m; traps += t;
            console.log('F ' + salt + ' ' + cx + ' ' + cz + ' ' + m + ' ' + t);
        }
    }
}
console.log('counts ' + mines + ' ' + traps);
// 3. The move, for cells that fired. A fixed shape, so a missing destination is a
// number rather than a missing token.
const FIRED = __FIRED__;
for (const salt of SALTS) {
    for (const cell of FIRED) {
        let before = new Set(MOVED);
        relocateDevice("mine", cell[0], cell[1], salt);
        const mine = relocatedTo(MOVED, before);
        before = new Set(TRAP_MOVED);
        relocateDevice("trap", cell[0], cell[1], salt);
        const trap = relocatedTo(TRAP_MOVED, before);
        console.log('R ' + salt + ' ' + cell[0] + ' ' + cell[1] + ' ' +
            mine.cx + ' ' + mine.cz + ' ' + trap.cx + ' ' + trap.cz);
    }
}
// 4. The dish. The craters are the gate's own, built from the same triples the port
// is given, so the radius comes off `hash(seed)` on both sides.
const CRATERS = __CRATERS__;
const built = CRATERS.map(function (s) {
    const r = TUNING.explosions.crater.radius * (0.85 + hash(s[2]) * 0.3);
    const reach = r * CRATER_LIP_OUT;
    return { x: s[0], z: s[1], r: r, reach2: reach * reach,
             dip: TUNING.explosions.crater.depth, lip: TUNING.explosions.crater.lip };
});
for (const s of CRATERS) {
    for (let i = -20; i <= 20; i++) {
        for (let j = -20; j <= 20; j++) {
            const x = s[0] + i * 0.2;
            const z = s[1] + j * 0.2;
            console.log('D ' + x + ' ' + z + ' ' + craterDip(built, x, z));
        }
    }
}
"""

## The salts both sides are asked about. The default is `weather.js`'s; the second is
## what a session seed would derive to, since the whole point of the salt is that two
## sessions have their mines in different places.
const SALTS := [0x2f6e2b1d, 0x1a2b3c4d]
## Cells the gate asks to move a device out of. The origin is inside the safe disc, so
## it exercises the `continue` that refuses it; the rest are ordinary field.
const FIRED := [[0, 0], [1, 0], [12, -7], [-20, 33], [7, 7]]
## Cells pre-marked as already gone and as replacements, so the relocation's retry
## path is taken rather than always answering with its first candidate.
const SPENT := [[2, 0], [3, 0], [4, 1]]
const MOVED := [[12, -7]]
## Craters to build on both sides: `(x, z, seed)`.
const CRATERS := [[3.5, -2.0, 0.417], [-11.25, 8.5, 0.902], [0.0, 0.0, 0.103]]

## The dish is plain arithmetic over the crate positions, which are the gate's own
## numbers, so it should agree to the last bit -- the tolerance is for the `sqrt` and
## the two engines' libm, which are not the same libm.
const TOLERANCE := 1e-12

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var source: String = JS \
		.replace("__SALTS__", JSON.stringify(SALTS)) \
		.replace("__FIRED__", JSON.stringify(FIRED)) \
		.replace("__SPENT__", JSON.stringify(_keys(SPENT))) \
		.replace("__MOVED__", JSON.stringify(_keys(MOVED))) \
		.replace("__CRATERS__", JSON.stringify(CRATERS))
	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var hashes := {}
	var field := {}
	var moves := {}
	## Doubles, not a `Vector2`: every Godot vector type is float32, and keying a
	## query by a narrowed position is the trap `PORT.md` section 9 is about -- asking
	## the port about a *rounded* point is asking a different question.
	var dish: Array = []
	var counts := Vector2i.ZERO
	for line in answers:
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log H ") and parts.size() == 6:
			hashes[Vector3i(int(parts[2]), int(parts[3]), int(parts[4]))] = int(parts[5])
		elif line.begins_with("log F ") and parts.size() == 7:
			field[Vector3i(int(parts[2]), int(parts[3]), int(parts[4]))] = Vector2i(
				int(parts[5]), int(parts[6]))
		elif line.begins_with("log R ") and parts.size() == 9:
			moves[Vector3i(int(parts[2]), int(parts[3]), int(parts[4]))] = [
				Vector2i(int(parts[5]), int(parts[6])),
				Vector2i(int(parts[7]), int(parts[8]))]
		elif line.begins_with("log D ") and parts.size() == 5:
			dish.append([float(parts[2]), float(parts[3]), float(parts[4])])
		elif line.begins_with("log counts ") and parts.size() == 4:
			counts = Vector2i(int(parts[2]), int(parts[3]))

	print("oracle answered ", hashes.size(), " hash(es), ", field.size(), " cell(s), ",
		moves.size(), " move(s), ", dish.size(), " dip(s)")

	# 1. The hashes, bit for bit. The key is `(salt, cx, cz)` -- the order the line was
	# emitted in -- so the call reads `(cx, cz, salt)`.
	var devices := Explosions.new()
	devices.meadow = Meadow.new()
	var hash_mismatches := 0
	var first_hash := ""
	for key: Vector3i in hashes:
		var got: int = _bits(devices.trap_noise(key.y, key.z, key.x))
		if got != hashes[key]:
			hash_mismatches += 1
			if first_hash == "":
				first_hash = "salt %d cell (%d, %d): js %d, gd %d" % [
					key.x, key.y, key.z, hashes[key], got]

	# 2. The field: the minefield itself.
	var mine_mismatches := 0
	var trap_mismatches := 0
	var first_field := ""
	var port_mines := 0
	var port_traps := 0
	for key: Vector3i in field:
		devices.salt = key.x
		var want: Vector2i = field[key]
		var mine: bool = devices.mine_at(key.y, key.z)
		var trap: bool = devices.trap_at(key.y, key.z)
		if mine:
			port_mines += 1
		if trap:
			port_traps += 1
		if (1 if mine else 0) != want.x:
			mine_mismatches += 1
			if first_field == "":
				first_field = "salt %d cell (%d, %d): js %d, gd %d" % [
					key.x, key.y, key.z, want.x, 1 if mine else 0]
		if (1 if trap else 0) != want.y:
			trap_mismatches += 1
			if first_field == "":
				first_field = "salt %d cell (%d, %d): js trap %d, gd %d" % [
					key.x, key.y, key.z, want.y, 1 if trap else 0]

	# 3. The move.
	var move_mismatches := 0
	var first_move := ""
	for key: Vector3i in moves:
		devices.salt = key.x
		# The same pre-spent and pre-moved cells the oracle was built with.
		devices.spent = {}
		devices.moved = {}
		devices.trap_moved = {}
		for cell: Array in SPENT:
			devices.spent[Meadow.key(int(cell[0]), int(cell[1]))] = true
		for cell: Array in MOVED:
			devices.moved[Meadow.key(int(cell[0]), int(cell[1]))] = true
		var before: Dictionary = devices.moved.duplicate()
		devices.relocate("mine", key.y, key.z)
		var mine_got: Vector2i = _landed(devices.moved, before)
		before = devices.trap_moved.duplicate()
		devices.relocate("trap", key.y, key.z)
		var trap_got: Vector2i = _landed(devices.trap_moved, before)
		var want: Array = moves[key]
		if mine_got != want[0] or trap_got != want[1]:
			move_mismatches += 1
			if first_move == "":
				first_move = "salt %d from (%d, %d): js %s/%s, gd %s/%s" % [
					key.x, key.y, key.z, want[0], want[1], mine_got, trap_got]

	# 4. The dish.
	Craters.clear()
	for crater: Array in CRATERS:
		Craters.add(crater[0], crater[1], crater[2])
	var worst_dip := 0.0
	var worst_at := ""
	for spot: Array in dish:
		var want: float = spot[2]
		var got: float = Craters.dip_at(spot[0], spot[1])
		var difference: float = absf(got - want)
		if difference > worst_dip:
			worst_dip = difference
			worst_at = "(%.2f, %.2f): js %.17f, gd %.17f" % [spot[0], spot[1], want, got]

	print("hash mismatches: ", hash_mismatches)
	if first_hash != "":
		print("  first: ", first_hash)
	print("the field: port %d mine(s), %d trap(s); scene %d mine(s), %d trap(s)"
		% [port_mines, port_traps, counts.x, counts.y])
	print("field mismatches: ", mine_mismatches, " mine, ", trap_mismatches, " trap")
	if first_field != "":
		print("  first: ", first_field)
	print("relocation mismatches: ", move_mismatches)
	if first_move != "":
		print("  first: ", first_move)
	print("crater dip disagreement: %.12f (tolerance %.12f)" % [worst_dip, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)

	# 5. Behaviour no oracle can see: spending is idempotent and a replacement is
	#    somewhere else, which is the half that keeps the field drifting rather than
	#    thinning out.
	var book := Explosions.new()
	book.meadow = Meadow.new()
	book.salt = SALTS[0]
	var first_mine := _first_mine(book, 30)
	var book_ok := true
	var moved_to := ""
	if first_mine == Vector2i(-99999, -99999):
		book_ok = false
	else:
		if not book.mine_armed(first_mine.x, first_mine.y):
			book_ok = false
		if not book.spend("mine", first_mine.x, first_mine.y):
			book_ok = false
		if book.mine_armed(first_mine.x, first_mine.y):
			book_ok = false          # gone for the session
		if book.spend("mine", first_mine.x, first_mine.y):
			book_ok = false          # ...and cannot be spent twice
		if book.spent.is_empty():
			book_ok = false          # a derived mine leaves its cell spent
		var where: Vector2i = Meadow.cell_of(int(book.moved.keys()[0]))
		moved_to = str(where)
		if book.moved.is_empty():
			book_ok = false          # a replacement moved somewhere
		elif where == first_mine:
			book_ok = false          # ...and not onto the cell it left
	print("book-keeping: %s (a mine at %s went, and a replacement is at %s)"
		% ["ok" if book_ok else "WRONG", str(first_mine), moved_to])

	# 6. The bang, end to end: a goat stands on a mine and the whole system runs --
	#    the trigger, the fuse, the hole, the damage, the throw and the replacement.
	#    Everything above this checks a piece against the scene's own arithmetic; this
	#    is the only thing here that says the pieces are wired to each other.
	Craters.clear()
	var goat := PlayerGoat.new()
	root.add_child(goat)
	goat.ready_up()
	var world := Explosions.new()
	world.meadow = Meadow.new()
	world.goat = goat
	world.salt = SALTS[0]
	var target := _first_mine(world, 30)
	var bang_ok := true
	var notes: Array[String] = []
	if target == Vector2i(-99999, -99999):
		bang_ok = false
		notes.append("there is no mine in the field to stand on")
	else:
		var mx: float = target.x * 2 + 1
		var mz: float = target.y * 2 + 1
		goat.px = mx
		goat.pz = mz
		goat.trip_stamp = world.check_triggers(mx, mz, false, goat.trip_stamp)
		if world.pending.is_empty():
			bang_ok = false
			notes.append("standing on an armed mine did not light a fuse")
		# The bang lands when the fuse runs out (0.18 s); the rest of the time is the
		# goat's arc, which is the goat's own frame.
		for i in 40:
			world.update(0.02)
			goat.step(0.02, {}, 1.0, {}, world.meadow)
		var dip: float = Craters.dip_at(mx, mz)
		notes.append("crater under it: %.3f m, %d live" % [dip, Craters.count()])
		notes.append("health after: %.1f of %d" % [goat.health, PlayerGoat.STATS_MAX])
		notes.append("mode %s, %.2f m above the ground, %.3f m from the blast"
			% [goat.mode, goat.py, absf(goat.px - mx) + absf(goat.pz - mz)])
		if Craters.count() < 1:
			bang_ok = false
			notes.append("a bang dug no hole at all")
		elif Craters.count() > 1 + Explosions.CHAIN_DEPTH:
			# One bang, plus at most one round of neighbours (`chainDepth`). More than
			# that is a cascade the tuning says cannot happen.
			bang_ok = false
			notes.append("a bang cascaded further than `chainDepth` allows")
		# The tuning's own depth, and the goat is at the centre so it takes the full
		# `blast.damage` -- clamped by the floor, which is the promise that a mine
		# cannot end this player's run.
		if not (dip < -0.3 and dip > -0.5):
			bang_ok = false
			notes.append("the crater is not the tuning's depth")
		if not (goat.health < 60.0 and goat.health >= Explosions.BLAST_HEALTH_FLOOR):
			bang_ok = false
			notes.append("the blast did not take the damage it should")
		if goat.mode != "flung" or goat.py <= 0.0:
			bang_ok = false
			notes.append("the blast did not throw the goat")
		if world.spent.is_empty() or world.moved.is_empty():
			bang_ok = false
			notes.append("the device did not leave its cell spent and replace itself")
	print("the bang: ", "ok" if bang_ok else "WRONG")
	for note in notes:
		print("  ", note)

	# 7. The bite, end to end: a trapped tuft eaten from *outside* the walk-in trigger.
	#    The eat range is 1.1 m and the trigger is 0.6 m, so a goat that presses E the
	#    moment a tuft comes into reach would otherwise take a free meal off a device the
	#    scene makes it pay for. `food.js` `startEat` is where that is decided, so this
	#    runs the goat's own bite with the devices' hook -- and it asks the *trigger's own
	#    query* first, so "outside" is the trigger's rule and not this test's arithmetic.
	var bite := Explosions.new()
	bite.meadow = Meadow.new()
	bite.salt = SALTS[0]
	var bitten := PlayerGoat.new()
	root.add_child(bitten)
	bitten.ready_up()
	bite.goat = bitten
	var bitable: Dictionary = _bitable_trap(bite, 30)
	var bite_ok := true
	var bite_notes: Array[String] = []
	if bitable.is_empty():
		bite_ok = false
		bite_notes.append("no trapped tuft stands in reach of a bite outside the trigger")
	else:
		# 1.0 m away in x: inside the 1.1 m eat reach, outside the 0.6 m trigger.
		bitten.px = float(bitable["x"]) + 1.0
		bitten.pz = float(bitable["z"])
		bitten.energy = 50.0
		bitten.satiety = 0.0
		var walk: Dictionary = bite.meadow.nearest(bitten.px, bitten.pz,
			Explosions.MINE_TRIGGER, Callable(bite, "trap_at"))
		if not walk.is_empty():
			bite_ok = false
			bite_notes.append("the walk-in trigger reaches this tuft, so this is no bite test")
		bitten.step(1.0 / 60.0, {"eat": true}, 1.0, {}, bite.meadow,
			Callable(bite, "trip_trap_at"))
		bite_notes.append("after the bite: mode %s, energy %.2f, satiety %.2f"
			% [bitten.mode, bitten.energy, bitten.satiety])
		if bitten.mode != "eat":
			bite_ok = false
			bite_notes.append("the bite did not start")
		if bite.meadow.has_tuft(int(bitable["cx"]), int(bitable["cz"])):
			bite_ok = false
			bite_notes.append("the trapped tuft was not eaten")
		if bite.pending.is_empty():
			bite_ok = false
			bite_notes.append("eating a trapped tuft lit no fuse")
		elif String(bite.pending[0]["kind"]) != "trap":
			bite_ok = false
			bite_notes.append("the bite lit a fuse on something other than the trap")
		# The meal is what a trapped tuft must *not* give: the goat ate a mine.
		if bitten.energy > 50.0 or bitten.satiety > 0.0:
			bite_ok = false
			bite_notes.append("a trapped tuft fed the goat")
		if bite.trap_spent.is_empty():
			bite_ok = false
			bite_notes.append("the trap did not leave its cell spent")
	print("the bite: ", "ok" if bite_ok else "WRONG")
	for note in bite_notes:
		print("  ", note)

	host.free()
	devices.free()
	book.free()
	goat.free()
	bitten.free()
	world.free()
	bite.free()
	Craters.clear()

	if hashes.size() == 0:
		failures.append("the oracle answered no hashes at all")
	if hash_mismatches != 0:
		failures.append("the cell hash differs from the scene's in %d place(s)"
			% hash_mismatches)
	if mine_mismatches != 0 or trap_mismatches != 0:
		failures.append("the field is not the scene's: %d mine(s) and %d trap(s) differ"
			% [mine_mismatches, trap_mismatches])
	if port_mines != counts.x or port_traps != counts.y:
		failures.append("the field has %d mine(s) and %d trap(s); the scene has %d and %d"
			% [port_mines, port_traps, counts.x, counts.y])
	if move_mismatches != 0:
		failures.append("a fired device did not move where the scene says it did (%d)"
			% move_mismatches)
	if worst_dip > TOLERANCE:
		failures.append("the crater dish differs by %f (limit %f)" % [worst_dip, TOLERANCE])
	if not book_ok:
		failures.append("spending a device is not the scene's: it was not idempotent, "
			+ "or nothing was replaced")
	if not bang_ok:
		failures.append("a bang is not the scene's: see the notes above")
	if not bite_ok:
		failures.append("a bite on a trapped tuft is not the scene's: see the notes above")

	if failures.is_empty():
		print("OK: the device field, its moves and its holes are the scene's")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

## The tuple keys each side is seeded with, in the shape the JavaScript wants.
func _keys(cells: Array) -> Array:
	var out: Array = []
	for cell: Array in cells:
		out.append(Meadow.key(int(cell[0]), int(cell[1])))
	return out

## Where a relocation landed: `relocate` answers true or false, the scene's own shape,
## so the destination is read back out of the set it wrote to -- which is how the
## oracle is asked too, and how a peer knows where a device it did not fire went.
func _landed(after: Dictionary, before: Dictionary) -> Vector2i:
	for key: int in after:
		if not before.has(key):
			return Meadow.cell_of(key)
	return Vector2i(-99999, -99999)

## A hash as its uint32 bits, so the comparison has no float in it.
func _bits(value: float) -> int:
	return int(round(value * 4294967296.0))

## The first armed mine along a spiral-free sweep of the field, which is what a
## book-keeping check needs: any mine at all, deterministically chosen.
func _first_mine(field: Explosions, span: int) -> Vector2i:
	for cx in range(-span, span + 1):
		for cz in range(-span, span + 1):
			if field.mine_armed(cx, cz):
				return Vector2i(cx, cz)
	return Vector2i(-99999, -99999)

## A trapped tuft the goat can bite *without* walking into it: the bite test puts the
## goat 1.0 m away in x -- inside the 1.1 m eat range, outside the 0.6 m trigger -- and
## this keeps looking until the nearest tuft from there is that very tuft, because
## otherwise the bite would be a bite on a neighbour and would prove nothing.
func _bitable_trap(field: Explosions, span: int) -> Dictionary:
	for cx in range(-span, span + 1):
		for cz in range(-span, span + 1):
			if not field.meadow.has_tuft(cx, cz) or not field.trap_at(cx, cz):
				continue
			var tuft: Dictionary = field.meadow.tuft_in(cx, cz)
			var target: Dictionary = field.meadow.nearest(
				float(tuft["x"]) + 1.0, float(tuft["z"]))
			if target.is_empty():
				continue
			if int(target["cx"]) == cx and int(target["cz"]) == cz:
				return tuft
	return {}

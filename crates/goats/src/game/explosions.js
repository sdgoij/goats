// Part 16/16 of the goat scene: landmines, boobytraps and the bangs they make.
// ---- explosions ------------------------------------------------------------
//
// Two devices, both *derived* rather than placed: a 2-unit cell either holds a
// mine or does not, and a share of the tufts are trapped, from a hash of the cell
// salted per session (`trapSalt`, weather.js). Nothing is stored and nothing
// travels at boot, so every process that knows the session seed computes the same
// field -- which is also what makes a mine detector a *mod* rather than a core
// feature, and why the layout needs no room on the wire.
//
// The only state is where the devices are: which cells have already gone off and
// which cells a replacement moved into (`SPENT`/`MOVED` and their trap twins), what
// is waiting on a fuse (`PENDING`), the craters the ground is carrying (`CRATERS`) and
// the live effect instances (`FX`). A device
// does not blow up where it was tripped -- the trigger starts a fuse
// (`TUNING.explosions.fuse`), and the bang lands that many seconds later, which gives
// the art a beat to read and the player a beat of "oh no".
//
// What a blast does here is damage, with a falloff and a floor (M19b). The fling
// is M19c, the crater is M19d and the wire is M19e; the effect is the weather's
// cloud puff drawn as a camera-facing billboard, which M19f replaces with Blender
// atlases behind the same pool.

// A device's *location* is the only thing that changes during a session: when one
// goes off it is gone from where it was and a replacement is placed elsewhere by the
// same kind of hash (`relocateDevice`), so the field drifts instead of thinning out.
// Both halves stay derived, which is what keeps the wire honest: a peer that learns
// *which cell fired* computes the same move, so nothing about the move travels (see
// the M19e note in ROADMAP.md).
//
// A key is a cell key, packed exactly as `tuftKey` (food.js) packs one.
const SPENT = new Set();        // mine cells that have gone off: empty ground now
const MOVED = new Set();        // ...and mine cells a replacement was placed in
const TRAP_SPENT = new Set();   // the same two, for trapped tufts
const TRAP_MOVED = new Set();
const PENDING = [];             // { kind, x, z, seed, depth, left }
let tripCount = 0;              // devices taken out of the field, for the tell cache's key

// The effect pool. Fixed capacity, built once: nothing allocates while the game
// runs, and `TUNING.explosions.maxActive` selects how much of it is live, so a
// mod can raise the count without rebuilding the array (the shape `RAIN` uses).
//
// `fxTop` is one past the highest slot in use, and the per-frame passes stop
// there rather than at `FX_CAPACITY`. That is not a micro-optimisation: sweeping
// all 64 slots every frame is 128 reads of `FX[i]` and `slot.live`, and the
// property read is the operation this engine is worst at -- measured in this
// scene, the two sweeps alone cost ~2 ms/frame while sixteen inlined JS calls
// cost nothing. At rest `fxTop` is 0, so the frame does no pool work at all.
const FX_CAPACITY = 64;
const FX = [];
let fxTop = 0;
(function buildFxPool() {
    for (let i = 0; i < FX_CAPACITY; i++) {
        FX.push({ live: false, kind: 0, x: 0, y: 0, z: 0, age: 0, dur: 1, seed: 0, scale: 1 });
    }
})();

// What a bang looks like for now: the weather's own cloud puff (weather.js), the
// soft radial sprite this generator was copied from. Reusing it keeps M19b out of
// the texture list entirely -- one new texture turned out to cost the whole frame
// in the draw path (see the M19b notes in ROADMAP.md) -- and the Blender atlases
// (M19f) replace both users of it behind the same pool.
const FX_PUFF_TIME = 0.9;
const FX_PUFF_LIFT = 1.1;
const FX_PUFF_SCALE = 2.8;

let blastCount = 0;

// A cell's trap value in 0..1: the mixing `nearestTuft` and `drawTufts` inline,
// with the session salt. Deliberately not `hash()`: that one is `Math.sin`-based,
// and a per-cell decision wants the integer mixing every peer reproduces.
function trapNoise(cx, cz, salt) {
    let h = (cx * 374761393 + cz * 668265263 + salt) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

// Whether cell (cx, cz) holds a mine. `safe` clears a disc around the spawn, so
// `restart()` always puts the goat somewhere survivable; nothing else is
// excluded, so mines sit on slopes, in hollows and at the edge of the field the
// same way they sit anywhere else.
//
// The distance is to the cell's nearest edge, not its centre, so the clear disc
// is a guarantee about the ground rather than about cell centres.
function mineAt(cx, cz) {
    const x = cx * 2 + 1;
    const z = cz * 2 + 1;
    // Plain comparisons rather than `Math.abs`/`Math.max`: this is a per-cell
    // path, and a builtin is a call the engine cannot inline either.
    const ax = x < 0 ? -x : x;
    const az = z < 0 ? -z : z;
    const dx = ax > 1 ? ax - 1 : 0;
    const dz = az > 1 ? az - 1 : 0;
    const safe = TUNING.explosions.safe;
    if (dx * dx + dz * dz < safe * safe) return false;
    return trapNoise(cx, cz, trapSalt) < TUNING.explosions.mine.density;
}

// Whether cell (cx, cz) holds an armed mine *now*: the derived field, minus the
// mines that have gone off, plus the replacements that have moved in.
function mineArmed(cx, cz) {
    const key = tuftKey(cx, cz);
    if (SPENT.has(key)) return false;
    return MOVED.has(key) || mineAt(cx, cz);
}

// Whether the tuft in cell (cx, cz) is trapped now, on the same rule. A tuft exists
// only where the meadow's own hash says so, so this is only ever asked about a tuft
// that is there -- `nearestTuft` is what finds those, and it is also what carries the
// `trappedOnly` filter this is used through.
function trapAt(cx, cz) {
    const key = tuftKey(cx, cz);
    if (TRAP_SPENT.has(key)) return false;
    return TRAP_MOVED.has(key) ||
        trapNoise(cx ^ 0x5bf03635, cz ^ 0x27d4eb2f, trapSalt) < TUNING.explosions.trap.chance;
}

// The tuft in cell (cx, cz), or null: where the meadow puts one, if it puts one there.
//
// A tuft is anchored at the cell's *even* corner -- `nearestTuft` jitters it +-0.9 m
// around `cx * 2` -- which is not the point a mine's cell centre uses (`cx * 2 + 1`);
// asking from the wrong one is a metre and a half of diagonal, and every tuft jittered
// away from that corner falls outside the query's own range. This is that derivation
// for one cell rather than a search for the nearest, which is both cheaper and
// unambiguous: the nearest tuft to a cell's anchor can be a *neighbour's*.
//
// It answers for the meadow as it is derived, eaten or not -- whether a tuft is
// currently *there* is `EATEN`, which is the caller's business.
function tuftInCell(cx, cz) {
    let h = (cx * 374761393 + cz * 668265263) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    h = (h ^ (h >>> 16)) >>> 0;
    const a = h / 4294967296;
    if (a < 0.45) return null;
    let h2 = (cx * 1103515245 + cz * 12345) | 0;
    h2 = Math.imul(h2 ^ (h2 >>> 15), 2246822519);
    h2 = (h2 ^ (h2 >>> 13)) >>> 0;
    return {
        cx: cx,
        cz: cz,
        x: cx * 2 + (h2 / 4294967296 - 0.5) * 1.8,
        z: cz * 2 + (a - 0.5) * 1.8,
    };
}

// Where a device goes when it has gone off.
//
// The destination is derived from the cell it left rather than from anything that
// has to be remembered or sent: a ring `relocate.min`..`relocate.max` metres around
// the cell, with the radius and the angle drawn from the cell's own key and the try
// index. Every process that knows which cell fired therefore computes the same
// destination, which is what lets a device move without a word on the wire.
//
// The ring never reaches inside `blast.radius`: a bang must not set off a mine it has
// just placed, or a single blast would chain forever. `tries` draws before the device
// is simply not replaced -- a bang takes one out of the world rather than ever
// doubling one up -- and the spawn's safe disc is refused like everything else.
//
// A trap has one more condition: it has to land in a cell the meadow grows a tuft in,
// because a trap without a tuft is not a device. That is why it asks `tuftInCell`
// about the candidate cell rather than the meadow's hash directly -- and why it asks
// for a *live* one: a trap on a cell whose grass is currently eaten is a device nobody
// can see or trip.
function relocateDevice(kind, fcx, fcz) {
    const e = TUNING.explosions;
    const r = e.relocate;
    const lo = r.min > e.blast.radius ? r.min : e.blast.radius;
    const fx = fcx * 2 + 1;
    const fz = fcz * 2 + 1;
    const mine = kind !== "trap";
    for (let tries = 0; tries < r.tries; tries++) {
        const d = lo + (r.max - lo) * trapNoise(fcx, fcz, trapSalt + tries);
        // A second draw for the angle, off the other coordinate and the try.
        const a = 6.283185307179586 * trapNoise(fcz ^ tries, fcx + tries, trapSalt ^ 0x27d4eb2f);
        const cx = Math.floor((fx + Math.cos(a) * d) / 2);
        const cz = Math.floor((fz + Math.sin(a) * d) / 2);
        const x = cx * 2 + 1;
        const z = cz * 2 + 1;
        // The spawn's disc, measured to the cell's nearest edge exactly as
        // `mineAt` measures it.
        const ax = x < 0 ? -x : x;
        const az = z < 0 ? -z : z;
        const sx = ax > 1 ? ax - 1 : 0;
        const sz = az > 1 ? az - 1 : 0;
        if (sx * sx + sz * sz < e.safe * e.safe) continue;
        const key = tuftKey(cx, cz);
        if (mine) {
            // `mineArmed` is false both for a cell that already holds one *and* for a
            // cell whose mine has already gone off, and the second must stay empty for
            // the session -- so the spent set is its own test here.
            if (SPENT.has(key) || mineArmed(cx, cz)) continue;
            MOVED.add(key);
            return true;
        }
        if (TRAP_SPENT.has(key) || trapAt(cx, cz)) continue;
        if (tuftInCell(cx, cz) === null || EATEN.has(key)) continue;
        TRAP_MOVED.add(key);
        return true;
    }
    return false;
}

// The nearest armed mine within `trigger` of (x, z), or null -- the goat's *own*
// cell only, because that is the only cell a mine's trigger disc can reach: the
// disc is `trigger` around a 2 m cell's centre, so it never comes within `trigger`
// of a neighbour's centre. One cell per goat per arrival, not a box around it.
function mineInCell(x, z, cx, cz) {
    if (!mineArmed(cx, cz)) return null;
    const e = TUNING.explosions;
    const mx = cx * 2 + 1;
    const mz = cz * 2 + 1;
    const dx = mx - x;
    const dz = mz - z;
    if (dx * dx + dz * dz > e.mine.trigger * e.mine.trigger) return null;
    return { cx: cx, cz: cz, x: mx, z: mz };
}

// Take a device out of the field: it has gone off, so it is spent -- a derived cell stays
// empty for the session -- and a replacement is placed elsewhere (`relocateDevice`).
// False when there is nothing armed at that cell, which is what makes it safe to call
// for a device that has already gone off.
//
// This is the *whole* of what a process has to do when it hears that a key fired (M19e):
// the move follows from the cell that fired, so the wire carries the key and nothing
// about where the device went.
function spendDevice(kind, cx, cz) {
    const key = tuftKey(cx, cz);
    const mine = kind !== "trap";
    if (mine) {
        if (!mineArmed(cx, cz)) return false;
        // A replacement that goes off is simply removed; a derived mine leaves its
        // cell spent, which is what keeps that cell empty for the session.
        if (!MOVED.delete(key)) SPENT.add(key);
    } else {
        if (!trapAt(cx, cz)) return false;
        if (!TRAP_MOVED.delete(key)) TRAP_SPENT.add(key);
    }
    tripCount += 1;
    relocateDevice(kind, cx, cz);
    return true;
}

// Put a device on a fuse: it leaves the world from this moment -- it cannot be
// tripped again while it waits, and its replacement has already been placed
// elsewhere -- and the bang lands when the fuse runs out. Returns false when there
// is nothing armed at that cell (a spent cell, or one whose replacement is gone too).
function tripDevice(kind, cx, cz, x, z, depth) {
    if (!spendDevice(kind, cx, cz)) return false;
    const key = tuftKey(cx, cz);
    PENDING.push({
        kind: kind,
        key: key,
        x: x,
        z: z,
        seed: hash(key * 0.0001),
        depth: depth === undefined ? 0 : depth,
        left: TUNING.explosions.fuse,
    });
    return true;
}

// ---- craters (M19d) ---------------------------------------------------------
//
// A bang dishes the ground. The dish is a *term in `terrainHeight`* (world.js) rather
// than geometry of its own, so everything that reads the ground -- the goat, the herd,
// the peers, the grass, both shadows -- stands in the crater with nothing added
// anywhere: one pure function, already read by all of them.
//
// The list is the only state, capped at `crater.max` with the oldest retired first, and
// it heals by scaling the dish down over `crater.heal`. The ground closing over is what
// keeps the list -- and, once M19e puts craters on the wire, the datagram -- bounded,
// the same argument `EATEN`'s regrow window makes for the meadow.
//
// All of this is per process until M19e: a crater is not replicated yet, so two players
// in a session see the holes they made themselves (see *The wire* in ROADMAP.md).
const CRATERS = [];             // { x, z, r, reach2, depth, dip, lip, seed, age, heal, drop }

// Metres outside the dish's radius where the raised lip has fallen back to nothing.
const CRATER_LIP_OUT = 1.45;

// How far the dish eases before the per-cell height cache and the mesh are told to
// catch up -- and, since the *ground* reads this same value, the size of the step a
// goat standing in a healing crater would feel. Ten centimetres is under a hooffall,
// and it costs a rebuild roughly every minute of a crater's four. Both halves read the
// quantized value, so what the goat walks on is exactly what the mesh shows.
const CRATER_STEP = 0.1;

// The craters' own contribution to the ground: a bowl with a raised rim, eased back to
// flat as it heals. Called from `terrainHeight` for every goat, every tuft cell and
// every shadow vertex, so the shape is: nothing at all when there are no craters, two
// multiplies and a compare for one that is nowhere near the query.
function craterDipAt(x, z) {
    let dip = 0;
    for (let i = 0; i < CRATERS.length; i++) {
        const c = CRATERS[i];
        const dx = x - c.x;
        const dz = z - c.z;
        const d2 = dx * dx + dz * dz;
        if (d2 > c.reach2) continue;
        const t = Math.sqrt(d2) / c.r;
        if (t < 1) {
            // The bowl: -dip at the centre, flat at the rim.
            const s = 1 - t;
            dip -= c.dip * s * s * (3 - 2 * s);
        } else {
            // The lip: raised at the rim, nothing at `CRATER_LIP_OUT`.
            let s = (t - 1) / (CRATER_LIP_OUT - 1);
            if (s > 1) continue;
            s = 1 - s;
            dip += c.lip * s * s * (3 - 2 * s);
        }
    }
    return dip;
}

// The live craters, for the console and the tests: where, how wide, how deep right
// now, and how far through its heal it is.
function sceneCraters() {
    const out = [];
    for (let i = 0; i < CRATERS.length; i++) {
        const c = CRATERS[i];
        out.push({
            x: c.x,
            z: c.z,
            r: c.r,
            depth: c.dip,
            age: c.age,
            heal: c.heal,
            seed: c.seed,
        });
    }
    return out;
}

// Drop a crater's cells out of the per-cell height cache, so the grass (and anything
// else that reads it) sees the ground as it is now, and mark the mesh dirty. The cache
// is keyed by cell and world-anchored, so a cell is *deleted* rather than overwritten:
// the next reader re-derives it.
//
// The cells always go -- a re-derive is cheap and always right -- but the *mesh* is
// only rebuilt for a crater near the goat. A rebuild is a whole field's worth of
// vertices, and a bang a bot set off forty metres away would otherwise hitch the frame
// it landed in, over five centimetres of dish that nobody is looking at: the next
// anchor rebuild picks it up on the way there (`terrainEnsure`).
function craterDropCells(c) {
    const r = c.r * CRATER_LIP_OUT;
    const cx0 = Math.floor((c.x - r) / 2);
    const cx1 = Math.ceil((c.x + r) / 2);
    const cz0 = Math.floor((c.z - r) / 2);
    const cz1 = Math.ceil((c.z + r) / 2);
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) TERRAIN_CELL_H.delete(tuftKey(cx, cz));
    }
    const dx = c.x - goat.px;
    const dz = c.z - goat.pz;
    const near = TUNING.terrain.snap;
    if (dx * dx + dz * dz <= near * near) terrainDirty = true;
}

// The tufts a crater covers, as cell keys. A crater kills the grass it swallowed, and
// the meadow's own `EATEN` is the mechanism -- with the crater's heal rather than a
// bite's regrow window, so a tuft comes back exactly as the ground does.
//
// A tuft stands where its own hash jittered it inside its cell, not at the cell's
// centre, so the test is the tuft's position against the crater: the box is widened a
// cell for the same reason.
function craterTuftCells(c) {
    const cells = [];
    const r = c.r;
    const cx0 = Math.floor((c.x - r) / 2) - 1;
    const cx1 = Math.floor((c.x + r) / 2) + 1;
    const cz0 = Math.floor((c.z - r) / 2) - 1;
    const cz1 = Math.floor((c.z + r) / 2) + 1;
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) {
            const t = tuftInCell(cx, cz);
            if (t === null) continue;
            const dx = t.x - c.x;
            const dz = t.z - c.z;
            if (dx * dx + dz * dz > r * r) continue;
            cells.push(tuftKey(cx, cz));
        }
    }
    return cells;
}

// Whether a *live* crater other than `skip` still covers the tuft in `key`, which is
// what decides whether a retiring crater may let it back.
function craterCoversKey(key, skip) {
    for (let i = 0; i < CRATERS.length; i++) {
        const c = CRATERS[i];
        if (c === skip) continue;
        const cells = craterTuftCells(c);
        if (cells.indexOf(key) >= 0) return true;
    }
    return false;
}

// Mark (or release) the tufts a crater covers. Releasing asks the other craters first:
// two bangs in the same place must not let the grass back through the outer one. The
// meadow is the host's whatever the session looks like (M12b), so a client kills
// nothing here and mirrors the host's world instead.
function markCraterTufts(c, on) {
    if (!netWorldLocal()) return;
    const cells = craterTuftCells(c);
    for (let i = 0; i < cells.length; i++) {
        if (on) EATEN.set(cells[i], c.heal);
        else if (!craterCoversKey(cells[i], c)) EATEN.delete(cells[i]);
    }
}

// Retire a crater: the ground is flat again, the grass comes back, and the mesh is
// told. Used by the heal, by the cap, and by the harness's reset.
function retireCrater(c) {
    markCraterTufts(c, false);
    c.dip = 0;
    craterDropCells(c);
}

// Dig one. The radius varies a little per bang -- a minefield of identical holes reads
// as a pattern -- and the depth is the tuning's.
function addCrater(x, z, seed) {
    const t = TUNING.explosions.crater;
    if (t.radius <= 0 || t.depth <= 0 || t.max <= 0) return null;
    // The cap retires the oldest rather than refusing the newest: a bang with no hole is
    // a promise broken, and a far-away crater closing over is not.
    while (CRATERS.length > 0 && CRATERS.length >= t.max) retireCrater(CRATERS.shift());
    const r = t.radius * (0.85 + hash(seed) * 0.3);
    const reach = r * CRATER_LIP_OUT;
    const c = {
        x: x,
        z: z,
        r: r,
        reach2: reach * reach,
        depth: t.depth,
        dip: t.depth,
        lip: t.lip,
        seed: seed,
        age: 0,
        heal: t.heal,
        drop: t.depth,
    };
    CRATERS.push(c);
    markCraterTufts(c, true);
    craterDropCells(c);
    return c;
}

// Age the craters: the dish eases back to flat over `heal`, and the ground's caches are
// told when it has moved far enough to matter. Runs whether or not the explosion system
// is enabled: the ground is not an effect, and a crater that never healed would be a
// hole in the world left by a debug switch.
function updateCraters(dt) {
    for (let i = CRATERS.length - 1; i >= 0; i--) {
        const c = CRATERS[i];
        c.age += dt;
        if (c.age >= c.heal) {
            CRATERS.splice(i, 1);
            retireCrater(c);
            continue;
        }
        const next = c.depth * (1 - c.age / c.heal);
        if (c.drop - next >= CRATER_STEP) {
            // Quantized, so the dip `craterDipAt` returns and the dip the mesh was built
            // from are the same number: one rebuild per step, and no drift between the
            // ground the goat stands on and the ground it can see.
            c.drop = Math.floor(next / CRATER_STEP) * CRATER_STEP;
            c.dip = c.drop;
            craterDropCells(c);
        }
    }
}

// Forget every crater: the ground comes back, the grass with it, and the mesh is told.
// What the harness resets the field with between cases.
function sceneResetCraters() {
    for (let i = 0; i < CRATERS.length; i++) retireCrater(CRATERS[i]);
    CRATERS.length = 0;
}

// The host's craters (M19e): state rather than events, because a joiner has to see the
// ground as it is. `null` keeps what we have -- the snapshot could not carry them -- and a
// list is adopted whole.
//
// Reconciled in place rather than rebuilt: the world arrives ten times a second, and
// retiring and re-adding every crater each time would drop the height cache and rebuild the
// mesh with it, which is exactly the cost M19d spent its time removing.
function applyCraters(list) {
    if (!Array.isArray(list)) return;
    for (let i = 0; i < list.length; i++) {
        const s = list[i];
        const c = craterNear(s.x, s.z);
        if (c === null) mirrorCrater(s);
        else adoptCrater(c, s);
    }
    // Whatever the host no longer has is gone -- it healed, or the cap retired it. Walked
    // backwards because retiring splices.
    for (let i = CRATERS.length - 1; i >= 0; i--) {
        const c = CRATERS[i];
        if (!craterListed(list, c)) {
            CRATERS.splice(i, 1);
            retireCrater(c);
        }
    }
}

// A mirrored crater, built from the host's numbers rather than from the tuning: `r` varies a
// little per bang and only the host knows which way it went, and `depth` is the dish as it
// stands. The seed does not travel and nothing on the ground reads it -- it is the tint's
// jitter, and a client is allowed its own.
function mirrorCrater(s) {
    const c = {
        x: s.x,
        z: s.z,
        r: s.r,
        reach2: (s.r * CRATER_LIP_OUT) * (s.r * CRATER_LIP_OUT),
        depth: s.depth,
        dip: s.depth,
        lip: TUNING.explosions.crater.lip,
        seed: hash(s.x * 7.1 + s.z * 3.3),
        age: 0,
        // The host heals; this end mirrors. A dish that aged here would disagree with the
        // ground the host is telling everyone about, so a mirrored crater never closes over
        // on its own -- the snapshot that drops it is what retires it.
        heal: Infinity,
        drop: Math.floor(s.depth / CRATER_STEP) * CRATER_STEP,
    };
    CRATERS.push(c);
    markCraterTufts(c, true);
    craterDropCells(c);
    return c;
}

// Take the host's numbers for a crater we already have. The mesh and the height cache hear
// about it only when the *quantized* dish actually moves, which is the rule the heal follows
// too -- so a snapshot of an unchanged crater costs a handful of compares.
function adoptCrater(c, s) {
    const next = Math.floor(s.depth / CRATER_STEP) * CRATER_STEP;
    const wider = c.r !== s.r;
    c.depth = s.depth;
    c.r = s.r;
    c.reach2 = (s.r * CRATER_LIP_OUT) * (s.r * CRATER_LIP_OUT);
    if (!wider && next === c.drop) return;
    c.drop = next;
    c.dip = next;
    craterDropCells(c);
}

// The crater at (x, z), or null. A metre: the position is the host's and could be a
// centimetre off the one this end mirrored, while a crater is metres wide -- two craters
// closer than that are the same hole.
function craterNear(x, z) {
    for (let i = 0; i < CRATERS.length; i++) {
        const c = CRATERS[i];
        const dx = c.x - x;
        const dz = c.z - z;
        if (dx * dx + dz * dz <= 1) return c;
    }
    return null;
}

// Whether the host's list still carries `c`.
function craterListed(list, c) {
    for (let i = 0; i < list.length; i++) {
        const dx = list[i].x - c.x;
        const dz = list[i].z - c.z;
        if (dx * dx + dz * dz <= 1) return true;
    }
    return false;
}

// A bang at (x, z): leave a crater, damage every goat this process simulates, and
// set off the neighbours if there is chain budget left. One level deep by default,
// so a dense field cannot cascade into a frame-long loop.
//
// `key` is the device that made it, and only a bang a *device* made has one (M19e): a
// chained bang is another device going off and reports itself when its own fuse ends,
// while the harness's own `blast(...)` and a bang that arrived over the wire pass none
// and are never handed back out.
function blast(kind, x, z, seed, depth, key) {
    const e = TUNING.explosions;
    blastCount += 1;
    // The hole the bang makes (M19d). It is the *ground* that is everyone's, so every
    // process that applies a blast digs one -- which is why a client's own bang is a
    // crater for its player and the host's world snapshot is where the others will
    // come from (M19e).
    addCrater(x, z, seed);
    const r = e.blast.radius;
    // The player's goat is simulated here whatever the session looks like
    // (M12b), so it always takes the blast, and it is clamped by `healthFloor`. The
    // herd's blast is a few lines below, on the same curve without that floor.
    const dx = goat.px - x;
    const dz = goat.pz - z;
    const d2 = dx * dx + dz * dz;
    if (d2 <= r * r) {
        const d = Math.sqrt(d2);
        const falloff = 1 - d / r;
        stats.health = Math.max(e.blast.healthFloor,
            stats.health - e.blast.damage * falloff * falloff);
        // M19c: away from the blast, up, and scaled by the same falloff as the
        // damage, so the rim is a shove and the centre is a launch.
        const u = flingDirection(dx, dz, d, seed);
        startFling(u.x * e.blast.push * falloff, u.z * e.blast.push * falloff,
            e.blast.lift * falloff);
    }
    // The herd takes the blast too, but only where the herd is ours to move -- the
    // same rule `checkTriggers` follows below: offline and on the host. A client
    // never applies a blast to a bot it only mirrors.
    if (netWorldLocal()) {
        for (let i = 0; i < BOTS.length; i++) {
            const b = BOTS[i];
            if (b.mode === "dead") continue;   // a corpse takes no second bang
            const bx = b.x - x;
            const bz = b.z - z;
            const bd2 = bx * bx + bz * bz;
            if (bd2 > r * r) continue;
            const bd = Math.sqrt(bd2);
            const bfalloff = 1 - bd / r;
            // The player's own curve, off the player's radius and damage -- but not
            // the player's floor, which is the promise that a mine cannot end *this*
            // player's run. A bot is not that promise: three bangs on the centre kill
            // it and one at the rim is a bruise. A lethal bang kills instead of
            // throwing, and a bot killed in the air keeps the arc it already had, so
            // a chain on a flung bot drops a corpse rather than teleporting one.
            b.health = Math.max(0, b.health - e.blast.damage * bfalloff * bfalloff);
            if (b.health <= 0) {
                botDie(b);
                continue;
            }
            const bu = flingDirection(bx, bz, bd, seed);
            startBotFling(b, bu.x * e.blast.push * bfalloff, bu.z * e.blast.push * bfalloff,
                e.blast.lift * bfalloff);
        }
    }
    spawnBlastFx(x, z, seed);
    // Heard wherever the goat is, in or out of the radius (audio.js).
    playBlast(x, z);
    if (depth < e.chainDepth) chainFrom(x, z, depth + 1);
    // And told to the others (M19e), by the process that fired it -- the reporter does
    // not wait for the host to fire it back.
    if (key !== undefined) netBlastFired(kind, key, x, z);
}

// Where the device in a cell is, as { x, z }, or null when the cell holds none. A mine
// sits at its cell's centre; a trap sits on the tuft it trapped, which `tuftInCell`
// already derives. The host answers with this, because it owns the layout and is therefore
// the one that can say where a key actually is (M19e).
function deviceAt(kind, cx, cz) {
    if (kind !== "trap") return { x: cx * 2 + 1, z: cz * 2 + 1 };
    const t = tuftInCell(cx, cz);
    return t === null ? null : { x: t.x, z: t.z };
}

// A bang somebody else's process fired (M19e): ours to see and ours to feel, but not ours
// to fire again. The device leaves the field from the key alone, and the bang is the same
// `blast` with the same seed -- it is derived from the key, so a chained crater is the same
// size here as there. The chain stops at this depth: the devices a chain sets off are the
// origin's to report, and each of them fires exactly once.
function applyRemoteBlast(kind, key, x, z) {
    const cell = tuftCell(key);
    spendDevice(kind, cell.cx, cell.cz);
    blast(kind, x, z, hash(key * 0.0001), TUNING.explosions.chainDepth);
}

// A client's device went off (M19e), on the host. The device leaves the field here too --
// the neighbours must not trip it -- and the bang is applied the way this process applies
// any other: the ground is everyone's, and the host's crater list is the state every client
// adopts, so a bang the host did not dig would be erased by the host's own next snapshot.
//
// The return is the *answer*, not an input: where the device actually was, from this
// scene's own layout (`deviceAt`). `null` when the cell holds a trap with no tuft in it -- a
// key that is not a device here -- and then nothing is relayed. The host bridge is what
// turns this into the relay, and `headless.rs` wraps it in the JSON the server reads back.
function sceneBlastReport(kind, key) {
    const cell = tuftCell(key);
    const at = deviceAt(kind, cell.cx, cell.cz);
    if (at === null) return null;
    applyRemoteBlast(kind, key, at.x, at.z);
    return { x: at.x, z: at.z };
}

// The devices the host has seen go off (M19e): world state, beside the meadow, so that a
// joiner sees the field as it stands. `null` means the snapshot could not carry it and
// keeps the field we have -- the meadow's own contract -- and spending is idempotent, so a
// device this process fired itself is already spent and costs nothing here.
function applySpent(list) {
    if (!Array.isArray(list)) return;
    for (let i = 0; i < list.length; i++) {
        const entry = list[i];
        const cell = tuftCell(entry.key);
        spendDevice(entry.trap ? "trap" : "mine", cell.cx, cell.cz);
    }
}

// The direction a blast throws a goat in: away from the centre, turned a little off
// that axis by the blast's own stream so two goats side by side do not fly in
// lockstep. A goat dead on the centre has no direction to take, so the stream picks
// one for it rather than dividing by zero. One small object per blast -- blasts are
// rare (a few a second at most), unlike everything in the frame loop.
function flingDirection(ox, oz, d, seed) {
    let ux, uz;
    if (d > 1e-3) {
        ux = ox / d;
        uz = oz / d;
    } else {
        const a = hash(seed * 9.7) * 6.283185307179586;
        ux = Math.cos(a);
        uz = Math.sin(a);
    }
    const turn = (hash(seed * 3.7 + 1.3) - 0.5) * 0.6;   // +-0.3 rad off-axis
    return { x: ux - uz * turn, z: uz + ux * turn };
}

// A blast sets off the armed devices it reaches, `chain` seconds later. The fuse
// makes a cascade read as a sequence rather than as one frame of noise. Armed means
// what `mineArmed` means, so a mine that has moved into the blast's reach chains like
// any other -- and the ring a replacement is placed on never reaches inside
// `blast.radius`, so a bang cannot set off the mine it has just moved.
function chainFrom(x, z, depth) {
    const e = TUNING.explosions;
    const r = e.blast.radius;
    const cx0 = Math.floor((x - r) / 2);
    const cx1 = Math.floor((x + r) / 2);
    const cz0 = Math.floor((z - r) / 2);
    const cz1 = Math.floor((z + r) / 2);
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) {
            if (!mineArmed(cx, cz)) continue;
            const mx = cx * 2 + 1;
            const mz = cz * 2 + 1;
            const dx = mx - x;
            const dz = mz - z;
            if (dx * dx + dz * dz > r * r) continue;
            tripDevice("mine", cx, cz, mx, mz, depth);
        }
    }
}

// A slot index for a new effect, or -1 when the pool is full. The oldest instance
// gives way: a fresh bang the player just heard matters more than the tail of an
// old one.
function fxTake() {
    const cap = clamp(Math.round(TUNING.explosions.maxActive), 0, FX_CAPACITY);
    if (cap <= 0) return -1;
    let oldest = -1;
    for (let i = 0; i < cap; i++) {
        if (!FX[i].live) return i;
        if (oldest < 0 || FX[i].age > FX[oldest].age) oldest = i;
    }
    return oldest;
}

function spawnBlastFx(x, z, seed) {
    const at = fxTake();
    if (at < 0) return;
    if (at + 1 > fxTop) fxTop = at + 1;
    const slot = FX[at];
    slot.live = true;
    slot.kind = 0;
    slot.x = x;
    slot.z = z;
    slot.y = terrainHeight(x, z) + 0.3;
    slot.age = 0;
    slot.dur = FX_PUFF_TIME;
    slot.seed = seed;
    slot.scale = FX_PUFF_SCALE * (0.8 + hash(seed) * 0.5);
}

// The player's trigger, and the herd's: a goat on the ground walks onto a mine
// or over a trapped tuft. Calls come from `updateExplosions`, once per arrival
// rather than once per frame -- see the stamp in `checkTriggers` for why that is
// the same thing.

// Whether the goat is over the ground rather than on it. The model's hop is the
// clip's root motion, so `goat.py` stays 0 through a jump and the *mode* is what
// says airborne there; the cube fallback really does lift `py`, and `clearance`
// is the height that counts as "over it". A landing is when this stops being
// true, which is what sets off the mine the goat came down on.
function goatAirborne() {
    // A flung goat owns its own height (the arc in `goat.js`), so it is airborne by
    // construction; a jump is airborne by mode, since the clip's root motion does
    // the hop and `goat.py` stays 0; and the cube fallback really does lift `py`.
    if (mode === "flung") return true;
    return haveModel ? mode === "jump" : goat.py > TUNING.explosions.mine.clearance;
}

// The half-metre bucket each goat was last tested in, with the airborne flag
// packed beside it (one compare says whether anything a device cares about has
// changed). The bucket is finer than the cell on purpose: a mine's trigger disc
// is a sub-cell region, so a goat can walk into one without changing cells, and
// 0.5 m against a 0.6 m radius means a goat at 3 m/s cannot step over a bucket.
// A goat standing still is not walking onto anything, so most frames cost one
// compare per goat.
//
// The stamp is a plain field on the unit (`goat.trip`, `b.trip`) rather than an
// entry in a Map: a member read is a property read, while `Map.get` is a builtin
// call -- and this engine's own micro-suite is explicit that a crux-native
// builtin is not a JS leaf and cannot be inlined, so a Map lookup per unit per
// frame is the expensive shape (measured: sixteen inlined JS calls per frame cost
// nothing, while the same work through Maps did not move when the calls around it
// were removed).
function checkTriggers(unit, x, z, airborne) {
    // The half-metre bucket and the airborne bit, inlined rather than the two
    // calls this used to be (`tuftKey` over `tripStamp`): this runs for the goat
    // and for every bot, every frame, and a stamp is only worth having if
    // computing it is one expression. `| 0` is the bucket rather than
    // `Math.floor` because a bucket only has to be a stable 0.5 m partition --
    // the *cell* that decides the device stays `Math.floor(x / 2)`, below.
    const stamp = ((((x * 2) | 0) + 4096) * 8192 + (((z * 2) | 0) + 4096)) * 2 +
        (airborne ? 1 : 0);
    if (unit.trip === stamp) return;
    unit.trip = stamp;
    if (airborne) return;
    const cx = Math.floor(x / 2);
    const cz = Math.floor(z / 2);
    const mine = mineInCell(x, z, cx, cz);
    if (mine !== null) tripDevice("mine", mine.cx, mine.cz, mine.x, mine.z, 0);
    // Walking over a trap is the same test at the tuft's own position, which is
    // what `nearestTuft` already knows -- and its `trappedOnly` filter is what
    // keeps this from firing on the grass around it.
    const t = nearestTuft(x, z, TUNING.explosions.mine.trigger, true);
    if (t !== null) tripDevice("trap", t.cx, t.cz, t.x, t.z, 0);
}

function updateExplosions(dt) {
    // The ground heals whether or not the system is on: a crater is not an effect, and
    // `enabled 0` is a frame-cost bisect, not a way to leave a hole in the world.
    if (CRATERS.length > 0) updateCraters(dt);
    // `tune explosions.enabled 0` turns the whole system off, which is what a
    // frame-cost bisect needs: one command, no rebuild, and the engine, the world
    // and every other system stay exactly as they were.
    if (TUNING.explosions.enabled <= 0) return;
    const e = TUNING.explosions;

    // Fuses first, so a bang that lands this frame can still chain.
    for (let i = PENDING.length - 1; i >= 0; i--) {
        const pending = PENDING[i];
        pending.left -= dt;
        if (pending.left > 0) continue;
        PENDING.splice(i, 1);
        blast(pending.kind, pending.x, pending.z, pending.seed, pending.depth, pending.key);
    }

    for (let i = 0; i < fxTop; i++) {
        const slot = FX[i];
        if (!slot.live) continue;
        slot.age += dt;
        if (slot.age >= slot.dur) slot.live = false;
    }
    while (fxTop > 0 && !FX[fxTop - 1].live) fxTop -= 1;

    // A sleeping goat is not moving, and a dead one is not a goat the world has
    // to be fair about: neither trips anything. The player's goat is simulated
    // here whatever the session looks like (M12b); the herd is ours only when the
    // world is, which is offline and on the host.
    if (mode !== "sleep" && mode !== "dead") {
        checkTriggers(goat, goat.px, goat.pz, goatAirborne());
    }
    if (!netWorldLocal()) return;
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        // Neither a sleeping bot nor a dead one is walking anywhere. Sleeping is the
        // rule that was already here; a corpse is the same argument and one more: a
        // body lying on a mine is inert until something moves it, and letting one
        // trip a device would only ever be a bot blowing itself up again.
        if (b.mode === "sleep" || b.mode === "dead") continue;
        checkTriggers(b, b.x, b.z, botAirborne(b));
    }
}

// The bang, and the faint patch that warns of a mine. Drawn inside the 3D pass,
// after the world, so smoke reads over the goats it is blowing up rather than
// behind them.
function drawExplosions() {
    if (cloudTex < 0 || TUNING.explosions.enabled <= 0) return;
    const e = TUNING.explosions;
    const tell = e.mine.tell;
    if (tell > 0) drawMineTells(tell);
    // The scorch, until M19f's decals: a dark disc the width of the dish, at the ground
    // it dished, fading faster than the ground closes. The same soft puff the tell uses
    // -- one texture, no new asset, and the same argument M19b made for the bang itself.
    //
    // It is also *fill rate*, and the only thing in this system that is: every one of
    // these is a camera-facing alpha quad metres across, so a field of craters behind a
    // low camera is more blended pixels than everything else in the scene put together.
    // Hence the range: a tint twenty metres away is a few pixels nobody can read, and
    // `crater.scorch 0` is one `tune` away if the fill still shows (it is what M19d
    // shipped to bisect exactly that).
    if (e.crater.scorch > 0) {
        const range = e.crater.scorchRange;
        const range2 = range * range;
        for (let i = 0; i < CRATERS.length; i++) {
            const c = CRATERS[i];
            const dx = c.x - goat.px;
            const dz = c.z - goat.pz;
            if (dx * dx + dz * dz > range2) continue;
            const fade = 1 - c.age / c.heal;
            const alpha = Math.round(150 * fade * fade);
            if (alpha <= 0) continue;
            rl.drawBillboard(cloudTex, c.x, terrainHeight(c.x, c.z) + 0.03, c.z, c.r * 2.2,
                rl.color(44, 36, 28, alpha));
        }
    }
    for (let i = 0; i < fxTop; i++) {
        const slot = FX[i];
        if (!slot.live) continue;
        const t = slot.age / slot.dur;
        const fade = 1 - t;
        const alpha = Math.round(255 * fade * fade);
        rl.drawBillboard(cloudTex, slot.x, slot.y + t * FX_PUFF_LIFT, slot.z,
            slot.scale * (0.55 + t), rl.color(255, 206, 140, alpha));
    }
}

// "Nearly invisible" needs a fair tell or the feature is a tax on walking: an
// armed mine within `tell` metres shows a faint disturbed-earth patch. `tell: 0`
// makes them invisible (and a mod can read the layout and draw its own).
//
// The patches are found once and redrawn, because a patch does not move: the frame's
// cost is then the nought-to-two patches on screen rather than the sixteen-cell
// window that finds them. That matters here -- a per-cell derivation is a call, a
// builtin (`Math.imul`) and a property read, and this engine's own numbers say a
// `property read` is its slowest per-frame operation once the pool sweeps are out of
// the way. The window is re-scanned when the goat has gone far enough for it to hold
// different cells, or when any of the field's inputs moves: the density and the safe
// radius are live tuning leaves (the console, mods and the harness's chain case all
// write them), the salt moves with the session, and `tripCount` moves whenever a
// device goes off, since its replacement lands somewhere else in that same window.
const TELLS = [];
let tellX = 0;
let tellZ = 0;
let tellRange = -1;
let tellSalt = 0;
let tellDensity = 0;
let tellSafe = 0;
let tellTrips = 0;

function drawMineTells(tell) {
    const e = TUNING.explosions;
    const dx = goat.px - tellX;
    const dz = goat.pz - tellZ;
    if (tellRange !== tell || tellSalt !== trapSalt ||
        tellDensity !== e.mine.density || tellSafe !== e.safe ||
        tellTrips !== tripCount ||
        dx * dx + dz * dz > 0.25) {
        tellX = goat.px;
        tellZ = goat.pz;
        tellRange = tell;
        tellSalt = trapSalt;
        tellDensity = e.mine.density;
        tellSafe = e.safe;
        tellTrips = tripCount;
        scanMineTells(tell);
    }
    for (let i = 0; i < TELLS.length; i++) {
        const patch = TELLS[i];
        rl.drawBillboard(cloudTex, patch.x, patch.y, patch.z, 1.3,
            rl.color(46, 40, 32, 120));
    }
}

// The cells the tell disc can touch, and nothing more, into `TELLS`. Runs on
// arrival rather than per frame, so it can afford the per-cell derivation.
function scanMineTells(tell) {
    TELLS.length = 0;
    const cx0 = Math.floor((goat.px - tell) * 0.5);
    const cx1 = Math.floor((goat.px + tell) * 0.5);
    const cz0 = Math.floor((goat.pz - tell) * 0.5);
    const cz1 = Math.floor((goat.pz + tell) * 0.5);
    const limit = tell * tell;
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) {
            if (!mineArmed(cx, cz)) continue;
            const mx = cx * 2 + 1;
            const mz = cz * 2 + 1;
            const dx = mx - goat.px;
            const dz = mz - goat.pz;
            if (dx * dx + dz * dz > limit) continue;
            TELLS.push({
                x: mx,
                y: terrainHeight(mx, mz) + 0.04,
                z: mz,
                key: tuftKey(cx, cz),
            });
        }
    }
}

// The devices near (x, z), read-only: the debug view of a field with almost no
// state to inspect, and the shape `goats.explosions.traps` will hand a mod (a
// mine detector is then a mod, not a core feature).
function sceneTraps(x, z, range) {
    const out = { mines: [], traps: [] };
    const range2 = range * range;
    const r = Math.ceil(range / 2) + 1;
    const cx0 = Math.floor(x / 2);
    const cz0 = Math.floor(z / 2);
    for (let cx = cx0 - r; cx <= cx0 + r; cx++) {
        for (let cz = cz0 - r; cz <= cz0 + r; cz++) {
            const mx = cx * 2 + 1;
            const mz = cz * 2 + 1;
            const dx = mx - x;
            const dz = mz - z;
            if (dx * dx + dz * dz > range2) continue;
            const key = tuftKey(cx, cz);
            if (mineArmed(cx, cz)) {
                out.mines.push({
                    x: mx, z: mz, key: key, dist: Math.sqrt(dx * dx + dz * dz),
                    moved: MOVED.has(key),
                });
            }
            // A trapped tuft is reported at the tuft, which is where the bang would
            // land -- the tuft's own hash is `tuftInCell`'s.
            if (trapAt(cx, cz) && !EATEN.has(key)) {
                const t = tuftInCell(cx, cz);
                if (t !== null) {
                    out.traps.push({
                        x: t.x,
                        z: t.z,
                        key: key,
                        dist: Math.sqrt((t.x - x) * (t.x - x) + (t.z - z) * (t.z - z)),
                        moved: TRAP_MOVED.has(key),
                    });
                }
            }
        }
    }
    return out;
}

// The device state as one object, for the console and the tests: how many devices
// have gone off, how many replacements have moved in, how many are waiting on a
// fuse, how many effects are live.
function sceneExplosions() {
    let live = 0;
    for (let i = 0; i < fxTop; i++) {
        if (FX[i].live) live += 1;
    }
    return {
        spent: SPENT.size + TRAP_SPENT.size,
        moved: MOVED.size + TRAP_MOVED.size,
        craters: CRATERS.length,
        pending: PENDING.length,
        live: live,
        blasts: blastCount,
        safe: TUNING.explosions.safe,
    };
}

// Forget where the devices have got to: the derived field comes back exactly as it was
// at boot. This is what the harness resets the field with between cases -- clearing
// `SPENT` alone would leave the replacements it moved standing in the field.
function sceneResetDevices() {
    SPENT.clear();
    MOVED.clear();
    TRAP_SPENT.clear();
    TRAP_MOVED.clear();
}

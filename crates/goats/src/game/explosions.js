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
// The only state is what changes: which devices have gone off (`SPENT`, until
// they re-arm), what is waiting on a fuse (`PENDING`) and the live effect
// instances (`FX`). A device does not blow up where it was tripped -- the trigger
// starts a fuse (`TUNING.explosions.fuse`), and the bang lands that many seconds
// later, which gives the art a beat to read and the player a beat of "oh no".
//
// What a blast does here is damage, with a falloff and a floor (M19b). The fling
// is M19c, the crater is M19d and the wire is M19e; the effect is the weather's
// cloud puff drawn as a camera-facing billboard, which M19f replaces with Blender
// atlases behind the same pool.

// A device key is a cell key, packed exactly as `tuftKey` (food.js) packs one, so
// a mine and a tuft in the same cell cannot be mistaken for each other's.
const SPENT = new Map();       // key -> seconds left before it re-arms
const PENDING = [];            // { kind, x, z, seed, depth, left }

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

// Whether the tuft in cell (cx, cz) is trapped. A tuft exists only where the
// meadow's own hash says so, so this is only ever asked about a tuft that is
// there -- `nearestTuft` is what finds those, and it is also what carries the
// `trappedOnly` filter this is used through.
function trapAt(cx, cz) {
    return trapNoise(cx ^ 0x5bf03635, cz ^ 0x27d4eb2f, trapSalt) < TUNING.explosions.trap.chance;
}

// How long a device that has just gone off stays down.
function rearmFor(kind) {
    return kind === "trap" ? TUNING.explosions.trap.rearm : TUNING.explosions.mine.rearm;
}

// The nearest armed mine within `trigger` of (x, z), or null -- the goat's *own*
// cell only, because that is the only cell a mine's trigger disc can reach: the
// disc is `trigger` around a 2 m cell's centre, so it never comes within `trigger`
// of a neighbour's centre. One cell per goat per arrival, not a box around it.
function mineInCell(x, z, cx, cz) {
    if (!mineAt(cx, cz)) return null;
    const e = TUNING.explosions;
    const mx = cx * 2 + 1;
    const mz = cz * 2 + 1;
    const dx = mx - x;
    const dz = mz - z;
    if (dx * dx + dz * dz > e.mine.trigger * e.mine.trigger) return null;
    if (SPENT.has(tuftKey(cx, cz))) return null;
    return { cx: cx, cz: cz, x: mx, z: mz };
}

// Put a device on a fuse: it is spent from this moment (so nothing trips it
// again while it waits) and the bang lands when the fuse runs out. Returns false
// when the device had already gone off.
function tripDevice(kind, cx, cz, x, z, depth) {
    const key = tuftKey(cx, cz);
    if (SPENT.has(key)) return false;
    SPENT.set(key, rearmFor(kind));
    PENDING.push({
        kind: kind,
        x: x,
        z: z,
        seed: hash(key * 0.0001),
        depth: depth === undefined ? 0 : depth,
        left: TUNING.explosions.fuse,
    });
    return true;
}

// A bang at (x, z): damage every goat this process simulates, and set off the
// neighbours if there is chain budget left. One level deep by default, so a
// dense field cannot cascade into a frame-long loop.
function blast(kind, x, z, seed, depth) {
    const e = TUNING.explosions;
    blastCount += 1;
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
// makes a cascade read as a sequence rather than as one frame of noise.
function chainFrom(x, z, depth) {
    const e = TUNING.explosions;
    const r = e.blast.radius;
    const cx0 = Math.floor((x - r) / 2);
    const cx1 = Math.floor((x + r) / 2);
    const cz0 = Math.floor((z - r) / 2);
    const cz1 = Math.floor((z + r) / 2);
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) {
            if (!mineAt(cx, cz)) continue;
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
        blast(pending.kind, pending.x, pending.z, pending.seed, pending.depth);
    }

    // Devices that have gone off re-arm, which is what keeps a minefield a place
    // you avoid for a while rather than a permanent no-go zone.
    if (SPENT.size > 0) {
        for (const key of SPENT.keys()) {
            const left = SPENT.get(key) - dt;
            if (left <= 0) SPENT.delete(key);
            else SPENT.set(key, left);
        }
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
    const tell = TUNING.explosions.mine.tell;
    if (tell > 0) drawMineTells(tell);
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
// The patches are found once and redrawn, because a patch never moves and never
// changes: the frame's cost is then the nought-to-two patches on screen rather
// than the sixteen-cell window that finds them. That matters here -- a per-cell
// derivation is a call, a builtin (`Math.imul`) and a property read, and this
// engine's own numbers say a `property read` is its slowest per-frame operation
// once the pool sweeps are out of the way. The window is re-scanned when the goat
// has gone far enough for it to hold different cells, or when any of the field's
// inputs moves: the density and the safe radius are live tuning leaves (the
// console, mods and the harness's chain case all write them) and the salt moves
// with the session.
const TELLS = [];
let tellX = 0;
let tellZ = 0;
let tellRange = -1;
let tellSalt = 0;
let tellDensity = 0;
let tellSafe = 0;

function drawMineTells(tell) {
    const e = TUNING.explosions;
    const dx = goat.px - tellX;
    const dz = goat.pz - tellZ;
    if (tellRange !== tell || tellSalt !== trapSalt ||
        tellDensity !== e.mine.density || tellSafe !== e.safe ||
        dx * dx + dz * dz > 0.25) {
        tellX = goat.px;
        tellZ = goat.pz;
        tellRange = tell;
        tellSalt = trapSalt;
        tellDensity = e.mine.density;
        tellSafe = e.safe;
        scanMineTells(tell);
    }
    for (let i = 0; i < TELLS.length; i++) {
        const patch = TELLS[i];
        if (SPENT.has(patch.key)) continue;
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
            if (!mineAt(cx, cz)) continue;
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
            const left = SPENT.has(key) ? SPENT.get(key) : 0;
            if (mineAt(cx, cz)) {
                out.mines.push({
                    x: mx, z: mz, key: key, dist: Math.sqrt(dx * dx + dz * dz), rearm: left,
                });
            }
            // A trapped tuft is reported at the tuft, which is where the bang
            // would land -- the tuft's own hash is `nearestTuft`'s.
            if (trapAt(cx, cz)) {
                const t = nearestTuft(mx, mz, 1.5, true);
                if (t !== null && t.cx === cx && t.cz === cz) {
                    out.traps.push({
                        x: t.x,
                        z: t.z,
                        key: key,
                        dist: Math.sqrt((t.x - x) * (t.x - x) + (t.z - z) * (t.z - z)),
                        rearm: left,
                    });
                }
            }
        }
    }
    return out;
}

// The device state as one object, for the console and the tests: how many have
// gone off, how many are waiting on a fuse, how many effects are live.
function sceneExplosions() {
    let live = 0;
    for (let i = 0; i < fxTop; i++) {
        if (FX[i].live) live += 1;
    }
    return {
        spent: SPENT.size,
        pending: PENDING.length,
        live: live,
        blasts: blastCount,
        safe: TUNING.explosions.safe,
    };
}

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
// Bodies one debris instance can throw. The pool's slots carry the arrays, so a bang
// fills them rather than allocating, and the draw is arithmetic over them.
const DEBRIS_MAX = 12;
const FX = [];
let fxTop = 0;
(function buildFxPool() {
    for (let i = 0; i < FX_CAPACITY; i++) {
        const slot = {
            live: false, kind: 0, x: 0, y: 0, z: 0, age: 0, dur: 1, seed: 0, scale: 1,
            spin: 0, n: 0,
            // The grit's own streams, drawn once when the bang is thrown rather than
            // per frame: `hash` is `Math.sin`-based and this engine charges for a
            // builtin, so a body's direction is decided the frame it leaves the hole.
            bx: [], by: [], bz: [], vx: [], vy: [], vz: [],
        };
        for (let b = 0; b < DEBRIS_MAX; b++) {
            slot.bx.push(0);
            slot.by.push(0);
            slot.bz.push(0);
            slot.vx.push(0);
            slot.vy.push(0);
            slot.vz.push(0);
        }
        FX.push(slot);
    }
})();

// The bang's light (M19f): a handful of point lights, each a peak that fades over
// `flash.time`. Four is more than a chain can use -- `chain` is 0.15 s against a
// 0.3 s flash, so two overlapping is the busy case -- and the *strongest* live one is
// the one handed to the shader, which is what stops the second bang of a pair from
// darkening the first: the light coming off a fresh bang is brighter than the tail
// of the one before it.
const FLASH_CAPACITY = 4;
const FLASH = [];
let flashTop = 0;
let flashEnergy = 0;            // the energy the shader was last given
(function buildFlashPool() {
    for (let i = 0; i < FLASH_CAPACITY; i++) {
        FLASH.push({ live: false, x: 0, y: 0, z: 0, age: 0, dur: 1, peak: 0 });
    }
})();

// The player's own reaction (M19f): the camera is knocked along the blast's direction
// and a red frame flashes for a beat when a bang hurts *this* goat. Both are held as
// the number the offset is scaled by, so the camera and the HUD are handed exactly
// what the cases can read back.
let shakeEnergy = 0;            // metres of offset at its peak, decaying
let shakePhase = 0;             // where the knock is in its oscillation
let shakeDirX = 0, shakeDirZ = 0;
let hurtPulse = 0;              // fraction of a full-strength hit

// ---- the effect atlases (M19f) ----------------------------------------------
//
// An effect's look is a flipbook: one atlas and a source rectangle per frame
// (`drawBillboardRec`), so a bang costs a texture handle and four numbers a frame
// rather than a model. The atlases are *generated* here at boot -- the same
// value-noise puff the weather's clouds are built from (`makeWeatherTextures`), laid
// out as a grid whose frames step through the effect -- so the scene gains no binary
// data. A mod replaces one with real art by pointing `fx.blast` or `fx.smoke` in the
// asset table at an image; the only thing its layout has to agree with is `cols`.
const FX_FIRE = 0;
const FX_SMOKE = 1;
const FX_DEBRIS = 2;              // the third kind is bodies, and has no atlas
const FX_ATLAS = [-1, -1];        // the two textures, -1 when there is none
const FX_COLUMNS = [0, 0];        // cells across, read off the texture
const FX_CELL = [0, 0];           // one cell's edge in pixels, read the same way

// The margin each frame keeps inside its cell. A bilinear sample at a frame's edge
// reads that padding rather than the neighbouring frame, which is the whole reason
// it is there -- the alternative is `TEXTURE_FILTER_POINT` (M19a), and the atlases
// are deliberately *not* set to it: point-filtered smoke at four metres is visibly
// blocky.
const FX_PAD = 8;

// Value noise on integer mixing rather than `hash`/`vnoise2`: those are built on
// `Math.sin`, and this samples four corners per octave for every pixel of every
// frame at boot. The mixing is `trapNoise`'s, which is the same trade.
function fxHash(x, y, salt) {
    let h = (x * 374761393 + y * 668265263 + salt) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

function fxNoise(x, y, salt) {
    const xi = Math.floor(x);
    const yi = Math.floor(y);
    const xf = x - xi;
    const yf = y - yi;
    const u = xf * xf * (3 - 2 * xf);
    const v = yf * yf * (3 - 2 * yf);
    const a = fxHash(xi, yi, salt);
    const b = fxHash(xi + 1, yi, salt);
    const c = fxHash(xi, yi + 1, salt);
    const d = fxHash(xi + 1, yi + 1, salt);
    return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
}

// One noise field, 32x32, built once and sampled by index. A value-noise sample is
// four hashes and an interpolation, and the atlases are tens of thousands of pixels
// built on the *interpreter* path -- the boot frames of the harness and the headless
// host, where a loop only ever runs once and is never compiled. Sampling a tile is an
// array index and two masks instead, which is the same trade the pools make.
const FX_TILE = 32;
const FX_TILE_MASK = FX_TILE - 1;
const FX_NOISE_TILE = (function buildFxNoiseTile() {
    const out = [];
    for (let y = 0; y < FX_TILE; y++) {
        for (let x = 0; x < FX_TILE; x++) {
            out.push(0.55 * fxNoise(x * 0.17, y * 0.17, 11) +
                0.30 * fxNoise(x * 0.34, y * 0.34, 7) +
                0.15 * fxNoise(x * 0.69, y * 0.69, 5));
        }
    }
    return out;
})();

// The tile's value at (x, y), scrolled by the frame's own offsets so the fire licks
// rather than pulsing: the same field, read from a different corner each frame.
function fxTileAt(x, y, ox, oy) {
    return FX_NOISE_TILE[((x + ox) & FX_TILE_MASK) * FX_TILE + ((y + oy) & FX_TILE_MASK)];
}

// One atlas, as hex: `cols x cols` cells of `cell` pixels, each frame a step further
// through the effect than the one before. The puff grows along the strip, the noise
// scrolls a little with it so the fire licks rather than pulses, and the content
// stays inside `FX_PAD` -- which is what makes the padding real rather than
// decorative. Fire carries its own colour ramp (a white-hot core, orange at the
// rim) because it is drawn additively and the draw's tint is a single colour; smoke
// is grey and gets its whole shape from alpha.
function fxAtlasPixels(kind, cols, cell) {
    const frames = cols * cols;
    const radius = (cell - FX_PAD * 2) / cell;
    const fire = kind === FX_FIRE;
    // One entry per row, joined once at the end: a string grown a pixel at a time is
    // quadratic in the atlas's size, and this runs at boot on the interpreter too (the
    // headless host and the harness), where that is the difference between a moment
    // and a minute.
    const rows = [];
    for (let f = 0; f < frames; f++) {
        const t = frames > 1 ? f / (frames - 1) : 1;
        const rad = radius * (fire ? 0.42 + 0.58 * t : 0.30 + 0.70 * t);
        const gain = fire ? 2.2 - 0.45 * t : 1.8;
        const bias = fire ? 0.55 : 0.45;
        // Two scrolls of the same tile, so the puff's edge breaks up instead of
        // reading as one soft blob, and neither one repeats over the frame.
        const ox = Math.round(f * 5.3);
        const oy = Math.round(f * 2.7);
        for (let y = 0; y < cell; y++) {
            let row = "";
            for (let x = 0; x < cell; x++) {
                const u = (x + 0.5) / cell - 0.5;
                const v = (y + 0.5) / cell - 0.5;
                const edge = Math.sqrt(u * u + v * v) / 0.5 / rad;
                let a = 0;
                let r = 0, g = 0, b = 0;
                if (edge < 1) {
                    const n = 0.62 * fxTileAt(x >> 1, y >> 1, ox, oy) +
                        0.38 * fxTileAt(x, y, oy, ox);
                    let k = (1 - edge) * (n * gain - bias);
                    k = k < 0 ? 0 : (k > 1 ? 1 : k);
                    if (fire) {
                        const heat = 1 - edge;
                        a = k;
                        r = 255;
                        g = 120 + 130 * heat;
                        b = 30 + 120 * heat * heat;
                    } else {
                        a = k * 0.62;
                        r = 120;
                        g = 112;
                        b = 104;
                    }
                }
                row += HEX256[Math.round(r)] + HEX256[Math.round(g)] + HEX256[Math.round(b)] +
                    HEX256[Math.round(a * 255)];
            }
            rows.push(row);
        }
    }
    return rows.join("");
}

// The atlases, at boot: a mod's if the asset table has one, the generated grid
// otherwise.
function makeFxTextures() {
    fxAtlasLoad(FX_FIRE, "fx.blast", "blast");
    fxAtlasLoad(FX_SMOKE, "fx.smoke", "smoke");
    makeCraterTexture();
}

// One atlas, from the asset table or the generator, and the grid read back off it.
// `cols` is the tuning's, because a grid cannot be guessed from an image; the cell
// size is the texture's, because that is arithmetic -- `textureWidth / cols` -- and
// so a mod's atlas declares one number and not two.
function fxAtlasLoad(kind, slot, key) {
    const cfg = TUNING.explosions.fx[key];
    const cols = Math.max(1, Math.round(cfg.cols));
    let tex = -1;
    const names = assetList(slot);
    if (names.length > 0 && typeof rl.loadTexture === "function") tex = rl.loadTexture(names[0]);
    if (tex < 0) tex = fxAtlasMake(kind, cols, Math.max(8, Math.round(cfg.cell)));
    FX_ATLAS[kind] = tex;
    FX_COLUMNS[kind] = cols;
    const width = tex >= 0 && typeof rl.textureWidth === "function" ? rl.textureWidth(tex) : 0;
    FX_CELL[kind] = width > 0 ? Math.round(width / cols) : Math.max(8, Math.round(cfg.cell));
}

// The generated atlas, through `rl.makeTexture`, which decodes plain hex and sets
// the texture to point filtering. Bilinear is what the padding is for, so it is
// asked for here rather than left as whatever the loader did.
function fxAtlasMake(kind, cols, cell) {
    if (typeof rl.makeTexture !== "function") return -1;
    const size = cols * cell;
    const tex = rl.makeTexture(size, size, fxAtlasPixels(kind, cols, cell));
    if (tex >= 0 && typeof rl.setTextureFilter === "function" &&
        typeof rl.TEXTURE_FILTER_BILINEAR === "number") {
        rl.setTextureFilter(tex, rl.TEXTURE_FILTER_BILINEAR);
    }
    return tex;
}

// ---- the crater decal (M19f) -------------------------------------------------
//
// A crater's scorch, drawn *on the ground* rather than as a camera-facing billboard.
// That is the whole reason `drawQuad3D` exists, and it is a fill-rate argument, not
// an aesthetic one: a flat disc of the same diameter covers a fraction of the pixels
// a billboard does from a low camera, and the interim M19d shipped -- the mine's own
// puff, scaled to the dish -- was the most expensive thing in this system.
let craterTex = -1;
let craterTexW = 0;
let craterTexH = 0;

function makeCraterTexture() {
    const names = assetList("fx.crater");
    if (names.length > 0 && typeof rl.loadTexture === "function") craterTex = rl.loadTexture(names[0]);
    if (craterTex >= 0) {
        craterTexW = typeof rl.textureWidth === "function" ? rl.textureWidth(craterTex) : 0;
        craterTexH = typeof rl.textureHeight === "function" ? rl.textureHeight(craterTex) : 0;
        if (craterTexW > 0 && craterTexH > 0) return;
        craterTex = -1;
    }
    if (typeof rl.makeTexture !== "function") return;
    const N = 64;
    craterTexW = N;
    craterTexH = N;
    // Row-wise, joined once: see `fxAtlasPixels` for why.
    const rows = [];
    for (let y = 0; y < N; y++) {
        let row = "";
        for (let x = 0; x < N; x++) {
            const u = (x + 0.5) / N - 0.5;
            const v = (y + 0.5) / N - 0.5;
            const d = Math.sqrt(u * u + v * v) / 0.5;
            let a = 0, r = 0, g = 0, b = 0;
            if (d < 1) {
                const n = 0.62 * fxTileAt(x >> 1, y >> 1, 7, 3) + 0.38 * fxTileAt(x, y, 13, 19);
                let k = (1 - d) * (n * 2.0 - 0.5);
                k = k < 0 ? 0 : (k > 1 ? 1 : k);
                a = k * 0.95;
                // Char in the middle, the ochre of turned earth at the rim, and
                // enough mottling that it does not read as a printed disc.
                const shade = 0.6 + 0.7 * n;
                r = (20 + 84 * d) * shade;
                g = (15 + 58 * d) * shade;
                b = (11 + 34 * d) * shade;
            }
            row += HEX256[Math.round(r)] + HEX256[Math.round(g)] + HEX256[Math.round(b)] +
                HEX256[Math.round(a * 255)];
        }
        rows.push(row);
    }
    craterTex = rl.makeTexture(N, N, rows.join(""));
    if (craterTex >= 0 && typeof rl.setTextureFilter === "function" &&
        typeof rl.TEXTURE_FILTER_BILINEAR === "number") {
        rl.setTextureFilter(craterTex, rl.TEXTURE_FILTER_BILINEAR);
    }
}

// The decal's basis on the ground, yawed by the crater's own seed. `drawQuad3D`'s
// one contract is the winding -- a quad is visible from the side `right x up` points
// to -- and this basis keeps that cross product at (0, 1, 0) whatever the yaw, which
// is what makes a decal on the ground visible from above rather than culled.
function craterBasis(seed) {
    const a = hash(seed * 11.3) * 6.283185307179586;
    const c = Math.cos(a);
    const s = Math.sin(a);
    return { right: [c, 0, -s], up: [-s, 0, -c] };
}

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

// Whether the *core* devices are in the field at all (M19g). A mod that brings its own
// devices can turn these off with `goats.explosions.armed(false)`, and the request is
// held per mod so unloading one hands the field back. What is gated is the derivation
// (`mineArmed`/`trapAt`) rather than the book-keeping: a mod's own devices are its own
// business, and a bang reported from the wire still lands whatever this says.
const CORE_OFF = new Set();

// `goats.explosions.armed(on)` (M19g). Called with no argument it *asks*; called with
// `false` it takes the core devices out of the field, and `true` hands them back. The
// request is the mod's, so two mods cannot cancel each other by load order, and the
// return is whether the change took (which is what a console or a script reads).
function modCoreArmed(id, on) {
    if (on === undefined) return CORE_OFF.size === 0;
    if (on) CORE_OFF.delete(id);
    else CORE_OFF.add(id);
    return true;
}

// Whether cell (cx, cz) holds an armed mine *now*: the derived field, minus the
// mines that have gone off, plus the replacements that have moved in.
function mineArmed(cx, cz) {
    if (CORE_OFF.size > 0) return false;
    const key = tuftKey(cx, cz);
    if (SPENT.has(key)) return false;
    return MOVED.has(key) || mineAt(cx, cz);
}

// Whether the tuft in cell (cx, cz) is trapped now, on the same rule. A tuft exists
// only where the meadow's own hash says so, so this is only ever asked about a tuft
// that is there -- `nearestTuft` is what finds those, and it is also what carries the
// `trappedOnly` filter this is used through.
function trapAt(cx, cz) {
    if (CORE_OFF.size > 0) return false;
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
    // The click between the trigger and the bang (M19g), at the device rather than at the
    // goat: a mine underfoot ticks, and one the goat walks away from ticks behind it.
    playTrigger(kind, x, z);
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
    // What this bang touched, for the `blast` event a mod may be listening to (M19g).
    let took = 0;            // damage this goat took; 0 when it was outside the radius
    let touched = 0;         // bots inside the radius
    let killed = 0;          // ...and how many of those it killed
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
        took = e.blast.damage * falloff * falloff;
        stats.health = Math.max(e.blast.healthFloor, stats.health - took);
        // The player's own reaction (M19f): the knock and the flash are this process's,
        // and both are scaled by what the blast actually took.
        if (took > 0) hurtBy(took);
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
            touched += 1;
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
                killed += 1;
                continue;
            }
            const bu = flingDirection(bx, bz, bd, seed);
            startBotFling(b, bu.x * e.blast.push * bfalloff, bu.z * e.blast.push * bfalloff,
                e.blast.lift * bfalloff);
        }
    }
    spawnBlastFx(x, z, seed);
    // And its light, which is the part the *world* rather than the sprite reacts to.
    flashAt(x, z, seed);
    // ...and the knock, which is the part the player does. It is outside the damage
    // radius on purpose: a bang just past the goat's feet is a shove with no bruise.
    blastShake(x, z, seed);
    // Heard wherever the goat is, in or out of the radius (audio.js).
    playBlast(x, z, depth);
    // Told to the mods (M19g), *after* the world has taken it: a handler sees the
    // damage, the herd and the hole as they stand, which is what makes "add scorch,
    // a scoreboard, a smell of gunpowder" a callback rather than a re-implementation.
    // It fires for a mod's own blast too -- `goats.explosions.blast` comes through
    // here -- so a mod cannot tell its own bangs apart from the core ones by the event
    // alone, which is deliberate: the event is about the bang, not about who made it.
    modEmit("blast", {
        kind: kind,
        x: x,
        z: z,
        seed: seed,
        radius: r,
        depth: depth,
        player: took,
        bots: touched,
        killed: killed,
    });
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
    const fx = TUNING.explosions.fx;
    const ground = terrainHeight(x, z);
    fxSpawn(FX_FIRE, x, ground + 0.2, z, seed, fx.blast.time, fx.blast.scale, seed);
    // Two plumes: the close one is thicker and lives the tuning's `time`, the far one
    // is smaller, slower and longer, which is what gives the column depth rather than
    // one flat puff. The phases are the same seed turned differently, so a bang looks
    // the same to everyone who sees it.
    fxSpawn(FX_SMOKE, x + 0.35, ground, z - 0.25, seed + 1.7, fx.smoke.time, fx.smoke.scale,
        seed * 1.3);
    fxSpawn(FX_SMOKE, x - 0.45, ground, z + 0.15, seed + 3.1, fx.smoke.time * 1.25,
        fx.smoke.scale * 0.62, seed * 0.7);
    spawnDebrisFx(x, ground, z, seed);
}

// One instance of an effect. `phase` becomes the frame it starts on, so two plumes
// of one bang -- and two bangs of the same age -- are not showing the same picture.
function fxSpawn(kind, x, y, z, seed, dur, scale, phase) {
    const at = fxTake();
    if (at < 0) return -1;
    if (at + 1 > fxTop) fxTop = at + 1;
    const slot = FX[at];
    slot.live = true;
    slot.kind = kind;
    slot.x = x;
    slot.y = y;
    slot.z = z;
    slot.age = 0;
    slot.dur = dur > 0 ? dur : 0.01;
    slot.seed = seed;
    slot.scale = scale * (0.8 + hash(seed) * 0.5);
    slot.spin = phase - Math.floor(phase);
    slot.n = 0;
    return at;
}

// The grit a bang throws: cubes on streams drawn here and once. The bodies are the
// exception to the billboards -- grit thrown outward reads as *things* -- and they
// cost a cube each, so the count is the tuning's and the pool has room for it.
function spawnDebrisFx(x, ground, z, seed) {
    const d = TUNING.explosions.fx.debris;
    const count = clamp(Math.round(d.count), 0, DEBRIS_MAX);
    if (count <= 0 || d.time <= 0) return;
    const at = fxSpawn(FX_DEBRIS, x, ground, z, seed, d.time, 0, 0);
    if (at < 0) return;
    const slot = FX[at];
    slot.n = count;
    for (let i = 0; i < count; i++) {
        const a = hash(seed * 3.1 + i * 1.7) * 6.283185307179586;
        const speed = d.speed * (0.35 + hash(seed * 5.7 + i * 2.3) * 0.9);
        slot.bx[i] = x;
        slot.by[i] = ground + 0.25;
        slot.bz[i] = z;
        slot.vx[i] = Math.cos(a) * speed;
        slot.vz[i] = Math.sin(a) * speed;
        slot.vy[i] = d.up * (0.5 + hash(seed * 7.3 + i * 3.1) * 0.9);
    }
}

// Which cell of an atlas an instance is on: its age through its life, plus the phase
// it was born with, cut into frames. Exposed (below) as `sceneFxFrame`, because a
// grid that is one cell out is a picture of the neighbouring frame -- a check, not a
// crash.
function fxFrame(kind, t, spin) {
    const cols = FX_COLUMNS[kind];
    const frames = cols * cols;
    if (frames <= 1) return 0;
    let f = Math.floor(t * (frames - 1) + spin);
    if (f < 0) f = 0;
    if (f >= frames) f = frames - 1;
    return f;
}

// The frame an instance of `kind` shows at `t` through its life, as a source
// rectangle: the arithmetic the draw uses, for the console and the tests.
function sceneFxFrame(kind, t) {
    const cols = FX_COLUMNS[kind] | 0;
    const cell = FX_CELL[kind] | 0;
    if (cols <= 0 || cell <= 0) return { cols: 0, cell: 0, frames: 0, frame: 0, sx: 0, sy: 0 };
    const f = fxFrame(kind, t, 0);
    return {
        cols: cols,
        cell: cell,
        frames: cols * cols,
        frame: f,
        sx: (f % cols) * cell,
        sy: Math.floor(f / cols) * cell,
    };
}

// The knock a bang gives the camera: strongest at its own centre and tending to
// nothing rather than reaching it, which is what makes the same bang read differently
// at two metres and at thirty. The direction is the blast's own -- the camera is
// pushed *away* -- and a bang dead on the goat has no direction to give, so it takes
// the seed's.
function blastShake(x, z, seed) {
    const cfg = TUNING.explosions.shake;
    if (cfg.energy <= 0) return;
    const dx = goat.px - x;
    const dz = goat.pz - z;
    const d2 = dx * dx + dz * dz;
    const r2 = cfg.range * cfg.range;
    const d = Math.sqrt(d2);
    if (d > 0.01) {
        shakeDirX = dx / d;
        shakeDirZ = dz / d;
    } else {
        const a = hash(seed * 5.3) * 6.283185307179586;
        shakeDirX = Math.cos(a);
        shakeDirZ = Math.sin(a);
    }
    const energy = cfg.energy * (r2 / (r2 + d2)) * (0.85 + hash(seed * 1.9) * 0.3);
    // A fresh, harder bang takes the knock over; a distant one landing on top of a
    // near one does not cut it short. The phase restarts a quarter turn in, which is
    // the swing, so the first frame of the shake is the shove outward.
    if (energy > shakeEnergy) {
        shakeEnergy = energy;
        shakePhase = 1.5;
    }
}

// Where the camera and its target are moved to this frame, in metres. The vertical is
// a smaller and faster oscillation of the same phase, which is what keeps the knock
// from reading as a slide.
function shakeOffsetX() { return shakeEnergy * shakeDirX * Math.sin(shakePhase); }
function shakeOffsetY() { return shakeEnergy * 0.55 * Math.sin(shakePhase * 1.7 + 1.1); }
function shakeOffsetZ() { return shakeEnergy * shakeDirZ * Math.sin(shakePhase); }

// The HUD's flash: how much of itself a hit of `damage` is worth. The strongest
// unrecovered hit wins, so a second bang cannot make a bruise look like a scratch.
function hurtBy(damage) {
    const cfg = TUNING.explosions.pulse;
    const k = cfg.damage > 0 ? damage / cfg.damage : 0;
    if (k > hurtPulse) hurtPulse = k > 1 ? 1 : k;
}

// The red frame, for a beat after a hit. A border rather than a screenful of tint on
// purpose: it is four small rectangles rather than every pixel on the screen, and it
// reads the same.
function drawDamagePulse() {
    if (hurtPulse <= 0 || typeof rl.drawRectangle !== "function") return;
    const a = hurtPulse > 1 ? 1 : hurtPulse;
    const band = Math.round(24 + 46 * a);
    const tint = rl.color(150, 20, 16, Math.round(120 * a));
    rl.drawRectangle(0, 0, screenW, band, tint);
    rl.drawRectangle(0, screenH - band, screenW, band, tint);
    rl.drawRectangle(0, 0, band, screenH, tint);
    rl.drawRectangle(screenW - band, 0, band, screenH, tint);
}
// A slot for a fresh flash, or -1: a free one, else the oldest (the dimmest, since
// every one of them is fading). Four lights is a fixed cost the pool pays once.
function flashTake() {
    let oldest = -1;
    for (let i = 0; i < FLASH_CAPACITY; i++) {
        if (!FLASH[i].live) return i;
        if (oldest < 0 || FLASH[i].age > FLASH[oldest].age) oldest = i;
    }
    return oldest;
}

// The light a bang throws, over the fireball. The peak and the life both jitter a
// little off the seed so that two bangs in a row are not the same flash, the way the
// bang itself is not the same bang (audio.js picks it off the same seed).
function flashAt(x, z, seed) {
    const f = TUNING.explosions.flash;
    if (f.energy <= 0 || f.time <= 0) return;
    const at = flashTake();
    if (at < 0) return;
    if (at + 1 > flashTop) flashTop = at + 1;
    const slot = FLASH[at];
    slot.live = true;
    slot.x = x;
    slot.y = terrainHeight(x, z) + f.lift;
    slot.z = z;
    slot.age = 0;
    slot.dur = f.time * (0.9 + hash(seed * 1.7) * 0.2);
    slot.peak = f.energy * (0.85 + hash(seed * 2.9 + 0.7) * 0.3);
}

// Age the flashes and hand the strongest to the lit shader. Runs whether or not the
// system is on, for the reason the craters heal whether or not it is: `enabled 0` is
// a frame-cost bisect, and a bisect that leaves a light burning is not a bisect.
//
// The decay is squared, so the flash reads as a hit and not as a lamp being turned
// down; the last frame of the last flash is what writes zero, and once the last one
// is out the shader is left alone entirely.
function updateFlashes(dt) {
    let best = 0;
    let bx = 0, by = 0, bz = 0;
    for (let i = 0; i < flashTop; i++) {
        const f = FLASH[i];
        if (!f.live) continue;
        f.age += dt;
        if (f.age >= f.dur) {
            f.live = false;
            continue;
        }
        const fade = 1 - f.age / f.dur;
        const energy = f.peak * fade * fade;
        if (energy > best) {
            best = energy;
            bx = f.x;
            by = f.y;
            bz = f.z;
        }
    }
    while (flashTop > 0 && !FLASH[flashTop - 1].live) flashTop -= 1;
    if (best > 0 || flashEnergy > 0) {
        flashEnergy = best;
        setBlastLight(bx, by, bz, best);
    }
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
    // `enabled 0` is a frame-cost bisect, not a way to leave a hole in the world. The
    // bang's light is the same argument.
    if (CRATERS.length > 0) updateCraters(dt);
    if (flashTop > 0 || flashEnergy > 0) updateFlashes(dt);
    // The player's knock and the HUD's flash, on the same rule: they are about a bang
    // that already happened, so switching the system off for a bisect must not leave
    // the camera vibrating or the screen red.
    if (shakeEnergy > 0) {
        shakePhase += dt * TUNING.explosions.shake.speed;
        shakeEnergy -= dt * TUNING.explosions.shake.decay;
        if (shakeEnergy < 0) shakeEnergy = 0;
    }
    if (hurtPulse > 0) {
        hurtPulse -= dt * TUNING.explosions.pulse.decay;
        if (hurtPulse < 0) hurtPulse = 0;
    }
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

// The look of a bang (M19f): the flipbook billboards, the hot core and the grit,
// over the world it happened in. Drawn inside the 3D pass, after the goats and the
// grass, so smoke reads over what it hit rather than behind it.
//
// The ladder is the point of the shader/mesh fallbacks elsewhere: no atlas (a mod
// replaced the slot with something that will not decode, or there is no image path)
// falls back to the weather's own puff, and no texture at all to an untextured
// primitive. Each rung is forced by the harness, and each is a picture rather than
// an error.
function drawExplosions() {
    if (TUNING.explosions.enabled <= 0) return;
    const e = TUNING.explosions;
    const tell = e.mine.tell;
    if (tell > 0 && cloudTex >= 0) drawMineTells(tell);
    // The scorch: a decal per crater, yawed by its own seed and tinted as it heals.
    // The range is what keeps a field of them from being fill rate nobody can read --
    // and `crater.scorch 0` is the bisect, which is what M19d shipped for exactly
    // that. Without the decal texture the interim puff is still there: it is a
    // billboard, so it costs more, and it is a picture of the same thing.
    if (e.crater.scorch > 0) {
        const range = e.crater.scorchRange;
        const range2 = range * range;
        for (let i = 0; i < CRATERS.length; i++) {
            const c = CRATERS[i];
            const dx = c.x - goat.px;
            const dz = c.z - goat.pz;
            if (dx * dx + dz * dz > range2) continue;
            const fade = 1 - c.age / c.heal;
            const alpha = Math.round(170 * fade * fade);
            if (alpha <= 0) continue;
            const y = terrainHeight(c.x, c.z) + 0.03;
            if (craterTex >= 0 && craterTexW > 0 && craterTexH > 0) {
                const b = craterBasis(c.seed);
                rl.drawQuad3D(craterTex, 0, 0, craterTexW, craterTexH, c.x, y, c.z,
                    b.right[0], b.right[1], b.right[2],
                    b.up[0], b.up[1], b.up[2],
                    c.r * 2.4, c.r * 2.4, rl.color(255, 250, 240, alpha));
            } else if (cloudTex >= 0) {
                rl.drawBillboard(cloudTex, c.x, y, c.z, c.r * 2.2,
                    rl.color(44, 36, 28, alpha));
            }
        }
    }
    if (fxTop === 0) return;
    // Smoke and grit first, the fire over them: the fire is what lights the smoke, so
    // that is also the order that reads. The blend change is once for the whole pool
    // rather than once per instance.
    let fire = 0;
    for (let i = 0; i < fxTop; i++) {
        const slot = FX[i];
        if (!slot.live) continue;
        if (slot.kind === FX_FIRE) {
            fire += 1;
        } else if (slot.kind === FX_SMOKE) {
            drawFxSmoke(slot);
        } else {
            drawFxDebris(slot);
        }
    }
    if (fire > 0 && typeof rl.beginBlendMode === "function") {
        rl.beginBlendMode(rl.BLEND_ADDITIVE);
        for (let i = 0; i < fxTop; i++) {
            if (FX[i].live && FX[i].kind === FX_FIRE) drawFxFire(FX[i]);
        }
        rl.endBlendMode();
    }
}

// The fireball: one flipbook frame, additive, rising as it burns out, with a small
// sphere under it for the core -- the flames are a picture, and the sphere is the
// thing that is bright.
function drawFxFire(slot) {
    const t = slot.age / slot.dur;
    const fade = 1 - t;
    const alpha = Math.round(255 * fade * fade);
    if (alpha <= 0) return;
    const size = slot.scale * (0.62 + 0.55 * t);
    const y = slot.y + TUNING.explosions.fx.blast.lift * t;
    const cols = FX_COLUMNS[FX_FIRE];
    const cell = FX_CELL[FX_FIRE];
    if (FX_ATLAS[FX_FIRE] >= 0 && cols > 0 && cell > 0) {
        const f = fxFrame(FX_FIRE, t, slot.spin);
        rl.drawBillboardRec(FX_ATLAS[FX_FIRE], (f % cols) * cell, Math.floor(f / cols) * cell,
            cell, cell, slot.x, y, slot.z, size, size,
            rl.color(255, 214, 168, alpha));
    } else if (cloudTex >= 0) {
        // No atlas: the weather's own puff, which is what M19b shipped.
        rl.drawBillboard(cloudTex, slot.x, y, slot.z, size * 0.68,
            rl.color(255, 206, 140, alpha));
    } else {
        // No texture at all: a hot cube. There is nothing to sample, so the shape is
        // the message -- the flat-slab rung of the ladder.
        rl.drawCube(slot.x, y + size * 0.5, slot.z, size, size, size,
            rl.color(255, 150, 60, 255));
    }
    if (t < 0.55) {
        const core = slot.scale * (0.10 + 0.28 * t);
        rl.drawSphereEx(slot.x, y + core * 0.6, slot.z, core, 5, 6,
            rl.color(255, 226, 180, alpha));
    }
}

// One smoke plume, alpha-blended and depth-tested. Two of these are spawned per
// bang, which is what gives the column depth; the tint carries the fade, since the
// atlas is the same grey all the way through.
function drawFxSmoke(slot) {
    const t = slot.age / slot.dur;
    const fade = 1 - t;
    const alpha = Math.round(210 * fade * fade);
    if (alpha <= 0) return;
    const size = slot.scale * (0.55 + 0.85 * t);
    const y = slot.y + TUNING.explosions.fx.smoke.lift * t;
    const cols = FX_COLUMNS[FX_SMOKE];
    const cell = FX_CELL[FX_SMOKE];
    if (FX_ATLAS[FX_SMOKE] >= 0 && cols > 0 && cell > 0) {
        const f = fxFrame(FX_SMOKE, t, slot.spin);
        rl.drawBillboardRec(FX_ATLAS[FX_SMOKE], (f % cols) * cell, Math.floor(f / cols) * cell,
            cell, cell, slot.x, y, slot.z, size, size,
            rl.color(196, 182, 166, alpha));
    } else if (cloudTex >= 0) {
        rl.drawBillboard(cloudTex, slot.x, y, slot.z, size * 0.7,
            rl.color(120, 112, 104, alpha));
    } else {
        rl.drawCube(slot.x, y, slot.z, size * 0.5, size * 0.5, size * 0.5,
            rl.color(70, 66, 62, 255));
    }
}

// The grit: cubes on the streams the bang drew for them, thrown outward and up and
// falling under a gravity of its own. They are gone in under a second, and the last
// of the fall is hidden by the ground rather than stopped by it -- a body that has
// gone under is behind an opaque surface, which is cheaper than a collision test.
function drawFxDebris(slot) {
    const d = TUNING.explosions.fx.debris;
    const t = slot.age;
    const n = slot.n;
    const size = d.size;
    for (let i = 0; i < n; i++) {
        rl.drawCube(slot.bx[i] + slot.vx[i] * t,
            slot.by[i] + slot.vy[i] * t - 0.5 * d.gravity * t * t,
            slot.bz[i] + slot.vz[i] * t,
            size, size, size, rl.color(64, 54, 42, 255));
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
            // A mine sits at its cell's centre, so that centre *is* its position -- which
            // is why filtering the cell by this distance is right for a mine.
            const mx = cx * 2 + 1;
            const mz = cz * 2 + 1;
            const dx = mx - x;
            const dz = mz - z;
            if (dx * dx + dz * dz <= range2 && mineArmed(cx, cz)) {
                const key = tuftKey(cx, cz);
                out.mines.push({
                    x: mx, z: mz, key: key, dist: Math.sqrt(dx * dx + dz * dz),
                    moved: MOVED.has(key),
                });
            }
            if (!trapAt(cx, cz)) continue;
            const key = tuftKey(cx, cz);
            if (EATEN.has(key)) continue;
            // A trapped tuft is reported at the tuft -- and *judged* at the tuft. It sits
            // at the cell's even corner (up to 1.4 m from the centre above) plus its own
            // jitter, so a cell the centre keeps out of range can hold a tuft that is
            // right under the query. Filtering the cell by the centre hid every tuft
            // jittered away from the middle: a query from on top of a trap came back
            // empty, which is the one thing its own `dist` was there to say. (M19d's
            // trap, in the one place it survived -- see *The mechanics* in ROADMAP.md.)
            const t = tuftInCell(cx, cz);
            if (t === null) continue;
            const tdx = t.x - x;
            const tdz = t.z - z;
            if (tdx * tdx + tdz * tdz > range2) continue;
            out.traps.push({
                x: t.x, z: t.z, key: key,
                dist: Math.sqrt(tdx * tdx + tdz * tdz),
                moved: TRAP_MOVED.has(key),
            });
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
        // The light as the shader has it, so a test can watch it come up on a bang
        // and go out `flash.time` later without a GPU to read the uniform back from.
        flash: flashEnergy,
        // ...and the player's own two reactions, which are read the same way.
        shake: shakeEnergy,
        hurt: hurtPulse,
        // Whether the core devices are in the field at all (M19g): false while a mod has
        // asked for its own devices to be the only ones.
        armed: CORE_OFF.size === 0,
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

// ---- water (M20a) ---------------------------------------------------------
//
// Rain does not run downhill here. A pool's surface is *level*, so the model is
// hydrostatic: one priority-flood pass over the terrain grid gives `W_F`, the spill
// level of every vertex's basin, and the water then sits where
//
//     depth(x, z) = max(0, min(W, W_F) - terrainHeight(x, z))
//
// That one expression is the whole of "water pools in the lowest parts". A cell
// above the table is dry; a basin fills up to the table; two basins merge when the
// table passes their shared saddle; and a basin stops rising at its spill level and
// overflows instead of climbing. A crater (explosions.js) is just another basin, so
// a fresh hole becomes a puddle for free.
//
// The level `W` is a *pure function of the weather's `rainAmount`*, not an integral
// over time, and that is deliberate: it is the whole reason water needs nothing on
// the wire. An accumulator would integrate a rate over each peer's own frame times
// and drift apart; `rainAmount` is already seeded, eased and mirrored to clients
// (weather.js), so a host and a client, an offline session and the harness all put
// the same water in the same hollows with no field to send.
//
// M20a is the field and the fill only -- no draw. `sceneWater()` is the seam the
// harness reads and a mod will; the surface mesh, the waves and the reflections are
// M20b to M20e.

// The fill runs on the terrain's own grid, because that is where the ground it is a
// function of lives: `W_F` is indexed exactly as `T_H` (world.js). The arrays are the
// grid's, allocated once, like the terrain's.
const WATER_N = T_N;                    // vertices per side
const WATER_CELL = TERRAIN_CELL;        // world units per cell
const WATER_HALF = T_HALF;              // half the field's width
const W_F = new Array(WATER_N * WATER_N);       // the spill (filled) height per vertex
const W_SEEN = new Array(WATER_N * WATER_N);    // the flood's visited flags
const W_HEAP = new Array(WATER_N * WATER_N);    // the flood's min-heap, of vertex indices

let waterHeapN = 0;
let waterReady = false;     // the fill has run at least once
let waterLevel = 0;         // `W`, in metres
let waterLevelMin = 0;      // the lowest ground in the field
let waterLevelMax = 0;      // the highest spill level in the field
let waterForce = -1;        // `flood <h>`: a level set by hand; -1 = derive from rain

// ---- the priority flood ---------------------------------------------------
//
// Barnes et al.'s fill: seed the window's rim at the rim's own height, then pop the
// lowest filled vertex and relax its neighbours to the higher of their own ground
// and the water that reached them. Seeding the rim at *its own height* rather than
// at infinity gives the field an outlet, so water that reaches the edge leaves
// instead of stacking against a wall -- which is what keeps a lake near the window's
// edge honest as the window follows the goat.
//
// The heap and the relax step are small functions of their own, with the arrays
// passed in: the engine's JIT compiles a small parameter-only body and interprets a
// large one (PERF.md section 7.2), and the flood calls these a few thousand times.

function waterHeapPush(heap, key, i) {
    let c = waterHeapN++;
    heap[c] = i;
    while (c > 0) {
        const p = (c - 1) >> 1;
        if (key[heap[p]] <= key[heap[c]]) break;
        const t = heap[p];
        heap[p] = heap[c];
        heap[c] = t;
        c = p;
    }
}

function waterHeapPop(heap, key) {
    const top = heap[0];
    const n = --waterHeapN;
    heap[0] = heap[n];
    let c = 0;
    for (;;) {
        const l = c + c + 1;
        if (l >= n) break;
        const r = l + 1;
        let m = c;
        if (key[heap[l]] < key[heap[m]]) m = l;
        if (r < n && key[heap[r]] < key[heap[m]]) m = r;
        if (m === c) break;
        const t = heap[m];
        heap[m] = heap[c];
        heap[c] = t;
        c = m;
    }
    return top;
}

// Relax one neighbour: its filled height is the higher of its own ground and the
// water that arrived. The `seen` flag is what keeps the flood to one visit a vertex.
function waterVisit(h, f, seen, heap, k, level) {
    if (seen[k] === 1) return;
    seen[k] = 1;
    const ground = h[k];
    const next = ground > level ? ground : level;
    f[k] = next;
    waterHeapPush(heap, f, k);
}

function waterFill() {
    const n = WATER_N;
    const last = n - 1;
    const count = n * n;
    const h = T_H;
    const f = W_F;
    const seen = W_SEEN;
    const heap = W_HEAP;
    waterHeapN = 0;
    for (let k = 0; k < count; k++) {
        f[k] = h[k];
        seen[k] = 0;
    }
    // The rim, at its own height. The `seen` guard covers the corners, which the two
    // tests would both claim.
    for (let j = 0; j < n; j++) {
        for (let i = 0; i < n; i++) {
            if (i !== 0 && i !== last && j !== 0 && j !== last) continue;
            const k = j * n + i;
            if (seen[k] === 1) continue;
            seen[k] = 1;
            waterHeapPush(heap, f, k);
        }
    }
    while (waterHeapN > 0) {
        const k = waterHeapPop(heap, f);
        const level = f[k];
        const i = k % n;
        const j = (k - i) / n;
        if (i > 0) waterVisit(h, f, seen, heap, k - 1, level);
        if (i < last) waterVisit(h, f, seen, heap, k + 1, level);
        if (j > 0) waterVisit(h, f, seen, heap, k - n, level);
        if (j < last) waterVisit(h, f, seen, heap, k + n, level);
    }
}

// ---- the field, from the ground -------------------------------------------

// Rebuild the field from the ground. Called wherever the terrain mesh is rebuilt
// (world.js `terrainBuildRects`) -- a step to a new anchor, or a crater dinting the
// grid -- because the fill is a function of the heights and a crater is a new basin.
function waterRebuild() {
    if (!TERRAIN_MESH_OK) {
        waterReady = false;
        return;
    }
    waterFill();
    const count = WATER_N * WATER_N;
    // The range the table walks: from the lowest *ground* -- so a dry spell is exactly
    // dry, the lowest vertex reading depth 0 and every other cell less -- to the
    // highest *spill*, so the heaviest rain fills every basin to its rim.
    let lo = T_H[0];
    let hi = W_F[0];
    for (let k = 1; k < count; k++) {
        const g = T_H[k];
        if (g < lo) lo = g;
        const f = W_F[k];
        if (f > hi) hi = f;
    }
    waterLevelMin = lo;
    waterLevelMax = hi;
    waterReady = true;
    waterUpdate();
}

// The level for this frame, from the weather alone (see the header). `fill` is how
// much of the basins' spill range the heaviest rain reaches, so the deepest hollows
// hold the first water and the shallow ones only fill in a downpour: the level rises
// monotonically from the lowest ground to the highest spill.
function waterUpdate() {
    if (!waterReady) return;
    const t = TUNING.water;
    if (t.enabled === 0) {
        waterLevel = waterLevelMin;
        return;
    }
    if (waterForce >= 0) {
        waterLevel = waterForce;
        return;
    }
    let wetted = (rainAmount - t.seep) / (1 - t.seep);
    if (wetted < 0) wetted = 0;
    if (wetted > 1) wetted = 1;
    waterLevel = waterLevelMin + wetted * t.fill * (waterLevelMax - waterLevelMin);
}

// The `flood <h>` debug override, for a demo or a screenshot review. Anything below
// zero hands the level back to the weather, the way `C` hands the weather back to the
// seeded machine.
function waterSetForce(level) {
    waterForce = level < 0 ? -1 : level;
    waterUpdate();
}

// ---- reading it -----------------------------------------------------------

// One vertex's depth, from the table and the spill level. Capped at
// `TUNING.water.maxDepth`: v1 keeps pools wading depth (M20g lifts it for swimming).
function waterVertexDepth(k) {
    const surface = W_F[k] < waterLevel ? W_F[k] : waterLevel;
    const d = surface - T_H[k];
    if (d <= 0) return 0;
    const cap = TUNING.water.maxDepth;
    return d > cap ? cap : d;
}

// The water depth at a world point, bilinear over the grid so a wading goat reads a
// smooth number rather than whichever vertex it happens to stand nearest. Off the
// built grid there is no water: the field only spans +/-`WATER_HALF` and follows the
// goat, exactly as the terrain mesh does.
function waterDepthAt(x, z) {
    if (!waterReady || TUNING.water.enabled === 0) return 0;
    const fx = (x - (terrainAnchorX - WATER_HALF)) / WATER_CELL;
    const fz = (z - (terrainAnchorZ - WATER_HALF)) / WATER_CELL;
    const i = Math.floor(fx);
    const j = Math.floor(fz);
    if (i < 0 || j < 0 || i >= WATER_N - 1 || j >= WATER_N - 1) return 0;
    const u = fx - i;
    const v = fz - j;
    const k = j * WATER_N + i;
    const d00 = waterVertexDepth(k);
    const d10 = waterVertexDepth(k + 1);
    const d01 = waterVertexDepth(k + WATER_N);
    const d11 = waterVertexDepth(k + WATER_N + 1);
    const top = d00 + (d10 - d00) * u;
    const bot = d01 + (d11 - d01) * u;
    return top + (bot - top) * v;
}

// The seam: the level, how much of the field it covers, where the deepest point is,
// and how deep it is under the goat. A read a mod and the console both want, and the
// one the harness asserts against -- so it reports the numbers the frame uses rather
// than a second derivation of them.
function sceneWater() {
    const count = WATER_N * WATER_N;
    const area = WATER_CELL * WATER_CELL;
    const cap = TUNING.water.maxDepth;
    const level = waterLevel;
    let wet = 0;
    let volume = 0;
    let deepest = 0;
    let di = 0;
    let dj = 0;
    for (let k = 0; k < count; k++) {
        const surface = W_F[k] < level ? W_F[k] : level;
        let d = surface - T_H[k];
        if (d <= 0) continue;
        if (d > cap) d = cap;
        wet++;
        volume += d * area;
        if (d > deepest) {
            deepest = d;
            const i = k % WATER_N;
            di = i;
            dj = (k - i) / WATER_N;
        }
    }
    const x0 = terrainAnchorX - WATER_HALF;
    const z0 = terrainAnchorZ - WATER_HALF;
    return {
        level: netRound3(isFinite(level) ? level : 0),
        enabled: TUNING.water.enabled !== 0,
        forced: waterForce >= 0,
        wet: wet,
        cells: count,
        volume: netRound3(volume),
        deepest: netRound3(deepest),
        deepX: netRound3(x0 + di * WATER_CELL),
        deepZ: netRound3(z0 + dj * WATER_CELL),
        goatDepth: netRound3(waterDepthAt(goat.px, goat.pz)),
        low: netRound3(waterLevelMin),
        high: netRound3(waterLevelMax),
    };
}

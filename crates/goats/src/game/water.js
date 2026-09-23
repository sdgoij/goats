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
let waterFloor = 0;         // the table's low end, smoothed across rebuilds
let waterOn = false;        // the table stands above the ground: there is water to draw
let waterClock = 0;         // the waves' own seconds, and deliberately not `worldTime`
let waterMesh = -1;         // the surface mesh (M20b)
let waterQuads = 0;         // how many of the grid's quads can hold water at all
let waterLogX = NaN;        // the last anchor this reported on, like the terrain's
let waterLogZ = NaN;

// The surface's colours, as multipliers on the light the ground gets: a pale
// green-blue where a puddle is thin enough to see the bottom through, and a dark
// teal where a basin is full. The alpha is the deep water's.
const W_SHALLOW = [0.40, 0.58, 0.53, 0.55];
const W_DEEP = [0.05, 0.15, 0.19, 0.85];
// How fast the table's floor follows the window's lowest ground, per rebuild. The
// grid follows the goat, so that minimum steps when a deeper hollow enters or leaves
// the window; at 1.0 the whole field's water would step with it.
const WATER_FLOOR_EASE = 0.25;
// The grid's own arrays for the mesh, reused on every build: the engine's `makeModel`
// re-uploads arrays it has already seen far more cheaply than freshly allocated ones
// (world.js).
const W_VERTS = new Array(WATER_N * WATER_N * 3);
const W_NORM = new Array(WATER_N * WATER_N * 3);
const W_COL = new Array(WATER_N * WATER_N * 4);
const W_TEX = new Array(WATER_N * WATER_N * 2);
const W_IDX = new Array(TERRAIN_QUADS * TERRAIN_QUADS * 6);

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
    // The table's floor is smoothed across rebuilds (see `WATER_FLOOR_EASE`): the
    // window's lowest ground is not the world's, and it steps as the grid follows the
    // goat. A dry spell is still *exactly* dry -- `waterUpdate` pins the level to the
    // unsmoothed minimum when there is nothing to pool.
    waterFloor = waterReady ? waterFloor + (lo - waterFloor) * WATER_FLOOR_EASE : lo;
    waterReady = true;
    waterUpdate();
    waterBuild();
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
    } else if (waterForce >= 0) {
        waterLevel = waterForce;
    } else {
        let wetted = (rainAmount - t.seep) / (1 - t.seep);
        if (wetted < 0) wetted = 0;
        if (wetted > 1) wetted = 1;
        waterLevel = wetted <= 0
            ? waterLevelMin
            : waterFloor + wetted * t.fill * (waterLevelMax - waterFloor);
    }
    waterOn = waterLevel > waterLevelMin + 1e-6;
}

// The `flood <h>` debug override, for a demo or a screenshot review. Anything below
// zero hands the level back to the weather, the way `C` hands the weather back to the
// seeded machine.
function waterSetForce(level) {
    waterForce = level < 0 ? -1 : level;
    waterUpdate();
}

// ---- the surface (M20b) ---------------------------------------------------
//
// The mesh carries the *ground* in its positions and, in its texcoord, the deepest
// water each vertex's basin can hold. That split is the point: the level is a uniform
// the shader applies (`lighting.js`, `WATER_VS`), so the mesh is rebuilt only when the
// *ground* changes -- a new anchor or a crater -- and never as the rain rises.
//
// The vertices are the whole grid (any of them can be under water); the index list is
// cut down to the quads a basin's own ground touches, which is what decimates the
// draw: a dry field costs one empty draw rather than the terrain's again.
function waterBuild() {
    const n = WATER_N;
    const x0 = terrainAnchorX - WATER_HALF;
    const z0 = terrainAnchorZ - WATER_HALF;
    for (let j = 0; j < n; j++) {
        const wz = z0 + j * WATER_CELL;
        for (let i = 0; i < n; i++) {
            const k = j * n + i;
            const ground = T_H[k];
            let maxDepth = W_F[k] - ground;
            if (maxDepth < 0) maxDepth = 0;
            W_VERTS[k * 3] = x0 + i * WATER_CELL;
            W_VERTS[k * 3 + 1] = ground;
            W_VERTS[k * 3 + 2] = wz;
            W_NORM[k * 3] = 0;
            W_NORM[k * 3 + 1] = 1;
            W_NORM[k * 3 + 2] = 0;
            W_COL[k * 4] = 255;
            W_COL[k * 4 + 1] = 255;
            W_COL[k * 4 + 2] = 255;
            W_COL[k * 4 + 3] = 255;
            W_TEX[k * 2] = maxDepth;
            W_TEX[k * 2 + 1] = 0;
        }
    }
    // Wound like the terrain's own grid (and raylib's `GenMeshPlane`), so the surface
    // faces up. A quad is worth drawing if any corner of it is under its own spill
    // level; `W_IDX` is then trimmed in place, which keeps the array's identity while
    // shrinking what the engine is asked to upload.
    let t = 0;
    for (let j = 0; j < TERRAIN_QUADS; j++) {
        for (let i = 0; i < TERRAIN_QUADS; i++) {
            const a = j * n + i;
            const b = a + 1;
            const c = a + n;
            const d = c + 1;
            if (W_TEX[a * 2] <= 0 && W_TEX[b * 2] <= 0 &&
                W_TEX[c * 2] <= 0 && W_TEX[d * 2] <= 0) continue;
            W_IDX[t++] = a; W_IDX[t++] = c; W_IDX[t++] = b;
            W_IDX[t++] = b; W_IDX[t++] = c; W_IDX[t++] = d;
        }
    }
    waterQuads = t / 6;
    W_IDX.length = t;
    if (waterMesh >= 0) rl.unloadModel(waterMesh);
    waterMesh = rl.makeModel(W_VERTS, W_IDX, W_NORM, W_COL, W_TEX);
    // A fresh model starts on raylib's default shader, and the water needs its own (it
    // is where the surface height comes from), plus the shadow map. Exactly what
    // `terrainUpload` re-applies for the ground.
    if (waterShader >= 0) rl.setModelShader(waterMesh, waterShader);
    if (shadowColor >= 0) rl.setModelTexture(waterMesh, SHADOW_MAP_INDEX, shadowColor);
    if (terrainAnchorX !== waterLogX || terrainAnchorZ !== waterLogZ) {
        waterLogX = terrainAnchorX;
        waterLogZ = terrainAnchorZ;
        console.log("water: mesh " + waterMesh + " " + waterQuads + " quads of " +
            (TERRAIN_QUADS * TERRAIN_QUADS) + ", level " + netRound3(waterLevel));
    }
}

// The level, the colours and the chop, pushed as the surface is drawn. The light, the
// ambient, the shadow and the blast light are the shared ones (`setLitUniforms`,
// lighting.js).
function waterSetUniforms() {
    const shader = waterShader;
    const u = waterUniforms;
    if (shader < 0 || u === null) return;
    const t = TUNING.water;
    const wave = t.wave;
    rl.setShaderValue(shader, u.level, waterLevel, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValueVector4(shader, u.shallow, W_SHALLOW[0], W_SHALLOW[1], W_SHALLOW[2], W_SHALLOW[3]);
    rl.setShaderValueVector4(shader, u.deep, W_DEEP[0], W_DEEP[1], W_DEEP[2], W_DEEP[3]);
    rl.setShaderValue(shader, u.shore, t.shore, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(shader, u.time, waterClock, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(shader, u.fresnel, t.fresnel, rl.SHADER_UNIFORM_FLOAT);
    // The chop rides the same gust the grass sways to. The direction is a unit vector
    // whatever the wind is doing -- a dead calm still has chop, and the shader
    // normalises it again anyway.
    const wx = windX;
    const wz = windZ;
    const len = Math.sqrt(wx * wx + wz * wz);
    const dx = len > 1e-3 ? wx / len : 1.0;
    const dz = len > 1e-3 ? wz / len : 0.0;
    const gustNorm = clamp(windSway / TUNING.weather.windNorm, 0, 1);
    rl.setShaderValueVector3(shader, u.wind, dx, dz, (1 - wave.wind) + wave.wind * gustNorm);
    rl.setShaderValueVector3(shader, u.wave, wave.height, wave.scale, wave.speed);
    // What the fresnel reflects, until M20e has a real mirror to sample: the scene's own
    // daylight grade, dimmed with the sky, so night water reflects a dark sky and the
    // pool's colour matches the hour (~-ish, `ambR/G/B` and `skyLight`, world.js).
    rl.setShaderValueVector3(shader, u.sky, ambR * skyLight, ambG * skyLight, ambB * skyLight);
}

// The surface, drawn last in the 3D pass so it blends over the ground and over
// anything standing in it. Blending has to be asked for: a model draw leaves whatever
// blend state it found, and this is the scene's only transparent model.
function waterDraw() {
    if (!waterOn || waterMesh < 0 || waterShader < 0) return;
    // The wave clock advances here, once per frame that draws water: `worldTime` wraps at
    // midnight, and a phase that jumped with it would be a visible pop once a game-day.
    waterClock += sceneDt();
    waterSetUniforms();
    const blend = typeof rl.beginBlendMode === "function";
    if (blend) rl.beginBlendMode(rl.BLEND_ALPHA);
    rl.drawModelEx(waterMesh, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, rl.WHITE);
    if (blend) rl.endBlendMode();
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
        on: waterOn,
        wet: wet,
        cells: count,
        volume: netRound3(volume),
        deepest: netRound3(deepest),
        deepX: netRound3(x0 + di * WATER_CELL),
        deepZ: netRound3(z0 + dj * WATER_CELL),
        goatDepth: netRound3(waterDepthAt(goat.px, goat.pz)),
        low: netRound3(waterLevelMin),
        high: netRound3(waterLevelMax),
        floor: netRound3(waterFloor),
        rise: netRound3(waterLevel - waterLevelMin),
        mesh: waterMesh,
        quads: waterQuads,
        shader: waterShader,
    };
}

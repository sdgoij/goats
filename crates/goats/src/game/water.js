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
// The level `W` is a function of the weather's `rainAmount` and of nothing else that would
// have to be sent: the rain is already seeded, eased and mirrored to clients (weather.js).
// Its ends are *declared* -- `TUNING.water.low`/`high`, the field's floor and its midline --
// and not measured off the grid the goat happens to be standing on. Measuring them is what
// the first cut of this did, and it cannot work: the window follows the goat, so the same
// world point is read from a table of a different height one step later. A pool 0.11 m deep
// from one window is dry from the next, over ground that has not moved, and stepping back
// brings it back -- which is what the play-through reported and what this now cannot do.
// What the water adds of its own is *wetting* -- one scalar, 0..1 -- and it is a **follower
// rather than an accumulator**: the table rises the instant the rain does (`waterUpdate`)
// and falls back slowly (`waterStep`), so a shower leaves standing water behind it instead
// of taking its puddles away with it. That distinction is the whole of why this still needs
// no field on the wire. An accumulator of `rain * rate * dt` -- the first cut of this design
// -- integrates each peer's own frame times and drifts apart without bound; a follower has
// a *restoring force*, so it converges on the rain's own value and two peers can only differ
// by how far apart their samples of the same shared signal fall -- millimetres of level, at
// these time constants, and only while a front is moving. That is an estimate, not a
// measurement, and M20f's audit is where it gets proven or where the level moves onto the
// wire (the ROADMAP's call 4).
//
// The fill and the level are M20a; the surface, the chop, the wake and the drag are
// M20b-M20d; the shore, the filling rate and the drain were retuned by eye in M20d'.
// `sceneWater()` is the seam the harness reads and a mod will; the reflections are M20e.

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
let waterWet = 0;           // the water's own wetting, 0..1 (`waterStep`)
let waterGround = 0;        // the window's lowest ground, and only ever a *test*: nothing
                            // is lower than it, so the table clears it exactly when
                            // something in the window is wet
let waterForce = NaN;       // `flood <h>`: a level set by hand; a non-number = from the rain
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
// The wetting's shape, and the point where a draining table is called dry. The wetting
// is *concave* in the rain (`wetnessFor`), which is what makes a moderate shower leave a
// pool rather than a film. Zero is exact rather than asymptotic because a follower never
// reaches its own target, and `waterUpdate` needs a real zero to pin the table to its own
// floor -- which is what keeps a dry spell *exactly* dry, M6's own rule.
const WATER_WET_CURVE = 0.5;
const WATER_DRY_EPS = 1e-4;
// The grid's own arrays for the mesh, reused on every build: the engine's `makeModel`
// re-uploads arrays it has already seen far more cheaply than freshly allocated ones
// (world.js).
const W_VERTS = new Array(WATER_N * WATER_N * 3);
const W_NORM = new Array(WATER_N * WATER_N * 3);
const W_COL = new Array(WATER_N * WATER_N * 4);
const W_TEX = new Array(WATER_N * WATER_N * 2);
const W_IDX = new Array(TERRAIN_QUADS * TERRAIN_QUADS * 6);

// ---- the wake and the splashes (M20d) -------------------------------------
//
// Both are cosmetic and local -- nothing about them travels -- so they live beside the
// draw rather than in the simulation, and a client gets them for the herd it mirrors.
// The wake is a few rings the shader carries as uniforms; a splash is a handful of
// pooled drops drawn with the M0 primitives, the way the explosion's grit is.
const RIPPLE_MAX = 3;               // the rings `WATER_FS` carries at once
const RIPPLE_LIFE = 1.6;            // seconds a ring lasts
const RIPPLE_SPEED = 1.1;           // m/s the front travels
const RIPPLE_STEP = 0.45;           // metres of travel between the goat's rings
const RIPPLE_MIN_DEPTH = 0.04;      // metres of water before a hoof leaves anything
const SPLASH_MAX = 24;              // drops in the pool; each is a draw
const SPLASH_DROPS = 8;             // drops one splash throws
const SPLASH_LIFE = 0.55;           // seconds a drop lives
const SPLASH_GRAVITY = 14;          // m/s^2, so a drop is gone before it is a puddle

const RIPPLE = [];                  // { x, z, r, s }: the front's radius and strength
const SPLASH = [];                  // { x, y, z, vx, vy, vz, life }
for (let rippleInit = 0; rippleInit < RIPPLE_MAX; rippleInit++) {
    RIPPLE.push({ x: 0, z: 0, r: 0, s: 0 });
}
let waterCulled = 0;                // tufts the grass field skipped under the water
let splashTop = 0;
let rippleLastX = NaN;              // where the goat's last ring was laid
let rippleLastZ = NaN;
let goatWet = false;                // the goat's feet were under the surface last frame

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
    // The fill is still run: the surface is decimated by it and `waterSubmergedAt` still asks
    // it whether a vertex can hold water. Nothing about the *level* is read off it any more.
    waterFill();
    const count = WATER_N * WATER_N;
    // The window's lowest ground, which is the one thing a rebuild still measures: it is the
    // "is anything wet" test in `waterUpdate`, and nothing in the window is lower than it. It
    // is a test and never a level, which is the whole of the difference -- a level taken from
    // the window is a level that changes when the goat walks, and the next window's lowest
    // ground is a different number over ground that has not moved.
    let ground = Infinity;
    for (let k = 0; k < count; k++) {
        const g = T_H[k];
        if (g < ground) ground = g;
    }
    waterGround = ground;
    waterReady = true;
    waterUpdate();
    waterBuild();
}

// The rain, as the share of the basins' spill range it can reach. Nothing below `seep`
// -- the ground drinks the first of it, and a dry spell stays exactly dry -- and above
// it a *concave* curve, so the first of a shower is most of what pools. The table then
// walks `0..fill` of the range from the lowest ground that can hold water to the highest
// spill, which stays monotone in the rain at every step.
function wetnessFor(rain) {
    const t = TUNING.water;
    const raw = (rain - t.seep) / (1 - t.seep);
    if (raw <= 0) return 0;
    return Math.pow(raw > 1 ? 1 : raw, WATER_WET_CURVE);
}

// One frame of the water's *drain*, the one half of its clock that has to age: the table
// answers the rain the instant the rain moves (see `waterUpdate`), but it lets go
// slowly, so a pool stands for `TUNING.water.wetDown` seconds after the rain that filled
// it has gone. `dt` is the frame's own (goat.js), from the one place a local weather step
// and a mirroring client's applied weather both pass through -- and it is the frame's
// rather than the hook's because a client can reach the hook twice in one frame, from an
// arriving packet and from the frame itself. A paused UI hands in 0, so the water waits
// with everything else.
function waterStep(dt) {
    const target = wetnessFor(rainAmount);
    if (target < waterWet) {
        const down = TUNING.water.wetDown;
        const k = down > 1e-6 ? Math.min(1, dt / down) : 1;
        waterWet += (target - waterWet) * k;
        if (waterWet < WATER_DRY_EPS) waterWet = 0;
    }
    waterUpdate();
}

// The level for this frame, from the wetting above (see the header). `fill` is how much
// of the basins' spill range the heaviest rain reaches, so the deepest hollows hold the
// first water and the shallow ones only fill in a downpour: the level rises monotonically
// from the lowest ground that can hold water to the highest spill.
function waterUpdate() {
    if (!waterReady) return;
    // The grass field counts its own skips for the frame about to be drawn (below).
    waterCulled = 0;
    // The rise is immediate, so it lives here rather than in the frame's step: there is
    // no lag in it to age, every caller can be trusted with it, and the water answers the
    // rain the moment the rain is set -- which is also the half of the water's clock that
    // cannot differ between two peers, since it carries no memory at all.
    const target = wetnessFor(rainAmount);
    if (target > waterWet) waterWet = target;
    const t = TUNING.water;
    if (t.enabled === 0) {
        waterLevel = t.low;
    } else if (isFinite(waterForce)) {
        waterLevel = waterForce;
    } else if (waterWet <= 0) {
        waterLevel = t.low;
    } else {
        // The table, and the whole of it: the declared band, walked by the wetting. No window
        // to read, no floor to lag behind and no clamp -- `waterWet` is all the memory there
        // is, so two peers handed the same rain agree to the last bit, and the ceiling is
        // `high` because the band ends there rather than because something holds it down.
        waterLevel = t.low + waterWet * t.fill * (t.high - t.low);
    }
    // There is water to draw when the table clears the window's lowest ground, which is the
    // same statement as "the deepest pool in the window has a depth": nothing in it is lower
    // than that, so something is wet exactly when the table is above it.
    waterOn = waterLevel > waterGround + 1e-6;
    // No water is also no wake: the goat cannot be standing in what is not there, and the
    // step that would notice is only reached when there is a surface to draw (M20d).
    if (!waterOn) goatWet = false;
}

// The `flood <h>` debug override, for a demo or a screenshot review, and the bisect for
// the whole system. A *level* is any finite number: this field's water lives below zero --
// the ground is a metre or two of relief either side of it -- so a sign cannot double as
// the off switch. `waterForceOff` is the way back, the way `C` hands the weather back to
// the seeded machine.
function waterSetForce(level) {
    waterForce = isFinite(level) ? level : NaN;
    waterUpdate();
}

function waterForceOff() {
    waterForce = NaN;
    waterUpdate();
}

// ---- the surface (M20b) ---------------------------------------------------
//
// The mesh carries the *ground* in its positions, and the level is one uniform the shader
// applies (`lighting.js`, `WATER_VS`): a vertex is lifted to the table by its own depth, so
// the mesh is rebuilt only when the *ground* changes -- a new anchor or a crater -- and never
// as the rain rises. The texcoord still carries the fill's per-vertex basin depth, and
// nothing reads it any more: it is the last thing keeping `waterFill` alive.
//
// The vertices are the whole grid (any of them can be under water); the index list is cut
// down to the quads whose ground stands under the table's ceiling, which is what decimates
// the draw: a dry field costs one empty draw rather than the terrain's again.
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
    // faces up. A quad is worth drawing if any corner of it stands under the highest level
    // the weather can make -- the table's own ceiling, since nothing above it can ever be
    // wet. Decimating by the fill's per-vertex basin instead was right while the level was
    // the window's; with the table the world's it would punch holes, because a cell the
    // flood lets drain out of the grid's edge can be under water and is no basin at all.
    // `W_IDX` is trimmed in place, which keeps the array's identity while shrinking what the
    // engine is asked to upload.
    let t = 0;
    const top = TUNING.water.high;
    for (let j = 0; j < TERRAIN_QUADS; j++) {
        for (let i = 0; i < TERRAIN_QUADS; i++) {
            const a = j * n + i;
            const b = a + 1;
            const c = a + n;
            const d = c + 1;
            if (T_H[a] >= top && T_H[b] >= top &&
                T_H[c] >= top && T_H[d] >= top) continue;
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
    // The wake: every slot pushed, a spent one as nothing, so a ring cannot linger in the
    // shader after its strength reached zero (M20d).
    rl.setShaderValueVector4(shader, u.ripple0, RIPPLE[0].x, RIPPLE[0].z, RIPPLE[0].r, RIPPLE[0].s);
    rl.setShaderValueVector4(shader, u.ripple1, RIPPLE[1].x, RIPPLE[1].z, RIPPLE[1].r, RIPPLE[1].s);
    rl.setShaderValueVector4(shader, u.ripple2, RIPPLE[2].x, RIPPLE[2].z, RIPPLE[2].r, RIPPLE[2].s);
}

// The surface, drawn last in the 3D pass so it blends over the ground and over
// anything standing in it. Blending has to be asked for: a model draw leaves whatever
// blend state it found, and this is the scene's only transparent model.
function waterDraw() {
    if (!waterOn || waterMesh < 0 || waterShader < 0) return;
    const dt = sceneDt();
    // The wave clock advances here, once per frame that draws water: `worldTime` wraps at
    // midnight, and a phase that jumped with it would be a visible pop once a game-day.
    waterClock += dt;
    // The wake and the splashes, before the surface they belong to (M20d).
    waterActorStep(dt);
    waterSetUniforms();
    const blend = typeof rl.beginBlendMode === "function";
    if (blend) rl.beginBlendMode(rl.BLEND_ALPHA);
    rl.drawModelEx(waterMesh, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, rl.WHITE);
    if (blend) rl.endBlendMode();
    waterSplashDraw();
}

// ---- reading it, and what it does to a goat (M20d) ------------------------

// Whether a tuft standing at (x, z) is under the water, for the grass field to skip.
// It is a lookup rather than a comparison with the table alone: a cell that *drains* --
// its spill level is its own ground -- is dry even where the table is above it, which is
// the gully between two pools, and `W_TEX` already holds that per-vertex answer as
// `max(0, W_F - terrain)`. `waterCulled` counts what it skipped, for the HUD's sake and
// the harness's.
function waterSubmergedAt(x, z) {
    if (!waterOn) return false;
    const i = Math.round((x - (terrainAnchorX - WATER_HALF)) / WATER_CELL);
    const j = Math.round((z - (terrainAnchorZ - WATER_HALF)) / WATER_CELL);
    if (i < 0 || j < 0 || i >= WATER_N || j >= WATER_N) return false;
    const k = j * WATER_N + i;
    if (T_H[k] >= waterLevel) return false;
    waterCulled += 1;
    return true;
}

// How much of the water's effect applies where the goat is standing: 0 dry, 1 at the
// wading cap. Both factors below are exactly 1 when it is 0, which is what keeps `clear`
// neutral and the harness's gait speeds exact -- M6's own rule, and the reason the drag is
// gated on the depth rather than on the weather.
function waterDragFraction() {
    const depth = waterDepthAt(goat.px, goat.pz);
    if (depth <= 0) return 0;
    const cap = TUNING.water.maxDepth;
    if (cap <= 0) return 1;
    return depth / cap > 1 ? 1 : depth / cap;
}

function waterSpeedFactor() { return 1 - TUNING.water.drag * waterDragFraction(); }

function waterDrainFactor() { return 1 + TUNING.water.dragEnergy * waterDragFraction(); }

// The HUD's water read-out, for the weather line it belongs beside: whether the goat is
// standing in water, how deep, and what it costs it. Empty when it is dry, so a `clear`
// frame's weather line is exactly the line it has always been -- and empty under a
// centimetre, because the drain leaves a film that thin behind for minutes after the rain
// has gone, and a pool nobody can see should not have a read-out.
const WATER_HUD_MIN = 0.01;
function waterHudText() {
    const depth = waterDepthAt(goat.px, goat.pz);
    if (depth < WATER_HUD_MIN) return "";
    return "water " + depth.toFixed(2) + " m   slowed " +
        Math.round(TUNING.water.drag * waterDragFraction() * 100) + "%";
}

// One live ring. The weakest slot is the oldest, because a ring's strength decays with its
// age -- so there is no index to keep.
function waterRippleAdd(x, z, strength) {
    let at = 0;
    for (let i = 1; i < RIPPLE_MAX; i++) if (RIPPLE[i].s < RIPPLE[at].s) at = i;
    const slot = RIPPLE[at];
    slot.x = x;
    slot.z = z;
    slot.r = 0;
    slot.s = strength;
}

function waterRipplesLive() {
    let n = 0;
    for (let i = 0; i < RIPPLE_MAX; i++) if (RIPPLE[i].s > 0) n += 1;
    return n;
}

function waterSplashLive() {
    let n = 0;
    for (let i = 0; i < SPLASH_MAX; i++) {
        const d = SPLASH[i];
        if (d !== undefined && d.life > 0) n += 1;
    }
    return n;
}

// A splash: a few drops leaving the surface in a shallow cone, from the same hash the rest
// of the scene uses for variation, so no two are the same and nothing is stored per drop
// beyond the slot it is in.
function waterSplash(x, z, strength) {
    const surface = terrainHeight(x, z) + waterDepthAt(x, z);
    const count = Math.round(SPLASH_DROPS * strength);
    for (let i = 0; i < count; i++) {
        if (splashTop >= SPLASH_MAX) splashTop = 0;
        let slot = SPLASH[splashTop];
        if (slot === undefined) {
            slot = { x: 0, y: 0, z: 0, vx: 0, vy: 0, vz: 0, life: 0 };
            SPLASH[splashTop] = slot;
        }
        splashTop += 1;
        const a = hash(x * 7.1 + z * 3.7 + i * 1.9) * 6.283185307179586;
        const out = 0.5 + hash(x * 4.7 + z * 8.3 + i * 3.1) * 0.9;
        const up = 1.4 + hash(x * 2.3 + z * 5.9 + i * 2.7) * 1.6;
        slot.x = x + Math.cos(a) * 0.18;
        slot.y = surface + 0.02;
        slot.z = z + Math.sin(a) * 0.18;
        slot.vx = Math.cos(a) * out;
        slot.vz = Math.sin(a) * out;
        slot.vy = up;
        slot.life = SPLASH_LIFE;
    }
}

function waterSplashStep(dt) {
    for (let i = 0; i < SPLASH_MAX; i++) {
        const d = SPLASH[i];
        if (d === undefined || d.life <= 0) continue;
        d.life -= dt;
        d.x += d.vx * dt;
        d.z += d.vz * dt;
        d.vy -= SPLASH_GRAVITY * dt;
        d.y += d.vy * dt;
    }
}

function waterSplashDraw() {
    for (let i = 0; i < SPLASH_MAX; i++) {
        const d = SPLASH[i];
        if (d === undefined || d.life <= 0) continue;
        const fade = d.life / SPLASH_LIFE;
        rl.drawSphereEx(d.x, d.y, d.z, 0.035, 4, 4, rl.color(232, 244, 248, Math.round(200 * fade)));
    }
}

// One frame of the wake and the splashes. The goat's rings are laid by distance travelled,
// so they are evenly spaced however fast it walks, and an actor *entering* the water throws
// a splash and a stronger ring: that edge -- a step in, a landing -- is what matters, not
// everything that is merely standing in a pool.
//
// The herd is checked too, on every frame whatever the frame is doing: a bot is mirrored on
// a client, and a splash is exactly the kind of thing that should not need a simulation to
// see. The herd pays no drag for it (`waterSpeedFactor` is the player's), which keeps the
// bot checks and the netplay determinism where they were.
function waterActorStep(dt) {
    for (let i = 0; i < RIPPLE_MAX; i++) {
        const r = RIPPLE[i];
        if (r.s <= 0) continue;
        r.r += RIPPLE_SPEED * dt;
        r.s -= dt / RIPPLE_LIFE;
        if (r.s < 0) r.s = 0;
    }
    waterSplashStep(dt);
    const depth = waterDepthAt(goat.px, goat.pz);
    const wet = depth > RIPPLE_MIN_DEPTH && goat.py < depth;
    if (wet) {
        if (!goatWet) {
            waterRippleAdd(goat.px, goat.pz, 1.0);
            waterSplash(goat.px, goat.pz, 0.7);
        } else {
            const dx = goat.px - rippleLastX;
            const dz = goat.pz - rippleLastZ;
            if (!(dx * dx + dz * dz < RIPPLE_STEP * RIPPLE_STEP)) {
                waterRippleAdd(goat.px, goat.pz, 0.6);
            }
        }
        rippleLastX = goat.px;
        rippleLastZ = goat.pz;
    }
    goatWet = wet;
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        const bd = waterDepthAt(b.x, b.z);
        const bw = bd > RIPPLE_MIN_DEPTH && b.py < bd;
        if (bw && b.wet !== true) {
            waterRippleAdd(b.x, b.z, 0.9);
            waterSplash(b.x, b.z, 0.6);
        }
        b.wet = bw;
    }
}

// One vertex's depth, from the table and the spill level. Capped at
// `TUNING.water.maxDepth`: v1 keeps pools wading depth (M20g lifts it for swimming).
function waterVertexDepth(k) {
    // The surface is the *table*, at every vertex: a cell is wet exactly when the table stands
    // over its ground, and a basin whose rim the table has passed is simply submerged. The
    // fill's spill used to cap this (`min(W_F, level)`) and that was wrong twice: a pool
    // stopped deepening at its own rim while the table went on climbing, and a cell the flood
    // lets drain out of the window's edge -- an artifact of where the grid stops, not a fact
    // about the ground -- read dry with the water standing over it. So the depth here is the
    // water's own, as it is in the report and in the shader: `maxDepth` is the *wading* cap
    // and lives where wading is decided (`waterDragFraction`), not wrapped around a depth.
    const d = waterLevel - T_H[k];
    return d > 0 ? d : 0;
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
    const level = waterLevel;
    let wet = 0;
    let volume = 0;
    let deepest = 0;
    let di = 0;
    let dj = 0;
    for (let k = 0; k < count; k++) {
        const d = level - T_H[k];
        if (d <= 0) continue;
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
        forced: isFinite(waterForce),
        on: waterOn,
        wetting: netRound3(waterWet),
        wet: wet,
        cells: count,
        volume: netRound3(volume),
        deepest: netRound3(deepest),
        deepX: netRound3(x0 + di * WATER_CELL),
        deepZ: netRound3(z0 + dj * WATER_CELL),
        goatDepth: netRound3(waterDepthAt(goat.px, goat.pz)),
        ground: netRound3(waterGround),
        floor: netRound3(TUNING.water.low),
        high: netRound3(TUNING.water.high),
        rise: netRound3(waterLevel - TUNING.water.low),
        mesh: waterMesh,
        quads: waterQuads,
        shader: waterShader,
        culled: waterCulled,
        splashes: waterSplashLive(),
        ripples: waterRipplesLive(),
        drag: waterSpeedFactor(),
        drain: waterDrainFactor(),
    };
}

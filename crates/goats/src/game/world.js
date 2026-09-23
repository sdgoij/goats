// ---- scenery -------------------------------------------------------------

// Grass is generated procedurally around the goat in `drawTufts` (weather.js),
// so the field extends as far as the eye (and the shadow pass) can see and never
// leaves bare ground behind after a walk.

// ---- terrain -------------------------------------------------------------
//
// The ground is a heightfield drawn as one mesh rather than a field of cubes. A
// grid of 48x48 quads is built through `rl.makeModel`, so it carries real
// per-vertex normals, UVs and colours. Immediate-mode geometry cannot: `drawCube`
// and `drawTriangle3D` leave raylib's default normal (0, 0, 1) and texcoord
// (0, 0), so a heightfield built from them is mis-lit and untexturable -- and a
// cube per cell measures ~14 us, which caps a frame at roughly 100 cells. One
// `drawModelEx` replaces what would be hundreds of draw calls.
//
// `terrainHeight` is the single source of truth for the ground: the goat, the
// herd, the grass, the eyes and both shadows all read it, so nothing floats or
// sinks as the ground rises.

const TERRAIN_CELL = 2;         // world units per grid cell (matches the grass)
const TERRAIN_QUADS = 48;       // quads per side: a field of +/- 48 units
const TERRAIN_DETAIL = 64;      // detail-texture size, in pixels

// Per-cell ground heights for the grass, keyed by cell. The field is
// world-anchored, so a cell's height never changes; the cache keeps `drawTufts`
// from paying three octaves of noise for every cell of the visible field on
// every frame (which measured ~2 ms/frame at 1440p). It follows the goat, so it
// is cleared rather than growing without bound.
const TERRAIN_CELL_H = new Map();

// The ground palette. The mesh carries these as per-vertex colours, so adjacent
// cells blend and a material boundary reads as a gradient rather than a tile.
const T_ROCK = [128, 122, 112];
const T_MUD = [104, 84, 62];
const T_SAND = [198, 178, 130];
const T_GRASS = [98, 150, 84];
const T_GRASS_DK = [78, 126, 66];
const T_HILL = [126, 146, 74];

// The mesh binding the heightfield needs. Without it the ground falls back to
// the flat slab and `terrainHeight` stays at zero, so placement maths still
// works.
const TERRAIN_MESH_OK = typeof rl.makeModel === "function";

let terrainMesh = -1;
let terrainDetail = -1;
let terrainAnchorX = 0;         // snapped centre of the built grid
let terrainAnchorZ = 0;
let terrainBuilt = false;
// Set when the ground itself changes -- a crater appearing or closing over -- so the
// mesh picks it up on the frame it happens rather than when the goat has walked
// `TUNING.terrain.snap` away. `explosions.js` sets it; `terrainEnsure` consumes it.
// (The pending box itself is `terrainPatch`, declared with the grid below.)
let terrainVerts = 0;
let terrainTris = 0;
// The last anchor this reported on. The log is for the anchor moves -- one line per 24
// units of walking -- rather than for every rebuild: a crater near the goat rebuilds the
// mesh a handful of times over its four minutes, and none of that is news, nor should it
// grow the in-game console without bound.
let terrainLogX = NaN;
let terrainLogZ = NaN;

// Smooth 0..1 value noise, three octaves: broad hills with smaller bumps on top.
function terrainShape(x, z) {
    return 0.62 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1) +
        0.26 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9) +
        0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3);
}

// The ground height at (x, z). A bowl around the origin stays level so the goat
// starts on flat grass, and the relief eases in over `TUNING.terrain.ramp` so
// there is no cliff at its edge. The craters are the one thing that changes the
// ground after the field is derived: `craterDipAt` is their term (explosions.js),
// and it is why every reader of this function stands in a hole for free.
function terrainHeight(x, z) {
    if (!TERRAIN_MESH_OK) return 0;
    return terrainBaseHeight(x, z) + craterDipAt(x, z);
}

// Everything about the ground that depends only on where you are, with the craters left
// out: the bowl and the three-octave noise. Split from `terrainHeight` so that a rebuild
// can lay the crater term down a crater at a time (`terrainStampCraters`) rather than
// asking every vertex to scan the crater list -- at the 24-crater cap that scan was 713
// of a 721 ms rebuild (PERF.md appendix B). The readers keep calling `terrainHeight`, so
// the two halves are added back in the same order for them.
function terrainBaseHeight(x, z) {
    const d = Math.sqrt(x * x + z * z);
    let t = (d - TUNING.terrain.flat) / TUNING.terrain.ramp;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    t = t * t * (3 - 2 * t);
    return (terrainShape(x, z) - 0.5) * 2 * TUNING.terrain.relief * t;
}

// The goat's ground-contact height. `g.py` is the height *above* the ground
// (a jump, or the cube fallback's bob), so the terrain under it is added here and
// every part drawn from `g.py` lands on the surface.
function goatBaseY(g) {
    return terrainHeight(g.px, g.pz) + g.py;
}

// Ground material from the height, the slope (0 flat .. 1 steep) and a
// low-frequency patchiness noise: rock takes the peaks and scarps, mud the
// hollows, sand the dry flat patches, and grass everything else.
function terrainMaterial(y, slope, m) {
    if (slope > 0.5 || y > 1.15) return T_ROCK;
    if (y < -0.55 && m < 0.6) return T_MUD;
    if (slope < 0.09 && m > 0.6) return T_SAND;
    if (y > 0.35) return T_HILL;
    return m < 0.5 ? T_GRASS : T_GRASS_DK;
}

// A subtle tiling detail texture (neutral noise around 0.85), so the material
// colours keep a grain up close without a texture atlas.
function makeTerrainTexture() {
    const n = TERRAIN_DETAIL;
    let pixels = "";
    for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
            const v = 0.60 * vnoise2(x * 0.13 + 2.3, y * 0.13 + 7.7) +
                0.27 * vnoise2(x * 0.31 + 19.1, y * 0.31 + 4.3) +
                0.13 * hash(x * 5.7 + y * 17.3);
            const c = Math.round(196 + 59 * clamp(v, 0, 1));
            pixels += HEX256[c] + HEX256[Math.round(c * 0.97)] +
                HEX256[Math.round(c * 0.88)] + "ff";
        }
    }
    terrainDetail = rl.makeTexture(n, n, pixels);
}

// Build the grid at the current anchor: one `makeModel` call, replacing the
// previous mesh. `terrainEnsure` only calls this when the anchor has moved or the
// ground has changed, so between rebuilds the terrain costs a single draw.
//
// The arrays are the grid's, not the call's: they are allocated once and recomputed
// into. So is the index list -- the 48x48 topology never changes, whatever the anchor
// or the craters do -- and the recompute is limited to the rectangle that actually
// moved, which is the whole field for a step and a handful of vertices for a crater.
const T_N = TERRAIN_QUADS + 1;                  // vertices per side
const T_HALF = (TERRAIN_QUADS * TERRAIN_CELL) / 2;
const T_H = new Array(T_N * T_N);
const T_VERTS = new Array(T_N * T_N * 3);
const T_NORMS = new Array(T_N * T_N * 3);
const T_COLS = new Array(T_N * T_N * 4);
const T_UVS = new Array(T_N * T_N * 2);
const T_IDX = new Array(TERRAIN_QUADS * TERRAIN_QUADS * 6);
// One number per vertex, used by the crater stamp to tell whether a cell in the
// rectangle being built has already had this crater's term added (see
// `terrainStampCraters`).
const T_STAMP = new Array(T_N * T_N);
let terrainIdxBuilt = false;
let terrainStampId = 0;

// The ground that has changed since the mesh was last handed to the engine, as
// world-space boxes, and `null`-free: a crater folds its own circle in through
// `terrainDirtyAt`. Boxes rather than a flag because a 1.6 m hole is a handful of
// vertices -- the mesh is a 96 m square, and rebuilding all of it for one crater is
// what made a bang hitch (~150-650 ms measured, growing with the crater count,
// against the ~0.2 ms of engine call it cannot avoid).
//
// A *list* rather than one box because a bang at the cap is two events in one frame --
// a new crater here and the oldest retired over there -- and a single box spanning
// both is most of the field (measured: 110 ms against 5 ms for the two separately).
// Boxes that overlap or touch are merged, so a chain of craters in one place still
// costs one rect.
const terrainPatches = [];

function terrainDirtyAt(x, z, r) {
    const minX = x - r;
    const maxX = x + r;
    const minZ = z - r;
    const maxZ = z + r;
    for (let i = 0; i < terrainPatches.length; i++) {
        const p = terrainPatches[i];
        if (minX > p.maxX + TERRAIN_CELL || maxX < p.minX - TERRAIN_CELL ||
            minZ > p.maxZ + TERRAIN_CELL || maxZ < p.minZ - TERRAIN_CELL) continue;
        if (minX < p.minX) p.minX = minX;
        if (maxX > p.maxX) p.maxX = maxX;
        if (minZ < p.minZ) p.minZ = minZ;
        if (maxZ > p.maxZ) p.maxZ = maxZ;
        return;
    }
    terrainPatches.push({ minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ });
}

function terrainClampIndex(v) {
    if (v < 0) return 0;
    if (v > T_N - 1) return T_N - 1;
    return v;
}

// The vertices a pending patch touches, widened by one vertex on every side: the
// normals come from central differences, so the vertices at the edge of the change
// need their neighbours' heights to be current too.
function terrainPatchRect(p) {
    const x0 = terrainAnchorX - T_HALF;
    const z0 = terrainAnchorZ - T_HALF;
    return {
        i0: terrainClampIndex(Math.floor((p.minX - x0) / TERRAIN_CELL) - 1),
        i1: terrainClampIndex(Math.ceil((p.maxX - x0) / TERRAIN_CELL) + 1),
        j0: terrainClampIndex(Math.floor((p.minZ - z0) / TERRAIN_CELL) - 1),
        j1: terrainClampIndex(Math.ceil((p.maxZ - z0) / TERRAIN_CELL) + 1),
    };
}

// One grid row of heights, without the craters: they go on top as a stamp. A function of
// its own on purpose: the engine's JIT compiles a small function and interprets a large
// one (PERF.md, `perf probe`: ~50 ns an iteration against ~730), and these loops are the
// whole cost of a rebuild.
function terrainHeightRow(j, i0, i1) {
    const wz = terrainAnchorZ - T_HALF + j * TERRAIN_CELL;
    const x0 = terrainAnchorX - T_HALF;
    const base = j * T_N;
    for (let i = i0; i <= i1; i++) {
        const wx = x0 + i * TERRAIN_CELL;
        T_H[base + i] = terrainBaseHeight(wx, wz);
    }
}

// The craters' contribution, stamped onto the heights the row pass just wrote.
//
// A crater reaches `c.r * CRATER_LIP_OUT` metres -- about two cells -- so it can only
// touch the handful of vertices inside its own box, and "which vertices does this crater
// move" is a much smaller question than "which craters move this vertex", which is what
// `terrainHeight` asks and what a rebuild cannot afford: at the cap, 2401 vertices
// against 24 craters is 57600 iterations of an interpreted loop, measured at 713 ms.
// Stamping the same 24 craters costs about 250 vertex visits.
//
// The term is `craterDipAt`'s exactly, and the craters are visited in the same order. The
// sum is associated differently -- the scan accumulates the terms and adds the total to
// the base once, this adds each term to the base in turn -- so a vertex under two
// overlapping craters can differ in the last bit of an addition. The two paths were
// compared vertex by vertex at the 24-crater cap (all 2401 of them) and agreed exactly.
//
// This *adds*, where the row pass *assigns*, and that is why it is clipped to the
// rectangles being built: a vertex outside them is already holding a finished total. Two
// rectangles may share a vertex (`terrainPatchRect` widens each box by a cell, so two
// patches two metres apart can overlap), so each (build, crater) pass carries its own
// marker in `T_STAMP` and steps over a cell that has already had it.
function terrainStampCraters(rects) {
    const x0 = terrainAnchorX - T_HALF;
    const z0 = terrainAnchorZ - T_HALF;
    const nc = CRATERS.length;
    for (let k = 0; k < nc; k++) {
        const c = CRATERS[k];
        const reach = c.r * CRATER_LIP_OUT;
        terrainStampId++;
        const sid = terrainStampId;
        for (let r = 0; r < rects.length; r++) {
            const rect = rects[r];
            let i0 = Math.floor((c.x - reach - x0) / TERRAIN_CELL);
            let i1 = Math.ceil((c.x + reach - x0) / TERRAIN_CELL);
            let j0 = Math.floor((c.z - reach - z0) / TERRAIN_CELL);
            let j1 = Math.ceil((c.z + reach - z0) / TERRAIN_CELL);
            if (i0 < rect.i0) i0 = rect.i0;
            if (i1 > rect.i1) i1 = rect.i1;
            if (j0 < rect.j0) j0 = rect.j0;
            if (j1 > rect.j1) j1 = rect.j1;
            if (i0 > i1 || j0 > j1) continue;
            for (let j = j0; j <= j1; j++) {
                const wz = z0 + j * TERRAIN_CELL;
                const row = j * T_N;
                for (let i = i0; i <= i1; i++) {
                    const cell = row + i;
                    if (T_STAMP[cell] === sid) continue;
                    T_STAMP[cell] = sid;
                    T_H[cell] += craterDipOne(c, x0 + i * TERRAIN_CELL, wz);
                }
            }
        }
    }
}

// One vertex's position, normal, colour and texcoord. Also its own function, for the
// same reason as the row.
function terrainVertex(k, i, j) {
    const wx = terrainAnchorX - T_HALF + i * TERRAIN_CELL;
    const wz = terrainAnchorZ - T_HALF + j * TERRAIN_CELL;
    const y = T_H[k];
    T_VERTS[k * 3] = wx;
    T_VERTS[k * 3 + 1] = y;
    T_VERTS[k * 3 + 2] = wz;
    // Central differences on the grid give the normal, so the shading is smooth
    // across cells without a normal attribute on the geometry.
    const dx = (T_H[k + (i < T_N - 1 ? 1 : 0)] - T_H[k - (i > 0 ? 1 : 0)]) /
        (2 * TERRAIN_CELL);
    const dz = (T_H[k + (j < T_N - 1 ? T_N : 0)] - T_H[k - (j > 0 ? T_N : 0)]) /
        (2 * TERRAIN_CELL);
    const inv = 1 / Math.sqrt(dx * dx + dz * dz + 1);
    T_NORMS[k * 3] = -dx * inv;
    T_NORMS[k * 3 + 1] = inv;
    T_NORMS[k * 3 + 2] = -dz * inv;
    const c = terrainMaterial(y, Math.min(1, Math.sqrt(dx * dx + dz * dz)),
        vnoise2(wx * 0.07 + 3.1, wz * 0.07 + 9.7));
    T_COLS[k * 4] = c[0];
    T_COLS[k * 4 + 1] = c[1];
    T_COLS[k * 4 + 2] = c[2];
    T_COLS[k * 4 + 3] = 255;
    T_UVS[k * 2] = wx * TUNING.terrain.uv;
    T_UVS[k * 2 + 1] = wz * TUNING.terrain.uv;
}

function terrainAttrRow(j, i0, i1) {
    const base = j * T_N;
    for (let i = i0; i <= i1; i++) terrainVertex(base + i, i, j);
}

// Wound like raylib's own `GenMeshPlane` (the same two triangles per quad). Built
// once: the topology is the same grid at every anchor.
function terrainIndices() {
    let t = 0;
    for (let j = 0; j < TERRAIN_QUADS; j++) {
        for (let i = 0; i < TERRAIN_QUADS; i++) {
            const a = j * T_N + i;
            const b = a + 1;
            const c = a + T_N;
            const d = c + 1;
            T_IDX[t++] = a; T_IDX[t++] = c; T_IDX[t++] = b;
            T_IDX[t++] = b; T_IDX[t++] = c; T_IDX[t++] = d;
        }
    }
}

function terrainBuildRects(rects) {
    if (!terrainIdxBuilt) { terrainIndices(); terrainIdxBuilt = true; }
    // The ground itself for every rectangle, then every crater over all of them, then
    // the vertices: the craters are added to heights, so no vertex may be derived from a
    // height before the last stamp has landed on it.
    for (let r = 0; r < rects.length; r++) {
        const rect = rects[r];
        for (let j = rect.j0; j <= rect.j1; j++) terrainHeightRow(j, rect.i0, rect.i1);
    }
    terrainStampCraters(rects);
    for (let r = 0; r < rects.length; r++) {
        const rect = rects[r];
        for (let j = rect.j0; j <= rect.j1; j++) terrainAttrRow(j, rect.i0, rect.i1);
    }
    terrainUpload();
}

function terrainBuild(i0, i1, j0, j1) {
    terrainBuildRects([{ i0: i0, i1: i1, j0: j0, j1: j1 }]);
}

// The one engine call the mesh costs. The arrays are the same objects every time, which
// is why a re-upload measured 0.2 ms against 13 ms for freshly allocated ones.
function terrainUpload() {
    if (terrainMesh >= 0) rl.unloadModel(terrainMesh);
    terrainMesh = rl.makeModel(T_VERTS, T_IDX, T_NORMS, T_COLS, T_UVS);
    terrainVerts = T_N * T_N;
    terrainTris = TERRAIN_QUADS * TERRAIN_QUADS * 2;
    rl.setModelTexture(terrainMesh, 0, terrainDetail);
    // A fresh model starts on raylib's default shader, so re-apply the lit
    // program and the shadow map the same way the goat's material gets them. The
    // terrain is a `makeModel` mesh with no bone data, so it takes the *plain*
    // program on every build (never `modelShaderFor`).
    if (litShader >= 0) rl.setModelShader(terrainMesh, useLighting ? litShader : -1);
    if (shadowColor >= 0) rl.setModelTexture(terrainMesh, SHADOW_MAP_INDEX, shadowColor);
    terrainBuilt = true;
    if (terrainAnchorX !== terrainLogX || terrainAnchorZ !== terrainLogZ) {
        terrainLogX = terrainAnchorX;
        terrainLogZ = terrainAnchorZ;
        console.log("terrain: mesh " + terrainMesh + " " + terrainVerts + " verts " +
            terrainTris + " tris cell " + TERRAIN_CELL +
            " anchor " + terrainAnchorX + "," + terrainAnchorZ);
    }
}

// Startup: make the detail texture and the first grid.
function makeTerrain() {
    if (!TERRAIN_MESH_OK) {
        console.log("terrain: engine has no makeModel - keeping the flat slab");
        return;
    }
    makeTerrainTexture();
    terrainAnchorX = Math.round(goat.px / TUNING.terrain.snap) * TUNING.terrain.snap;
    terrainAnchorZ = Math.round(goat.pz / TUNING.terrain.snap) * TUNING.terrain.snap;
    terrainBuild(0, T_N - 1, 0, T_N - 1);
}

// Rebuild the grid when the goat has left the one it was built around, or patch the
// boxes the ground changed in. Called once per frame; the snapped anchor means a step
// rebuild lands every `TUNING.terrain.snap` units of travel, not every frame, and one
// upload covers every box a frame's craters made.
function terrainEnsure(px, pz) {
    if (terrainDetail < 0) return;
    const ax = Math.round(px / TUNING.terrain.snap) * TUNING.terrain.snap;
    const az = Math.round(pz / TUNING.terrain.snap) * TUNING.terrain.snap;
    const moved = !terrainBuilt || ax !== terrainAnchorX || az !== terrainAnchorZ;
    if (!moved && terrainPatches.length === 0) return;
    if (moved) {
        // A step covers the whole field, so anything pending is already in it.
        terrainPatches.length = 0;
        terrainAnchorX = ax;
        terrainAnchorZ = az;
        terrainBuild(0, T_N - 1, 0, T_N - 1);
        return;
    }
    const rects = [];
    for (let i = 0; i < terrainPatches.length; i++) rects.push(terrainPatchRect(terrainPatches[i]));
    terrainPatches.length = 0;
    terrainBuildRects(rects);
}

// Draw the ground. `tint` multiplies the mesh's own per-vertex colours: white
// when the lit shader supplies the light, the ambient grade when it does not.
// A model draw binds its material shader and resets raylib's batch shader, so
// this must run outside `beginShaderMode`.
function drawTerrain(tint) {
    if (terrainMesh < 0) {
        // No mesh binding: the flat slab the sandbox used before the heightmap.
        rl.drawCube(Math.round(goat.px / 2) * 2, -0.06, Math.round(goat.pz / 2) * 2,
            70, 0.1, 70, tint);
        return;
    }
    rl.drawModelEx(terrainMesh, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, tint);
}

// Point the terrain material at the lit program, or back at raylib's default
// when lighting is off -- the same toggle `setModelShader` does for the goat.
// Deliberately not `modelShaderFor`: the terrain is a `makeModel` mesh with no
// bone data, so on a `gpu-skinning` build a skinned program would read the generic
// bone attributes (indices 0, weights 1) and deform the whole grid by whichever
// model was drawn last (`slag/.notes/gpu-skinning.md`, section 1b).
function setTerrainShader(shader) {
    if (terrainMesh >= 0) rl.setModelShader(terrainMesh, shader);
}

// ---- day/night -----------------------------------------------------------

// The clock and its speed are `TUNING.world.dayLength` / `TUNING.world.timeFast`,
// and the cold-night energy penalty is `TUNING.world.nightDrainMult`.

// Sky keyframes by hour: sky-top and horizon colours plus a 0..1 light factor
// used to tint the whole scene. Hour 24 repeats hour 0.
const SKY_KEYS = [
    { h: 0.0, top: [8, 10, 28], bot: [16, 20, 44], light: 0.0 },
    { h: 4.5, top: [12, 14, 34], bot: [26, 28, 54], light: 0.0 },
    { h: 6.0, top: [70, 70, 120], bot: [190, 120, 90], light: 0.25 },
    { h: 7.5, top: [120, 165, 220], bot: [235, 190, 150], light: 0.8 },
    { h: 12.0, top: [110, 170, 240], bot: [175, 210, 245], light: 1.0 },
    { h: 17.0, top: [120, 165, 220], bot: [235, 200, 160], light: 0.85 },
    { h: 19.0, top: [90, 80, 130], bot: [225, 130, 90], light: 0.35 },
    { h: 20.5, top: [26, 28, 58], bot: [70, 60, 90], light: 0.08 },
    { h: 22.0, top: [10, 12, 30], bot: [18, 22, 46], light: 0.0 },
    { h: 24.0, top: [8, 10, 28], bot: [16, 20, 44], light: 0.0 },
];

let worldTime = 8.0;        // hours, [0, 24)
let skyLight = 1.0;         // 0 (night) .. 1 (full day)
let skyWarm = 0.0;          // 0 (neutral) .. 1 (dawn/dusk warm)
let skyTop = 0;             // packed sky colours, refreshed each frame
let skyBot = 0;
let ambR = 1.0, ambG = 1.0, ambB = 1.0;
let ambTint = 0xFFFFFFFF;
let ambFur, ambFurDk, ambDark, ambHorn, ambHoof, ambEye, ambTuft, ambShadow;
let clockText = "";

// Fixed star field on a big sphere; drawn relative to the goat so it reads as
// infinitely far away.
const STARS = [];
(function buildStars() {
    for (let i = 0; i < 320; i++) {
        const a = hash(i * 12.9898) * Math.PI * 2;
        const e = 0.05 + hash(i * 78.233) * 1.35;
        const r = Math.cos(e) * 90;
        STARS.push({ x: Math.cos(a) * r, y: Math.sin(e) * 90, z: Math.sin(a) * r, b: hash(i * 4.1) });
    }
})();

function mod24(h) {
    return ((h % 24) + 24) % 24;
}

function mix(a, b, t) {
    return a + (b - a) * t;
}

// Sample the sky curve at `h` hours: packed top/horizon colours and the light
// factor, interpolated between the two surrounding keyframes.
function skySample(h) {
    let i = 0;
    while (i < SKY_KEYS.length - 2 && h > SKY_KEYS[i + 1].h) i += 1;
    const a = SKY_KEYS[i];
    const b = SKY_KEYS[i + 1];
    const span = b.h - a.h;
    const t = span > 0 ? (h - a.h) / span : 0;
    return {
        top: rl.color(
            Math.round(mix(a.top[0], b.top[0], t)),
            Math.round(mix(a.top[1], b.top[1], t)),
            Math.round(mix(a.top[2], b.top[2], t)), 255),
        bot: rl.color(
            Math.round(mix(a.bot[0], b.bot[0], t)),
            Math.round(mix(a.bot[1], b.bot[1], t)),
            Math.round(mix(a.bot[2], b.bot[2], t)), 255),
        light: mix(a.light, b.light, t),
    };
}

// Multiply a packed 0xRRGGBBAA colour by per-channel factors.
function scaleColor(packed, fr, fg, fb) {
    return rl.color(
        Math.round(((packed >>> 24) & 255) * fr),
        Math.round(((packed >>> 16) & 255) * fg),
        Math.round(((packed >>> 8) & 255) * fb),
        255);
}

// Refresh the scene's ambient tint once per frame: a dim, blue-shifted version
// of daylight, plus the palette the fallback goat and terrain are drawn with.
function updateAmbient() {
    const t = skyLight;
    // Warm the light around dawn and dusk (light factor near 0.3).
    const warm = Math.max(0, Math.min(1, 1 - Math.abs(t - 0.3) / 0.34));
    skyWarm = warm;
    ambR = Math.min(1, 0.40 + 0.60 * t + 0.14 * warm);
    ambG = Math.min(1, 0.44 + 0.56 * t + 0.02 * warm);
    ambB = Math.min(1, 0.62 + 0.38 * t - 0.14 * warm);
    ambTint = rl.color(Math.round(255 * ambR), Math.round(255 * ambG), Math.round(255 * ambB), 255);
    ambFur = scaleColor(FUR, ambR, ambG, ambB);
    ambFurDk = scaleColor(FUR_DK, ambR, ambG, ambB);
    ambDark = scaleColor(DARK, ambR, ambG, ambB);
    ambHorn = scaleColor(HORN, ambR, ambG, ambB);
    ambHoof = scaleColor(HOOF, ambR, ambG, ambB);
    ambEye = scaleColor(EYE, ambR, ambG, ambB);
    ambTuft = scaleColor(TUFT, ambR, ambG, ambB);
    const dark = 1 - 0.5 * t;
    ambShadow = scaleColor(GROUND, ambR * dark, ambG * dark, ambB * dark);
}

function drawStars() {
    const fade = (0.35 - skyLight) / 0.35;
    if (fade <= 0) return;
    for (let i = 0; i < STARS.length; i++) {
        const s = Math.round((120 + 135 * STARS[i].b) * fade);
        rl.drawPoint3D(goat.px + STARS[i].x, STARS[i].y, goat.pz + STARS[i].z,
            rl.color(s, s, Math.min(255, s + 25), 255));
    }
}

// ---- the sun and moon (M2) ------------------------------------------------
//
// Two spheres on the light's own line through the goat: the sun at `SUN_DIR` and
// the moon at the other end of it, 600 units out, drawn with the celestial program
// (lighting.js) so the moon carries a terminator and the sun's disc stays flat.
//
// What this replaces was a stack of camera-facing sprites at 70 units, and three
// things about it read as glitches. The discs were placed in the plane `z =
// goat.pz` -- their direction had no tilt -- while the sky's glow, the cloud light
// and the shadow map all use `LIGHT_DIR`, which carries the arc's tilt, so the halo
// sat about ten degrees off the disc it belonged to and the clouds were lit from
// somewhere else. The elevation gates (`dy > -0.25`) drew each body for an hour and
// a half *below* the horizon, where the terrain slab ends, so a disc hung in the
// void under the world instead of setting. And at 70 units the sky slid with the
// goat: a body that close swings ten degrees when the goat walks ten metres.
//
// Now the bodies sit on the light's own line, they are gone once they are below the
// horizon (faded over the last few degrees, so a set does not pop), and at 600
// units a walk across the meadow moves them about a degree.
const CELESTIAL_R = 600;
// The angular size the discs had as sprites -- about 2.6 degrees for the sun and
// 2.5 for the moon, a shade smaller because it is.
const SUN_RADIUS = 13.6;
const MOON_RADIUS = 12.9;
// What the weather takes off a body *before* the clouds are drawn over it: the
// cloud layer is composited after the bodies (sky.js, `SKY_LAYER_CLOUD`), so a
// cloud that covers a disc hides it, and this is the haze a broken sky still
// leaves -- a disc glows dimmer through a gap than it does in the clear. And the
// elevation over which a body fades out at the horizon, as the sine of the angle
// -- a flat world's horizon is a hard line, so this stands in for setting behind
// it.
const CELESTIAL_CLOUD_FADE = 0.55;
const CELESTIAL_HORIZON = 0.05;
// The sun's glare, as two elements: a tight one on the disc, and a wide faint halo
// under it, which is what makes it read as a sun rather than as a bright circle.
// Both are multiples of the disc's radius.
const CELESTIAL_GLARE = 5.2;
const CELESTIAL_HALO = 11.0;
const SUN_TINT = [255, 246, 214];
const MOON_TINT = [238, 234, 222];
let sunMesh = -1;
let moonMesh = -1;

// One unit sphere as a `makeModel` mesh, wound outward (the terrain's grid winding
// would put the front faces on the inside -- a sphere's grid closes back on itself)
// with normals so it can be shaded and UVs so the moon can carry a surface. 48
// columns by 24 rows keeps the disc from reading as a polygon at the few dozen
// pixels it covers.
function makeSphereMesh() {
    const COLS = 48, ROWS = 24;
    const count = (COLS + 1) * (ROWS + 1);
    const verts = new Array(count * 3);
    const norms = new Array(count * 3);
    const cols = new Array(count * 4);
    const uvs = new Array(count * 2);
    for (let j = 0; j <= ROWS; j++) {
        const v = j / ROWS;
        const phi = v * Math.PI;
        const sp = Math.sin(phi);
        const cp = Math.cos(phi);
        for (let i = 0; i <= COLS; i++) {
            const u = i / COLS;
            const th = u * Math.PI * 2;
            const x = sp * Math.cos(th);
            const y = cp;
            const z = sp * Math.sin(th);
            const k = j * (COLS + 1) + i;
            verts[k * 3] = x;
            verts[k * 3 + 1] = y;
            verts[k * 3 + 2] = z;
            norms[k * 3] = x;
            norms[k * 3 + 1] = y;
            norms[k * 3 + 2] = z;
            cols[k * 4] = 255;
            cols[k * 4 + 1] = 255;
            cols[k * 4 + 2] = 255;
            cols[k * 4 + 3] = 255;
            uvs[k * 2] = u;
            uvs[k * 2 + 1] = 1 - v;
        }
    }
    const idx = new Array(COLS * ROWS * 6);
    let t = 0;
    for (let j = 0; j < ROWS; j++) {
        for (let i = 0; i < COLS; i++) {
            const a = j * (COLS + 1) + i;
            const b = a + 1;
            const c = a + COLS + 1;
            const d = c + 1;
            idx[t++] = a; idx[t++] = b; idx[t++] = c;
            idx[t++] = b; idx[t++] = d; idx[t++] = c;
        }
    }
    return rl.makeModel(verts, idx, norms, cols, uvs);
}

// The two bodies, built with the sky's other assets -- before the terrain's mesh,
// since the harness reads the *last* mesh built and that has to stay the terrain.
// `makeModel` rather than `drawSphere`: immediate-mode geometry carries no normals,
// so a sphere drawn that way cannot be shaded at all, which is why the bodies used
// to be sprites.
function makeCelestial() {
    if (!TERRAIN_MESH_OK) {
        console.log("celestial: engine has no makeModel - the sun and moon are not drawn");
        return;
    }
    sunMesh = makeSphereMesh();
    moonMesh = makeSphereMesh();
    if (moonTex >= 0) rl.setModelTexture(moonMesh, 0, moonTex);
    console.log("celestial: sun " + sunMesh + ", moon " + moonMesh + ", r " + CELESTIAL_R);
}

// Where a body is and how opaque it is, from the sun's direction and which end of
// the line the body sits on (`side` 1 or -1). The one rule the draw and
// `sceneCelestial` share, so what a test reads is what is drawn; `alpha` is what
// the tint carries, so zero means not drawn at all.
function celestialPlacement(side, cover) {
    const up = SUN_DIR[1] * side;
    const fade = up <= 0 ? 0 : Math.min(1, up / CELESTIAL_HORIZON);
    return {
        x: goat.px + SUN_DIR[0] * side * CELESTIAL_R,
        y: up * CELESTIAL_R,
        z: goat.pz + SUN_DIR[2] * side * CELESTIAL_R,
        elevation: up,
        alpha: Math.round(255 * cover * fade),
    };
}

// What the weather takes off a body, 0..1.
function celestialCover() {
    return 1 - CELESTIAL_CLOUD_FADE * cloudiness;
}

// One body: the glare first -- a radial gradient is the one sprite that cannot look
// wrong however the camera turns -- and the sphere over it. `shaded` is 0 on the
// sun, whose disc is the light, and 1 on the moon, which is lit by the sun. All of
// it sits between the sky's two layers, so the cloud layer lands over the top.
function drawCelestialBody(mesh, side, radius, tint, shaded, glare, cover) {
    if (mesh < 0) return;
    const place = celestialPlacement(side, cover);
    if (place.alpha <= 2) return;
    // A low disc reddens, the way the sky's own glow does. Only the sun warms
    // (`shaded` 0 is the body that *is* the light); a setting moon stays grey.
    const warm = shaded === 0 ? Math.min(1, Math.max(0, place.elevation / 0.30)) : 1;
    const r = tint[0];
    const g = Math.round(tint[1] * (0.78 + 0.22 * warm));
    const b = Math.round(tint[2] * (0.42 + 0.58 * warm));
    if (glare > 0 && glowTex >= 0) {
        // Additive: the glare *adds* light to the sky it hangs in rather than
        // greying that sky toward its own colour, which is what glare is. The alpha
        // blend was a stand-in for this from when the `rl` surface had no blend
        // modes at all.
        const additive = typeof rl.beginBlendMode === "function";
        if (additive) rl.beginBlendMode(rl.BLEND_ADDITIVE);
        // The wide halo under the tight one: a single billboard reads as a bright
        // circle rather than as glare.
        rl.drawBillboard(glowTex, place.x, place.y, place.z, radius * CELESTIAL_HALO,
            rl.color(r, g, b, Math.round(place.alpha * 0.10)));
        rl.drawBillboard(glowTex, place.x, place.y, place.z, radius * glare,
            rl.color(r, g, b, Math.round(place.alpha * 0.35)));
        if (additive) rl.endBlendMode();
    }
    if (celestialShader >= 0) {
        rl.setShaderValue(celestialShader, celestialUniforms.shaded, shaded,
            rl.SHADER_UNIFORM_FLOAT);
    }
    rl.drawModelEx(mesh, place.x, place.y, place.z, 0, 1, 0, 0,
        radius, radius, radius, rl.color(r, g, b, place.alpha));
}

// The sun and the moon, on opposite ends of the light's line, arcing east to west
// between 06:00 and 18:00. The frame calls this between the sky's two layers
// (goat.js), which is what puts both bodies -- and the sun's glare -- behind the
// clouds.
function drawCelestial(cx, cy, cz) {
    if (sunMesh < 0 && moonMesh < 0) return;
    setCelestialUniforms(cx, cy, cz);
    const cover = celestialCover();
    drawCelestialBody(sunMesh, 1, SUN_RADIUS, SUN_TINT, 0.0, CELESTIAL_GLARE, cover);
    drawCelestialBody(moonMesh, -1, MOON_RADIUS, MOON_TINT, 1.0, 0, cover);
}

// What the two bodies are doing, as numbers. The geometry is the part a test can
// check without a GPU, and it is the part that was wrong: whether each body is on
// the line the light comes from (`sunDot` is +1 when the light is the sun and -1
// when it is the moon), whether it is above the horizon, and how much of it the
// weather leaves.
function sceneCelestial() {
    const cover = celestialCover();
    const sun = celestialPlacement(1, cover);
    const moon = celestialPlacement(-1, cover);
    return {
        hour: worldTime,
        radius: CELESTIAL_R,
        goat: [goat.px, goat.pz],
        sun: sun,
        moon: moon,
        light: [LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]],
        sunDir: [SUN_DIR[0], SUN_DIR[1], SUN_DIR[2]],
        sunDot: SUN_DIR[0] * LIGHT_DIR[0] + SUN_DIR[1] * LIGHT_DIR[1] + SUN_DIR[2] * LIGHT_DIR[2],
        meshes: [sunMesh, moonMesh],
        shaded: celestialShader >= 0,
    };
}

// Cheap contact shadow: a flattened dark rectangle under the goat, darker and
// longer-lived the higher the sun. Used only when the lit shader is unavailable;
// with lighting on the goat casts a real projected silhouette (see below).
function drawShadow() {
    if (skyLight <= 0.05) return;
    // Sits on the terrain; the 0.06 offset clears the local slope.
    rl.drawCube(goat.px, terrainHeight(goat.px, goat.pz) + 0.06, goat.pz,
        1.25, 0.012, 1.7, ambShadow);
}

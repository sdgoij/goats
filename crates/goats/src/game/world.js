// ---- scenery -------------------------------------------------------------

// Grass is generated procedurally around the goat in `drawTufts` (weather.js),
// so the field extends as far as the eye (and the shadow pass) can see and never
// leaves bare ground behind after a walk.

// ---- terrain -------------------------------------------------------------
//
// The ground is a heightfield drawn as three surfaces rather than a field of
// cubes: a detailed 48x48-quad grid around the goat, a 4 m mid ring out to 96 m,
// and an 8 m far ring out to 192 m, with a seam strip at each join. All
// are built through `rl.makeModel`, so they carry real per-vertex normals, UVs
// and colours. Immediate-mode geometry cannot: `drawCube` and `drawTriangle3D`
// leave raylib's default normal (0, 0, 1) and texcoord (0, 0), so a heightfield
// built from them is mis-lit and untexturable -- and a cube per cell measures
// ~14 us, which caps a frame at roughly 100 cells. A handful of `drawModelEx`
// calls replace what would be hundreds.
//
// The height is hills plus mountains: three octaves of rolling noise, a fourth for
// the detail the 2 m cells can resolve, and a ridge field that stands the range up
// beyond `terrain.mountainFlat`. The peaks are the reason the goat can fly -- they
// are tens of metres above the spawn meadow, far past anything a jump reaches --
// and their snow line at 26 m is above the cloud deck, so the summit reads out of
// the weather.
//
// `terrainHeight` is the single source of truth for the ground: the goat, the
// herd, the grass, the eyes and both shadows all read it, so nothing floats or
// sinks as the ground rises.
//
// A vertex's *normal and colour* are a function of where it is, not of which grid
// holds it: both are measured over `TERRAIN_SLOPE_STEP` metres of the field, the
// same stencil at every level of detail. That is what stops the three surfaces
// from reading as three surfaces. Each grid's own cell is the obvious stencil and
// the wrong one -- a 2 m central difference and an 8 m one describe the same hill
// differently (the fourth noise octave is ~3.4 m, at the 2 m grid's own Nyquist
// limit), and the difference lands exactly on the join between two of them. With
// one stencil the three agree vertex for vertex wherever they share a world point,
// so a seam is a change of triangle density and nothing else.
//
// The border that *was* visible from the air was not this one: it was the lit
// program reaching the near grid and not the rings. See `terrainRebind` and the
// call in `makeLighting`.

const TERRAIN_CELL = 2;         // world units per grid cell (matches the grass)
const TERRAIN_QUADS = 48;       // quads per side: a field of +/- 48 units
const TERRAIN_DETAIL = 256;     // detail-texture size, in pixels

// Two coarse rings outside the near grid. Both are a 48x48 grid whose square
// hole is half their own half-extent, so they share one index topology: the mid
// ring's 4 m cells carry the 48..96 m band, where the old 8 m ring's facets read
// as tiles, and the far ring's 8 m cells run from 96 to 192 m.
const TERRAIN_MID_CELL = 4;
const TERRAIN_MID_HALF = 96;
const TERRAIN_FAR_CELL = 8;
const TERRAIN_FAR_HALF = 192;
const TERRAIN_RING_QUADS = 48;
const TERRAIN_RING_HOLE = 24;   // quads per side removed for the hole

// The one stencil every surface's normal and material are measured over, in
// metres. Four is the widest step that all three grids can agree on: the near
// grid reads it from its own heights (2 cells), the mid ring from its own (1
// cell), and the far ring -- whose cells are 8 m, so it has no sample at +/-4 --
// from the field itself. One stencil, three ways to reach it, one answer.
const TERRAIN_SLOPE_STEP = 4.0;
const T_SLOPE_CELLS = TERRAIN_SLOPE_STEP / TERRAIN_CELL;        // 2
const M_SLOPE_CELLS = TERRAIN_SLOPE_STEP / TERRAIN_MID_CELL;    // 1
// 0 means "not a whole number of cells": that grid reads the field instead.
const F_SLOPE_CELLS = 0;

// Per-cell ground heights for the grass, keyed by cell. The field is
// world-anchored, so a cell's height never changes; the cache keeps `drawTufts`
// from paying the noise for every cell of the visible field on every frame
// (which measured ~2 ms/frame at 1440p). It follows the goat, so it is cleared
// rather than growing without bound.
const TERRAIN_CELL_H = new Map();

// The ground palette. The mesh carries these as per-vertex colours, so adjacent
// cells blend and a material boundary reads as a gradient rather than a tile.
const T_ROCK = [128, 122, 112];
const T_MUD = [104, 84, 62];
const T_SAND = [198, 178, 130];
const T_GRASS = [98, 150, 84];
const T_GRASS_DK = [78, 126, 66];
const T_HILL = [126, 146, 74];
// The caps, which are what give a 30 m peak a readable height from the valley.
const T_SNOW = [232, 238, 245];
// Where `terrainMaterial` writes its answer: one scratch colour, so the
// per-vertex path allocates nothing.
const TERRAIN_MAT = [0, 0, 0];

// The mesh binding the heightfield needs. Without it the ground falls back to
// the flat slab and `terrainHeight` stays at zero, so placement maths still
// works.
const TERRAIN_MESH_OK = typeof rl.makeModel === "function";

let terrainMesh = -1;
// The two coarse rings, drawn under and outside the near one. Separate handles
// because the near grid has to stay the last `makeModel` the engine sees (the
// harness and the app both read the near grid's facts off the newest mesh).
let terrainMid = -1;
let terrainFar = -1;
// The seam strips: the vertical lens between a fine edge and the coarse chord
// that meets it. The near grid's 2 m edge and the mid ring's 4 m edge share
// *positions* but not *heights* -- the coarse edge is a straight chord between
// every other fine vertex -- so the two surfaces leave a lens you can see
// through at a grazing angle. A strip from each fine vertex to the chord at the
// same (x, z) closes it exactly, and unlike a constant-depth skirt it has no
// depth to fight with and no depth to run out of.
let terrainNearSeam = -1;
let terrainMidSeam = -1;
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
// The lit program's `detailFade` uniform, looked up once per program. It is the
// switch that lets the shared lit shader fade the ground's grain with distance
// without touching the goat or the herd, whose own textures must not fade.
let terrainFadeLoc = -1;
let terrainFadeShader = -2;
let terrainFadeOn = false;
// The last anchor this reported on. The log is for the anchor moves -- one line per 24
// units of walking -- rather than for every rebuild: a crater near the goat rebuilds the
// mesh a handful of times over its four minutes, and none of that is news, nor should it
// grow the in-game console without bound.
let terrainLogX = NaN;
let terrainLogZ = NaN;

// Smooth 0..1 value noise, four octaves: broad hills with smaller bumps on top.
// The last octave is the detail the near grid's 2 m cells can resolve -- a 3 m
// feature is four vertices across -- and it is what keeps a hillside from reading
// as a smooth sheet up close.
function terrainShape(x, z) {
    return 0.58 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1) +
        0.25 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9) +
        0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3) +
        0.05 * vnoise2(x * 0.29 + 5.3, z * 0.29 + 33.7);
}

// The mountains: two ridge octaves (a ridge is the fold of a value-noise field,
// `1 - |2n - 1|`, which is what turns blobs into crests) under a low-frequency
// mask, so the range has passes and shoulders rather than cones. It is a pure
// function of the world like the hills, so the rings and the near grid sample
// the same ground.
function terrainRidge(x, z) {
    const broad = 1 - Math.abs(2 * vnoise2(x * 0.0105 + 91.3, z * 0.0105 + 17.9) - 1);
    const fine = 1 - Math.abs(2 * vnoise2(x * 0.028 + 3.7, z * 0.028 + 55.1) - 1);
    const ridge = 0.72 * broad + 0.28 * fine;
    const mask = smoothstep(0.30, 0.70, vnoise2(x * 0.0062 + 7.3, z * 0.0062 + 41.7));
    // Squared: the crests sharpen and the valleys flatten, which is the shape a
    // mountain range has and a sum of noise does not.
    return ridge * ridge * mask;
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
    // The mountains ramp in on their own, wider ring: the spawn meadow stays the
    // hills' own +/- 2 m, and the range only becomes a range past `mountainFlat`.
    let tm = (d - TUNING.terrain.mountainFlat) / TUNING.terrain.mountainRamp;
    tm = tm < 0 ? 0 : tm > 1 ? 1 : tm;
    tm = tm * tm * (3 - 2 * tm);
    return (terrainShape(x, z) - 0.5) * 2 * TUNING.terrain.relief * t +
        terrainRidge(x, z) * TUNING.terrain.mountain * tm;
}

// The goat's ground-contact height. `g.py` is the height *above* the ground
// (a jump, or the cube fallback's bob), so the terrain under it is added here and
// every part drawn from `g.py` lands on the surface.
function goatBaseY(g) {
    return terrainHeight(g.px, g.pz) + g.py;
}

// Ground material from the height, the slope (0 flat .. 1 steep) and a
// low-frequency patchiness noise: rock takes the peaks and scarps, mud the
// hollows, sand the dry flat patches, and grass everything else. The two height
// lines are *perturbed by that noise*, which is what keeps a contour from reading
// as a hard tile edge across a 4 m or 8 m ring.
//
// Every line here is a *band*, not a threshold. Each material is mixed in over a
// smoothstep ramp, in the order the old thresholds implied (snow over rock over
// mud over sand over hill over grass). A hard threshold is what turns the 14 m
// patchiness into 14 m *tiles*: the palette entry flips over one vertex, so the
// ground reads as a field of flat colour patches -- and the same hillside read at
// 2 m and at 8 m puts those borders in different places, which is what made a ring
// of LOD visible as a change of pattern. A ramp survives a change of sample rate as
// a slightly different shade instead of as a border, and it keeps the broad
// material variety the palette was there for.
function terrainMaterial(y, slope, m) {
    // Grass to dark grass over the patchiness. Same hue at two lightnesses, so
    // this one is the field's own broad variation rather than a material change.
    const g = smoothstep(0.35, 0.65, m);
    let r = T_GRASS[0] + (T_GRASS_DK[0] - T_GRASS[0]) * g;
    let gr = T_GRASS[1] + (T_GRASS_DK[1] - T_GRASS[1]) * g;
    let b = T_GRASS[2] + (T_GRASS_DK[2] - T_GRASS[2]) * g;

    // Hill, on the height the patchiness perturbs.
    const hillY = 0.35 + (m - 0.5) * 0.3;
    let w = smoothstep(hillY - 0.3, hillY + 0.3, y);
    r += (T_HILL[0] - r) * w;
    gr += (T_HILL[1] - gr) * w;
    b += (T_HILL[2] - b) * w;

    // Sand on the flat, dry patches: the flatter the ground and the drier the
    // patch noise, the more of it.
    w = (1 - smoothstep(0.05, 0.14, slope)) * smoothstep(0.52, 0.68, m);
    r += (T_SAND[0] - r) * w;
    gr += (T_SAND[1] - gr) * w;
    b += (T_SAND[2] - b) * w;

    // Mud in the hollows.
    w = (1 - smoothstep(-0.9, -0.35, y)) * (1 - smoothstep(0.5, 0.7, m));
    r += (T_MUD[0] - r) * w;
    gr += (T_MUD[1] - gr) * w;
    b += (T_MUD[2] - b) * w;

    // Rock on the scarps and above the hill line. The two routes to it are the
    // old `slope > 0.5 || y > ...`, kept as a maximum so a steep *and* high vertex
    // is still one rock vertex rather than two mixes.
    const rockY = 1.15 + (m - 0.5) * 0.6;
    w = Math.max(smoothstep(0.40, 0.62, slope), smoothstep(rockY - 0.45, rockY + 0.45, y));
    r += (T_ROCK[0] - r) * w;
    gr += (T_ROCK[1] - gr) * w;
    b += (T_ROCK[2] - b) * w;

    // Snow above the snow line, which the patchiness also moves.
    const snowY = 26 + (m - 0.5) * 3;
    w = smoothstep(snowY - 1.2, snowY + 1.2, y);
    r += (T_SNOW[0] - r) * w;
    gr += (T_SNOW[1] - gr) * w;
    b += (T_SNOW[2] - b) * w;

    TERRAIN_MAT[0] = r;
    TERRAIN_MAT[1] = gr;
    TERRAIN_MAT[2] = b;
    return TERRAIN_MAT;
}

// A subtle tiling detail texture (neutral noise around 0.88), so the material
// colours keep a grain up close without a texture atlas.
//
// The noise is **periodic**: every octave is a whole number of lattice cells
// across the tile, and the lattice wraps, so the pattern has no left/right or
// top/bottom edge. A non-periodic noise is cheap to write and wrong to tile --
// each repeat starts on a different value, so once the ground is far enough away
// for a repeat to be one flat colour the landscape is a chessboard of 8 m
// squares. The table is baked per octave because the per-pixel path would
// otherwise pay a `Math.sin` per lattice corner, 65k pixels at a time.
function terrainNoiseTable(period) {
    const table = new Array(period * period);
    for (let y = 0; y < period; y++) {
        for (let x = 0; x < period; x++) {
            table[y * period + x] = hash(x * 57.0 + y * 131.0);
        }
    }
    return table;
}

function terrainNoiseSample(table, period, x, y) {
    const xi = Math.floor(x);
    const yi = Math.floor(y);
    const xf = x - xi;
    const yf = y - yi;
    const u = xf * xf * (3 - 2 * xf);
    const v = yf * yf * (3 - 2 * yf);
    const x0 = ((xi % period) + period) % period;
    const y0 = ((yi % period) + period) % period;
    const x1 = x0 + 1 === period ? 0 : x0 + 1;
    const y1 = y0 + 1 === period ? 0 : y0 + 1;
    const a = table[y0 * period + x0];
    const b = table[y0 * period + x1];
    const c = table[y1 * period + x0];
    const d = table[y1 * period + x1];
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v;
}

function makeTerrainTexture() {
    const n = TERRAIN_DETAIL;
    // Four octaves, each an exact number of lattice cells across the tile: 1 m,
    // 35 cm, 13 cm and 5 cm features at the 8.3 m world period.
    const cells = [8, 24, 64, 160];
    const amp = [0.50, 0.27, 0.15, 0.08];
    const tables = [];
    for (let o = 0; o < cells.length; o++) tables.push(terrainNoiseTable(cells[o]));
    let pixels = "";
    for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
            let v = 0;
            for (let o = 0; o < cells.length; o++) {
                v += amp[o] * terrainNoiseSample(tables[o], cells[o],
                    x * cells[o] / n, y * cells[o] / n);
            }
            const c = Math.round(198 + 57 * clamp(v, 0, 1));
            pixels += HEX256[c] + HEX256[Math.round(c * 0.97)] +
                HEX256[Math.round(c * 0.88)] + "ff";
        }
    }
    terrainDetail = rl.makeTexture(n, n, pixels);
    // `makeTexture` comes back point-sampled, which is right for a mod's chunky
    // atlas and wrong for a ground grain magnified across a metre: point samples
    // of a 3 cm texel read as the squares the field looked pixelated with.
    if (terrainDetail >= 0 && typeof rl.setTextureFilter === "function" &&
        typeof rl.TEXTURE_FILTER_BILINEAR === "number") {
        rl.setTextureFilter(terrainDetail, rl.TEXTURE_FILTER_BILINEAR);
    }
}

// Build the grid at the current anchor: one `makeModel` call, replacing the
// previous mesh. `terrainEnsure` only calls this when the anchor has moved or the
// ground has changed, so between rebuilds the terrain costs a single draw.
//
// The arrays are the grid's, not the call's: they are allocated once and recomputed
// into. So is the index list -- the 48x48 topology never changes, whatever the anchor
// or the craters do -- and the recompute is limited to the rectangle that actually
// moved, which is a strip for a step and a handful of vertices for a crater.
//
// A step is **incremental**: every cell size divides the 32 unit snap, so the new
// grid is the old one shifted by whole cells. The overlapping vertices are the
// same world points and their attributes are copied, and only the strip the shift
// uncovered is resampled (~1900 points instead of ~7200). The shift is **in place**:
// the scene's arrays are module-level and this engine's collector does not record a
// write to a global slot, so handing a binding a fresh array is a write-barrier
// miss (and a panic). It also costs one less allocation per step.
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

// The two rings' arrays. Both grids are `RING_N` square at their own cell size,
// with the quads inside their hole left out of the index list; the heights are
// still filled there, because a vertex just outside the hole reads its inside
// neighbour for the normal. The unused inner vertices are zero and unreferenced --
// a few thousand floats nobody samples is cheaper than a second topology.
const RING_N = TERRAIN_RING_QUADS + 1;
const RING_HOLE0 = (TERRAIN_RING_QUADS - TERRAIN_RING_HOLE) / 2;
const RING_HOLE1 = (TERRAIN_RING_QUADS + TERRAIN_RING_HOLE) / 2;
const RING_IDX = new Array((TERRAIN_RING_QUADS * TERRAIN_RING_QUADS -
    (RING_HOLE1 - RING_HOLE0) * (RING_HOLE1 - RING_HOLE0)) * 6);
let terrainRingIdxBuilt = false;

const M_H = new Array(RING_N * RING_N);
// Filled with zeroes up front: the hole's interior is never indexed, but the
// engine's `makeModel` takes a flat array of numbers and a sparse array is not
// one. The ring overwrites every entry it uses; the rest stay zero and unseen.
const M_VERTS = new Array(RING_N * RING_N * 3).fill(0);
const M_NORMS = new Array(RING_N * RING_N * 3).fill(0);
const M_COLS = new Array(RING_N * RING_N * 4).fill(0);
const M_UVS = new Array(RING_N * RING_N * 2).fill(0);

const F_H = new Array(RING_N * RING_N);
const F_VERTS = new Array(RING_N * RING_N * 3).fill(0);
const F_NORMS = new Array(RING_N * RING_N * 3).fill(0);
const F_COLS = new Array(RING_N * RING_N * 4).fill(0);
const F_UVS = new Array(RING_N * RING_N * 2).fill(0);

// One seam strip's arrays, reused for both seams: `makeModel` copies them into
// the engine, so the near strip and the mid strip can be built from the same
// objects. The perimeter is the same 49-vertex square for both; the indices are
// static.
const SEAM_COUNT = 4 * RING_N - 4;
const SEAM_I = new Array(SEAM_COUNT);
const SEAM_J = new Array(SEAM_COUNT);
const SEAM_VERTS = new Array(SEAM_COUNT * 2 * 3).fill(0);
const SEAM_NORMS = new Array(SEAM_COUNT * 2 * 3).fill(0);
const SEAM_COLS = new Array(SEAM_COUNT * 2 * 4).fill(0);
const SEAM_UVS = new Array(SEAM_COUNT * 2 * 2).fill(0);
const SEAM_IDX = new Array(SEAM_COUNT * 12);
let seamPerimeterBuilt = false;

// The perimeter of a ring's *hole*, in the same order as a surface's own
// perimeter and with half the vertices: the near grid's 2 m edge meets the mid
// ring's 4 m hole, and the mid ring's 4 m edge meets the far ring's 8 m one, so
// both seams are exactly two fine vertices per coarse one. That ratio is what
// lets `terrainSeamBuild` find the chord's height under a fine vertex by
// interpolating between one coarse vertex and the next.
const HOLE_N = RING_HOLE1 - RING_HOLE0 + 1;
const HOLE_PERIM = 4 * HOLE_N - 4;
const HOLE_I = new Array(HOLE_PERIM);
const HOLE_J = new Array(HOLE_PERIM);

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

// The vertices a pending patch touches, widened on every side by the shared
// stencil: the normals are central differences over `TERRAIN_SLOPE_STEP`, so a
// vertex that far from the change has to be rewritten too.
function terrainPatchRect(p) {
    const x0 = terrainAnchorX - T_HALF;
    const z0 = terrainAnchorZ - T_HALF;
    const pad = T_SLOPE_CELLS;
    return {
        i0: terrainClampIndex(Math.floor((p.minX - x0) / TERRAIN_CELL) - pad),
        i1: terrainClampIndex(Math.ceil((p.maxX - x0) / TERRAIN_CELL) + pad),
        j0: terrainClampIndex(Math.floor((p.minZ - z0) / TERRAIN_CELL) - pad),
        j1: terrainClampIndex(Math.ceil((p.maxZ - z0) / TERRAIN_CELL) + pad),
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

// The slope at a world point, from the field itself, over the shared
// `TERRAIN_SLOPE_STEP`. Used wherever a grid has no sample on both sides of the
// stencil: every vertex of the far ring (8 m cells, so no +/-4 m neighbour) and
// the edge band of the two grids that do (the central difference would run off
// the array). Those are exactly the vertices a seam shares with a coarser
// surface, so both sides take the same route to the same number.
function terrainSlopeAt(wx, wz) {
    const d = TERRAIN_SLOPE_STEP;
    TERRAIN_SLOPE[0] = (terrainBaseHeight(wx + d, wz) - terrainBaseHeight(wx - d, wz)) / (2 * d);
    TERRAIN_SLOPE[1] = (terrainBaseHeight(wx, wz + d) - terrainBaseHeight(wx, wz - d)) / (2 * d);
}

// Scratch for `terrainSlopeAt`, so the per-vertex path allocates nothing.
const TERRAIN_SLOPE = [0, 0];

// One vertex's position, normal, colour and texcoord. One function for the near
// grid and the rings: they differ only in spacing and in how they reach the
// shared stencil.
//
// `stepCells` is `TERRAIN_SLOPE_STEP` in this grid's cells (2 for the near grid, 1
// for the mid ring, 0 for the far one, which reads the field). It is the whole of
// the LOD difference: with the same stencil on every surface, a world point's
// normal and colour do not depend on which grid drew it, so a seam is a change of
// triangle density and nothing else.
function terrainGridVertex(H, VERTS, NORMS, COLS, UVS, half, cell, n, k, i, j, stepCells) {
    const wx = terrainAnchorX - half + i * cell;
    const wz = terrainAnchorZ - half + j * cell;
    const y = H[k];
    VERTS[k * 3] = wx;
    VERTS[k * 3 + 1] = y;
    VERTS[k * 3 + 2] = wz;
    // Central differences over `TERRAIN_SLOPE_STEP`, so the shading is smooth
    // across cells and the *scale* of it is the same on every surface. The edge
    // band and the far ring read the field instead: a one-sided difference is a
    // slope *near* the vertex rather than at it, and the vertex on the other side
    // of a seam is measured centrally, so the two would disagree on the shared
    // point -- which is exactly the border this stencil exists to remove.
    const span = 2 * TERRAIN_SLOPE_STEP;
    let dx, dz;
    if (stepCells < 1 || i < stepCells || i > n - 1 - stepCells ||
        j < stepCells || j > n - 1 - stepCells) {
        terrainSlopeAt(wx, wz);
        dx = TERRAIN_SLOPE[0];
        dz = TERRAIN_SLOPE[1];
    } else {
        dx = (H[k + stepCells] - H[k - stepCells]) / span;
        dz = (H[k + stepCells * n] - H[k - stepCells * n]) / span;
    }
    const inv = 1 / Math.sqrt(dx * dx + dz * dz + 1);
    NORMS[k * 3] = -dx * inv;
    NORMS[k * 3 + 1] = inv;
    NORMS[k * 3 + 2] = -dz * inv;
    const c = terrainMaterial(y, Math.min(1, Math.sqrt(dx * dx + dz * dz)),
        vnoise2(wx * 0.07 + 3.1, wz * 0.07 + 9.7));
    COLS[k * 4] = c[0];
    COLS[k * 4 + 1] = c[1];
    COLS[k * 4 + 2] = c[2];
    COLS[k * 4 + 3] = 255;
    UVS[k * 2] = wx * TUNING.terrain.uv;
    UVS[k * 2 + 1] = wz * TUNING.terrain.uv;
}

// Write every vertex of `rects` for one grid.
function terrainWriteRects(H, VERTS, NORMS, COLS, UVS, half, cell, n, rects, stepCells) {
    for (let r = 0; r < rects.length; r++) {
        const rect = rects[r];
        for (let j = rect.j0; j <= rect.j1; j++) {
            const row = j * n;
            for (let i = rect.i0; i <= rect.i1; i++) {
                terrainGridVertex(H, VERTS, NORMS, COLS, UVS, half, cell, n, row + i, i, j, stepCells);
            }
        }
    }
}

// ---- incremental grids ----------------------------------------------------
//
// Every cell size divides `TUNING.terrain.snap`, so a snapped step is the same
// grid shifted by whole cells. The overlapping vertices describe the same world
// points, so their heights and attributes are copied and only the strip the shift
// uncovered is sampled -- ~1900 field calls instead of ~7200, which is what makes
// a step affordable in a browser frame.

// How many cells a snapped step is in this grid's units; `n` when the move is not
// a whole number of cells or is at least the whole grid (a teleport).
function terrainShift(delta, cell, n) {
    const steps = delta / cell;
    const rounded = Math.round(steps);
    if (Math.abs(steps - rounded) > 1e-5 || Math.abs(rounded) >= n) return n;
    return rounded;
}

// A grid's heights after the anchor moved by (di, dj) cells. In place: the new
// position of a cell is `i + di`, so iterating away from the side the rows/columns
// move toward never overwrites a source that a later cell still needs.
function terrainShiftHeights(H, x0, z0, cell, n, di, dj, full) {
    if (full || H.length !== n * n) {
        for (let j = 0; j < n; j++) {
            const wz = z0 + j * cell;
            const row = j * n;
            for (let i = 0; i < n; i++) H[row + i] = terrainBaseHeight(x0 + i * cell, wz);
        }
        return;
    }
    const jStep = dj > 0 ? 1 : -1;
    for (let j = dj > 0 ? 0 : n - 1; j >= 0 && j < n; j += jStep) {
        const row = j * n;
        const sj = j + dj;
        if (sj < 0 || sj >= n) {
            const wz = z0 + j * cell;
            for (let i = 0; i < n; i++) H[row + i] = terrainBaseHeight(x0 + i * cell, wz);
            continue;
        }
        const srow = sj * n;
        const iStep = di > 0 ? 1 : -1;
        for (let i = di > 0 ? 0 : n - 1; i >= 0 && i < n; i += iStep) {
            const si = i + di;
            if (si >= 0 && si < n) H[row + i] = H[srow + si];
            else H[row + i] = terrainBaseHeight(x0 + i * cell, z0 + j * cell);
        }
    }
}

// The attribute arrays after the same shift, also in place. Entries outside the
// overlap keep their old values until `terrainDirtyRects` rewrites them.
function terrainShiftAttr(A, n, stride, di, dj) {
    if (di === 0 && dj === 0) return;
    const jStep = dj > 0 ? 1 : -1;
    for (let j = dj > 0 ? 0 : n - 1; j >= 0 && j < n; j += jStep) {
        const sj = j + dj;
        if (sj < 0 || sj >= n) continue;
        const drow = j * n;
        const srow = sj * n;
        const iStep = di > 0 ? 1 : -1;
        for (let i = di > 0 ? 0 : n - 1; i >= 0 && i < n; i += iStep) {
            const si = i + di;
            if (si < 0 || si >= n) continue;
            const d = (drow + i) * stride;
            const s = (srow + si) * stride;
            for (let c = 0; c < stride; c++) A[d + c] = A[s + c];
        }
    }
}

// The blocks a shift made new, widened by `pad` vertices so the normals on the
// inner edge read the new neighbour. A move on both axes exposes two strips,
// whose union is an L -- not the corner their bounding box would be.
function terrainDirtyRects(n, di, dj, full, pad) {
    if (full || (di === 0 && dj === 0)) return [{ i0: 0, i1: n - 1, j0: 0, j1: n - 1 }];
    const rects = [];
    if (di !== 0) {
        const i0 = di > 0 ? n - di : 0;
        const i1 = di > 0 ? n - 1 : -di - 1;
        rects.push({
            i0: Math.max(0, i0 - pad), i1: Math.min(n - 1, i1 + pad), j0: 0, j1: n - 1,
        });
    }
    if (dj !== 0) {
        const j0 = dj > 0 ? n - dj : 0;
        const j1 = dj > 0 ? n - 1 : -dj - 1;
        rects.push({
            i0: 0, i1: n - 1, j0: Math.max(0, j0 - pad), j1: Math.min(n - 1, j1 + pad),
        });
    }
    return rects;
}

// One axis' edge bits: 1 for a vertex whose shared stencil runs off that axis'
// array, which is the band `stepCells` wide at each end. For the near grid that
// is two vertices, for the mid ring one, and for the far ring none -- it reads
// the field at every vertex, so its rule never changes and the pass below does
// nothing there.
function terrainAxisBits(n, stepCells) {
    const near = new Array(n);
    for (let v = 0; v < n; v++) {
        near[v] = (v < stepCells || v > n - 1 - stepCells) ? 1 : 0;
    }
    return near;
}

// Recompute the copied vertices whose *edge rule* changed under the shift. A world
// point that was in the edge band and is now interior was shaded one-sided, and
// one that moved into the band with the central difference. The rule is
// `near(i) or near(j)`, so one bit per axis answers a whole row at a time.
function terrainFixEdgeChanges(H, VERTS, NORMS, COLS, UVS, half, cell, n, di, dj, stepCells) {
    if (stepCells < 1) return;
    const near = terrainAxisBits(n, stepCells);
    for (let j = 0; j < n; j++) {
        const sj = j + dj;
        if (sj < 0 || sj >= n) continue;
        const nj = near[j];
        const sjn = near[sj];
        const row = j * n;
        for (let i = 0; i < n; i++) {
            const si = i + di;
            if (si < 0 || si >= n) continue;
            if ((near[i] | nj) !== (near[si] | sjn)) {
                terrainGridVertex(H, VERTS, NORMS, COLS, UVS, half, cell, n, row + i, i, j, stepCells);
            }
        }
    }
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

// The tail every near-grid build shares: craters over the freshly sampled cells,
// the attributes over the rectangles that need them, the seam strip (which hangs
// off the boundary), the water rebuild, and the upload. The terrain has to be the
// last mesh the engine is handed, because that is the one the harness reads its
// facts back off, so `terrainUpload` is last and the water (also a `makeModel`
// mesh) is before it.
function terrainApplyNear(attrRects, craterRects, waterRects) {
    terrainStampCraters(craterRects);
    terrainWriteRects(T_H, T_VERTS, T_NORMS, T_COLS, T_UVS, T_HALF, TERRAIN_CELL, T_N,
        attrRects, false);
    terrainNearSeam = terrainSeamBuild(T_H, T_NORMS, T_COLS, T_UVS,
        T_HALF, TERRAIN_CELL, M_H, terrainNearSeam);
    waterRebuild(waterRects);
    terrainUpload();
}

// A crater patch or a collapse: the heights are sampled again for the rectangles
// (which `terrainPatchRect` has already widened by the shared stencil), then the
// usual tail.
function terrainBuildRects(rects) {
    if (!terrainIdxBuilt) { terrainIndices(); terrainIdxBuilt = true; }
    for (let r = 0; r < rects.length; r++) {
        const rect = rects[r];
        for (let j = rect.j0; j <= rect.j1; j++) terrainHeightRow(j, rect.i0, rect.i1);
    }
    terrainApplyNear(rects, rects, rects);
}

// A snapped anchor move: shift the three grids and resample only the strips the
// shift uncovered. `forceFull` is a teleport, a first build, or a move on the same
// frame the ground itself changed (a crater the shift would otherwise carry over
// unstamped).
function terrainStep(prevX, prevZ, forceFull) {
    if (!terrainIdxBuilt) { terrainIndices(); terrainIdxBuilt = true; }
    if (!terrainRingIdxBuilt) { terrainRingIndices(); terrainRingIdxBuilt = true; }
    const dx = terrainAnchorX - prevX;
    const dz = terrainAnchorZ - prevZ;
    let full = forceFull || !isFinite(prevX) || !isFinite(prevZ);
    let di = 0, dj = 0, mdi = 0, mdj = 0, fdi = 0, fdj = 0;
    if (!full) {
        di = terrainShift(dx, TERRAIN_CELL, T_N);
        dj = terrainShift(dz, TERRAIN_CELL, T_N);
        mdi = terrainShift(dx, TERRAIN_MID_CELL, RING_N);
        mdj = terrainShift(dz, TERRAIN_MID_CELL, RING_N);
        fdi = terrainShift(dx, TERRAIN_FAR_CELL, RING_N);
        fdj = terrainShift(dz, TERRAIN_FAR_CELL, RING_N);
        if (di >= T_N || dj >= T_N || mdi >= RING_N || mdj >= RING_N ||
            fdi >= RING_N || fdj >= RING_N) full = true;
    }
    if (full) { di = 0; dj = 0; mdi = 0; mdj = 0; fdi = 0; fdj = 0; }

    // Far first: the mid seam interpolates the far ring's hole heights.
    terrainShiftHeights(F_H, terrainAnchorX - TERRAIN_FAR_HALF,
        terrainAnchorZ - TERRAIN_FAR_HALF, TERRAIN_FAR_CELL, RING_N, fdi, fdj, full);
    terrainShiftAttr(F_VERTS, RING_N, 3, fdi, fdj);
    terrainShiftAttr(F_NORMS, RING_N, 3, fdi, fdj);
    terrainShiftAttr(F_COLS, RING_N, 4, fdi, fdj);
    terrainShiftAttr(F_UVS, RING_N, 2, fdi, fdj);
    const farRects = terrainDirtyRects(RING_N, fdi, fdj, full, 1);
    terrainWriteRects(F_H, F_VERTS, F_NORMS, F_COLS, F_UVS, TERRAIN_FAR_HALF,
        TERRAIN_FAR_CELL, RING_N, farRects, F_SLOPE_CELLS);
    if (!full) {
        terrainFixEdgeChanges(F_H, F_VERTS, F_NORMS, F_COLS, F_UVS, TERRAIN_FAR_HALF,
            TERRAIN_FAR_CELL, RING_N, fdi, fdj, F_SLOPE_CELLS);
    }
    terrainFar = terrainRingUpload(F_VERTS, F_NORMS, F_COLS, F_UVS, terrainFar);

    terrainShiftHeights(M_H, terrainAnchorX - TERRAIN_MID_HALF,
        terrainAnchorZ - TERRAIN_MID_HALF, TERRAIN_MID_CELL, RING_N, mdi, mdj, full);
    terrainShiftAttr(M_VERTS, RING_N, 3, mdi, mdj);
    terrainShiftAttr(M_NORMS, RING_N, 3, mdi, mdj);
    terrainShiftAttr(M_COLS, RING_N, 4, mdi, mdj);
    terrainShiftAttr(M_UVS, RING_N, 2, mdi, mdj);
    const midRects = terrainDirtyRects(RING_N, mdi, mdj, full, 1);
    terrainWriteRects(M_H, M_VERTS, M_NORMS, M_COLS, M_UVS, TERRAIN_MID_HALF,
        TERRAIN_MID_CELL, RING_N, midRects, M_SLOPE_CELLS);
    if (!full) {
        terrainFixEdgeChanges(M_H, M_VERTS, M_NORMS, M_COLS, M_UVS, TERRAIN_MID_HALF,
            TERRAIN_MID_CELL, RING_N, mdi, mdj, M_SLOPE_CELLS);
    }
    terrainMidSeam = terrainSeamBuild(M_H, M_NORMS, M_COLS, M_UVS,
        TERRAIN_MID_HALF, TERRAIN_MID_CELL, F_H, terrainMidSeam);
    terrainMid = terrainRingUpload(M_VERTS, M_NORMS, M_COLS, M_UVS, terrainMid);

    terrainShiftHeights(T_H, terrainAnchorX - T_HALF, terrainAnchorZ - T_HALF,
        TERRAIN_CELL, T_N, di, dj, full);
    terrainShiftAttr(T_VERTS, T_N, 3, di, dj);
    terrainShiftAttr(T_NORMS, T_N, 3, di, dj);
    terrainShiftAttr(T_COLS, T_N, 4, di, dj);
    terrainShiftAttr(T_UVS, T_N, 2, di, dj);
const attrRects = terrainDirtyRects(T_N, di, dj, full, 1);
	// Craters are stamped over the *new* cells only: a copied cell already carries
	// the term at its world point, and stamping again would add it twice.
	const craterRects = terrainDirtyRects(T_N, di, dj, full, 0);
	if (!full) {
		terrainFixEdgeChanges(T_H, T_VERTS, T_NORMS, T_COLS, T_UVS, T_HALF, TERRAIN_CELL,
			T_N, di, dj, T_SLOPE_CELLS);
	}
	const fullRect = [{ i0: 0, i1: T_N - 1, j0: 0, j1: T_N - 1 }];
    terrainApplyNear(attrRects, craterRects, fullRect);
}

// The one engine call a ground mesh costs, plus the material bindings every
// fresh model needs. A fresh model starts on raylib's default shader, so the lit
// program and the shadow map are re-applied the same way the goat's material gets
// them. The ground meshes are `makeModel` meshes with no bone data, so they take
// the *plain* program on every build (never `modelShaderFor`).
function terrainBind(model) {
    rl.setModelTexture(model, 0, terrainDetail);
    if (litShader >= 0) rl.setModelShader(model, useLighting ? litShader : -1);
    if (shadowColor >= 0) rl.setModelTexture(model, SHADOW_MAP_INDEX, shadowColor);
}

function terrainUpload() {
    if (terrainMesh >= 0) rl.unloadModel(terrainMesh);
    terrainMesh = rl.makeModel(T_VERTS, T_IDX, T_NORMS, T_COLS, T_UVS);
    terrainVerts = T_N * T_N;
    terrainTris = TERRAIN_QUADS * TERRAIN_QUADS * 2;
    terrainBind(terrainMesh);
    terrainBuilt = true;
    if (terrainAnchorX !== terrainLogX || terrainAnchorZ !== terrainLogZ) {
        terrainLogX = terrainAnchorX;
        terrainLogZ = terrainAnchorZ;
        console.log("terrain: mesh " + terrainMesh + " " + terrainVerts + " verts " +
            terrainTris + " tris cell " + TERRAIN_CELL +
            " anchor " + terrainAnchorX + "," + terrainAnchorZ);
    }
}

// The two rings' topology. Both are 48x48 grids with a 24x24-quad hole, so one
// index list serves the mid ring and the far one. The quads inside the hole are
// the inner surface's square; the ones around it are the range.
function terrainRingIndices() {
    let t = 0;
    for (let j = 0; j < TERRAIN_RING_QUADS; j++) {
        for (let i = 0; i < TERRAIN_RING_QUADS; i++) {
            if (i >= RING_HOLE0 && i < RING_HOLE1 && j >= RING_HOLE0 && j < RING_HOLE1) continue;
            const a = j * RING_N + i;
            const b = a + 1;
            const c = a + RING_N;
            const d = c + 1;
            RING_IDX[t++] = a; RING_IDX[t++] = c; RING_IDX[t++] = b;
            RING_IDX[t++] = b; RING_IDX[t++] = c; RING_IDX[t++] = d;
        }
    }
}

// Hand the engine one ring's arrays. The heights and attributes are the caller's
// (shifted in `terrainStep`); the caller rebuilds the rings *before* the near
// grid, because the newest `makeModel` is the mesh the harness reports the
// terrain's facts from.
function terrainRingUpload(VERTS, NORMS, COLS, UVS, old) {
    if (old >= 0) rl.unloadModel(old);
    const model = rl.makeModel(VERTS, RING_IDX, NORMS, COLS, UVS);
    terrainBind(model);
    return model;
}

// The perimeter of every surface, in order around the square, and the seam
// strip's index list. Shared by both seams: the near grid and the rings are all
// `RING_N` square. Each edge is a quad, emitted with both windings -- a seam is
// looked at through the lens from one side and from outside the other, and
// raylib keeps only the front face.
function terrainSeamIndices() {
    if (seamPerimeterBuilt) return;
    seamPerimeterBuilt = true;
    let p = 0;
    for (let i = 0; i < RING_N; i++) { SEAM_I[p] = i; SEAM_J[p] = 0; p++; }
    for (let j = 1; j < RING_N; j++) { SEAM_I[p] = RING_N - 1; SEAM_J[p] = j; p++; }
    for (let i = RING_N - 2; i >= 0; i--) { SEAM_I[p] = i; SEAM_J[p] = RING_N - 1; p++; }
    for (let j = RING_N - 2; j >= 1; j--) { SEAM_I[p] = 0; SEAM_J[p] = j; p++; }
    // The hole's perimeter, in the same order but `HOLE_N` square.
    p = 0;
    for (let i = RING_HOLE0; i <= RING_HOLE1; i++) { HOLE_I[p] = i; HOLE_J[p] = RING_HOLE0; p++; }
    for (let j = RING_HOLE0 + 1; j <= RING_HOLE1; j++) { HOLE_I[p] = RING_HOLE1; HOLE_J[p] = j; p++; }
    for (let i = RING_HOLE1 - 1; i >= RING_HOLE0; i--) { HOLE_I[p] = i; HOLE_J[p] = RING_HOLE1; p++; }
    for (let j = RING_HOLE1 - 1; j >= RING_HOLE0 + 1; j--) { HOLE_I[p] = RING_HOLE0; HOLE_J[p] = j; p++; }
    let t = 0;
    for (let k = 0; k < SEAM_COUNT; k++) {
        const next = (k + 1) % SEAM_COUNT;
        const a = k * 2;            // fine
        const b = next * 2;         // fine, next
        const c = next * 2 + 1;     // coarse, next
        const d = k * 2 + 1;        // coarse
        SEAM_IDX[t++] = a; SEAM_IDX[t++] = b; SEAM_IDX[t++] = c;
        SEAM_IDX[t++] = a; SEAM_IDX[t++] = c; SEAM_IDX[t++] = d;
        SEAM_IDX[t++] = a; SEAM_IDX[t++] = c; SEAM_IDX[t++] = b;
        SEAM_IDX[t++] = a; SEAM_IDX[t++] = d; SEAM_IDX[t++] = c;
    }
}

// Rebuild a seam strip. The top vertices are the fine surface's own boundary -- a
// seam never invents a second edge. The bottom vertices stand at the same (x, z)
// with the height of the *coarse* chord crossing them, which is a straight line
// between every other fine vertex: at an even fine index that is the coarse
// vertex itself (a degenerate quad, invisible), and between two of them the
// strip spans the lens the two triangulations leave. Two fine vertices per
// coarse one is what makes the position along the chord `k / 2`.
function terrainSeamBuild(H, NORMS, COLS, UVS, half, cell, coarseH, old) {
    terrainSeamIndices();
    const ratio = SEAM_COUNT / HOLE_PERIM;
    for (let k = 0; k < SEAM_COUNT; k++) {
        const i = SEAM_I[k];
        const j = SEAM_J[k];
        const src = j * RING_N + i;
        const wx = terrainAnchorX - half + i * cell;
        const wz = terrainAnchorZ - half + j * cell;
        const y = H[src];
        // Where along the coarse perimeter this fine vertex lies. Both lists
        // start at the same corner and run the same way, so the parameter is
        // just the fine index scaled into coarse steps.
        const at = k / ratio;
        const c0 = Math.floor(at) % HOLE_PERIM;
        const f = at - Math.floor(at);
        const c1 = (c0 + 1) % HOLE_PERIM;
        const y0 = coarseH[HOLE_J[c0] * RING_N + HOLE_I[c0]];
        const y1 = coarseH[HOLE_J[c1] * RING_N + HOLE_I[c1]];
        const yChord = y0 + (y1 - y0) * f;
        const top = k * 2;
        const bot = top + 1;
        SEAM_VERTS[top * 3] = wx;
        SEAM_VERTS[top * 3 + 1] = y;
        SEAM_VERTS[top * 3 + 2] = wz;
        SEAM_VERTS[bot * 3] = wx;
        SEAM_VERTS[bot * 3 + 1] = yChord;
        SEAM_VERTS[bot * 3 + 2] = wz;
        // The fine surface's normal and colour on both edges, so the strip
        // shades as the ground it fills rather than as a wall.
        for (let c = 0; c < 3; c++) {
            SEAM_NORMS[top * 3 + c] = NORMS[src * 3 + c];
            SEAM_NORMS[bot * 3 + c] = NORMS[src * 3 + c];
        }
        for (let c = 0; c < 4; c++) {
            SEAM_COLS[top * 4 + c] = COLS[src * 4 + c];
            SEAM_COLS[bot * 4 + c] = COLS[src * 4 + c];
        }
        SEAM_UVS[top * 2] = UVS[src * 2];
        SEAM_UVS[top * 2 + 1] = UVS[src * 2 + 1];
        SEAM_UVS[bot * 2] = UVS[src * 2];
        SEAM_UVS[bot * 2 + 1] = UVS[src * 2 + 1];
    }
    if (old >= 0) rl.unloadModel(old);
    const model = rl.makeModel(SEAM_VERTS, SEAM_IDX, SEAM_NORMS, SEAM_COLS, SEAM_UVS);
    terrainBind(model);
    return model;
}

// The mid ring (4 m cells, 48..96 m) and the far ring (8 m, 96..192 m). Both
// share the near grid's anchor, and each ring's hole matches the surface inside
// it, so the three tile: the near covers the mid's hole and the mid covers the
// far's. The far ring is built first because the mid seam hangs off its hole
// boundary; the near grid is built last because it must be the newest model.
// Startup: make the detail texture and the first grid.
function makeTerrain() {
    if (!TERRAIN_MESH_OK) {
        console.log("terrain: engine has no makeModel - keeping the flat slab");
        return;
    }
    makeTerrainTexture();
    terrainAnchorX = Math.round(goat.px / TUNING.terrain.snap) * TUNING.terrain.snap;
    terrainAnchorZ = Math.round(goat.pz / TUNING.terrain.snap) * TUNING.terrain.snap;
    // The first build is a full one; after this every anchor move is a shift.
    terrainStep(NaN, NaN, true);
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
        const prevX = terrainBuilt ? terrainAnchorX : NaN;
        const prevZ = terrainBuilt ? terrainAnchorZ : NaN;
        // A crater or a collapse since the last build changes cells the shift would
        // simply copy over, so a move on that frame takes the full path (a crater
        // that lands *after* this point is patched by `terrainEnsure`'s rectangle).
        const groundChanged = terrainPatches.length > 0;
        terrainPatches.length = 0;
        terrainAnchorX = ax;
        terrainAnchorZ = az;
        terrainStep(prevX, prevZ, groundChanged);
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
    // Far to near: the coarser rings are the ground behind the finer ones at each
    // seam, and each strip is drawn after the surface it hangs from so it is only
    // seen through the lens it exists to close.
    //
    // `detailFade` is on for exactly these five submissions. `setShaderValue`
    // binds the program to write the value, which the next `drawModelEx` would do
    // anyway, and the lit shader is shared with every model in the scene.
    if (useLighting && litShader >= 0 && typeof rl.getShaderLocation === "function" &&
        typeof rl.setShaderValue === "function" &&
        typeof rl.SHADER_UNIFORM_FLOAT === "number") {
        if (terrainFadeShader !== litShader) {
            terrainFadeShader = litShader;
            terrainFadeLoc = rl.getShaderLocation(litShader, "detailFade");
        }
        if (terrainFadeLoc >= 0) {
            rl.setShaderValue(litShader, terrainFadeLoc, 1, rl.SHADER_UNIFORM_FLOAT);
            terrainFadeOn = true;
        }
    }
    if (terrainFar >= 0) rl.drawModelEx(terrainFar, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, tint);
    if (terrainMid >= 0) rl.drawModelEx(terrainMid, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, tint);
    if (terrainMidSeam >= 0) rl.drawModelEx(terrainMidSeam, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, tint);
    rl.drawModelEx(terrainMesh, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, tint);
    if (terrainNearSeam >= 0) rl.drawModelEx(terrainNearSeam, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, tint);
    if (terrainFadeOn) {
        rl.setShaderValue(litShader, terrainFadeLoc, 0, rl.SHADER_UNIFORM_FLOAT);
        terrainFadeOn = false;
    }
}

// Re-apply the material bindings every ground mesh needs -- the lit program and
// the shadow map, both of which `terrainBind` owns. `makeLighting` runs two load
// steps after `makeTerrain`, so the meshes it built could not be bound when they
// were made; this is the call that finishes the job, over all five, now that the
// programs and the shadow map exist.
function terrainRebind() {
    if (terrainMesh >= 0) terrainBind(terrainMesh);
    if (terrainMid >= 0) terrainBind(terrainMid);
    if (terrainFar >= 0) terrainBind(terrainFar);
    if (terrainNearSeam >= 0) terrainBind(terrainNearSeam);
    if (terrainMidSeam >= 0) terrainBind(terrainMidSeam);
}

// Point the terrain material at the lit program, or back at raylib's default
// when lighting is off -- the same toggle `setModelShader` does for the goat.
// Deliberately not `modelShaderFor`: the terrain is a `makeModel` mesh with no
// bone data, so on a `gpu-skinning` build a skinned program would read the generic
// bone attributes (indices 0, weights 1) and deform the whole grid by whichever
// model was drawn last (`slag/.notes/gpu-skinning.md`, section 1b).
function setTerrainShader(shader) {
    if (terrainMesh >= 0) rl.setModelShader(terrainMesh, shader);
    if (terrainMid >= 0) rl.setModelShader(terrainMid, shader);
    if (terrainFar >= 0) rl.setModelShader(terrainFar, shader);
    if (terrainNearSeam >= 0) rl.setModelShader(terrainNearSeam, shader);
    if (terrainMidSeam >= 0) rl.setModelShader(terrainMidSeam, shader);
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

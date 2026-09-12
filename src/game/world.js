// Part 3/12 of the goat scene: grass, the day/night curve, sun, moon and stars.
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
const TERRAIN_RELIEF = 2.1;     // peak displacement, in metres
const TERRAIN_FLAT = 6;         // spawn-bowl radius that stays level, in units
const TERRAIN_RAMP = 16;        // units over which the bowl reaches full relief
const TERRAIN_SNAP = 24;        // rebuild when the goat has moved this far
const TERRAIN_UV = 0.06;        // texture tiles per world unit
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
let terrainVerts = 0;
let terrainTris = 0;

// Smooth 0..1 value noise, three octaves: broad hills with smaller bumps on top.
function terrainShape(x, z) {
    return 0.62 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1) +
        0.26 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9) +
        0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3);
}

// The ground height at (x, z). A bowl around the origin stays level so the goat
// starts on flat grass, and the relief eases in over `TERRAIN_RAMP` so there is
// no cliff at its edge.
function terrainHeight(x, z) {
    if (!TERRAIN_MESH_OK) return 0;
    const d = Math.sqrt(x * x + z * z);
    let t = (d - TERRAIN_FLAT) / TERRAIN_RAMP;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    t = t * t * (3 - 2 * t);
    return (terrainShape(x, z) - 0.5) * 2 * TERRAIN_RELIEF * t;
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
// previous mesh. `terrainEnsure` only calls this when the anchor has moved, so
// between rebuilds the terrain costs a single draw.
function terrainBuild() {
    const n = TERRAIN_QUADS + 1;
    const step = TERRAIN_CELL;
    const half = (TERRAIN_QUADS * TERRAIN_CELL) / 2;
    const ax = terrainAnchorX;
    const az = terrainAnchorZ;
    // Heights first, so the slope comes from the grid instead of four more field
    // samples per vertex.
    const h = new Array(n * n);
    for (let j = 0; j < n; j++) {
        const wz = az - half + j * step;
        for (let i = 0; i < n; i++) {
            h[j * n + i] = terrainHeight(ax - half + i * step, wz);
        }
    }
    const verts = new Array(n * n * 3);
    const norms = new Array(n * n * 3);
    const cols = new Array(n * n * 4);
    const uvs = new Array(n * n * 2);
    for (let j = 0; j < n; j++) {
        const wz = az - half + j * step;
        for (let i = 0; i < n; i++) {
            const k = j * n + i;
            const wx = ax - half + i * step;
            const y = h[k];
            verts[k * 3] = wx;
            verts[k * 3 + 1] = y;
            verts[k * 3 + 2] = wz;
            // Central differences on the grid give the normal, so the shading is
            // smooth across cells without a normal attribute on the geometry.
            const dx = (h[k + (i < n - 1 ? 1 : 0)] - h[k - (i > 0 ? 1 : 0)]) / (2 * step);
            const dz = (h[k + (j < n - 1 ? n : 0)] - h[k - (j > 0 ? n : 0)]) / (2 * step);
            const inv = 1 / Math.sqrt(dx * dx + dz * dz + 1);
            norms[k * 3] = -dx * inv;
            norms[k * 3 + 1] = inv;
            norms[k * 3 + 2] = -dz * inv;
            const c = terrainMaterial(y, Math.min(1, Math.sqrt(dx * dx + dz * dz)),
                vnoise2(wx * 0.07 + 3.1, wz * 0.07 + 9.7));
            cols[k * 4] = c[0];
            cols[k * 4 + 1] = c[1];
            cols[k * 4 + 2] = c[2];
            cols[k * 4 + 3] = 255;
            uvs[k * 2] = wx * TERRAIN_UV;
            uvs[k * 2 + 1] = wz * TERRAIN_UV;
        }
    }
    // Wound like raylib's own `GenMeshPlane` (the same two triangles per quad).
    const idx = new Array(TERRAIN_QUADS * TERRAIN_QUADS * 6);
    let t = 0;
    for (let j = 0; j < TERRAIN_QUADS; j++) {
        for (let i = 0; i < TERRAIN_QUADS; i++) {
            const a = j * n + i;
            const b = a + 1;
            const c = a + n;
            const d = c + 1;
            idx[t++] = a; idx[t++] = c; idx[t++] = b;
            idx[t++] = b; idx[t++] = c; idx[t++] = d;
        }
    }
    if (terrainMesh >= 0) rl.unloadModel(terrainMesh);
    terrainMesh = rl.makeModel(verts, idx, norms, cols, uvs);
    terrainVerts = n * n;
    terrainTris = TERRAIN_QUADS * TERRAIN_QUADS * 2;
    rl.setModelTexture(terrainMesh, 0, terrainDetail);
    // A fresh model starts on raylib's default shader, so re-apply the lit
    // program and the shadow map the same way the goat's material gets them.
    if (litShader >= 0) rl.setModelShader(terrainMesh, useLighting ? litShader : -1);
    if (shadowColor >= 0) rl.setModelTexture(terrainMesh, SHADOW_MAP_INDEX, shadowColor);
    terrainBuilt = true;
    console.log("terrain: mesh " + terrainMesh + " " + terrainVerts + " verts " +
        terrainTris + " tris cell " + TERRAIN_CELL +
        " anchor " + terrainAnchorX + "," + terrainAnchorZ);
}

// Startup: make the detail texture and the first grid.
function makeTerrain() {
    if (!TERRAIN_MESH_OK) {
        console.log("terrain: engine has no makeModel - keeping the flat slab");
        return;
    }
    makeTerrainTexture();
    terrainAnchorX = Math.round(goat.px / TERRAIN_SNAP) * TERRAIN_SNAP;
    terrainAnchorZ = Math.round(goat.pz / TERRAIN_SNAP) * TERRAIN_SNAP;
    terrainBuild();
}

// Rebuild the grid when the goat has left the one it was built around. Called
// once per frame; the snapped anchor means the rebuild lands every
// `TERRAIN_SNAP` units of travel, not every frame.
function terrainEnsure(px, pz) {
    if (terrainDetail < 0) return;
    const ax = Math.round(px / TERRAIN_SNAP) * TERRAIN_SNAP;
    const az = Math.round(pz / TERRAIN_SNAP) * TERRAIN_SNAP;
    if (terrainBuilt && ax === terrainAnchorX && az === terrainAnchorZ) return;
    terrainAnchorX = ax;
    terrainAnchorZ = az;
    terrainBuild();
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
function setTerrainShader(shader) {
    if (terrainMesh >= 0) rl.setModelShader(terrainMesh, shader);
}

// ---- day/night -----------------------------------------------------------

const DAY_LENGTH = 240;         // real seconds for one 24 h day
const TIME_FAST = 40;           // hold T to advance time this many times faster
const NIGHT_DRAIN_MULT = 1.6;   // energy drains faster in the cold

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

// Sun and moon on opposite sides of a celestial sphere, arcing east to west
// between 06:00 and 18:00. The sun is a stack of soft glow billboards (a hard
// `drawSphere` reads flat), the moon a procedural cratered disc with a halo.
function drawCelestial() {
    const a = ((worldTime - 6) / 12) * Math.PI;   // 0 at 06:00, PI at 18:00
    const dx = Math.cos(a);
    const dy = Math.sin(a);
    const R = 70;
    const sx = goat.px + dx * R;
    const sy = dy * R;
    if (dy > -0.25 && glowTex >= 0) {
        const warm = 0.55 + 0.45 * Math.max(0, dy);
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 26,
            rl.color(255, Math.round(205 * warm + 30), Math.round(115 * warm + 40), 34));
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 14,
            rl.color(255, Math.round(220 * warm + 30), Math.round(150 * warm + 70), 64));
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 7.2, rl.color(255, 250, 225, 140));
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 3.2, rl.color(255, 255, 246, 255));
    }
    if (dy < 0.25 && moonTex >= 0) {
        rl.drawBillboard(glowTex, goat.px - dx * R, -dy * R, goat.pz, 9.5,
            rl.color(196, 212, 240, 44));
        rl.drawBillboard(moonTex, goat.px - dx * R, -dy * R, goat.pz, 3.0,
            rl.color(255, 255, 255, 255));
    }
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


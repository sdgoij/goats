// The `birds` mod: a flock of procedural birds with generated textures, five
// animations and boids flocking, shared in multiplayer.
//
// It is a `side: "world"` mod, so the host simulates the flock and every peer
// renders the same birds (the join handshake requires the same set). The model
// is built in JavaScript -- `rl.makeModel` for the meshes, `rl.makeTexture` for
// the feather pattern -- so the mod ships no binary assets. See APIv1.md §5.4
// for the walk-through.
//
// Two engine facts shape the code:
//
//   * `rl.makeTexture` uploads to the GPU, so it needs the window: the meshes
//     are built lazily on the first `update`/`draw3d`, never in the entry.
//   * `rl.drawModelEx` takes a single axis and angle. Yaw, pitch, roll and each
//     wing's flap are therefore composed into one quaternion per part and
//     handed over as that axis-angle.

// ---- constants ------------------------------------------------------------

const MOD_ID = goats.mod.id;
const COUNT = 6;                 // birds in the flock
const SCALE = 1.3;               // base model scale
const LEG = 0.13;                // body height above the ground, at rest
const PERCH_H = 1.15;            // height of a goat's back, where a bird sits
const PERCH_R = 40;              // a goat this close is a candidate perch
const PERCH_PLAYER = -2;         // `b.perch`: a bot index, this, or -1 for none

const WALK_SPEED = 1.1;
const FLY_SPEED = 6.0;
const TAKEOFF_TIME = 0.9;
const LAND_TIME = 1.6;
const CRUISE_MIN = 4;
const CRUISE_MAX = 8;
const HOME_R = 14;               // stay inside this radius of the home point
const SEP = 3.2;                // boid separation / alignment / cohesion
const ALIGN = 8;
const COH = 11;
const CULL = 150;                // no draw beyond this distance
const MIN_GAP = 1.2;             // airborne birds are pushed apart to this

const ST = { IDLE: 0, WALK: 1, TAKEOFF: 2, FLY: 3, LAND: 4, PERCH: 5 };
const ST_NAME = ["idle", "walk", "takeoff", "fly", "land", "perch"];

const BODY_COL = [122, 92, 60];
const HEAD_COL = [140, 110, 74];
const WING_COL = [172, 142, 104];
const WING_EDGE = [104, 82, 56];
const BEAK_COL = [232, 156, 58];
// Colours handed to the engine must come from `rl.color`: the real binding packs
// one into a number, while the null `rl` the server uses returns an object.
const SHADOW = rl.color(0, 0, 0, 60);

const SHOULDER = { x: 0.06, y: 0.055, z: 0.05 };

// ---- local helpers --------------------------------------------------------
//
// The public `goats` surface is the contract; these are self-contained rather
// than reaching into the scene's own globals.

const flockRnd = (function () {
    goats.world.registerStream("f", 0x5eed);
    return goats.rng("f");
})();
const HOME = { x: 0, z: 0 };

function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
function rand(a, b) { return a + (b - a) * flockRnd(); }
function r1(v) { return Math.round(v * 10) / 10; }
function r2(v) { return Math.round(v * 100) / 100; }
function groundAt(x, z) { return goats.world.terrainHeight(x, z); }
function angleDelta(a, b) {
    let d = a - b;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    return d;
}
// A small 2D value noise, for the feather texture. Deterministic and local.
function hash1(n) { const s = Math.sin(n) * 43758.5453; return s - Math.floor(s); }
function noise(x, y) {
    const xi = Math.floor(x), yi = Math.floor(y);
    const xf = x - xi, yf = y - yi;
    const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    const a = hash1(xi * 57.0 + yi * 131.0);
    const b = hash1((xi + 1) * 57.0 + yi * 131.0);
    const c = hash1(xi * 57.0 + (yi + 1) * 131.0);
    const d = hash1((xi + 1) * 57.0 + (yi + 1) * 131.0);
    return a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v;
}
const HEX = (function () {
    const d = "0123456789abcdef";
    const out = [];
    for (let i = 0; i < 256; i++) out.push(d[Math.floor(i / 16)] + d[i % 16]);
    return out;
})();
function hex2(v) { return HEX[clamp(Math.round(v), 0, 255)]; }

// ---- quaternions ----------------------------------------------------------
//
// Compose the orientation of a part into one axis-angle, which is all
// `drawModelEx` accepts. Conventions: the bird faces local +X, up is +Y and the
// right wing is +Z; yaw is about Y, pitch about Z, roll about X.

function qAxis(x, y, z, rad) {
    const s = Math.sin(rad / 2);
    return { x: x * s, y: y * s, z: z * s, w: Math.cos(rad / 2) };
}
function qMul(a, b) {
    return {
        x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}
function qRot(q, v) {
    const x = q.x, y = q.y, z = q.z, w = q.w;
    const tx = 2 * (y * v.z - z * v.y);
    const ty = 2 * (z * v.x - x * v.z);
    const tz = 2 * (x * v.y - y * v.x);
    return {
        x: v.x + w * tx + (y * tz - z * ty),
        y: v.y + w * ty + (z * tx - x * tz),
        z: v.z + w * tz + (x * ty - y * tx),
    };
}
function qAxisAngle(q) {
    const w = clamp(q.w, -1, 1);
    const s = Math.sqrt(Math.max(1e-12, 1 - w * w));
    if (s < 1e-6) return { x: 0, y: 1, z: 0, deg: 0 };
    return { x: q.x / s, y: q.y / s, z: q.z / s, deg: (2 * Math.acos(w) * 180) / Math.PI };
}
function bodyQuat(b) {
    return qMul(qMul(qAxis(0, 1, 0, b.yaw), qAxis(0, 0, 1, b.pitch)), qAxis(1, 0, 0, b.roll));
}

// ---- meshes ---------------------------------------------------------------
//
// `face` picks the winding from the expected outward direction, so the mesh is
// correct whichever way raylib culls and there is no need to duplicate faces.

function Mesh() { this.v = []; this.n = []; this.c = []; this.uv = []; this.i = []; }
Mesh.prototype.vert = function (x, y, z, col, u, v, nx, ny, nz) {
    const at = (this.v.length / 3) | 0;
    this.v.push(x, y, z);
    this.n.push(nx, ny, nz);
    this.c.push(col[0], col[1], col[2], 255);
    this.uv.push(u, v);
    return at;
};
Mesh.prototype.face = function (a, b, c, ex, ey, ez) {
    const v = this.v;
    const ux = v[b * 3] - v[a * 3], uy = v[b * 3 + 1] - v[a * 3 + 1], uz = v[b * 3 + 2] - v[a * 3 + 2];
    const wx = v[c * 3] - v[a * 3], wy = v[c * 3 + 1] - v[a * 3 + 1], wz = v[c * 3 + 2] - v[a * 3 + 2];
    const nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
    if (nx * ex + ny * ey + nz * ez < 0) this.i.push(a, c, b);
    else this.i.push(a, b, c);
};
Mesh.prototype.quad = function (a, b, c, d, ex, ey, ez) {
    this.face(a, b, c, ex, ey, ez);
    this.face(a, c, d, ex, ey, ez);
};
Mesh.prototype.model = function () {
    return rl.makeModel(this.v, this.i, this.n, this.c, this.uv);
};

function buildBodyModel() {
    const m = new Mesh();
    const RINGS = [
        [-0.52, 0.005, 0.030],
        [-0.32, 0.020, 0.075],
        [-0.08, 0.035, 0.108],
        [0.18, 0.045, 0.100],
        [0.38, 0.058, 0.068],
        [0.52, 0.072, 0.048],
    ];
    const SEG = 6;
    const start = [];
    for (let r = 0; r < RINGS.length; r++) {
        start.push(m.v.length / 3);
        const x = RINGS[r][0], cy = RINGS[r][1], rad = RINGS[r][2];
        for (let s = 0; s < SEG; s++) {
            const a = (s / SEG) * Math.PI * 2;
            const sy = Math.sin(a), sz = Math.cos(a);
            m.vert(x, cy + sy * rad * 0.9, sz * rad, r >= 4 ? HEAD_COL : BODY_COL,
                (x + 0.8) * 1.1, s / SEG, 0, sy, sz);
        }
    }
    for (let r = 0; r < RINGS.length - 1; r++) {
        for (let s = 0; s < SEG; s++) {
            const a = start[r] + s, b = start[r] + (s + 1) % SEG;
            const c = start[r + 1] + s, d = start[r + 1] + (s + 1) % SEG;
            const mid = ((s + 0.5) / SEG) * Math.PI * 2;
            m.quad(a, b, d, c, 0, Math.sin(mid), Math.cos(mid));
        }
    }
    // A pointed tail, then a beak ring and tip at the front.
    const tail = m.vert(-0.80, 0.01, 0, BODY_COL, 0, 0.5, -1, 0, 0);
    for (let s = 0; s < SEG; s++) m.face(start[0] + s, start[0] + (s + 1) % SEG, tail, -1, 0, 0);

    const head = start[start.length - 1];
    const beak = m.v.length / 3;
    for (let s = 0; s < SEG; s++) {
        const a = (s / SEG) * Math.PI * 2;
        m.vert(0.565, 0.072 + Math.sin(a) * 0.020, Math.cos(a) * 0.024, BEAK_COL, 0.9, s / SEG, 1, 0, 0);
    }
    const tip = m.vert(0.70, 0.068, 0, BEAK_COL, 1, 0.5, 1, 0, 0);
    for (let s = 0; s < SEG; s++) {
        const a = head + s, b = head + (s + 1) % SEG;
        const c = beak + s, d = beak + (s + 1) % SEG;
        m.quad(a, b, d, c, 1, 0, 0);
        m.face(beak + s, beak + (s + 1) % SEG, tip, 1, 0, 0);
    }
    return m.model();
}

function buildWingModel(side) {
    const m = new Mesh();
    // z, leading-edge x, trailing-edge x, half-thickness.
    const SEC = [
        [0.03, 0.10, -0.16, 0.020],
        [0.30, 0.09, -0.20, 0.022],
        [0.58, 0.06, -0.16, 0.016],
        [0.82, 0.00, -0.06, 0.006],
    ];
    const rings = [];
    for (let i = 0; i < SEC.length; i++) {
        const z = SEC[i][0] * side, lead = SEC[i][1], trail = SEC[i][2], th = SEC[i][3];
        const yOff = SEC[i][0] * 0.06;   // dihedral
        const mid = (lead + trail) / 2;
        rings.push([
            m.vert(lead, yOff, z, WING_COL, 0, i / SEC.length, 0, 0, side),
            m.vert(mid, yOff + th, z, WING_COL, 0.5, i / SEC.length, 0, 1, 0),
            m.vert(trail, yOff, z, WING_EDGE, 1, i / SEC.length, 0, 0, side),
            m.vert(mid, yOff - th, z, WING_COL, 0.5, i / SEC.length, 0, -1, 0),
        ]);
    }
    for (let i = 0; i < rings.length - 1; i++) {
        const A = rings[i], B = rings[i + 1];
        const midX = (SEC[i][1] + SEC[i][2] + SEC[i + 1][1] + SEC[i + 1][2]) / 4;
        const yMid = ((SEC[i][0] + SEC[i + 1][0]) / 2) * 0.06;
        for (let e = 0; e < 4; e++) {
            const e2 = (e + 1) % 4;
            const avgX = (m.v[A[e] * 3] + m.v[B[e] * 3] + m.v[A[e2] * 3] + m.v[B[e2] * 3]) / 4;
            const avgY = (m.v[A[e] * 3 + 1] + m.v[B[e] * 3 + 1] + m.v[A[e2] * 3 + 1] + m.v[B[e2] * 3 + 1]) / 4;
            m.quad(A[e], A[e2], B[e2], B[e], avgX - midX, avgY - yMid, 0);
        }
    }
    const R = rings[0], T = rings[rings.length - 1];
    m.quad(R[0], R[3], R[2], R[1], 0, 0, -side);
    m.quad(T[0], T[1], T[2], T[3], 0, 0, side);
    return m.model();
}

// A tiling feather texture: soft bars along one axis over value noise. Baked to
// a "rrggbbaa" string and handed to `rl.makeTexture`.
function featherHex(n) {
    let out = "";
    for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
            const bars = Math.sin((y / n) * Math.PI * 2 * 6 + Math.sin((x / n) * 6.0) * 0.9);
            const g = clamp(0.80 + 0.16 * (noise(x * 0.28, y * 0.28) - 0.5) + 0.10 * bars, 0, 1);
            const c = hex2(g * 255);
            out += c + c + c + "ff";
        }
    }
    return out;
}

// ---- the flock ------------------------------------------------------------

let BIRDS = [];
let built = false;
let bodyModel = -1, wingR = -1, wingL = -1, featherTex = -1;

function newBird() {
    return {
        x: 0, y: 0, z: 0, yaw: 0, st: ST.IDLE, t: 0, dur: 1,
        vx: 0, vy: 0, vz: 0, flap: 0, pitch: 0, roll: 0, yawRate: 0, prevYaw: 0,
        cruise: 9, perch: -1, size: 1, // client mirror targets
        tx: 0, ty: 0, tz: 0, tyaw: 0,
    };
}

function syncFlock(n) {
    while (BIRDS.length < n) BIRDS.push(newBird());
    if (BIRDS.length > n) BIRDS.length = n;
}

function seedFlock() {
    syncFlock(COUNT);
    for (let i = 0; i < BIRDS.length; i++) placeBird(BIRDS[i], i);
}

// Put a bird back on the ground near the home point. Used to spawn a bird and,
// defensively, to recover one whose position went non-finite (which would make
// it draw as nothing -- it would simply vanish).
function placeBird(b, i) {
    const a = i * 2.399963 + 0.7;
    const r = 5 + flockRnd() * 9;
    b.x = HOME.x + Math.cos(a) * r;
    b.z = HOME.z + Math.sin(a) * r;
    b.y = groundAt(b.x, b.z) + LEG;
    b.yaw = a + Math.PI;
    b.prevYaw = b.yaw;
    b.st = ST.IDLE;
    b.t = 0;
    b.dur = rand(2, 6);
    b.cruise = rand(CRUISE_MIN, CRUISE_MAX);
    b.size = 0.9 + 0.2 * ((i % 3) / 2);
    b.vx = b.vz = b.vy = 0;
    b.pitch = b.roll = b.yawRate = 0;
    b.perch = -1;
}

function ensureBuilt() {
    if (built) return;
    built = true;
    if (typeof rl.makeModel === "function" && typeof rl.makeTexture === "function") {
        bodyModel = buildBodyModel();
        wingR = buildWingModel(1);
        wingL = buildWingModel(-1);
        featherTex = rl.makeTexture(32, 32, featherHex(32));
        if (featherTex >= 0) {
            rl.setModelTexture(bodyModel, 0, featherTex);
            rl.setModelTexture(wingR, 0, featherTex);
            rl.setModelTexture(wingL, 0, featherTex);
        }
        goats.log("birds: models " + bodyModel + "/" + wingR + "/" + wingL +
            " tex " + featherTex);
    }
    seedFlockIfEmpty();
}

// A client may already hold the host's snapshot by the time the window is
// ready; only an empty flock is seeded locally, around the flock's home.
function seedFlockIfEmpty() {
    if (BIRDS.length > 0) return;
    updateHome();
    seedFlock();
}

// Where the flock gathers. A solo game or a host has a real player goat that
// moves, so the flock follows it. A dedicated server's own goat never moves,
// and clients do not render it, so there the flock gathers around the herd
// instead -- the herd is on every peer. Movement is detected from the goat's
// position, which is what the tests can drive.
let anchorPlayer = false;
let lastPX = null, lastPZ = null;
function updateHome() {
    const p = goats.player.state();
    if (lastPX !== null && Math.abs(p.x - lastPX) + Math.abs(p.z - lastPZ) > 0.01) {
        anchorPlayer = true;
    }
    lastPX = p.x;
    lastPZ = p.z;
    if (anchorPlayer) {
        HOME.x = p.x;
        HOME.z = p.z;
        return;
    }
    const bots = goats.bots.list();
    if (bots.length > 0) {
        let sx = 0, sz = 0;
        for (let i = 0; i < bots.length; i++) { sx += bots[i].x; sz += bots[i].z; }
        HOME.x = sx / bots.length;
        HOME.z = sz / bots.length;
        return;
    }
    HOME.x = p.x;
    HOME.z = p.z;
}

function setSt(b, st, dur) { b.st = st; b.t = 0; b.dur = dur; }

// Bring the whole flock to the player: a ring on the ground right beside the
// goat, facing it. The console command `birds gather` uses it, which is also
// the quickest way to confirm the models are being drawn at all.
function gatherBirds() {
    const p = goats.player.state();
    const n = Math.max(1, BIRDS.length);
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        const a = (i / n) * Math.PI * 2;
        b.x = p.x + Math.cos(a) * 2.5;
        b.z = p.z + Math.sin(a) * 2.5;
        b.y = groundAt(b.x, b.z) + LEG;
        b.yaw = a + Math.PI;
        b.prevYaw = b.yaw;
        b.vx = b.vz = b.vy = 0;
        b.pitch = b.roll = b.yawRate = 0;
        b.perch = -1;
        setSt(b, ST.IDLE, 2);
        // A client mirrors the host, so its own move is only a target update.
        b.tx = b.x; b.ty = b.y; b.tz = b.z; b.tyaw = b.yaw;
    }
}

function startTakeoff(b) {
    setSt(b, ST.TAKEOFF, TAKEOFF_TIME);
    b.cruise = rand(CRUISE_MIN, CRUISE_MAX);
    b.perch = -1;   // chosen again when this flight decides to land
    b.vx = Math.cos(b.yaw) * 2;
    b.vz = -Math.sin(b.yaw) * 2;
}

// The nearest settled goat to perch on: the player's or a bot's, whichever is
// closer. A moving goat is skipped -- chasing one never reaches it -- and only
// some landings near a goat choose it, so the flock still uses the ground.
function pickPerch(b) {
    let best = -1, bd = PERCH_R * PERCH_R;
    const p = goats.player.state();
    const pdx = p.x - b.x, pdz = p.z - b.z;
    if ((p.speed || 0) < 1.5 && pdx * pdx + pdz * pdz < bd) { bd = pdx * pdx + pdz * pdz; best = PERCH_PLAYER; }
    const bots = goats.bots.list();
    for (let i = 0; i < bots.length; i++) {
        const bot = bots[i];
        if (bot.mode === "run" || bot.mode === "trot") continue;
        const dx = bot.x - b.x, dz = bot.z - b.z;
        const d2 = dx * dx + dz * dz;
        if (d2 < bd) { bd = d2; best = i; }
    }
    return best !== -1 && flockRnd() < 0.35 ? best : -1;
}

// Where a perched bird sits, or null if its goat is gone. `speed` lets a bird
// leave a goat that starts moving.
function perchTarget(b) {
    if (b.perch === PERCH_PLAYER) {
        const p = goats.player.state();
        return { x: p.x, z: p.z, y: groundAt(p.x, p.z) + PERCH_H, yaw: p.yaw, speed: p.speed || 0 };
    }
    const bot = goats.bots.list()[b.perch];
    if (bot === undefined) return null;
    return { x: bot.x, z: bot.z, y: groundAt(bot.x, bot.z) + PERCH_H, yaw: bot.yaw,
        speed: bot.mode === "run" ? 4 : 0 };
}

function flapWave(t, amp, hz) { return amp * (0.5 - 0.5 * Math.cos(t * hz * Math.PI * 2)); }

// A grounded bird that has been left behind flies to catch up; walking at 1.1
// m/s cannot keep pace with a running player, and a bird stranded far away is
// culled and looks like it vanished.
function tooFar(b) {
    const dx = HOME.x - b.x, dz = HOME.z - b.z;
    const r = HOME_R + 6;
    return dx * dx + dz * dz > r * r;
}

// The wing flap is a pure function of the state and its clock, so the host and
// a mirroring client pose a bird identically without sending the angle.
function flapFor(b) {
    const glide = b.st === ST.FLY && Math.floor(b.t / 6) % 2 === 1;
    switch (b.st) {
        case ST.FLY: return glide ? 0.10 + 0.05 * Math.sin(b.t * 2) : flapWave(b.t, 0.8, 2.2);
        case ST.TAKEOFF: return flapWave(b.t, 0.95, 1.7);
        case ST.LAND: return flapWave(b.t, 0.7, 1.2) * (1 - 0.6 * clamp(b.t / LAND_TIME, 0, 1));
        case ST.WALK: return 0.06 * (1 + Math.sin(b.t * 8));
        case ST.PERCH: return 0.04 * (1 + Math.sin(b.t * 5));
        default: return 0;
    }
}

function stepIdle(b, dt) {
    if (tooFar(b)) { startTakeoff(b); return; }
    b.y += (groundAt(b.x, b.z) + LEG - b.y) * Math.min(1, dt * 8);
    if (b.t < b.dur) return;
    const roll = flockRnd();
    if (roll < 0.72) setSt(b, ST.WALK, rand(3, 7));
    else startTakeoff(b);
}

function stepWalk(b, dt) {
    b.x += Math.cos(b.yaw) * WALK_SPEED * dt;
    b.z += -Math.sin(b.yaw) * WALK_SPEED * dt;
    b.y += (groundAt(b.x, b.z) + LEG - b.y) * Math.min(1, dt * 8);
    b.yaw += Math.sin(b.t * 1.7 + b.size * 9) * 0.6 * dt;
    if (tooFar(b)) { startTakeoff(b); return; }
    const dx = HOME.x - b.x, dz = HOME.z - b.z;
    if (dx * dx + dz * dz > HOME_R * HOME_R) b.yaw = Math.atan2(-dz, dx);
    if (b.t < b.dur) return;
    const roll = flockRnd();
    if (roll < 0.45) setSt(b, ST.IDLE, rand(2, 6));
    else if (roll < 0.75) setSt(b, ST.WALK, rand(3, 7));
    else startTakeoff(b);
}

function stepTakeoff(b, dt) {
    const u = clamp(b.t / TAKEOFF_TIME, 0, 1);
    b.vy = 3.4 * u;
    b.y += b.vy * dt;
    const sp = 1.5 + 3.5 * u;
    b.x += Math.cos(b.yaw) * sp * dt;
    b.z += -Math.sin(b.yaw) * sp * dt;
    if (u >= 1) setSt(b, ST.FLY, rand(6, 12));
}

function stepLand(b, dt) {
    // A perch target that keeps moving is given up: chasing one never closes,
    // and the bird would hang in the air instead of ever landing.
    if (b.t > LAND_TIME + 1.5) b.perch = -1;
    const perch = b.perch === -1 ? null : perchTarget(b);
    if (b.perch !== -1 && perch === null) b.perch = -1;

    const ground = groundAt(b.x, b.z) + LEG;
    const tx = perch === null ? b.x : perch.x;
    const tz = perch === null ? b.z : perch.z;
    const ty = perch === null ? ground : perch.y;
    const k = Math.min(1, dt * 2.5);
    b.x += (tx - b.x) * k;
    b.z += (tz - b.z) * k;
    b.y += (ty - b.y) * k;
    b.yaw += angleDelta(Math.atan2(-(tz - b.z), tx - b.x), b.yaw) * k;

    if (perch === null) {
        // The ground target moves with the bird, so only the height can settle.
        if (Math.abs(b.y - ground) < 0.25) {
            setSt(b, flockRnd() < 0.4 ? ST.WALK : ST.IDLE, rand(2, 6));
        }
        return;
    }
    const dx = b.x - perch.x, dz = b.z - perch.z;
    if (dx * dx + dz * dz < 1.44 && Math.abs(b.y - perch.y) < 0.9) {
        setSt(b, ST.PERCH, rand(4, 9));
    }
}

function stepPerch(b, dt) {
    const t = perchTarget(b);
    if (t === null || t.speed > 2) { startTakeoff(b); return; }
    b.x = t.x;
    b.z = t.z;
    b.y = t.y;
    b.yaw = t.yaw;
    if (b.t >= b.dur) startTakeoff(b);
}

// Boids: separation, alignment, cohesion, a pull home and a soft altitude hold.
function stepFly(b, dt) {
    let aliX = 0, aliZ = 0, cohX = 0, cohZ = 0, sepX = 0, sepZ = 0, nA = 0, nC = 0, nS = 0;
    for (let i = 0; i < BIRDS.length; i++) {
        const o = BIRDS[i];
        if (o === b || o.st !== ST.FLY) continue;
        const dx = b.x - o.x, dz = b.z - o.z;
        const d2 = dx * dx + dz * dz;
        if (d2 < COH * COH) {
            cohX += o.x; cohZ += o.z; nC++;
            aliX += Math.cos(o.yaw); aliZ += -Math.sin(o.yaw); nA++;
        }
        if (d2 > 1e-4 && d2 < SEP * SEP) {
            // Graded by distance, so a near pair pushes harder than a distant one.
            const d = Math.sqrt(d2);
            const w = (SEP - d) / SEP;
            sepX += (dx / d) * w;
            sepZ += (dz / d) * w;
            nS++;
        }
    }
    let ax = 0, az = 0;
    if (nS > 0) {
        const m = Math.hypot(sepX, sepZ) || 1;
        ax += (sepX / m) * 10.0;
        az += (sepZ / m) * 10.0;
    }
    if (nA > 0) {
        const m = Math.hypot(aliX, aliZ) || 1;
        ax += (aliX / m - Math.cos(b.yaw)) * 2.4;
        az += (aliZ / m + Math.sin(b.yaw)) * 2.4;
    }
    if (nC > 0) {
        const cx = cohX / nC - b.x, cz = cohZ / nC - b.z;
        const m = Math.hypot(cx, cz) || 1;
        ax += (cx / m) * 0.9;
        az += (cz / m) * 0.9;
    }
    const hx = HOME.x - b.x, hz = HOME.z - b.z;
    const hd = Math.hypot(hx, hz);
    if (hd > HOME_R) { ax += (hx / hd) * 6.0; az += (hz / hd) * 6.0; }

    if (!(Math.hypot(b.vx, b.vz) > 0.05)) {
        b.vx = Math.cos(b.yaw) * FLY_SPEED;
        b.vz = -Math.sin(b.yaw) * FLY_SPEED;
    }
    b.vx += ax * dt;
    b.vz += az * dt;
    const sp = Math.hypot(b.vx, b.vz);
    const ns = sp + (FLY_SPEED - sp) * Math.min(1, dt * 1.2);
    b.vx = (b.vx / sp) * ns;
    b.vz = (b.vz / sp) * ns;
    b.x += b.vx * dt;
    b.z += b.vz * dt;
    b.yaw = Math.atan2(-b.vz, b.vx);

    // Glide in stretches; flap in between. The glide flag is a function of the
    // state clock, so a client derives it from the synced `t` without being told.
    const glide = Math.floor(b.t / 6) % 2 === 1;
    const targetY = glide ? b.cruise - 0.8 : b.cruise;
    b.y += (targetY - b.y) * Math.min(1, dt * 0.9);
    const floor = groundAt(b.x, b.z) + 2.5;
    if (b.y < floor) b.y += (floor - b.y) * Math.min(1, dt * 2);
    b.vy = (targetY - b.y) * 0.5;

    if (b.t >= b.dur) {
        b.perch = pickPerch(b);
        setSt(b, ST.LAND, LAND_TIME);
    }
}

function poseTargets(b) {
    let pitch = 0;
    if (b.st === ST.TAKEOFF) pitch = 0.5 * clamp(b.t / TAKEOFF_TIME, 0, 1);
    else if (b.st === ST.LAND) pitch = -0.25 + 0.4 * clamp(b.t / LAND_TIME, 0, 1);
    else if (b.st === ST.FLY) pitch = clamp(b.vy * 0.05, -0.18, 0.18);
    b.pitch += (pitch - b.pitch) * 0.12;
    const roll = clamp(b.yawRate * 0.5, -0.55, 0.55);
    b.roll += (roll - b.roll) * 0.12;
}

// Anything off the ground: two of these must not overlap in the air, whatever
// the steering did. A hard positional pass guarantees it; steering alone cannot
// when a bird takes off right beside another.
function airborne(b) { return b.st === ST.TAKEOFF || b.st === ST.FLY || b.st === ST.LAND; }
function separateFlock() {
    for (let i = 0; i < BIRDS.length; i++) {
        const a = BIRDS[i];
        if (!airborne(a)) continue;
        for (let j = i + 1; j < BIRDS.length; j++) {
            const b = BIRDS[j];
            if (!airborne(b)) continue;
            let dx = b.x - a.x, dz = b.z - a.z;
            let d2 = dx * dx + dz * dz;
            if (d2 >= MIN_GAP * MIN_GAP) continue;
            let d = Math.sqrt(d2);
            let ux, uz;
            if (d < 1e-3) { ux = Math.cos(i * 2.4); uz = Math.sin(i * 2.4); }
            else { ux = dx / d; uz = dz / d; }
            const push = (MIN_GAP - d) * 0.5;
            a.x -= ux * push; a.z -= uz * push;
            b.x += ux * push; b.z += uz * push;
        }
    }
}

function simulate(dt) {
    updateHome();
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        // A non-finite position draws as nothing, so recover the bird rather
        // than let it silently vanish.
        if (!Number.isFinite(b.x) || !Number.isFinite(b.y) || !Number.isFinite(b.z) ||
            !Number.isFinite(b.yaw)) {
            placeBird(b, i);
            continue;
        }
        b.prevYaw = b.yaw;
        b.t += dt;
        switch (b.st) {
            case ST.WALK: stepWalk(b, dt); break;
            case ST.TAKEOFF: stepTakeoff(b, dt); break;
            case ST.FLY: stepFly(b, dt); break;
            case ST.LAND: stepLand(b, dt); break;
            case ST.PERCH: stepPerch(b, dt); break;
            default: stepIdle(b, dt); break;
        }
        b.yawRate = angleDelta(b.yaw, b.prevYaw) / dt;
        poseTargets(b);
    }
    separateFlock();
}

// A client does not simulate: it eases toward the host's last snapshot and
// advances the state clock so the flap stays smooth between packets.
const MIRROR_K = 7;
function mirror(dt) {
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        b.prevYaw = b.yaw;
        b.t += dt;
        const k = Math.min(1, dt * MIRROR_K);
        b.x += (b.tx - b.x) * k;
        b.y += (b.ty - b.y) * k;
        b.z += (b.tz - b.z) * k;
        b.yaw += angleDelta(b.tyaw, b.yaw) * k;
        b.yawRate = angleDelta(b.yaw, b.prevYaw) / dt;
        poseTargets(b);
    }
}

// ---- multiplayer ----------------------------------------------------------

goats.world.extend(MOD_ID, {
    publish: function () {
        const out = [];
        for (let i = 0; i < BIRDS.length; i++) {
            const b = BIRDS[i];
            // Five numbers per bird. `publishRows` rounds them and refuses a
            // NaN, so a bug here lands in the log with this mod's name on it
            // rather than arriving at every peer as `null`.
            out.push([r1(b.x), r1(b.y), r1(b.z), r2(b.yaw), b.st]);
        }
        return goats.world.publishRows(out);
    },
    apply: function (state) {
        if (!Array.isArray(state)) return;
        syncFlock(state.length);
        for (let i = 0; i < state.length; i++) {
            const s = state[i];
            const b = BIRDS[i];
            if (!Array.isArray(s) || s.length < 5) continue;
            if (!Number.isFinite(s[0]) || !Number.isFinite(s[1]) || !Number.isFinite(s[2]) ||
                !Number.isFinite(s[3])) continue;
            const st = s[4] | 0;
            // The state clock is local; reset it only when the state changes, so
            // the flap and the take-off/landing pitch still run smoothly.
            if (b.st !== st) b.t = 0;
            b.st = st;
            b.tx = s[0]; b.ty = s[1]; b.tz = s[2]; b.tyaw = s[3];
        }
    },
});

// ---- render ---------------------------------------------------------------

function drawFlock(cam) {
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        const dx = b.x - cam.x, dz = b.z - cam.z;
        if (dx * dx + dz * dz > CULL * CULL) continue;
        const gy = groundAt(b.x, b.z);
        const s = SCALE * b.size;
        const lift = b.y - gy;
        if (lift < 7) {
            const sh = clamp(1 - lift / 7, 0, 1) * 0.9 * s;
            rl.drawCube(b.x, gy + 0.03, b.z, sh, 0.012, sh * 0.7, SHADOW);
        }
        const q = bodyQuat(b);
        const ba = qAxisAngle(q);
        const tint = rl.color(200 + ((i * 17) % 56), 200 + ((i * 29) % 56), 200 + ((i * 11) % 56), 255);
        rl.drawModelEx(bodyModel, b.x, b.y, b.z, ba.x, ba.y, ba.z, ba.deg, s, s, s, tint);
        const f = flapFor(b);
        for (let side = -1; side <= 1; side += 2) {
            const wq = qMul(q, qAxis(1, 0, 0, side > 0 ? -f : f));
            const wa = qAxisAngle(wq);
            const pv = qRot(q, { x: SHOULDER.x * s, y: SHOULDER.y * s, z: side * SHOULDER.z * s });
            rl.drawModelEx(side > 0 ? wingR : wingL,
                b.x + pv.x, b.y + pv.y, b.z + pv.z, wa.x, wa.y, wa.z, wa.deg, s, s, s, tint);
        }
    }
}

// ---- lifecycle and surface ------------------------------------------------

goats.on("update", function (dt) {
    if (!(dt > 0)) return;
    ensureBuilt();
    if (goats.net.localWorld()) simulate(dt);
    else mirror(dt);
});

goats.on("draw3d", function (cam) {
    ensureBuilt();
    if (bodyModel < 0) return;
    drawFlock(cam);
});

goats.on("shutdown", function () {
    if (typeof rl.unloadModel !== "function") return;
    if (bodyModel >= 0) rl.unloadModel(bodyModel);
    if (wingR >= 0) rl.unloadModel(wingR);
    if (wingL >= 0) rl.unloadModel(wingL);
    bodyModel = wingR = wingL = -1;
    built = false;
    BIRDS = [];
});

goats.command("birds", function (parts) {
    const verb = parts[1] === undefined ? "" : parts[1];
    if (verb === "scatter") { seedFlock(); return "ok birds scattered"; }
    if (verb === "gather" || verb === "here") { gatherBirds(); return "ok birds gathered"; }
    if (verb === "fly") {
        for (let i = 0; i < BIRDS.length; i++) startTakeoff(BIRDS[i]);
        return "ok birds flying";
    }
    if (verb === "land") {
        for (let i = 0; i < BIRDS.length; i++) {
            BIRDS[i].perch = -1;
            setSt(BIRDS[i], ST.LAND, LAND_TIME);
        }
        return "ok birds landing";
    }
    const counts = {};
    let near = Infinity, far = 0;
    const p = goats.player.state();
    for (let i = 0; i < BIRDS.length; i++) {
        const name = ST_NAME[BIRDS[i].st] || "?";
        counts[name] = (counts[name] || 0) + 1;
        const d = Math.hypot(BIRDS[i].x - p.x, BIRDS[i].z - p.z);
        if (d < near) near = d;
        if (d > far) far = d;
    }
    return "ok " + JSON.stringify({ count: BIRDS.length, local: goats.net.localWorld(),
        anchor: anchorPlayer ? "player" : "herd", near: BIRDS.length ? r1(near) : null,
        far: BIRDS.length ? r1(far) : null, states: counts });
});

goats.log("birds: " + COUNT + " procedural birds ready");

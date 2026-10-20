// The `birds` mod: a flock of procedural birds with generated textures, eight
// animation states and boids flocking, shared in multiplayer.
//
// It is a `side: "world"` mod, so the host simulates the flock and every peer
// renders the same birds (the join handshake requires the same set). The model
// is built in JavaScript -- `goats.gfx.mesh` for the meshes, `goats.gfx.texture`
// for the feather pattern -- and the only files it ships are the two macaw calls
// its manifest declares for the squawk. See APIv1.md §5.4 for the walk-through.
//
// Two of its behaviours reach into the world rather than only drawing in it, both
// through the surface M19g added for mods (`goats.explosions`, APIv1.md §4.15): a
// bird walking over a device sets it off and is flung away by it -- with a squawk,
// the only sound this mod ships -- and a bird perched on the player's goat gives the
// goat energy and health back while it sits there.
//
// The third is captured-bird flight (`FLIGHT.md` §4): a bird perched on a goat that
// jumps is *captured*, and a goat with a captured bird can run and jump into the air.
// The controllers are the scene's -- `goats.player.setFlight` and the herd's -- and
// this mod only grants the capability, keeps the bird on the goat's back in 3D, and
// lets it go when the goat releases it. What is *here* rather than in the engine is
// the seat: the goat's own back point, rotated about the body pivot its mesh turns
// about, so a banking goat carries its bird through the turn.
//
// Two facts about the *surface* shape the code:
//
//   * `goats.gfx.texture` hands its image to the GPU, so it needs the window: the
//     meshes are built lazily on the first `update`/`draw3d`, never in the entry.
//   * `goats.gfx.draw.mesh` takes a single axis and angle. Yaw, pitch, roll and each
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
const PERCH_PEER = -3;           // ...or a remote player's goat, named in `b.peer`

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
// A bird's own width, for anything outside the flock that wants to collide with one
// -- the fatguy's run, through `goats.entities` (APIv1.md §4.16). The body is drawn
// at `SCALE` with `LEG` off the ground, and this is the radius around it.
const BODY_R = 0.35;

const ST = { IDLE: 0, WALK: 1, TAKEOFF: 2, FLY: 3, LAND: 4, PERCH: 5, FLUNG: 6, RIDE: 7 };
const ST_NAME = ["idle", "walk", "takeoff", "fly", "land", "perch", "flung", "ride"];

// A captured bird's wingbeat, which is a *strong* flap rather than a boid's glide:
// it is the only thing that moves on the goat's back (`FLIGHT.md` §4.3).
const RIDE_FLAP_AMP = 0.9;
const RIDE_FLAP_HZ = 3.2;

// `FLIGHT.md` §4.6: a client older than the flight slice has no `setFlight`, and the
// flock then behaves exactly as it did before -- no capture, no ride, no grant.
const FLIGHT_API = typeof goats.player.setFlight === "function";
// ...and `goats.peers` (`APIv1.md` §4.21) is the host's window on a joiner's goat. Without
// it the flock is exactly the host/solo feature it was; with it, a peer can be a rider.
const PEERS_API = FLIGHT_API && goats.peers !== undefined && goats.peers !== null &&
    typeof goats.peers.list === "function";

// ---- the goat's friends ---------------------------------------------------
//
// Two things the flock does to the world around it, both through the surface M19g
// added for mods (`goats.explosions`, `APIv1.md` §4.15): a bird walking over a device
// sets it off and is thrown by it, and a bird sitting on the player's back gives the
// goat a little of its energy and health back while it stays.

const TRIP_R = 0.6;              // metres; the core's own `explosions.mine.trigger`
const FLUNG_PUSH = 16;           // m/s away from the device -- a bird weighs less than a goat
const FLUNG_LIFT = 40;           // m/s up
const FLUNG_GRAVITY = -72;       // the goat's own gravity, so the arc comes down hard
const FLUNG_MAX = 2.5;           // seconds; a ceiling, so a bird cannot hang in the air
const FLUNG_SPIN = 1.5;          // whole turns over the arc
const BLESS_ENERGY = 4;          // energy a second, while a bird sits on the goat
const BLESS_HEALTH = 2;          // ...and health, which is the sleep rate
const BLESS_R2 = 1.0;            // metres^2: how close a mirroring client counts as "aboard"

const SQUAWK_VOLUME = 0.9;       // the squawk, over the sfx slider's own volume
const SQUAWK_FADE = 24;          // metres past which it is effectively silent

const BODY_COL = [122, 92, 60];
const HEAD_COL = [140, 110, 74];
const WING_COL = [172, 142, 104];
const WING_EDGE = [104, 82, 56];
const BEAK_COL = [232, 156, 58];
// Colours come from `goats.draw.color`, which is also where the named constants are:
// a client packs one into whatever its engine wants, and a mod never sees that.

const SHOULDER = { x: 0.06, y: 0.055, z: 0.05 };

// ---- local helpers --------------------------------------------------------
//
// The public `goats` surface is the contract; these are self-contained rather
// than reaching into the scene's own globals.

// Frozen members of `Math`, and the reason this file reads the way it does.
//
// The engine compiles a function body only when it names no *global* (PERF.md
// §4b): one `Math.sin(b.yaw)` in a body -- and `stepFly` has a dozen, inside an
// O(n^2) neighbour loop -- costs that whole body its compiled path and leaves it
// on the interpreter at ~100x the cost, every frame, for six birds. Reading a
// binding from an enclosing scope is not a global read and does not disqualify a
// body, so the members are frozen here and called as locals below. Behaviour is
// unchanged: these are the same functions and the same values.
const PI = Math.PI;
const ABS = Math.abs;
const MIN = Math.min;
const MAX = Math.max;
const FLOOR = Math.floor;
const ROUND = Math.round;
const SQRT = Math.sqrt;
const SIN = Math.sin;
const COS = Math.cos;
const ATAN2 = Math.atan2;
const HYPOT = Math.hypot;
const ACOS = Math.acos;
const IS_FINITE = Number.isFinite;

const flockRnd = (function () {
    goats.world.registerStream("f", 0x5eed);
    return goats.rng("f");
})();
const HOME = { x: 0, z: 0 };

function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
function rand(a, b) { return a + (b - a) * flockRnd(); }
function r1(v) { return ROUND(v * 10) / 10; }
function r2(v) { return ROUND(v * 100) / 100; }
function groundAt(x, z) { return goats.world.terrainHeight(x, z); }

// The water (the scene's `goats.water` seam): a bird stands on the *ground*, and the ground
// is under the water wherever a pool is. `LEG` is the body's own height above that ground,
// so the test is "would the water come over its feet" -- a bird may stand in a shallow
// puddle, and may not walk off under a pool and vanish into it. Every state that puts a bird
// on the ground asks this first, and a bird that is already down takes off when the water
// finds it (which is what a rising table does under a standing bird).
function dryAt(x, z) { return goats.water.depthAt(x, z) <= LEG; }
// Arithmetic rather than two `while`s: a body with two sequential loops is
// interpreted (`jitprobe`'s `s two loops`), and this runs per bird per frame.
function angleDelta(a, b) {
    const d = a - b;
    const twoPi = PI * 2;
    return d - twoPi * FLOOR((d + PI) / twoPi);
}
// A small 2D value noise, for the feather texture. Deterministic and local.
function hash1(n) { const s = SIN(n) * 43758.5453; return s - FLOOR(s); }
function noise(x, y) {
    const xi = FLOOR(x), yi = FLOOR(y);
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
    for (let i = 0; i < 256; i++) out.push(d[FLOOR(i / 16)] + d[i % 16]);
    return out;
})();
function hex2(v) { return HEX[clamp(ROUND(v), 0, 255)]; }

// ---- quaternions ----------------------------------------------------------
//
// Compose the orientation of a part into one axis-angle, which is all
// `drawModelEx` accepts. Conventions: the bird faces local +X, up is +Y and the
// right wing is +Z; yaw is about Y, pitch about Z, roll about X.
//
// Every helper writes into an object the caller owns instead of building one, because
// this runs once a frame for every drawn bird and it used to allocate its way through
// the whole pose: `bodyQuat` alone made five objects (three axes and two multiplies) and
// the two wings made ten more, so a flock of a dozen handed the collector ~200 objects a
// frame. Turning this draw off measured 12.6k of the scene's ~42k allocations a second.
//
// The scratch below is reused, so a result must be read before the next call that uses
// the same slot -- which is the discipline the draw already keeps: the body quaternion
// outlives both wing results, and each axis-angle is consumed by its own `drawModelEx`.
const Q_TMP1 = { x: 0, y: 0, z: 0, w: 1 };
const Q_TMP2 = { x: 0, y: 0, z: 0, w: 1 };
const Q_BODY = { x: 0, y: 0, z: 0, w: 1 };
const Q_RIDE = { x: 0, y: 0, z: 0, w: 1 };
const V_RIDE = { x: 0, y: 0, z: 0 };
const AA_BODY = { x: 0, y: 0, z: 0, rad: 0 };
const AA_WING = { x: 0, y: 0, z: 0, rad: 0 };
const V_WING = { x: 0, y: 0, z: 0 };

function qAxisInto(out, x, y, z, rad) {
    const s = SIN(rad / 2);
    out.x = x * s;
    out.y = y * s;
    out.z = z * s;
    out.w = COS(rad / 2);
    return out;
}

// `out` may be either input: the four components are read out of `a` and `b` before
// anything is written.
function qMulInto(out, a, b) {
    const x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
    const y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
    const z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
    const w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
    out.x = x;
    out.y = y;
    out.z = z;
    out.w = w;
    return out;
}

function qRotInto(out, q, vx, vy, vz) {
    const x = q.x, y = q.y, z = q.z, w = q.w;
    const tx = 2 * (y * vz - z * vy);
    const ty = 2 * (z * vx - x * vz);
    const tz = 2 * (x * vy - y * vx);
    const rx = vx + w * tx + (y * tz - z * ty);
    const ry = vy + w * ty + (z * tx - x * tz);
    const rz = vz + w * tz + (x * ty - y * tx);
    out.x = rx;
    out.y = ry;
    out.z = rz;
    return out;
}

function qAxisAngleInto(out, q) {
    // **Radians**, which is what `goats.gfx.draw.mesh` takes (`APIv1.md` section 4.19) and what the
    // reference client multiplies by `180 / PI` for raylib. It used to be degrees here -- the field
    // was called `deg` and raylib's `DrawModelEx` wants those -- and the port drew every bird as a
    // helicopter until this was found: a 57x angle is a rotor, not a wingbeat.
    const w = clamp(q.w, -1, 1);
    const s = SQRT(MAX(1e-12, 1 - w * w));
    if (s < 1e-6) {
        out.x = 0;
        out.y = 1;
        out.z = 0;
        out.rad = 0;
        return out;
    }
    out.x = q.x / s;
    out.y = q.y / s;
    out.z = q.z / s;
    out.rad = 2 * ACOS(w);
    return out;
}

// Yaw about Y, then pitch about Z, then roll about X. `out` must be a scratch of its
// own, not one of the two temporaries.
function bodyQuatInto(out, b) {
    qMulInto(Q_TMP1, qAxisInto(Q_TMP2, 0, 1, 0, b.yaw), qAxisInto(out, 0, 0, 1, b.pitch));
    qAxisInto(Q_TMP2, 1, 0, 0, b.roll);
    qMulInto(out, Q_TMP1, Q_TMP2);
    return out;
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
    return goats.gfx.mesh(this.v, this.i, this.n, this.c, this.uv);
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
            const a = (s / SEG) * PI * 2;
            const sy = SIN(a), sz = COS(a);
            m.vert(x, cy + sy * rad * 0.9, sz * rad, r >= 4 ? HEAD_COL : BODY_COL,
                (x + 0.8) * 1.1, s / SEG, 0, sy, sz);
        }
    }
    for (let r = 0; r < RINGS.length - 1; r++) {
        for (let s = 0; s < SEG; s++) {
            const a = start[r] + s, b = start[r] + (s + 1) % SEG;
            const c = start[r + 1] + s, d = start[r + 1] + (s + 1) % SEG;
            const mid = ((s + 0.5) / SEG) * PI * 2;
            m.quad(a, b, d, c, 0, SIN(mid), COS(mid));
        }
    }
    // A pointed tail, then a beak ring and tip at the front.
    const tail = m.vert(-0.80, 0.01, 0, BODY_COL, 0, 0.5, -1, 0, 0);
    for (let s = 0; s < SEG; s++) m.face(start[0] + s, start[0] + (s + 1) % SEG, tail, -1, 0, 0);

    const head = start[start.length - 1];
    const beak = m.v.length / 3;
    for (let s = 0; s < SEG; s++) {
        const a = (s / SEG) * PI * 2;
        m.vert(0.565, 0.072 + SIN(a) * 0.020, COS(a) * 0.024, BEAK_COL, 0.9, s / SEG, 1, 0, 0);
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
// a "rrggbbaa" string and handed to `goats.gfx.texture` as the mod's own image.
function featherHex(n) {
    let out = "";
    for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
            const bars = SIN((y / n) * PI * 2 * 6 + SIN((x / n) * 6.0) * 0.9);
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
let bodyModel = null, wingR = null, wingL = null, featherTex = null;
let trips = 0;      // devices the flock has set off (M19g's surface, below)
let mineTrips = 0;  // ...and which kind they were: a case can tell a trap from a mine
let trapTrips = 0;
let blessed = 0;    // seconds a bird has spent on the player's back
let ridePivot = 0.7; // `explosions.fling.pivot`, refreshed with the flock's frame
let SQUAWKS = [];   // the two macaw calls the manifest declares, loaded at build

function newBird() {
    return {
        x: 0, y: 0, z: 0, yaw: 0, st: ST.IDLE, t: 0, dur: 1,
        vx: 0, vy: 0, vz: 0, flap: 0, pitch: 0, roll: 0, yawRate: 0, prevYaw: 0,
        cruise: 9, perch: -1, peer: "", size: 1, // client mirror targets
        tx: 0, ty: 0, tz: 0, tyaw: 0, tpitch: 0, troll: 0,
        trip: -1, sent: false,         // the device bucket, and a bird on an errand
        captured: false,               // the bird is a goat's rider (`FLIGHT.md` §4)
        justCaptured: false,           // the grant was made this frame (see `updateRiders`)
        mine: false,                   // a mirror: this bird rides *this* client's goat
    };
}

function syncFlock(n) {
    while (BIRDS.length < n) BIRDS.push(newBird());
    if (BIRDS.length > n) BIRDS.length = n;
}

function seedFlock() {
    // A reseed is a new flock: no bird of it is anybody's rider, so the grants go with
    // the birds `scatter` replaces.
    dropRiders();
    syncFlock(COUNT);
    for (let i = 0; i < BIRDS.length; i++) placeBird(BIRDS[i], i);
}

// Put a bird back on the ground near the home point. Used to spawn a bird and,
// defensively, to recover one whose position went non-finite (which would make
// it draw as nothing -- it would simply vanish).
function placeBird(b, i) {
    const a = i * 2.399963 + 0.7;
    const r = 5 + flockRnd() * 9;
    b.x = HOME.x + COS(a) * r;
    b.z = HOME.z + SIN(a) * r;
    b.y = groundAt(b.x, b.z) + LEG;
    b.yaw = a + PI;
    b.prevYaw = b.yaw;
    b.st = ST.IDLE;
    b.t = 0;
    b.dur = rand(2, 6);
    b.cruise = rand(CRUISE_MIN, CRUISE_MAX);
    b.size = 0.9 + 0.2 * ((i % 3) / 2);
    b.vx = b.vz = b.vy = 0;
    b.pitch = b.roll = b.yawRate = 0;
    b.perch = -1;
    b.peer = "";
    b.trip = -1;
    b.sent = false;
    b.captured = false;
    b.justCaptured = false;
    b.mine = false;
    b.tpitch = b.troll = 0;
}

function ensureBuilt() {
    if (built) return;
    built = true;
    // A handle is *opaque*, so a client with no renderer answers `null` here and the
    // whole flock draws nothing -- which is one `if` in this mod rather than a check on
    // an engine library it would have to name (APIv1.md section 0).
    bodyModel = buildBodyModel();
    wingR = buildWingModel(1);
    wingL = buildWingModel(-1);
    featherTex = goats.gfx.texture(32, featherHex(32));
    if (featherTex !== null) {
        goats.gfx.bind(bodyModel, featherTex);
        goats.gfx.bind(wingR, featherTex);
        goats.gfx.bind(wingL, featherTex);
    }
    goats.log("birds: models " + bodyModel + "/" + wingR + "/" + wingL +
        " tex " + featherTex);
    // The squawk: the two files the manifest declares under one slot of the mod's
    // own, which the host registered with the engine before this entry ran -- so
    // what comes back here is an opaque name and `goats.sfx.load` finds the bytes.
    // The surface has no `unload`, so these live until the process ends, the way the
    // scene's own effects do when a mod is switched off.
    const squawkNames = goats.assets.all("sfx.squawk");
    for (let i = 0; i < squawkNames.length; i++) {
        const sound = goats.sfx.load(squawkNames[i]);
        if (sound !== null) SQUAWKS.push(sound);
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
    if (lastPX !== null && ABS(p.x - lastPX) + ABS(p.z - lastPZ) > 0.01) {
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
    // The flock comes to the ground beside the goat, so any ride is over: a bird cannot
    // be in the ring and on a back at once.
    dropRiders();
    const p = goats.player.state();
    const n = MAX(1, BIRDS.length);
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        const a = (i / n) * PI * 2;
        b.x = p.x + COS(a) * 2.5;
        b.z = p.z + SIN(a) * 2.5;
        b.y = groundAt(b.x, b.z) + LEG;
        b.yaw = a + PI;
        b.prevYaw = b.yaw;
        b.vx = b.vz = b.vy = 0;
        b.pitch = b.roll = b.yawRate = 0;
        b.perch = -1;
        b.peer = "";
        b.sent = false;
        b.captured = false;
        setSt(b, ST.IDLE, 2);
        // A client mirrors the host, so its own move is only a target update.
        b.tx = b.x; b.ty = b.y; b.tz = b.z; b.tyaw = b.yaw;
    }
}

// Sever every ride, for the commands that move the whole flock somewhere a rider cannot
// stay (`FLIGHT.md` §4.6). `dismount` clears the grant as well as the seat, so a goat left
// armed with no bird on its back cannot happen through a console verb.
function dropRiders() {
    for (let i = 0; i < BIRDS.length; i++) {
        if (BIRDS[i].captured) dismount(BIRDS[i]);
    }
}

// Put a bird on the player's back, in the perch the landing path would have given it.
// `birds sit` uses it, which is the friend mechanic at its most literal and the way
// the suite drives it without waiting for a landing to pick the player.
function perchOnGoat(b) {
    // A rider put back into a plain perch is not a rider any more: the grant goes too.
    if (b.captured) dismount(b);
    const p = goats.player.state();
    b.perch = PERCH_PLAYER;
    b.x = p.x;
    b.z = p.z;
    b.y = groundAt(p.x, p.z) + PERCH_H;
    b.yaw = p.yaw;
    b.prevYaw = b.yaw;
    b.vx = b.vz = b.vy = 0;
    b.pitch = b.roll = b.yawRate = 0;
    b.sent = false;
    b.captured = false;
    b.peer = "";
    b.tx = b.x; b.ty = b.y; b.tz = b.z; b.tyaw = b.yaw;
    setSt(b, ST.PERCH, 600);   // long enough to watch the goat fill up
}

// The same on a joiner's goat, for the host's flock (`birds sit <name>` and the capture
// test). The peer row is the host's mirror of it, so this is a seat on where the peer is
// being drawn, exactly like a landing would be.
function perchOnPeer(b, peer) {
    if (b.captured) dismount(b);
    b.perch = PERCH_PEER;
    b.peer = peer.name;
    b.x = peer.x;
    b.z = peer.z;
    b.y = groundAt(peer.x, peer.z) + PERCH_H + (peer.y > 0 ? peer.y : 0);
    b.yaw = peer.yaw;
    b.prevYaw = b.yaw;
    b.vx = b.vz = b.vy = 0;
    b.pitch = b.roll = b.yawRate = 0;
    b.sent = false;
    b.captured = false;
    b.justCaptured = false;
    b.tx = b.x; b.ty = b.y; b.tz = b.z; b.tyaw = b.yaw;
    setSt(b, ST.PERCH, 600);
}

// The nearest armed device to the player, of one kind or either (`birds boom [mine|
// trap]`). Null when the field is empty in reach, which the command reports rather
// than teleporting a bird into a meadow and pretending something happened.
function nearestDevice(want) {
    const p = goats.player.state();
    const near = goats.explosions.traps(p.x, p.z, 40);
    const pools = want === "trap" ? [["trap", near.traps]] :
        want === "mine" ? [["mine", near.mines]] :
            [["mine", near.mines], ["trap", near.traps]];
    let best = null, bd = Infinity;
    for (let i = 0; i < pools.length; i++) {
        const list = pools[i][1];
        for (let j = 0; j < list.length; j++) {
            if (list[j].dist < bd) {
                bd = list[j].dist;
                best = { kind: pools[i][0], x: list[j].x, z: list[j].z };
            }
        }
    }
    return best;
}

// Birds and goats are friends: a bird sitting on the player's back gives the goat back
// a little energy and health for as long as it stays. It is read from the perch's own
// owner on the process that made the landing, and from the *position* on a client -- a
// mirroring client is never told which goat a bird chose, but it can see one on its own
// goat's back, and the player's stats are the one thing every process owns locally.
// A dead goat is left alone: a bird is not a resurrection.
function blessGoat(dt, exact) {
    let sitting = 0;
    let px = 0, pz = 0, have = false;
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        if (b.st !== ST.PERCH && b.st !== ST.RIDE) continue;
        if (exact) {
            if (b.perch === PERCH_PLAYER) sitting += 1;
            continue;
        }
        // A client is not told which goat a bird chose, so it reads the bird against
        // its own goat's position -- which is where the host put it.
        if (!have) {
            const p = goats.player.state();
            px = p.x; pz = p.z; have = true;
        }
        const dx = b.x - px, dz = b.z - pz;
        if (dx * dx + dz * dz <= BLESS_R2) sitting += 1;
    }
    if (sitting === 0) return;   // the usual frame: no flock query, no state at all
    // A dead goat is left alone: a bird is not a resurrection. A rider heals its goat
    // on the ground *and* in the air (`FLIGHT.md` §4.5), which is the energy that pays
    // for the flight -- but not at zero health, because the heal would revive it.
    const p = goats.player.state();
    if (p.mode === "dead" || p.health <= 0) return;
    goats.player.giveEnergy(BLESS_ENERGY * sitting * dt);
    goats.player.giveHealth(BLESS_HEALTH * sitting * dt);
    blessed += sitting * dt;
}

function startTakeoff(b) {
    setSt(b, ST.TAKEOFF, TAKEOFF_TIME);
    b.cruise = rand(CRUISE_MIN, CRUISE_MAX);
    b.perch = -1;   // chosen again when this flight decides to land
    b.peer = "";
    b.captured = false; // a bird that leaves the ground is nobody's rider
    b.justCaptured = false;
    b.sent = false; // any errand is over the moment the bird leaves the ground
    b.vx = COS(b.yaw) * 2;
    b.vz = -SIN(b.yaw) * 2;
}

// The nearest settled goat to perch on: the player's, a bot's or -- on a host -- a
// joiner's, whichever is closer. A moving goat is skipped -- chasing one never reaches it
// -- and only some landings near a goat choose it, so the flock still uses the ground. A
// goat that already carries a rider is skipped too: one bird per goat.
//
// The answer is `{perch, peer}` rather than the bare code, because a peer's identity is a
// name and the code alone cannot say which one (`FLIGHT.md` §8).
function pickPerch(b) {
    let best = null, bd = PERCH_R * PERCH_R;
    const p = goats.player.state();
    const pdx = p.x - b.x, pdz = p.z - b.z;
    if (!p.flight && (p.speed || 0) < 1.5 && pdx * pdx + pdz * pdz < bd) {
        bd = pdx * pdx + pdz * pdz;
        best = { perch: PERCH_PLAYER, peer: "" };
    }
    const bots = goats.bots.list();
    for (let i = 0; i < bots.length; i++) {
        const bot = bots[i];
        if (bot.flight) continue;
        if (bot.mode === "run" || bot.mode === "trot") continue;
        const dx = bot.x - b.x, dz = bot.z - b.z;
        const d2 = dx * dx + dz * dz;
        if (d2 < bd) { bd = d2; best = { perch: i, peer: "" }; }
    }
    // A joiner's goat, from the host's mirror of it. Only a standing one is a candidate:
    // a running or flying peer is the same chase a moving goat is, and its own rider (if
    // it has one) is not a second seat.
    if (PEERS_API) {
        for (let i = 0; i < peerRows.length; i++) {
            const peer = peerRows[i];
            if (peer.mode !== "idle" && peer.mode !== "walk" && peer.mode !== "trot") continue;
            if (riderOfPeer(peer.name) !== null) continue;
            const dx = peer.x - b.x, dz = peer.z - b.z;
            const d2 = dx * dx + dz * dz;
            if (d2 < bd) { bd = d2; best = { perch: PERCH_PEER, peer: peer.name }; }
        }
    }
    return best !== null && flockRnd() < 0.35 ? best : null;
}

// Where a perched bird sits, or null if its goat is gone. `speed` lets a bird
// leave a goat that starts moving.
function perchTarget(b) {
    if (b.perch === PERCH_PLAYER) {
        const p = goats.player.state();
        // `p.y` is the goat's own height above the ground under it: zero standing,
        // positive through a blast's arc (M19c). A bird on the back of a blasted goat
        // has to go up with it, or it glides along the ground beneath its friend until
        // the goat lands on top of it.
        const lift = p.y > 0 ? p.y : 0;
        return { x: p.x, z: p.z, y: groundAt(p.x, p.z) + PERCH_H + lift, yaw: p.yaw,
            speed: p.speed || 0 };
    }
    if (b.perch === PERCH_PEER) {
        // The host's mirror of a joiner: the same numbers the peer's own client draws, a
        // snapshot or two behind. The perch is the flat back height, as for any goat; the
        // captured seat is `riderTarget`, which adds the attitude.
        const peer = peerByName(b.peer);
        if (peer === null) return null;
        const lift = peer.y > 0 ? peer.y : 0;
        return { x: peer.x, z: peer.z, y: groundAt(peer.x, peer.z) + PERCH_H + lift,
            yaw: peer.yaw, speed: peer.mode === "run" || peer.mode === "fly" ? 6 : 0 };
    }
    // One bot, by index: this runs once a frame for every perched bird, and `list()`
    // would build a handle for every bot in the herd -- an object and four closures
    // each -- to read the one. `get` is the same read for one bot (APIv1 §4.8).
    const bot = goats.bots.get(b.perch);
    if (bot === null) return null;
    return { x: bot.x, z: bot.z, y: groundAt(bot.x, bot.z) + PERCH_H, yaw: bot.yaw,
        speed: bot.mode === "run" ? 4 : 0 };
}

// ---- captured riders ------------------------------------------------------
//
// A bird perched on a goat that jumps is *captured* (`FLIGHT.md` §4.2). The grant is
// the goat's: `setFlight(true)` arms it, and its next *running* jump goes into the
// air. The bird then rides the goat's back in 3D -- the same seat the perch uses at
// zero attitude, rotated about the body pivot the goat's own mesh turns about --
// until the goat releases it (`E`), dies, or is blown off its flight.
//
// The poll is the seam: the port's event surface is partial, so the mod watches the
// goat's mode rather than listening for a `jump`. Both clients put the goat's new
// mode in place before `modFrameTick`, so the frame after the key is the capture.
//
// A *joiner's* goat is not the host's, so the host reads it through `goats.peers`
// (`FLIGHT.md` §8). Nothing about the seat changes: a peer's feet and attitude are the
// same numbers a bot's are, from the host's mirror of the peer's broadcast pose.

// `goats.peers.list()` once a frame on the host, rather than per rider: a peer row is built
// by the surface on every call and a rider is looked up from its name. `updateRiders`
// refreshes this, and the command that seats a bird on a peer refreshes it too, because it
// runs outside the flock's frame.
let peerRows = [];
function refreshPeers() {
    peerRows = PEERS_API ? goats.peers.list() : [];
}
function peerByName(name) {
    for (let i = 0; i < peerRows.length; i++) {
        if (peerRows[i].name === name) return peerRows[i];
    }
    return null;
}

// The rider's live state, or null when its goat is gone. `base` is the goat's feet in
// world space: the ground under it plus its own height above that ground, which is
// what `y`/`py` is on both clients (`FLIGHT.md` §4.3). `local` says whether this process
// owns the goat (its own player, or one of its bots): a peer's capability is the peer's
// own to hold, and this end never sets it.
//
// One reusable record, filled and returned: `updateRiders` asks once per rider per
// frame and consumes the answer before the next ask, and the flock's update is the
// hottest loop this mod runs (PERF.md appendix B).
const RIDE_STATE = { mode: "", x: 0, z: 0, base: 0, yaw: 0, pitch: 0, roll: 0, flight: false, speed: 0, local: true };
const RIDE_TARGET = { x: 0, y: 0, z: 0, yaw: 0, pitch: 0, roll: 0 };

function riderState(b) {
    const r = RIDE_STATE;
    if (b.perch === PERCH_PEER) {
        const peer = peerByName(b.peer);
        if (peer === null) return null;
        r.mode = peer.mode;
        r.x = peer.x;
        r.z = peer.z;
        r.base = groundAt(peer.x, peer.z) + (peer.y > 0 ? peer.y : 0);
        r.yaw = peer.yaw;
        r.pitch = peer.pitch || 0;
        r.roll = peer.roll || 0;
        // Not this end's to know: the peer's grant lives on the peer's client, and the
        // wire carries the *result* (a gait and an attitude), not the capability.
        r.flight = true;
        r.speed = peer.mode === "run" || peer.mode === "fly" ? 6 : 0;
        r.local = false;
        return r;
    }
    if (b.perch === PERCH_PLAYER) {
        const p = goats.player.state();
        r.mode = p.mode;
        r.x = p.x;
        r.z = p.z;
        r.base = groundAt(p.x, p.z) + (p.y > 0 ? p.y : 0);
        r.yaw = p.yaw;
        r.pitch = p.pitch || 0;
        r.roll = p.roll || 0;
        r.flight = p.flight === true;
        r.speed = p.speed || 0;
        r.local = true;
        return r;
    }
    // One bot, by index -- `get` rather than `list`, the same reason `perchTarget`
    // gives: a handle per bot is an object and four closures, and this reads one.
    const bot = goats.bots.get(b.perch);
    if (bot === null) return null;
    r.mode = bot.mode;
    r.x = bot.x;
    r.z = bot.z;
    r.base = groundAt(bot.x, bot.z) + (bot.y > 0 ? bot.y : 0);
    r.yaw = bot.yaw;
    r.pitch = bot.pitch || 0;
    r.roll = bot.roll || 0;
    r.flight = bot.flight === true;
    r.speed = 0;
    r.local = true;
    return r;
}

// Where the bird sits: on the goat's *drawn* back, not at its feet. The mesh turns
// about `explosions.fling.pivot` (its barrel), so the seat is the point the flung arc
// rotates: `feet + pivot + R * (PERCH_H - pivot)`. At zero attitude that is exactly
// `feet + PERCH_H`, the old perch height -- a bird on a standing goat does not move.
function riderTarget(b, pivot) {
    const r = riderState(b);
    if (r === null) return null;
    bodyQuatInto(Q_RIDE, r);
    qRotInto(V_RIDE, Q_RIDE, 0, PERCH_H - pivot, 0);
    const t = RIDE_TARGET;
    t.x = r.x + V_RIDE.x;
    t.y = r.base + pivot + V_RIDE.y;
    t.z = r.z + V_RIDE.z;
    t.yaw = r.yaw;
    t.pitch = r.pitch;
    t.roll = r.roll;
    return t;
}

// One frame on the goat's back. `dur`, `speed` and `tooFar` are the goat's problem
// now: a rider goes where it goes. The attitude is the goat's own, so the bird leans
// through a turn and pitches up in a climb with it. False when the rider is gone.
function stepRide(b, pivot) {
    const t = riderTarget(b, pivot);
    if (t === null) return false;
    b.x = t.x;
    b.y = t.y;
    b.z = t.z;
    b.yaw = t.yaw;
    b.pitch = t.pitch;
    b.roll = t.roll;
    return true;
}

// The first settled, uncaptured bird perched on `rider`, or null.
function perchedOn(rider) {
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        if (b.st === ST.PERCH && b.perch === rider && !b.captured) return b;
    }
    return null;
}

// The bird already riding `rider`, or null. One bird per goat (`FLIGHT.md` §12), so
// a second bird that landed on the same back stays an ordinary perch.
function riderOf(rider) {
    for (let i = 0; i < BIRDS.length; i++) {
        if (BIRDS[i].captured && BIRDS[i].perch === rider) return BIRDS[i];
    }
    return null;
}

// The same two reads for a peer's goat, whose identity is its name rather than an index.
function perchedOnPeer(name) {
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        if (b.st === ST.PERCH && b.perch === PERCH_PEER && b.peer === name && !b.captured) {
            return b;
        }
    }
    return null;
}

function riderOfPeer(name) {
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        if (b.captured && b.perch === PERCH_PEER && b.peer === name) return b;
    }
    return null;
}

// The goat jumped with a bird on its back: the bird is its rider from now on. `RIDE`
// waits until the jump ends (`updateRiders`), because the capture jump's clip hop is
// the goat's own and re-clocking the bird in the middle of it would make the seat
// jump for a frame. A bot is captured on a hop it took during a zoomies run, so its
// `zoom` clock is still running and the next hop takes off -- deliberately *not*
// nudged here, because `zoomies()` sets the mode to `run` and would cancel the jump
// that just captured the bird (`FLIGHT.md` §4.2).
//
// A peer is the one rider this end cannot arm: `setFlight` is local, so the grant is
// published as the rider's name and the peer's own client makes it (`FLIGHT.md` §8).
function captureBird(b, rider, peer) {
    b.captured = true;
    b.justCaptured = true;
    b.perch = rider;
    b.peer = peer === undefined ? "" : peer;
    b.sent = false;
    if (rider === PERCH_PLAYER) {
        goats.player.setFlight(true);
    } else if (rider >= 0) {
        const bot = goats.bots.get(rider);
        // A bot that vanished between the hop and this frame has nothing to arm.
        if (bot !== null) bot.setFlight(true);
    }
    // The joke needs a sound: a bird that has just been kidnapped says so.
    playSquawk(b.x, b.z);
}

// The goat came down without its bird, or lost it. It leaves the way any other bird
// does, and the capability goes with it -- `setFlight(false)` is the `E` a dead or
// unloaded goat never got to make.
function releaseBird(b) {
    dismount(b);
    startTakeoff(b);
    playSquawk(b.x, b.z);
}

// Sever the ride without sending the bird away: the capability goes, the seat does
// not. `releaseBird` is the flight's exit; this is the order to come down with the
// rest of the flock (`birds land`), and the half both share.
function dismount(b) {
    const perch = b.perch;
    b.captured = false;
    b.justCaptured = false;
    b.perch = -1;
    b.peer = "";
    if (!FLIGHT_API) return;
    // A peer's grant is its own client's; the published rider map no longer names it and
    // that client clears it on the same edge.
    if (perch === PERCH_PLAYER) {
        goats.player.setFlight(false);
    } else if (perch >= 0) {
        const bot = goats.bots.get(perch);
        if (bot !== null) bot.setFlight(false);
    }
}

// Capture polling and the riders' transitions, once a frame at the top of the sim.
// The `last` tables are what make this an edge rather than a state: the goat spends
// several frames in `jump`, and a capture is the *entering* of it.
let lastPlayerMode = "";
const lastBotMode = [];
const lastPeerMode = {};

function updateRiders(pivot) {
    if (!FLIGHT_API) return;
    refreshPeers();
    const p = goats.player.state();
    if (p.mode === "jump" && lastPlayerMode !== "jump" && riderOf(PERCH_PLAYER) === null) {
        const b = perchedOn(PERCH_PLAYER);
        if (b !== null) captureBird(b, PERCH_PLAYER);
    }
    lastPlayerMode = p.mode;

    const list = goats.bots.list();
    for (let i = 0; i < list.length; i++) {
        const mode = list[i].mode;
        if (mode === "jump" && lastBotMode[i] !== "jump" && riderOf(i) === null) {
            const b = perchedOn(i);
            if (b !== null) captureBird(b, i);
        }
        lastBotMode[i] = mode;
    }
    // The herd can be resized under the table; a shorter list leaves stale entries
    // that the next bot at that index would inherit, so trim it here.
    lastBotMode.length = list.length;

    // ...and the same edge for a joiner's goat, from the host's mirror of it. The name is
    // the identity and a frame's absence of it is a disconnect, so the table is rebuilt and
    // the names that left are dropped below.
    if (PEERS_API) {
        const seen = {};
        for (let i = 0; i < peerRows.length; i++) {
            const peer = peerRows[i];
            seen[peer.name] = true;
            if (peer.mode === "jump" && lastPeerMode[peer.name] !== "jump" &&
                riderOfPeer(peer.name) === null) {
                const b = perchedOnPeer(peer.name);
                if (b !== null) captureBird(b, PERCH_PEER, peer.name);
            }
            lastPeerMode[peer.name] = peer.mode;
        }
        for (const name in lastPeerMode) {
            if (seen[name] !== true) delete lastPeerMode[name];
        }
    }

    // Then the riders: a capture becomes a ride once its goat is out of the jump, and
    // a goat that lost the bird lets it go. One pass over the flock, so a rider's own
    // step finds the state settled rather than seeing last frame's capture.
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        if (!b.captured) continue;
        // The grant is made *in this pass*, and the port's mod realm reads the snapshot the
        // frame pushed before these hooks ran -- so a capture would see its own goat still
        // unarmed and release the bird on the spot. One frame of grace is the whole fix, and
        // it is only the `!flight` clause: a death or a release this frame still counts.
        const granted = b.justCaptured;
        b.justCaptured = false;
        const r = riderState(b);
        // `fall` is the release and `dead` is the end of the goat; `!flight` is a capability
        // taken away by a blast, a restart, or another mod -- and only *this* end can read
        // it, so a peer's own grant is not second-guessed here.
        const lost = r !== null && r.local && !r.flight && !granted;
        if (r === null || r.mode === "fall" || r.mode === "dead" || lost) {
            releaseBird(b);
            continue;
        }
        if (b.st === ST.PERCH && r.mode !== "jump") setSt(b, ST.RIDE, 0);
    }
}

function flapWave(t, amp, hz) { return amp * (0.5 - 0.5 * COS(t * hz * PI * 2)); }

// A grounded bird that has been left behind flies to catch up; walking at 1.1
// m/s cannot keep pace with a running player, and a bird stranded far away is
// culled and looks like it vanished.
function tooFar(b) {
    // A bird sent to a device (`birds boom`) is on an errand, and the errand is out
    // past the flock's home by definition -- turning back would defeat it.
    if (b.sent) return false;
    const dx = HOME.x - b.x, dz = HOME.z - b.z;
    const r = HOME_R + 6;
    return dx * dx + dz * dz > r * r;
}

// The wing flap is a pure function of the state and its clock, so the host and
// a mirroring client pose a bird identically without sending the angle.
function flapFor(b) {
    const glide = b.st === ST.FLY && FLOOR(b.t / 6) % 2 === 1;
    switch (b.st) {
        case ST.FLY: return glide ? 0.10 + 0.05 * SIN(b.t * 2) : flapWave(b.t, 0.8, 2.2);
        case ST.TAKEOFF: return flapWave(b.t, 0.95, 1.7);
        case ST.LAND: return flapWave(b.t, 0.7, 1.2) * (1 - 0.6 * clamp(b.t / LAND_TIME, 0, 1));
        case ST.WALK: return 0.06 * (1 + SIN(b.t * 8));
        case ST.PERCH: return 0.04 * (1 + SIN(b.t * 5));
        case ST.RIDE: return flapWave(b.t, RIDE_FLAP_AMP, RIDE_FLAP_HZ);
        case ST.FLUNG: return flapWave(b.t, 0.95, 3.2);   // frantic, and getting nowhere
        default: return 0;
    }
}

function stepIdle(b, dt) {
    if (tooFar(b)) { startTakeoff(b); return; }
    // The water can arrive under a bird that is standing in it: the flock does not wait
    // for the pool to drain, it leaves.
    if (!dryAt(b.x, b.z)) { startTakeoff(b); return; }
    b.y += (groundAt(b.x, b.z) + LEG - b.y) * MIN(1, dt * 8);
    if (b.t < b.dur) return;
    const roll = flockRnd();
    if (roll < 0.72) setSt(b, ST.WALK, rand(3, 7));
    else startTakeoff(b);
}

function stepWalk(b, dt) {
    b.x += COS(b.yaw) * WALK_SPEED * dt;
    b.z += -SIN(b.yaw) * WALK_SPEED * dt;
    b.y += (groundAt(b.x, b.z) + LEG - b.y) * MIN(1, dt * 8);
    b.yaw += SIN(b.t * 1.7 + b.size * 9) * 0.6 * dt;
    if (tooFar(b)) { startTakeoff(b); return; }
    // ...and the same for a bird that walks *into* one: the step that puts its feet under
    // the water is the step that lifts it off, so a pool is walked around rather than
    // waded through.
    if (!dryAt(b.x, b.z)) { startTakeoff(b); return; }
    const dx = HOME.x - b.x, dz = HOME.z - b.z;
    if (dx * dx + dz * dz > HOME_R * HOME_R) b.yaw = ATAN2(-dz, dx);
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
    b.x += COS(b.yaw) * sp * dt;
    b.z += -SIN(b.yaw) * sp * dt;
    if (u >= 1) setSt(b, ST.FLY, rand(6, 12));
}

function stepLand(b, dt) {
    // A perch target that keeps moving is given up: chasing one never closes,
    // and the bird would hang in the air instead of ever landing.
    if (b.t > LAND_TIME + 1.5) { b.perch = -1; b.peer = ""; }
    const perch = b.perch === -1 ? null : perchTarget(b);
    if (b.perch !== -1 && perch === null) { b.perch = -1; b.peer = ""; }

    const ground = groundAt(b.x, b.z) + LEG;
    const tx = perch === null ? b.x : perch.x;
    const tz = perch === null ? b.z : perch.z;
    const ty = perch === null ? ground : perch.y;
    const k = MIN(1, dt * 2.5);
    b.x += (tx - b.x) * k;
    b.z += (tz - b.z) * k;
    b.y += (ty - b.y) * k;
    b.yaw += angleDelta(ATAN2(-(tz - b.z), tx - b.x), b.yaw) * k;

    if (perch === null) {
        // Over water there is nothing to stand on: the descent gives up rather than
        // settling a centimetre under the surface, which is where the flock used to end up
        // in a pool (a pair of wings and no bird).
        if (!dryAt(b.x, b.z)) { startTakeoff(b); return; }
        // The ground target moves with the bird, so only the height can settle.
        if (ABS(b.y - ground) < 0.25) {
            setSt(b, flockRnd() < 0.4 ? ST.WALK : ST.IDLE, rand(2, 6));
        }
        return;
    }
    const dx = b.x - perch.x, dz = b.z - perch.z;
    if (dx * dx + dz * dz < 1.44 && ABS(b.y - perch.y) < 0.9) {
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

// Thrown by a device it set off (`tripDevices`). The goat's arc, in a lighter body:
// the same gravity, its own push and lift, and it ends where the ground is -- crater
// or slope or neither, because the ground is `terrainHeight` for a bird too.
function stepFlung(b, dt) {
    b.vy += FLUNG_GRAVITY * dt;
    b.x += b.vx * dt;
    b.z += b.vz * dt;
    b.y += b.vy * dt;
    b.yaw = ATAN2(-b.vz, b.vx);
    const rest = groundAt(b.x, b.z) + LEG;
    if ((b.vy < 0 && b.y <= rest) || b.t >= FLUNG_MAX) {
        b.y = rest;
        b.vx = b.vz = b.vy = 0;
        b.pitch = b.roll = 0;
        setSt(b, flockRnd() < 0.5 ? ST.WALK : ST.IDLE, rand(2, 5));
    }
}

// A bird walking over a device sets it off, and is thrown by it. Both halves are the
// mod surface M19g added: `goats.explosions.traps` is the field, read-only and the
// same derivation the core uses (so a device a mod has switched off is not a device
// here either), and `goats.explosions.blast` is the bang. Only the process that
// simulates the flock asks -- a mirroring client is told, like every other state.
function tripDevices(b) {
    // The half-metre bucket, the core's own trick in `checkTriggers`: a bird standing
    // still would otherwise ask the field the same question sixty times a second.
    const stamp = ((((b.x * 2) | 0) + 4096) * 8192 + (((b.z * 2) | 0) + 4096));
    if (b.trip === stamp) return;
    b.trip = stamp;
    // `traps` is already filtered to `range` of the bird's feet, which is the whole
    // trigger test at the core's own radius -- `mine.trigger` is what a goat walks
    // within, and a bird is no wider. Of either kind, the *nearest* is what goes off: a
    // bird standing on a trap with a mine half a metre away sets off what it is on.
    const near = goats.explosions.traps(b.x, b.z, TRIP_R);
    let kind = null, dev = null, best = Infinity;
    const pools = [["mine", near.mines], ["trap", near.traps]];
    for (let i = 0; i < pools.length; i++) {
        const list = pools[i][1];
        for (let j = 0; j < list.length; j++) {
            if (list[j].dist < best) {
                best = list[j].dist;
                kind = pools[i][0];
                dev = list[j];
            }
        }
    }
    if (dev === null) return;
    // The core's own blast path, so the crater, the damage, the light, the sound, the
    // event and -- in a session -- the report are the ones a goat's bang gets. It also
    // spends the device in that cell and moves its replacement, which is what keeps the
    // bird from setting the same one off on landing and keeps the field drifting.
    goats.explosions.blast(dev.x, dev.z, kind);
    flingBird(b, dev);
    trips += 1;
    if (kind === "trap") trapTrips += 1;
    else mineTrips += 1;
}

// A bird thrown by a device squawks on the way out: one of the two calls, picked and
// pitched like the goat's own bleats so a field of birds does not sound like a button,
// faded by how far the goat is. The volume rides the sfx slider; the master mute (`M`)
// is not on the mod surface, which is the one place a mod's sound cannot follow the
// game's -- a `muted` on `goats.settings` would close it.
function playSquawk(x, z) {
    if (SQUAWKS.length === 0) return;
    const p = goats.player.state();
    const att = 1 / (1 + HYPOT(x - p.x, z - p.z) / SQUAWK_FADE);
    const sound = SQUAWKS[FLOOR(flockRnd() * SQUAWKS.length) % SQUAWKS.length];
    goats.sfx.play(sound, goats.settings.get().sfx * SQUAWK_VOLUME * att,
        0.9 + flockRnd() * 0.25);
}

function flingBird(b, dev) {
    let dx = b.x - dev.x, dz = b.z - dev.z;
    let d = HYPOT(dx, dz);
    // Standing right on it: blown back the way it came in.
    if (d < 0.05) { dx = -COS(b.yaw); dz = SIN(b.yaw); d = 1; }
    b.vx = (dx / d) * FLUNG_PUSH;
    b.vz = (dz / d) * FLUNG_PUSH;
    b.vy = FLUNG_LIFT;
    b.perch = -1;
    b.sent = false;
    b.roll = 0;
    setSt(b, ST.FLUNG, FLUNG_MAX);
    playSquawk(b.x, b.z);
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
            aliX += COS(o.yaw); aliZ += -SIN(o.yaw); nA++;
        }
        if (d2 > 1e-4 && d2 < SEP * SEP) {
            // Graded by distance, so a near pair pushes harder than a distant one.
            const d = SQRT(d2);
            const w = (SEP - d) / SEP;
            sepX += (dx / d) * w;
            sepZ += (dz / d) * w;
            nS++;
        }
    }
    let ax = 0, az = 0;
    if (nS > 0) {
        const m = HYPOT(sepX, sepZ) || 1;
        ax += (sepX / m) * 10.0;
        az += (sepZ / m) * 10.0;
    }
    if (nA > 0) {
        const m = HYPOT(aliX, aliZ) || 1;
        ax += (aliX / m - COS(b.yaw)) * 2.4;
        az += (aliZ / m + SIN(b.yaw)) * 2.4;
    }
    if (nC > 0) {
        const cx = cohX / nC - b.x, cz = cohZ / nC - b.z;
        const m = HYPOT(cx, cz) || 1;
        ax += (cx / m) * 0.9;
        az += (cz / m) * 0.9;
    }
    const hx = HOME.x - b.x, hz = HOME.z - b.z;
    const hd = HYPOT(hx, hz);
    if (hd > HOME_R) { ax += (hx / hd) * 6.0; az += (hz / hd) * 6.0; }

    if (!(HYPOT(b.vx, b.vz) > 0.05)) {
        b.vx = COS(b.yaw) * FLY_SPEED;
        b.vz = -SIN(b.yaw) * FLY_SPEED;
    }
    b.vx += ax * dt;
    b.vz += az * dt;
    const sp = HYPOT(b.vx, b.vz);
    const ns = sp + (FLY_SPEED - sp) * MIN(1, dt * 1.2);
    b.vx = (b.vx / sp) * ns;
    b.vz = (b.vz / sp) * ns;
    b.x += b.vx * dt;
    b.z += b.vz * dt;
    b.yaw = ATAN2(-b.vz, b.vx);

    // Glide in stretches; flap in between. The glide flag is a function of the
    // state clock, so a client derives it from the synced `t` without being told.
    const glide = FLOOR(b.t / 6) % 2 === 1;
    const targetY = glide ? b.cruise - 0.8 : b.cruise;
    b.y += (targetY - b.y) * MIN(1, dt * 0.9);
    const floor = groundAt(b.x, b.z) + 2.5;
    if (b.y < floor) b.y += (floor - b.y) * MIN(1, dt * 2);
    b.vy = (targetY - b.y) * 0.5;

    if (b.t >= b.dur) {
        const pick = pickPerch(b);
        b.perch = pick === null ? -1 : pick.perch;
        b.peer = pick === null ? "" : pick.peer;
        setSt(b, ST.LAND, LAND_TIME);
    }
}

function poseTargets(b) {
    // A rider's attitude is its goat's, written by `stepRide`: easing it toward the
    // boid targets here would fight the seat. A mirrored rider takes the host's angles
    // in `mirror` instead, so it is the state as well as the flag.
    if (b.captured || b.st === ST.RIDE) return;
    let pitch = 0;
    if (b.st === ST.TAKEOFF) pitch = 0.5 * clamp(b.t / TAKEOFF_TIME, 0, 1);
    else if (b.st === ST.LAND) pitch = -0.25 + 0.4 * clamp(b.t / LAND_TIME, 0, 1);
    else if (b.st === ST.FLY) pitch = clamp(b.vy * 0.05, -0.18, 0.18);
    else if (b.st === ST.FLUNG) pitch = clamp(b.vy * 0.06, -0.7, 0.7);
    // A flung bird tumbles on the *state clock* rather than easing toward a target: a
    // mirroring client resets that clock when the state arrives, so both ends spin at
    // the same rate without the angle being sent, and the whole turns land it level.
    if (b.st === ST.FLUNG) {
        b.pitch = pitch;
        b.roll = -b.t * FLUNG_SPIN * PI * 2;
        return;
    }
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
            let d = SQRT(d2);
            let ux, uz;
            if (d < 1e-3) { ux = COS(i * 2.4); uz = SIN(i * 2.4); }
            else { ux = dx / d; uz = dz / d; }
            const push = (MIN_GAP - d) * 0.5;
            a.x -= ux * push; a.z -= uz * push;
            b.x += ux * push; b.z += uz * push;
        }
    }
}

// The pivot the goat's own body turns about (`FLIGHT.md` §4.3), read once a frame: a
// tuning write can move it while the game runs, and the clamp is the reference's own.
function ridePivotNow() {
    const v = goats.tuning.get("explosions.fling.pivot");
    return typeof v === "number" && IS_FINITE(v) ? v : 0.7;
}

function simulate(dt) {
    updateHome();
    ridePivot = ridePivotNow();
    // The host's window on the joiners (`APIv1.md` §4.21), once a frame for the riders to
    // read: `goats.peers.list()` builds its rows on every call.
    refreshPeers();
    // Capture and release first: the frame the goat jumps is the frame the bird
    // becomes its rider, and a goat that has lost its bird is a plain perch again.
    updateRiders(ridePivot);
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        // A non-finite position draws as nothing, so recover the bird rather
        // than let it silently vanish. A captured bird's recovery is its rider: a
        // teleporting flock must not leave the rider behind on the old ground.
        if (!IS_FINITE(b.x) || !IS_FINITE(b.y) || !IS_FINITE(b.z) ||
            !IS_FINITE(b.yaw)) {
            if (!(b.captured && stepRide(b, ridePivot) && IS_FINITE(b.x) &&
                IS_FINITE(b.y) && IS_FINITE(b.z))) {
                placeBird(b, i);
            }
            continue;
        }
        b.prevYaw = b.yaw;
        b.t += dt;
        switch (b.st) {
            case ST.WALK: stepWalk(b, dt); break;
            case ST.TAKEOFF: stepTakeoff(b, dt); break;
            case ST.FLY: stepFly(b, dt); break;
            case ST.LAND: stepLand(b, dt); break;
            // A captured bird is on its goat's back until the jump that captured it
            // ends; only the *state* waits for `RIDE` (`FLIGHT.md` §4.2).
            case ST.PERCH: if (b.captured) stepRide(b, ridePivot); else stepPerch(b, dt); break;
            case ST.RIDE: stepRide(b, ridePivot); break;
            case ST.FLUNG: stepFlung(b, dt); break;
            default: stepIdle(b, dt); break;
        }
        // On the ground is where a device can be tripped. A bird on a goat's back is
        // 1.15 m up, over the `clearance` a mine needs -- the goat it is riding trips
        // that one, if anything does. A rider never trips one either.
        if (b.st === ST.IDLE || b.st === ST.WALK) tripDevices(b);
        b.yawRate = angleDelta(b.yaw, b.prevYaw) / dt;
        poseTargets(b);
    }
    separateFlock();
}

// A client does not simulate: it eases toward the host's last snapshot and
// advances the state clock so the flap stays smooth between packets.
const MIRROR_K = 7;
function mirror(dt) {
    ridePivot = ridePivotNow();
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        b.prevYaw = b.yaw;
        b.t += dt;
        // A flung bird is moving at the arc's speed rather than at a boid's, so it
        // gets a stiffer ease: the snapshot arrives at the world datagram's cadence and
        // a first-order lag would leave it gliding a dozen metres behind the host's.
        const k = MIN(1, dt * (b.st === ST.FLUNG ? 14 : MIRROR_K));
        b.x += (b.tx - b.x) * k;
        b.y += (b.ty - b.y) * k;
        b.z += (b.tz - b.z) * k;
        b.yaw += angleDelta(b.tyaw, b.yaw) * k;
        b.yawRate = angleDelta(b.yaw, b.prevYaw) / dt;
        if (b.st === ST.RIDE || b.captured) {
            // A rider's attitude is its goat's, so the host *sends* it -- the row's last
            // two numbers (`FLIGHT.md` §6.2) -- and the client eases toward it. The boid
            // targets would build a different attitude from the position's own motion.
            // During the capture jump the state is still PERCH, but `captured` is set, so
            // the attitude is the goat's then too.
            b.pitch += (b.tpitch - b.pitch) * k;
            b.roll += (b.troll - b.roll) * k;
        } else {
            poseTargets(b);
        }
        // ...and if the host named *this* client's goat as the rider (`apply`), the bird
        // sits on the local goat exactly, rather than on the host's snapshot of it: the
        // eased row is the host's view, a pose or two behind. The state and the clock are
        // still the host's, so the flap stays in step.
        if (b.mine) {
            b.perch = PERCH_PLAYER;
            b.peer = "";
            stepRide(b, ridePivot);
        }
    }
}

// ---- multiplayer ----------------------------------------------------------
//
// The host simulates the flock; a joiner mirrors it. The rows carry the flight; the
// `riders` map carries *who* is riding, because a capability is local and the one client
// that can arm a joiner's goat is that joiner (`FLIGHT.md` §8). It is a map rather than a
// column of names so an ordinary frame -- no riders -- costs `{}`.

// The name the rider's own client compares against `goats.net.name()`. The host's own
// goat is named on a client host -- so a joiner never mistakes "the local player" for
// itself. A *server* host has no name of its own (`goatsd` is not a player) and its
// phantom player goat never jumps, so it publishes nothing rather than a word a joiner
// could have asked for. A solo game has no consumer, and "player" is a readable fallback.
function riderKey(b) {
    if (!b.captured) return "";
    if (b.perch === PERCH_PEER) return b.peer;
    if (b.perch === PERCH_PLAYER) {
        const name = goats.net.name();
        return name !== "" ? name : (goats.net.inSession() ? "" : "player");
    }
    return "bot:" + b.perch;
}

// Whether the last applied snapshot named this client's goat. The grant is made on the
// *edge*, not while the name persists: a joiner's own `E`, a restart or a death clears the
// capability locally, and re-arming it from a snapshot still naming the same bird would
// undo the release for as long as the host takes to notice.
let localRider = false;

goats.world.extend(MOD_ID, {
    publish: function () {
        const out = [];
        const riders = {};
        for (let i = 0; i < BIRDS.length; i++) {
            const b = BIRDS[i];
            // Seven numbers per bird: the five the flock has always published, then
            // the attitude a `RIDE` bird inherits from its goat (`FLIGHT.md` §6.2).
            // `publishRows` rounds them and refuses a NaN, so a bug here lands in the
            // log with this mod's name on it rather than arriving at every peer as
            // `null`; it accepts up to eight wide, so the row is still legal.
            out.push([r1(b.x), r1(b.y), r1(b.z), r2(b.yaw), b.st, r2(b.pitch), r2(b.roll)]);
            const key = riderKey(b);
            if (key !== "") riders[i] = key;
        }
        return { rows: goats.world.publishRows(out), riders: riders };
    },
    apply: function (state) {
        // The object is 1.2.0's shape; a bare array is 1.1.0's, and reading it costs one
        // branch -- the row itself did not change.
        const rows = Array.isArray(state) ? state :
            (state !== null && typeof state === "object" ? state.rows : null);
        if (!Array.isArray(rows)) return;
        const riders = !Array.isArray(state) && state !== null &&
            typeof state === "object" && typeof state.riders === "object" &&
            state.riders !== null ? state.riders : null;
        const myName = goats.net.name();
        let named = false;
        syncFlock(rows.length);
        for (let i = 0; i < rows.length; i++) {
            const s = rows[i];
            const b = BIRDS[i];
            if (!Array.isArray(s) || s.length < 5) continue;
            if (!IS_FINITE(s[0]) || !IS_FINITE(s[1]) || !IS_FINITE(s[2]) ||
                !IS_FINITE(s[3])) continue;
            const st = s[4] | 0;
            // The state clock is local; reset it only when the state changes, so
            // the flap and the take-off/landing pitch still run smoothly.
            if (b.st !== st) b.t = 0;
            b.st = st;
            b.tx = s[0]; b.ty = s[1]; b.tz = s[2]; b.tyaw = s[3];
            // The two attitude numbers arrived with protocol 12. An older row has no
            // fifth/sixth value, and a client in a mixed session cannot happen anyway
            // (the mod's hash is in the handshake) -- but reading a missing slot as 0
            // is what makes the row's shape additive rather than a second version.
            b.tpitch = IS_FINITE(s[5]) ? s[5] : 0;
            b.troll = IS_FINITE(s[6]) ? s[6] : 0;
            // Who is on the back. Only this client's own goat grants anything; a peer's
            // rider is drawn from the host's eased row like any other `RIDE` bird.
            const rider = riders === null ? undefined : riders[i];
            const mine = myName !== "" && rider === myName;
            if (mine) named = true;
            b.captured = rider !== undefined;
            b.mine = mine;
            b.perch = mine ? PERCH_PLAYER : -1;
            b.peer = "";
        }
        // The edge: the host has just named this goat, so the bird is aboard and the next
        // running jump is a take-off; or it has stopped naming it (a release, a death, a
        // blast), and the capability goes with the bird.
        if (FLIGHT_API && named !== localRider) {
            goats.player.setFlight(named);
            localRider = named;
        }
    },
});

// ---- render ---------------------------------------------------------------

// One bird's parts, shared by the lit pass and the shadow pass. The draw calls are
// the same either way: the scene routes `goats.gfx.draw.mesh` through its depth
// program while the `shadow` hook runs (mods.js), so this casts without a second
// code path -- and the Godot port, whose meshes cast by default, simply never
// emits the hook.
function drawBird(b, i) {
    const s = SCALE * b.size;
    const q = bodyQuatInto(Q_BODY, b);
    const ba = qAxisAngleInto(AA_BODY, q);
    const tint = goats.draw.color(200 + ((i * 17) % 56), 200 + ((i * 29) % 56), 200 + ((i * 11) % 56), 255);
    goats.gfx.draw.mesh(bodyModel, b.x, b.y, b.z, ba.x, ba.y, ba.z, ba.rad, s, tint);
    const f = flapFor(b);
    for (let side = -1; side <= 1; side += 2) {
        const wq = qMulInto(Q_TMP1, q, qAxisInto(Q_TMP2, 1, 0, 0, side > 0 ? -f : f));
        const wa = qAxisAngleInto(AA_WING, wq);
        const pv = qRotInto(V_WING, q, SHOULDER.x * s, SHOULDER.y * s, side * SHOULDER.z * s);
        goats.gfx.draw.mesh(side > 0 ? wingR : wingL,
            b.x + pv.x, b.y + pv.y, b.z + pv.z, wa.x, wa.y, wa.z, wa.rad, s, tint);
    }
}

function drawFlock(cam) {
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        const dx = b.x - cam.x, dz = b.z - cam.z;
        if (dx * dx + dz * dz > CULL * CULL) continue;
        drawBird(b, i);
    }
}

// The flock casts into the scene's shadow map, the way it does in the Godot port
// where a `MeshInstance3D` casts by default. What this replaces is the pair of
// translucent cubes the lit pass used to drop under each bird -- flat squares that
// ignored the sun, the wings and the crest. No cull here: six birds, and the map
// clips what is outside its box.
goats.on("shadow", function () {
    if (bodyModel === null) return;
    ensureBuilt();
    for (let i = 0; i < BIRDS.length; i++) drawBird(BIRDS[i], i);
});

// ---- lifecycle and surface ------------------------------------------------

// The flock is offered to other mods, which is the whole of the fatguy's bird
// collision: a row is `[x, y, z, r]` and it is read live, because the flock moves
// every frame (APIv1.md §4.16). Nothing is published for this -- it is a client's
// own view of the birds it is drawing.

// The rows are read on the spot -- `modEntitiesNear` runs the callback and walks the
// rows in the same call -- so they are pooled and refilled rather than rebuilt: a row
// and its array, per bird, per query, was 13 allocations a frame for the one asker
// (PERF.md appendix B).
const ENTITY_ROWS = [];

goats.entities.offer("flock", function () {
    for (let i = 0; i < BIRDS.length; i++) {
        const row = ENTITY_ROWS[i] === undefined ? (ENTITY_ROWS[i] = [0, 0, 0, 0]) : ENTITY_ROWS[i];
        row[0] = BIRDS[i].x;
        row[1] = BIRDS[i].y;
        row[2] = BIRDS[i].z;
        row[3] = BODY_R;
    }
    ENTITY_ROWS.length = BIRDS.length;
    return ENTITY_ROWS;
});

goats.on("update", function (dt) {
    if (!(dt > 0)) return;
    ensureBuilt();
    const local = goats.net.localWorld();
    if (local) simulate(dt);
    else mirror(dt);
    // Both ends: a bird on the back of *this* process's goat is this process's gift,
    // whoever simulated the landing.
    blessGoat(dt, local);
});

goats.on("draw3d", function (cam) {
    ensureBuilt();
    if (bodyModel === null) return;
    drawFlock(cam);
});

goats.on("shutdown", function () {
    // The grant is this mod's, so it goes with the mod: a goat left armed by a bird
    // that no longer exists could still take off. On a client the bot writes are
    // ignored, exactly as every other bot write is (the host owns the herd).
    if (FLIGHT_API) {
        goats.player.setFlight(false);
        const list = goats.bots.list();
        for (let i = 0; i < list.length; i++) list[i].setFlight(false);
    }
    if (bodyModel !== null) goats.gfx.unload(bodyModel);
    if (wingR !== null) goats.gfx.unload(wingR);
    if (wingL !== null) goats.gfx.unload(wingL);
    bodyModel = wingR = wingL = null;
    built = false;
    BIRDS = [];
    // The sounds are dropped rather than freed: there is no `unloadSound` to call.
    SQUAWKS = [];
});

goats.command("birds", function (parts) {
    const verb = parts[1] === undefined ? "" : parts[1];
    if (verb === "scatter") { seedFlock(); return "ok birds scattered"; }
    if (verb === "gather" || verb === "here") { gatherBirds(); return "ok birds gathered"; }
    if (verb === "fly") {
        dropRiders();
        for (let i = 0; i < BIRDS.length; i++) startTakeoff(BIRDS[i]);
        return "ok birds flying";
    }
    if (verb === "land") {
        for (let i = 0; i < BIRDS.length; i++) {
            // A landing order ends a ride too: an order that left a goat armed with
            // no bird on its back would be the one way to fly away from the flock.
            if (BIRDS[i].captured) dismount(BIRDS[i]);
            BIRDS[i].perch = -1;
            setSt(BIRDS[i], ST.LAND, LAND_TIME);
        }
        return "ok birds landing";
    }
    if (verb === "mount") {
        // The test/demo path (`FLIGHT.md` §4.6): a bird straight onto the player's
        // goat, armed, without waiting for a landing to pick it.
        if (!FLIGHT_API) return "error birds: this client has no flight";
        if (!goats.net.localWorld()) return "error birds: the host owns the flock";
        if (BIRDS.length === 0) return "ok no birds";
        const b = riderOf(PERCH_PLAYER) || BIRDS[0];
        b.captured = true;
        b.perch = PERCH_PLAYER;
        b.sent = false;
        stepRide(b, ridePivot);   // seated this frame, not the next
        setSt(b, ST.RIDE, 0);
        goats.player.setFlight(true);
        return "ok bird mounted";
    }
    if (verb === "drop") {
        if (!goats.net.localWorld()) return "error birds: the host owns the flock";
        const b = riderOf(PERCH_PLAYER);
        if (b === null) return "ok no bird aboard";
        // `E` first, so the bird leaves a goat that is already falling rather than one
        // still in the air with its capability taken away.
        goats.player.release();
        releaseBird(b);
        return "ok bird released";
    }
    if (verb === "ride") {
        if (!FLIGHT_API) return "error birds: this client has no flight";
        if (!goats.net.localWorld()) return "error birds: the host owns the flock";
        if (BIRDS.length === 0) return "ok no birds";
        ridePivot = ridePivotNow();
        // A number is a bot; a name is a joiner's goat (`FLIGHT.md` §8). The peer path is
        // the host's alone, because the flock is the host's -- and it arms nothing here:
        // the published rider map is what the peer's own client grants from.
        const arg = parts[2] === undefined ? "0" : String(parts[2]);
        const want = Number(arg);
        if (!IS_FINITE(want)) {
            if (!PEERS_API) return "error birds: this client has no peers";
            refreshPeers();
            const peer = peerByName(arg);
            if (peer === null) return "error birds: no peer " + arg;
            const b = riderOfPeer(arg) || BIRDS[0];
            b.captured = true;
            b.justCaptured = false;   // a peer's grant is its own client's, not this end's
            b.perch = PERCH_PEER;
            b.peer = arg;
            b.sent = false;
            stepRide(b, ridePivot);
            setSt(b, ST.RIDE, 0);
            return "ok bird riding peer " + arg;
        }
        const index = FLOOR(want);
        const bot = goats.bots.get(index);
        if (bot === null) return "error birds: no bot " + index;
        const b = riderOf(index) || BIRDS[0];
        b.captured = true;
        b.perch = index;
        b.peer = "";
        b.sent = false;
        stepRide(b, ridePivot);
        setSt(b, ST.RIDE, 0);
        bot.setFlight(true);
        // The bot's take-off is the zoomies run's hop (`bots.js`), so start one: it
        // hops, and the hop is the flight. A capture path never does this -- it would
        // cancel the jump that captured the bird (`FLIGHT.md` §4.2).
        bot.zoomies(3);
        return "ok bird riding bot " + index;
    }
    if (verb === "sit") {
        // A bird on the goat's back, and the rest of the flock on the ground beside it.
        // A name seats it on that joiner's goat instead, which is the host's own view of
        // the capture (`FLIGHT.md` §8): the bird is a plain perch until that goat jumps.
        gatherBirds();
        if (BIRDS.length === 0) return "ok birds sitting";
        if (parts[2] !== undefined) {
            if (!PEERS_API) return "error birds: this client has no peers";
            if (!goats.net.localWorld()) return "error birds: the host owns the flock";
            refreshPeers();
            const name = String(parts[2]);
            const peer = peerByName(name);
            if (peer === null) return "error birds: no peer " + name;
            perchOnPeer(BIRDS[0], peer);
            return "ok bird sitting on " + name;
        }
        perchOnGoat(BIRDS[0]);
        return "ok birds sitting";
    }
    if (verb === "boom") {
        // Send a bird onto the nearest device and let the next update trip it, so the
        // command exercises the same path a wandering bird does rather than a shortcut.
        const dev = nearestDevice(parts[2]);
        if (dev === null) return "ok no device in reach";
        if (BIRDS.length === 0) return "ok no birds";
        const b = BIRDS[0];
        // Sending a rider into a mine field is still a ride ending: the goat is disarmed
        // before the errand, not left holding a grant for a bird that has flown off.
        if (b.captured) dismount(b);
        b.x = dev.x;
        b.z = dev.z;
        b.y = groundAt(dev.x, dev.z) + LEG;
        b.vx = b.vz = b.vy = 0;
        b.perch = -1;
        b.peer = "";
        b.trip = -1;      // the bucket must not swallow the move
        b.sent = true;    // the errand is deliberately outside the flock's home
        setSt(b, ST.IDLE, 1);
        return "ok bird sent to the " + dev.kind;
    }
    const counts = {};
    let near = Infinity, far = 0;
    let captured = 0;
    const riders = [];
    const p = goats.player.state();
    for (let i = 0; i < BIRDS.length; i++) {
        const b = BIRDS[i];
        const name = ST_NAME[b.st] || "?";
        counts[name] = (counts[name] || 0) + 1;
        if (b.captured) {
            captured += 1;
            riders.push(b.perch === PERCH_PEER ? b.peer :
                b.perch === PERCH_PLAYER ? "player" : b.perch);
        }
        const d = HYPOT(b.x - p.x, b.z - p.z);
        if (d < near) near = d;
        if (d > far) far = d;
    }
    return "ok " + JSON.stringify({ count: BIRDS.length, local: goats.net.localWorld(),
        anchor: anchorPlayer ? "player" : "herd", near: BIRDS.length ? r1(near) : null,
        far: BIRDS.length ? r1(far) : null, states: counts, captured: captured,
        riders: riders, flight: FLIGHT_API,
        trips: trips, mineTrips: mineTrips, trapTrips: trapTrips, blessed: r1(blessed) });
});

goats.log("birds: " + COUNT + " procedural birds ready");

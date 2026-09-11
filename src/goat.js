// A walking, running, jumping goat for the Slag x raylib sandbox.
//
// The goat is `goat_animated.glb`, the model baked from the Blender rig. It is
// loaded through the `rl` model surface added for this demo:
//
//   rl.loadModel            load a .glb (also finds embedded assets)
//   rl.isModelValid         did it load?
//   rl.modelBounds          bounding box, used to stand the goat on the ground
//   rl.modelAnimationCount  how many clips came with it
//   rl.modelAnimationName   clip name ("GoatIdle", "GoatWalk", "GoatRun",
//                           "GoatJump", "GoatTrot", "GoatSleep", "GoatDeath")
//   rl.modelAnimationFrameCount
//   rl.modelAnimationDuration  clip length in seconds
//   rl.updateModelAnimation pose the model at a clip frame
//   rl.drawModelEx          draw it with position, yaw, scale and tint
//   rl.unloadModel          free the model and its clips
//
// Every clip bakes its forward travel as *in-place* motion, so the goat is
// moved by the script at the speed the gait implies and the clip is advanced at
// the matching rate, which keeps the hooves from skating:
//
//   speed = stride / (duty * clipDuration)
//
// where `stride` is how far a planted hoof sweeps back per step and `duty` is
// the fraction of the cycle that foot spends on the ground. Jump height comes
// from the `GoatJump` clip's root motion, so the script only needs to move the
// goat horizontally while it is airborne.
//
// If the model cannot be loaded (an `rl` build without `SUPPORT_FILEFORMAT_GLTF`,
// or a missing asset) the sandbox falls back to the original cube-skeleton goat:
// voxel-filled body boxes and 2-bone-IK limbs drawn with `rl.drawCube`.
//
// A day/night cycle drives a gradient sky, a sun and moon arcing overhead, a
// star field, a scene-wide ambient tint and a blob shadow. Hold T to
// fast-forward the clock. (True lighting and cast shadows need shaders and are
// still on the roadmap.)
//
// The goat has health and energy. Energy drains faster the harder it works; at
// zero the goat is exhausted -- capped at a walk and slowly losing health -- so
// it has to sleep to recover. At zero health it dies and needs a restart.
//
// Controls:
//   W / S         walk forward / backward
//   CTRL + W/S    trot
//   SHIFT + W/S   run
//   SPACE         jump
//   Z             sleep / wake
//   R             restart after death
//   T (hold)      fast-forward the clock
//   A / D         turn left / right
//   mouse drag    orbit the camera        mouse wheel    zoom
//   P             pause / resume
//   ESC           quit

// ---- tuning --------------------------------------------------------------

const MODEL_PATH = "goat_animated.glb";
const MODEL_SCALE = 1.0;
const TURN_RATE = 1.8;     // rad/s
const FALLBACK_TROT_MULT = 1.3;  // how much faster the cube goat "trots"
const FALLBACK_RUN_MULT = 1.6;   // how much faster the cube goat "runs"
const FALLBACK_JUMP_TIME = 0.6;  // seconds of the cube goat's hop
const FALLBACK_JUMP_H = 0.55;    // metres of the cube goat's hop

// ---- stats ---------------------------------------------------------------

const MAX_STAT = 100;
const ENERGY_DRAIN = { idle: 0.4, walk: 1.0, trot: 2.0, run: 4.0 };  // per second
const JUMP_ENERGY_COST = 2.0;
const SLEEP_ENERGY_RECOVER = 12;   // per second
const SLEEP_HEALTH_RECOVER = 2;
const IDLE_HEALTH_RECOVER = 0.1;
const EXHAUST_HEALTH_DRAIN = 3;
const RESTED_ENERGY = 20;          // health only regenerates above this
const AUTO_SLEEP_DELAY = 2.0;      // seconds idle while exhausted
const DEAD_EYE_FRACTION = 0.75;    // show the X eyes once the death clip is this far in

// Cube-fallback gait only (ignored when the model loads).
const V_STRIDE = 0.20;
const V_LIFT = 0.10;
const V_GROUND = 0.02;
const V_DROP = -0.08;
const V_BOB = 0.018;
const V_L1 = 0.26;
const V_L2 = 0.28;
const V_HIP_Y = 0.56;
const V_CYCLE = 0.70;

// The four legs of the cube fallback's 4-beat lateral walk (back-left leads).
const LEGS = [
    { hx: -0.34, hz: 0.18, phase: 0.00 },  // back left
    { hx: 0.34, hz: 0.18, phase: 0.25 },   // front left
    { hx: -0.34, hz: -0.18, phase: 0.50 }, // back right
    { hx: 0.34, hz: -0.18, phase: 0.75 },  // front right
];

// ---- palette (the cube fallback; the model brings its own textures) ------

const FUR = rl.color(206, 186, 156);
const FUR_DK = rl.color(150, 128, 100);
const DARK = rl.color(64, 50, 42);
const HORN = rl.color(84, 70, 56);
const HOOF = rl.color(46, 38, 34);
const EYE = rl.color(26, 22, 20);
const SKY = rl.color(150, 198, 235);
const GROUND = rl.color(104, 156, 88);
const TUFT = rl.color(78, 128, 66);

// ---- small maths helpers -------------------------------------------------

function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

function mod1(v) {
    return ((v % 1) + 1) % 1;
}

function hash(n) {
    const s = Math.sin(n * 127.1) * 43758.5453;
    return s - Math.floor(s);
}

// Local -> world: yaw about Y, then translate. The goat faces local +X, and
// `rl.drawModelEx` rotates the model by the same convention (a Y-axis rotation
// maps local +X to (cos, -sin) in the XZ plane).
function toWorld(p, g) {
    const c = Math.cos(g.yaw);
    const s = Math.sin(g.yaw);
    return { x: g.px + p.x * c + p.z * s, y: g.py + p.y, z: g.pz - p.x * s + p.z * c };
}

// A point `len` along a bone that starts at `from`, rotated `ang` in the local
// X-Y plane (measured from straight down towards +X, like the Blender rig).
function segEnd(from, ang, len) {
    return { x: from.x + Math.sin(ang) * len, y: from.y - Math.cos(ang) * len, z: from.z };
}

// ---- the model goat ------------------------------------------------------

let model = -1;
let haveModel = false;
let groundOffset = 0;

// Clip handles by role, filled in from the model's animation names. Each is
// { index, frames, duration } or null when that clip is absent.
const CLIP = { idle: null, walk: null, trot: null, run: null, jump: null, sleep: null, death: null };

// Model-space eye points baked in Blender for the sleep and death poses, used
// to place the closed-eye and X-eye sprites (glTF Y-up, from the rig).
const SLEEP_EYES = [
    { x: 0.9204, y: 0.6112, z: -0.2877 },
    { x: 0.9879, y: 0.6272, z: -0.0165 },
];
const DEATH_EYES = [
    { x: 0.8852, y: 0.9087, z: 0.1013 },
    { x: 0.8764, y: 0.8544, z: 0.3758 },
];

// Authored stride and stance fraction of each locomotion clip, used to derive
// the ground speed that keeps the hooves from skating. The walk is a 4-beat
// lateral walk and the trot a 2-beat diagonal gait (each foot planted half the
// cycle); the run is a 2-beat gait with a short flight phase (each foot planted
// a third of the cycle).
const GAIT = {
    walk: { stride: 0.40, duty: 0.50 },
    trot: { stride: 0.46, duty: 0.50 },
    run: { stride: 0.50, duty: 0.34 },
};

function findClip(names, wanted) {
    for (let i = 0; i < names.length; i++) {
        if (names[i].toLowerCase().indexOf(wanted) >= 0) return i;
    }
    return -1;
}

function clipInfo(index) {
    return {
        index: index,
        frames: rl.modelAnimationFrameCount(model, index),
        duration: rl.modelAnimationDuration(model, index),
    };
}

function gaitSpeed(role) {
    const info = CLIP[role];
    const gait = GAIT[role];
    if (info === null || gait === undefined || info.duration <= 0) return null;
    return gait.stride / (gait.duty * info.duration);
}

function walkSpeed() { return gaitSpeed("walk") || (2 * V_STRIDE) / V_CYCLE; }
function trotSpeed() { return gaitSpeed("trot") || walkSpeed() * 1.8; }
function runSpeed() { return gaitSpeed("run") || walkSpeed() * 3.5; }

// Load the goat and index its clips. Must run after `rl.initWindow`, since
// raylib uploads the model's textures through the GL context.
function loadGoat() {
    model = rl.loadModel(MODEL_PATH);
    // `rl.loadModel` returns -1 when nothing loaded. (It deliberately does not
    // gate on raylib's own `IsModelValid`, which rejects skinned models in this
    // CPU-skinning build because their bone VBOs are never uploaded.)
    if (model < 0) {
        console.log("goat: no model at " + MODEL_PATH + " - using the cube fallback");
        haveModel = false;
        return;
    }
    haveModel = true;

    const bounds = rl.modelBounds(model);
    groundOffset = -bounds.minY;

    const count = rl.modelAnimationCount(model);
    const names = [];
    for (let i = 0; i < count; i++) {
        const name = rl.modelAnimationName(model, i);
        names.push(name);
        console.log("goat: clip " + i + " is '" + name + "' (" +
            rl.modelAnimationFrameCount(model, i) + " frames, " +
            rl.modelAnimationDuration(model, i).toFixed(3) + "s)");
    }
    // Match by substring so the clips survive a rename (GoatRun -> Run, ...).
    const idle = findClip(names, "idle");
    const jump = findClip(names, "jump");
    const run = findClip(names, "run");
    const trot = findClip(names, "trot");
    const walk = findClip(names, "walk");
    const sleep = findClip(names, "sleep");
    const death = findClip(names, "death");
    CLIP.idle = idle >= 0 ? clipInfo(idle) : null;
    CLIP.jump = jump >= 0 ? clipInfo(jump) : null;
    CLIP.run = run >= 0 ? clipInfo(run) : null;
    CLIP.trot = trot >= 0 ? clipInfo(trot) : null;
    CLIP.walk = walk >= 0 ? clipInfo(walk) : null;
    CLIP.sleep = sleep >= 0 ? clipInfo(sleep) : null;
    CLIP.death = death >= 0 ? clipInfo(death) : null;

    console.log("goat: model handle " + model + ", live=" + rl.isModelValid(model) +
        ", bones=" + rl.modelBoneCount(model) + ", walk " + walkSpeed().toFixed(2) +
        ", trot " + trotSpeed().toFixed(2) + ", run " + runSpeed().toFixed(2) + " m/s");
    console.log("goat: model loaded, y " + bounds.minY.toFixed(3) + ".." + bounds.maxY.toFixed(3));
}

// Pose a clip at `phase` in [0,1] across its keyframes.
function poseModel(role, phase) {
    const info = CLIP[role];
    if (info === null || info.frames < 1) return false;
    const last = info.frames - 1;
    let frame = phase * last;
    if (frame > last) frame = last;
    rl.updateModelAnimation(model, info.index, frame);
    return true;
}

// Draw the model: position, yaw about +Y (degrees), uniform scale, no tint.
function drawModelGoat(g) {
    const yawDeg = (g.yaw * 180) / Math.PI;
    rl.drawModelEx(model, g.px, g.py + groundOffset, g.pz,
        0, 1, 0, yawDeg, MODEL_SCALE, MODEL_SCALE, MODEL_SCALE, ambTint);
}

// ---- the cube fallback ---------------------------------------------------

// Fill a box with a grid of cubes, then yaw it with the goat. Filling (rather
// than one big cube) is what lets body parts rotate despite `drawCube` being
// axis-aligned.
function drawBox(g, center, size, color, cell) {
    const nx = Math.max(1, Math.round(size.x / cell));
    const ny = Math.max(1, Math.round(size.y / cell));
    const nz = Math.max(1, Math.round(size.z / cell));
    const sx = size.x / nx;
    const sy = size.y / ny;
    const sz = size.z / nz;
    for (let i = 0; i < nx; i++) {
        for (let j = 0; j < ny; j++) {
            for (let k = 0; k < nz; k++) {
                const p = {
                    x: center.x - size.x / 2 + sx * (i + 0.5),
                    y: center.y - size.y / 2 + sy * (j + 0.5),
                    z: center.z - size.z / 2 + sz * (k + 0.5),
                };
                const w = toWorld(p, g);
                rl.drawCube(w.x, w.y, w.z, sx * 1.02, sy * 1.02, sz * 1.02, color);
            }
        }
    }
}

// Draw a limb as `n` cubes sampled along the bone, so it can point any way.
function drawSeg(g, from, ang, len, thick, color, n) {
    for (let i = 0; i < n; i++) {
        const t = (i + 0.5) / n;
        const local = segEnd(from, ang, len * t);
        const w = toWorld(local, g);
        rl.drawCube(w.x, w.y, w.z, thick, thick, thick, color);
    }
}

// 2-bone IK: place the foot at (dx, dy) relative to the hip, returning the
// upper- and lower-bone angles. The knee sits behind the hip->foot line.
function legAngles(dx, dy) {
    let d = Math.sqrt(dx * dx + dy * dy);
    d = clamp(d, Math.abs(V_L1 - V_L2) + 1e-4, (V_L1 + V_L2) * 0.999);
    const phi = Math.atan2(dx, -dy);
    const c1 = clamp((V_L1 * V_L1 + d * d - V_L2 * V_L2) / (2 * V_L1 * d), -1, 1);
    const c2 = clamp((V_L2 * V_L2 + d * d - V_L1 * V_L1) / (2 * V_L2 * d), -1, 1);
    const a1 = Math.acos(c1);
    const b = Math.acos(c2);
    return { upper: phi - a1, lower: phi + b };
}

// Where a hoof wants to be at cycle time `t`: planted and sliding back through
// stance (half the cycle), then lifted and reaching forward through swing.
function footTarget(t, phase) {
    const tt = mod1(t + phase);
    if (tt < 0.5) {
        const s = tt / 0.5;
        return { dx: V_STRIDE * (1 - 2 * s), worldY: V_GROUND };
    }
    const s = (tt - 0.5) / 0.5;
    return { dx: V_STRIDE * (-1 + 2 * s), worldY: V_GROUND + V_LIFT * Math.sin(Math.PI * s) };
}

function drawLeg(g, leg) {
    const f = footTarget(g.phase, leg.phase);
    const dy = (f.worldY - g.py) - V_HIP_Y; // foot height relative to the hip
    const ang = legAngles(f.dx, dy);

    const hip = { x: leg.hx, y: V_HIP_Y, z: leg.hz };
    drawSeg(g, hip, ang.upper, V_L1, 0.11, ambFur, 3);
    const knee = segEnd(hip, ang.upper, V_L1);
    drawSeg(g, knee, ang.lower, V_L2, 0.09, ambFur, 3);
    const foot = segEnd(knee, ang.lower, V_L2);
    const w = toWorld(foot, g);
    rl.drawCube(w.x, w.y, w.z, 0.12, 0.10, 0.12, ambHoof);
}

function drawGoat(g) {
    // barrel of the body
    drawBox(g, { x: 0.0, y: 0.78, z: 0.0 }, { x: 1.20, y: 0.62, z: 0.56 }, ambFur, 0.30);
    // neck (shoulder -> head base) and tail
    drawSeg(g, { x: 0.40, y: 0.92, z: 0.0 }, Math.atan2(0.32, -0.20), 0.377, 0.22, ambFur, 3);
    drawSeg(g, { x: -0.58, y: 0.90, z: 0.0 }, Math.atan2(-0.10, -0.12), 0.156, 0.09, ambFurDk, 2);
    // head, muzzle, beard
    drawBox(g, { x: 0.86, y: 1.16, z: 0.0 }, { x: 0.34, y: 0.28, z: 0.28 }, ambFur, 0.14);
    drawBox(g, { x: 1.02, y: 1.10, z: 0.0 }, { x: 0.20, y: 0.16, z: 0.18 }, ambDark, 0.10);
    drawBox(g, { x: 0.98, y: 0.98, z: 0.0 }, { x: 0.08, y: 0.10, z: 0.08 }, ambDark, 0.08);
    // ears, horns, eyes
    for (let s = -1; s <= 1; s += 2) {
        drawBox(g, { x: 0.80, y: 1.26, z: 0.16 * s }, { x: 0.10, y: 0.07, z: 0.18 }, ambDark, 0.09);
        drawSeg(g, { x: 0.80, y: 1.28, z: 0.07 * s }, Math.atan2(-0.14, -0.14), 0.198, 0.07, ambHorn, 2);
        drawBox(g, { x: 0.90, y: 1.19, z: 0.14 * s }, { x: 0.06, y: 0.05, z: 0.05 }, ambEye, 0.05);
    }
    // legs
    for (let i = 0; i < LEGS.length; i++) {
        drawLeg(g, LEGS[i]);
    }
}

// ---- scenery -------------------------------------------------------------

// Static, deterministically jittered grass, thinned out so it reads as tufts.
const TUFTS = [];
(function buildTufts() {
    for (let gx = -40; gx <= 40; gx += 2) {
        for (let gz = -40; gz <= 40; gz += 2) {
            const a = hash(gx * 3.1 + gz * 7.7);
            if (a < 0.45) continue;
            const b = hash(gx * 11.3 - gz * 5.1);
            TUFTS.push({ x: gx + (b - 0.5) * 1.8, z: gz + (a - 0.5) * 1.8 });
        }
    }
    console.log("goat: " + TUFTS.length + " grass tufts");
})();

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
let skyTop = 0;             // packed sky colours, refreshed each frame
let skyBot = 0;
let ambR = 1.0, ambG = 1.0, ambB = 1.0;
let ambTint = 0xFFFFFFFF;
let ambFur, ambFurDk, ambDark, ambHorn, ambHoof, ambEye, ambGround, ambTuft, ambShadow;
let clockText = "";

// Fixed star field on a big sphere; drawn relative to the goat so it reads as
// infinitely far away.
const STARS = [];
(function buildStars() {
    for (let i = 0; i < 320; i++) {
        const a = hash(i * 12.9898) * Math.PI * 2;
        const e = 0.05 + hash(i * 78.233) * 1.35;
        const r = Math.cos(e) * 90;
        STARS.push({ x: Math.cos(a) * r, y: Math.sin(e) * 90, z: Math.sin(a) * r });
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
    ambR = 0.40 + 0.60 * t;
    ambG = 0.44 + 0.56 * t;
    ambB = 0.62 + 0.38 * t;
    ambTint = rl.color(Math.round(255 * ambR), Math.round(255 * ambG), Math.round(255 * ambB), 255);
    ambFur = scaleColor(FUR, ambR, ambG, ambB);
    ambFurDk = scaleColor(FUR_DK, ambR, ambG, ambB);
    ambDark = scaleColor(DARK, ambR, ambG, ambB);
    ambHorn = scaleColor(HORN, ambR, ambG, ambB);
    ambHoof = scaleColor(HOOF, ambR, ambG, ambB);
    ambEye = scaleColor(EYE, ambR, ambG, ambB);
    ambGround = scaleColor(GROUND, ambR, ambG, ambB);
    ambTuft = scaleColor(TUFT, ambR, ambG, ambB);
    const dark = 1 - 0.5 * t;
    ambShadow = scaleColor(GROUND, ambR * dark, ambG * dark, ambB * dark);
}

function drawStars() {
    const fade = (0.35 - skyLight) / 0.35;
    if (fade <= 0) return;
    const shade = Math.round(200 * fade + 40);
    const blue = Math.min(255, shade + 25);
    for (let i = 0; i < STARS.length; i++) {
        rl.drawPoint3D(goat.px + STARS[i].x, STARS[i].y, goat.pz + STARS[i].z,
            rl.color(shade, shade, blue, 255));
    }
}

// Sun and moon on opposite sides of a celestial sphere, arcing east to west
// between 06:00 and 18:00.
function drawCelestial() {
    const a = ((worldTime - 6) / 12) * Math.PI;   // 0 at 06:00, PI at 18:00
    const dx = Math.cos(a);
    const dy = Math.sin(a);
    const R = 70;
    if (dy > -0.25) {
        const warm = 0.55 + 0.45 * Math.max(0, dy);
        rl.drawSphere(goat.px + dx * R, dy * R, goat.pz, 2.4,
            rl.color(255, Math.round(220 * warm + 35), Math.round(150 * warm + 80), 255));
    }
    if (dy < 0.25) {
        rl.drawSphere(goat.px - dx * R, -dy * R, goat.pz, 1.8, rl.color(214, 220, 238, 255));
    }
}

// Cheap contact shadow: a flattened dark rectangle under the goat, darker and
// longer-lived the higher the sun. Real cast shadows need shaders (M4).
function drawShadow() {
    if (skyLight <= 0.05) return;
    rl.drawCube(goat.px, 0.02, goat.pz, 1.25, 0.012, 1.7, ambShadow);
}

function drawGround(g) {
    // Snap the slab to a 2-unit grid so it looks pinned down while we travel.
    const gx = Math.round(g.px / 2) * 2;
    const gz = Math.round(g.pz / 2) * 2;
    rl.drawCube(gx, -0.06, gz, 70, 0.1, 70, ambGround);
    rl.drawGrid(40, 1.0);
    for (let i = 0; i < TUFTS.length; i++) {
        const tx = TUFTS[i].x - g.px;
        const tz = TUFTS[i].z - g.pz;
        if (tx * tx + tz * tz > 576) continue; // cull beyond 24 units
        rl.drawCube(TUFTS[i].x, 0.06, TUFTS[i].z, 0.14, 0.16, 0.14, ambTuft);
    }
}

// ---- gait state ----------------------------------------------------------

const goat = { px: 0, pz: 0, py: V_DROP, yaw: 0, phase: 0 };
let paused = false;
let mode = "idle";       // idle | walk | trot | run | jump | sleep | dead
let jumpTime = 0;        // seconds into the current jump
let jumpSpeed = 0;       // ground speed frozen at take-off
let jumpDir = 0;         // travel direction (-1/0/1) frozen at take-off
let sleepTime = 0;       // seconds slept since last awake
let deathTime = 0;       // seconds since the death started
let idleTimer = 0;       // seconds spent idle while exhausted
const stats = { health: MAX_STAT, energy: MAX_STAT };
let exhausted = false;
let xTex = -1;           // X-eye sprite texture (made after the window opens)
let lidTex = -1;         // closed-eye sprite texture
let camYaw = 0.7;
let camPitch = 0.42;
let camDist = 5.2;

// Live gait read-outs, refreshed once per frame at `run()` depth. `drawHud`
// reads these rather than calling the helpers itself: in a debug build every
// extra JS activation costs ~160 KB of native stack, and the guard trips if the
// HUD's own frame nests a few more calls.
let curRole = "walk";
let curSpeed = 0;
let curClipName = "";

// Which clip role is driving the pose right now, falling back to the walk for
// any role the model does not provide.
function clipRole() {
    if (mode === "dead" && CLIP.death) return "death";
    if (mode === "sleep" && CLIP.sleep) return "sleep";
    if (mode === "jump" && CLIP.jump) return "jump";
    if (mode === "run" && CLIP.run) return "run";
    if (mode === "trot" && CLIP.trot) return "trot";
    if (mode === "idle" && CLIP.idle) return "idle";
    return "walk";
}

function jumpDuration() {
    return CLIP.jump ? CLIP.jump.duration : FALLBACK_JUMP_TIME;
}

// Seconds of an idle/walk/run loop (one full cycle), for phase advance.
function loopDuration() {
    const role = clipRole();
    if (haveModel && CLIP[role]) return CLIP[role].duration;
    return V_CYCLE;
}

// Ground speed for the current gait, from the stride/duty above.
function groundSpeed() {
    if (mode === "sleep" || mode === "dead") return 0;
    if (!haveModel) {
        let mult = 1;
        if (mode === "run") mult = FALLBACK_RUN_MULT;
        else if (mode === "trot") mult = FALLBACK_TROT_MULT;
        return ((2 * V_STRIDE) / V_CYCLE) * mult;
    }
    if (mode === "run" && CLIP.run) return runSpeed();
    if (mode === "trot" && CLIP.trot) return trotSpeed();
    return walkSpeed();
}

function startJump(move, gait) {
    mode = "jump";
    jumpTime = 0;
    jumpDir = move;
    if (!haveModel) {
        let mult = 1;
        if (gait === "run") mult = FALLBACK_RUN_MULT;
        else if (gait === "trot") mult = FALLBACK_TROT_MULT;
        jumpSpeed = ((2 * V_STRIDE) / V_CYCLE) * mult;
    } else if (gait === "run" && CLIP.run) {
        jumpSpeed = runSpeed();
    } else if (gait === "trot" && CLIP.trot) {
        jumpSpeed = trotSpeed();
    } else {
        jumpSpeed = walkSpeed();
    }
    stats.energy = Math.max(0, stats.energy - JUMP_ENERGY_COST);
}

function startSleep() {
    mode = "sleep";
    sleepTime = 0;
    idleTimer = 0;
}

function wakeUp() {
    mode = "idle";
    sleepTime = 0;
}

function die() {
    mode = "dead";
    deathTime = 0;
}

function restart() {
    stats.health = MAX_STAT;
    stats.energy = MAX_STAT;
    exhausted = false;
    idleTimer = 0;
    sleepTime = 0;
    deathTime = 0;
    goat.px = 0;
    goat.pz = 0;
    goat.yaw = 0;
    goat.phase = 0;
    mode = "idle";
}

// Advance health/energy for the current mode, once per frame. Returns "die"
// when health runs out so the caller can switch to the dead state.
function updateStats(dt) {
    if (mode === "dead") {
        deathTime += dt;
        return "dead";
    }
    if (mode === "sleep") {
        sleepTime += dt;
        stats.energy = Math.min(MAX_STAT, stats.energy + SLEEP_ENERGY_RECOVER * dt);
        stats.health = Math.min(MAX_STAT, stats.health + SLEEP_HEALTH_RECOVER * dt);
        return "sleep";
    }
    let drain = ENERGY_DRAIN.idle;
    if (mode === "run") drain = ENERGY_DRAIN.run;
    else if (mode === "trot") drain = ENERGY_DRAIN.trot;
    else if (mode === "walk") drain = ENERGY_DRAIN.walk;
    if (skyLight < 0.25) drain *= NIGHT_DRAIN_MULT;   // cold nights burn energy faster
    stats.energy = Math.max(0, stats.energy - drain * dt);
    if (stats.energy <= 0) {
        exhausted = true;
        stats.health = Math.max(0, stats.health - EXHAUST_HEALTH_DRAIN * dt);
    } else {
        exhausted = false;
        if (mode === "idle" && stats.energy > RESTED_ENERGY) {
            stats.health = Math.min(MAX_STAT, stats.health + IDLE_HEALTH_RECOVER * dt);
        }
    }
    return stats.health <= 0 ? "die" : "awake";
}

// Build the eye sprites: a black X for the dead state and a closed-lid bar for
// sleeping, both on a transparent field. Needs a live GL context.
function makeEyeTextures() {
    let x = "";
    let lid = "";
    for (let y = 0; y < 8; y++) {
        for (let px = 0; px < 8; px++) {
            x += (Math.abs(px - y) <= 1 || Math.abs(px - (7 - y)) <= 1) ? "232323FF" : "00000000";
            lid += (y === 3 || y === 4) ? "232323FF" : "00000000";
        }
    }
    xTex = rl.makeTexture(8, 8, x);
    lidTex = rl.makeTexture(8, 8, lid);
}

// Billboard the closed-eye / X-eye sprites onto the goat's eyes. Kept flat (no
// helper calls) because `run()` -> `drawEyes` already sits near the debug
// build's stack budget.
function drawEyes() {
    let eyes = null;
    let tex = -1;
    let size = 0.12;
    if (mode === "sleep" && lidTex >= 0) {
        eyes = SLEEP_EYES;
        tex = lidTex;
        size = 0.11;
    } else if (mode === "dead" && xTex >= 0 && CLIP.death &&
        deathTime >= CLIP.death.duration * DEAD_EYE_FRACTION) {
        eyes = DEATH_EYES;
        tex = xTex;
        size = 0.13;
    }
    if (eyes === null) return;
    const c = Math.cos(goat.yaw);
    const s = Math.sin(goat.yaw);
    const py = goat.py + groundOffset;
    for (let i = 0; i < eyes.length; i++) {
        const wx = goat.px + eyes[i].x * c + eyes[i].z * s;
        const wz = goat.pz - eyes[i].x * s + eyes[i].z * c;
        rl.drawBillboard(tex, wx, py + eyes[i].y, wz, size, rl.WHITE);
    }
}

// ---- main ----------------------------------------------------------------

function drawHud(move) {
    const h = rl.getScreenHeight();
    let state = "standing";
    if (mode === "dead") state = "dead - R to restart";
    else if (paused) state = "paused (P to resume)";
    else if (mode === "sleep") state = "sleeping (Z to wake)";
    else if (mode === "jump") state = "jumping";
    else if (move > 0 && mode === "run") state = "running";
    else if (move > 0 && mode === "trot") state = "trotting";
    else if (move > 0) state = "walking forward";
    else if (move < 0) state = "walking backward";

    let how = "cube fallback - 4-beat walk with 2-bone IK";
    if (haveModel) {
        how = curClipName !== "" ? "clip '" + curClipName + "'" : "glb model";
    }
    const status = clockText + "   speed " + curSpeed.toFixed(2) + " m/s   phase " +
        goat.phase.toFixed(2) + "   fps " + rl.getFPS();
    rl.drawText("Slag goat  -  " + how, 10, 8, 18, rl.RAYWHITE);
    rl.drawText("W/S walk   CTRL trot   SHIFT run   SPACE jump   Z sleep   T time   A/D turn   drag: orbit   wheel: zoom   P: pause   ESC: quit",
        10, 32, 14, rl.RAYWHITE);

    // Health and energy bars, top-right.
    const bw = 160;
    const bx = rl.getScreenWidth() - bw - 12;
    rl.drawRectangle(bx, 10, bw, 14, rl.color(28, 28, 34, 220));
    rl.drawRectangle(bx + 1, 11, Math.round((bw - 2) * stats.health / MAX_STAT), 12,
        rl.color(208, 62, 62, 255));
    rl.drawRectangle(bx, 30, bw, 14, rl.color(28, 28, 34, 220));
    rl.drawRectangle(bx + 1, 31, Math.round((bw - 2) * stats.energy / MAX_STAT), 12,
        rl.color(222, 190, 62, 255));
    rl.drawText("health " + Math.round(stats.health) + "   energy " + Math.round(stats.energy),
        bx, 50, 14, rl.RAYWHITE);
    if (mode === "sleep") rl.drawText("Z z z", bx, 70, 20, rl.RAYWHITE);

    rl.drawText(status + "   " + state, 10, h - 24, 14, rl.RAYWHITE);
}

function run() {
    rl.initWindow(1000, 640, "Slag goat - walk / run / jump / sleep");
    rl.setTargetFPS(60);
    loadGoat();
    makeEyeTextures();

    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    let frames = 0;
    while (!rl.windowShouldClose()) {
        const dt = Math.min(rl.getFrameTime(), 0.05);
        frames += 1;

        // day/night: advance the clock, then refresh the sky and the ambient
        // tint the whole scene is drawn with.
        const fast = rl.isKeyDown(rl.KEY_T);
        worldTime = mod24(worldTime + (dt / DAY_LENGTH) * 24 * (fast ? TIME_FAST : 1));
        const sky = skySample(worldTime);
        skyTop = sky.top;
        skyBot = sky.bot;
        skyLight = sky.light;
        updateAmbient();
        const hh = Math.floor(worldTime);
        const mm = Math.floor((worldTime - hh) * 60);
        clockText = (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm;

        // camera: drag to orbit, arrows as a fallback, wheel to zoom
        if (rl.isMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            camYaw -= rl.getMouseDeltaX() * 0.004;
            camPitch -= rl.getMouseDeltaY() * 0.004;
        }
        if (rl.isKeyDown(rl.KEY_LEFT)) camYaw += 1.6 * dt;
        if (rl.isKeyDown(rl.KEY_RIGHT)) camYaw -= 1.6 * dt;
        if (rl.isKeyDown(rl.KEY_UP)) camPitch += 1.0 * dt;
        if (rl.isKeyDown(rl.KEY_DOWN)) camPitch -= 1.0 * dt;
        camDist -= rl.getMouseWheelMove() * 0.4;
        camPitch = clamp(camPitch, 0.08, 1.35);
        camDist = clamp(camDist, 2.2, 12.0);

        // input
        if (rl.isKeyPressed(rl.KEY_P)) paused = !paused;
        let move = 0;
        if (rl.isKeyDown(rl.KEY_W)) move += 1;
        if (rl.isKeyDown(rl.KEY_S)) move -= 1;
        let turn = 0;
        if (rl.isKeyDown(rl.KEY_A)) turn += 1;
        if (rl.isKeyDown(rl.KEY_D)) turn -= 1;
        const running = rl.isKeyDown(rl.KEY_LEFT_SHIFT) || rl.isKeyDown(rl.KEY_RIGHT_SHIFT);
        const trotting = rl.isKeyDown(rl.KEY_LEFT_CONTROL) || rl.isKeyDown(rl.KEY_RIGHT_CONTROL);
        let gait = running ? "run" : trotting ? "trot" : "walk";
        if (exhausted) gait = "walk";   // an exhausted goat cannot run or trot
        if (mode !== "sleep" && mode !== "dead") goat.yaw += turn * TURN_RATE * dt;

        // state machine: jump, sleep and death lock the mode; everything else
        // follows the requested gait.
        if (mode === "dead") {
            if (rl.isKeyPressed(rl.KEY_R)) restart();
        } else if (mode === "sleep") {
            if (rl.isKeyPressed(rl.KEY_Z) || move !== 0 || stats.energy >= MAX_STAT) {
                wakeUp();
            }
        } else if (mode === "jump") {
            jumpTime += dt;
            if (jumpTime >= jumpDuration()) {
                mode = move !== 0 ? gait : "idle";
            }
        } else if (rl.isKeyPressed(rl.KEY_Z)) {
            startSleep();
        } else if (rl.isKeyPressed(rl.KEY_SPACE)) {
            startJump(move, gait);
        } else {
            mode = move !== 0 ? gait : "idle";
            // drop off on our own once exhausted and standing still
            if (exhausted && move === 0) {
                idleTimer += dt;
                if (idleTimer >= AUTO_SLEEP_DELAY) startSleep();
            } else {
                idleTimer = 0;
            }
        }

        if (updateStats(dt) === "die") die();

        curRole = clipRole();
        curSpeed = groundSpeed();

        if (!paused) {
            if (mode === "jump") {
                // Horizontal travel continues at the speed set at take-off; the
                // vertical arc comes from the clip (or the fallback hop).
                if (jumpDir !== 0) {
                    goat.px += Math.cos(goat.yaw) * jumpDir * jumpSpeed * dt;
                    goat.pz += -Math.sin(goat.yaw) * jumpDir * jumpSpeed * dt;
                }
                if (!haveModel) {
                    goat.py = V_DROP + FALLBACK_JUMP_H *
                        Math.sin(Math.PI * Math.min(jumpTime / jumpDuration(), 1));
                }
            } else if (mode === "sleep") {
                goat.phase = mod1(goat.phase + dt / loopDuration());
                goat.py = haveModel ? 0 : V_DROP;
            } else if (mode === "dead") {
                goat.py = haveModel ? 0 : V_DROP;
            } else {
                goat.phase = mod1(goat.phase + dt / loopDuration());
                const speed = groundSpeed();
                if (move !== 0) {
                    goat.px += Math.cos(goat.yaw) * move * speed * dt;
                    goat.pz += -Math.sin(goat.yaw) * move * speed * dt;
                }
                // The model's clip bobs the body itself; only the fallback needs a bob.
                goat.py = haveModel ? 0 : V_DROP + Math.sin(4 * Math.PI * goat.phase) * V_BOB;
            }
        }

        if (haveModel) {
            if (mode === "jump" && CLIP.jump) {
                poseModel("jump", Math.min(jumpTime / CLIP.jump.duration, 1));
            } else if (mode === "dead" && CLIP.death) {
                poseModel("death", Math.min(deathTime / CLIP.death.duration, 1));
            } else {
                poseModel(curRole, goat.phase);
            }
            const info = CLIP[curRole];
            curClipName = info !== null ? rl.modelAnimationName(model, info.index) : "";
        }

        // render
        const ty = 0.85 + goat.py;
        const cp = Math.cos(camPitch);
        const cx = goat.px + camDist * cp * Math.sin(camYaw);
        const cy = ty + camDist * Math.sin(camPitch);
        const cz = goat.pz + camDist * cp * Math.cos(camYaw);

        rl.beginDrawing();
        rl.clearBackground(skyBot);
        rl.drawRectangleGradientV(0, 0, sw, sh, skyTop, skyBot);
        rl.beginMode3D(cx, cy, cz, goat.px, ty, goat.pz, 55);
        drawStars();
        drawCelestial();
        drawGround(goat);
        drawShadow();
        if (haveModel) {
            drawModelGoat(goat);
            drawEyes();
        } else {
            drawGoat(goat);
        }
        rl.endMode3D();
        drawHud(move);
        rl.endDrawing();

        if (frames % 240 === 0) {
            console.log("frame " + frames + " mode " + mode + " phase " + goat.phase.toFixed(2) +
                " fps " + rl.getFPS());
        }
    }

    console.log("window closed after " + frames + " frames");
    if (haveModel) {
        rl.unloadModel(model);
    }
    rl.closeWindow();
}

run();

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
// Weather runs on a small state machine (clear -> cloudy -> rain -> clearing)
// with eased cloudiness and rain intensity. Wind gusts drive drifting cloud
// billboards, the screen-space rain angle and the grass sway; C jumps to the
// next weather state. Cloud and puff sprites are procedural. (Weather audio
// and shader clouds are still to come.)
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
//   C             next weather state
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

// Draw the model: position, yaw about +Y (degrees), uniform scale, given tint.
function drawModelGoat(g, tint) {
    const yawDeg = (g.yaw * 180) / Math.PI;
    rl.drawModelEx(model, g.px, g.py + groundOffset, g.pz,
        0, 1, 0, yawDeg, MODEL_SCALE, MODEL_SCALE, MODEL_SCALE, tint);
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
            TUFTS.push({ x: gx + (b - 0.5) * 1.8, z: gz + (a - 0.5) * 1.8, p: hash(gx * 5.7 + gz * 2.3) * 6.28 });
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
    ambGround = scaleColor(GROUND, ambR, ambG, ambB);
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
    rl.drawCube(goat.px, 0.02, goat.pz, 1.25, 0.012, 1.7, ambShadow);
}

// ---- lighting (M4): directional light and projected cast shadows ---------
//
// raylib's default shader is unlit, so the scene is lit by a small custom
// program. The goat is a CPU-skinned model: raylib deforms its positions *and*
// normals on the CPU and uploads them, so a normal shader lit per-fragment works
// without the bone matrices a GPU-skinning build would need. `DrawMesh` binds
// the material shader and ignores `beginShaderMode`, so `setModelShader` points
// the goat's materials at the lit program; the terrain (immediate-mode cubes)
// goes through `beginShaderMode`.
//
// Shadows are a planar projection rather than a shadow map: the goat is drawn a
// second time with a vertex shader that squashes every vertex onto the ground
// along the light direction, filled with a translucent dark colour. On the flat
// terrain this reads as a cast shadow that tracks the sun, with none of the
// bias/acne tuning a depth map needs. A depth-map pass (soft edges, self-shadowing)
// can replace it once the render-texture bindings are wired up.

const GROUND_Y = 0.02;          // the plane the shadow is projected onto
const SHADOW_ALPHA = 0.34;      // base opacity of the cast shadow

const LIGHT_DIR = [0.4, 0.8, 0.12];   // unit vector pointing at the active body
const LIGHT_COLOR = [0.9, 0.9, 0.9];  // rgb, already scaled by intensity
const LIGHT_AMBIENT = [0.2, 0.22, 0.3];

let litShader = -1;
let shadowShader = -1;
let litUniforms = null;
let shadowUniforms = null;
let useLighting = true;         // toggled with L
let lightingText = "cube shader";

const LIT_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "in vec2 vertexTexCoord;",
    "in vec3 vertexNormal;",
    "in vec4 vertexColor;",
    "uniform mat4 mvp;",
    "uniform mat4 matModel;",
    "uniform mat4 matNormal;",
    "out vec2 fragTexCoord;",
    "out vec4 fragColor;",
    "out vec3 fragWorldPos;",
    "out vec3 fragNormal;",
    "void main() {",
    "    vec4 world = matModel * vec4(vertexPosition, 1.0);",
    "    fragWorldPos = world.xyz;",
    "    fragNormal = normalize(mat3(matNormal) * vertexNormal);",
    "    fragTexCoord = vertexTexCoord;",
    "    fragColor = vertexColor;",
    "    gl_Position = mvp * vec4(vertexPosition, 1.0);",
    "}",
].join("\n");

const LIT_FS = [
    "#version 330",
    "in vec2 fragTexCoord;",
    "in vec4 fragColor;",
    "in vec3 fragWorldPos;",
    "in vec3 fragNormal;",
    "uniform sampler2D texture0;",
    "uniform sampler2D texture1;",
    "uniform vec4 colDiffuse;",
    "uniform vec3 lightDir;",
    "uniform vec4 lightColor;",
    "uniform vec4 ambientColor;",
    "uniform vec3 camPos;",
    "uniform mat4 lightVP;",
    "uniform vec2 shadowTexel;",
    "uniform float shadowBias;",
    "uniform float shadowStrength;",
    "out vec4 finalColor;",
    // Depth is packed across RGB so 8-bit channels give ~24-bit precision.
    "float unpackDepth(vec3 c) { return dot(c, vec3(1.0, 1.0/255.0, 1.0/65025.0)); }",
    "void main() {",
    "    vec4 texel = texture(texture0, fragTexCoord) * colDiffuse * fragColor;",
    "    vec3 n = normalize(fragNormal);",
    "    vec3 viewDir = normalize(camPos - fragWorldPos);",
    "    if (dot(n, viewDir) < 0.0) n = -n;",
    "    vec3 l = normalize(lightDir);",
    "    float ndl = max(dot(n, l), 0.0);",
    "    float hemi = 0.5 + 0.5 * n.y;",
    "    vec3 ambient = ambientColor.rgb * mix(0.55, 1.05, hemi);",
    "    float shadow = 1.0;",
    "    if (shadowStrength > 0.001) {",
    "        vec4 lclip = lightVP * vec4(fragWorldPos, 1.0);",
    "        vec3 ndc = lclip.xyz / lclip.w;",
    "        vec2 uv = ndc.xy * 0.5 + 0.5;",
    "        float ref = ndc.z * 0.5 + 0.5;",
    "        if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0 && ref < 1.0) {",
    "            float sum = 0.0;",
    "            for (int y = -1; y <= 1; y++) {",
    "                for (int x = -1; x <= 1; x++) {",
    "                    vec3 e = texture(texture1, uv + vec2(float(x), float(y))*shadowTexel).rgb;",
    "                    float d = 1.0 - unpackDepth(e);",
    "                    sum += (ref - shadowBias > d) ? 1.0 : 0.0;",
    "                }",
    "            }",
    "            shadow = 1.0 - (sum/9.0)*shadowStrength;",
    "        }",
    "    }",
    "    vec3 diffuse = lightColor.rgb * ndl * shadow;",
    "    vec3 halfV = normalize(l + viewDir);",
    "    float spec = pow(max(dot(n, halfV), 0.0), 24.0) * ndl * shadow * 0.18;",
    "    vec3 color = texel.rgb * (ambient + diffuse) + lightColor.rgb * spec;",
    "    finalColor = vec4(color, texel.a);",
    "}",
].join("\n");

const SHADOW_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "uniform mat4 matModel;",
    "uniform mat4 matView;",
    "uniform mat4 matProjection;",
    "uniform vec3 lightDir;",
    "uniform float groundY;",
    "uniform float shadowOn;",
    "void main() {",
    "    vec3 world = (matModel * vec4(vertexPosition, 1.0)).xyz;",
    "    if (shadowOn > 0.5 && lightDir.y > 0.06 && world.y > groundY) {",
    "        float t = (world.y - groundY) / lightDir.y;",
    "        vec3 projected = vec3(world.x - lightDir.x*t, groundY, world.z - lightDir.z*t);",
    "        gl_Position = matProjection * matView * vec4(projected, 1.0);",
    "    } else {",
    "        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);",
    "    }",
    "}",
].join("\n");

const SHADOW_FS = [
    "#version 330",
    "uniform float shadowAlpha;",
    "out vec4 finalColor;",
    "void main() { finalColor = vec4(0.02, 0.04, 0.02, shadowAlpha); }",
].join("\n");

// Compile the lit and shadow programs and cache their uniform locations. Must run
// after the window exists (shaders need a GL context).
function makeLighting() {
    // Degrade gracefully on an engine without the shader bindings (the scene then
    // keeps the M2/M3 ambient-tint look).
    if (typeof rl.loadShaderFromMemory !== "function" ||
        typeof rl.setModelShader !== "function" ||
        typeof rl.setShaderValueVector3 !== "function" ||
        typeof rl.setShaderValueVector4 !== "function") {
        console.log("lighting: engine has no shader bindings - using the cube shader");
        litShader = -1;
        lightingText = "cube shader";
        return;
    }
    litShader = rl.loadShaderFromMemory(LIT_VS, LIT_FS);
    if (litShader < 0 || !rl.isShaderValid(litShader)) {
        console.log("lighting: lit shader failed to compile - falling back to the cube shader");
        litShader = -1;
        lightingText = "cube shader";
        return;
    }
    shadowShader = rl.loadShaderFromMemory(SHADOW_VS, SHADOW_FS);
    if (shadowShader < 0 || !rl.isShaderValid(shadowShader)) shadowShader = -1;
    litUniforms = {
        lightDir: rl.getShaderLocation(litShader, "lightDir"),
        lightColor: rl.getShaderLocation(litShader, "lightColor"),
        ambientColor: rl.getShaderLocation(litShader, "ambientColor"),
        camPos: rl.getShaderLocation(litShader, "camPos"),
    };
    shadowUniforms = shadowShader >= 0 ? {
        lightDir: rl.getShaderLocation(shadowShader, "lightDir"),
        groundY: rl.getShaderLocation(shadowShader, "groundY"),
        shadowOn: rl.getShaderLocation(shadowShader, "shadowOn"),
        shadowAlpha: rl.getShaderLocation(shadowShader, "shadowAlpha"),
    } : null;
    if (haveModel) rl.setModelShader(model, litShader);
    makeShadowMap();
    console.log("lighting: lit shader " + litShader + ", shadow shader " + shadowShader);
}

// Refresh the light direction and colours from the day/night clock. The sun and
// moon are the same two bodies `drawCelestial` arcs across the sky, so the light
// and the visible disc always agree.
function updateLight() {
    const a = ((worldTime - 6) / 12) * Math.PI;   // 0 at 06:00, PI at 18:00
    const sunX = Math.cos(a);
    const sunY = Math.sin(a);
    const tilt = 0.18;                            // push light off the XZ plane
    const day = sunY > 0.02;
    let lx = sunX, ly = sunY, lz = tilt;
    if (!day) {
        lx = -sunX; ly = -sunY; lz = -tilt;       // the moon takes over
    }
    const len = Math.sqrt(lx * lx + ly * ly + lz * lz) || 1;
    LIGHT_DIR[0] = lx / len;
    LIGHT_DIR[1] = ly / len;
    LIGHT_DIR[2] = lz / len;

    const warm = Math.max(0, Math.min(1, 1 - Math.abs(sunY) / 0.45));
    const intense = day ? 0.30 + 0.70 * skyLight : 0.16;
    if (day) {
        LIGHT_COLOR[0] = intense;
        LIGHT_COLOR[1] = intense * (1 - 0.22 * warm);
        LIGHT_COLOR[2] = intense * (1 - 0.55 * warm);
    } else {
        LIGHT_COLOR[0] = intense * 0.72;
        LIGHT_COLOR[1] = intense * 0.80;
        LIGHT_COLOR[2] = intense;
    }
    LIGHT_AMBIENT[0] = 0.10 + 0.12 * skyLight;
    LIGHT_AMBIENT[1] = 0.12 + 0.13 * skyLight;
    LIGHT_AMBIENT[2] = 0.18 + 0.16 * skyLight;
}

function setLitUniforms(cx, cy, cz) {
    rl.setShaderValueVector3(litShader, litUniforms.lightDir,
        LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
    rl.setShaderValueVector4(litShader, litUniforms.lightColor,
        LIGHT_COLOR[0], LIGHT_COLOR[1], LIGHT_COLOR[2], 1.0);
    rl.setShaderValueVector4(litShader, litUniforms.ambientColor,
        LIGHT_AMBIENT[0], LIGHT_AMBIENT[1], LIGHT_AMBIENT[2], 1.0);
    rl.setShaderValueVector3(litShader, litUniforms.camPos, cx, cy, cz);
    if (litShadow !== null) {
        setMatrixOn(litShader, litShadow.lightVP, LIGHT_MATRIX);
        rl.setShaderValueVector2(litShader, litShadow.texel, 1 / SHADOW_SIZE, 1 / SHADOW_SIZE);
        rl.setShaderValue(litShader, litShadow.bias, SHADOW_BIAS, rl.SHADER_UNIFORM_FLOAT);
        rl.setShaderValue(litShader, litShadow.strength, shadowStrengthNow, rl.SHADER_UNIFORM_FLOAT);
        // The terrain goes through the batch path, which never sees the model's
        // material map 1, so bind the shadow sampler explicitly for it.
        if (shadowStrengthNow > 0.001 && shadowSamplerLoc >= 0) {
            rl.setShaderValueTexture(litShader, shadowSamplerLoc, shadowColor);
        }
    }
}

function setShadowUniforms() {
    rl.setShaderValueVector3(shadowShader, shadowUniforms.lightDir,
        LIGHT_DIR[0], LIGHT_DIR[1], LIGHT_DIR[2]);
    rl.setShaderValue(shadowShader, shadowUniforms.groundY, GROUND_Y, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(shadowShader, shadowUniforms.shadowOn, 1.0, rl.SHADER_UNIFORM_FLOAT);
    rl.setShaderValue(shadowShader, shadowUniforms.shadowAlpha,
        SHADOW_ALPHA * (0.35 + 0.65 * skyLight), rl.SHADER_UNIFORM_FLOAT);
}

// ---- shadow map (M4b) ----------------------------------------------------
//
// A depth-only pass renders the goat from the light's point of view into a
// render texture; the lit shader projects each fragment into that view and
// compares depths with a 3x3 PCF kernel, so the goat self-shadows and the
// terrain takes a proper (perspective-correct) shadow. Depth is packed across
// RGB and stored as `1 - depth`, so the cleared-black background reads as "far".
//
// Getting an extra texture into a *model* draw is the awkward part: `DrawMesh`
// binds a material's map `i` to texture unit `i` and feeds `texture{i}` from it,
// while `setShaderValueTexture` picks a unit that those maps then overwrite. So
// the shadow map lives in every material's map 1 (metalness), which the lit
// shader does not otherwise use. The terrain (batch path) has no materials, so it
// is handed the sampler with `setShaderValueTexture` instead.

const SHADOW_OFF = 0;
const SHADOW_PLANAR = 1;
const SHADOW_MAP = 2;

const SHADOW_SIZE = 1024;
const SHADOW_HALF = 7.0;      // half-width of the light's box, in world units
const SHADOW_DIST = 22.0;     // how far the light sits from its centre
const SHADOW_NEAR = 1.0;
const SHADOW_FAR = 48.0;
const SHADOW_BIAS = 0.0018;
const SHADOW_STRENGTH = 0.85; // how dark a fully-shadowed sample gets
const SHADOW_MAP_INDEX = 1;   // MATERIAL_MAP_METALNESS -> sampler `texture1`

let shadowMapReady = false;
let shadowMode = SHADOW_PLANAR;
let shadowRT = -1;
let shadowColor = -1;
let depthShader = -1;
let depthUniforms = null;
let litShadow = null;         // locations of the lit shader's shadow uniforms
let shadowSamplerLoc = -1;
const LIGHT_MATRIX = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
let shadowStrengthNow = 0;

const DEPTH_VS = [
    "#version 330",
    "in vec3 vertexPosition;",
    "uniform mat4 matModel;",
    "uniform mat4 lightVP;",
    "out vec4 vClip;",
    "void main() {",
    "    vClip = lightVP * matModel * vec4(vertexPosition, 1.0);",
    "    gl_Position = vClip;",
    "}",
].join("\n");

const DEPTH_FS = [
    "#version 330",
    "in vec4 vClip;",
    "out vec4 finalColor;",
    "vec3 packDepth(float d) {",
    "    vec3 enc = fract(vec3(1.0, 255.0, 65025.0)*d);",
    "    enc -= enc.yzz*vec3(1.0/255.0, 1.0/255.0, 0.0);",
    "    return enc;",
    "}",
    "void main() {",
    "    float depth = vClip.z/vClip.w*0.5 + 0.5;",
    "    finalColor = vec4(packDepth(clamp(1.0 - depth, 0.0, 0.999)), 1.0);",
    "}",
].join("\n");

function cross3(a, b) {
    return [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]];
}
function dot3(a, b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}
function unit3(v) {
    const l = Math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]) || 1;
    return [v[0]/l, v[1]/l, v[2]/l];
}

// Orthographic world -> light-clip matrix: x/y span a SHADOW_HALF box around
// (cx, cy, cz), z runs SHADOW_NEAR..SHADOW_FAR along the light direction, with
// the light at distance SHADOW_DIST. Row-major, the order `setShaderValueMatrix`
// takes.
function buildLightMatrix(cx, cy, cz) {
    const L = unit3(LIGHT_DIR);
    const up = Math.abs(L[1]) > 0.95 ? [0, 0, 1] : [0, 1, 0];
    const R = unit3(cross3(up, L));
    const U = cross3(L, R);
    const k = 2 / (SHADOW_FAR - SHADOW_NEAR);
    const dL = dot3([cx, cy, cz], L);
    const dR = dot3([cx, cy, cz], R);
    const dU = dot3([cx, cy, cz], U);
    const t2 = k*(SHADOW_DIST + dL) - k*SHADOW_NEAR - 1;
    return [
        R[0]/SHADOW_HALF, R[1]/SHADOW_HALF, R[2]/SHADOW_HALF, 0,
        U[0]/SHADOW_HALF, U[1]/SHADOW_HALF, U[2]/SHADOW_HALF, 0,
        -k*L[0], -k*L[1], -k*L[2], 0,
        -dR/SHADOW_HALF, -dU/SHADOW_HALF, t2, 1,
    ];
}

function setMatrixOn(shader, loc, m) {
    rl.setShaderValueMatrix(shader, loc,
        m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7],
        m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]);
}

// Build the render texture and depth program. Needs the window (GL) and the lit
// shader already compiled.
function makeShadowMap() {
    if (typeof rl.loadRenderTexture !== "function" || typeof rl.setModelTexture !== "function" ||
        typeof rl.setShaderValueMatrix !== "function" || typeof rl.setShaderValueTexture !== "function") {
        console.log("shadow map: engine lacks the bindings - keeping the planar shadow");
        return;
    }
    shadowSamplerLoc = rl.getShaderLocation(litShader, "texture1");
    litShadow = {
        lightVP: rl.getShaderLocation(litShader, "lightVP"),
        texel: rl.getShaderLocation(litShader, "shadowTexel"),
        bias: rl.getShaderLocation(litShader, "shadowBias"),
        strength: rl.getShaderLocation(litShader, "shadowStrength"),
    };
    shadowRT = rl.loadRenderTexture(SHADOW_SIZE, SHADOW_SIZE);
    if (shadowRT < 0 || !rl.isRenderTextureValid(shadowRT)) {
        shadowRT = -1;
        console.log("shadow map: no render texture - keeping the planar shadow");
        return;
    }
    shadowColor = rl.renderTextureColor(shadowRT);
    depthShader = rl.loadShaderFromMemory(DEPTH_VS, DEPTH_FS);
    if (depthShader < 0 || !rl.isShaderValid(depthShader)) {
        depthShader = -1;
        console.log("shadow map: depth shader failed to compile - keeping the planar shadow");
        return;
    }
    depthUniforms = { lightVP: rl.getShaderLocation(depthShader, "lightVP") };
    if (haveModel) rl.setModelTexture(model, SHADOW_MAP_INDEX, shadowColor);
    shadowMapReady = true;
    shadowMode = SHADOW_MAP;
    console.log("shadow map: rt " + shadowRT + " color " + shadowColor +
        " depth shader " + depthShader + " sampler loc " + shadowSamplerLoc);
}

// Refresh the light matrix and shadow strength for this frame.
function updateShadow() {
    shadowStrengthNow = 0;
    if (shadowMode !== SHADOW_MAP || !shadowMapReady) return;
    // Keep the light's box centred on the goat, snapped so it doesn't shimmer.
    const cx = Math.round(goat.px * 2) / 2;
    const cz = Math.round(goat.pz * 2) / 2;
    const m = buildLightMatrix(cx, 0.7, cz);
    for (let i = 0; i < 16; i++) LIGHT_MATRIX[i] = m[i];
    // Fade the shadow out as the light drops toward the horizon.
    const low = Math.min(1, Math.max(0, (LIGHT_DIR[1] - 0.06) / 0.25));
    shadowStrengthNow = SHADOW_STRENGTH * low * (0.35 + 0.65 * skyLight);
}

// Render the goat from the light's point of view into the shadow texture.
function renderShadowMap() {
    if (!shadowMapReady || !haveModel || shadowStrengthNow <= 0.001) return;
    rl.beginTextureMode(shadowRT);
    rl.clearBackground(rl.color(0, 0, 0, 255));
    rl.beginMode3D(0, 0, 0, goat.px, 0, goat.pz, 45);
    rl.setModelShader(model, depthShader);
    // Detach the shadow target while it is the framebuffer's own attachment.
    rl.setModelTexture(model, SHADOW_MAP_INDEX, -1);
    setMatrixOn(depthShader, depthUniforms.lightVP, LIGHT_MATRIX);
    drawModelGoat(goat, rl.WHITE);
    rl.setModelTexture(model, SHADOW_MAP_INDEX, shadowColor);
    rl.setModelShader(model, litShader);
    rl.endMode3D();
    rl.endTextureMode();
}

// ---- audio ---------------------------------------------------------------
//
// The background track and the weather beds are `Music` streams: they loop
// natively and stream from disk, so the long wind/rain files cost almost no
// memory. Bleats and thunder are short `Sound` effects, fired with a little
// pitch variation so repeats do not sound identical. Everything loads from
// `sfx/` on disk and fails silently if a file is missing.

const MUSIC_PATH = "sfx/jkstudios-rage-2-187959.mp3";
const RAIN_PATH = "sfx/WE Heavy Outside Rain 1.wav";
const WIND_PATH = "sfx/WE Light Wind Whistle 1.wav";
const BLEAT_PATHS = [
    "sfx/dragon-studio-goat-baa-390303.mp3",
    "sfx/dragon-studio-goat-kid-bleating-390290.mp3",
    "sfx/dragon-studio-goat-sound-390298.mp3",
    "sfx/dragon-studio-goat-sound-effect-390305.mp3",
    "sfx/mightuser-1-goat-sound-effect-259473.mp3",
    "sfx/freesound_community-happy-goat-6463.mp3",
];
const THUNDER_PATHS = [
    "sfx/WE Thunder 1.wav",
    "sfx/WE Thunder 26.wav",
    "sfx/WE Thunder 29.wav",
];

const MUSIC_VOLUME = 0.20;   // the background track sits well under the sfx
const SFX_VOLUME = 0.65;
const RAIN_VOLUME = 0.9;     // scaled by the rain amount
const WIND_VOLUME = 0.8;     // scaled by the wind gust

let audioReady = false;
let muted = false;
let musicMain = -1;
let rainLoop = -1;
let windLoop = -1;
const BLEATS = [];
const THUNDERS = [];
let thunderCooldown = 6;
let audioSeed = 0x2f6e2b1;

// A PRNG for audio variety, kept separate from the weather's so the weather
// sequence stays reproducible.
function arnd() {
    audioSeed ^= audioSeed << 13;
    audioSeed >>>= 0;
    audioSeed ^= audioSeed >>> 17;
    audioSeed ^= audioSeed << 5;
    audioSeed >>>= 0;
    return audioSeed / 4294967296;
}

function makeAudio() {
    if (typeof rl.loadMusic !== "function" || typeof rl.loadSound !== "function" ||
        typeof rl.updateMusic !== "function" || typeof rl.initAudioDevice !== "function") {
        console.log("audio: engine has no audio bindings");
        return;
    }
    rl.initAudioDevice();
    musicMain = rl.loadMusic(MUSIC_PATH);
    if (musicMain >= 0) {
        rl.setMusicVolume(musicMain, MUSIC_VOLUME);
        rl.playMusic(musicMain);
    }
    for (let i = 0; i < BLEAT_PATHS.length; i++) {
        const sound = rl.loadSound(BLEAT_PATHS[i]);
        if (sound >= 0) BLEATS.push(sound);
    }
    for (let i = 0; i < THUNDER_PATHS.length; i++) {
        const sound = rl.loadSound(THUNDER_PATHS[i]);
        if (sound >= 0) THUNDERS.push(sound);
    }
    // The ambience beds start at silence and swell with the weather; keeping
    // them playing avoids a start/stop click at every transition.
    rainLoop = rl.loadMusic(RAIN_PATH);
    if (rainLoop >= 0) {
        rl.setMusicVolume(rainLoop, 0);
        rl.playMusic(rainLoop);
    }
    windLoop = rl.loadMusic(WIND_PATH);
    if (windLoop >= 0) {
        rl.setMusicVolume(windLoop, 0);
        rl.playMusic(windLoop);
    }
    audioReady = true;
    console.log("audio: music " + musicMain + " rain " + rainLoop + " wind " + windLoop +
        " bleats " + BLEATS.length + " thunder " + THUNDERS.length);
}

// Fire a random bleat. `gain` scales the base sfx volume for the situation.
function playBleat(gain) {
    if (!audioReady || muted || BLEATS.length === 0) return;
    const sound = BLEATS[Math.floor(arnd() * BLEATS.length) % BLEATS.length];
    rl.setSoundVolume(sound, SFX_VOLUME * gain);
    rl.setSoundPitch(sound, 0.9 + arnd() * 0.25);
    rl.playSound(sound);
}

// Called once per frame: keep every stream fed and tie the beds to the weather.
function updateAudio(dt) {
    if (!audioReady) return;
    if (musicMain >= 0) rl.updateMusic(musicMain);
    if (rainLoop >= 0) {
        rl.updateMusic(rainLoop);
        rl.setMusicVolume(rainLoop, muted ? 0 : MUSIC_VOLUME * RAIN_VOLUME * rainAmount);
    }
    if (windLoop >= 0) {
        rl.updateMusic(windLoop);
        rl.setMusicVolume(windLoop, muted ? 0 : MUSIC_VOLUME * WIND_VOLUME * windSway);
    }
    thunderCooldown -= dt;
    if (rainAmount > 0.55 && thunderCooldown <= 0 && THUNDERS.length > 0) {
        const sound = THUNDERS[Math.floor(arnd() * THUNDERS.length) % THUNDERS.length];
        if (!muted) {
            rl.setSoundVolume(sound, SFX_VOLUME * 0.8);
            rl.playSound(sound);
        }
        thunderCooldown = 8 + arnd() * 14;
    }
}

function setMuted(next) {
    muted = next;
    if (audioReady && musicMain >= 0) rl.setMusicVolume(musicMain, muted ? 0 : MUSIC_VOLUME);
}

// ---- weather -------------------------------------------------------------

const WIND_BASE = 1.6;              // m/s
const CLOUD_DRIFT = 0.35;           // clouds move slower than the ground wind
const CLOUD_WRAP = 100;             // recycle clouds this far from the goat
const RAIN_MAX = 160;       // streaks; each is a drawLine, so this is a cost knob

const OVERCAST_TOP = rl.color(96, 102, 116, 255);
const OVERCAST_BOT = rl.color(150, 154, 162, 255);

const WEATHER_STATES = {
    clear: { cloud: 0.05, rain: 0.0 },
    cloudy: { cloud: 0.70, rain: 0.0 },
    rain: { cloud: 1.00, rain: 1.0 },
    clearing: { cloud: 0.40, rain: 0.12 },
};
const WEATHER_NEXT = {
    clear: ["cloudy"],
    cloudy: ["rain", "clear"],
    rain: ["clearing"],
    clearing: ["clear", "cloudy"],
};
const WEATHER_HOLD = { clear: [22, 45], cloudy: [16, 34], rain: [20, 40], clearing: [8, 16] };

let cloudTex = -1;
let weatherKind = "clear";
let weatherTimer = 24;
let cloudiness = 0.05;      // 0..1, eased toward the state's target
let rainAmount = 0.0;       // 0..1, eased
let rainActive = 0;
let windX = 1.0, windZ = 0.2;
let windSway = 0.4;
let swayTime = 0.0;
let weatherText = "";
let rngState = 0x9e3779b9;

// Deterministic PRNG (xorshift32) so a run's weather is reproducible and the
// headless harness stays stable.
function rnd() {
    rngState ^= rngState << 13;
    rngState >>>= 0;
    rngState ^= rngState >>> 17;
    rngState ^= rngState << 5;
    rngState >>>= 0;
    return rngState / 4294967296;
}

// Value noise, for the cloud puff sprite.
function vnoise2(x, y) {
    const xi = Math.floor(x);
    const yi = Math.floor(y);
    const xf = x - xi;
    const yf = y - yi;
    const u = xf * xf * (3 - 2 * xf);
    const v = yf * yf * (3 - 2 * yf);
    const a = hash(xi * 57.0 + yi * 131.0);
    const b = hash((xi + 1) * 57.0 + yi * 131.0);
    const c = hash(xi * 57.0 + (yi + 1) * 131.0);
    const d = hash((xi + 1) * 57.0 + (yi + 1) * 131.0);
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v;
}

function lerpColor(a, b, t) {
    const ar = (a >>> 24) & 255;
    const ag = (a >>> 16) & 255;
    const ab = (a >>> 8) & 255;
    const br = (b >>> 24) & 255;
    const bg = (b >>> 16) & 255;
    const bb = (b >>> 8) & 255;
    return rl.color(
        Math.round(ar + (br - ar) * t),
        Math.round(ag + (bg - ag) * t),
        Math.round(ab + (bb - ab) * t), 255);
}

const CLOUDS = [];
(function buildClouds() {
    for (let i = 0; i < 46; i++) {
        const a = hash(i * 2.1) * Math.PI * 2;
        const r = 26 + hash(i * 3.3) * 74;
        CLOUDS.push({
            x: Math.cos(a) * r,
            z: Math.sin(a) * r,
            y: 26 + hash(i * 5.5) * 22,
            size: 12 + hash(i * 7.1) * 22,
            cover: hash(i * 9.9),
        });
    }
})();

const RAIN = [];
(function buildRain() {
    for (let i = 0; i < RAIN_MAX; i++) {
        RAIN.push({ x: hash(i * 1.7), y: hash(i * 2.9), speed: 0.6 + hash(i * 4.3) });
    }
})();

// A soft noise-modulated puff, built once at startup.
function makeWeatherTextures() {
    const N = 48;
    let puff = "";
    for (let y = 0; y < N; y++) {
        for (let x = 0; x < N; x++) {
            const u = (x + 0.5) / N - 0.5;
            const v = (y + 0.5) / N - 0.5;
            const d = Math.sqrt(u * u + v * v) / 0.5;
            let a = 0;
            if (d < 1) {
                const n = 0.55 * vnoise2(x * 0.18, y * 0.18) +
                    0.30 * vnoise2(x * 0.37 + 11, y * 0.37 + 7) +
                    0.15 * vnoise2(x * 0.71 + 23, y * 0.71 + 5);
                a = (1 - d) * (n * 1.8 - 0.32);
                a = Math.min(1, Math.max(0, a)) * 255;
            }
            puff += "ffffff" + HEX256[Math.round(a)];
        }
    }
    cloudTex = rl.makeTexture(N, N, puff);
}

function updateWind(dt) {
    swayTime += dt;
    const gust = 0.55 + 0.35 * Math.sin(swayTime * 0.7) + 0.2 * Math.sin(swayTime * 1.9 + 1.3);
    const dir = 0.5 * Math.sin(swayTime * 0.23);
    const speed = WIND_BASE * Math.max(0.2, gust);
    windX = Math.cos(dir) * speed;
    windZ = Math.sin(dir) * speed;
    windSway = Math.min(1.4, speed / WIND_BASE) * (0.55 + 0.45 * cloudiness);
}

function updateWeather(dt) {
    weatherTimer -= dt;
    if (weatherTimer <= 0) {
        const opts = WEATHER_NEXT[weatherKind];
        weatherKind = opts[Math.floor(rnd() * opts.length) % opts.length];
        const hold = WEATHER_HOLD[weatherKind];
        weatherTimer = hold[0] + rnd() * (hold[1] - hold[0]);
    }
    const target = WEATHER_STATES[weatherKind];
    const k = Math.min(1, dt * 0.6);
    cloudiness += (target.cloud - cloudiness) * k;
    rainAmount += (target.rain - rainAmount) * k;
    weatherText = weatherKind + "   wind " +
        Math.sqrt(windX * windX + windZ * windZ).toFixed(1) + " m/s";
    if (rainAmount > 0.02) weatherText = weatherText + "   rain " + Math.round(rainAmount * 100) + "%";
}

// C jumps to the next state, for previewing the cycle.
function forceWeather() {
    weatherKind = WEATHER_NEXT[weatherKind][0];
    weatherTimer = WEATHER_HOLD[weatherKind][0];
}

function updateClouds(dt) {
    const W = CLOUD_WRAP;
    for (let i = 0; i < CLOUDS.length; i++) {
        const c = CLOUDS[i];
        c.x += windX * CLOUD_DRIFT * dt;
        c.z += windZ * CLOUD_DRIFT * dt;
        if (c.x - goat.px > W) c.x -= 2 * W;
        else if (c.x - goat.px < -W) c.x += 2 * W;
        if (c.z - goat.pz > W) c.z -= 2 * W;
        else if (c.z - goat.pz < -W) c.z += 2 * W;
    }
}

function drawClouds() {
    if (cloudTex < 0 || cloudiness < 0.04) return;
    const t = skyLight;
    const warm = Math.max(0, Math.min(1, 1 - Math.abs(t - 0.3) / 0.34));
    const cr = Math.min(255, Math.round(118 + 137 * t + 30 * warm));
    const cg = Math.min(255, Math.round(122 + 133 * t + 8 * warm));
    const cb = Math.min(255, Math.round(140 + 115 * t - 20 * warm));
    for (let i = 0; i < CLOUDS.length; i++) {
        const c = CLOUDS[i];
        if (c.cover > cloudiness) continue;
        const grow = Math.min(1, (cloudiness - c.cover) / 0.3 + 0.4);
        rl.drawBillboard(cloudTex, c.x, c.y, c.z, c.size,
            rl.color(cr, cg, cb, Math.round(190 * cloudiness * grow)));
    }
}

function updateRain(dt) {
    rainActive = Math.round(RAIN_MAX * rainAmount);
    for (let i = 0; i < rainActive; i++) {
        const d = RAIN[i];
        d.y += (0.7 + d.speed) * dt;
        d.x += windX * 0.02 * dt;
        if (d.y > 1.05) {
            d.y = d.y - 1.1;
            d.x = hash(i * 13.1 + rngState * 0.0001);
        }
        if (d.x > 1.1) d.x = d.x - 1.2;
        else if (d.x < -0.1) d.x = d.x + 1.2;
    }
}

// Screen-space rain overlay: short streaks angled along the wind.
function drawRain(w, h) {
    if (rainActive <= 0) return;
    const slant = windX * 0.035;
    const col = rl.color(182, 202, 232, 150);
    for (let i = 0; i < rainActive; i++) {
        const d = RAIN[i];
        const sx = d.x * w;
        const sy = d.y * h;
        const len = 0.045 * h * (0.6 + d.speed);
        rl.drawLine(Math.round(sx), Math.round(sy),
            Math.round(sx + slant * w), Math.round(sy + len), col);
    }
}

function drawGround(g, groundCol, tuftCol) {
    // Snap the slab to a 2-unit grid so it looks pinned down while we travel.
    const gx = Math.round(g.px / 2) * 2;
    const gz = Math.round(g.pz / 2) * 2;
    rl.drawCube(gx, -0.06, gz, 70, 0.1, 70, groundCol);
    rl.drawGrid(40, 1.0);
    for (let i = 0; i < TUFTS.length; i++) {
        const tx = TUFTS[i].x - g.px;
        const tz = TUFTS[i].z - g.pz;
        const d2 = tx * tx + tz * tz;
        if (d2 > 576) continue; // cull beyond 24 units
        // Lean each tuft with the gust; nearer ones get a second segment so the
        // bend reads up close.
        const off = Math.sin(swayTime * 3.0 + TUFTS[i].p) * 0.11 * windSway;
        rl.drawCube(TUFTS[i].x + off, 0.06, TUFTS[i].z + off * 0.4, 0.14, 0.16, 0.14, tuftCol);
        if (d2 < 180) {
            rl.drawCube(TUFTS[i].x + off * 1.7, 0.20, TUFTS[i].z + off * 0.7,
                0.11, 0.16, 0.11, tuftCol);
        }
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
let moonTex = -1;        // procedural cratered moon disc
let glowTex = -1;        // radial sun/star glow
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
    playBleat(0.9);
}

function startSleep() {
    mode = "sleep";
    sleepTime = 0;
    idleTimer = 0;
    playBleat(0.45);
}

function wakeUp() {
    mode = "idle";
    sleepTime = 0;
    playBleat(0.7);
}

function die() {
    mode = "dead";
    deathTime = 0;
    playBleat(1.0);
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

// Two-character hex for every byte, so the texture builders avoid per-pixel
// string formatting.
const HEX256 = (function buildHex256() {
    const d = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    const out = [];
    for (let i = 0; i < 256; i++) out.push(d[Math.floor(i / 16)] + d[i % 16]);
    return out;
})();

// Procedural moon and glow sprites: the demo stays asset-free, and an alpha moon
// composites cleanly (a photo would drag a black square along, since the `rl`
// surface has no additive blend mode yet).
function makeSkyTextures() {
    const N = 64;
    const craters = [];
    for (let i = 0; i < 16; i++) {
        const a = hash(i * 3.7) * Math.PI * 2;
        const rr = Math.sqrt(hash(i * 9.1)) * 0.40;
        craters.push({
            cx: 0.5 + Math.cos(a) * rr,
            cy: 0.5 + Math.sin(a) * rr,
            cr: 0.045 + hash(i * 5.3) * 0.11,
            deep: hash(i * 7.7),
        });
    }
    let moon = "";
    let glow = "";
    for (let y = 0; y < N; y++) {
        for (let x = 0; x < N; x++) {
            const u = (x + 0.5) / N - 0.5;
            const v = (y + 0.5) / N - 0.5;
            const d = Math.sqrt(u * u + v * v);
            let r = 0;
            let g = 0;
            let b = 0;
            let a = 0;
            if (d < 0.5) {
                const limb = 1 - 0.35 * (d / 0.5) * (d / 0.5);
                let shade = 0.82 * limb;
                for (let i = 0; i < craters.length; i++) {
                    const c = craters[i];
                    const dx = u + 0.5 - c.cx;
                    const dy = v + 0.5 - c.cy;
                    const dd = Math.sqrt(dx * dx + dy * dy);
                    if (dd < c.cr) {
                        const t = 1 - dd / c.cr;
                        shade = shade - 0.20 * t * (0.5 + c.deep);
                        if (dd > c.cr * 0.72) shade = shade + 0.14 * t;
                    }
                }
                shade = Math.min(1, Math.max(0.32, shade));
                r = 236 * shade;
                g = 232 * shade;
                b = 220 * shade;
                a = 255 * Math.min(1, (0.5 - d) / 0.015);
            }
            moon += HEX256[Math.min(255, Math.max(0, Math.round(r)))] +
                HEX256[Math.min(255, Math.max(0, Math.round(g)))] +
                HEX256[Math.min(255, Math.max(0, Math.round(b)))] +
                HEX256[Math.min(255, Math.max(0, Math.round(a)))];
            const gd = d / 0.5;
            const ga = gd >= 1 ? 0 : Math.round(255 * (1 - gd) * (1 - gd));
            glow += "fff6d6" + HEX256[ga];
        }
    }
    moonTex = rl.makeTexture(N, N, moon);
    glowTex = rl.makeTexture(N, N, glow);
}
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
        goat.phase.toFixed(2) + "   fps " + rl.getFPS() + "   light " + lightingText +
        "   audio " + (audioReady ? (muted ? "muted" : "on") : "off");
    rl.drawText("Slag goat  -  " + how, 10, 8, 18, rl.RAYWHITE);
    rl.drawText("W/S walk   CTRL trot   SHIFT run   SPACE jump   Z sleep   T time   L light   K shadow   M audio   A/D turn   drag: orbit   wheel: zoom   P: pause   ESC: quit",
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

    rl.drawText(weatherText, 10, h - 44, 14, rl.RAYWHITE);
    rl.drawText(status + "   " + state, 10, h - 24, 14, rl.RAYWHITE);
}

function run() {
    rl.initWindow(1000, 640, "Slag goat - walk / run / jump / sleep");
    rl.setTargetFPS(60);
    loadGoat();
    makeEyeTextures();
    makeSkyTextures();
    makeWeatherTextures();
    makeLighting();
    makeAudio();

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
        updateWind(dt);
        updateWeather(dt);
        updateClouds(dt);
        updateRain(dt);
        updateAudio(dt);
        // overcast skies wash the gradient toward grey
        const grey = Math.min(0.75, cloudiness * 0.75);
        skyTop = lerpColor(sky.top, OVERCAST_TOP, grey);
        skyBot = lerpColor(sky.bot, OVERCAST_BOT, grey);
        skyLight = sky.light;
        updateAmbient();
        updateLight();
        updateShadow();
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
        if (rl.isKeyPressed(rl.KEY_C)) forceWeather();
        if (rl.isKeyPressed(rl.KEY_L) && litShader >= 0) {
            useLighting = !useLighting;
            if (haveModel) rl.setModelShader(model, useLighting ? litShader : -1);
        }
        if (rl.isKeyPressed(rl.KEY_K) && litShader >= 0) {
            // Cycle shadows: map -> planar -> off. The map needs the engine
            // bindings; planar is the fallback.
            shadowMode = (shadowMode + 1) % 3;
            if (shadowMode === SHADOW_MAP && !shadowMapReady) shadowMode = SHADOW_OFF;
            if (shadowMode === SHADOW_PLANAR && shadowShader < 0) shadowMode = SHADOW_OFF;
        }
        if (rl.isKeyPressed(rl.KEY_M)) setMuted(!muted);
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
        const lit = useLighting && litShader >= 0;
        // The shadow-map pass must run before the main 3D pass, since it swaps
        // render targets and leaves the model pointing back at the lit shader.
        if (lit) renderShadowMap();
        rl.beginMode3D(cx, cy, cz, goat.px, ty, goat.pz, 55);
        drawStars();
        drawCelestial();
        drawClouds();

        if (lit) {
            // Terrain is immediate-mode geometry, so it goes through the lit
            // program with base colours: the shader now supplies the light.
            rl.beginShaderMode(litShader);
            setLitUniforms(cx, cy, cz);
            drawGround(goat, GROUND, TUFT);
            if (!haveModel) drawGoat(goat);
            rl.endShaderMode();
            if (haveModel) {
                // The planar fallback is drawn first, under the goat; the shadow
                // map is sampled by the lit shader during the goat's own draw.
                if (shadowMode === SHADOW_PLANAR && shadowShader >= 0 && LIGHT_DIR[1] > 0.06) {
                    rl.setModelShader(model, shadowShader);
                    setShadowUniforms();
                    drawModelGoat(goat, rl.WHITE);
                    rl.setModelShader(model, litShader);
                }
                drawModelGoat(goat, rl.WHITE);
                drawEyes();
            }
            if (shadowMode === SHADOW_MAP && shadowStrengthNow > 0.001) lightingText = "lit + shadow map";
            else if (shadowMode === SHADOW_PLANAR && LIGHT_DIR[1] > 0.06) lightingText = "lit + planar shadow";
            else lightingText = "lit";
        } else {
            // No shader: the M2/M3 look, with the ambient tint and a blob shadow.
            drawGround(goat, ambGround, ambTuft);
            drawShadow();
            if (haveModel) {
                drawModelGoat(goat, ambTint);
                drawEyes();
            } else {
                drawGoat(goat);
            }
            lightingText = litShader < 0 ? "cube shader" : "off";
        }
        rl.endMode3D();
        drawRain(sw, sh);
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
    if (audioReady) rl.closeAudioDevice();
    rl.closeWindow();
}

run();

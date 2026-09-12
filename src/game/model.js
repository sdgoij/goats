// Part 2/12 of the goat scene: the animated model and the cube fallback.
// ---- the model goat ------------------------------------------------------

let model = -1;
let haveModel = false;
let groundOffset = 0;

// Clip handles by role, filled in from the model's animation names. Each is
// { index, frames, duration } or null when that clip is absent. `CLIP[role]` is
// the default; `VARIANTS[role]` holds every clip for roles that have more than
// one (idle/sleep/jump), so different goats can play different versions.
const CLIP = { idle: null, walk: null, trot: null, run: null, jump: null, sleep: null, death: null, eat: null };
const VARIANTS = { idle: [], sleep: [], jump: [], eat: [] };
const playerVariant = { idle: 0, sleep: -1, jump: -1, eat: -1 };

// Model-space eye points baked in Blender for the death pose, used to place the
// X-eye sprites (glTF Y-up, from the rig). Sleeping eyes are real eyelid
// geometry now -- the `LidL`/`LidR` bones close in the GoatSleep clip.
const DEATH_EYES = [
    { x: 0.8259, y: 0.4274, z: 1.6120 },
    { x: 0.7945, y: 0.1493, z: 1.6031 },
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

// Every clip whose name contains `wanted`, in model order. Used for the role
// variants (GoatIdle, GoatIdle2, GoatIdle3, ...).
function findClips(names, wanted) {
    const out = [];
    for (let i = 0; i < names.length; i++) {
        if (names[i].toLowerCase().indexOf(wanted) >= 0) out.push(i);
    }
    return out;
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
    const idle = findClips(names, "idle");
    const jump = findClips(names, "jump");
    const sleep = findClips(names, "sleep");
    // "eat" alone would also match "death"; the clips are GoatEat/GoatEat2.
    const eat = findClips(names, "goateat");
    const run = findClip(names, "run");
    const trot = findClip(names, "trot");
    const walk = findClip(names, "walk");
    const death = findClip(names, "death");
    CLIP.idle = idle.length > 0 ? clipInfo(idle[0]) : null;
    CLIP.jump = jump.length > 0 ? clipInfo(jump[0]) : null;
    CLIP.sleep = sleep.length > 0 ? clipInfo(sleep[0]) : null;
    CLIP.eat = eat.length > 0 ? clipInfo(eat[0]) : null;
    VARIANTS.idle = idle.map(clipInfo);
    VARIANTS.jump = jump.map(clipInfo);
    VARIANTS.sleep = sleep.map(clipInfo);
    VARIANTS.eat = eat.map(clipInfo);
    CLIP.run = run >= 0 ? clipInfo(run) : null;
    CLIP.trot = trot >= 0 ? clipInfo(trot) : null;
    CLIP.walk = walk >= 0 ? clipInfo(walk) : null;
    CLIP.death = death >= 0 ? clipInfo(death) : null;

    console.log("goat: model handle " + model + ", live=" + rl.isModelValid(model) +
        ", bones=" + rl.modelBoneCount(model) + ", walk " + walkSpeed().toFixed(2) +
        ", trot " + trotSpeed().toFixed(2) + ", run " + runSpeed().toFixed(2) + " m/s");
    console.log("goat: model loaded, y " + bounds.minY.toFixed(3) + ".." + bounds.maxY.toFixed(3));
}

// Pose a clip at `phase` in [0,1] across its keyframes, on a specific model.
// Every bot owns a model handle of its own -- CPU skinning writes deformed
// vertices into the model's meshes, so two goats cannot share one model and
// still animate independently -- which is why the handle is explicit.
function poseModelOn(handle, info, phase) {
    if (info === null || info === undefined || info.frames < 1) return false;
    const last = info.frames - 1;
    let frame = phase * last;
    if (frame > last) frame = last;
    rl.updateModelAnimation(handle, info.index, frame);
    return true;
}

// Which clip variant to play for a role, wrapping the index.
function clipAt(role, variant) {
    const list = VARIANTS[role];
    if (list !== undefined && list.length > 0) {
        const n = list.length;
        return list[((variant % n) + n) % n];
    }
    return CLIP[role];
}

function clipCount(role) {
    const list = VARIANTS[role];
    return list !== undefined ? list.length : 0;
}

// Advance the player's variant for a role, so it does not always do the same
// idle / sleep / jump. Bots cycle their own variants in bots.js.
function cyclePlayerVariant(role) {
    const n = clipCount(role);
    if (n > 1) playerVariant[role] = (playerVariant[role] + 1) % n;
}

function playerClip(role) {
    return clipAt(role, playerVariant[role]);
}

// Length of the one-shot eat clip (the player's current variant), or the
// fallback when the model has no eat clip.
function eatDuration() {
    const info = playerClip("eat");
    return info !== null && info !== undefined ? info.duration : EAT_FALLBACK_TIME;
}

function poseModel(role, phase) {
    return poseModelOn(model, playerClip(role), phase);
}

// Draw the model: position, yaw about +Y (degrees), uniform scale, given tint.
// The y is the ground under the goat (`goatBaseY`), so it walks up the terrain.
function drawModelGoat(g, tint) {
    const yawDeg = (g.yaw * 180) / Math.PI;
    rl.drawModelEx(model, g.px, goatBaseY(g) + groundOffset, g.pz,
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


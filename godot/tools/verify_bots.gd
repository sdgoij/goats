# The herd gate: `bots.gd` against `bots.js`.
#
#   Godot --headless --path godot --script res://tools/verify_bots.gd
#
# The bots are the most *branchy* thing in the port and the most sensitive to a wrong
# transcription, because almost nothing they do is a formula: they draw from their own
# PRNG, they compare floats to decide whether they have arrived, and one frame's
# decision changes every frame after it. A single draw taken in the wrong order or a
# single `>` written as a `>=` does not bend the herd, it *replaces* it -- and the
# earlier frames still look right, which is exactly the shape of bug the port's own
# notes keep finding (see `player_goat.gd` `clip_role`).
#
# So this gate checks four things, in increasing order of "does it matter":
#
#   1. **The primitives.** `botRnd`'s xorshift, `botSpec`'s coat/scale/temperament
#      table past the sixth cycle, the *second* of `sceneUseSeed`'s five draws, and the
#      model's clips by role -- the last compared against the table `player_goat.gd`
#      reads off the same model, which is a second reader of one source rather than a
#      second copy of a rule.
#   2. **The tape.** A scripted run of 2100 frames -- the goat parked at four points,
#      two of them inside the herd so the push-apart has something to do, a shower
#      midway, one bot thrown by a blast and one killed and left to get up -- with every
#      bot's position, yaw, phase, timer, mode, satiety, health, clip and height
#      compared frame for frame, and `goatMinGap`/`botBellyMax`/`botGrazeWalks` beside
#      them.
#   3. **The collision.** Every frame's push-apart is checked to have left no overlap at
#      all, and the gate counts the frames it *moved* something -- a gate that never
#      overlapped two goats would be checking nothing.
#   4. **The coverage.** The oracle reports how many frames each mode lasted and how many
#      bites landed on a trapped tuft, and the gate insists every one of them happened:
#      a tape that never dozed or never bit a trap would pass while checking less than
#      it claims to.
#
# Three things are *seams* rather than transcriptions, and each is named here because a
# gate must not quietly substitute a rule it is supposed to be checking. The traps, the
# armed mines and the water are stubs -- the same pure functions handed to both sides --
# because the devices are `verify_devices.gd`'s and the water is `verify_water.gd`'s, and
# what the herd does with them (bite a trap and get nothing, wake up in the rain, respawn
# off a mine) is what this gate is about. The heightfield is transcribed (`world.js`'s
# `terrainBaseHeight`, as `verify_grass.gd` carries it) with no craters, so it is the
# field alone. And the clip *durations* are injected from the model Godot loaded, exactly
# as `verify_goat.gd` injects them: the two engines' models are the same file, and the
# number a gait's speed comes off is the number the loader read.
#
# The oracle is `bots.js` transcribed from its source -- **not** from the port. That is
# the rule the port learned the hard way, and it is why the JS below quotes the scene's
# own expressions rather than "the same thing more clearly".
extends SceneTree

## `bots.js`, `food.js`, `weather.js` and `world.js`, transcribed *from their sources*.
## The device and water calls are the stubs above; everything else is the scene's.
const JS := """
// ---- the ground, `world.js`'s -----------------------------------------------
function hash(n) { const s = Math.sin(n * 127.1) * 43758.5453; return s - Math.floor(s); }
function vnoise2(x, y) {
    const xi = Math.floor(x), yi = Math.floor(y);
    const xf = x - xi, yf = y - yi;
    const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    const a = hash(xi * 57.0 + yi * 131.0);
    const b = hash((xi + 1) * 57.0 + yi * 131.0);
    const c = hash(xi * 57.0 + (yi + 1) * 131.0);
    const d = hash((xi + 1) * 57.0 + (yi + 1) * 131.0);
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v;
}
function terrainShape(x, z) {
    const broad = 0.62 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1);
    const middle = 0.26 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9);
    const fine = 0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3);
    return broad + middle + fine;
}
function terrainBaseHeight(x, z) {
    const d = Math.sqrt(x * x + z * z);
    let t = (d - 6) / 16;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    t = t * t * (3 - 2 * t);
    return (terrainShape(x, z) - 0.5) * 2 * 2.1 * t;
}
// No craters are dug in this tape, so `terrainHeight` is the field alone.
function terrainHeight(x, z) { return terrainBaseHeight(x, z); }

// ---- the seams ---------------------------------------------------------------
// The device field and the water, as pure functions handed to both sides. The water is
// *the goat's own latitude*: everything more than 16 m south of the player is flooded. It
// has to move for the scene's two water rules to be reachable at all -- a bot cannot doze
// in water, so a *fixed* lake can never hold a sleeping bot to wake -- and the goat is the
// one thing that moves on both sides.
function trapAt(cx, cz, x, z) { return ((cx * 7 + cz * 13) % 3) === 0; }
function mineArmed(cx, cz) { return ((cx + cz) % 2) === 0; }
function waterInWater(x, z) { return z < goat.pz - 16; }

// ---- the tuning `bots.js` reads ----------------------------------------------
const TUNING = {
    stats: { max: 100 },
    movement: { turnRate: 1.8, goatRadius: 0.45, modelScale: 1.0 },
    gait: { walk: { stride: 0.40, duty: 0.50 }, trot: { stride: 0.46, duty: 0.50 },
            run: { stride: 0.50, duty: 0.34 } },
    jump: { fallbackTime: 0.6 },
    food: { eatRange: 1.1, eatSatiety: 0.55, satietyDecay: 0.02, fullBelly: 0.85,
            fullBellyHeal: 3, regrowMin: 40, regrowMax: 90, rainShelter: 0.6 },
    weather: { rainSlow: 0.28, windSlow: 0.07, windNorm: 1.4 },
    explosions: { fling: { gravity: -72, maxFlight: 2.5 } },
    herd: { count: 7, deathLinger: 8, spec: [
        { coat: [196, 168, 128], scale: 0.80, bold: 0.95, lazy: 0.55, name: "tan kid" },
        { coat: [222, 216, 206], scale: 1.06, bold: 1.00, lazy: 0.50, name: "cream" },
        { coat: [116, 92, 70], scale: 1.22, bold: 0.70, lazy: 0.72, name: "big brown" },
        { coat: [156, 126, 92], scale: 0.94, bold: 1.18, lazy: 0.32, name: "lively" },
        { coat: [88, 90, 98], scale: 1.12, bold: 0.85, lazy: 0.62, name: "charcoal" },
        { coat: [208, 180, 142], scale: 0.74, bold: 1.05, lazy: 0.45, name: "small beige" },
    ] },
};
const GRAZE_SEEK_RANGE = 12;
const EAT_FALLBACK_TIME = 2.4;
const V_STRIDE = 0.20, V_CYCLE = 0.70;

// ---- the model's clips, injected ---------------------------------------------
// `__CLIPS__` is `{ role: [[name, length], ...] }`, read off the loaded model.
const CLIPS = __CLIPS__;
const CLIP = {};
const VARIANTS = { idle: [], sleep: [], jump: [], eat: [] };
for (const role in CLIPS) {
    const list = CLIPS[role];
    CLIP[role] = list.length > 0 ? { name: list[0][0], duration: list[0][1] } : null;
}
for (const role of ["idle", "sleep", "jump", "eat"]) {
    const list = CLIPS[role] || [];
    for (let i = 0; i < list.length; i++) VARIANTS[role].push({ name: list[i][0], duration: list[i][1] });
}
// `model.js` `clipAt` / `clipCount`, verbatim -- including the wrap that makes a bot's
// initial `-1` the role's *last* variant rather than its first.
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

// ---- food, `food.js`'s -------------------------------------------------------
const EATEN = new Map();
let foodRngState = 0x1f2e3d4c;
let eatenCount = 0;
function tuftKey(cx, cz) { return (cx + 4096) * 8192 + (cz + 4096); }
function assignRegrow(key) {
    foodRngState ^= foodRngState << 13; foodRngState >>>= 0;
    foodRngState ^= foodRngState >>> 17;
    foodRngState ^= foodRngState << 5; foodRngState >>>= 0;
    EATEN.set(key, TUNING.food.regrowMin +
        (foodRngState / 4294967296) * (TUNING.food.regrowMax - TUNING.food.regrowMin));
    eatenCount += 1;
}
function consumeTuft(target) {
    if (target === null || target === undefined) return false;
    assignRegrow(tuftKey(target.cx, target.cz));
    return true;
}
function satedHeal(belly) {
    if (belly < TUNING.food.fullBelly) return 0;
    return TUNING.food.fullBellyHeal;
}
// `nearestTuft` with the trap filter dropped, as `verify_meadow.gd` has it: the traps
// here are the gate's stub, and the search asks the *food* question and only that.
function nearestTuft(x, z, range) {
    const r = Math.ceil(range / 2);
    const cx = Math.floor(x / 2);
    const cz = Math.floor(z / 2);
    let best = null;
    let bestD2 = range * range;
    for (let i = cx - r; i <= cx + r; i++) {
        for (let j = cz - r; j <= cz + r; j++) {
            let h = (i * 374761393 + j * 668265263) | 0;
            h = Math.imul(h ^ (h >>> 13), 1274126177);
            h = (h ^ (h >>> 16)) >>> 0;
            const a = h / 4294967296;
            if (a < 0.45) continue;
            if (EATEN.has((i + 4096) * 8192 + (j + 4096))) continue;
            let h2 = (i * 1103515245 + j * 12345) | 0;
            h2 = Math.imul(h2 ^ (h2 >>> 15), 2246822519);
            h2 = (h2 ^ (h2 >>> 13)) >>> 0;
            const tx = i * 2 + (h2 / 4294967296 - 0.5) * 1.8;
            const tz = j * 2 + (a - 0.5) * 1.8;
            const dx = tx - x;
            const dz = tz - z;
            const d2 = dx * dx + dz * dz;
            if (d2 <= bestD2) { bestD2 = d2; best = { x: tx, z: tz, cx: i, cz: j, d2: d2 }; }
        }
    }
    return best;
}

// ---- weather, `weather.js`'s -------------------------------------------------
// `weatherSpeedFor` reads the module's own `rainAmount`/`windSway`; here the tape is
// what moves them.
let rainAmount = 0, windSway = 0;
function rainSlowFactor(sat) {
    return TUNING.weather.rainSlow * (1 - TUNING.food.rainShelter * Math.max(0, Math.min(1, sat)));
}
function weatherSpeedFor(sat) {
    const windNorm = Math.min(1, windSway / TUNING.weather.windNorm);
    return 1 - (rainSlowFactor(sat) + TUNING.weather.windSlow * windNorm) * rainAmount;
}

// ---- the herd, `bots.js`'s ---------------------------------------------------
const BOTS = [];
let botRngState = 0x2545f491;
let botBellyMax = 0, botGrazeWalks = 0;
const STATS = { eat: 0, sleep: 0, jump: 0, flung: 0, dead: 0, trapped: 0, wakes: 0 };
const goat = { px: 0, pz: 0 };
function botRnd() {
    botRngState ^= botRngState << 13;
    botRngState >>>= 0;
    botRngState ^= botRngState >>> 17;
    botRngState ^= botRngState << 5;
    botRngState >>>= 0;
    return botRngState / 4294967296;
}
function botSpec(i) {
    const base = TUNING.herd.spec[i % TUNING.herd.spec.length];
    const cycle = Math.floor(i / TUNING.herd.spec.length);
    if (cycle === 0) return base;
    return { coat: base.coat, scale: base.scale * (1 + 0.08 * cycle), bold: base.bold,
             lazy: base.lazy, name: base.name };
}
function botAdd(i) {
    const a = i * 2.399963 + 0.3;
    const r = 6 + botRnd() * 14;
    BOTS.push({
        spec: botSpec(i),
        x: goat.px + Math.cos(a) * r,
        z: goat.pz + Math.sin(a) * r,
        yaw: a + Math.PI,
        phase: botRnd(),
        mode: "idle",
        timer: 0.5 + botRnd() * 3,
        tx: 0, tz: 0, zoom: 0,
        jumpTime: 0, jumpDur: 1, jumpSpeed: 0, jumpCool: 0,
        eatTime: 0, eatDur: 1, eatCool: 0,
        satiety: 0, graze: false,
        health: TUNING.stats.max,
        deathTime: 0, deathDur: 1,
        py: 0, flyTime: 0, flyY: 0, flyFlight: 1, flyVX: 0, flyVY: 0, flyVZ: 0,
        var: { idle: -1, sleep: -1, jump: -1, eat: -1, walk: 0, trot: 0, run: 0,
               flung: -1, death: -1 },
    });
}
function botRole(b) {
    if (b.mode === "dead" && CLIP.death) return "death";
    if (b.mode === "flung") return CLIP.flung ? "flung" : "jump";
    if (b.mode === "jump" && CLIP.jump) return "jump";
    if (b.mode === "eat" && CLIP.eat) return "eat";
    if (b.mode === "sleep" && CLIP.sleep) return "sleep";
    if (b.mode === "run" && CLIP.run) return "run";
    if (b.mode === "trot" && CLIP.trot) return "trot";
    if (b.mode === "idle" && CLIP.idle) return "idle";
    return "walk";
}
function startBotFling(b, vx, vz, vy) {
    if (b.mode !== "flung") {
        b.flyY = terrainHeight(b.x, b.z);
        b.flyTime = 0;
        b.mode = "flung";
        b.timer = 0;
        b.graze = false;
        b.zoom = 0;
    }
    b.flyVX += vx;
    b.flyVZ += vz;
    b.flyVY += vy;
    const g = TUNING.explosions.fling.gravity;
    const air = b.flyVY > 0 && g < 0 ? (-2 * b.flyVY) / g : 0.4;
    b.flyFlight = Math.max(0.3, Math.min(TUNING.explosions.fling.maxFlight, b.flyTime + air));
}
function botFlingProgress(b) { return Math.min(b.flyTime / b.flyFlight, 1); }
function botDie(b) {
    b.health = 0;
    b.mode = "dead";
    b.deathTime = 0;
    b.graze = false;
    b.zoom = 0;
    const n = clipCount("death");
    if (n > 1) b.var.death = (b.var.death + 1) % n;
    const info = clipAt("death", b.var.death);
    b.deathDur = info !== null && info !== undefined && info.duration > 0 ? info.duration : 1;
}
function botRespawn(b) {
    let x = b.x;
    let z = b.z;
    for (let tries = 0; tries < 8; tries++) {
        const a = botRnd() * Math.PI * 2;
        const r = 10 + botRnd() * 16;
        x = goat.px + Math.cos(a) * r;
        z = goat.pz + Math.sin(a) * r;
        if (!mineArmed(Math.floor(x / 2), Math.floor(z / 2))) break;
    }
    b.x = x;
    b.z = z;
    b.yaw = Math.atan2(-(goat.pz - z), goat.px - x);
    b.health = TUNING.stats.max;
    b.deathTime = 0;
    b.py = 0;
    b.flyTime = 0;
    b.flyFlight = 1;
    b.flyVX = 0;
    b.flyVY = 0;
    b.flyVZ = 0;
    b.satiety = 0;
    b.graze = false;
    b.zoom = 0;
    b.mode = "idle";
    b.timer = 1.5 + botRnd() * 3;
}
function botStartEat(b, t) {
    const n = clipCount("eat");
    if (n > 1) b.var.eat = (b.var.eat + 1) % n;
    const info = clipAt("eat", b.var.eat);
    consumeTuft(t);
    b.yaw = Math.atan2(-(t.z - b.z), t.x - b.x);
    // `trapAt` + `tripDevice`: the gate's stub has no fuse to light, so the *test* is
    // the whole of it -- which is the half the belly depends on.
    if (trapAt(t.cx, t.cz, t.x, t.z)) {
        STATS.trapped += 1;
    } else {
        const heal = satedHeal(b.satiety);
        b.satiety = Math.min(1, b.satiety + TUNING.food.eatSatiety);
        b.health = Math.min(TUNING.stats.max, b.health + heal);
    }
    b.mode = "eat";
    b.eatTime = 0;
    b.eatDur = info !== null && info !== undefined ? info.duration : EAT_FALLBACK_TIME;
    b.timer = b.eatDur;
    b.eatCool = 20 + botRnd() * 40;
    b.graze = false;
    b.zoom = 0;
}
function botNewAction(b) {
    if (b.eatCool <= 0 && botRnd() < 0.6) {
        const near = nearestTuft(b.x, b.z, TUNING.food.eatRange);
        if (near !== null) {
            botStartEat(b, near);
            return;
        }
        const far = nearestTuft(b.x, b.z, GRAZE_SEEK_RANGE);
        if (far !== null) {
            b.graze = true;
            botGrazeWalks += 1;
            b.tx = far.x;
            b.tz = far.z;
            b.mode = "walk";
            b.timer = 14;
            b.zoom = 0;
            return;
        }
    }
    b.graze = false;
    const r = botRnd();
    if (r < 0.30 + 0.35 * b.spec.lazy) {
        b.mode = botRnd() < 0.10 && !waterInWater(b.x, b.z) ? "sleep" : "idle";
        b.timer = b.mode === "sleep" ? 5 + botRnd() * 6 : 2 + botRnd() * 5;
        b.zoom = 0;
        const n = clipCount(b.mode);
        if (n > 1) b.var[b.mode] = (b.var[b.mode] + 1) % n;
        return;
    }
    const s = botRnd();
    b.mode = s < 0.60 ? "walk" : s < 0.90 ? "trot" : "run";
    b.timer = 3 + botRnd() * 9;
    b.zoom = b.mode === "run" ? 2.5 + botRnd() * 4 : 0;
    b.jumpCool = 0.4 + botRnd() * 1.0;
    const reach = b.mode === "run" ? 22 : b.mode === "trot" ? 14 : 7;
    const dist = reach + botRnd() * 14;
    const dx = goat.px - b.x;
    const dz = goat.pz - b.z;
    const far = Math.sqrt(dx * dx + dz * dz);
    const a = far > 42 ? Math.atan2(-dz, dx) + (botRnd() - 0.5) * 0.9
        : botRnd() * Math.PI * 2;
    b.tx = b.x + Math.cos(a) * dist;
    b.tz = b.z - Math.sin(a) * dist;
}
function updateBots(dt) {
    const TURN = 1.5;
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        if (b.mode === "dead") {
            b.deathTime += dt;
            if (b.py > 0) {
                b.x += b.flyVX * dt;
                b.z += b.flyVZ * dt;
                b.flyVY += TUNING.explosions.fling.gravity * dt;
                b.flyY += b.flyVY * dt;
                b.py = b.flyY - terrainHeight(b.x, b.z);
                if (b.flyVY <= 0 && b.py <= 0) {
                    b.py = 0;
                    b.flyVX = 0;
                    b.flyVY = 0;
                    b.flyVZ = 0;
                }
            }
            if (b.deathTime >= TUNING.herd.deathLinger) botRespawn(b);
            continue;
        }
        b.timer -= dt;
        if (b.mode === "sleep" && waterInWater(b.x, b.z)) {
            STATS.wakes += 1;
            b.mode = "idle";
            b.timer = 0;
        }
        if (b.jumpCool > 0) b.jumpCool -= dt;
        if (b.eatCool > 0) b.eatCool -= dt;
        if (b.satiety > 0) b.satiety = Math.max(0, b.satiety - TUNING.food.satietyDecay * dt);
        if (b.satiety > botBellyMax) botBellyMax = b.satiety;

        if (b.mode === "flung") {
            b.flyTime += dt;
            b.x += b.flyVX * dt;
            b.z += b.flyVZ * dt;
            b.flyVY += TUNING.explosions.fling.gravity * dt;
            b.flyY += b.flyVY * dt;
            b.py = b.flyY - terrainHeight(b.x, b.z);
            if (b.flyVY <= 0 && b.py <= 0) {
                b.py = 0;
                b.flyVX = 0;
                b.flyVY = 0;
                b.flyVZ = 0;
                b.mode = "idle";
                b.timer = 1.5 + botRnd() * 3;
            }
        } else if (b.mode === "jump") {
            b.jumpTime += dt;
            b.x += Math.cos(b.yaw) * b.jumpSpeed * dt;
            b.z += -Math.sin(b.yaw) * b.jumpSpeed * dt;
            if (b.jumpTime >= b.jumpDur) {
                if (b.zoom > 0) {
                    b.mode = "run";
                    b.jumpCool = 0.4 + botRnd() * 1.2;
                } else {
                    b.mode = "idle";
                    b.timer = 1.5 + botRnd() * 3;
                }
            }
        } else if (b.mode === "eat") {
            b.eatTime += dt;
            if (b.eatTime >= b.eatDur) {
                b.mode = "idle";
                b.timer = 1.5 + botRnd() * 3;
            }
        } else {
            const role = botRole(b);
            const info = clipAt(role, b.var[role]);
            const gait = TUNING.gait[role];
            let spd = 0;
            if (b.mode !== "idle" && b.mode !== "sleep") {
                const base = (info !== null && info.duration > 0 && gait !== undefined)
                    ? gait.stride / (gait.duty * info.duration)
                    : (2 * V_STRIDE) / V_CYCLE;
                spd = base * (0.75 + 0.5 * b.spec.bold) * weatherSpeedFor(b.satiety);
            }

            if (spd > 0) {
                const dx = b.tx - b.x;
                const dz = b.tz - b.z;
                const d = Math.sqrt(dx * dx + dz * dz);
                const arrive = b.graze ? 0.7 : 1.6;
                if (d < arrive || b.timer <= 0) {
                    if (b.graze) {
                        b.graze = false;
                        const t = nearestTuft(b.x, b.z, TUNING.food.eatRange);
                        if (t !== null) botStartEat(b, t);
                        else {
                            b.mode = "idle";
                            b.timer = 1.5 + botRnd() * 3;
                        }
                    } else if (b.mode === "run" && b.zoom > 0) {
                        const a = botRnd() * Math.PI * 2;
                        const r = 9 + botRnd() * 12;
                        b.tx = b.x + Math.cos(a) * r;
                        b.tz = b.z - Math.sin(a) * r;
                        b.timer = 2 + botRnd() * 3;
                    } else {
                        b.mode = "idle";
                        b.timer = 1.5 + botRnd() * 4;
                    }
                } else {
                    const want = Math.atan2(-dz, dx);
                    let diff = want - b.yaw;
                    while (diff > Math.PI) diff -= Math.PI * 2;
                    while (diff < -Math.PI) diff += Math.PI * 2;
                    b.yaw += Math.max(-TURN * dt, Math.min(TURN * dt, diff));
                    b.x += Math.cos(b.yaw) * spd * dt;
                    b.z += -Math.sin(b.yaw) * spd * dt;
                }
            } else if (b.timer <= 0) {
                botNewAction(b);
            }

            if (b.mode === "run") {
                b.zoom -= dt;
                if (b.zoom > 0 && b.jumpCool <= 0 && spd > 0) {
                    b.mode = "jump";
                    const nj = clipCount("jump");
                    if (nj > 1) b.var.jump = (b.var.jump + 1) % nj;
                    const jinfo = clipAt("jump", b.var.jump);
                    b.jumpDur = jinfo !== null && jinfo !== undefined ? jinfo.duration
                        : TUNING.jump.fallbackTime;
                    b.jumpTime = 0;
                    b.jumpSpeed = spd * 1.15;
                    b.jumpCool = 0.5 + botRnd() * 1.3;
                }
            }

            if (b.mode !== "jump") {
                const cur = clipAt(role, b.var[role]);
                const dur = cur !== null && cur !== undefined && cur.duration > 0 ? cur.duration
                    : V_CYCLE;
                b.phase = ((b.phase + dt / dur) % 1 + 1) % 1;
            }
        }

        const px = b.x - goat.px;
        const pz = b.z - goat.pz;
        const far = Math.sqrt(px * px + pz * pz);
        if (far > 80) {
            b.x = goat.px + (px / far) * 80;
            b.z = goat.pz + (pz / far) * 80;
        }
    }
}
function collidePairs(bots, count, gx, gz, rad, pr) {
    let moved = true;
    for (let pass = 0; pass < 2 && moved; pass++) {
        moved = false;
        for (let i = 0; i < count; i++) {
            const b = bots[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr) {
                if (d2 <= 1e-4) b.x = gx + rr;
                else {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / d;
                    b.x += dx * push;
                    b.z += dz * push;
                }
                if (b.timer > 0.6) b.timer = 0.6;
                moved = true;
            }
        }
        for (let i = 0; i < count; i++) {
            const a = bots[i];
            const ar = rad * a.spec.scale;
            for (let j = i + 1; j < count; j++) {
                const b = bots[j];
                const rr = ar + rad * b.spec.scale;
                const dx = b.x - a.x;
                const dz = b.z - a.z;
                const d2 = dx * dx + dz * dz;
                if (d2 < rr * rr && d2 > 1e-4) {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / (2 * d);
                    a.x -= dx * push;
                    a.z -= dz * push;
                    b.x += dx * push;
                    b.z += dz * push;
                    moved = true;
                }
            }
        }
    }
}
function resolveGoatCollisions() {
    const movement = TUNING.movement;
    const rad = movement.goatRadius;
    collidePairs(BOTS, BOTS.length, goat.px, goat.pz, rad, rad * movement.modelScale);
}
function goatMinGap() {
    let best = 1e9;
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        let dx = b.x - goat.px;
        let dz = b.z - goat.pz;
        let d = Math.sqrt(dx * dx + dz * dz) -
            TUNING.movement.goatRadius * (TUNING.movement.modelScale + b.spec.scale);
        if (d < best) best = d;
        for (let j = i + 1; j < BOTS.length; j++) {
            const c = BOTS[j];
            dx = c.x - b.x;
            dz = c.z - b.z;
            d = Math.sqrt(dx * dx + dz * dz) - TUNING.movement.goatRadius * (b.spec.scale + c.spec.scale);
            if (d < best) best = d;
        }
    }
    return best;
}

// ---- the primitives ----------------------------------------------------------
for (let i = 0; i < 18; i++) {
    const s = botSpec(i);
    console.log('P ' + i + ' ' + s.scale + ' ' + s.bold + ' ' + s.lazy + ' ' +
        s.coat[0] + ' ' + s.coat[1] + ' ' + s.coat[2] + ' ' + s.name);
}
// `botRngState` itself rather than `botRnd()`: the draw is the state divided by 2**32,
// and the embedded engine prints a double to fewer digits than it holds -- so comparing
// the divided value compares a *string*, which is the lesson `meadow.gd` `cell_hash`
// records about Godot's float32 vectors. The draw is taken, then the state read.
for (let i = 0; i < 40; i++) { botRnd(); console.log('R ' + i + ' ' + botRngState); }
// `weather.js` `sceneUseSeed`: the bots' stream is the *second* of five draws. The
// step after it is what the port can read -- its stream is private and the only way to
// see it is to draw from it -- so the gate compares the *first draw the herd makes*.
const SEEDS = __SEEDS__;
for (const seed of SEEDS) {
    let s = (seed | 0) || 1;
    const next = function () {
        s ^= s << 13; s >>>= 0;
        s ^= s >>> 17;
        s ^= s << 5; s >>>= 0;
        return s;
    };
    next();
    s = next() || 1;
    s ^= s << 13; s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5; s >>>= 0;
    console.log('S ' + seed + ' ' + s);
}
for (const role in CLIPS) {
    for (let i = 0; i < CLIPS[role].length; i++) {
        console.log('C ' + role + ' ' + i + ' ' + CLIPS[role][i][0] + ' ' + CLIPS[role][i][1]);
    }
}

// ---- the tape ----------------------------------------------------------------
const TAPE = __TAPE__;
const DT = 1 / 60;
// The draw check above spent the shared stream, so the herd's own run starts over.
botRngState = 0x2545f491;
for (let i = 0; i < TUNING.herd.count; i++) botAdd(i);
let frame = 0;
for (let s = 0; s < TAPE.length; s++) {
    const seg = TAPE[s];
    for (let f = 0; f < seg.frames; f++) {
        goat.px = seg.gx;
        goat.pz = seg.gz;
        rainAmount = seg.rain;
        windSway = seg.wind;
        if (f === 0) {
            if (seg.event === "fling") startBotFling(BOTS[seg.bot], seg.vx, seg.vz, seg.vy);
            else if (seg.event === "kill") botDie(BOTS[seg.bot]);
        }
        updateBots(DT);
        for (let b = 0; b < BOTS.length; b++) {
            if (BOTS[b].mode === "eat") STATS.eat += 1;
            else if (BOTS[b].mode === "sleep") STATS.sleep += 1;
            else if (BOTS[b].mode === "jump") STATS.jump += 1;
            else if (BOTS[b].mode === "flung") STATS.flung += 1;
            else if (BOTS[b].mode === "dead") STATS.dead += 1;
        }
        resolveGoatCollisions();
        for (let b = 0; b < BOTS.length; b++) {
            const bot = BOTS[b];
            const role = botRole(bot);
            const info = clipAt(role, bot.var[role]);
            console.log('B ' + frame + ' ' + b + ' ' + bot.x + ' ' + bot.z + ' ' + bot.yaw +
                ' ' + bot.phase + ' ' + bot.timer + ' ' + bot.mode + ' ' + bot.satiety + ' ' +
                bot.health + ' ' + (info ? info.name : "") + ' ' + bot.py);
        }
        console.log('G ' + frame + ' ' + goatMinGap() + ' ' + botBellyMax + ' ' + botGrazeWalks);
        frame += 1;
    }
}
console.log('T ' + STATS.eat + ' ' + STATS.sleep + ' ' + STATS.jump + ' ' + STATS.flung +
    ' ' + STATS.dead + ' ' + STATS.trapped + ' ' + STATS.wakes);
console.log('F ' + frame);
"""

## The tape, as segments: `frames` at a time, with the goat parked at `(gx, gz)` and the
## weather held at `rain`/`wind`, and an optional `event` fired before the segment's first
## frame. It is built to cross every edge the machine has, and it is *long* because the
## herd's own decisions are stochastic: a doze is one `botRnd` in ten inside a branch that
## is itself one draw in two, so a tape short enough to be cheap is a tape that runs the
## whole distance without anybody lying down.
##
##   * the spawn, the first actions, a grazing walk and a bite (frames 0-660) -- the herd
##     feeding itself, on the bowl;
##   * a shower, which slows the bots and which the doze test reads (660-1380);
##   * a **fling** -- bot 1 thrown by a blast -- and a **kill** -- bot 3, which is left for
##     `herd.deathLinger` and then gets up somewhere else;
##   * the goat parked at five points, three of them off the bowl, so the push-apart has
##     both the player and other bots to separate;
##   * the goat taken **far north** twice, which walks the water line south over the herd
##     and back -- that is the only way the *wake* is reachable, since a bot never dozes in
##     water and a fixed lake can never catch one asleep. The latitude is not free: the line
##     is the goat's own `z` less sixteen, so 44 puts it at 28, north of every bot that has
##     been standing where the herd was while the goat walked away.
##   * a last downpour, to leave the tape on the rain's own branch.
##
## There is no `regrowMin` ceiling on the length: the gate never runs the meadow's
## countdown on either side, so no tuft comes back and the eaten set only grows -- which is
## the same set on both sides, because both eat the same cells in the same order.
const TAPE := [
	{"frames": 360, "gx": 0.0, "gz": 0.0, "rain": 0.0, "wind": 0.0},
	{"frames": 300, "gx": 4.0, "gz": 1.0, "rain": 0.0, "wind": 0.0},
	{"frames": 420, "gx": 4.0, "gz": 4.0, "rain": 0.5, "wind": 1.1},
	{"frames": 300, "gx": -2.0, "gz": 3.0, "rain": 0.5, "wind": 1.1,
		"event": "fling", "bot": 1, "vx": 1.5, "vz": -0.5, "vy": 6.0},
	{"frames": 420, "gx": -3.0, "gz": 2.0, "rain": 0.0, "wind": 0.3},
	{"frames": 420, "gx": 0.0, "gz": 0.0, "rain": 0.0, "wind": 0.0,
		"event": "kill", "bot": 3},
	{"frames": 360, "gx": 0.0, "gz": 0.0, "rain": 0.8, "wind": 1.5},
	{"frames": 300, "gx": 0.0, "gz": 44.0, "rain": 0.8, "wind": 1.5},
	{"frames": 300, "gx": 0.0, "gz": 0.0, "rain": 0.0, "wind": 0.0},
	{"frames": 300, "gx": 0.0, "gz": 44.0, "rain": 0.0, "wind": 0.0},
	{"frames": 300, "gx": 0.0, "gz": 0.0, "rain": 0.0, "wind": 0.0},
]

## Seeds for the `sceneUseSeed` check: a positive one, the offline constant itself, a
## negative one (where `| 0` and the `|| 1` guard both have to be right) and zero.
const SEEDS := [1234, 0x2545f491, -77, 0]

## The frame step the tape is run at, matching `DT` in the oracle.
const DT := 1.0 / 60.0

## The tolerance on every compared field. Positions accumulate 2100 frames of `cos`,
## `sin`, `atan2` and `sqrt` on two engines whose libm is not the same libm, so the claim
## is that the same script produces the same herd and not that the bits match: a nanometre
## after thirty-five seconds is four orders above one ULP and eleven below a millimetre.
## `verify_goat.gd` makes the same claim against the same engines at the same tolerance.
const TOLERANCE := 1e-9

## Overlap left after a collision pass is allowed this much slop: the push-apart solves to
## the last bit of a double, and re-measuring it re-rounds.
const GAP_TOLERANCE := 1e-9

## The goat under test, kept on the gate itself as well as on the herd: the water seam is
## the goat's own latitude, and a `Callable` takes no extra arguments.
var _goat: PlayerGoat

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	# The goat, for the model's clips and for the herd to orbit. It is never stepped: the
	# tape *parks* it, so its own state machine is `verify_goat.gd`'s business.
	var goat := PlayerGoat.new()
	root.add_child(goat)
	goat.ready_up()
	_goat = goat
	if goat.clip_length("walk") <= 0.0:
		print("FAIL: the goat has no walk clip - the model did not load")
		quit(1)
		return

	# The clips, as `player_goat.gd` reads them: `{ role: [[name, length], ...] }`. This
	# is what both sides pose from, and it is also what `bots.gd`'s own role index is
	# checked against below -- two readers of one model, not two copies of a rule.
	var clips := {}
	for role: String in PlayerGoat.ROLES:
		var names: PackedStringArray = goat.clip_names(role)
		var lengths: Array = goat.clip_durations(role)
		var entries: Array = []
		for k in names.size():
			entries.append([String(names[k]), float(lengths[k])])
		clips[role] = entries

	# The herd under test, and the seams both it and the oracle are handed.
	var bots := Bots.new()
	root.add_child(bots)
	bots.goat = goat
	bots.meadow = Meadow.new()
	bots.trap = Callable(self, "_stub_trap")
	bots.armed = Callable(self, "_stub_armed")
	bots.in_water = Callable(self, "_stub_in_water")
	# The herd is built *before* anything reads it: the rig is where the clips by role come
	# from, and the spawn is the first thing either side does to its stream.
	bots.set_herd_size(Bots.COUNT)
	if bots.count() != Bots.COUNT:
		print("FAIL: the herd is %d goat(s), not %d" % [bots.count(), Bots.COUNT])
		quit(1)
		return

	var source: String = JS.replace("__CLIPS__", JSON.stringify(clips)) \
		.replace("__TAPE__", JSON.stringify(TAPE)) \
		.replace("__SEEDS__", JSON.stringify(SEEDS))
	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	var answers: PackedStringArray = host.call("poll_lines")
	var specs := {}
	var rolls := {}
	var streams := {}
	var oracle_clips := {}
	var oracle_bots := {}
	var oracle_globals := {}
	var coverage := {}
	var frames := 0
	for line in answers:
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log P ") and parts.size() >= 10:
			# `name` is the last field and may hold a space ("tan kid").
			specs[int(parts[2])] = {
				"scale": float(parts[3]), "bold": float(parts[4]), "lazy": float(parts[5]),
				"coat": [int(parts[6]), int(parts[7]), int(parts[8])],
				"name": " ".join(parts.slice(9)),
			}
		elif line.begins_with("log R ") and parts.size() == 4:
			rolls[int(parts[2])] = int(parts[3])
		elif line.begins_with("log S ") and parts.size() == 4:
			streams[int(parts[2])] = int(parts[3])
		elif line.begins_with("log C ") and parts.size() == 6:
			var role: String = parts[2]
			if not oracle_clips.has(role):
				oracle_clips[role] = []
			(oracle_clips[role] as Array).append([parts[4], float(parts[5])])
		elif line.begins_with("log B ") and parts.size() == 14:
			# `log B <frame> <bot> <x> <z> <yaw> <phase> <timer> <mode> <satiety>
			# <health> <clip> <py>` -- `parts[0]` is the `log`, so the payload starts at
			# one. Keyed by *bot*, in frame order, which is how the comparison reads it.
			var bot_at: int = int(parts[3])
			if not oracle_bots.has(bot_at):
				oracle_bots[bot_at] = []
			(oracle_bots[bot_at] as Array).append(parts)
		elif line.begins_with("log G ") and parts.size() == 6:
			oracle_globals[int(parts[2])] = [float(parts[3]), float(parts[4]), int(parts[5])]
		elif line.begins_with("log T ") and parts.size() == 9:
			coverage = {
				"eat": int(parts[2]), "sleep": int(parts[3]), "jump": int(parts[4]),
				"flung": int(parts[5]), "dead": int(parts[6]), "trapped": int(parts[7]),
				"wakes": int(parts[8]),
			}
		elif line.begins_with("log F ") and parts.size() == 3:
			frames = int(parts[2])
	print("oracle answered ", frames, " frame(s), ", oracle_bots.size(), " bot(s), ",
		oracle_clips.size(), " role(s)")

	if frames != _total_frames():
		failures.append("the oracle ran %d frame(s) and the tape is %d"
			% [frames, _total_frames()])

	# 1. The primitives.
	var spec_failures := 0
	var first_spec_failure := ""
	for i in 18:
		var wanted: Dictionary = specs.get(i, {})
		if wanted.is_empty():
			continue
		var got: Dictionary = bots.spec_of(i)
		var got_coat: Array = got["coat"]
		var wanted_coat: Array = wanted["coat"]
		if absf(float(got["scale"]) - float(wanted["scale"])) > TOLERANCE \
				or absf(float(got["bold"]) - float(wanted["bold"])) > TOLERANCE \
				or absf(float(got["lazy"]) - float(wanted["lazy"])) > TOLERANCE \
				or int(got_coat[0]) != int(wanted_coat[0]) \
				or int(got_coat[1]) != int(wanted_coat[1]) \
				or int(got_coat[2]) != int(wanted_coat[2]) \
				or String(got["name"]) != String(wanted["name"]):
			spec_failures += 1
			if first_spec_failure == "":
				first_spec_failure = "spec %d: scene %s, port %s" % [i, wanted, got]
	print("botSpec: %d spec(s), %d mismatch(es)" % [specs.size(), spec_failures])
	if first_spec_failure != "":
		print("  first: ", first_spec_failure)

	# The draws themselves, on a herd that is not the tape's -- `bot_rnd` mutates the
	# stream, so the tape's herd must not have spent any of it. The comparison is on the
	# *state*, recovered exactly from the draw, because the oracle can only hand back the
	# decimal the embedded engine printed and that is fewer digits than the double holds.
	var probe := Bots.new()
	var roll_mismatches := 0
	var first_roll := ""
	for i in 40:
		var got: int = int(round(probe.bot_rnd() * 4294967296.0))
		var wanted: int = int(rolls.get(i, 0))
		if got != wanted:
			roll_mismatches += 1
			if first_roll == "":
				first_roll = "draw %d: scene %d, port %d" % [i, wanted, got]
	print("botRnd: %d draw(s), %d mismatch(es)" % [rolls.size(), roll_mismatches])
	if first_roll != "":
		print("  first: ", first_roll)

	var stream_failures := 0
	var first_stream := ""
	for seed: int in streams:
		probe.use_seed(seed)
		var got: int = int(round(probe.bot_rnd() * 4294967296.0))
		var wanted: int = int(streams[seed])
		if got != wanted:
			stream_failures += 1
			if first_stream == "":
				first_stream = "seed %d: scene %d, port %d" % [seed, wanted, got]
	print("use_seed: %d seed(s), %d mismatch(es)" % [streams.size(), stream_failures])
	if first_stream != "":
		print("  first: ", first_stream)
	probe.free()

	# The role index, against the same table the oracle was handed -- and the *lengths* with
	# it, because a length is a rule: it is what a gait's speed and the loop's phase advance
	# are divided by, so a table that is right in name and wrong in duration drifts.
	var clip_failures := 0
	var duration_worst := 0.0
	var duration_first := ""
	for role: String in oracle_clips:
		var wanted: Array = oracle_clips[role]
		var got: PackedStringArray = bots.clip_names(role)
		if got.size() != wanted.size():
			clip_failures += 1
			print("  role %s: scene has %d clip(s), port %d" % [role, wanted.size(), got.size()])
			continue
		for k in wanted.size():
			if String(wanted[k][0]) != String(got[k]):
				clip_failures += 1
				print("  role %s clip %d: scene %s, port %s"
					% [role, k, String(wanted[k][0]), String(got[k])])
			var difference: float = absf(bots.clip_length(role, k) - float(wanted[k][1]))
			if difference > duration_worst:
				duration_worst = difference
			if difference > TOLERANCE and duration_first == "":
				duration_first = "%s clip %d: scene %.17f, port %.17f" % [
					role, k, float(wanted[k][1]), bots.clip_length(role, k)]
	print("clips by role: %d role(s), %d mismatch(es)" % [oracle_clips.size(), clip_failures])
	print("clip durations: worst %.17f" % duration_worst)
	if duration_first != "":
		print("  first: ", duration_first)

	# 2. The tape.
	var compared := 0
	var worst := 0.0
	var worst_at := ""
	var field_mismatches := 0
	var first_field_mismatch := ""
	var mode_mismatches := 0
	var first_mode_mismatch := ""
	var clip_mismatches := 0
	var first_clip_mismatch := ""
	var global_worst := 0.0
	var global_mismatches := 0
	var first_global_mismatch := ""
	var overlapping := 0
	var pushed := 0
	var wakes := 0
	var first_parts: PackedStringArray = PackedStringArray()
	var first_state: Dictionary = {}
	var previous_modes: Array[String] = []
	var previous_x: Array[float] = []
	var previous_z: Array[float] = []
	var boundary_sleepers: Array = []
	for i in Bots.COUNT:
		previous_modes.append("")
		previous_x.append(0.0)
		previous_z.append(0.0)
	var frame := 0
	var mode_frames := {"eat": 0, "sleep": 0, "jump": 0, "flung": 0, "dead": 0}
	for segment: Dictionary in TAPE:
		var rain: float = float(segment["rain"])
		var wind: float = float(segment["wind"])
		for f in int(segment["frames"]):
			if f == 0:
				var asleep := 0
				var lowest := 9999.0
				for i in bots.count():
					if previous_modes[i] == "sleep":
						asleep += 1
						lowest = minf(lowest, previous_z[i])
				boundary_sleepers.append([segment.get("gz", 0.0), asleep, lowest])
			goat.px = float(segment["gx"])
			goat.pz = float(segment["gz"])
			if f == 0 and segment.has("event"):
				var bot: int = int(segment["bot"])
				if String(segment["event"]) == "fling":
					bots.fling_at(bot, float(segment["vx"]), float(segment["vz"]),
						float(segment["vy"]))
				else:
					bots.kill_at(bot)
			bots.update(DT, {"rain_amount": rain, "wind_sway": wind})
			# A sleep broken by the water: the bot's mode *last* frame, and the water where it
			# stood then. The gate reads it from the same seam the herd does, so this is a
			# count of the rule firing rather than a second implementation of it.
			for i in bots.count():
				if previous_modes[i] == "sleep" \
						and _stub_in_water(previous_x[i], previous_z[i]):
					wakes += 1
			# Whether this frame's push-apart had anything to do, which is the only way
			# to tell a collision rule that holds from a herd that never touched.
			var before: Array = []
			for i in bots.count():
				var state: Dictionary = bots.state(i)
				before.append([float(state["x"]), float(state["z"])])
			bots.resolve_collisions()
			# No overlap may survive a pass, and a pass that had something to separate is
			# the only evidence that the rule is doing anything at all.
			var gap: float = bots.min_gap()
			if gap < -GAP_TOLERANCE:
				overlapping += 1
			for i in bots.count():
				var state: Dictionary = bots.state(i)
				if absf(float(state["x"]) - float((before[i] as Array)[0])) > 0.0 \
						or absf(float(state["z"]) - float((before[i] as Array)[1])) > 0.0:
					pushed += 1
					break
			for i in bots.count():
				var state: Dictionary = bots.state(i)
				var bot_lines: Variant = oracle_bots.get(i, [])
				if not (bot_lines is Array) or frame >= (bot_lines as Array).size():
					continue
				var parts: PackedStringArray = (bot_lines as Array)[frame]
				var wanted: Array[float] = [
					float(parts[4]), float(parts[5]), float(parts[6]), float(parts[7]),
					float(parts[8]), float(parts[10]), float(parts[11]), float(parts[13]),
				]
				var got: Array[float] = [
					float(state["x"]), float(state["z"]), float(state["yaw"]),
					float(state["phase"]), float(state["timer"]), float(state["satiety"]),
					float(state["health"]), float(state["py"]),
				]
				for k in wanted.size():
					var difference: float = absf(got[k] - wanted[k])
					compared += 1
					if difference > worst:
						worst = difference
						worst_at = "frame %d bot %d field %d: scene %.17f, port %.17f" % [
							frame, i, k, wanted[k], got[k]]
					if difference > TOLERANCE:
						field_mismatches += 1
						if first_field_mismatch == "":
							first_field_mismatch = \
								"frame %d bot %d field %d: scene %.17f, port %.17f" % [
									frame, i, k, wanted[k], got[k]]
							first_parts = parts
							first_state = state.duplicate()
				if String(state["mode"]) != String(parts[9]):
					mode_mismatches += 1
					if first_mode_mismatch == "":
						first_mode_mismatch = "frame %d bot %d: scene %s, port %s" % [
							frame, i, String(parts[9]), String(state["mode"])]
				var mode: String = String(state["mode"])
				if mode_frames.has(mode):
					mode_frames[mode] = int(mode_frames[mode]) + 1
				if String(state["clip"]) != String(parts[12]):
					clip_mismatches += 1
					if first_clip_mismatch == "":
						first_clip_mismatch = "frame %d bot %d: scene %s, port %s" % [
							frame, i, String(parts[12]), String(state["clip"])]
			for i in bots.count():
				var state: Dictionary = bots.state(i)
				previous_modes[i] = String(state["mode"])
				previous_x[i] = float(state["x"])
				previous_z[i] = float(state["z"])
			var wanted_global: Variant = oracle_globals.get(frame, null)
			if wanted_global is Array:
				var got_global: Array[float] = [
					bots.min_gap(), bots.belly_max, float(bots.graze_walks)]
				for k in 3:
					var difference: float = absf(got_global[k] - float((wanted_global as Array)[k]))
					compared += 1
					if difference > global_worst:
						global_worst = difference
					if difference > TOLERANCE:
						global_mismatches += 1
						if first_global_mismatch == "":
							first_global_mismatch = \
								"frame %d field %d: scene %.17f, port %.17f" % [
									frame, k, float((wanted_global as Array)[k]), got_global[k]]
			frame += 1

	print("tape: %d frame(s), %d value(s) compared" % [frame, compared])
	print("largest disagreement: %.17f (tolerance %.17f)" % [worst, TOLERANCE])
	if worst_at != "":
		print("  worst at ", worst_at)
	print("field mismatches: ", field_mismatches)
	if first_field_mismatch != "":
		print("  first: ", first_field_mismatch)
		print("    scene line: ", first_parts)
		print("    port state: ", first_state)
	print("mode mismatches: ", mode_mismatches)
	if first_mode_mismatch != "":
		print("  first: ", first_mode_mismatch)
	print("clip mismatches: ", clip_mismatches)
	if first_clip_mismatch != "":
		print("  first: ", first_clip_mismatch)
	print("herd values: %d mismatch(es), worst %.17f" % [global_mismatches, global_worst])
	if first_global_mismatch != "":
		print("  first: ", first_global_mismatch)

	# 3. The collision, and 4. the coverage. Both are claims about the *tape* rather than
	# about the port -- a gate whose herd never touched and never dozed would pass while
	# checking less than it says it does.
	print("push-apart: %d frame(s) with something to separate, %d frame(s) overlapping after"
		% [pushed, overlapping])
	print("modes: eat %d, sleep %d, jump %d, flung %d, dead %d frame(s)"
		% [mode_frames["eat"], mode_frames["sleep"], mode_frames["jump"],
			mode_frames["flung"], mode_frames["dead"]])
	print("coverage: %s, and the gate counted %d wake(s)" % [coverage, wakes])
	if wakes == 0:
		# The one coverage claim the *tape* can get wrong for its own reasons: a wake needs a
		# bot asleep at the moment the water line moves, so this is the report a maintainer
		# needs to see that the tape is at fault and not the herd.
		for boundary: Array in boundary_sleepers:
			print("  segment at gz %s: %d asleep, southmost %s"
				% [boundary[0], boundary[1], boundary[2]])

	for check: Dictionary in _coverage_checks(mode_frames, coverage, wakes):
		if not bool(check["ok"]):
			failures.append(String(check["why"]))

	if frames != _total_frames():
		failures.append("the oracle ran %d frame(s), expected %d" % [frames, _total_frames()])
	if spec_failures != 0:
		failures.append("botSpec mismatched in %d place(s)" % spec_failures)
	if specs.size() != 18:
		failures.append("the oracle answered %d botSpec(s), expected 18" % specs.size())
	if roll_mismatches != 0:
		failures.append("botRnd differs in %d of %d draw(s)" % [roll_mismatches, rolls.size()])
	if rolls.size() != 40:
		failures.append("the oracle answered %d botRnd draw(s), expected 40" % rolls.size())
	if stream_failures != 0:
		failures.append("use_seed differs for %d seed(s)" % stream_failures)
	if streams.size() != SEEDS.size():
		failures.append("the oracle answered %d seed(s), expected %d"
			% [streams.size(), SEEDS.size()])
	if clip_failures != 0:
		failures.append("the role index differs from the loaded model in %d place(s)"
			% clip_failures)
	if oracle_bots.size() != Bots.COUNT:
		failures.append("the oracle answered %d bot(s), expected %d"
			% [oracle_bots.size(), Bots.COUNT])
	if field_mismatches != 0:
		failures.append("the tape disagrees in %d of %d value(s)" % [field_mismatches, compared])
	if worst > TOLERANCE:
		failures.append("the largest disagreement is %f (limit %f)" % [worst, TOLERANCE])
	if mode_mismatches != 0:
		failures.append("the herd is in the wrong mode %d time(s)" % mode_mismatches)
	if clip_mismatches != 0:
		failures.append("the herd plays the wrong clip %d time(s)" % clip_mismatches)
	if global_mismatches != 0:
		failures.append("the herd's own values disagree %d time(s)" % global_mismatches)
	if overlapping != 0:
		failures.append("goats overlap after the push-apart in %d frame(s)" % overlapping)
	if pushed == 0:
		failures.append("the push-apart never had two goats to separate")

	host.free()

	if failures.is_empty():
		print("OK: the GDScript herd is the scene's herd, and it feeds itself")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

## The tape's total frame count, which the oracle is held to.
func _total_frames() -> int:
	var total := 0
	for segment: Dictionary in TAPE:
		total += int(segment["frames"])
	return total

## Whether the tape exercised what it claims to. Each entry is a claim about coverage, and
## a claim that is not met is a gate that is quieter than it looks.
func _coverage_checks(mode_frames: Dictionary, coverage: Dictionary, wakes: int) -> Array:
	var checks: Array = []
	var wanted: Dictionary = {
		"eat": "the tape never let the herd eat",
		"sleep": "the tape never let a bot doze off",
		"jump": "the tape never caught a bot mid-zoomies",
		"flung": "the tape never threw a bot",
		"dead": "the tape never killed a bot",
	}
	for mode: String in wanted:
		checks.append({
			"ok": int(mode_frames.get(mode, 0)) > 0,
			"why": String(wanted[mode]),
		})
	checks.append({
		"ok": int(coverage.get("trapped", 0)) > 0,
		"why": "the tape never bit into a trapped tuft",
	})
	checks.append({
		"ok": wakes > 0 and wakes == int(coverage.get("wakes", -1)),
		"why": "the tape never let the water reach a sleeping bot, or the gate and the herd disagree about how often it did",
	})
	return checks

## The trap stub, `explosions.js`'s `trapAt` in shape and this gate's in fact: the tuft in
## a cell is trapped for one cell in three. The devices' own derivation is
## `verify_devices.gd`'s, and the herd only needs *a* trap to bite.
func _stub_trap(cx: int, cz: int, _x: float, _z: float) -> bool:
	return (cx * 7 + cz * 13) % 3 == 0

## The armed-mine stub, `mine_armed`'s shape: half the cells, so a respawn's eight tries
## are actually spent rather than always landing on the first.
func _stub_armed(cx: int, cz: int) -> bool:
	return (cx + cz) % 2 == 0

## The water stub, `Water.in_water`'s shape: the ground more than sixteen metres south
## of the player is flooded. It has to be the *goat's own latitude* rather than a fixed
## lake, because the scene has two water rules about a sleep -- the doze a bot is refused
## and the one the rain ends -- and a lake that never moves can only ever exercise the
## first: a bot cannot doze into one. Parking the goat far north walks the line south over
## the herd, which is what wakes anybody already lying down.
##
## It stands in for `waterInWater` -- the HUD's own line, `depthAt >= 0.01` -- and a *stub*
## rather than that rule because the herd's own gate is about what the herd does with the
## answer. The rule itself is `verify_water_wake.gd`'s, and so is the difference between it
## and `waterSubmergedAt`, which is the grass cull's and not the sleep rule's.
func _stub_in_water(x: float, z: float) -> bool:
	return z < _goat.pz - 16.0

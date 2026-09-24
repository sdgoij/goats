// Each bot owns its own model handle. That is not wasteful book-keeping: the pose
// lives in the model -- in the meshes a CPU-skinning build deforms, in the bone
// matrices a `gpu-skinning` build uploads -- so two goats can only hold different
// poses if they have different models. The handles also let every bot carry its own
// procedural fleece texture applied to its material's diffuse map.
//
// The bots roam on a small state machine -- graze, stroll, trot, occasionally
// sprint, rarely doze -- with per-bot size and temperament. They wander around
// the player and are steered home once they drift too far, so the herd stays
// near without any explicit flocking.
// ---- bot herd ------------------------------------------------------------

// How far a bot will look for grass to walk to when it decides to graze.
const GRAZE_SEEK_RANGE = 12;

// Coat colour (for the procedural fleece), body scale, and temperament live in
// `TUNING.herd.spec` (core.js). `bold` scales a bot's cruising speed; `lazy`
// biases it toward standing still.

const BOTS = [];
const BOT_TEX = [];

// A private PRNG. The bots must not touch `rnd()` (weather.js): that stream is
// seeded and the harness asserts on the exact weather it produces, so drawing
// from it here would shift every later value.
let botRngState = 0x2545f491;
// Highest belly any bot has reached this run, and how many times a bot has set
// off to walk to a tuft; both logged every 240 frames so the harness can see the
// herd actually fed itself.
let botBellyMax = 0;
let botGrazeWalks = 0;
function botRnd() {
    botRngState ^= botRngState << 13;
    botRngState >>>= 0;
    botRngState ^= botRngState >>> 17;
    botRngState ^= botRngState << 5;
    botRngState >>>= 0;
    return botRngState / 4294967296;
}

// One mottled fleece texture per bot, tinted from its coat colour. Built in JS
// and handed to `rl.makeTexture` like the cloud and sky sprites.
function makeBotTextures() {
    if (typeof rl.makeTexture !== "function") return;
    const N = 64;
    for (let i = 0; i < TUNING.herd.spec.length; i++) {
        const c = TUNING.herd.spec[i].coat;
        let hex = "";
        for (let y = 0; y < N; y++) {
            for (let x = 0; x < N; x++) {
                const n = 0.55 * vnoise2(x * 0.17 + i * 13.7, y * 0.17 + i * 5.1) +
                    0.30 * vnoise2(x * 0.39 + i * 3.3, y * 0.39 + i * 9.9) +
                    0.15 * vnoise2(x * 0.86 + i, y * 0.86 + i * 2);
                const s = 0.62 + 0.70 * (n - 0.5);
                hex += HEX256[Math.round(clamp(c[0] * s, 0, 255))] +
                    HEX256[Math.round(clamp(c[1] * s, 0, 255))] +
                    HEX256[Math.round(clamp(c[2] * s, 0, 255))] + "ff";
            }
        }
        BOT_TEX.push(rl.makeTexture(N, N, hex));
    }
}

// The temperament/coat for bot `i`. Only six fleeces are hand-authored, so past
// the sixth the coats recycle with a bigger body -- enough variety up to the
// settings' ten goats.
function botSpec(i) {
    const base = TUNING.herd.spec[i % TUNING.herd.spec.length];
    const cycle = Math.floor(i / TUNING.herd.spec.length);
    if (cycle === 0) return base;
    return { coat: base.coat, scale: base.scale * (1 + 0.08 * cycle), bold: base.bold, lazy: base.lazy };
}

// Load one bot's model and give it its lit shader, shadow map and fleece.
function botAdd(i) {
    const handle = rl.loadModel(ASSET_SLOTS["model.goat"]);
    if (handle < 0) return false;
    const tex = BOT_TEX[i % BOT_TEX.length];
    modelLoaded(handle);
    // The lit program, or the unlit one where the `L` toggle has the lighting off:
    // a bot that appears while it is off (`herd.count` changes) must not come up
    // lit, which is what naming `litShader` unconditionally did.
    if (litShader >= 0) {
        rl.setModelShader(handle, modelShaderFor(handle, useLighting ? litShader : -1));
    }
    if (shadowColor >= 0) rl.setModelTexture(handle, SHADOW_MAP_INDEX, shadowColor);
    if (tex !== undefined && tex >= 0) rl.setModelTexture(handle, 0, tex);
    // A golden-angle spread rings the player evenly for any herd size.
    const a = i * 2.399963 + 0.3;
    const r = 6 + botRnd() * 14;
    const spawned = {
        model: handle,
        spec: botSpec(i),
        x: goat.px + Math.cos(a) * r,
        z: goat.pz + Math.sin(a) * r,
        yaw: a + Math.PI,
        phase: botRnd(),
        mode: "idle",
        timer: 0.5 + botRnd() * 3,
        tx: 0,
        tz: 0,
        zoom: 0,       // seconds of "zoomies" left while running
        jumpTime: 0,
        jumpDur: 1,
        jumpSpeed: 0,
        jumpCool: 0,
        eatTime: 0,    // seconds into the current meal
        eatDur: 1,
        eatCool: 0,    // seconds before this bot will graze again
        satiety: 0,    // 0..1, eases this bot's rain slowdown while it lasts
        graze: false,  // walking to a tuft to eat when it arrives
        // Blast damage (M19a). A bot takes the same curve the player does and, unlike
        // the player, is not spared by `blast.healthFloor` -- that floor is the
        // promise that *this* player's run cannot be ended by a mine. So a bot can be
        // killed, and the only thing that heals it is coming back: a bot's bruises are
        // the herd's memory of a minefield.
        health: TUNING.stats.max,
        deathTime: 0,  // seconds since it died
        deathDur: 1,   // seconds the death clip runs for (the pose's stretch)
        // The blast's arc (M19c), the player's shape (goat.js) in a bot's own
        // fields: `py` is the height above the ground it is drawn at, `flyY` the
        // absolute height the physics integrates, and `flyTime`/`flyFlight` the
        // clip's stretch.
        py: 0,
        flyTime: 0,
        flyY: 0,
        flyFlight: 1,
        flyVX: 0,
        flyVY: 0,
        flyVZ: 0,
        // Which clip variant this bot plays per role; -1 so the first cycle
        // lands on index 0, and walk/trot/run have only one clip each.
        var: { idle: -1, sleep: -1, jump: -1, eat: -1, walk: 0, trot: 0, run: 0, flung: -1, death: -1 },
    };
    BOTS.push(spawned);
    modEmit("spawn", modBotHandle(spawned));
    return true;
}

// Grow or shrink the herd to `n` (0..10). Every bot owns its model (CPU skinning),
// so a change loads or unloads individual goats at runtime.
function setHerdSize(n) {
    if (typeof rl.loadModel !== "function" || !haveModel) return;
    n = clamp(Math.round(n), 0, 10);
    while (BOTS.length > n) {
        const b = BOTS.pop();
        modEmit("despawn", modBotHandle(b));
        if (typeof rl.unloadModel === "function") rl.unloadModel(b.model);
    }
    while (BOTS.length < n) {
        if (!botAdd(BOTS.length)) break;
    }
}

function unloadBots() {
    for (let i = 0; i < BOTS.length; i++) modEmit("despawn", modBotHandle(BOTS[i]));
    if (typeof rl.unloadModel === "function") {
        for (let i = 0; i < BOTS.length; i++) rl.unloadModel(BOTS[i].model);
    }
    BOTS.length = 0;
}

// Point every bot's materials at `shader` (or restore the originals for -1),
// mirroring the player's `L` toggle. `modelShaderFor` maps the plain program the
// caller names to the skinned one a `gpu-skinning` build draws them with.
function setBotsShader(shader) {
    for (let i = 0; i < BOTS.length; i++) {
        rl.setModelShader(BOTS[i].model, modelShaderFor(BOTS[i].model, shader));
    }
}

// The clip role a bot is currently playing, falling back like the player does.
function botRole(b) {
    // Dead is not a gait: the bot plays the death clip, the one `clipRole` reaches
    // for, and with no such clip it falls through to the walk like the player does.
    if (b.mode === "dead" && CLIP.death) return "death";
    // A flung bot reads as the flung clip when the model has one and as the jump
    // when it does not -- the same fallback as `clipRole` and `peerRole`, since a
    // flung bot is posed from its arc's fraction rather than from a gait.
    if (b.mode === "flung") return CLIP.flung ? "flung" : "jump";
    if (b.mode === "jump" && CLIP.jump) return "jump";
    if (b.mode === "eat" && CLIP.eat) return "eat";
    if (b.mode === "sleep" && CLIP.sleep) return "sleep";
    if (b.mode === "run" && CLIP.run) return "run";
    if (b.mode === "trot" && CLIP.trot) return "trot";
    if (b.mode === "idle" && CLIP.idle) return "idle";
    return "walk";
}

// Take a blast's impulse (M19c), the player's `startFling` (goat.js) in a bot's
// fields. A second bang mid-arc adds to the arc rather than restarting it, so a
// chain through a minefield reads as one continuous throw.
function startBotFling(b, vx, vz, vy) {
    if (b.mode !== "flung") {
        b.flyY = terrainHeight(b.x, b.z);   // the arc starts where the bot is
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

// The fraction through a flung bot's arc, which is what the pose is stretched over
// and what a viewer rolls it by. A client has no arc of its own: `netApplyWorld`
// points `flyTime`/`flyFlight` at the fraction the host sent, exactly as it does for
// a jump, so this reads the same on both sides of the wire.
function botFlingProgress(b) {
    return Math.min(b.flyTime / b.flyFlight, 1);
}

// Whether a bot is over the ground rather than on it. A jump is airborne by mode
// (the clip's root motion does the hop, so there is no height to read) and a flung
// bot owns its own height. A landing is when this stops being true, which is what
// sets off a mine the bot comes down on.
function botAirborne(b) {
    return b.mode === "jump" || b.mode === "flung";
}

// A lethal bang (M19a). The blast that kills a bot does not also throw it -- that is
// the one place this differs from the player, whose arc and damage are applied
// together -- but a bot killed *in the air* keeps the arc it already had, so a chain
// on a flung bot drops a corpse rather than teleporting one to the ground. The
// timing, the clip and the pose are the player's `die()` and `clipRole` exactly.
function botDie(b) {
    b.health = 0;
    b.mode = "dead";
    b.deathTime = 0;
    b.graze = false;
    b.zoom = 0;
    const n = clipCount("death");
    if (n > 1) b.var.death = (b.var.death + 1) % n;
    const info = clipAt("death", b.var.death);
    // With no death clip there is nothing to stretch the fraction over (`botRole`
    // falls through to the walk, as the player's `clipRole` does), so any positive
    // number will do -- but it has to be one, because the pose divides by it.
    b.deathDur = info !== null && info !== undefined && info.duration > 0 ? info.duration : 1;
}

// Bring a dead bot back (M19a). The herd keeps the size the setting asks for, so a
// bot that dies is replaced by itself rather than by nothing: it gets up out of the
// way, facing the player, with a whole skin. Ground with no armed mine under it is
// preferred -- a bot that respawned onto one would be blown up before it took a
// step, which reads as a bug rather than as a minefield -- but eight tries is the
// whole of the search, and a dense field has no clean ground left to offer.
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

// Pick a new action: graze, stand and gaze, doze, or set off to a wander target,
// aimed back toward the player when the bot has drifted too far. Kept as one
// function rather than action + target helpers so the per-frame call depth stays
// shallow -- debug builds guard the native stack hard, and bots run every frame.

// Begin a meal: consume `t`, fill the belly, turn onto it and play an eat clip.
// Used both when grass is already under the nose and when a grazing walk arrives.
function botStartEat(b, t) {
    const n = clipCount("eat");
    if (n > 1) b.var.eat = (b.var.eat + 1) % n;
    const info = clipAt("eat", b.var.eat);
    consumeTuft(t);
    b.yaw = Math.atan2(-(t.z - b.z), t.x - b.x);
    // A trapped tuft is a bang for a bot too (explosions.js): the tuft is gone,
    // the belly gets nothing, and the herd is where that pays off -- everyone
    // sees a bot go up in the air.
    if (trapAt(t.cx, t.cz)) {
        tripDevice("trap", t.cx, t.cz, t.x, t.z, 0);
    } else {
        // The herd's meals get the second helping too (food.js `satedHeal`): a bot that
        // has grazed its belly full heals a little with every tuft after that, which is
        // the only way back from the bruises a minefield hands it.
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
    // Bots graze too. If a tuft is already under the nose they eat it now;
    // otherwise they walk to the nearest one and eat when they arrive (the
    // arrival check in `updateBots` reads the `graze` flag). The cooldown keeps
    // the herd from stripping the field bare.
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
            b.timer = 14;      // give up if the walk drags on
            b.zoom = 0;
            return;
        }
    }
    b.graze = false;
    const r = botRnd();
    if (r < 0.30 + 0.35 * b.spec.lazy) {
        // A bot does not doze in the water any more than the player's goat does (M20f′).
        // The roll is the same roll and the stream is untouched either way -- the same one
        // `botRnd` is spent on the mode and one on the timer, which is why the *timer* line
        // still asks `b.mode` rather than a second draw. Reading the table is fair here:
        // `net.js` has the host alone simulating the herd, so a client never takes this
        // branch (`netApplyWorld` hands it the host's modes).
        b.mode = botRnd() < 0.10 && !waterInWater(b.x, b.z) ? "sleep" : "idle";
        b.timer = b.mode === "sleep" ? 5 + botRnd() * 6 : 2 + botRnd() * 5;
        b.zoom = 0;
        // Rotate the variant so this bot does not always do the same clip.
        const n = clipCount(b.mode);
        if (n > 1) b.var[b.mode] = (b.var[b.mode] + 1) % n;
        return;
    }
    const s = botRnd();
    b.mode = s < 0.60 ? "walk" : s < 0.90 ? "trot" : "run";
    b.timer = 3 + botRnd() * 9;
    // A run is a "zoomies" burst: updateBots throws in the odd jump while it
    // lasts, which is what makes a running bot look like it has the zoomies.
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
            // Dead (M19a): the body lies where it fell, playing the death clip, and
            // nothing else happens to it -- no AI, no grazing, and no devices, since
            // a corpse does not set off a mine. The one thing a corpse still does is
            // fall: a bot killed mid-arc lands (the arc it had is the arc it keeps),
            // and the death clip plays on the way down. `herd.deathLinger` seconds
            // later `botRespawn` puts it back on its feet somewhere else.
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
        // ...and one the rain reaches gets up, for the same reason and in the same way the
        // player's goat does: `botNewAction` above is where a sleep is refused, and this is
        // where one that has already started ends. No draw is taken -- the timer is set to
        // zero, so the plan that follows is the ordinary one for this frame.
        if (b.mode === "sleep" && waterInWater(b.x, b.z)) {
            b.mode = "idle";
            b.timer = 0;
        }
        if (b.jumpCool > 0) b.jumpCool -= dt;
        if (b.eatCool > 0) b.eatCool -= dt;
        if (b.satiety > 0) b.satiety = Math.max(0, b.satiety - TUNING.food.satietyDecay * dt);
        if (b.satiety > botBellyMax) botBellyMax = b.satiety;

        if (b.mode === "flung") {
            // The arc (M19c), the player's exactly: an absolute height with `py`
            // derived from it, so a slope a bot crosses mid-air cannot drag it, and
            // the ground it actually meets that ends the flight. There is no AI
            // while it flies -- being thrown is the whole of it -- and a bot that
            // lands simply takes up its next idea.
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
            // Airborne: the jump clip's root motion does the hop, so this only
            // carries the bot forward along its heading.
            b.jumpTime += dt;
            b.x += Math.cos(b.yaw) * b.jumpSpeed * dt;
            b.z += -Math.sin(b.yaw) * b.jumpSpeed * dt;
            if (b.jumpTime >= b.jumpDur) {
                if (b.zoom > 0) {
                    b.mode = "run";        // still zooming: run on
                    b.jumpCool = 0.4 + botRnd() * 1.2;
                } else {
                    b.mode = "idle";
                    b.timer = 1.5 + botRnd() * 3;
                }
            }
        } else if (b.mode === "eat") {
            // A meal is one-shot: hold position, play it out, then move on.
            b.eatTime += dt;
            if (b.eatTime >= b.eatDur) {
                b.mode = "idle";
                b.timer = 1.5 + botRnd() * 3;
            }
        } else {
            // Speed for the current gait, from the same stride/duty the player uses.
            const role = botRole(b);
            const info = clipAt(role, b.var[role]);
            const gait = TUNING.gait[role];
            let spd = 0;
            if (b.mode !== "idle" && b.mode !== "sleep") {
                const base = (info !== null && info.duration > 0 && gait !== undefined)
                    ? gait.stride / (gait.duty * info.duration)
                    : (2 * V_STRIDE) / V_CYCLE;
                // Rain slows the bots too, each eased by its own belly (food.js),
                // so a herd that has been grazing keeps its pace in the wet.
                spd = base * (0.75 + 0.5 * b.spec.bold) * weatherSpeedFor(b.satiety);
            }

            if (spd > 0) {
                const dx = b.tx - b.x;
                const dz = b.tz - b.z;
                const d = Math.sqrt(dx * dx + dz * dz);
                // A grazing walk closes right in on its tuft; other targets stop short.
                const arrive = b.graze ? 0.7 : 1.6;
                if (d < arrive || b.timer <= 0) {
                    if (b.graze) {
                        // Arrived: eat whatever is under the nose now (the tuft
                        // may have been taken meanwhile), else give up.
                        b.graze = false;
                        const t = nearestTuft(b.x, b.z, TUNING.food.eatRange);
                        if (t !== null) botStartEat(b, t);
                        else {
                            b.mode = "idle";
                            b.timer = 1.5 + botRnd() * 3;
                        }
                    } else if (b.mode === "run" && b.zoom > 0) {
                        // Mid-zoomies: grab a fresh target and keep going.
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
                    // Steer toward the target (the goat faces local +X, so heading
                    // `yaw` moves along (cos, -sin) in the XZ plane).
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

            // Zoomies: while a run lasts, hop every second or so.
            if (b.mode === "run") {
                b.zoom -= dt;
                if (b.zoom > 0 && b.jumpCool <= 0 && spd > 0) {
                    b.mode = "jump";
                    const nj = clipCount("jump");
                    if (nj > 1) b.var.jump = (b.var.jump + 1) % nj;
                    const jinfo = clipAt("jump", b.var.jump);
                    b.jumpDur = jinfo !== null && jinfo !== undefined ? jinfo.duration : TUNING.jump.fallbackTime;
                    b.jumpTime = 0;
                    b.jumpSpeed = spd * 1.15;
                    b.jumpCool = 0.5 + botRnd() * 1.3;
                }
            }

            // Advance the looping clip (jumps pose themselves from jumpTime).
            if (b.mode !== "jump") {
                const cur = clipAt(role, b.var[role]);
                const dur = cur !== null && cur !== undefined && cur.duration > 0 ? cur.duration : V_CYCLE;
                b.phase = mod1(b.phase + dt / dur);
            }
        }

        // A hard backstop: if a bot ever gets really far, pull it back in.
        const px = b.x - goat.px;
        const pz = b.z - goat.pz;
        const far = Math.sqrt(px * px + pz * pz);
        if (far > 80) {
            b.x = goat.px + (px / far) * 80;
            b.z = goat.pz + (pz / far) * 80;
        }
    }
}

// Push apart any goats that overlap, so nobody can walk through anybody else.
// Bots yield fully to the player (it can shove them) and split the push evenly
// with each other. Runs after both the player and the bots have moved.
//
// Split in two on purpose: `collidePairs` touches nothing but its parameters,
// which is what lets this engine compile it -- a body that names a true global
// (this one read `TUNING` and called `Math.sqrt`) stays in the interpreter at
// roughly forty times the cost, which is the whole of the 0.49 ms this phase
// used to take. See PERF.md §7 for the measurements; the caller below is the
// hoisting half of that recipe and the `** 0.5` is the other half (`Math.sqrt`
// is a global read of `Math`).
function collidePairs(bots, count, gx, gz, rad, pr) {
    // Two relaxation passes: shoving a bot off the player can push it into another bot,
    // so a second pass settles the chain -- but only a pass that moved something can
    // have made a chain, and the herd spends most frames touching nobody. Measured:
    // this whole pass is 28 pair-iterations a frame in the quiet case and every
    // iteration costs this engine ~3.6 allocation boxes, so running the second one
    // unconditionally was paying twice for a case that only comes up on the frames the
    // goat walks into the herd. A chain still settles inside the frame it was made in.
    let moved = true;                       // the first pass always runs
    for (let pass = 0; pass < 2 && moved; pass++) {
        moved = false;
        for (let i = 0; i < count; i++) {
            const b = bots[i];
            const rr = pr + rad * b.spec.scale;
            const dx = b.x - gx;
            const dz = b.z - gz;
            const d2 = dx * dx + dz * dz;
            if (d2 < rr * rr) {
                if (d2 <= 1e-4) {
                    b.x = gx + rr;    // dead centre: shove it out sideways
                } else {
                    const d = d2 ** 0.5;
                    const push = (rr - d) / d;
                    b.x += dx * push;
                    b.z += dz * push;
                }
                if (b.timer > 0.6) b.timer = 0.6;   // re-think the plan soon
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

// Smallest gap between any two goats (negative means they overlap). The frame
// log reports it so the headless harness can assert collisions actually hold.
function goatMinGap() {
    let best = 1e9;
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        let dx = b.x - goat.px;
        let dz = b.z - goat.pz;
        let d = Math.sqrt(dx * dx + dz * dz) - TUNING.movement.goatRadius * (TUNING.movement.modelScale + b.spec.scale);
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

// Draw the herd. Bots outside the shadow map's box get a small contact blob so
// they stay grounded; inside the box the map shadow covers them instead.
function drawBots(tint) {
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        const dx = b.x - goat.px;
        const dz = b.z - goat.pz;
        if (dx * dx + dz * dz > shadowGrassCull2()) {
            rl.drawCube(b.x, terrainHeight(b.x, b.z) + 0.06, b.z,
                1.3 * b.spec.scale, 0.012, 1.75 * b.spec.scale, ambShadow);
        }
        const role = botRole(b);
        // One-shot roles (jump, eat, death, flung) pose from their own clock; the rest
        // loop. The death clip is the model's, so the fraction is real there; with no
        // such clip `botRole` has nothing to pose and the loop phase stands in.
        const pose = b.mode === "jump" ? Math.min(b.jumpTime / b.jumpDur, 1)
            : b.mode === "eat" ? Math.min(b.eatTime / b.eatDur, 1)
                : b.mode === "dead" && CLIP.death ? Math.min(b.deathTime / b.deathDur, 1)
                    : b.mode === "flung" ? botFlingProgress(b) : b.phase;
        poseModelOn(b.model, clipAt(role, b.var[role]), pose);
        // Draw directly (no `drawModelAt` wrapper) to keep the JS call depth
        // shallow -- the debug stack guard is tight.
        const y = terrainHeight(b.x, b.z) + groundOffset * b.spec.scale + b.py;
        if (b.mode === "flung") {
            // The roll is the placeholder's, on the same rule as the player's: with
            // no clip tumbling the bot, the scene turns it (`flingDraw`, model.js).
            const d = flingDraw(b.x, y, b.z, b.yaw, flingTumble(pose),
                TUNING.explosions.fling.pivot * b.spec.scale);
            rl.drawModelEx(b.model, d.x, d.y, d.z, d.ax, d.ay, d.az, d.deg,
                b.spec.scale, b.spec.scale, b.spec.scale, tint);
            continue;
        }
        rl.drawModelEx(b.model, b.x, y, b.z, 0, 1, 0, (b.yaw * 180) / Math.PI,
            b.spec.scale, b.spec.scale, b.spec.scale, tint);
    }
}

// Depth pass: draw the bots that fall inside the light's box. Called from
// `renderShadowMap` while the goat's own depth draw is set up.
// The herd in the depth pass. It does **not** pose: the model still carries the
// pose the previous frame's lit pass left in it -- the deformed mesh on a
// CPU-skinning build, the bone matrices on a `gpu-skinning` one -- and that deform
// is the most expensive thing this scene does per bot (on the CPU build),
// so posing twice per frame -- once here, once in `drawBots` -- was paying for
// the same work twice. A shadow map drawn from a pose one frame old is not
// something anyone can see.
function drawBotsShadow() {
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        const dx = b.x - goat.px;
        const dz = b.z - goat.pz;
        if (dx * dx + dz * dz > shadowGrassCull2()) continue;
        rl.setModelShader(b.model, modelShaderFor(b.model, depthShader));
        rl.setModelTexture(b.model, SHADOW_MAP_INDEX, -1);
        // No pose here, but the transform is free: a thrown bot is in the air in
        // the depth pass too (the roll comes from the fraction the pose already
        // reflects, so a client's mirrored bot rolls the same way).
        const y = terrainHeight(b.x, b.z) + groundOffset * b.spec.scale + b.py;
        if (b.mode === "flung") {
            const d = flingDraw(b.x, y, b.z, b.yaw, flingTumble(botFlingProgress(b)),
                TUNING.explosions.fling.pivot * b.spec.scale);
            rl.drawModelEx(b.model, d.x, d.y, d.z, d.ax, d.ay, d.az, d.deg,
                b.spec.scale, b.spec.scale, b.spec.scale, rl.WHITE);
        } else {
            rl.drawModelEx(b.model, b.x, y, b.z, 0, 1, 0, (b.yaw * 180) / Math.PI,
                b.spec.scale, b.spec.scale, b.spec.scale, rl.WHITE);
        }
        rl.setModelTexture(b.model, SHADOW_MAP_INDEX, shadowColor);
        rl.setModelShader(b.model, modelShaderFor(b.model, litShader));
    }
}

// The herd size is `TUNING.herd.count`, so the menu and the console write it
// through `tuningSet` and a mod retunes it the same way. Only resize once the
// world is live: before that the load steps read the count themselves.
tuningWatch("herd.count", function (path, value) {
    if (loaded) setHerdSize(value);
});

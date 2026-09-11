// Part 8/9 of the goat scene: the bot herd.
//
// Each bot owns its own model handle. That is not wasteful book-keeping: this is
// a CPU-skinning build, so `updateModelAnimation` deforms the vertices *inside
// the model's meshes*, which means two goats can only hold different poses if
// they have different models. The handles also let every bot carry its own
// procedural fleece texture applied to its material's diffuse map.
//
// The bots roam on a small state machine -- graze, stroll, trot, occasionally
// sprint, rarely doze -- with per-bot size and temperament. They wander around
// the player and are steered home once they drift too far, so the herd stays
// near without any explicit flocking.
// ---- bot herd ------------------------------------------------------------

const BOT_COUNT = 6;

// Coat colour (for the procedural fleece), body scale, and temperament.
// `bold` scales a bot's cruising speed; `lazy` biases it toward standing still.
const BOT_SPEC = [
    { coat: [196, 168, 128], scale: 0.80, bold: 0.95, lazy: 0.55, name: "tan kid" },
    { coat: [222, 216, 206], scale: 1.06, bold: 1.00, lazy: 0.50, name: "cream" },
    { coat: [116, 92, 70], scale: 1.22, bold: 0.70, lazy: 0.72, name: "big brown" },
    { coat: [156, 126, 92], scale: 0.94, bold: 1.18, lazy: 0.32, name: "lively" },
    { coat: [88, 90, 98], scale: 1.12, bold: 0.85, lazy: 0.62, name: "charcoal" },
    { coat: [208, 180, 142], scale: 0.74, bold: 1.05, lazy: 0.45, name: "small beige" },
];

const BOTS = [];
const BOT_TEX = [];

// A private PRNG. The bots must not touch `rnd()` (weather.js): that stream is
// seeded and the harness asserts on the exact weather it produces, so drawing
// from it here would shift every later value.
let botRngState = 0x2545f491;
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
    for (let i = 0; i < BOT_SPEC.length; i++) {
        const c = BOT_SPEC[i].coat;
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

// Load one model per bot and give it its lit shader, shadow map and fleece.
function loadBots() {
    if (typeof rl.loadModel !== "function" || !haveModel) return;
    for (let i = 0; i < BOT_SPEC.length; i++) {
        const handle = rl.loadModel(MODEL_PATH);
        if (handle < 0) continue;
        if (litShader >= 0) rl.setModelShader(handle, litShader);
        if (shadowColor >= 0) rl.setModelTexture(handle, SHADOW_MAP_INDEX, shadowColor);
        if (BOT_TEX[i] !== undefined && BOT_TEX[i] >= 0) rl.setModelTexture(handle, 0, BOT_TEX[i]);
        const a = (i / BOT_SPEC.length) * Math.PI * 2 + 0.3;
        const r = 6 + botRnd() * 14;
        BOTS.push({
            model: handle,
            spec: BOT_SPEC[i],
            x: goat.px + Math.cos(a) * r,
            z: goat.pz + Math.sin(a) * r,
            yaw: a + Math.PI,
            phase: botRnd(),
            mode: "idle",
            timer: 0.5 + botRnd() * 3,
            tx: 0,
            tz: 0,
        });
    }
    if (BOTS.length > 0) console.log("goat: " + BOTS.length + " bot goats");
}

function unloadBots() {
    if (typeof rl.unloadModel === "function") {
        for (let i = 0; i < BOTS.length; i++) rl.unloadModel(BOTS[i].model);
    }
    BOTS.length = 0;
}

// Point every bot's materials at `shader` (or restore the originals for -1),
// mirroring the player's `L` toggle.
function setBotsShader(shader) {
    for (let i = 0; i < BOTS.length; i++) rl.setModelShader(BOTS[i].model, shader);
}

// The clip role a bot is currently playing, falling back like the player does.
function botRole(b) {
    if (b.mode === "sleep" && CLIP.sleep) return "sleep";
    if (b.mode === "run" && CLIP.run) return "run";
    if (b.mode === "trot" && CLIP.trot) return "trot";
    if (b.mode === "idle" && CLIP.idle) return "idle";
    return "walk";
}

// Pick a new action: stand and gaze, graze, doze, or set off to a wander target,
// aimed back toward the player when the bot has drifted too far. Kept as one
// function rather than action + target helpers so the per-frame call depth stays
// shallow -- debug builds guard the native stack hard, and bots run every frame.
function botNewAction(b) {
    const r = botRnd();
    if (r < 0.30 + 0.35 * b.spec.lazy) {
        b.mode = botRnd() < 0.10 ? "sleep" : "idle";
        b.timer = b.mode === "sleep" ? 5 + botRnd() * 6 : 2 + botRnd() * 5;
        return;
    }
    const s = botRnd();
    b.mode = s < 0.68 ? "walk" : s < 0.92 ? "trot" : "run";
    b.timer = 3 + botRnd() * 9;
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
        b.timer -= dt;

        // Speed for the current gait, from the same stride/duty the player uses.
        let role = botRole(b);
        let info = CLIP[role];
        let spd = 0;
        if (b.mode !== "idle" && b.mode !== "sleep") {
            const g = GAIT[role];
            const base = (info !== null && info.duration > 0 && g !== undefined)
                ? g.stride / (g.duty * info.duration)
                : (2 * V_STRIDE) / V_CYCLE;
            spd = base * (0.75 + 0.5 * b.spec.bold);
        }

        if (spd > 0) {
            const dx = b.tx - b.x;
            const dz = b.tz - b.z;
            const d = Math.sqrt(dx * dx + dz * dz);
            if (d < 1.6 || b.timer <= 0) {
                b.mode = "idle";
                b.timer = 1.5 + botRnd() * 4;
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

        // Advance the clip (re-read the role in case the action just changed).
        role = botRole(b);
        info = CLIP[role];
        const dur = info !== null && info.duration > 0 ? info.duration : V_CYCLE;
        b.phase = mod1(b.phase + dt / dur);

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

// Draw the herd. Bots outside the shadow map's box get a small contact blob so
// they stay grounded; inside the box the map shadow covers them instead.
function drawBots(tint) {
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        const dx = b.x - goat.px;
        const dz = b.z - goat.pz;
        if (dx * dx + dz * dz > SHADOW_GRASS_CULL2) {
            rl.drawCube(b.x, 0.02, b.z, 1.3 * b.spec.scale, 0.012, 1.75 * b.spec.scale, ambShadow);
        }
        poseModelOn(b.model, botRole(b), b.phase);
        // Draw directly (no `drawModelAt` wrapper) to keep the JS call depth
        // shallow -- the debug stack guard is tight.
        rl.drawModelEx(b.model, b.x, groundOffset * b.spec.scale, b.z,
            0, 1, 0, (b.yaw * 180) / Math.PI,
            b.spec.scale, b.spec.scale, b.spec.scale, tint);
    }
}

// Depth pass: draw the bots that fall inside the light's box. Called from
// `renderShadowMap` while the goat's own depth draw is set up.
function drawBotsShadow() {
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        const dx = b.x - goat.px;
        const dz = b.z - goat.pz;
        if (dx * dx + dz * dz > SHADOW_GRASS_CULL2) continue;
        rl.setModelShader(b.model, depthShader);
        rl.setModelTexture(b.model, SHADOW_MAP_INDEX, -1);
        poseModelOn(b.model, botRole(b), b.phase);
        rl.drawModelEx(b.model, b.x, groundOffset * b.spec.scale, b.z,
            0, 1, 0, (b.yaw * 180) / Math.PI,
            b.spec.scale, b.spec.scale, b.spec.scale, rl.WHITE);
        rl.setModelTexture(b.model, SHADOW_MAP_INDEX, shadowColor);
        rl.setModelShader(b.model, litShader);
    }
}

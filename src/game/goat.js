// Part 10/11 of the goat scene: the gait state machine, HUD and frame loop.
// ---- gait state ----------------------------------------------------------

const goat = { px: 0, pz: 0, py: V_DROP, yaw: 0, phase: 0 };
let paused = false;
let mode = "idle";       // idle | walk | trot | run | jump | sleep | dead
let jumpTime = 0;        // seconds into the current jump
let eatTime = 0;         // seconds into the current meal
let jumpSpeed = 0;       // ground speed frozen at take-off
let jumpDir = 0;         // travel direction (-1/0/1) frozen at take-off
let sleepTime = 0;       // seconds slept since last awake
let deathTime = 0;       // seconds since the death started
let idleTimer = 0;       // seconds spent idle while exhausted
let lastMode = "idle";   // for cycling the player's idle animation variant
const stats = { health: MAX_STAT, energy: MAX_STAT };
let exhausted = false;
let xTex = -1;           // X-eye sprite texture (made after the window opens)
let moonTex = -1;        // procedural cratered moon disc
let glowTex = -1;        // radial sun/star glow
let camYaw = 0.7;
let camPitch = 0.42;
let camDist = 5.2;

// Filled in by `sceneInit`; the host owns the frame loop now (see below).
let screenW = 1;
let screenH = 1;
let sceneFrames = 0;

// Live gait read-outs, refreshed once per frame at `run()` depth. `drawHud`
// reads these rather than calling the helpers itself: in a debug build every
// extra JS activation costs ~160 KB of native stack, and the guard trips if the
// HUD's own frame nests a few more calls.
let curRole = "walk";
let curSpeed = 0;
let curClipName = "";
// Nearest edible tuft this frame, and whether it is close enough to eat; the
// HUD's action menu and the E handler read these.
let foodTarget = null;
let foodReady = false;

// Which clip role is driving the pose right now, falling back to the walk for
// any role the model does not provide.
function clipRole() {
    if (mode === "dead" && CLIP.death) return "death";
    if (mode === "sleep" && CLIP.sleep) return "sleep";
    if (mode === "eat" && CLIP.eat) return "eat";
    if (mode === "jump" && CLIP.jump) return "jump";
    if (mode === "run" && CLIP.run) return "run";
    if (mode === "trot" && CLIP.trot) return "trot";
    if (mode === "idle" && CLIP.idle) return "idle";
    return "walk";
}

function jumpDuration() {
    const info = playerClip("jump");
    return info !== null && info !== undefined ? info.duration : FALLBACK_JUMP_TIME;
}

// Seconds of an idle/walk/run loop (one full cycle), for phase advance.
function loopDuration() {
    const role = clipRole();
    const info = haveModel ? playerClip(role) : null;
    if (info !== null && info !== undefined) return info.duration;
    return V_CYCLE;
}

// Ground speed for the current gait, from the stride/duty above.
function groundSpeed() {
    if (mode === "sleep" || mode === "dead") return 0;
    let base;
    if (!haveModel) {
        let mult = 1;
        if (mode === "run") mult = FALLBACK_RUN_MULT;
        else if (mode === "trot") mult = FALLBACK_TROT_MULT;
        base = ((2 * V_STRIDE) / V_CYCLE) * mult;
    } else if (mode === "run" && CLIP.run) {
        base = runSpeed();
    } else if (mode === "trot" && CLIP.trot) {
        base = trotSpeed();
    } else {
        base = walkSpeed();
    }
    // Rain and wind slow the goat: it works harder for the same clip.
    return base * weatherSpeed;
}

function startJump(move, gait) {
    mode = "jump";
    cyclePlayerVariant("jump");
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
    jumpSpeed *= weatherSpeed;   // a wet goat does not jump as far
    stats.energy = Math.max(0, stats.energy - JUMP_ENERGY_COST);
    playBleat(0.9);
}

function startSleep() {
    mode = "sleep";
    cyclePlayerVariant("sleep");
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
    satiety = 0;          // a new life starts hungry
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
    drain *= weatherDrain;                            // ...and so does being soaked
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

// Build the X-eye sprite for the dead state, on a transparent field. Needs a
// live GL context. (Sleeping eyes use the model's real eyelids, so there is no
// closed-lid sprite any more.)
function makeEyeTextures() {
    let x = "";
    for (let y = 0; y < 8; y++) {
        for (let px = 0; px < 8; px++) {
            x += (Math.abs(px - y) <= 1 || Math.abs(px - (7 - y)) <= 1) ? "232323FF" : "00000000";
        }
    }
    xTex = rl.makeTexture(8, 8, x);
}

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
    // Only the dead state still uses a sprite; the sleeping goat's eyes are closed
    // by the GoatSleep clip's eyelid bones.
    if (!(mode === "dead" && xTex >= 0 && CLIP.death &&
        deathTime >= CLIP.death.duration * DEAD_EYE_FRACTION)) return;
    const eyes = DEATH_EYES;
    const size = 0.13;
    const c = Math.cos(goat.yaw);
    const s = Math.sin(goat.yaw);
    const py = goat.py + groundOffset;
    for (let i = 0; i < eyes.length; i++) {
        const wx = goat.px + eyes[i].x * c + eyes[i].z * s;
        const wz = goat.pz - eyes[i].x * s + eyes[i].z * c;
        rl.drawBillboard(xTex, wx, py + eyes[i].y, wz, size, rl.WHITE);
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
    else if (mode === "eat") state = "eating";
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
        "   sky " + (useSkyShader && skyShader >= 0 ? "shader" : "billboards") +
        "   audio " + (audioReady ? (muted ? "muted" : "on") : "off") +
        "   herd " + BOTS.length;
    rl.drawText("Slag goat  -  " + how, 10, 8, 18, rl.RAYWHITE);
    rl.drawText("W/S walk   CTRL trot   SHIFT run   SPACE jump   E eat   Z sleep   T time   L light   K shadow   B sky   M audio   A/D turn   P: pause   ESC: quit",
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
    rl.drawText("health " + Math.round(stats.health) + "   energy " + Math.round(stats.energy) +
        "   belly " + Math.round(satiety * 100) + "%", bx, 50, 14, rl.RAYWHITE);
    if (mode === "sleep") rl.drawText("Z z z", bx, 70, 20, rl.RAYWHITE);

    // Action menu: a grass tuft is within reach, so offer the Eat action.
    if (foodReady) {
        const mw = 132;
        const mh = 34;
        const mx = rl.getScreenWidth() - mw - 12;
        const my = h - mh - 12;
        rl.drawRectangle(mx, my, mw, mh, rl.color(24, 26, 32, 220));
        rl.drawRectangleLines(mx, my, mw, mh, rl.color(232, 201, 116, 255));
        rl.drawText("Eat", mx + 12, my + 9, 18, rl.RAYWHITE);
        rl.drawText("(E)", mx + mw - 34, my + 11, 16, rl.color(232, 201, 116, 255));
    }

    rl.drawText(weatherText, 10, h - 44, 14, rl.RAYWHITE);
    rl.drawText(status + "   " + state, 10, h - 24, 14, rl.RAYWHITE);
}

// ---- host-driven frame loop ----------------------------------------------
//
// The host (`src/main.rs`) owns the loop so it can interleave commands from
// stdin between frames: it calls `sceneInit()` once, then `sceneFrame()` until
// it returns false, then `sceneShutdown()`. `run()` is the standalone driver
// kept for the headless harness (`tools/goat_logic_test.js`).

function sceneInit() {
    rl.initWindow(1000, 640, "Slag goat - walk / run / jump / sleep");
    rl.setTargetFPS(60);
    loadGoat();
    makeEyeTextures();
    makeSkyTextures();
    makeWeatherTextures();
    makeLighting();
    makeSkyShader();
    makeAudio();
    makeBotTextures();
    loadBots();

    screenW = rl.getScreenWidth();
    screenH = rl.getScreenHeight();
    sceneFrames = 0;
}

// One frame: advance the world and draw it. Returns false once the window is
// closing or `quit` was received, so the host stops calling it.
function sceneFrame() {
    if (ctlQuit || rl.windowShouldClose()) return false;
    const dt = Math.min(rl.getFrameTime(), 0.05);
    sceneFrames += 1;

    // food: the nearest tuft decides whether the action menu shows, and the E
    // handler below eats it.
    foodTarget = nearestTuft(goat.px, goat.pz, EAT_RANGE);
    foodReady = foodTarget !== null && mode !== "dead" && mode !== "sleep" &&
        mode !== "jump" && mode !== "eat";

    // day/night: advance the clock, then refresh the sky and the ambient
    // tint the whole scene is drawn with.
    const fast = ctlKeyDown(rl.KEY_T);
    worldTime = mod24(worldTime + (dt / DAY_LENGTH) * 24 * (fast ? TIME_FAST : 1));
    const sky = skySample(worldTime);
    updateWind(dt);
    updateWeather(dt);
    updateClouds(dt);
    updateRain(dt);
    updateAudio(dt);
    updateFood(dt);
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
    if (ctlKeyDown(rl.KEY_LEFT)) camYaw += 1.6 * dt;
    if (ctlKeyDown(rl.KEY_RIGHT)) camYaw -= 1.6 * dt;
    if (ctlKeyDown(rl.KEY_UP)) camPitch += 1.0 * dt;
    if (ctlKeyDown(rl.KEY_DOWN)) camPitch -= 1.0 * dt;
    camDist -= rl.getMouseWheelMove() * 0.4;
    camPitch = clamp(camPitch, 0.08, 1.35);
    camDist = clamp(camDist, 2.2, 12.0);

    // input
    if (rl.isKeyPressed(rl.KEY_P)) paused = !paused;
    if (rl.isKeyPressed(rl.KEY_C)) forceWeather();
    if (rl.isKeyPressed(rl.KEY_L) && litShader >= 0) {
        useLighting = !useLighting;
        if (haveModel) rl.setModelShader(model, useLighting ? litShader : -1);
        setBotsShader(useLighting ? litShader : -1);
    }
    if (rl.isKeyPressed(rl.KEY_K) && litShader >= 0) {
        // Cycle shadows: map -> planar -> off. The map needs the engine
        // bindings; planar is the fallback.
        shadowMode = (shadowMode + 1) % 3;
        if (shadowMode === SHADOW_MAP && !shadowMapReady) shadowMode = SHADOW_OFF;
        if (shadowMode === SHADOW_PLANAR && shadowShader < 0) shadowMode = SHADOW_OFF;
    }
    if (rl.isKeyPressed(rl.KEY_M)) setMuted(!muted);
    if (rl.isKeyPressed(rl.KEY_B) && skyShader >= 0) useSkyShader = !useSkyShader;
    let move = 0;
    if (ctlKeyDown(rl.KEY_W)) move += 1;
    if (ctlKeyDown(rl.KEY_S)) move -= 1;
    let turn = 0;
    if (ctlKeyDown(rl.KEY_A)) turn += 1;
    if (ctlKeyDown(rl.KEY_D)) turn -= 1;
    const running = ctlKeyDown(rl.KEY_LEFT_SHIFT) || ctlKeyDown(rl.KEY_RIGHT_SHIFT);
    const trotting = ctlKeyDown(rl.KEY_LEFT_CONTROL) || ctlKeyDown(rl.KEY_RIGHT_CONTROL);
    let gait = running ? "run" : trotting ? "trot" : "walk";
    if (exhausted) gait = "walk";   // an exhausted goat cannot run or trot
    if (mode !== "sleep" && mode !== "dead" && mode !== "eat") goat.yaw += turn * TURN_RATE * dt;

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
    } else if (mode === "eat") {
        eatTime += dt;
        if (eatTime >= eatDuration()) {
            mode = move !== 0 ? gait : "idle";
        }
    } else if (rl.isKeyPressed(rl.KEY_E) && foodReady) {
        startEat(foodTarget);
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

    // The player's idle variant advances each time it settles into idle, so
    // it cycles through the idle clips instead of always doing the same one.
    if (mode !== lastMode) {
        if (mode === "idle") cyclePlayerVariant("idle");
        lastMode = mode;
    }

    curRole = clipRole();
    curSpeed = groundSpeed();

    // `step <n>` (ctl.js) unsticks this gate for a fixed number of frames even
    // while paused, so a script can advance the world deterministically.
    if (!paused || ctlStep > 0) {
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
        } else if (mode === "eat") {
            // The meal is posed from `eatTime`; the goat stays put.
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
        } else if (mode === "eat" && CLIP.eat) {
            poseModel("eat", Math.min(eatTime / CLIP.eat.duration, 1));
        } else {
            poseModel(curRole, goat.phase);
        }
        const info = playerClip(curRole);
        curClipName = info !== null && info !== undefined ? rl.modelAnimationName(model, info.index) : "";
    }
    updateBots(dt);
    resolveGoatCollisions();

    // render
    const ty = 0.85 + goat.py;
    const cp = Math.cos(camPitch);
    const cx = goat.px + camDist * cp * Math.sin(camYaw);
    const cy = ty + camDist * Math.sin(camPitch);
    const cz = goat.pz + camDist * cp * Math.cos(camYaw);

    rl.beginDrawing();
    rl.clearBackground(skyBot);
    const skyShaderOn = useSkyShader && skyShader >= 0;
    if (skyShaderOn) {
        drawSky(cx, cy, cz, goat.px, ty, goat.pz, screenW, screenH, dt);
    } else {
        rl.drawRectangleGradientV(0, 0, screenW, screenH, skyTop, skyBot);
    }
    const lit = useLighting && litShader >= 0;
    // The shadow-map pass must run before the main 3D pass, since it swaps
    // render targets and leaves the model pointing back at the lit shader.
    if (lit) renderShadowMap();
    rl.beginMode3D(cx, cy, cz, goat.px, ty, goat.pz, 55);
    drawStars();
    drawCelestial();
    if (!skyShaderOn) drawClouds();

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
        drawBots(rl.WHITE);
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
        drawBots(ambTint);
        lightingText = litShader < 0 ? "cube shader" : "off";
    }
    rl.endMode3D();
drawRain(screenW, screenH);
drawHud(move);
rl.endDrawing();

if (sceneFrames % 240 === 0) {
    console.log("frame " + sceneFrames + " mode " + mode + " phase " + goat.phase.toFixed(2) +
        " fps " + rl.getFPS() + " gap " + goatMinGap().toFixed(2));
}

    if (ctlStep > 0) {
        ctlStep -= 1;
        if (ctlStep === 0) paused = true;   // a step always ends paused
    }

    return true;
}

function sceneShutdown() {
    console.log("window closed after " + sceneFrames + " frames");
    unloadBots();
    if (haveModel) {
        rl.unloadModel(model);
    }
    if (audioReady) rl.closeAudioDevice();
    rl.closeWindow();
}

// The standalone driver: init, frame until the window closes, tear down. Used
// by the headless harness; the host drives the pieces directly.
function run() {
    sceneInit();
    while (sceneFrame()) {}
    sceneShutdown();
}

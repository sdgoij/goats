// Part 10/14 of the goat scene: the gait state machine, HUD and frame loop.
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
const stats = { health: TUNING.stats.max, energy: TUNING.stats.max };
let exhausted = false;
let xTex = -1;           // X-eye sprite texture (made after the window opens)
let moonTex = -1;        // procedural cratered moon disc
let glowTex = -1;        // radial sun/star glow
let camYaw = TUNING.camera.yaw;
let camPitch = TUNING.camera.pitch;
let camDist = TUNING.camera.dist;

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
    return info !== null && info !== undefined ? info.duration : TUNING.jump.fallbackTime;
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
        if (mode === "run") mult = TUNING.jump.fallbackRunMult;
        else if (mode === "trot") mult = TUNING.jump.fallbackTrotMult;
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
        if (gait === "run") mult = TUNING.jump.fallbackRunMult;
        else if (gait === "trot") mult = TUNING.jump.fallbackTrotMult;
        jumpSpeed = ((2 * V_STRIDE) / V_CYCLE) * mult;
    } else if (gait === "run" && CLIP.run) {
        jumpSpeed = runSpeed();
    } else if (gait === "trot" && CLIP.trot) {
        jumpSpeed = trotSpeed();
    } else {
        jumpSpeed = walkSpeed();
    }
    jumpSpeed *= weatherSpeed;   // a wet goat does not jump as far
    stats.energy = Math.max(0, stats.energy - TUNING.stats.jumpEnergyCost);
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
    stats.health = TUNING.stats.max;
    stats.energy = TUNING.stats.max;
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
        stats.energy = Math.min(TUNING.stats.max, stats.energy + TUNING.stats.sleepEnergyRecover * dt);
        stats.health = Math.min(TUNING.stats.max, stats.health + TUNING.stats.sleepHealthRecover * dt);
        return "sleep";
    }
    let drain = TUNING.stats.energyDrain.idle;
    if (mode === "run") drain = TUNING.stats.energyDrain.run;
    else if (mode === "trot") drain = TUNING.stats.energyDrain.trot;
    else if (mode === "walk") drain = TUNING.stats.energyDrain.walk;
    if (skyLight < 0.25) drain *= TUNING.world.nightDrainMult;   // cold nights burn energy faster
    drain *= weatherDrain;                            // ...and so does being soaked
    stats.energy = Math.max(0, stats.energy - drain * dt);
    if (stats.energy <= 0) {
        exhausted = true;
        stats.health = Math.max(0, stats.health - TUNING.stats.exhaustHealthDrain * dt);
    } else {
        exhausted = false;
        if (mode === "idle" && stats.energy > TUNING.stats.restedEnergy) {
            stats.health = Math.min(TUNING.stats.max, stats.health + TUNING.stats.idleHealthRecover * dt);
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
        deathTime >= CLIP.death.duration * TUNING.stats.deadEyeFraction)) return;
    const eyes = DEATH_EYES;
    const size = 0.13;
    const c = Math.cos(goat.yaw);
    const s = Math.sin(goat.yaw);
    const py = goatBaseY(goat) + groundOffset;
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

    const status = clockText + "   speed " + curSpeed.toFixed(2) + " m/s   phase " +
        goat.phase.toFixed(2) + "   fps " + rl.getFPS() + "   light " + lightingText +
        "   sky " + (useSkyShader && skyShader >= 0 ? "shader" : "billboards") +
            "   clouds " + CLOUD_LEVELS[cloudLevel()] +
        "   audio " + (audioReady ? (muted ? "muted" : "on") : "off") +
        "   herd " + BOTS.length;

    // Health and energy bars, top-right.
    const bw = 160;
    const bx = rl.getScreenWidth() - bw - 12;
    rl.drawRectangle(bx, 10, bw, 14, rl.color(28, 28, 34, 220));
    rl.drawRectangle(bx + 1, 11, Math.round((bw - 2) * stats.health / TUNING.stats.max), 12,
        rl.color(208, 62, 62, 255));
    rl.drawRectangle(bx, 30, bw, 14, rl.color(28, 28, 34, 220));
    rl.drawRectangle(bx + 1, 31, Math.round((bw - 2) * stats.energy / TUNING.stats.max), 12,
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
// The host (`crates/goats/src/main.rs`) owns the loop so it can interleave
// commands from stdin between frames: it calls `sceneInit()` once, then
// `sceneFrame()` until it returns false, then `sceneShutdown()`. `run()` is the
// standalone driver
// kept for the headless harness (`tools/goat_logic_test.js`).

// ---- loading -------------------------------------------------------------
//
// Startup work is split into steps so the frame loop can paint a splash (and a
// progress bar) between them: `sceneInit` opens the window, then each
// `sceneFrame` takes one step while `sceneReady()` is false. Cheap work runs
// first, so the window paints before the heavy model loads.

let loaded = false;
let loadStep = 0;
let loadTotal = 0;

// The harness reads this to tell loading frames from game frames.
function sceneReady() {
    return loaded;
}

function sceneLoadStep() {
    const i = loadStep;
    loadStep += 1;
    if (i === 0) makeEyeTextures();
    else if (i === 1) makeSkyTextures();
    else if (i === 2) makeWeatherTextures();
    else if (i === 3) loadGoat();
    else if (i === 4) makeTerrain();
    else if (i === 5) makeLighting();
    else if (i === 6) makeSkyShader();
    else if (i === 7) makeAudio();
    else if (i === 8) makeBotTextures();
    else {
        // One bot per step, so the bar keeps moving through the model loads.
        const want = clamp(Math.round(TUNING.herd.count), 0, 10);
        if (BOTS.length < want) botAdd(BOTS.length);
    }
}

// The splash: title, progress bar and a step counter.
function drawLoading() {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    rl.beginDrawing();
    rl.clearBackground(rl.color(10, 12, 18, 255));
    const w = 420;
    const x = Math.round((sw - w) / 2);
    const y = Math.round(sh / 2);
    rl.drawText("Slag goat", x, y - 64, 40, rl.RAYWHITE);
    if (typeof rl.guiProgressBar === "function") {
        rl.guiProgressBar(x, y, w, 24, "", "Loading", loadStep, 0, loadTotal > 0 ? loadTotal : 1);
    } else {
        rl.drawRectangle(x, y, w, 24, rl.color(40, 44, 52, 255));
        rl.drawRectangle(x, y, Math.round(w * loadStep / (loadTotal > 0 ? loadTotal : 1)), 24,
            rl.color(120, 190, 120, 255));
    }
    rl.drawText("loading " + Math.min(loadStep, loadTotal) + " / " + loadTotal,
        x, y + 34, 16, rl.RAYWHITE);
    rl.endDrawing();
}

function sceneInit() {
    rl.initWindow(1000, 640, "Slag goat - walk / run / jump / sleep");
    rl.setTargetFPS(60);
    // ESC is ours now: it opens the menu instead of closing the window.
    if (typeof rl.setExitKey === "function") rl.setExitKey(0);
    // Full-screen by default; the Settings toggle and F11 flip it later.
    if (SETTINGS.fullscreen && typeof rl.toggleFullscreen === "function" &&
        typeof rl.isWindowFullscreen === "function" && !rl.isWindowFullscreen()) {
        rl.toggleFullscreen();
    }
    // The load runs a step at a time from `sceneFrame`, so the splash shows.
    loaded = false;
    loadStep = 0;
    loadTotal = 9 + clamp(Math.round(TUNING.herd.count), 0, 10);
    screenW = rl.getScreenWidth();
    screenH = rl.getScreenHeight();
    sceneFrames = 0;
}

// One frame: advance the world and draw it. Returns false once the window is
// closing or `quit` was received, so the host stops calling it.
function sceneFrame() {
    if (ctlQuit || rl.windowShouldClose()) return false;

    // Loading: take one startup step per frame, drawing the splash until done.
    if (!loaded) {
        if (loadStep < loadTotal) sceneLoadStep();
        if (loadStep >= loadTotal) {
            loaded = true;
            applyStartupSettings();
            if (BOTS.length > 0) console.log("goat: " + BOTS.length + " bot goats");
        } else {
            drawLoading();
            return true;
        }
    }

    // The console is an overlay: update it first, because while it is open it
    // takes Escape (closing itself) and swallows the gameplay keys below.
    const consoleAteEsc = consoleUpdate();
    // ESC toggles the main menu: it freezes the game and opens the menu; a second
    // press resumes (or steps back from a sub-screen).
    if (rl.isKeyPressed(rl.KEY_ESCAPE) && !consoleAteEsc) {
        uiScreen = uiScreen === "hud" ? "main" : uiScreen === "main" ? "hud" : "main";
    }
    // A menu freezes time: every world update is dt-driven, so a zero dt is the
    // whole pause (input is gated separately).
    const dt = uiIsOpen() ? 0 : Math.min(rl.getFrameTime(), 0.05);
    sceneFrames += 1;
    // Full-screen can change the drawable size; keep the cached size current.
    screenW = rl.getScreenWidth();
    screenH = rl.getScreenHeight();

    // food: the nearest tuft decides whether the action menu shows, and the E
    // handler below eats it.
    foodTarget = nearestTuft(goat.px, goat.pz, TUNING.food.eatRange);
    foodReady = foodTarget !== null && mode !== "dead" && mode !== "sleep" &&
        mode !== "jump" && mode !== "eat";

    // day/night: advance the clock, then refresh the sky and the ambient
    // tint the whole scene is drawn with.
    // The clock and the weather are server-owned in a client session; the local
    // T accelerator and the C force are for the host and offline play.
    const fast = netWeatherLocal() && ctlKeyDown(rl.KEY_T);
    worldTime = mod24(worldTime + (dt / TUNING.world.dayLength) * 24 * (fast ? TUNING.world.timeFast : 1));
    const sky = skySample(worldTime);
    if (netWeatherLocal()) {
        updateWind(dt);
        updateWeather(dt);
    } else {
        // The server's wind and cloudiness arrive over the wire. Only the visual
        // sway clock and this goat's own effects are ours to keep.
        swayTime += dt;
        updateWeatherEffects();
    }
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
    if (uiScreen === "hud" && !consoleOpen && rl.isMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
        camYaw -= rl.getMouseDeltaX() * 0.004;
        camPitch -= rl.getMouseDeltaY() * 0.004;
    }
    if (ctlKeyDown(rl.KEY_LEFT)) camYaw += 1.6 * dt;
    if (ctlKeyDown(rl.KEY_RIGHT)) camYaw -= 1.6 * dt;
    if (ctlKeyDown(rl.KEY_UP)) camPitch += 1.0 * dt;
    if (ctlKeyDown(rl.KEY_DOWN)) camPitch -= 1.0 * dt;
    if (uiScreen === "hud" && !consoleOpen) camDist -= rl.getMouseWheelMove() * 0.4;
    camPitch = clamp(camPitch, 0.08, 1.35);
    camDist = clamp(camDist, TUNING.camera.minDist, TUNING.camera.maxDist);

    // input
    if (press(rl.KEY_P)) paused = !paused;
    if (press(rl.KEY_C) && netWeatherLocal()) forceWeather();
    if (press(rl.KEY_L) && litShader >= 0) {
        useLighting = !useLighting;
        SETTINGS.light = useLighting;
        if (haveModel) rl.setModelShader(model, useLighting ? litShader : -1);
        setBotsShader(useLighting ? litShader : -1);
        setTerrainShader(useLighting ? litShader : -1);
    }
    if (press(rl.KEY_K) && litShader >= 0) {
        // Cycle shadows: map -> planar -> off. The map needs the engine
        // bindings; planar is the fallback.
        shadowMode = (shadowMode + 1) % 3;
        if (shadowMode === SHADOW_MAP && !shadowMapReady) shadowMode = SHADOW_OFF;
        if (shadowMode === SHADOW_PLANAR && shadowShader < 0) shadowMode = SHADOW_OFF;
        SETTINGS.shadow = shadowMode;
    }
    if (press(rl.KEY_M)) setMuted(!muted);
    // `KEY_F11` ships with the engine's fullscreen bindings; skip the toggle if
    // an older engine does not export it (a non-number would throw in raylib).
    if (typeof rl.KEY_F11 === "number" && press(rl.KEY_F11)) {
        SETTINGS.fullscreen = !SETTINGS.fullscreen;
        applySettings();
    }
    if (press(rl.KEY_B) && skyShader >= 0) {
        useSkyShader = !useSkyShader;
        SETTINGS.sky = useSkyShader;
    }
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
    if (mode !== "sleep" && mode !== "dead" && mode !== "eat") goat.yaw += turn * TUNING.movement.turnRate * dt;

    // state machine: jump, sleep, eat and death lock the mode; everything else
    // follows the requested gait. A menu freezes the machine entirely.
    if (uiScreen !== "hud") {
        // paused by the menu
    } else if (mode === "dead") {
        if (press(rl.KEY_R)) restart();
    } else if (mode === "sleep") {
        if (press(rl.KEY_Z) || move !== 0 || stats.energy >= TUNING.stats.max) {
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
    } else if (press(rl.KEY_E) && foodReady) {
        startEat(foodTarget);
    } else if (press(rl.KEY_Z)) {
        startSleep();
    } else if (press(rl.KEY_SPACE)) {
        startJump(move, gait);
    } else {
        mode = move !== 0 ? gait : "idle";
        // drop off on our own once exhausted and standing still
        if (exhausted && move === 0) {
            idleTimer += dt;
            if (idleTimer >= TUNING.stats.autoSleepDelay) startSleep();
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
                goat.py = V_DROP + TUNING.jump.fallbackHeight *
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
    // The bots are server-owned in a session: only the host simulates them, and
    // a client mirrors the snapshots it receives instead.
    if (netWorldLocal()) updateBots(dt);
    updatePeers(dt);
    resolveGoatCollisions();
    // The heightfield follows the goat: rebuild the grid if it has left the one
    // it was built around, before either the shadow pass or the visible one reads
    // it.
    terrainEnsure(goat.px, goat.pz);

    // render
    const ty = 0.85 + goatBaseY(goat);
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
        // `setLitUniforms` first: it binds the batch's texture units (the shadow
        // map's sampler among them) and the grass below samples them, so it must
        // stay adjacent to the grass draws. The terrain goes after the batch
        // block because it is a model draw: it binds its own material shader and
        // unbinds the texture units when it finishes.
        rl.beginShaderMode(litShader);
        setLitUniforms(cx, cy, cz);
        drawTufts(goat, TUFT, 576, 180);   // cull beyond 24 units, detail inside ~13
        if (!haveModel) drawGoat(goat);
        rl.endShaderMode();
        drawTerrain(rl.WHITE);
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
        drawPeers(rl.WHITE);
        if (shadowMode === SHADOW_MAP && shadowStrengthNow > 0.001) lightingText = "lit + shadow map";
        else if (shadowMode === SHADOW_PLANAR && LIGHT_DIR[1] > 0.06) lightingText = "lit + planar shadow";
        else lightingText = "lit";
    } else {
        // No shader: the M2/M3 look, with the ambient tint and a blob shadow.
        drawTerrain(ambTint);
        drawTufts(goat, ambTuft, 576, 180);
        drawShadow();
        if (haveModel) {
            drawModelGoat(goat, ambTint);
            drawEyes();
        } else {
            drawGoat(goat);
        }
        drawBots(ambTint);
        drawPeers(ambTint);
        lightingText = litShader < 0 ? "cube shader" : "off";
    }
    rl.endMode3D();
drawRain(screenW, screenH);
if (uiScreen === "hud") {
    drawHud(move);
    if (consoleOpen) drawConsole();
} else {
    drawUi();
}
rl.endDrawing();

if (sceneFrames % 240 === 0) {
    console.log("frame " + sceneFrames + " mode " + mode + " phase " + goat.phase.toFixed(2) +
        " fps " + rl.getFPS() + " gap " + goatMinGap().toFixed(2) +
        " bellyMax " + botBellyMax.toFixed(2) +
        " grazeWalks " + botGrazeWalks);
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

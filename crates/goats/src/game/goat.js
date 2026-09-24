// ---- gait state ----------------------------------------------------------

const goat = { px: 0, pz: 0, py: V_DROP, yaw: 0, phase: 0 };
let paused = false;
let mode = "idle";       // idle | walk | trot | run | jump | flung | sleep | dead
let jumpTime = 0;        // seconds into the current jump
let eatTime = 0;         // seconds into the current meal
let jumpSpeed = 0;       // ground speed frozen at take-off
let jumpDir = 0;         // travel direction (-1/0/1) frozen at take-off
// M19c: the blast's arc. `explosions.js` owns the impulse and calls `startFling`;
// this only flies it. `flingTime` drives the pose, the velocity is world-space,
// `flingY` is an *absolute* height (deriving `goat.py`, which is a height above the
// ground directly below, from it keeps a slope the goat crosses mid-air from
// dragging it up or down), and `flingFlight` is the ballistic time the clip is
// stretched over.
let flingTime = 0;
let flingVX = 0;
let flingVZ = 0;
let flingVY = 0;
let flingY = 0;
let flingFlight = 0;
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
    // The arc (M19c): the flung clip when the model has one, the jump when it does
    // not -- which is the placeholder the clip contract was written around, and the
    // pose below stretches whichever it got over the flight.
    if (mode === "flung") return CLIP.flung ? "flung" : "jump";
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
    // Rain and wind slow the goat: it works harder for the same clip. So does wading
    // (M20d), which is exactly 1 out of water, so `clear` on dry ground is untouched.
    return base * weatherSpeed * waterSpeedFactor();
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
    jumpSpeed *= weatherSpeed * waterSpeedFactor();   // a wet goat does not jump as far
    stats.energy = Math.max(0, stats.energy - TUNING.stats.jumpEnergyCost);
    playBleat(0.9);
}

// Take a blast's impulse (M19c). The caller has already decided this goat is in
// range and scaled the impulse by the falloff; this is where the goat starts being
// flown. A second blast mid-arc *adds* to the arc rather than restarting it, which
// is what a chain reaction through a minefield should look like.
function startFling(vx, vz, vy) {
    if (mode !== "flung") {
        flingY = goatBaseY(goat);   // the arc starts where the goat is
        flingTime = 0;
        mode = "flung";
        playBleat(1.0);
    }
    flingVX += vx;
    flingVZ += vz;
    flingVY += vy;
    // The pose is stretched over the ballistic time the remaining upward impulse
    // implies, counted from the start of the arc, so the phase keeps rising towards
    // 1 instead of jumping back.
    const g = TUNING.explosions.fling.gravity;
    const air = flingVY > 0 && g < 0 ? (-2 * flingVY) / g : 0.4;
    flingFlight = Math.max(0.3, Math.min(TUNING.explosions.fling.maxFlight, flingTime + air));
}

// How far through the arc the goat is, in [0, 1]. The pose is stretched over the
// flight with it, the roll is driven by it, and it is the phase a peer is told, so
// it is read from three places and written once.
function flingProgress() {
    return Math.min(flingTime / flingFlight, 1);
}

// A goat does not sleep in the water (M20f's follow-on): the mode is refused where the goat
// is standing in a pool, and a sleeping goat the rain reaches is woken. Both are the same
// question -- `waterInWater`, the HUD's own line -- so the key, the console verb, the
// auto-sleep after exhaustion and a mod's `setMode` all go through here and cannot disagree.
// It returns whether the goat went to sleep, which is what the console prints.
function startSleep() {
    if (waterInWater(goat.px, goat.pz)) return false;
    mode = "sleep";
    cyclePlayerVariant("sleep");
    sleepTime = 0;
    idleTimer = 0;
    playBleat(0.45);
    return true;
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
    // A death (or a console `restart`) mid-arc must not leave the next life
    // hovering: the mode, the velocities and the offset all go back to rest.
    flingTime = 0;
    flingVX = 0;
    flingVZ = 0;
    flingVY = 0;
    flingY = 0;
    flingFlight = 0;
    goat.py = haveModel ? 0 : V_DROP;
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
    drain *= waterDrainFactor();                      // ...and so does wading (M20d)
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

// The sky's own procedural textures: the moon's surface and the sun's glare.
//
// The moon is *equirectangular*, on the sphere's own UV grid, because a sphere is
// what wears it now (`makeCelestial`): the old generator drew a disc with a soft
// alpha edge and its craters in a square around the centre, and a disc cannot be
// wrapped onto a sphere -- the poles would sample the alpha ring and the ball would
// read as cut open. The craters are also kept off the poles, where the UV grid
// stretches them into bands, and the wrap in `u` is respected, so a crater lying on
// the seam is still one crater. The limb darkening the disc had is gone: the sphere
// shades its own limb now.
function makeSkyTextures() {
    const W = 128, H = 64;
    const craters = [];
    for (let i = 0; i < 46; i++) {
        craters.push({
            u: hash(i * 3.7),
            v: 0.12 + hash(i * 9.1) * 0.76,
            r: 0.018 + hash(i * 5.3) * 0.055,
            deep: 0.35 + hash(i * 7.7) * 0.65,
        });
    }
    let moon = "";
    for (let y = 0; y < H; y++) {
        const v = (y + 0.5) / H;
        for (let x = 0; x < W; x++) {
            const u = (x + 0.5) / W;
            // A little mottling, so the surface is not a flat grey.
            let shade = 0.88 + 0.12 * hash(x * 0.31 + y * 1.7);
            for (let i = 0; i < craters.length; i++) {
                const c = craters[i];
                let du = u - c.u;
                if (du > 0.5) du -= 1;
                if (du < -0.5) du += 1;
                // `v` spans half the angular range `u` does, so a crater only comes
                // out round on the sphere when the v distance is halved with it.
                const dv = (v - c.v) * 0.5;
                const dd = Math.sqrt(du * du + dv * dv);
                if (dd < c.r) {
                    const t = 1 - dd / c.r;
                    shade = shade - 0.26 * t * c.deep;       // the floor
                    if (dd > c.r * 0.7) shade = shade + 0.16 * t;   // and its rim
                }
            }
            shade = Math.min(1, Math.max(0.30, shade));
            const r = Math.round(238 * shade);
            const g = Math.round(234 * shade);
            const b = Math.round(222 * shade);
            moon += HEX256[r] + HEX256[g] + HEX256[b] + HEX256[255];
        }
    }
    moonTex = rl.makeTexture(W, H, moon);

    // The sun's glare: a white alpha falloff, drawn additively by
    // `drawCelestialBody`, so the black around it adds nothing (which is also why a
    // photographed glow would work).
    const N = 64;
    let glow = "";
    for (let y = 0; y < N; y++) {
        for (let x = 0; x < N; x++) {
            const u = (x + 0.5) / N - 0.5;
            const v = (y + 0.5) / N - 0.5;
            const d = Math.sqrt(u * u + v * v) / 0.5;
            const a = d >= 1 ? 0 : Math.round(255 * (1 - d) * (1 - d));
            glow += "fff6d6" + HEX256[a];
        }
    }
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

    // Health and energy bars, top-right, plus the built-in read-out line.
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

    // A compiled client mod's HUD contribution: a belly bar the mod owns through
    // `goats_hud`. It exists only while a wasm mod reports a value, so disabling
    // the mod removes the bar rather than leaving a built-in fallback behind.
    const wasmBelly = modWasmHudFill();
    let sleepY = 70;
    if (wasmBelly !== null) {
        rl.drawRectangle(bx, 70, bw, 14, rl.color(28, 28, 34, 220));
        rl.drawRectangle(bx + 1, 71, Math.round((bw - 2) * Math.max(0, Math.min(1, wasmBelly))), 12,
            rl.color(96, 186, 96, 255));
        rl.drawText("belly (wasm) " + Math.round(wasmBelly * 100) + "%", bx, 90, 14, rl.RAYWHITE);
        sleepY = 110;
    }
    if (mode === "sleep") rl.drawText("Z z z", bx, sleepY, 20, rl.RAYWHITE);

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
// kept for the headless harness (`crates/harness`).

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
    else if (i === 1) {
        // The sky's textures, and then the two bodies that wear them: a sphere each,
        // built before `makeTerrain`'s mesh because the harness reads the last mesh
        // built as "the terrain".
        makeSkyTextures();
        makeCelestial();
    }
    else if (i === 2) {
        // The weather's cloud puff and the explosions' flipbook atlases are both
        // procedurally built textures, so they share a step: one image path at boot,
        // and the splash still paints between this step and the next.
        makeWeatherTextures();
        makeFxTextures();
    }
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

// The `dt` the scene last stepped with, so the Rust host (M17b) can drive
// compiled mods at the same clock the JS simulation uses. A menu freeze shows up
// here as 0, exactly as it does for the JS `update` event.
let sceneLastDt = 0;
function sceneDt() { return sceneLastDt; }

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
            modEmit("ready");
        } else {
            drawLoading();
            return true;
        }
    }

    perfStart();

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
    sceneLastDt = dt;
    sceneFrames += 1;
    // Full-screen can change the drawable size; keep the cached size current.
    screenW = rl.getScreenWidth();
    screenH = rl.getScreenHeight();

    // food: the nearest tuft decides whether the action menu shows, and the E
    // handler below eats it.
    foodTarget = nearestTuft(goat.px, goat.pz, TUNING.food.eatRange);
    foodReady = foodTarget !== null && mode !== "dead" && mode !== "sleep" &&
        mode !== "jump" && mode !== "eat";
    perfMark("food");

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
    // The water's own clock, once a frame on either path (water.js): the table follows
    // the rain down through this and up through it instantly, so a shower leaves standing
    // water behind it. It is not in `updateWeatherEffects`, which a client can also reach
    // from an arriving packet: that is the same frame, and one frame of a follower is all
    // there is to give it.
    waterStep(dt);
    perfMark("weather");
    updateClouds(dt);
    perfMark("clouds_upd");
    updateRain(dt);
    perfMark("rain_upd");
    updateAudio(dt);
    perfMark("audio");
    updateFood(dt);
    perfMark("food_upd");
    updateExplosions(dt);
    perfMark("fx_upd");
    // overcast skies wash the gradient toward grey
    const grey = Math.min(0.75, cloudiness * 0.75);
    skyTop = lerpColor(sky.top, OVERCAST_TOP, grey);
    skyBot = lerpColor(sky.bot, OVERCAST_BOT, grey);
    skyLight = sky.light;
    updateAmbient();
    updateLight();
    updateShadow();
    perfMark("light");
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
        if (haveModel) rl.setModelShader(model, modelShaderFor(model, useLighting ? litShader : -1));
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
    // The water's own bisect (M20f): off is the whole system, which is the frame-cost
    // comparison a review wants and the state a mod's own water would start from.
    if (press(rl.KEY_J)) waterSetEnabled(TUNING.water.enabled === 0);
    perfMark("input");
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
        // The water can arrive under a sleeping goat -- the rain raises the table and the
        // goat is not going anywhere -- so the same test that refuses to *start* a sleep
        // ends one, which is the only way "no sleeping in the water" can hold.
        if (press(rl.KEY_Z) || move !== 0 || stats.energy >= TUNING.stats.max ||
            waterInWater(goat.px, goat.pz)) {
            wakeUp();
        }
    } else if (mode === "jump") {
        jumpTime += dt;
        if (jumpTime >= jumpDuration()) {
            mode = move !== 0 ? gait : "idle";
        }
    } else if (mode === "flung") {
        // Not in charge until the feet touch (M19c): no steering, no jumping out of
        // it, no eating. For about a second the goat is the blast's, which is the
        // whole feeling of the feature. The arc itself is advanced below.
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
        const previousMode = lastMode;
        lastMode = mode;
        modEmit("mode", mode, previousMode);
    }

    curRole = clipRole();
    curSpeed = groundSpeed();

    // `step <n>` (ctl.js) unsticks this gate for a fixed number of frames even
    // while paused, so a script can advance the world deterministically.
    if (!paused || ctlStep > 0) {
        if (mode === "flung") {
            // The arc (M19c), integrated in absolute height with `goat.py` (a height
            // above the ground directly below) derived from it, so a slope the goat
            // crosses mid-air cannot drag it along.
            flingTime += dt;
            goat.px += flingVX * dt;
            goat.pz += flingVZ * dt;
            flingVY += TUNING.explosions.fling.gravity * dt;
            // The arc carries the goat whatever the model has. With `GoatFlung` it is
            // the only thing lifting it; with the placeholder it has to be too, because
            // the jump action's own hop is 0.4 m of root motion -- a leap, not a launch
            // -- and leaning on that is what left a throw of twelve metres tumbling
            // along the ground. The clip's hop still rides on top of the arc, which is
            // a placeholder's cost and not a rule.
            //
            // `rest` is where the feet meet the ground: a model rests at 0, the cube
            // fallback sits `V_DROP` under the plane. The arc *starts* at that height,
            // so the descent is half of what ends the flight -- the height alone would
            // end it on the blast's own frame. It is ground contact and not the
            // ballistic time that ends it, which is what lands the goat on the ground
            // it really meets: on a slope, or beside a crater wall.
            const rest = haveModel ? 0 : V_DROP;
            flingY += flingVY * dt;
            goat.py = flingY - terrainHeight(goat.px, goat.pz);
            const landed = flingVY <= 0 && goat.py <= rest;
            if (landed) {
                // Down. If a later version ever makes blasts lethal, this is where
                // death would be decided instead of nothing happening.
                goat.py = haveModel ? 0 : V_DROP;
                flingVX = 0;
                flingVZ = 0;
                flingVY = 0;
                mode = move !== 0 ? gait : "idle";
            }
        } else if (mode === "jump") {
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
    perfMark("goat_sim");

    if (haveModel) {
        if (mode === "flung") {
            // One action, phase 0 at the blast and phase 1 at contact, stretched
            // over the arc's own length: `CLIP.flung` when the model has it, and the
            // jump posed the same way until Blender lands (M19c's placeholder). The
            // placeholder's own hop is small and starts and ends at rest, so all it
            // does is ride along on an arc that is already carrying the goat.
            poseModel(CLIP.flung ? "flung" : "jump", flingProgress());
        } else if (mode === "jump" && CLIP.jump) {
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
    perfMark("goat_pose");
    // The bots are server-owned in a session: only the host simulates them, and
    // a client mirrors the snapshots it receives instead.
    if (netWorldLocal()) updateBots(dt);
    perfMark("bots_ai");
    updatePeers(dt);
    perfMark("peers_upd");
    resolveGoatCollisions();
    perfMark("collide");
    // The heightfield follows the goat: rebuild the grid if it has left the one
    // it was built around, before either the shadow pass or the visible one reads
    // it.
    terrainEnsure(goat.px, goat.pz);
    perfMark("terrain_upd");

    // Mods see the world after it has moved and before it is drawn.
    modFrameTick(dt);
    perfMark("mods_upd");
    // The engine-cost benchmark, when the console has armed it (`perf loop <kind> <n>`).
    if (PERF_LOOP.n > 0) perfLoopRun();

    // render
    const ty = 0.85 + goatBaseY(goat);
    const cp = Math.cos(camPitch);
    const cx = goat.px + camDist * cp * Math.sin(camYaw);
    const cy = ty + camDist * Math.sin(camPitch);
    const cz = goat.pz + camDist * cp * Math.cos(camYaw);
    // The blast's knock (M19f): the camera *and* what it looks at are moved by the
    // same offset, so the world shifts rather than the view swinging. The sky is left
    // where it was, because the knock is a translation and the sky is where a
    // translation does nothing.
    const shakeX = shakeOffsetX();
    const shakeY = shakeOffsetY();
    const shakeZ = shakeOffsetZ();
    const vx = cx + shakeX;
    const vy = cy + shakeY;
    const vz = cz + shakeZ;
    const lookX = goat.px + shakeX;
    const lookY = ty + shakeY;
    const lookZ = goat.pz + shakeZ;

    rl.beginDrawing();
    rl.clearBackground(skyBot);
    const skyShaderOn = useSkyShader && skyShader >= 0;
    // The sky is two passes where the cloud layer can be blended over what is under
    // it: the bodies and the sun's glare are drawn between them, so a cloud that
    // drifts over the sun takes it -- per pixel, from the sky's own march -- instead
    // of the sun being painted on top of the cloud.
    const skySplit = skyShaderOn && skySplitOn();
    if (skyShaderOn) {
        drawSky(cx, cy, cz, goat.px, ty, goat.pz, screenW, screenH, dt,
            skySplit ? SKY_LAYER_AIR : SKY_LAYER_ALL);
    } else {
        rl.drawRectangleGradientV(0, 0, screenW, screenH, skyTop, skyBot);
    }
    perfMark("sky2d");
    const lit = useLighting && litShader >= 0;
    // The shadow-map pass must run before the main 3D pass, since it swaps
    // render targets and leaves the model pointing back at the lit shader.
    if (lit) renderShadowMap();
    // ...and so must the water's mirror (M20e), for the same reason and one more: raylib's
    // `endTextureMode` restores the *screen's* projection, so a texture pass that nested
    // inside the 3D one would leave everything after it flat. It draws nothing unless the
    // reflection setting asks for the mirror and there is water to reflect.
    if (lit) renderWaterMirror(vx, vy, vz, lookX, lookY, lookZ);
    perfMark("mirror");
    rl.beginMode3D(vx, vy, vz, lookX, lookY, lookZ, 55);
    drawStars();
    drawCelestial(cx, cy, cz);
    perfMark("stars");
    if (skySplit) {
        // Out of 3D for the one pass that has to land over the bodies and under the
        // world: the cloud layer, which attenuates what it covers.
        rl.endMode3D();
        drawSky(cx, cy, cz, goat.px, ty, goat.pz, screenW, screenH, dt, SKY_LAYER_CLOUD);
        perfMark("sky_clouds");
        rl.beginMode3D(vx, vy, vz, lookX, lookY, lookZ, 55);
    }
    if (!skyShaderOn) drawClouds();
    perfMark("clouds");

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
        perfMark("tufts");
        drawTerrain(rl.WHITE);
        perfMark("terrain");
        if (haveModel) {
            // The planar fallback is drawn first, under the goat; the shadow
            // map is sampled by the lit shader during the goat's own draw.
            if (shadowMode === SHADOW_PLANAR && shadowShader >= 0 && LIGHT_DIR[1] > 0.06) {
                rl.setModelShader(model, modelShaderFor(model, shadowShader));
                setShadowUniforms();
                drawModelGoat(goat, rl.WHITE);
                rl.setModelShader(model, modelShaderFor(model, litShader));
            }
            drawModelGoat(goat, rl.WHITE);
            drawEyes();
        }
        perfMark("goat");
        drawBots(rl.WHITE);
        perfMark("bots");
        drawPeers(rl.WHITE);
        perfMark("peers");
        // The water surface (M20b): last in the 3D pass, because it is the scene's only
        // transparent model and has to blend over the ground and over anything standing
        // in it. It shares the lit program's uniforms, so it lives in this branch; with
        // the lighting off the field is still simulated, just not drawn.
        waterDraw();
        perfMark("water");
        if (shadowMode === SHADOW_MAP && shadowStrengthNow > 0.001) lightingText = "lit + shadow map";
        else if (shadowMode === SHADOW_PLANAR && LIGHT_DIR[1] > 0.06) lightingText = "lit + planar shadow";
        else lightingText = "lit";
    } else {
        // No shader: the M2/M3 look, with the ambient tint and a blob shadow.
        drawTerrain(ambTint);
        perfMark("terrain");
        drawTufts(goat, ambTuft, 576, 180);
        drawShadow();
        perfMark("tufts");
        if (haveModel) {
            drawModelGoat(goat, ambTint);
            drawEyes();
        } else {
            drawGoat(goat);
        }
        perfMark("goat");
        drawBots(ambTint);
        perfMark("bots");
        drawPeers(ambTint);
        perfMark("peers");
        lightingText = litShader < 0 ? "cube shader" : "off";
    }
    // The bang goes over the world it happened in: after the goats and the grass,
    // before the HUD, so the smoke reads in front of what it hit.
    drawExplosions();
    perfMark("fx");
    modEmit("draw3d", { x: vx, y: vy, z: vz, targetX: lookX, targetY: lookY, targetZ: lookZ, fov: 55 });
    perfMark("mods_draw3d");
    rl.endMode3D();
    perfMark("endmode3d");
drawRain(screenW, screenH);
perfMark("rain2d");
if (uiScreen === "hud") {
    drawHud(move);
    // The blast's own HUD reaction (M19f), over the HUD it belongs to.
    drawDamagePulse();
    perfMark("hud");
    modEmit("hud", { width: screenW, height: screenH });
    perfMark("mods_hud");
    if (consoleOpen) drawConsole();
} else {
    drawUi();
    perfMark("hud");
}
modEmit("draw");
perfMark("mod2d");
rl.endDrawing();
perfMark("boundary");
perfEnd();

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
    modEmit("shutdown");
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

// ---- perf probe ------------------------------------------------------------
//
// A benchmark, not a feature: where a real (non-stub) frame spends its time.
// The scene times its own phases with `rl.getTime()` and reports ms/frame per
// phase; `perf on` logs every 240 frames, `perf` prints on demand, `perf probe`
// measures the engine boundary itself.
//
// Two things to read it with. The frame is vsynced, so a healthy frame is
// quantised to 16.7 ms and the numbers below decompose the *budget* rather than
// expose a stall; `boundary` is where the rest of it waits. And a phase time is
// submission plus any synchronous work in the call -- the GPU's own time lands in
// `boundary`, at the swap.
//
// A third thing, and the reason `worst`/`slow`/`slowms` are here: neither the
// phase table nor `fps` can see a *stutter*, because a single long frame is one
// 240th of a window's average. The engine collects at loop back edges (a
// safe-point mark-sweep: `ir.rs`'s backward `Jump` and `FastLoopHead`, `jit.rs`'s
// `gc_safepoint`), so its cost lands in whichever phase was running and shows up
// as isolated long frames -- `perf`'s average is the wrong instrument for it. A
// frame over `PERF_SLOW` is a dropped frame; their count and total are the
// numbers to compare across an engine change (PERF.md, "The collector's share").
const PERF = { on: false, t: 0, acc: {}, frames: 0, start: 0, worst: 0, slow: 0, slowMs: 0 };
const PERF_SLOW = 0.03;
let perfCubes = 0;

function perfStart() {
    if (PERF.on) {
        PERF.start = rl.getTime();
        PERF.t = PERF.start;
    }
}

// Ends the span that began at the previous mark (or at `perfStart`).
function perfMark(name) {
    if (!PERF.on) return;
    const now = rl.getTime();
    const had = PERF.acc[name];
    PERF.acc[name] = (had === undefined ? 0 : had) + (now - PERF.t);
    PERF.t = now;
}

function perfEnd() {
    if (!PERF.on) return;
    const full = rl.getTime() - PERF.start;
    if (full > PERF.worst) PERF.worst = full;
    if (full > PERF_SLOW) {
        PERF.slow += 1;
        PERF.slowMs += full;
    }
    PERF.frames += 1;
    if (PERF.frames % 240 === 0) perfLog();
}

function perfLog() {
    if (PERF.frames === 0) return;
    let line = "perf ms/frame n=" + PERF.frames;
    for (const name in PERF.acc) {
        line += " " + name + " " + ((PERF.acc[name] * 1000) / PERF.frames).toFixed(2);
    }
    line += " cubes/frame " + Math.round(perfCubes / PERF.frames);
    line += " worst " + (PERF.worst * 1000).toFixed(1);
    line += " slow " + PERF.slow + " slowms " + (PERF.slowMs * 1000).toFixed(1);
    console.log(line + " fps " + rl.getFPS() + " bots " + BOTS.length);
    PERF.acc = {};
    PERF.frames = 0;
    PERF.worst = 0;
    PERF.slow = 0;
    PERF.slowMs = 0;
    perfCubes = 0;
}

// The numbers inside a phase time cannot show: what one JS->native call costs,
// and what one property read off `rl` costs. A frame here is thousands of both
// (every cube, tuft and billboard is a read plus a call), so a change in either
// moves every phase at once -- which is the shape to look for when the whole
// frame gets slower and no single phase does. `jsNs` is the yardstick: the same
// loop with no engine crossing at all.
function perfProbe() {
    const n = 20000;
    let sink = 0;
    for (let i = 0; i < 2000; i++) { sink += rl.getFPS(); sink += rl.WHITE === undefined ? 0 : 1; }
    const t0 = rl.getTime();
    for (let i = 0; i < n; i++) sink += rl.getFPS();
    const t1 = rl.getTime();
    for (let i = 0; i < n; i++) sink += rl.WHITE === undefined ? 0 : 1;
    const t2 = rl.getTime();
    for (let i = 0; i < n; i++) sink += Math.sin(i);
    const t3 = rl.getTime();
    // A loop with nothing native in it at all, as the floor: if this is not an
    // order of magnitude under the others, the probe is measuring "this loop ran
    // in the interpreter" rather than "a call costs X".
    for (let i = 0; i < n; i++) sink += i * 3;
    const t4 = rl.getTime();
    // The same loop again, but in a function of its own with no engine call
    // anywhere in it -- the only caller does one native call before it and one
    // after. If the JIT compiles this and not the loops above, `pureNs` will be an
    // order of magnitude under `arithNs`, and the reason the scene's loops are
    // slow is visible in one number.
    sink += perfPureLoop(n);
    const t5 = rl.getTime();
    return {
        callNs: ((t1 - t0) / n) * 1e9,
        propNs: ((t2 - t1) / n) * 1e9,
        jsNs: ((t3 - t2) / n) * 1e9,
        arithNs: ((t4 - t3) / n) * 1e9,
        pureNs: ((t5 - t4) / n) * 1e9,
        sink: sink
    };
}

// Deliberately its own function, deliberately no engine call in it.
function perfPureLoop(n) {
    let sink = 0;
    for (let i = 0; i < n; i++) sink += i * 3;
    return sink;
}

// ---- the engine-cost benchmark -------------------------------------------
//
// `perf probe` above prices the crossings in one shot and counts nanoseconds only:
// nothing in it can see what a loop *allocates*. This runs a loop once a *frame*
// instead, with the body and the count the console picks (`perf loop <kind> <n>`), so
// the same run can be read off both clocks the scene already has -- `perf`'s for the
// time and `--gc-trace`'s for the boxes a minor sweeps. Then:
//
//     boxes per iteration = (boxes/s armed - boxes/s with `none`) / (60 x n)
//     ns per iteration    = what `perf loop` replies
//
// One variant per process: a configuration command between two windows collapses the
// second window (PERF.md appendix B). Each body isolates one operation class and takes
// everything it touches as a parameter, because that is the shape the JIT is meant to
// compile (§4b/§4c) -- so if a body allocates, the class it isolates is what the engine
// is allocating for, and if `call` differs from the same arithmetic inlined, the call is
// what costs. `new` is the calibration: one object literal is one box by definition.
const PERF_LOOP = { kind: "none", n: 0, frames: 0, ns: 0, sink: 0 };
const PERF_LOOP_KINDS = ["none", "arith", "arithinline", "global", "field", "fieldset", "index", "sqrt", "new", "call", "mapget", "maphas", "mapset"];
const PERF_LOOP_OBJ = { v: 1 };
const PERF_LOOP_ARR = [0, 1, 2, 3, 4, 5, 6, 7];
let PERF_LOOP_SEED = 7;                  // the global a `global` iteration reads

function perfLoopArith(n) {              // locals and arithmetic only
    let s = 0;
    for (let i = 0; i < n; i++) s += i * 3 - 1;
    return s;
}

function perfLoopGlobal(n) {             // one read of a global binding an iteration
    let s = 0;
    for (let i = 0; i < n; i++) s += PERF_LOOP_SEED + i;
    return s;
}

function perfLoopFieldRead(n, o) {       // one object property read an iteration
    let s = 0;
    for (let i = 0; i < n; i++) s += o.v;
    return s;
}

function perfLoopFieldWrite(n, o) {      // one object property write an iteration
    for (let i = 0; i < n; i++) o.v = i;
    return o.v;
}

function perfLoopIndex(n, a) {           // one array element read an iteration
    let s = 0;
    for (let i = 0; i < n; i++) s += a[i & 7];
    return s;
}

function perfLoopSqrt(n) {               // one builtin call an iteration
    let s = 0;
    for (let i = 1; i <= n; i++) s += Math.sqrt(i);
    return s;
}

function perfLoopNew(n) {                // one object literal an iteration
    let o = null;
    for (let i = 0; i < n; i++) o = { v: i };
    return o === null ? 0 : o.v;
}

function perfLoopCallee(i) {             // what the `call` body calls
    return i * 3 - 1;
}

function perfLoopCall(n) {               // one small JS call an iteration
    let s = 0;
    for (let i = 0; i < n; i++) s += perfLoopCallee(i);
    return s;
}

// The scene leans on Maps for its cell bookkeeping (`EATEN`, `SPENT`, `TRAP_SPENT`,
// the tuft height cache), and `field` above says an *object* read is free -- so these
// two ask the same question of an integer-keyed Map.
const PERF_LOOP_MAP = new Map();
(function primeLoopMap() {
    for (let i = 0; i < 8; i++) PERF_LOOP_MAP.set(i, i * 2);
})();

function perfLoopMapGet(n, m) {          // one Map.get an iteration
    let s = 0;
    for (let i = 0; i < n; i++) s += m.get(i & 7);
    return s;
}

function perfLoopMapHas(n, m) {          // one Map.has an iteration
    let s = 0;
    for (let i = 0; i < n; i++) if (m.has(i & 7)) s += 1;
    return s;
}

function perfLoopMapSet(n, m) {          // one Map.set on an existing key an iteration
    for (let i = 0; i < n; i++) m.set(i & 7, i);
    return m.get(7);
}

// One frame's worth, timed. `sceneFrame` calls it only when the console armed it, so an
// unarmed frame costs one comparison.
function perfLoopRun() {
    const n = PERF_LOOP.n;
    const kind = PERF_LOOP.kind;
    const t0 = rl.getTime();
    let s = 0;
    if (kind === "arith") s = perfLoopArith(n);
    // The same body as `arith`, but written out here: this driver is a large function,
    // so the pair answers whether it is the *call* into a small function that gets
    // compiled, or the loop, or neither.
    else if (kind === "arithinline") { for (let i = 0; i < n; i++) s += i * 3 - 1; }
    else if (kind === "global") s = perfLoopGlobal(n);
    else if (kind === "field") s = perfLoopFieldRead(n, PERF_LOOP_OBJ);
    else if (kind === "fieldset") s = perfLoopFieldWrite(n, PERF_LOOP_OBJ);
    else if (kind === "index") s = perfLoopIndex(n, PERF_LOOP_ARR);
    else if (kind === "sqrt") s = perfLoopSqrt(n);
    else if (kind === "new") s = perfLoopNew(n);
    else if (kind === "call") s = perfLoopCall(n);
    else if (kind === "mapget") s = perfLoopMapGet(n, PERF_LOOP_MAP);
    else if (kind === "maphas") s = perfLoopMapHas(n, PERF_LOOP_MAP);
    else if (kind === "mapset") s = perfLoopMapSet(n, PERF_LOOP_MAP);
    PERF_LOOP.sink += s;
    PERF_LOOP.frames += 1;
    PERF_LOOP.ns += rl.getTime() - t0;
}

function perfLoopSet(kind, n) {
    PERF_LOOP.kind = kind;
    PERF_LOOP.n = n;
    PERF_LOOP.frames = 0;
    PERF_LOOP.ns = 0;
    PERF_LOOP.sink = 0;
}

function perfLoopNs() {
    const iters = PERF_LOOP.frames * PERF_LOOP.n;
    return iters > 0 ? (PERF_LOOP.ns / iters) * 1e9 : 0;
}

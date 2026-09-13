// Headless harness for the scene in crates/goats/src/game/: stubs the `rl` surface, drives a scripted
// input timeline, and checks the clip each frame plus the reported stats.
//
//   node tools/goat_logic_test.js
//
// It does not touch raylib; it only exercises the JavaScript state machine.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const TOTAL = 4050;

// Clip table the stub model reports (raylib resamples to 60 fps).
const CLIPS = [
    { name: 'GoatIdle', dur: 6.0 },
    { name: 'GoatIdle2', dur: 7.0 },
    { name: 'GoatIdle3', dur: 6.0 },
    { name: 'GoatWalk', dur: 0.91667 },
    { name: 'GoatTrot', dur: 0.58333 },
    { name: 'GoatRun', dur: 0.5 },
    { name: 'GoatJump', dur: 1.16667 },
    { name: 'GoatJump2', dur: 1.33333 },
    { name: 'GoatSleep', dur: 8.0 },
    { name: 'GoatSleep2', dur: 8.0 },
    { name: 'GoatDeath', dur: 2.33333 },
    { name: 'GoatEat', dur: 2.5 },
    { name: 'GoatEat2', dur: 2.16667 },
];
const clipFrames = CLIPS.map((c) => Math.round(c.dur * 60) + 1);

let frameIndex = 0;
let lastPosed = null;
let modelLoads = 0;
const modelPaths = [];
let botPoses = 0;
let botJumps = 0;
const botClipNames = new Set();
let speedText = '';
let statsText = '';
let weatherText = '';
const modelShaderCalls = [];
const modelTextureCalls = [];
const musicLoads = [];
const musicPlayed = [];
let musicUpdates = 0;
const soundLoads = [];
const soundsPlayed = [];
const timeline = [];
const logs = [];
let shadowPass = false;
let shadowCubeDraws = 0;
let menuDraws = 0;
let cubeDraws = 0;
// The sky fragment shader's source, captured so the suite can assert the volume
// march is what actually gets compiled.
let skyFs = '';
// Splash instrumentation: loading frames are those drawn before `sceneReady()`.
let loadingFrames = 0;
let progressBarCalls = 0;
let splashTitle = false;
let splashStep = '';
// Terrain instrumentation: the last mesh handed to `makeModel`, how many were
// built, and the y the goat's model was last drawn at. The stub model's bounds
// start at y 0, so `groundOffset` is 0 and the drawn y is the terrain height
// under the goat plus any hop.
let terrainMeshesBuilt = 0;
let lastTerrainMesh = null;
let goatDrawY = null;
let goatDrawX = null;
let goatDrawZ = null;
const botDrawY = new Map();
let terrainError = null;

const keys = {};
const pressed = {};
// The console's text queue (M9): `rl.getCharPressed` drains this, the way raylib
// queues one codepoint per real key press.
const chars = [];
// The stubbed clipboard, and every write to it, so the copy path is observable.
let clipboard = '';
const clipboardWrites = [];
// Console probe (M9): the frames whose post-frame console/goat state is
// snapshotted, because `run()` drives the loop internally.
const consoleProbe = {};
const consoleProbeFrames = new Set([
    4007, 4008, 4009, 4011, 4013, 4016, 4018, 4021, 4032, 4034,
]);

function applyInput(i) {
    for (const k of Object.keys(keys)) delete keys[k];
    for (const k of Object.keys(pressed)) delete pressed[k];
    let w = false;
    if (i >= 10 && i < 30) w = true;                        // walk
    if (i >= 30 && i < 50) { w = true; keys[341] = true; }  // trot  (CTRL)
    if (i >= 50 && i < 70) { w = true; keys[340] = true; }  // run   (SHIFT)
    if (i >= 180 && i < 200) w = true;                      // walk after waking
    if (i >= 200) { w = true; keys[340] = true; }           // run to exhaustion, then die
    if (w) keys[87] = true;
    if (i === 70) pressed[32] = true;                       // SPACE jump
    if (i === 150) pressed[90] = true;                      // Z sleep
    if (i === 3000 || i === 3100) pressed[67] = true;       // C next weather
    if (i === 3200) pressed[76] = true;                     // L lighting off
    if (i === 3950) pressed[82] = true;                     // R restart
    // Console (M9). Frames 4010+ follow the R-restart run, so opening it there
    // stops a goat that was genuinely moving: that is what proves the input
    // gate, and it cannot disturb any earlier assertion.
    if (i === 4010) pressed[96] = true;                     // ` opens the console
    if (i === 4012) chars.push(112, 105, 110, 103);         // "ping"
    if (i === 4014) pressed[257] = true;                    // ENTER submits
    if (i === 4016) pressed[265] = true;                    // UP recalls history
    if (i === 4018) pressed[256] = true;                    // ESC closes, not the menu
    if (i === 4020) pressed[96] = true;                     // ` reopens
    if (i === 4022) pressed[256] = true;                    // ESC closes again
    // Clipboard: paste a ticket with Ctrl+V, copy the line back out with
    // Ctrl+C. The clipboard carries a newline, as one copied from a terminal
    // does, so the paste has to strip it.
    if (i === 4030) pressed[96] = true;                     // ` opens
    if (i === 4032) {
        clipboard = 'endpointABC\n';
        keys[341] = true;                                   // CTRL
        pressed[86] = true;                                 // V
    }
    if (i === 4034) {
        keys[341] = true;                                   // CTRL
        pressed[67] = true;                                 // C
    }
    if (i === 4036) pressed[96] = true;                     // ` closes
}

const constants = {
    MOUSE_BUTTON_LEFT: 0,
    KEY_SPACE: 32, KEY_ESCAPE: 256, KEY_ENTER: 257, KEY_BACKSPACE: 259, KEY_V: 86,
    KEY_DELETE: 261, KEY_GRAVE: 96,
    KEY_RIGHT: 262, KEY_LEFT: 263, KEY_DOWN: 264, KEY_UP: 265,
    KEY_LEFT_SHIFT: 340, KEY_RIGHT_SHIFT: 344,
    KEY_LEFT_CONTROL: 341, KEY_RIGHT_CONTROL: 345,
    KEY_A: 65, KEY_D: 68, KEY_R: 82, KEY_S: 83, KEY_W: 87, KEY_P: 80, KEY_Z: 90, KEY_T: 84,
    KEY_C: 67, KEY_L: 76, KEY_K: 75, KEY_M: 77, KEY_B: 66, KEY_E: 69,
    WHITE: {}, RAYWHITE: {},
    SHADER_UNIFORM_FLOAT: 0, SHADER_UNIFORM_VEC2: 1, SHADER_UNIFORM_VEC3: 2,
    SHADER_UNIFORM_VEC4: 3, SHADER_UNIFORM_INT: 4, SHADER_UNIFORM_UINT: 8,
};

const rl = Object.assign({}, constants, {
    color: () => ({}),
    initWindow: () => {}, setTargetFPS: () => {}, closeWindow: () => {}, setExitKey: () => {},
    toggleFullscreen: () => {}, isWindowFullscreen: () => false,
    loadModel: (p) => { modelPaths.push(p); const h = modelLoads; modelLoads += 1; return h; },
    // The terrain grid. The engine side is covered by the runtime surface test;
    // here the scene's use of it is what matters, so the arrays are kept for the
    // checks to inspect. The handle space is its own, so a terrain mesh can never
    // be confused with the goat (0) or a bot model.
    makeModel: (vertices, indices, normals, colors, texcoords) => {
        terrainMeshesBuilt += 1;
        lastTerrainMesh = { vertices, indices, normals, colors, texcoords };
        return 1000 + terrainMeshesBuilt;
    },
    isModelValid: () => true,
    unloadModel: () => {},
    modelBounds: () => ({ minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 1.47, maxZ: 0 }),
    modelBoneCount: () => 15,   // 13 body bones + LidL/LidR
    modelAnimationCount: () => CLIPS.length,
    modelAnimationName: (_m, i) => CLIPS[i].name,
    modelAnimationFrameCount: (_m, i) => clipFrames[i],
    modelAnimationDuration: (_m, i) => CLIPS[i].dur,
    updateModelAnimation: (_m, i, frame) => {
        // Only the player's model (handle 0) drives the state-machine checks;
        // the bots animate their own handles and would otherwise clobber them.
        if (_m === 0) lastPosed = { clip: CLIPS[i].name, frame: frame };
        else {
            botPoses += 1;
            botClipNames.add(CLIPS[i].name);
            if (CLIPS[i].name.indexOf('GoatJump') === 0) botJumps += 1;
        }
    },
    drawModelEx: (m, x, y, z) => {
        // The goat is handle 0 and the terrain meshes are 1000+; everything else
        // is a bot. Bots are drawn at the ground under them, so the recorded y
        // must equal `terrainHeight` there (`groundOffset` is 0 in this stub).
        // The goat's whole position is kept so the console test can show that
        // movement stops while the overlay is open.
        if (m === 0) { goatDrawY = y; goatDrawX = x; goatDrawZ = z; }
        else if (m < 1000) botDrawY.set(m, { x: x, y: y, z: z });
    },
    setModelShader: (_m, s) => { modelShaderCalls.push(s); },
    setModelTexture: (_m, index, tex) => { modelTextureCalls.push([index, tex]); },
    loadShaderFromMemory: (vs, fs) => {
        if (fs.indexOf('cloudiness') >= 0) skyFs = fs;
        return vs.indexOf('shadowOn') >= 0 ? 1
            : (vs.indexOf('vClip') >= 0 ? 2 : (fs.indexOf('cloudiness') >= 0 ? 3 : 0));
    },
    isShaderValid: () => true,
    getShaderLocation: () => 0,
    beginShaderMode: () => {}, endShaderMode: () => {},
    setShaderValue: () => {}, setShaderValueVector2: () => {},
    setShaderValueVector3: () => {}, setShaderValueVector4: () => {},
    setShaderValueMatrix: () => {}, setShaderValueTexture: () => {},
    loadRenderTexture: () => 5, isRenderTextureValid: () => true,
    renderTextureColor: () => 6, renderTextureDepth: () => 7,
    renderTextureSize: () => ({ x: 1024, y: 1024 }),
    beginTextureMode: () => { shadowPass = true; }, endTextureMode: () => { shadowPass = false; },
    initAudioDevice: () => {}, closeAudioDevice: () => {},
    loadSound: (p) => { soundLoads.push(p); return soundLoads.length - 1; },
    playSound: (s) => { soundsPlayed.push(s); },
    stopSound: () => {}, setSoundVolume: () => {}, setSoundPitch: () => {},
    isSoundPlaying: () => false,
    loadMusic: (p) => { musicLoads.push(p); return musicLoads.length - 1; },
    unloadMusic: () => {}, playMusic: (m) => { musicPlayed.push(m); },
    updateMusic: () => { musicUpdates += 1; }, stopMusic: () => {},
    pauseMusic: () => {}, resumeMusic: () => {},
    setMusicVolume: () => {}, setMusicPitch: () => {},
    isMusicPlaying: () => true, musicTimeLength: () => 100, musicTimePlayed: () => 0,
    makeTexture: () => 0,
    drawBillboard: () => {},
    // raygui controls (the menu screen); the harness never opens one, but the
    // engine surface should be complete.
    guiPanel: () => {}, guiGroupBox: () => {}, guiLabel: () => {},
    guiButton: () => false,
    guiToggle: (_x, _y, _w, _h, _t, v) => ({ action: 0, value: v }),
    guiSlider: (_x, _y, _w, _h, _l, _r, v) => ({ action: 0, value: v }),
    guiComboBox: (_x, _y, _w, _h, _t, v) => ({ action: 0, value: v }),
    guiProgressBar: () => { progressBarCalls += 1; return { action: 0, value: 0 }; },
    windowShouldClose: () => {
        if (frameIndex >= TOTAL) return true;
        applyInput(frameIndex);
        return false;
    },
    getFrameTime: () => 1 / 60,
    getFPS: () => 60, getScreenHeight: () => 640, getScreenWidth: () => 1000,
    isMouseButtonDown: () => false, getMouseDeltaX: () => 0, getMouseDeltaY: () => 0,
    getMouseWheelMove: () => 0,
    isKeyDown: (k) => !!keys[k],
    isKeyPressed: (k) => !!pressed[k],
    isKeyReleased: () => false, isKeyUp: (k) => !keys[k],
    getCharPressed: () => (chars.length > 0 ? chars.shift() : 0),
    getClipboardText: () => clipboard,
    setClipboardText: (text) => { clipboard = String(text); clipboardWrites.push(clipboard); },
    beginDrawing: () => {}, clearBackground: () => {}, endDrawing: () => {
        // The splash's loading frames are not part of the scripted timeline.
        if (typeof sandbox.sceneReady === 'function' && !sandbox.sceneReady()) {
            loadingFrames += 1;
            return;
        }
        timeline.push({
            i: frameIndex,
            clip: lastPosed ? lastPosed.clip : null,
            speed: speedText,
            stats: statsText,
            weather: weatherText,
        });
        // The console probe: snapshot the goat's position, the console's state
        // and the active screen at the scripted frames.
        if (consoleProbeFrames.has(frameIndex)) {
            consoleProbe[frameIndex] = {
                x: goatDrawX,
                z: goatDrawZ,
                state: JSON.parse(sandbox.sceneCommand('console').slice(3)),
                ui: sandbox.sceneCommand('ui').slice(3),
            };
        }
        frameIndex += 1;
    },
    beginMode3D: () => {}, endMode3D: () => {},
    drawCube: () => { if (shadowPass) shadowCubeDraws += 1; cubeDraws += 1; }, drawGrid: () => {},
    drawSphere: () => {}, drawPoint3D: () => {}, drawRectangleGradientV: () => {},
    drawLine: () => {},
    drawRectangle: () => {}, drawRectangleLines: () => { menuDraws += 1; }, drawText: (text) => {
        const s = String(text);
        if (s.indexOf('speed ') >= 0) speedText = s;
        else if (s.indexOf('health ') >= 0) statsText = s;
        else if (s.indexOf('wind ') >= 0) weatherText = s;
        else if (s.indexOf('Slag goat') >= 0) splashTitle = true;
        else if (s.indexOf('loading ') >= 0) splashStep = s;
    },
});

const sandbox = {
    rl,
    console: { log: (...a) => logs.push(a.join(' ')), warn: () => {}, error: () => {} },
};
vm.createContext(sandbox);

// crates/goats/src/main.rs is the single source of truth for the running order:
// the host joins the parts with `concat!`, and we parse that same list here so
// the two can never drift apart.
const gameDir = path.join(__dirname, '..', 'crates', 'goats', 'src', 'game');
const mainRs = fs.readFileSync(path.join(__dirname, '..', 'crates', 'goats', 'src', 'main.rs'), 'utf8');
const parts = [...mainRs.matchAll(/include_str!\("game\/([^"]+)"\)/g)].map((m) => m[1]);
if (parts.length === 0) throw new Error('no scene parts found in crates/goats/src/main.rs');
const source = parts.map((name) => fs.readFileSync(path.join(gameDir, name), 'utf8')).join('');
let thrown = null;
let defaultSettings = {};
// The scene must hand the loop back unloaded, so the host can paint a splash.
let readyBefore = null;
let hasLoadStep = false;
try {
    // The scene no longer self-drives (the host owns the loop -- see
    // crates/goats/src/main.rs), so evaluate it, read the settings defaults
    // before the scripted input (which presses L and friends), then start the
    // driver.
    vm.runInContext(source, sandbox, { filename: 'game.js' });
    readyBefore = typeof sandbox.sceneReady === 'function' ? sandbox.sceneReady() : null;
    hasLoadStep = typeof sandbox.sceneLoadStep === 'function';
    defaultSettings = JSON.parse(sandbox.sceneCommand('settings').slice(3));
    sandbox.run();
} catch (e) {
    thrown = e && e.stack ? e.stack : String(e);
}

const row = (i) => timeline.find((r) => r.i === i) || { clip: null, speed: '', stats: '', weather: '' };
const clipAt = (i) => row(i).clip;
// Roles with variants: accept GoatIdle / GoatIdle2 / GoatIdle3, and so on.
const isClip = (name, base) => name !== null && name.indexOf(base) === 0;
const weatherAt = (i) => row(i).weather;
function speedAt(i) {
    const m = /speed ([\d.]+) m\/s/.exec(row(i).speed);
    return m ? Number(m[1]) : null;
}
function statAt(i) {
    const m = /health (\d+)\s+energy (\d+)/.exec(row(i).stats);
    return m ? { health: Number(m[1]), energy: Number(m[2]) } : null;
}
function clockAt(i) {
    const m = /^(\d\d):(\d\d)/.exec(row(i).speed);
    return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}
function lightAt(i) {
    const m = /light (lit \+ shadow map|lit \+ planar shadow|lit|off|cube shader)/.exec(row(i).speed);
    return m ? m[1] : null;
}
function audioAt(i) {
    const m = /audio (on|muted|off)/.exec(row(i).speed);
    return m ? m[1] : null;
}
function skyAt(i) {
    const m = /sky (shader|billboards)/.exec(row(i).speed);
    return m ? m[1] : null;
}

let deathFrame = -1;
for (const r of timeline) {
    if (r.clip === 'GoatDeath') { deathFrame = r.i; break; }
}
const e20 = statAt(20);
const e60 = statAt(60);
const deadStats = deathFrame >= 0 ? statAt(deathFrame) : null;
const botLine = logs.find((l) => l.indexOf('bot goats') >= 0) || '';
const botCount = Number((/goat: (\d+) bot goats/.exec(botLine) || [])[1] || 0);
const gapVals = logs.map((l) => /gap (-?[\d.]+)/.exec(l)).filter(Boolean).map((m) => Number(m[1]));
const minGap = gapVals.length ? Math.min.apply(null, gapVals) : null;
const botIdles = [...botClipNames].filter((n) => n.indexOf('GoatIdle') === 0);
const playerIdles = [...new Set(timeline.map((r) => r.clip))].filter((n) => n && n.indexOf('GoatIdle') === 0);

// Embedding drift check: every asset the scene asks for must appear in the
// `ASSETS` table in crates/goats/src/main.rs, otherwise the binary silently
// falls back to a file on disk and stops being self-contained.
const embeddedNames = new Set(
    [...mainRs.matchAll(/\(\s*"([^"]+)"\s*,\s*include_bytes!/g)].map((m) => m[1]));
const requestedAssets = [...new Set([...modelPaths, ...musicLoads, ...soundLoads])];
const missingAssets = requestedAssets.filter((p) => !embeddedNames.has(p));

// Grass is food. `run()` has finished, so exercise the mechanic through the
// same command channel the host uses: find a tuft, stand on it, then eat it.
const eatTest = { found: false, menu: false, ate: false, energyRose: false, satietyRose: false, faced: false, gone: false, regrew: false };
let rainEase = false;
let botEats = 0;
let botSatiety = 0;
try {
    // `eaten` counts every tuft consumed this run; nothing pressed E, so a
    // nonzero count means the bots have been grazing.
    const afterRun = JSON.parse(sandbox.sceneCommand('state').slice(3));
    botEats = afterRun.eaten;
    botSatiety = afterRun.satiety;
    sandbox.sceneCommand('energy 40');
    const found = JSON.parse(sandbox.sceneCommand('grass').slice(3));
    if (found !== null && found !== undefined) {
        eatTest.found = true;
        // Stand half a metre short of the tuft, facing away, so the eat's facing
        // snap is observable.
        sandbox.sceneCommand('pos ' + (found.x - 0.5) + ' ' + found.z);
        sandbox.sceneCommand('yaw 180');
        const before = JSON.parse(sandbox.sceneCommand('state').slice(3));
        eatTest.menu = before.foodInReach === true;
        const reply = sandbox.sceneCommand('eat');
        const after = JSON.parse(sandbox.sceneCommand('state').slice(3));
        eatTest.ate = reply.indexOf('ok') === 0;
        eatTest.energyRose = after.energy > before.energy;
        eatTest.satietyRose = after.satiety > 0;
        // The goat turns onto the tuft (yaw 0 faces +x, where the tuft lies).
        eatTest.faced = Math.abs(after.yaw) < 0.2;
        const again = JSON.parse(sandbox.sceneCommand('grass').slice(3));
        eatTest.gone = again === null || again.key !== found.key;
        // Run the food clock past the longest regrow delay; the tuft returns.
        sandbox.updateFood(200);
        const regrown = JSON.parse(sandbox.sceneCommand('grass').slice(3));
        eatTest.regrew = regrown !== null && regrown.key === found.key;
    }
    rainEase = sandbox.rainSlowFactor(0) > sandbox.rainSlowFactor(1);
} catch (e) {
    eatTest.error = String(e);
}
const botEatClips = [...botClipNames].filter((n) => n.indexOf('GoatEat') === 0).length;

// Settings and screens are reachable through the command channel too.
let settingsDefaults = false;
let settingsApplied = false;
let cloudLevels = false;
let herdGrew = false;
let herdShrank = false;
let screenSet = false;
try {
    const s = defaultSettings;
    settingsDefaults = s.bgm === 90 && s.sfx === 90 && s.light === true &&
        s.shadow === 'map' && s.sky === true && s.cloud === 'medium' &&
        s.fullscreen === true && s.herd === 7;
    sandbox.sceneCommand('setting light off');
    sandbox.sceneCommand('setting shadow planar');
    sandbox.sceneCommand('setting sky off');
    sandbox.sceneCommand('setting herd 9');
    const f = JSON.parse(sandbox.sceneCommand('features').slice(3));
    const nine = JSON.parse(sandbox.sceneCommand('bots').slice(3)).count;
    sandbox.sceneCommand('setting herd 3');
    const three = JSON.parse(sandbox.sceneCommand('bots').slice(3)).count;
    settingsApplied = f.lighting === false && f.shadows === 'planar' && f.sky === false;
    sandbox.sceneCommand('setting fullscreen off');
    const fsOff = JSON.parse(sandbox.sceneCommand('settings').slice(3)).fullscreen === false;
    sandbox.sceneCommand('setting fullscreen on');
    settingsApplied = settingsApplied && fsOff;
    herdGrew = nine === 9;
    herdShrank = three === 3;
    sandbox.sceneCommand('setting light on');
    sandbox.sceneCommand('setting shadow map');
    sandbox.sceneCommand('setting sky on');
    sandbox.sceneCommand('setting herd 7');
    sandbox.sceneCommand('setting cloud low');
    const cloudLow = JSON.parse(sandbox.sceneCommand('settings').slice(3)).cloud === 'low';
    sandbox.sceneCommand('setting cloud high');
    const cloudHigh = JSON.parse(sandbox.sceneCommand('features').slice(3)).cloud === 'high';
    sandbox.sceneCommand('setting cloud medium');
    cloudLevels = cloudLow && cloudHigh &&
        JSON.parse(sandbox.sceneCommand('settings').slice(3)).cloud === 'medium';
    screenSet = sandbox.sceneCommand('ui settings') === 'ok ui settings' &&
        sandbox.sceneCommand('ui') === 'ok settings';
    sandbox.sceneCommand('ui hud');
} catch (e) {
    eatTest.uiError = String(e);
}
// Direct proof the visuals follow the model: drawn tufts drop when one is eaten.
let tuftVanishes = false;
let tuftDrawDrop = null;
try {
    const tuft = sandbox.nearestTuft(0, 0, 20);
    if (tuft !== null) {
        cubeDraws = 0;
        sandbox.drawTufts({ px: 0, pz: 0 }, 0, 576, 180);
        const drawnBefore = cubeDraws;
        sandbox.consumeTuft(tuft);
        cubeDraws = 0;
        sandbox.drawTufts({ px: 0, pz: 0 }, 0, 576, 180);
        const drawnAfter = cubeDraws;
        tuftDrawDrop = drawnBefore - drawnAfter;
        tuftVanishes = drawnAfter < drawnBefore;
    }
} catch (e) {
    eatTest.drawError = String(e);
}
const bellyLog = logs.map((l) => /bellyMax ([\d.]+)/.exec(l)).filter(Boolean).map((m) => Number(m[1]));
const botBellyMax = bellyLog.length ? Math.max.apply(null, bellyLog) : 0;
const botFed = botBellyMax > 0;
const grazeWalks = logs.map((l) => /grazeWalks (\d+)/.exec(l)).filter(Boolean).map((m) => Number(m[1]));
const botGrazeWalks = grazeWalks.length ? Math.max.apply(null, grazeWalks) : 0;

// ---- terrain -------------------------------------------------------------
// The heightfield, the mesh it feeds and the goat's placement on it. The engine
// side (`rl.makeModel`) is covered by the runtime surface test; here the question
// is whether the scene uses it: a field that is not flat, a level spawn bowl, a
// grid carrying real normals/UVs/material colours, and the goat drawn on the
// surface.
let terrainSpread = 0;
let terrainFlatAtSpawn = false;
let terrainMeshOk = false;
let terrainMaterials = 0;
let terrainStandOk = false;
let herdStandsOk = false;
try {
    let lo = 1e9;
    let hi = -1e9;
    for (let x = -60; x <= 60; x += 3) {
        for (let z = -60; z <= 60; z += 3) {
            const h = sandbox.terrainHeight(x, z);
            if (h < lo) lo = h;
            if (h > hi) hi = h;
        }
    }
    terrainSpread = hi - lo;
    terrainFlatAtSpawn = Math.abs(sandbox.terrainHeight(0, 0)) < 1e-9 &&
        Math.abs(sandbox.terrainHeight(4, -3)) < 1e-9;
    const m = lastTerrainMesh;
    if (m !== null) {
        const verts = m.vertices.length / 3;
        let vlo = 1e9;
        let vhi = -1e9;
        for (let i = 1; i < m.vertices.length; i += 3) {
            if (m.vertices[i] < vlo) vlo = m.vertices[i];
            if (m.vertices[i] > vhi) vhi = m.vertices[i];
        }
        const seen = new Set();
        for (let i = 0; i < m.colors.length; i += 4) {
            seen.add(m.colors[i] + ',' + m.colors[i + 1] + ',' + m.colors[i + 2]);
        }
        terrainMaterials = seen.size;
        terrainMeshOk = verts === 49 * 49 && vhi - vlo > 0.5 &&
            m.indices.length === 48 * 48 * 6 &&
            m.normals.length === verts * 3 && m.colors.length === verts * 4 &&
            m.texcoords.length === verts * 2;
    }
    const final = JSON.parse(sandbox.sceneCommand('state').slice(3));
    terrainStandOk = goatDrawY !== null && typeof goatDrawY === 'number' &&
        Math.abs(goatDrawY - sandbox.terrainHeight(final.x, final.z)) < 0.02;
    herdStandsOk = botDrawY.size > 0;
    for (const d of botDrawY.values()) {
        if (Math.abs(d.y - sandbox.terrainHeight(d.x, d.z)) > 1e-6) herdStandsOk = false;
    }
} catch (e) {
    terrainError = String(e);
}

// Network bridge (M10): the scene end of it is pure JS, so the harness drives it
// with no socket and no peer. `sceneNetDrain` is what the host calls each frame
// and `sceneNetEvent` is what it feeds back.
let netTest = {};
try {
    netTest.drainEmpty = sandbox.sceneNetDrain() === '';

    netTest.hostReply = sandbox.sceneCommand('host bob');
    const hostIntent = sandbox.sceneNetDrain();
    netTest.hostQueued = netTest.hostReply === 'ok host' &&
        hostIntent.indexOf('"type":"host"') >= 0 && hostIntent.indexOf('"name":"bob"') >= 0;
    netTest.drained = sandbox.sceneNetDrain() === '';   // the queue clears

    sandbox.sceneNetEvent('{"type":"hosting","name":"bob"}');
    sandbox.sceneNetEvent('{"type":"ticket","ticket":"endpointXYZ"}');
    sandbox.sceneNetEvent('{"type":"roster","names":["bob","alice"]}');
    const status = JSON.parse(sandbox.sceneCommand('net').slice(3));
    netTest.status = status.mode === 'host' && status.name === 'bob' &&
        status.ticket === 'endpointXYZ' && status.roster.length === 2;

    sandbox.sceneNetEvent('{"type":"joined","name":"alice"}');
    const consoleState = JSON.parse(sandbox.sceneCommand('console').slice(3));
    netTest.printed = consoleState.lines.some((l) => l.indexOf('alice joined') >= 0) &&
        consoleState.lines.some((l) => l.indexOf('roster bob, alice') >= 0);

    netTest.duplicate = sandbox.sceneCommand('host bob') === 'error already in a session (leave first)';
    netTest.left = sandbox.sceneCommand('leave') === 'ok leave' &&
        sandbox.sceneNetDrain().indexOf('"type":"close"') >= 0;

    sandbox.sceneNetEvent('{"type":"disconnected"}');
    netTest.reset = JSON.parse(sandbox.sceneCommand('net').slice(3)).mode === 'off';

    netTest.noTicket = sandbox.sceneCommand('connect') === 'error connect expects a ticket';
    netTest.joinQueued = sandbox.sceneCommand('connect endpointABC alice') === 'ok connect' &&
        sandbox.sceneNetDrain().indexOf('"ticket":"endpointABC"') >= 0;

    // A username prompt: the command asks, the next console line answers. The
    // outbox is cleared first because the join above queued an intent.
    sandbox.sceneNetDrain();
    netTest.promptReply = sandbox.sceneCommand('host');
    const promptState = JSON.parse(sandbox.sceneCommand('console').slice(3));
    netTest.promptAsked = netTest.promptReply === 'ok name?' && promptState.open === true &&
        promptState.lines.some((l) => l.indexOf('Username?') >= 0);
    sandbox.sceneCommand('console say carol');
    netTest.promptAnswered = sandbox.sceneNetDrain().indexOf('"name":"carol"') >= 0;

    // Master mute has to reach the host: the voice mixer is Rust's, so the
    // scene's only lever is the gain intent. Muted queues 0, unmuted queues
    // nothing at rest (its default already matches the host's).
    sandbox.setMuted(true);
    const muteIntent = sandbox.sceneNetDrain();
    netTest.voiceMuted = muteIntent.indexOf('"type":"voice_gain"') >= 0 &&
        muteIntent.indexOf('"gain":0') >= 0;
    sandbox.setMuted(false);
    sandbox.sceneNetDrain();
} catch (e) {
    netTest.error = String(e);
}

// Chat (M11): the scene end of it is queueing the line and printing what comes
// back. The routing is the server's, covered by the session tests.
let chatTest = {};
try {
    // Pretend to be in a session, so bare text is chat rather than an error.
    sandbox.sceneNetEvent('{"type":"hosting","name":"bob"}');
    sandbox.sceneNetDrain();

    // Bare text is global chat, and queues silently: no `ok` per line.
    const bareReply = sandbox.sceneCommand('hello everyone');
    chatTest.bare = bareReply === '' &&
        sandbox.sceneNetDrain().indexOf('"text":"hello everyone"') >= 0;

    // `say` is the same thing, spelled out.
    const sayReply = sandbox.sceneCommand('say hi there');
    chatTest.say = sayReply === '' &&
        sandbox.sceneNetDrain().indexOf('"text":"hi there"') >= 0;

    // `/msg` becomes the leading-`@` form the server routes for both sides.
    const msgReply = sandbox.sceneCommand('/msg alice psst');
    chatTest.msg = msgReply === '' &&
        sandbox.sceneNetDrain().indexOf('"text":"@alice psst"') >= 0;

    // A leading `@` typed directly is a whisper too.
    const atReply = sandbox.sceneCommand('@carol yo');
    chatTest.at = atReply === '' &&
        sandbox.sceneNetDrain().indexOf('"text":"@carol yo"') >= 0;

    // The slash forms still reach the commands they name.
    chatTest.slashCommand = sandbox.sceneCommand('/who').indexOf('ok ') === 0;

    // Offline, bare text stays an error, so a typo is caught rather than sent.
    sandbox.sceneNetEvent('{"type":"disconnected"}');
    chatTest.offline = sandbox.sceneCommand('hello?') === 'error unknown command: hello?';

    // A chat line prints into the scrollback, whispers marked.
    sandbox.sceneNetEvent('{"type":"chat","from":"alice","text":"hello all","direct":false}');
    sandbox.sceneNetEvent('{"type":"chat","from":"alice","text":"psst","direct":true}');
    const lines = JSON.parse(sandbox.sceneCommand('console').slice(3)).lines;
    chatTest.printed = lines.some((l) => l.indexOf('net: alice: hello all') >= 0) &&
        lines.some((l) => l.indexOf('net: dm alice: psst') >= 0);
} catch (e) {
    chatTest.error = String(e);
}

// World sync (M12): the seed handshake re-keys the streams, the local pose goes
// out on the datagram cadence, and peer snapshots become remote goats.
let syncTest = {};
try {
    // A session seed re-keys every stream, reproducibly, and a different seed
    // builds a different world.
    const before = sandbox.sceneStreams();
    sandbox.sceneNetEvent('{"type":"session","seed":4242}');
    const a = sandbox.sceneStreams();
    sandbox.sceneNetEvent('{"type":"session","seed":4242}');
    const b = sandbox.sceneStreams();
    sandbox.sceneNetEvent('{"type":"session","seed":99}');
    const c = sandbox.sceneStreams();
    syncTest.seeded = a.weather !== before.weather && a.weather === b.weather &&
        a.bots === b.bots && a.food === b.food && a.audio === b.audio;
    syncTest.seedDiffers = c.weather !== a.weather;

    // In a session the local goat is published, once per throttle window and
    // not again in the same frame.
    sandbox.sceneNetEvent('{"type":"hosting","name":"bob"}');
    const first = sandbox.sceneNetDrain();
    syncTest.pose = first.indexOf('"type":"pose"') >= 0 && first.indexOf('"gait"') >= 0;
    syncTest.poseThrottled = sandbox.sceneNetDrain().indexOf('"type":"pose"') < 0;
    // A host also owns the world and publishes its bots.
    syncTest.world = first.indexOf('"type":"world"') >= 0 &&
        first.indexOf('"bots"') >= 0 && first.indexOf('"weather"') >= 0;

    // A snapshot becomes a goat; a later one moves it; leaving removes it.
    sandbox.sceneNetEvent('{"type":"peer","name":"alice","state":{"x":3,"z":4,"yaw":0,"phase":0,"speed":0,"gait":"idle"}}');
    sandbox.sceneNetEvent('{"type":"peer","name":"alice","state":{"x":5,"z":6,"yaw":1,"phase":0.5,"speed":2,"gait":"trot"}}');
    const peers = sandbox.scenePeers();
    syncTest.peerAdded = peers.length === 1 && peers[0].name === 'alice' &&
        peers[0].tx === 5 && peers[0].tz === 6 && peers[0].gait === 'trot';
    sandbox.sceneNetEvent('{"type":"left","name":"alice"}');
    syncTest.peerLeft = sandbox.scenePeers().length === 0;
    sandbox.sceneNetEvent('{"type":"disconnected"}');

    // A client mirrors the server's bots, sky, streams and meadow, and publishes
    // no world of its own.
    sandbox.sceneNetEvent('{"type":"welcome","name":"eve"}');
    syncTest.clientNotLocal = sandbox.netWorldLocal() === false &&
        sandbox.netWeatherLocal() === false;
    sandbox.sceneNetEvent('{"type":"world","weather":' +
        '{"kind":"rain","cloudiness":0.9,"rain_amount":0.8,' +
        '"wind_x":1.5,"wind_z":-0.5,"wind_sway":1.2,"world_time":21.5},' +
        '"streams":{"weather":111,"bots":222,"food":333,"audio":444},' +
        '"eaten":[{"key":4242,"left":12.5}],"bots":[' +
        '{"index":0,"x":9,"z":9,"yaw":0,"phase":0.5,"gait":"walk","variant":0},' +
        '{"index":1,"x":-9,"z":-9,"yaw":1,"phase":0.25,"gait":"idle","variant":2}]}');
    const mirrored = sandbox.sceneWorldBots();
    syncTest.mirror = mirrored.length === 2 && mirrored[0].x === 9 &&
        mirrored[1].z === -9 && mirrored[1].gait === 'idle';
    const mirroredWeather = sandbox.sceneWeatherState();
    syncTest.weatherMirror = mirroredWeather.kind === 'rain' &&
        mirroredWeather.rain_amount === 0.8 && mirroredWeather.world_time === 21.5;
    const mirroredStreams = sandbox.sceneStreams();
    syncTest.streamsMirror = mirroredStreams.food === 333 && mirroredStreams.audio === 444;
    const mirroredEaten = sandbox.sceneEaten();
    syncTest.eatenMirror = mirroredEaten.length === 1 && mirroredEaten[0].key === 4242;
    syncTest.clientIsNotAuthority =
        sandbox.sceneNetDrain().indexOf('"type":"world"') < 0;

    // A client reports its bite rather than recording it; the meadow is the
    // host's. The world above cleared the meadow, so a tuft is there to eat.
    sandbox.sceneCommand('energy 40');
    const tuft = JSON.parse(sandbox.sceneCommand('grass').slice(3));
    if (tuft !== null && tuft !== undefined) {
        sandbox.sceneCommand('pos ' + (tuft.x - 0.5) + ' ' + tuft.z);
        sandbox.sceneNetDrain();
        const reply = sandbox.sceneCommand('eat');
        syncTest.reportsEat = reply.indexOf('ok') === 0 &&
            sandbox.sceneNetDrain().indexOf('"type":"consume"') >= 0;
    }
    sandbox.sceneNetEvent('{"type":"disconnected"}');
    syncTest.worldLocalOffline = sandbox.netWorldLocal() === true &&
        sandbox.netWeatherLocal() === true;
} catch (e) {
    syncTest.error = String(e);
}

// Console (M9): the snapshots taken at the scripted frames, and a shorthand.
const cp = (i) => consoleProbe[i] ||
    { x: null, z: null, state: { open: false, input: '', lines: [], history: [] }, ui: '' };
const cpLines = (i) => cp(i).state.lines || [];

// Clipboard (M9b): paste is a key path (frames 4030-4036), so the probe carries
// it; `copy` is a command and is driven directly here.
let clipTest = {};
try {
    const pasted = cp(4032).state.input;
    clipTest.pasted = pasted.endsWith('endpointABC') && pasted.indexOf('\n') < 0;
    clipTest.copiedKey = clipboardWrites.some((w) => w.endsWith('endpointABC'));
    clipTest.copyReply = sandbox.sceneCommand('copy hello');
    clipTest.copiedVerb = clipTest.copyReply === 'ok copy' &&
        clipboardWrites[clipboardWrites.length - 1] === 'hello';
    clipTest.nothing = sandbox.sceneCommand('copy') === 'error nothing to copy';
} catch (e) {
    clipTest.error = String(e);
}

// Tuning (M14a): the mutable tree the gameplay constants moved into. These
// reads/writes are side-effect free apart from the watchers, so the run above is
// untouched.
let tuningTest = {};
try {
    tuningTest.defaults = sandbox.tuningGet('stats.max') === 100 &&
        sandbox.tuningGet('movement.turnRate') === 1.8 &&
        sandbox.tuningGet('weather.rainSlow') === 0.28 &&
        sandbox.tuningGet('lighting.shadow.half') === 7.0;
    // A set stores the coerced value and is visible through a get.
    const set = sandbox.tuningSet('stats.jumpEnergyCost', 3.5);
    tuningTest.set = set === 3.5 && sandbox.tuningGet('stats.jumpEnergyCost') === 3.5;
    sandbox.tuningSet('stats.jumpEnergyCost', 2.0);
    // A bounded leaf clamps (camera, so no watcher fires).
    tuningTest.clamped = sandbox.tuningSet('camera.minDist', 0) === 0.1;
    sandbox.tuningSet('camera.minDist', 2.2);
    // A watcher sees the path and value, then unsubscribes.
    let sawPath = null;
    const off = sandbox.tuningWatch('stats.max', (path, value) => { sawPath = path + '=' + value; });
    sandbox.tuningSet('stats.max', 120);
    off();
    sandbox.tuningSet('stats.max', 100);
    tuningTest.watched = sawPath === 'stats.max=120';
    // A nested merge validates every leaf; a typo, a branch and a non-finite
    // write are all loud.
    sandbox.tuningMerge({ weather: { windSlow: 0.09 } });
    tuningTest.merged = sandbox.tuningGet('weather.windSlow') === 0.09;
    sandbox.tuningSet('weather.windSlow', 0.07);
    tuningTest.unknown = false;
    try { sandbox.tuningGet('stats.nope'); } catch (e) { tuningTest.unknown = true; }
    tuningTest.branch = false;
    try { sandbox.tuningSet('stats', 1); } catch (e) { tuningTest.branch = true; }
    tuningTest.notFinite = false;
    try { sandbox.tuningSet('stats.max', NaN); } catch (e) { tuningTest.notFinite = true; }
    tuningTest.all = tuningTest.defaults && tuningTest.set && tuningTest.clamped &&
        tuningTest.watched && tuningTest.merged && tuningTest.unknown &&
        tuningTest.branch && tuningTest.notFinite;
} catch (e) {
    tuningTest.error = String(e);
}

const checks = [
    ['no throw', thrown === null, thrown],
    ['idle at frame 3', isClip(clipAt(3), 'GoatIdle'), clipAt(3)],
    ['walk at frame 15', clipAt(15) === 'GoatWalk', clipAt(15)],
    ['trot at frame 40', clipAt(40) === 'GoatTrot', clipAt(40)],
    ['run at frame 60', clipAt(60) === 'GoatRun', clipAt(60)],
    ['jump starts at frame 70', isClip(clipAt(70), 'GoatJump'), clipAt(70)],
    ['landed to idle by frame 145', isClip(clipAt(145), 'GoatIdle'), clipAt(145)],
    ['sleeping at frame 160', isClip(clipAt(160), 'GoatSleep'), clipAt(160)],
    ['woke to walk at frame 190', clipAt(190) === 'GoatWalk', clipAt(190)],
    ['walk speed ~0.87 m/s', Math.abs((speedAt(15) || 0) - 0.873) < 0.01, speedAt(15)],
    ['trot speed ~1.58 m/s', Math.abs((speedAt(40) || 0) - 1.577) < 0.02, speedAt(40)],
    ['run speed ~2.94 m/s', Math.abs((speedAt(60) || 0) - 2.941) < 0.02, speedAt(60)],
    ['energy drains while running', e20 && e60 && e60.energy < e20.energy, [e20, e60]],
    ['clock advances over time', clockAt(20) !== null && clockAt(1200) > clockAt(20),
        [clockAt(20), clockAt(1200)]],
    ['weather text is reported', weatherAt(300) !== null && weatherAt(300).length > 0,
        weatherAt(300)],
    ['C changes the weather', weatherAt(2999) !== weatherAt(3200),
        [weatherAt(2999), weatherAt(3200)]],
    ['lighting is active', lightAt(15) === 'lit + shadow map', lightAt(15)],
    ['model uses the lit shader', modelShaderCalls.indexOf(0) >= 0, modelShaderCalls.slice(0, 4)],
    ['depth pass uses the depth shader', modelShaderCalls.indexOf(2) >= 0, modelShaderCalls.slice(0, 6)],
    ['grass casts in the shadow pass', shadowCubeDraws > 0, shadowCubeDraws],
    ['shadow map bound to the model', modelTextureCalls.some((c) => c[0] === 1 && c[1] === 6),
        modelTextureCalls.slice(0, 4)],
    ['L toggles lighting off', lightAt(3210) === 'off', lightAt(3210)],
    ['background music plays', musicPlayed.indexOf(0) >= 0, musicPlayed.slice(0, 4)],
    ['music streams are updated', musicUpdates > 0, musicUpdates],
    ['ambience beds load', musicLoads.length >= 3, musicLoads.length],
    ['the goat bleats on jump', soundsPlayed.length > 0, soundsPlayed.length],
    ['audio is reported', audioAt(15) === 'on', audioAt(15)],
    ['the sky shader is used', skyAt(15) === 'shader', skyAt(15)],
    // Frame 3400 is deterministically walking in ~15% rain (see the weather
    // PRNG), so its speed must be below the dry walk speed.
    ['rain is reported at the test frame', row(3400).weather.indexOf('rain ') >= 0, row(3400).weather],
    ['rain slows the goat', speedAt(3400) !== null && speedAt(3400) < speedAt(15) - 0.01,
        [speedAt(15), speedAt(3400)]],
    ['goat dies of exhaustion', deathFrame > 200 && deathFrame < 3950, deathFrame],
    ['death clip held while dead', clipAt(deathFrame + 5) === 'GoatDeath', clipAt(deathFrame + 5)],
    ['health is zero at death', deadStats !== null && deadStats.health === 0, deadStats],
    ['R restarts into run', clipAt(4000) === 'GoatRun', clipAt(4000)],
    ['bot goats load', botCount >= 2, botLine],
    ['bots animate their own models', botPoses > 0, botPoses],
    ['goats never overlap', minGap !== null && minGap > -0.12, minGap],
    ['bots get the zoomies (run + jump)', botJumps > 0, botJumps],
    ['bots play several idle variants', botIdles.length >= 2, botIdles],
    ['the player cycles idle variants', playerIdles.length >= 2, playerIdles],
    ['grass tufts are found', eatTest.found, eatTest],
    ['the model has eating clips', logs.some((l) => l.indexOf("'GoatEat") >= 0), logs.filter((l) => l.indexOf('GoatEat') >= 0).length],
    ['the eat menu is drawn in reach', menuDraws > 0, menuDraws],
    ['grass in reach shows the eat menu', eatTest.menu, eatTest],
    ['eating consumes the nearest tuft', eatTest.ate && eatTest.gone, eatTest],
    ['eating turns the goat onto the grass', eatTest.faced, eatTest],
    ['eating restores energy', eatTest.energyRose, eatTest],
    ['eating fills the belly', eatTest.satietyRose, eatTest],
    ['a full belly eases the rain slowdown', rainEase, rainEase],
    ['bots graze the field', botEats > 0, botEats],
    ['bots fill their own belly', botFed, botBellyMax],
    ['bots walk to a tuft to eat', botGrazeWalks > 0, botGrazeWalks],
    ['bots do not feed the player', botSatiety === 0, botSatiety],
    ['bots play the eating clip', botEatClips >= 1, botEatClips],
    ['eaten grass regrows', eatTest.regrew, eatTest],
    ['eaten grass stops being drawn', tuftVanishes, tuftDrawDrop],
    ['settings default to the spec', settingsDefaults, null],
    ['cloud quality can be set', cloudLevels, null],
    ['tuning tree carries the defaults', tuningTest.defaults, tuningTest],
    ['tuning set/get round-trips', tuningTest.set, tuningTest],
    ['tuning clamps a bounded leaf', tuningTest.clamped, tuningTest],
    ['tuning watchers fire and unsubscribe', tuningTest.watched, tuningTest],
    ['tuning merge validates every leaf', tuningTest.merged, tuningTest],
    ['tuning rejects unknown, branch and non-finite writes',
        tuningTest.unknown && tuningTest.branch && tuningTest.notFinite, tuningTest],
    // The volumetric march, not the flat M5 layer: these markers only exist in
    // the slab marcher.
    ['the sky shader marches a volume',
        skyFs.indexOf('sunTau') >= 0 && skyFs.indexOf('cloudSteps') >= 0 &&
        skyFs.indexOf('slabY') >= 0 && skyFs.indexOf('hg(') >= 0, skyFs.length],
    // The sun and moon discs come from `drawCelestial` as sprites over this pass,
    // so a smoothstep on the sun dot here would draw a second disc.
    ['the sky shader leaves the discs to drawCelestial',
        skyFs.indexOf('smoothstep(0.999') < 0, skyFs.indexOf('smoothstep(0.999')],
    ['settings apply to the world', settingsApplied, null],
    ['herd size grows the herd', herdGrew, null],
    ['herd size shrinks the herd', herdShrank, null],
    ['menu screens can be opened', screenSet, null],
    // Splash: the scene starts unloaded, the loop takes one step per frame and
    // paints a progress bar, then the game begins on the frame after the last
    // step (so `loadTotal - 1` loading frames are drawn for the default herd).
    ['the scene starts unloaded', readyBefore === false && hasLoadStep, readyBefore],
    ['the loader takes one step per frame', loadingFrames === 9 + 7 - 1, loadingFrames],
    ['the splash draws a progress bar', progressBarCalls === loadingFrames && progressBarCalls > 0,
        [progressBarCalls, loadingFrames]],
    ['the splash names the game and step count',
        splashTitle && splashStep === 'loading 15 / 16', [splashTitle, splashStep]],
    // Self-contained binary: the scene must not reach the filesystem for assets.
    ['every requested asset is embedded', requestedAssets.length >= 10 && missingAssets.length === 0,
        missingAssets],
    ['the embedded table covers model and audio', embeddedNames.size >= 13, embeddedNames.size],
    // Terrain: the field, the mesh built from it, and the goat standing on it.
    ['no terrain errors', terrainError === null, terrainError],
    ['the terrain is not flat', terrainSpread > 1.5, terrainSpread],
    ['the spawn bowl stays level', terrainFlatAtSpawn, null],
    ['the terrain is one grid with normals, UVs and colours', terrainMeshOk,
        lastTerrainMesh ? lastTerrainMesh.vertices.length / 3 : null],
    ['the terrain mesh carries several materials', terrainMaterials >= 4, terrainMaterials],
    ['the goat stands on the terrain', terrainStandOk, goatDrawY],
    ['the herd stands on the terrain', herdStandsOk, botDrawY.size],
    // Console (M9): the overlay opens, takes typed input, runs it through the
    // same dispatcher as the stdin channel, and freezes the goat while open.
    ['the console starts closed', cp(4008).state.open === false, cp(4008).state.open],
    ['backquote opens the console', cp(4011).state.open === true, cp(4011).state.open],
    ['the console echoes what was typed', cpLines(4016).indexOf('echo: > ping') >= 0, cpLines(4016)],
    ['the console runs the command', cpLines(4016).indexOf('local: ok pong') >= 0, cpLines(4016)],
    ['the console keeps command history', cp(4016).state.history.indexOf('ping') >= 0, cp(4016).state.history],
    ['UP recalls the last command', cp(4016).state.input === 'ping', cp(4016).state.input],
    ['ESC closes the console', cp(4018).state.open === false, cp(4018).state.open],
    ['ESC does not open the menu', cp(4018).ui === 'hud', cp(4018).ui],
    ['backquote reopens the console', cp(4021).state.open === true, cp(4021).state.open],
    ['the goat moves while the console is closed',
        cp(4007).x !== cp(4008).x || cp(4007).z !== cp(4008).z, [cp(4007), cp(4008)]],
    ['the console freezes the goat',
        cp(4009).x === cp(4011).x && cp(4009).z === cp(4011).z, [cp(4009), cp(4011)]],
    // Network bridge (M10): the scene end of it, driven without a socket.
    ['no network bridge errors', netTest.error === undefined, netTest.error],
    ['nothing is queued at rest', netTest.drainEmpty, netTest],
    ['host queues an intent and clears it', netTest.hostQueued && netTest.drained, netTest],
    ['events update the local view', netTest.status, netTest.status],
    ['events print to the console', netTest.printed, netTest],
    ['a second session is refused', netTest.duplicate, netTest],
    ['leave queues a close', netTest.left, netTest],
    ['disconnect resets the view', netTest.reset, netTest],
    ['connect without a ticket is an error', netTest.noTicket, netTest],
    ['connect queues a join', netTest.joinQueued, netTest],
    ['host without a name asks for one', netTest.promptAsked, netTest],
    ['the prompt answer is used', netTest.promptAnswered, netTest],
    ['muting tells the host to silence voice', netTest.voiceMuted, netTest],
    // Clipboard (M9b): a ticket is too long to type, so paste has to work.
    ['the console pastes and strips the newline', clipTest.pasted, clipTest],
    ['Ctrl+C copies the line', clipTest.copiedKey, clipTest],
    ['the copy verb writes the clipboard', clipTest.copiedVerb, clipTest],
    ['copy with nothing to copy is an error', clipTest.nothing, clipTest],
    ['no clipboard errors', clipTest.error === undefined, clipTest.error],
    // Chat (M11): the scene end of it; the routing is the server's.
    ['no chat errors', chatTest.error === undefined, chatTest.error],
    ['bare text is chat in a session', chatTest.bare, chatTest],
    ['say is chat, spelled out', chatTest.say, chatTest],
    ['/msg becomes a leading @name', chatTest.msg, chatTest],
    ['a leading @name is chat too', chatTest.at, chatTest],
    ['slash commands still reach commands', chatTest.slashCommand, chatTest],
    ['bare text is an error offline', chatTest.offline, chatTest],
    ['chat lines print, whispers marked', chatTest.printed, chatTest],
    // World sync (M12): seed handshake and the snapshot channel, scene end.
    ['a session seed re-keys every stream', syncTest.seeded, syncTest],
    ['a different seed builds a different world', syncTest.seedDiffers, syncTest],
    ['a session publishes the goat pose', syncTest.pose, syncTest],
    ['the pose channel is throttled per frame', syncTest.poseThrottled, syncTest],
    ['a peer snapshot becomes a remote goat', syncTest.peerAdded, syncTest],
    ['leaving removes the remote goat', syncTest.peerLeft, syncTest],
    ['a host publishes its bots', syncTest.world, syncTest],
    ['a client mirrors the server bots', syncTest.mirror, syncTest],
    ['a client mirrors the server weather', syncTest.weatherMirror, syncTest],
    ['a client adopts the server streams', syncTest.streamsMirror, syncTest],
    ['a client mirrors the server meadow', syncTest.eatenMirror, syncTest],
    ['a client reports its own bite', syncTest.reportsEat, syncTest],
    ['a client does not simulate or publish the bots',
        syncTest.clientNotLocal && syncTest.clientIsNotAuthority, syncTest],
    ['offline simulates the bots and the weather locally', syncTest.worldLocalOffline, syncTest],
    ['no world sync errors', syncTest.error === undefined, syncTest.error],
];

const failed = checks.filter((c) => !c[1]);
console.log('--- goat scene logic test ---');
console.log('model line:', logs.filter((l) => l.indexOf('model handle') >= 0).join(' | '));
console.log('shadow line:', logs.filter((l) => l.indexOf('shadow map') >= 0).join(' | '));
console.log('terrain line:', logs.filter((l) => l.indexOf('terrain:') >= 0)[0]);
console.log('death frame:', deathFrame, 'stats:', JSON.stringify(deadStats));
console.log('bot herd:', botCount, 'bot poses:', botPoses, 'bot jumps:', botJumps, 'min gap:', minGap);
console.log('bot idle variants:', botIdles.join(','), '| player idle variants:', playerIdles.join(','));
for (const [name, ok, got] of checks) {
    console.log((ok ? 'PASS' : 'FAIL') + '  ' + name + (ok ? '' : '  (got ' + JSON.stringify(got) + ')'));
}
console.log('---');
console.log(failed.length === 0 ? 'ALL PASS (' + checks.length + ')' : failed.length + ' FAILED');
process.exit(failed.length === 0 ? 0 : 1);

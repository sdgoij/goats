// Headless harness for the scene in src/game/: stubs the `rl` surface, drives a scripted
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
];
const clipFrames = CLIPS.map((c) => Math.round(c.dur * 60) + 1);

let frameIndex = 0;
let lastPosed = null;
let modelLoads = 0;
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

const keys = {};
const pressed = {};

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
}

const constants = {
    MOUSE_BUTTON_LEFT: 0,
    KEY_SPACE: 32, KEY_ESCAPE: 256,
    KEY_RIGHT: 262, KEY_LEFT: 263, KEY_DOWN: 264, KEY_UP: 265,
    KEY_LEFT_SHIFT: 340, KEY_RIGHT_SHIFT: 344,
    KEY_LEFT_CONTROL: 341, KEY_RIGHT_CONTROL: 345,
    KEY_A: 65, KEY_D: 68, KEY_R: 82, KEY_S: 83, KEY_W: 87, KEY_P: 80, KEY_Z: 90, KEY_T: 84,
    KEY_C: 67, KEY_L: 76, KEY_K: 75, KEY_M: 77, KEY_B: 66,
    WHITE: {}, RAYWHITE: {},
    SHADER_UNIFORM_FLOAT: 0, SHADER_UNIFORM_VEC2: 1, SHADER_UNIFORM_VEC3: 2,
    SHADER_UNIFORM_VEC4: 3, SHADER_UNIFORM_INT: 4, SHADER_UNIFORM_UINT: 8,
};

const rl = Object.assign({}, constants, {
    color: () => ({}),
    initWindow: () => {}, setTargetFPS: () => {}, closeWindow: () => {},
    loadModel: () => { const h = modelLoads; modelLoads += 1; return h; },
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
    drawModelEx: () => {},
    setModelShader: (_m, s) => { modelShaderCalls.push(s); },
    setModelTexture: (_m, index, tex) => { modelTextureCalls.push([index, tex]); },
    loadShaderFromMemory: (vs, fs) => (vs.indexOf('shadowOn') >= 0 ? 1
        : (vs.indexOf('vClip') >= 0 ? 2 : (fs.indexOf('cloudiness') >= 0 ? 3 : 0))),
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
    beginDrawing: () => {}, clearBackground: () => {}, endDrawing: () => {
        timeline.push({
            i: frameIndex,
            clip: lastPosed ? lastPosed.clip : null,
            speed: speedText,
            stats: statsText,
            weather: weatherText,
        });
        frameIndex += 1;
    },
    beginMode3D: () => {}, endMode3D: () => {},
    drawCube: () => { if (shadowPass) shadowCubeDraws += 1; }, drawGrid: () => {},
    drawSphere: () => {}, drawPoint3D: () => {}, drawRectangleGradientV: () => {},
    drawLine: () => {},
    drawRectangle: () => {}, drawText: (text) => {
        const s = String(text);
        if (s.indexOf('speed ') >= 0) speedText = s;
        else if (s.indexOf('health ') >= 0) statsText = s;
        else if (s.indexOf('wind ') >= 0) weatherText = s;
    },
});

const sandbox = {
    rl,
    console: { log: (...a) => logs.push(a.join(' ')), warn: () => {}, error: () => {} },
};
vm.createContext(sandbox);

// src/main.rs is the single source of truth for the running order: the host
// joins the parts with `concat!`, and we parse that same list here so the two
// can never drift apart.
const gameDir = path.join(__dirname, '..', 'src', 'game');
const mainRs = fs.readFileSync(path.join(__dirname, '..', 'src', 'main.rs'), 'utf8');
const parts = [...mainRs.matchAll(/include_str!\("game\/([^"]+)"\)/g)].map((m) => m[1]);
if (parts.length === 0) throw new Error('no src/game parts found in src/main.rs');
const source = parts.map((name) => fs.readFileSync(path.join(gameDir, name), 'utf8')).join('');
let thrown = null;
try {
    vm.runInContext(source, sandbox, { filename: 'game.js' });
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
];

const failed = checks.filter((c) => !c[1]);
console.log('--- goat scene logic test ---');
console.log('model line:', logs.filter((l) => l.indexOf('model handle') >= 0).join(' | '));
console.log('shadow line:', logs.filter((l) => l.indexOf('shadow map') >= 0).join(' | '));
console.log('death frame:', deathFrame, 'stats:', JSON.stringify(deadStats));
console.log('bot herd:', botCount, 'bot poses:', botPoses, 'bot jumps:', botJumps, 'min gap:', minGap);
console.log('bot idle variants:', botIdles.join(','), '| player idle variants:', playerIdles.join(','));
for (const [name, ok, got] of checks) {
    console.log((ok ? 'PASS' : 'FAIL') + '  ' + name + (ok ? '' : '  (got ' + JSON.stringify(got) + ')'));
}
console.log('---');
console.log(failed.length === 0 ? 'ALL PASS (' + checks.length + ')' : failed.length + ' FAILED');
process.exit(failed.length === 0 ? 0 : 1);

// Headless harness for src/goat.js: stubs the `rl` surface, drives a scripted
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
    { name: 'GoatWalk', dur: 0.91667 },
    { name: 'GoatTrot', dur: 0.58333 },
    { name: 'GoatRun', dur: 0.5 },
    { name: 'GoatJump', dur: 1.16667 },
    { name: 'GoatSleep', dur: 8.0 },
    { name: 'GoatDeath', dur: 1.79167 },
];
const clipFrames = CLIPS.map((c) => Math.round(c.dur * 60) + 1);

let frameIndex = 0;
let lastPosed = null;
let speedText = '';
let statsText = '';
const timeline = [];
const logs = [];

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
    if (i === 3950) pressed[82] = true;                     // R restart
}

const constants = {
    MOUSE_BUTTON_LEFT: 0,
    KEY_SPACE: 32, KEY_ESCAPE: 256,
    KEY_RIGHT: 262, KEY_LEFT: 263, KEY_DOWN: 264, KEY_UP: 265,
    KEY_LEFT_SHIFT: 340, KEY_RIGHT_SHIFT: 344,
    KEY_LEFT_CONTROL: 341, KEY_RIGHT_CONTROL: 345,
    KEY_A: 65, KEY_D: 68, KEY_R: 82, KEY_S: 83, KEY_W: 87, KEY_P: 80, KEY_Z: 90, KEY_T: 84,
    WHITE: {}, RAYWHITE: {},
};

const rl = Object.assign({}, constants, {
    color: () => ({}),
    initWindow: () => {}, setTargetFPS: () => {}, closeWindow: () => {},
    loadModel: () => 0,
    isModelValid: () => true,
    unloadModel: () => {},
    modelBounds: () => ({ minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 1.47, maxZ: 0 }),
    modelBoneCount: () => 13,
    modelAnimationCount: () => CLIPS.length,
    modelAnimationName: (_m, i) => CLIPS[i].name,
    modelAnimationFrameCount: (_m, i) => clipFrames[i],
    modelAnimationDuration: (_m, i) => CLIPS[i].dur,
    updateModelAnimation: (_m, i, frame) => {
        lastPosed = { clip: CLIPS[i].name, frame: frame };
    },
    drawModelEx: () => {},
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
        });
        frameIndex += 1;
    },
    beginMode3D: () => {}, endMode3D: () => {},
    drawCube: () => {}, drawGrid: () => {},
    drawSphere: () => {}, drawPoint3D: () => {}, drawRectangleGradientV: () => {},
    drawRectangle: () => {}, drawText: (text) => {
        const s = String(text);
        if (s.indexOf('speed ') >= 0) speedText = s;
        else if (s.indexOf('health ') >= 0) statsText = s;
    },
});

const sandbox = {
    rl,
    console: { log: (...a) => logs.push(a.join(' ')), warn: () => {}, error: () => {} },
};
vm.createContext(sandbox);

const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'goat.js'), 'utf8');
let thrown = null;
try {
    vm.runInContext(source, sandbox, { filename: 'goat.js' });
} catch (e) {
    thrown = e && e.stack ? e.stack : String(e);
}

const row = (i) => timeline.find((r) => r.i === i) || { clip: null, speed: '', stats: '' };
const clipAt = (i) => row(i).clip;
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

let deathFrame = -1;
for (const r of timeline) {
    if (r.clip === 'GoatDeath') { deathFrame = r.i; break; }
}
const e20 = statAt(20);
const e60 = statAt(60);
const deadStats = deathFrame >= 0 ? statAt(deathFrame) : null;

const checks = [
    ['no throw', thrown === null, thrown],
    ['idle at frame 3', clipAt(3) === 'GoatIdle', clipAt(3)],
    ['walk at frame 15', clipAt(15) === 'GoatWalk', clipAt(15)],
    ['trot at frame 40', clipAt(40) === 'GoatTrot', clipAt(40)],
    ['run at frame 60', clipAt(60) === 'GoatRun', clipAt(60)],
    ['jump starts at frame 70', clipAt(70) === 'GoatJump', clipAt(70)],
    ['landed to idle by frame 145', clipAt(145) === 'GoatIdle', clipAt(145)],
    ['sleeping at frame 160', clipAt(160) === 'GoatSleep', clipAt(160)],
    ['woke to walk at frame 190', clipAt(190) === 'GoatWalk', clipAt(190)],
    ['walk speed ~0.87 m/s', Math.abs((speedAt(15) || 0) - 0.873) < 0.01, speedAt(15)],
    ['trot speed ~1.58 m/s', Math.abs((speedAt(40) || 0) - 1.577) < 0.02, speedAt(40)],
    ['run speed ~2.94 m/s', Math.abs((speedAt(60) || 0) - 2.941) < 0.02, speedAt(60)],
    ['energy drains while running', e20 && e60 && e60.energy < e20.energy, [e20, e60]],
    ['clock advances over time', clockAt(20) !== null && clockAt(1200) > clockAt(20),
        [clockAt(20), clockAt(1200)]],
    ['goat dies of exhaustion', deathFrame > 200 && deathFrame < 3950, deathFrame],
    ['death clip held while dead', clipAt(deathFrame + 5) === 'GoatDeath', clipAt(deathFrame + 5)],
    ['health is zero at death', deadStats !== null && deadStats.health === 0, deadStats],
    ['R restarts into run', clipAt(4000) === 'GoatRun', clipAt(4000)],
];

const failed = checks.filter((c) => !c[1]);
console.log('--- goat.js logic test ---');
console.log('model line:', logs.filter((l) => l.indexOf('model handle') >= 0).join(' | '));
console.log('death frame:', deathFrame, 'stats:', JSON.stringify(deadStats));
for (const [name, ok, got] of checks) {
    console.log((ok ? 'PASS' : 'FAIL') + '  ' + name + (ok ? '' : '  (got ' + JSON.stringify(got) + ')'));
}
console.log('---');
console.log(failed.length === 0 ? 'ALL PASS (' + checks.length + ')' : failed.length + ' FAILED');
process.exit(failed.length === 0 ? 0 : 1);

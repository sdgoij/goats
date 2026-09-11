// Headless harness for src/goat.js: stubs the `rl` surface, drives a scripted
// input timeline, and checks the clip each frame and the reported speed.
//
//   node tools/goat_logic_test.js
//
// It does not touch raylib; it only exercises the JavaScript state machine.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const TOTAL = 200;

// Clip table the stub model reports (raylib resamples to 60 fps).
const CLIPS = [
    { name: 'GoatIdle', dur: 2.5 },
    { name: 'GoatWalk', dur: 1.0 },
    { name: 'GoatRun', dur: 0.58333 },
    { name: 'GoatJump', dur: 1.16667 },
    { name: 'GoatTrot', dur: 0.66667 },
];
const clipFrames = CLIPS.map((c) => Math.round(c.dur * 60) + 1);

let frameIndex = 0;
let lastPosed = null;
let speedText = '';
const timeline = [];
const posed = [];
const logs = [];

const keys = {};
const pressed = {};

function applyInput(i) {
    for (const k of Object.keys(keys)) delete keys[k];
    for (const k of Object.keys(pressed)) delete pressed[k];
    if ((i >= 10 && i < 50) || (i >= 130 && i < 141)) keys[87] = true;  // W
    if (i >= 30 && i < 50) keys[340] = true;                           // LEFT_SHIFT
    if (i === 50) pressed[32] = true;                                  // SPACE
}

const constants = {
    MOUSE_BUTTON_LEFT: 0,
    KEY_SPACE: 32, KEY_ESCAPE: 256,
    KEY_RIGHT: 262, KEY_LEFT: 263, KEY_DOWN: 264, KEY_UP: 265,
    KEY_LEFT_SHIFT: 340, KEY_RIGHT_SHIFT: 344,
    KEY_A: 65, KEY_D: 68, KEY_S: 83, KEY_W: 87, KEY_P: 80,
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
        posed.push(lastPosed);
    },
    drawModelEx: () => {},
    windowShouldClose: () => {
        if (frameIndex >= TOTAL) return true;
        applyInput(frameIndex);
        return false;
    },
    getFrameTime: () => 1 / 60,
    getFPS: () => 60, getScreenHeight: () => 640,
    isMouseButtonDown: () => false, getMouseDeltaX: () => 0, getMouseDeltaY: () => 0,
    getMouseWheelMove: () => 0,
    isKeyDown: (k) => !!keys[k],
    isKeyPressed: (k) => !!pressed[k],
    isKeyReleased: () => false, isKeyUp: (k) => !keys[k],
    beginDrawing: () => {}, clearBackground: () => {}, endDrawing: () => {
        timeline.push({ i: frameIndex, clip: lastPosed ? lastPosed.clip : null, speed: speedText });
        frameIndex += 1;
    },
    beginMode3D: () => {}, endMode3D: () => {},
    drawCube: () => {}, drawGrid: () => {},
    drawText: (text) => { if (String(text).indexOf('speed ') === 0) speedText = text; },
});

const sandbox = {
    rl,
    console: {
        log: (...a) => logs.push(a.join(' ')),
        warn: () => {}, error: (...a) => logs.push('ERROR ' + a.join(' ')),
    },
};
vm.createContext(sandbox);

const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'goat.js'), 'utf8');
let thrown = null;
try {
    vm.runInContext(source, sandbox, { filename: 'goat.js' });
} catch (e) {
    thrown = e && e.stack ? e.stack : String(e);
}

function speedAt(i) {
    const row = timeline.find((r) => r.i === i);
    if (!row) return null;
    const m = /speed ([\d.]+) m\/s/.exec(row.speed);
    return m ? Number(m[1]) : null;
}
function clipAt(i) {
    const row = timeline.find((r) => r.i === i);
    return row ? row.clip : null;
}

const checks = [
    ['no throw', thrown === null, thrown],
    ['idle at frame 3', clipAt(3) === 'GoatIdle', clipAt(3)],
    ['walk at frame 15', clipAt(15) === 'GoatWalk', clipAt(15)],
    ['run at frame 40', clipAt(40) === 'GoatRun', clipAt(40)],
    ['jump starts at frame 50', clipAt(50) === 'GoatJump', clipAt(50)],
    ['jump still airborne at frame 115', clipAt(115) === 'GoatJump', clipAt(115)],
    ['landed to idle by frame 125', clipAt(125) === 'GoatIdle', clipAt(125)],
    ['walk again at frame 135', clipAt(135) === 'GoatWalk', clipAt(135)],
    ['walk speed ~0.64 m/s', Math.abs((speedAt(15) || 0) - 0.64) < 0.01, speedAt(15)],
    ['run speed ~2.22 m/s', Math.abs((speedAt(40) || 0) - 2.219) < 0.02, speedAt(40)],
];

const failed = checks.filter((c) => !c[1]);
console.log('--- goat.js logic test ---');
console.log('model line:', logs.filter((l) => l.indexOf('model handle') >= 0).join(' | '));
console.log('run/jump model log:', logs.filter((l) => l.indexOf('run ') >= 0 && l.indexOf('m/s') >= 0).join(' | '));
for (const [name, ok, got] of checks) {
    console.log((ok ? 'PASS' : 'FAIL') + '  ' + name + (ok ? '' : '  (got ' + JSON.stringify(got) + ')'));
}
console.log('---');
console.log(failed.length === 0 ? 'ALL PASS (' + checks.length + ')' : failed.length + ' FAILED');
process.exit(failed.length === 0 ? 0 : 1);

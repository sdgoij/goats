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
    { name: 'GoatIdle', dur: 6.0 },
    { name: 'GoatWalk', dur: 0.91667 },
    { name: 'GoatRun', dur: 0.5 },
    { name: 'GoatJump', dur: 1.16667 },
    { name: 'GoatTrot', dur: 0.58333 },
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
    let w = false;
    if (i >= 10 && i < 30) w = true;                        // walk
    if (i >= 30 && i < 50) { w = true; keys[341] = true; }  // trot  (CTRL)
    if (i >= 50 && i < 70) { w = true; keys[340] = true; }  // run   (SHIFT)
    if (i >= 150 && i < 161) w = true;                      // walk again
    if (w) keys[87] = true;
    if (i === 70) pressed[32] = true;                       // jump  (SPACE)
}

const constants = {
    MOUSE_BUTTON_LEFT: 0,
    KEY_SPACE: 32, KEY_ESCAPE: 256,
    KEY_RIGHT: 262, KEY_LEFT: 263, KEY_DOWN: 264, KEY_UP: 265,
    KEY_LEFT_SHIFT: 340, KEY_RIGHT_SHIFT: 344,
    KEY_LEFT_CONTROL: 341, KEY_RIGHT_CONTROL: 345,
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
    ['trot at frame 40', clipAt(40) === 'GoatTrot', clipAt(40)],
    ['run at frame 60', clipAt(60) === 'GoatRun', clipAt(60)],
    ['jump starts at frame 70', clipAt(70) === 'GoatJump', clipAt(70)],
    ['jump still airborne at frame 110', clipAt(110) === 'GoatJump', clipAt(110)],
    ['landed to idle by frame 145', clipAt(145) === 'GoatIdle', clipAt(145)],
    ['walk again at frame 155', clipAt(155) === 'GoatWalk', clipAt(155)],
    ['walk speed ~0.87 m/s', Math.abs((speedAt(15) || 0) - 0.873) < 0.01, speedAt(15)],
    ['trot speed ~1.58 m/s', Math.abs((speedAt(40) || 0) - 1.577) < 0.02, speedAt(40)],
    ['run speed ~2.94 m/s', Math.abs((speedAt(60) || 0) - 2.941) < 0.02, speedAt(60)],
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

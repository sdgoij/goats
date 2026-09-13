// Logic test for the `birds` mod (mods/birds), run without raylib.
//
//   node tools/birds_mod_test.js
//
// It stubs the engine's `rl` surface with recording functions, evaluates the
// real scene, loads the mod the way the host does, and then drives the mod's
// `update` and `draw3d` hooks directly, so the whole simulation runs with no
// window. It asserts:
//
//   * the procedural meshes and generated texture are built, lazily
//   * the flock exists and every animation state is reached over time
//   * boid separation keeps flying birds apart
//   * the flock publishes a compact state that fits the world datagram budget
//   * a client mirrors the host's snapshot instead of simulating
//   * two fresh worlds with the same seed produce the same flock
//
// The vanilla `tools/goat_logic_test.js` stays free of this mod; `tools/
// mod_smoke_test.js` covers the generic host seam with the `example` fixture.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
// The running order lives in `crates/scene`, one list for the client, the server
// and the Rust harness; parse that same list so this harness tests the same scene.
const sceneDir = path.join(root, 'crates', 'scene', 'src');
const sceneLib = fs.readFileSync(path.join(sceneDir, 'lib.rs'), 'utf8');
const parts = [...sceneLib.matchAll(/"(\.\.\/\.\.\/goats\/src\/game\/[^"]+)"/g)].map((m) => m[1]);
if (parts.length === 0) throw new Error('no scene parts found in crates/scene/src/lib.rs');
const SCENE = parts.map((rel) => fs.readFileSync(path.join(sceneDir, rel), 'utf8')).join('');
const BIRDS_SRC = fs.readFileSync(path.join(root, 'mods', 'birds', 'mod.js'), 'utf8');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(root, 'mods', 'birds', 'mod.json'), 'utf8'));
const MOD_ID = MANIFEST.id;

const DT = 1 / 60;

// ---- a world --------------------------------------------------------------
//
// Each call builds an isolated sandbox with its own stub and counters, so two
// worlds can be compared for determinism.
function makeWorld() {
    const counters = {
        makeModel: 0, makeTexture: 0, setModelTexture: 0,
        drawModelEx: 0, drawCube: 0, unloadModel: 0,
    };
    let handle = 1;
    const noop = function () {};
    // Mimic the real binding: colours are packed numbers and every argument of a
    // draw call must be a number. The server's null `rl` is looser, which is how
    // an object colour once slipped through and aborted `draw3d` on the client.
    const nums = function (name, args) {
        for (let i = 0; i < args.length; i++) {
            if (typeof args[i] !== 'number' || !Number.isFinite(args[i])) {
                throw new TypeError('rl.' + name + ': argument ' + i + ' must be a number');
            }
        }
    };
    const rl = new Proxy({}, {
        get(target, prop) {
            switch (prop) {
                case 'makeModel': return function () { counters.makeModel += 1; return handle++; };
                case 'makeTexture': return function () { counters.makeTexture += 1; return 900 + counters.makeTexture; };
                case 'loadModel': return function () { return handle++; };
                case 'unloadModel': return function () { counters.unloadModel += 1; };
                case 'setModelTexture': return function () { counters.setModelTexture += 1; };
                case 'setModelShader': return noop;
                case 'drawModelEx': return function (...args) { nums('drawModelEx', args); counters.drawModelEx += 1; };
                case 'drawCube': return function (...args) { nums('drawCube', args); counters.drawCube += 1; };
                case 'color': return function (r, g, b, a) {
                    return (((r & 255) << 24) | ((g & 255) << 16) | ((b & 255) << 8) | ((a === undefined ? 255 : a) & 255)) >>> 0;
                };
                case 'isModelValid': return function () { return true; };
                case 'getScreenWidth': return function () { return 1280; };
                case 'getScreenHeight': return function () { return 720; };
                case 'getCharPressed': return function () { return 0; };
                case 'isKeyDown':
                case 'isKeyPressed': return function () { return false; };
                case 'isKeyUp': return function () { return true; };
                case 'windowShouldClose': return function () { return false; };
                case 'getFPS': return function () { return 60; };
                case 'getFrameTime': return function () { return DT; };
                default: {
                    const name = String(prop);
                    if (/^[A-Z][A-Z0-9_]+$/.test(name)) return 0;
                    return noop;
                }
            }
        },
    });

    const logs = [];
    const sandbox = {
        rl,
        console: { log: (...a) => logs.push(a.join(' ')), warn: () => {}, error: () => {} },
    };
    vm.createContext(sandbox);
    vm.runInContext(SCENE, sandbox, { filename: 'game.js' });

    sandbox.sceneMods(JSON.stringify([{
        id: MANIFEST.id, name: MANIFEST.name, version: MANIFEST.version,
        api: MANIFEST.api, side: MANIFEST.side, enabled: true, hash: '0',
        assets: {}, tuning: null,
    }]));
    vm.runInContext(
        '(function (goats) {\n"use strict";\n' + BIRDS_SRC +
        '\n})(goats.begin(' + JSON.stringify(MOD_ID) + '));',
        sandbox);
    sandbox.sceneModResult(MOD_ID, true, '');
    sandbox.sceneModFreeze();

    return {
        sandbox, counters, logs,
        step(n) { for (let i = 0; i < n; i++) sandbox.modEmit('update', DT); },
        draw() { sandbox.modEmit('draw3d', { x: 0, y: 6, z: 0, targetX: 0, targetY: 1, targetZ: 0, fov: 55 }); },
        status() { return JSON.parse(sandbox.sceneCommand('birds').slice(3)); },
        published() { return sandbox.sceneWorldMods().data[MOD_ID]; },
    };
}

const checks = [];
function check(name, ok, detail) { checks.push({ name, ok: ok === true, detail }); }

// ---- build ----------------------------------------------------------------
const world = makeWorld();
world.step(1);
check('meshes and a generated texture are built',
    world.counters.makeModel === 3 && world.counters.makeTexture === 1 &&
    world.counters.setModelTexture >= 3, world.counters);

world.draw();
const afterDraw = world.status();
check('the draw handler does not throw',
    !world.logs.some((line) => line.indexOf('handler threw') >= 0),
    world.logs.filter((line) => line.indexOf('handler threw') >= 0));
check('the flock spawns and draws body plus two wings each',
    afterDraw.count === 6 && world.counters.drawModelEx >= 18, { ...world.counters, count: afterDraw.count });
check('a `birds` command reports the flock', afterDraw.local === true, afterDraw);

// ---- animation states -----------------------------------------------------
// Run a minute of simulation and record which states are reached, and the
// closest two flying birds ever get.
const seen = new Set();
let minGap = Infinity;
const SAMPLES = 3600;
for (let i = 0; i < SAMPLES; i += 30) {
    world.step(30);
    const s = world.status();
    for (const name of Object.keys(s.states)) seen.add(name);
    const birds = world.published();
    for (let a = 0; a < birds.length; a++) {
        if (birds[a][4] !== 3) continue;
        for (let b = a + 1; b < birds.length; b++) {
            if (birds[b][4] !== 3) continue;
            const dx = birds[a][0] - birds[b][0];
            const dz = birds[a][2] - birds[b][2];
            minGap = Math.min(minGap, Math.hypot(dx, dz));
        }
    }
}
for (const name of ['idle', 'walk', 'takeoff', 'fly', 'land']) {
    check('reaches the ' + name + ' state', seen.has(name), [...seen]);
}
check('boid separation keeps flying birds apart', minGap > 0.3, minGap);

// ---- the world snapshot ---------------------------------------------------
const payload = JSON.stringify(world.published());
check('the published flock is one compact record per bird',
    Array.isArray(world.published()) && world.published().length === 6 &&
    world.published().every((r) => Array.isArray(r) && r.length === 5), world.published().length);
check('the flock payload stays within the world datagram budget',
    payload.length < 250, payload.length);

// ---- a client mirrors the host --------------------------------------------
const client = makeWorld();
client.sandbox.sceneNetEvent('{"type":"welcome","name":"eve"}');
client.sandbox.sceneApplyWorldMods({
    data: { [MOD_ID]: [[20, 9, -20, 0.5, 3], [26, 9, -26, 0.5, 3]] },
});
client.step(120);
const mirrored = client.published();
check('a client adopts the host flock size', mirrored.length === 2, mirrored.length);
check('a client eases toward the host snapshot',
    Math.abs(mirrored[0][0] - 20) < 1.5 && Math.abs(mirrored[0][2] + 20) < 1.5 &&
    Math.abs(mirrored[1][0] - 26) < 1.5, mirrored);
check('a client keeps the host animation state',
    mirrored[0][4] === 3 && mirrored[1][4] === 3, mirrored.map((r) => r[4]));
check('a client does not simulate', Math.abs(mirrored[0][1] - 9) < 0.6, mirrored[0]);

// ---- perching -------------------------------------------------------------
// Birds may land on the player's goat; over two minutes at least one should.
const perchWorld = makeWorld();
let perched = false;
for (let i = 0; i < 240; i++) {
    perchWorld.step(30);
    if (perchWorld.status().states.perch > 0) { perched = true; break; }
}
check('a bird perches on a goat', perched, perchWorld.status().states);

// ---- a moving player ------------------------------------------------------
// A landing must terminate even when the flock's home is moving: chasing a
// running goat forever once left birds hanging in the air, never settling.
const moveWorld = makeWorld();
let groundSamples = 0, landSamples = 0;
for (let i = 0; i < 120; i++) {
    for (let k = 0; k < 30; k++) {
        const t = (i * 30 + k) * DT;
        vm.runInContext(
            'goats.player.teleport(' + (Math.cos(t * 0.1) * 25).toFixed(2) + ',' +
            (Math.sin(t * 0.1) * 25).toFixed(2) + ')', moveWorld.sandbox);
        moveWorld.sandbox.modEmit('update', DT);
    }
    const s = moveWorld.status().states;
    groundSamples += (s.idle || 0) + (s.walk || 0) + (s.perch || 0);
    landSamples += s.land || 0;
}
check('birds settle while the player moves',
    groundSamples > 20 && groundSamples > landSamples, { groundSamples, landSamples });

// ---- a herd ---------------------------------------------------------------
// With a herd present the flock still follows the moving player, not the herd:
// trailing the herd left the birds behind, where they looked like they had
// vanished.
const herdWorld = makeWorld();
vm.runInContext('for (let i = 0; i < 6; i++) botAdd(i);', herdWorld.sandbox);
let herdFar = 0;
for (let i = 0; i < 180; i++) {
    const t = i * 0.5;
    vm.runInContext('goats.player.teleport(' + (Math.cos(t * 0.1) * 20).toFixed(2) + ',' +
        (Math.sin(t * 0.1) * 20).toFixed(2) + ')', herdWorld.sandbox);
    herdWorld.step(30);
    if (herdWorld.status().far > herdFar) herdFar = herdWorld.status().far;
}
check('the flock follows the player past a herd',
    herdWorld.status().anchor === 'player' && herdFar < 45,
    { anchor: herdWorld.status().anchor, herdFar });

// ---- determinism ----------------------------------------------------------
const a = makeWorld();
const b = makeWorld();
a.step(900);
b.step(900);
check('the same seed runs the same flock',
    JSON.stringify(a.published()) === JSON.stringify(b.published()),
    { a: a.published()[0], b: b.published()[0] });

// ---- command --------------------------------------------------------------
const before = world.published()[0].slice(0, 3);
check('`birds scatter` is accepted', world.sandbox.sceneCommand('birds scatter') === 'ok birds scattered');
world.step(1);
const after = world.published()[0].slice(0, 3);
check('`birds scatter` moves a bird', before[0] !== after[0] || before[2] !== after[2], { before, after });

// `gather` is the quick visual check: drop the flock in a ring beside the goat.
const cmdWorld = makeWorld();
cmdWorld.step(600);
vm.runInContext('goats.player.teleport(40, -20)', cmdWorld.sandbox);
check('`birds gather` brings the flock to the player',
    cmdWorld.sandbox.sceneCommand('birds gather') === 'ok birds gathered' &&
    cmdWorld.status().far < 5, cmdWorld.status());
check('`birds fly` lifts the whole flock', (function () {
    if (cmdWorld.sandbox.sceneCommand('birds fly') !== 'ok birds flying') return false;
    cmdWorld.step(1);
    const s = cmdWorld.status().states;
    return (s.takeoff || 0) + (s.fly || 0) === cmdWorld.status().count;
})(), cmdWorld.status());
check('`birds land` puts the whole flock down', (function () {
    if (cmdWorld.sandbox.sceneCommand('birds land') !== 'ok birds landing') return false;
    const s = cmdWorld.status().states;
    return (s.land || 0) === cmdWorld.status().count;
})(), cmdWorld.status());

// ---- shutdown -------------------------------------------------------------
world.sandbox.sceneModEnd(MOD_ID);
check('unloading frees the models', world.counters.unloadModel === 3, world.counters.unloadModel);

// ---- report ---------------------------------------------------------------
let failed = 0;
for (const c of checks) {
    if (!c.ok) failed += 1;
    console.log((c.ok ? 'PASS  ' : 'FAIL  ') + c.name +
        (c.ok || c.detail === undefined ? '' : '  ' + JSON.stringify(c.detail)));
}
if (failed > 0) {
    console.log('FAILED (' + failed + '/' + checks.length + ')');
    process.exit(1);
}
console.log('ALL PASS (' + checks.length + ')');

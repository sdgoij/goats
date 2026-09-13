// Smoke test for the mod surface, end to end on the JavaScript side.
//
//   node tools/mod_smoke_test.js [mods-dir]
//
// It stubs the engine's `rl` surface, evaluates the real scene, then loads the
// checked-in fixture the way the host does: push the metadata table with
// `sceneMods`, evaluate each entry inside its `goats.begin(id)` wrapper, report
// the result, and freeze. It then drives the seams the frame loop and the
// console use, and asserts:
//
//   * the fixture's command dispatches through `sceneCommand`
//   * its declared asset re-points the slot
//   * its `tuning.json` merges (and a typo warns rather than fails)
//   * its `"hud"` handler runs from `modEmit("hud", ...)`
//   * a throwing handler is isolated, not fatal
//   * a reload leaves no duplicate handlers or commands
//
// The main `tools/goat_logic_test.js` keeps its vanilla assertions and only ever
// uses synthetic mod tables, so it never loads this directory. This file is the
// opposite: it proves the host seam works against a real mod directory.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const modsDir = process.argv[2] === undefined
    ? path.join(root, 'mods', 'example')
    : path.resolve(process.argv[2]);

// ---- engine stub ----------------------------------------------------------
//
// A Proxy so any `rl.*` the scene defines a call to resolves to a no-op; only
// the handful this test observes are real. That keeps the stub small without
// making `eval` of the scene fail on a member nobody calls.
const drawTexts = [];
const noop = function () {};
const rl = new Proxy({}, {
    get(target, prop) {
        switch (prop) {
            case 'drawText':
                return function (text) { drawTexts.push(String(text)); };
            case 'color':
                return function (r, g, b, a) { return { r: r, g: g, b: b, a: a }; };
            case 'getScreenWidth': return function () { return 1280; };
            case 'getScreenHeight': return function () { return 720; };
            case 'getCharPressed': return function () { return 0; };
            case 'isKeyDown':
            case 'isKeyPressed': return function () { return false; };
            case 'windowShouldClose': return function () { return false; };
            case 'getFPS': return function () { return 60; };
            default: {
                const name = String(prop);
                // Engine constants (`rl.KEY_A`, `rl.WHITE`) read as numbers.
                if (/^[A-Z][A-Z0-9_]+$/.test(name)) return 0;
                return noop;
            }
        }
    },
});

const logs = [];
const sandbox = {
    rl,
    console: {
        log: function () { logs.push(Array.prototype.join.call(arguments, ' ')); },
        warn: function () { logs.push(Array.prototype.join.call(arguments, ' ')); },
        error: function () { logs.push(Array.prototype.join.call(arguments, ' ')); },
    },
};
vm.createContext(sandbox);

// ---- load the scene -------------------------------------------------------
//
// crates/scene/src/lib.rs is the running order's single source of truth; parse
// that same list so this harness tests the same scene.
const sceneDir = path.join(root, 'crates', 'scene', 'src');
const sceneLib = fs.readFileSync(path.join(sceneDir, 'lib.rs'), 'utf8');
const parts = [...sceneLib.matchAll(/"(\.\.\/\.\.\/goats\/src\/game\/[^"]+)"/g)].map((m) => m[1]);
if (parts.length === 0) throw new Error('no scene parts found in crates/scene/src/lib.rs');
const source = parts.map((rel) => fs.readFileSync(path.join(sceneDir, rel), 'utf8')).join('');
vm.runInContext(source, sandbox, { filename: 'game.js' });

// ---- read the fixture -----------------------------------------------------
//
// The host reads and validates these in Rust (crates/mods); this test reads the
// same files to build the table the scene is handed, and checks the fixture is
// shaped the way the loader requires.
const manifestPath = path.join(modsDir, 'mod.json');
if (!fs.existsSync(manifestPath)) throw new Error('no mod.json in ' + modsDir);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const entry = manifest.entry === undefined
    ? null
    : fs.readFileSync(path.join(modsDir, manifest.entry), 'utf8');
const tuning = manifest.tuning === undefined
    ? null
    : JSON.parse(fs.readFileSync(path.join(modsDir, manifest.tuning), 'utf8'));

const assets = {};
const assetFiles = [];
for (const slot of Object.keys(manifest.assets || {})) {
    const value = manifest.assets[slot];
    const file = Array.isArray(value) ? value[0] : value;
    // One file fills the slot on its own; the host names it `mod:<id>:<slot>`.
    assets[slot] = 'mod:' + manifest.id + ':' + slot;
    assetFiles.push(path.join(modsDir, file));
}

const checks = [];
function check(name, ok, detail) { checks.push({ name, ok: ok === true, detail }); }

check('the fixture manifest is well-formed',
    manifest.api === 1 && (manifest.side === undefined || manifest.side === 'client') &&
    typeof manifest.id === 'string' && manifest.id.length > 0,
    { id: manifest.id, api: manifest.api, side: manifest.side });
check('every declared asset exists and is a real file',
    assetFiles.length > 0 && assetFiles.every((f) => fs.existsSync(f) &&
        fs.readFileSync(f).subarray(0, 4).toString('latin1') === 'RIFF'),
    assetFiles.map((f) => path.relative(root, f)));

// ---- load it the way the host does ----------------------------------------
const table = [{
    id: manifest.id,
    name: manifest.name,
    version: manifest.version,
    api: manifest.api,
    side: manifest.side === undefined ? 'client' : manifest.side,
    description: manifest.description === undefined ? '' : manifest.description,
    enabled: true,
    hash: '0000000000000000',
    assets: assets,
    tuning: tuning,
}];

function wrap(fixtureSource) {
    return '(function (goats) {\n"use strict";\n' + fixtureSource +
        '\n})(goats.begin(' + JSON.stringify(manifest.id) + '));';
}

function load(fixtureSource) {
    vm.runInContext('sceneModEnd(' + JSON.stringify(manifest.id) + ')', sandbox);
    vm.runInContext(wrap(fixtureSource), sandbox);
    sandbox.sceneModResult(manifest.id, true, '');
}

const modsResult = sandbox.sceneMods(JSON.stringify(table));
load(entry);
sandbox.sceneModFreeze();

check('the table installs', modsResult === 'ok', modsResult);
check('the fixture is listed and enabled',
    vm.runInContext('goats.mods().some(function (m) { return m.id === ' +
        JSON.stringify(manifest.id) + ' && m.enabled; })', sandbox) === true);
check('the declared asset re-points its slot',
    vm.runInContext('goats.assets.get("sfx.bleat")', sandbox) ===
        'mod:' + manifest.id + ':sfx.bleat');

// A tuning tweak landed and the deliberate typo warned rather than aborting.
check('tuning.json merges a known leaf',
    vm.runInContext('goats.tuning.get("camera.dist")', sandbox) === 6.5,
    vm.runInContext('goats.tuning.get("camera.dist")', sandbox));
check('an unknown tuning path warns, not fails',
    logs.some((line) => line.indexOf('typo.notAThing') >= 0 && line.indexOf('unknown path') >= 0),
    logs.filter((line) => line.indexOf('typo') >= 0));

// ---- commands -------------------------------------------------------------
check('a mod command dispatches',
    sandbox.sceneCommand('hello') === 'ok hello world' &&
    sandbox.sceneCommand('hello goat') === 'ok hello goat',
    [sandbox.sceneCommand('hello'), sandbox.sceneCommand('hello goat')]);
check('a built-in still wins',
    sandbox.sceneCommand('ping') === 'ok pong');

// ---- the hud hook ---------------------------------------------------------
function emitHud() {
    vm.runInContext('modEmit("hud", { width: 1280, height: 720 })', sandbox);
}
drawTexts.length = 0;
emitHud();
check('the hud hook runs from the frame loop',
    drawTexts.length === 1 && drawTexts[0].indexOf('example mod') >= 0, drawTexts);

// ---- a throwing handler is isolated ---------------------------------------
//
// Re-enter the fixture with one extra handler that throws, the way a mod with a
// bug behaves. The frame must survive and the fixture's own hook must still run.
load(entry + '\ngoats.on("hud", function () { throw new Error("boom"); });\n');
const logCount = logs.length;
drawTexts.length = 0;
let threw = null;
try {
    emitHud();
} catch (error) {
    threw = String(error);
}
check('a throwing handler does not abort the frame',
    threw === null && drawTexts.length === 1, threw);
check('the throwing handler is reported',
    logs.slice(logCount).some((line) => line.indexOf('handler threw') >= 0 &&
        line.indexOf('boom') >= 0),
    logs.slice(logCount));

// ---- reload leaves no duplicates ------------------------------------------
load(entry);
drawTexts.length = 0;
emitHud();
check('reload leaves exactly one hud handler', drawTexts.length === 1, drawTexts);
check('reload leaves the command registered once',
    sandbox.sceneCommand('hello goat') === 'ok hello goat');

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

// The harness's `rl`: the null module plus what a test drives and reads back.
//
// This is evaluated after `null_rl.js`, so `rl` is already the whole surface; it
// overlays only the members the harness needs and leaves the rest alone. The
// scene cannot tell the difference, which is the point: the same script runs here
// as in the game, so a binding or a builtin the engine lacks fails a test instead
// of passing one.
//
// Two jobs, in one place:
//
//   * **Drive.** The scripted input timeline and the loop control. The scene's own
//     `run()` calls `windowShouldClose` and `endDrawing`, so the harness drives
//     the real frame loop rather than a re-implementation of it. Loading frames
//     are not counted -- the scene takes one startup step per frame and draws the
//     splash -- so a recorded `i` counts frames *after* the scene is ready, the
//     way the Node harness counted them before M15.
//   * **Observe.** Everything the assertions need, recorded as it happens: the
//     per-frame timeline, the console probes, model/shader/audio call tables, the
//     terrain mesh, the drawn positions and the scene's own `console.log` lines.
//
// Booleans the checks used to compute are *not* computed here: this records
// measurements, and the assertions stay in Rust. The one thing it does derive is
// facts that would otherwise mean shipping a whole terrain mesh across the
// boundary (triangle counts, the height spread, the material count).
//
// The budget is settable (`harnessSetTotal`), so a test can drive a short run;
// the frame indices are absolute either way, so a short run sees the same inputs
// at the same frames and simply stops earlier.

(function () {
    const DEFAULT_TOTAL = 4050;
    let total = DEFAULT_TOTAL;

    // ---- input -------------------------------------------------------------
    // Exactly as raylib queues it: key state for the frame, one-shot presses and
    // the typed-character queue.
    const keys = {};
    const pressed = {};
    const chars = [];
    let clipboard = '';
    const clipboardWrites = [];

    // ---- the recorded run ---------------------------------------------------
    const timeline = [];
    // The frames whose console/screen state is snapshotted. The console is an
    // overlay and the scripted input drives it only after the restart, so these
    // are the frames the console cases look at.
    const PROBE_FRAMES = [4007, 4008, 4009, 4011, 4013, 4016, 4018, 4021, 4032, 4034];
    const probes = {};

    let frameIndex = 0;
    let lastPosed = null;
    let speedText = '';
    let statsText = '';
    let weatherText = '';
    let splashTitle = false;
    let splashStep = '';
    let shadowPass = false;
    let skyFs = '';
    let goatDraw = null;
    const drawnRows = {};
    let lastTerrainMesh = null;

    // The counters a test can read and reset. `cubeDraws` is reset by the tuft
    // check, which draws the field twice and compares.
    const counters = {
        loadingFrames: 0, modelLoads: 0, botPoses: 0, botJumps: 0,
        cubeDraws: 0, shadowCubeDraws: 0, menuDraws: 0, progressBarCalls: 0,
        musicUpdates: 0, terrainMeshesBuilt: 0,
        texturesMade: 0, textureBinds: 0, modelsDrawn: 0, modelsUnloaded: 0,
    };
    const modelPaths = [];
    const botClipNames = {};
    const modelShaderCalls = [];
    const modelTextureCalls = [];
    const musicLoads = [];
    const musicPlayed = [];
    const soundLoads = [];
    const soundsPlayed = [];

    // The scene's own `console.log` lines. The checks read some of their numbers
    // out of them (the herd size, the closest gap the bots kept, the fullest
    // belly), so they are captured here as well as forwarded to the host.
    const logs = [];

    // The scripted input timeline, ported from the Node harness. Frames 10-200
    // exercise the gaits, the jump and sleep; 3000-3950 force the weather, the
    // lighting and the death/restart; 4010+ drive the console and the clipboard,
    // after the restart, so no earlier assertion can be disturbed.
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
        if (i === 4010) pressed[96] = true;                     // ` opens the console
        if (i === 4012) chars.push(112, 105, 110, 103);         // "ping"
        if (i === 4014) pressed[257] = true;                    // ENTER submits
        if (i === 4016) pressed[265] = true;                    // UP recalls history
        if (i === 4018) pressed[256] = true;                    // ESC closes, not the menu
        if (i === 4020) pressed[96] = true;                     // ` reopens
        if (i === 4022) pressed[256] = true;                    // ESC closes again
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

    // Colours are packed numbers on the real binding, and a draw call has to get
    // one: an object colour reaching `drawCube` is what aborted the birds on the
    // client, and a stub looser than the engine would have missed it. The check is
    // one `typeof` per call -- an `arguments` walk costs a JIT deopt and triples
    // the run.
    const pack = (r, g, b, a) =>
        (((r & 255) << 24) | ((g & 255) << 16) | ((b & 255) << 8) | ((a === undefined ? 255 : a) & 255)) >>> 0;

    const base = globalThis.rl;
    globalThis.rl = Object.assign({}, base, {
        color: pack,
        WHITE: pack(255, 255, 255),
        RAYWHITE: pack(245, 245, 245),
        // ---- input: the script, not the keyboard ---------------------------
        isKeyDown: (k) => !!keys[k],
        isKeyPressed: (k) => !!pressed[k],
        isKeyUp: (k) => !keys[k],
        getCharPressed: () => (chars.length > 0 ? chars.shift() : 0),
        getClipboardText: () => clipboard,
        setClipboardText: (text) => {
            clipboard = String(text);
            clipboardWrites.push(clipboard);
        },

        // ---- the loop ------------------------------------------------------
        windowShouldClose: () => {
            if (frameIndex >= total) return true;
            applyInput(frameIndex);
            return false;
        },
        endDrawing: () => {
            if (!sceneReady()) {
                counters.loadingFrames += 1;
                return;
            }
            timeline.push({
                i: frameIndex,
                clip: lastPosed ? lastPosed.clip : null,
                speed: speedText,
                stats: statsText,
                weather: weatherText,
            });
            // The console probe: the goat's drawn position, the console's state
            // and the active screen, taken through the same dispatcher a user
            // would.
            if (PROBE_FRAMES.indexOf(frameIndex) >= 0) {
                probes[frameIndex] = {
                    x: goatDraw === null ? null : goatDraw.x,
                    z: goatDraw === null ? null : goatDraw.z,
                    state: JSON.parse(sceneCommand('console').slice(3)),
                    ui: sceneCommand('ui').slice(3),
                };
            }
            frameIndex += 1;
        },

        // ---- models, meshes and clips --------------------------------------
        loadModel: (p) => {
            modelPaths.push(p);
            const handle = counters.modelLoads;
            counters.modelLoads += 1;
            return handle;
        },
        // The terrain grid. The engine side is covered by the runtime surface
        // test; here the scene's *use* of it matters, so the arrays are kept for
        // the facts derived in `harnessObserve`.
        makeModel: (vertices, indices, normals, colors, texcoords) => {
            counters.terrainMeshesBuilt += 1;
            lastTerrainMesh = {
                vertices: vertices, indices: indices, normals: normals,
                colors: colors, texcoords: texcoords,
            };
            return 1000 + counters.terrainMeshesBuilt;
        },
        modelBounds: () => ({ minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 1.47, maxZ: 0 }),
        modelBoneCount: () => 15,   // 13 body bones + LidL/LidR
        updateModelAnimation: (model, clip, frame) => {
            // Only the player's model (handle 0) drives the state-machine
            // checks; the bots animate their own handles and would clobber them.
            if (model === 0) lastPosed = { clip: base.modelAnimationName(model, clip), frame: frame };
            else {
                counters.botPoses += 1;
                const name = base.modelAnimationName(model, clip);
                botClipNames[name] = true;
                if (name.indexOf('GoatJump') === 0) counters.botJumps += 1;
            }
        },
        drawModelEx: function (model, x, y, z, axisX, axisY, axisZ, angle, sx, sy, sz, tint) {
            if (tint !== undefined && typeof tint !== 'number') {
                throw new TypeError('rl.drawModelEx: tint must be a packed colour, not ' + typeof tint);
            }
            counters.modelsDrawn += 1;
            // The goat is handle 0 and the terrain meshes are 1000+; everything
            // else is a bot. The bots are drawn at the ground under them, so the
            // recorded y must equal `terrainHeight` there -- which is what the
            // herd check compares. The goat's whole position is kept so the
            // console probe can show that movement stops while it is open.
            if (model === 0) goatDraw = { x: x, y: y, z: z };
            else if (model < 1000) drawnRows[model] = { x: x, y: y, z: z };
        },
        setModelShader: (_model, shader) => { modelShaderCalls.push(shader); },
        setModelTexture: (_model, index, texture) => {
            counters.textureBinds += 1;
            modelTextureCalls.push([index, texture]);
        },
        // A mod that builds its own geometry has nothing else to check: the meshes
        // it makes, the texture it bakes, the binds it does and the unload.
        makeTexture: () => { counters.texturesMade += 1; return 900 + counters.texturesMade; },
        unloadModel: () => { counters.modelsUnloaded += 1; },

        // ---- shaders and render targets ------------------------------------
        // The handle identifies which shader the scene compiled, so the checks
        // can tell the lit pass from the depth pass. The sky's fragment source is
        // kept, because a shader is only really tested by what it contains.
        loadShaderFromMemory: (vertex, fragment) => {
            if (fragment.indexOf('cloudiness') >= 0) skyFs = fragment;
            return vertex.indexOf('shadowOn') >= 0 ? 1
                : (vertex.indexOf('vClip') >= 0 ? 2 : (fragment.indexOf('cloudiness') >= 0 ? 3 : 0));
        },
        isShaderValid: () => true,
        getShaderLocation: () => 0,
        loadRenderTexture: () => 5, isRenderTextureValid: () => true,
        renderTextureColor: () => 6, renderTextureDepth: () => 7,
        renderTextureSize: () => ({ x: 1024, y: 1024 }),
        beginTextureMode: () => { shadowPass = true; },
        endTextureMode: () => { shadowPass = false; },

        // ---- audio ---------------------------------------------------------
        loadSound: (p) => { soundLoads.push(p); return soundLoads.length - 1; },
        playSound: (s) => { soundsPlayed.push(s); },
        isSoundPlaying: () => false,
        loadMusic: (p) => { musicLoads.push(p); return musicLoads.length - 1; },
        playMusic: (m) => { musicPlayed.push(m); },
        updateMusic: () => { counters.musicUpdates += 1; },
        isMusicPlaying: () => true, musicTimeLength: () => 100, musicTimePlayed: () => 0,

        // ---- raygui --------------------------------------------------------
        // The menu is drawn through these; the harness never clicks one, but the
        // progress bar's count is how the splash check knows it was drawn.
        guiProgressBar: () => { counters.progressBarCalls += 1; return { action: 0, value: 0 }; },

        // ---- drawing -------------------------------------------------------
        //
        // Deliberately parameterless. On Slag, naming a hot function's parameters
        // costs a quarter of the whole run -- 38s against 30s for the same 1.4M
        // calls -- so the tint check lives on `drawModelEx` instead, which is called
        // a few thousand times. The packed `color` above is what really closes the
        // hole the birds hit: the stub cannot hand out an object colour at all.
        drawCube: function () {
            if (shadowPass) counters.shadowCubeDraws += 1;
            counters.cubeDraws += 1;
        },
        drawRectangleLines: () => { counters.menuDraws += 1; },
        // The HUD read-outs, which are otherwise write-only. They carry the clock,
        // the speed, the lighting, the audio and the sky state in one line.
        drawText: (text) => {
            const line = String(text);
            if (line.indexOf('speed ') >= 0) speedText = line;
            else if (line.indexOf('health ') >= 0) statsText = line;
            else if (line.indexOf('wind ') >= 0) weatherText = line;
            else if (line.indexOf('Slag goat') >= 0) splashTitle = true;
            else if (line.indexOf('loading ') >= 0) splashStep = line;
        },
    });

    // ---- console.log capture ------------------------------------------------
    //
    // The host's `console.log` is a native function and does not carry
    // `Function.prototype`, so it cannot be forwarded with `.apply`; the joined
    // line is passed as one argument instead.
    const hostConsole = globalThis.console;
    const hostLog = hostConsole.log;
    hostConsole.log = function () {
        const text = Array.prototype.slice.call(arguments).join(' ');
        logs.push(text);
        hostLog(text);
    };

    // ---- the harness surface the glue and the Rust side use -----------------

    globalThis.harnessSetTotal = function (frames) {
        total = frames;
    };

    // Lets a test drive one more frame after the scripted run has ended, which is
    // how the mod cases reach the frame loop once `run()` has returned.
    globalThis.harnessResetFrame = function () {
        frameIndex = 0;
    };

    globalThis.harnessResetCounters = function (namesJson) {
        const names = JSON.parse(String(namesJson));
        for (let i = 0; i < names.length; i++) {
            if (counters[names[i]] === undefined) return 'error unknown counter: ' + names[i];
            counters[names[i]] = 0;
        }
        return 'ok';
    };

    // The terrain mesh as facts: the arrays are large, and the checks only ask
    // how many there are, how much the surface varies and how many materials it
    // carries.
    function meshFacts() {
        const mesh = lastTerrainMesh;
        if (mesh === null) return null;
        let low = 1e9;
        let high = -1e9;
        for (let i = 1; i < mesh.vertices.length; i += 3) {
            const y = mesh.vertices[i];
            if (y < low) low = y;
            if (y > high) high = y;
        }
        const seen = {};
        let materials = 0;
        for (let i = 0; i < mesh.colors.length; i += 4) {
            const key = mesh.colors[i] + ',' + mesh.colors[i + 1] + ',' + mesh.colors[i + 2];
            if (seen[key] !== true) { seen[key] = true; materials += 1; }
        }
        return {
            verts: mesh.vertices.length / 3,
            indices: mesh.indices.length,
            normals: mesh.normals.length,
            colors: mesh.colors.length,
            texcoords: mesh.texcoords.length,
            ySpread: high - low,
            materials: materials,
        };
    }

    // The numbers the scene logs, which no command reports. The patterns are not
    // global: a `g` regex carries `lastIndex` between lines and would skip
    // matches.
    function logMax(pattern) {
        const found = [];
        for (let i = 0; i < logs.length; i++) {
            const match = pattern.exec(logs[i]);
            if (match) found.push(Number(match[1]));
        }
        return found;
    }

    // `Math.min`/`Math.max` are natives too, so they are looped rather than
    // spread through an `apply`.
    function minOf(values) {
        if (values.length === 0) return null;
        let best = values[0];
        for (let i = 1; i < values.length; i++) if (values[i] < best) best = values[i];
        return best;
    }

    function maxOf(values) {
        let best = 0;
        for (let i = 0; i < values.length; i++) if (values[i] > best) best = values[i];
        return best;
    }

    function botCountFromLogs() {
        for (let i = 0; i < logs.length; i++) {
            const match = /goat: (\d+) bot goats/.exec(logs[i]);
            if (match) return Number(match[1]);
        }
        return 0;
    }

    globalThis.harnessObserve = function () {
        const drawn = [];
        for (const handle in drawnRows) drawn.push(drawnRows[handle]);
        let deathFrame = -1;
        const playerClips = [];
        const seenClip = {};
        for (let i = 0; i < timeline.length; i++) {
            const clip = timeline[i].clip;
            if (clip === 'GoatDeath' && deathFrame < 0) deathFrame = timeline[i].i;
            if (clip !== null && seenClip[clip] !== true) { seenClip[clip] = true; playerClips.push(clip); }
        }
        const idleOf = (names) => names.filter((n) => n.indexOf('GoatIdle') === 0);
        return JSON.stringify({
            loadingFrames: counters.loadingFrames,
            splashTitle: splashTitle,
            splashStep: splashStep,
            modelPaths: modelPaths,
            musicLoads: musicLoads,
            soundLoads: soundLoads,
            timeline: timeline,
            probes: probes,
            counters: {
                modelLoads: counters.modelLoads,
                botPoses: counters.botPoses,
                botJumps: counters.botJumps,
                musicUpdates: counters.musicUpdates,
                soundsPlayed: soundsPlayed.length,
                cubeDraws: counters.cubeDraws,
                shadowCubeDraws: counters.shadowCubeDraws,
                menuDraws: counters.menuDraws,
                progressBarCalls: counters.progressBarCalls,
                terrainMeshesBuilt: counters.terrainMeshesBuilt,
                texturesMade: counters.texturesMade,
                textureBinds: counters.textureBinds,
                modelsDrawn: counters.modelsDrawn,
                modelsUnloaded: counters.modelsUnloaded,
            },
            modelShaderCalls: modelShaderCalls,
            modelTextureCalls: modelTextureCalls,
            musicPlayed: musicPlayed,
            botClipNames: Object.keys(botClipNames),
            botCount: botCountFromLogs(),
            minGap: minOf(logMax(/gap (-?[\d.]+)/)),
            botBellyMax: maxOf(logMax(/bellyMax ([\d.]+)/)),
            botGrazeWalks: maxOf(logMax(/grazeWalks (\d+)/)),
            botIdles: idleOf(Object.keys(botClipNames)),
            playerIdles: idleOf(playerClips),
            playerClips: playerClips,
            deathFrame: deathFrame,
            mesh: meshFacts(),
            goatDraw: goatDraw,
            botDraw: drawn,
            skyFs: skyFs,
            clipboardWrites: clipboardWrites,
            logs: logs,
        });
    };
})();


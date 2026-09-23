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
    let waterFs = '';
    let goatDraw = null;
    // The last frame's layering, in order -- see the drawing members below. "The sun
    // is behind the cloud" is an *order*: the sky's layers with the bodies drawn
    // between them. It is cleared at each `beginDrawing` rather than accumulated,
    // because a whole run of it would be thousands of rows.
    const layers = [];
    // What a row of `layers` is: `[LAYER_SKY, layer, blend]` for a sky pass,
    // `[LAYER_MODEL, handle, 0]` for a model, `[LAYER_BILLBOARD, 0, blend]` for a
    // billboard. Numbers rather than names, so the rows deserialize as they are.
    const LAYER_SKY = 0, LAYER_MODEL = 1, LAYER_BILLBOARD = 2;
    let boundShader = -1;
    let blendMode = 0;
    let skyLayer = 0;
    let skyHandle = -1;
    const drawnRows = {};
    let lastTerrainMesh = null;
    // Which uniform each location stands for, so a recorded `setShaderValue` can be
    // named. The stub used to hand out 0 for everything, which cannot tell the shadow
    // bias from the blast's energy; the ids stay numbers (the scene compares one
    // against zero) and only the bookkeeping is new.
    const uniformNames = {};
    const uniformById = [];
    let uniformTop = 0;
    // The last value each uniform was given, by the name the *scene* asked for. With no
    // GL to compile a program, a name reached on both sides -- declared in the source and
    // asked for by that exact string -- is the strongest thing a case can check.
    const uniformValues = {};
    const uniformVectors = {};
    // The last value the scene put on the lit shader's `blastEnergy`, which is the
    // bang's light. Zero when nothing is burning.
    let blastEnergy = 0;
    // ...and the brightest it ever got, so a run can say the light was written at all
    // after the last flash has gone out.
    let blastEnergyPeak = 0;

    // The counters a test can read and reset. `cubeDraws` is reset by the tuft
    // check, which draws the field twice and compares.
    const counters = {
        loadingFrames: 0, modelLoads: 0, botPoses: 0, botJumps: 0,
        cubeDraws: 0, shadowCubeDraws: 0, menuDraws: 0, progressBarCalls: 0,
        musicUpdates: 0, terrainMeshesBuilt: 0,
        texturesMade: 0, textureBinds: 0, modelsDrawn: 0, modelsUnloaded: 0,
        billboardRecs: 0, sphereDraws: 0, billboards: 0, quadDraws: 0,
    };
    // The size each made texture was handed, so `textureWidth`/`textureHeight` answer
    // with something: the effect atlases (M19f) read their grid back off the image,
    // and a stub that always said 0 would take the fallback path every time.
    const textureSizes = {};
    const modelPaths = [];
    const botClipNames = {};
    const modelShaderCalls = [];
    const modelTextureCalls = [];
    // Which program each *model* was routed to, `[model, shader]`. The flat
    // `modelShaderCalls` above cannot tell the goat's route from the terrain
    // mesh's, and the `gpu-skinning` cases need exactly that: rigs to the skinned
    // program, everything without bone data to the plain one.
    const modelShaderRoutes = [];
    // Every `setModelCpuSkinning` the scene asked for, `[model, enabled]`: the
    // per-model fallback back to raylib's CPU deform pass.
    const cpuSkinCalls = [];
    // The vertex source of each *skinned* program the scene compiled, by handle.
    // A shader is only really tested by what it contains, and these are the ones
    // whose contents decide whether a model draws or collapses.
    const shaderVertices = {};
    const musicLoads = [];
    const musicPlayed = [];
    const soundLoads = [];
    const soundsPlayed = [];
    // Plays counted by the path that was loaded, so a check can name the sample it
    // expects -- the handles alone cannot say whether a bang or a bleat was heard.
    const soundPlays = {};
    // Which handles were played since the last frame boundary, for `isSoundPlaying`.
    const playing = {};

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

    // One vector uniform's value, by name (see `uniformVectors`).
    function recordVector(location, values) {
        const uniform = uniformById[location];
        if (uniform !== undefined) uniformVectors[uniform] = values;
    }

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
            // A frame boundary is the stub's only clock: a handle that was played is
            // "still playing" until the next one (see `isSoundPlaying`).
            for (const handle in playing) delete playing[handle];
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
        // The goat's rig: 13 body bones + LidL/LidR. A `gpu-skinning` case raises
        // `rl.MODEL_BONES` to drive a rig past the skinned programs' `boneMatrices`
        // array, which is the one rig the programs cannot cover.
        modelBoneCount: () => (typeof rl.MODEL_BONES === 'number' ? rl.MODEL_BONES : 15),
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
            // The order a model was drawn in, which is half of what "under the
            // clouds" means; the other half is the sky layer that follows it.
            layers.push([LAYER_MODEL, model, 0]);
            // The goat is handle 0 and the terrain meshes are 1000+; everything
            // else is a bot. The bots are drawn at the ground under them, so the
            // recorded y must equal `terrainHeight` there -- which is what the
            // herd check compares. The goat's whole position is kept so the
            // console probe can show that movement stops while it is open, and its
            // rotation too: the axis and angle are the one place a goat's tumble is
            // visible from here, and a flung goat is drawn on an axis of its own.
            if (model === 0) {
                goatDraw = {
                    x: x, y: y, z: z,
                    axisX: axisX, axisY: axisY, axisZ: axisZ, angle: angle,
                };
            } else if (model < 1000) {
                // The handle rides along: the herd is resized on the scripted
                // timeline, and a row for a model that has since been unloaded is
                // still in here, so a check that wants *this* bot's draw needs to
                // find it by handle rather than by position in the list.
                drawnRows[model] = {
                    model: model,
                    x: x, y: y, z: z,
                    axisX: axisX, axisY: axisY, axisZ: axisZ, angle: angle,
                };
            }
        },
        setModelShader: (model, shader) => {
            modelShaderCalls.push(shader);
            modelShaderRoutes.push([model, shader]);
        },
        // The way back to CPU skinning for one model, which a `gpu-skinning` build
        // needs for a rig its skinned programs cannot cover.
        setModelCpuSkinning: (model, enabled) => {
            cpuSkinCalls.push([model, enabled ? 1 : 0]);
        },
        setModelTexture: (_model, index, texture) => {
            counters.textureBinds += 1;
            modelTextureCalls.push([index, texture]);
        },
        // A mod that builds its own geometry has nothing else to check: the meshes
        // it makes, the texture it bakes, the binds it does and the unload.
        makeTexture: (w, h) => {
            counters.texturesMade += 1;
            const handle = 900 + counters.texturesMade;
            textureSizes[handle] = { w: w, h: h };
            return handle;
        },
        // No mod atlas in the harness's asset table, which is what the ladder's first
        // rung falls back from; `loadTexture` returning -1 is that fallback.
        loadTexture: () => -1,
        textureWidth: (t) => (textureSizes[t] ? textureSizes[t].w : 0),
        textureHeight: (t) => (textureSizes[t] ? textureSizes[t].h : 0),
        setTextureFilter: () => {},
        // The effect pipeline's own draws (M19f), counted so a check can say "one per
        // live instance" without a GPU to look at.
        unloadModel: () => { counters.modelsUnloaded += 1; },

        // ---- shaders and render targets ------------------------------------
        // Which raylib the scene is running on: the real engine reports a boolean
        // (`rl.GPU_SKINNING`, off in a CPU-skinning build). A case flips it before
        // the run, which is the only way to exercise the skinned path without a GL
        // context -- the scene branches on it rather than on behaviour.
        GPU_SKINNING: false,
        // The `BlendMode` members the scene reaches for: `ADDITIVE` for the sun's
        // glare, `ALPHA_PREMULTIPLY` for the sky's cloud layer, which attenuates the
        // bodies under it, and plain `ALPHA` for the water surface (M20b), the scene's
        // only transparent model. The engine reports the whole enum; defining these
        // here is what puts them on the tested path.
        BLEND_ALPHA: 0,
        BLEND_ADDITIVE: 1,
        BLEND_ALPHA_PREMULTIPLY: 5,
        // The handle identifies which shader the scene compiled, so the checks
        // can tell the lit pass from the depth pass. The sky's fragment source is
        // kept, because a shader is only really tested by what it contains.
        loadShaderFromMemory: (vertex, fragment) => {
            // The sky is the only program drawn as a full-screen rectangle, so its
            // handle is remembered: that is what tells a sky layer apart from every
            // other rectangle the scene draws.
            if (fragment.indexOf('cloudiness') >= 0) { skyFs = fragment; skyHandle = 3; }
            // The celestial bodies' own program (M2) declares its own fragment
            // uniform, which is how a case can say the spheres are routed to it.
            if (fragment.indexOf('shaded') >= 0) return 8;
            // The water surface's program (M20b) declares its own colours, which is how
            // a case can say a pool is routed to it rather than to the ground's.
            if (fragment.indexOf('waterDeep') >= 0) { waterFs = fragment; return 9; }
            const base = vertex.indexOf('shadowOn') >= 0 ? 1
                : (vertex.indexOf('vClip') >= 0 ? 2 : (fragment.indexOf('cloudiness') >= 0 ? 3 : 0));
            // A skinned variant is the same source plus the bone block, so it is
            // told apart by the uniform it declares and gets a handle of its own
            // (4..6, one per plain family): a case has to be able to say *which*
            // program a model was routed to. The unlit skinned program -- what `-1`
            // becomes on this build, since raylib's own default does not skin -- is
            // told from the lit family by its fragment shader carrying no light.
            if (vertex.indexOf('boneMatrices') >= 0) {
                const skinned = (base === 0 && fragment.indexOf('lightDir') < 0) ? 7 : base + 4;
                shaderVertices[skinned] = vertex;
                return skinned;
            }
            return base;
        },
        isShaderValid: () => true,
        getShaderLocation: (_shader, name) => {
            let id = uniformNames[name];
            if (id === undefined) {
                uniformTop += 1;
                id = uniformTop;
                uniformNames[name] = id;
                uniformById[id] = name;
            }
            return id;
        },
        setShaderValue: (shader, location, value) => {
            const uniform = uniformById[location];
            if (uniform !== undefined) uniformValues[uniform] = value;
            if (uniform === 'blastEnergy') {
                blastEnergy = value;
                if (value > blastEnergyPeak) blastEnergyPeak = value;
            }
            // The layer the next sky draw will ask for; recorded per draw below.
            if (uniform === 'skyLayer' && shader === skyHandle) skyLayer = value;
        },
        // The vector uniforms by name, so a case can say the chop's own numbers reached
        // the water's program (`waterWave`, `waterWind`) rather than only being declared
        // in its source.
        setShaderValueVector2: (_s, location, x, y) => recordVector(location, [x, y]),
        setShaderValueVector3: (_s, location, x, y, z) => recordVector(location, [x, y, z]),
        setShaderValueVector4: (_s, location, x, y, z, w) => recordVector(location, [x, y, z, w]),
        loadRenderTexture: () => 5, isRenderTextureValid: () => true,
        renderTextureColor: () => 6, renderTextureDepth: () => 7,
        renderTextureSize: () => ({ x: 1024, y: 1024 }),
        beginTextureMode: () => { shadowPass = true; },
        endTextureMode: () => { shadowPass = false; },

        // ---- audio ---------------------------------------------------------
        loadSound: (p) => { soundLoads.push(p); return soundLoads.length - 1; },
        playSound: (s) => {
            soundsPlayed.push(s);
            playing[s] = true;
            const path = soundLoads[s];
            soundPlays[path] = (soundPlays[path] || 0) + 1;
        },
        // The stub has no clock, so "playing" can only mean "started since the last frame
        // boundary" -- which is exactly enough for the one thing the scene asks it
        // (M19g's pools: two bangs in one frame must not take the same copy).
        isSoundPlaying: (s) => playing[s] === true,
        stopSound: (s) => { playing[s] = false; },
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
        drawBillboardRec: () => { counters.billboardRecs += 1; layers.push([LAYER_BILLBOARD, 0, blendMode]); },
        drawBillboard: () => { counters.billboards += 1; layers.push([LAYER_BILLBOARD, 0, blendMode]); },
        drawSphereEx: () => { counters.sphereDraws += 1; },
        // The blend state, which one pass of the sky is the only thing that changes:
        // the mode is recorded so a case can say the cloud layer composited rather
        // than drew over. `endBlendMode` restores raylib's default alpha (0).
        beginBlendMode: (mode) => { blendMode = mode; }, endBlendMode: () => { blendMode = 0; },
        drawQuad3D: () => { counters.quadDraws += 1; }, drawPoint3D: () => {},
        drawRectangleLines: () => { counters.menuDraws += 1; },
        // A sky layer is the one *shader-bound* rectangle the scene draws, and the
        // only way "the bodies are under the clouds" can be read back.
        beginDrawing: () => { layers.length = 0; },
        beginShaderMode: (shader) => { boundShader = shader; },
        endShaderMode: () => { boundShader = -1; },
        drawRectangle: () => {
            if (skyHandle >= 0 && boundShader === skyHandle) {
                layers.push([LAYER_SKY, skyLayer, blendMode]);
            }
        },
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
            soundPlays: soundPlays,
            // The handles, in order: a slot's pool can only be checked by asking whether
            // two plays used two different ones (M19g) -- the counts by path cannot tell
            // a second copy from a restart.
            soundHandles: soundsPlayed,
            timeline: timeline,
            probes: probes,
            // The last frame's draw order: the sky's layers, the models and the
            // billboards, as they happened.
            layers: layers,
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
                billboardRecs: counters.billboardRecs,
                sphereDraws: counters.sphereDraws,
                billboards: counters.billboards,
                quadDraws: counters.quadDraws,
            },
            modelShaderCalls: modelShaderCalls,
            modelShaderRoutes: modelShaderRoutes,
            skinnedShaders: shaderVertices,
            cpuSkinCalls: cpuSkinCalls,
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
            waterFs: waterFs,
            uniformValues: uniformValues,
            uniformVectors: uniformVectors,
            blastEnergy: blastEnergy,
            blastEnergyPeak: blastEnergyPeak,
            clipboardWrites: clipboardWrites,
            logs: logs,
        });
    };
})();


// The harness's `rl`: the null module plus what a test drives and reads back.
//
// This is evaluated after `null_rl.js`, so `rl` is already the whole surface;
// it overlays only the members the harness needs and leaves the rest alone. The
// scene cannot tell the difference, which is the point: the same script runs
// here as in the game, so a binding or a builtin the engine lacks fails a test
// instead of passing one.
//
// The loop control lives here. `windowShouldClose` stops the run once the frame
// budget is spent, applying that frame's scripted input first; `endDrawing`
// records the frame. Loading frames are not counted -- the scene takes one
// startup step per frame and draws the splash -- so a recorded `i` counts frames
// *after* the scene is ready, exactly as `tools/goat_logic_test.js` counted them.
//
// The budget is settable (`harnessSetTotal`) so a test can drive a short run; the
// frame indices are absolute either way, so a short run sees the same inputs at
// the same frames and simply stops earlier.

(function () {
    const DEFAULT_TOTAL = 4050;
    let total = DEFAULT_TOTAL;

    // The recorded run: one row per ready frame.
    const timeline = [];
    // Input, exactly as raylib queues it: key state for the frame, one-shot
    // presses, and the typed-character queue.
    const keys = {};
    const pressed = {};
    const chars = [];
    let clipboard = '';
    const clipboardWrites = [];

    let frameIndex = 0;
    let loadingFrames = 0;
    let modelLoads = 0;
    const modelPaths = [];
    let lastPosed = null;
    let speedText = '';
    let statsText = '';
    let weatherText = '';
    let splashTitle = false;
    let splashStep = '';
    let cubeDraws = 0;

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

    const base = globalThis.rl;
    globalThis.rl = Object.assign({}, base, {
        // Input: the script, not the keyboard.
        isKeyDown: (k) => !!keys[k],
        isKeyPressed: (k) => !!pressed[k],
        getCharPressed: () => (chars.length > 0 ? chars.shift() : 0),
        getClipboardText: () => clipboard,
        setClipboardText: (text) => {
            clipboard = String(text);
            clipboardWrites.push(clipboard);
        },

        // The loop. The scene's own `run()` calls these, so the harness drives
        // the real frame loop rather than a re-implementation of it.
        windowShouldClose: () => {
            if (frameIndex >= total) return true;
            applyInput(frameIndex);
            return false;
        },
        endDrawing: () => {
            if (!sceneReady()) {
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
            frameIndex += 1;
        },

        // Models and clips. Handle 0 is the player's goat; the bots animate their
        // own handles, so only the goat drives the state-machine checks.
        loadModel: (p) => {
            modelPaths.push(p);
            const handle = modelLoads;
            modelLoads += 1;
            return handle;
        },
        updateModelAnimation: (model, clip, frame) => {
            if (model === 0) lastPosed = { clip: base.modelAnimationName(model, clip), frame: frame };
        },

        // The HUD read-outs, which are otherwise write-only.
        drawText: (text) => {
            const line = String(text);
            if (line.indexOf('speed ') >= 0) speedText = line;
            else if (line.indexOf('health ') >= 0) statsText = line;
            else if (line.indexOf('wind ') >= 0) weatherText = line;
            else if (line.indexOf('Slag goat') >= 0) splashTitle = true;
            else if (line.indexOf('loading ') >= 0) splashStep = line;
        },
        drawCube: () => { cubeDraws += 1; },
    });

    globalThis.harnessSetTotal = function (frames) {
        total = frames;
    };

    // Everything the Rust side reads, as one JSON string -- the shape
    // `sceneWorldJson` already uses for the same reason.
    globalThis.harnessObserve = function () {
        return JSON.stringify({
            loadingFrames: loadingFrames,
            modelLoads: modelLoads,
            modelPaths: modelPaths,
            timeline: timeline,
            splashTitle: splashTitle,
            splashStep: splashStep,
            cubeDraws: cubeDraws,
            clipboardWrites: clipboardWrites,
        });
    };
})();

// A stub `rl` for the headless server scene.
//
// `goatsd` evaluates the same scene the client does (`crates/goats/src/game/`)
// so the bots and the weather move by exactly the same rules, but it has no
// window and no GPU. This file is the null `rl` module it needs: every member
// the scene touches, with the drawing and input calls doing nothing and the few
// that the simulation actually reads returning something plausible.
//
// It must stay in step with the scene's use of `rl`. The surface here is
// enumerated from the scene itself; a member the scene adds and this file
// forgets will fail loudly (`rl.thing is not a function`) the first time the
// server runs, which is the point of not using a catch-all Proxy.

(function () {
    const KEY = {
        KEY_SPACE: 32, KEY_ESCAPE: 256, KEY_ENTER: 257, KEY_BACKSPACE: 259,
        KEY_DELETE: 261, KEY_RIGHT: 262, KEY_LEFT: 263, KEY_DOWN: 264, KEY_UP: 265,
        KEY_LEFT_SHIFT: 340, KEY_RIGHT_SHIFT: 344,
        KEY_LEFT_CONTROL: 341, KEY_RIGHT_CONTROL: 345,
        KEY_A: 65, KEY_B: 66, KEY_C: 67, KEY_D: 68, KEY_E: 69, KEY_F11: 122,
        KEY_K: 75, KEY_L: 76, KEY_M: 77, KEY_P: 80, KEY_R: 82, KEY_S: 83,
        KEY_T: 84, KEY_V: 86, KEY_W: 87, KEY_Z: 90, KEY_GRAVE: 96,
        MOUSE_BUTTON_LEFT: 0,
        SHADER_UNIFORM_FLOAT: 0, SHADER_UNIFORM_VEC2: 1, SHADER_UNIFORM_VEC3: 2,
        SHADER_UNIFORM_VEC4: 3, SHADER_UNIFORM_INT: 4, SHADER_UNIFORM_UINT: 8,
    };

    // The clips the scene indexes by name. The names are what matter -- the
    // scene matches on substrings -- and the durations give the gaits their
    // speeds, so they mirror the real model's.
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

    let models = 0;
    let terrain = 0;
    const noop = function () {};
    const color = (r, g, b, a) => ({ r: r, g: g, b: b, a: a === undefined ? 255 : a });

    globalThis.rl = Object.assign({}, KEY, {
        color: color,
        WHITE: color(255, 255, 255), RAYWHITE: color(245, 245, 245),

        // Window and loop.
        initWindow: noop, setTargetFPS: noop, closeWindow: noop, setExitKey: noop,
        toggleFullscreen: noop, isWindowFullscreen: () => false,
        windowShouldClose: () => false,   // the server owns the loop
        getFrameTime: () => 1 / 60,       // a fixed step, so the sim is steady
        getFPS: () => 60, getScreenWidth: () => 1000, getScreenHeight: () => 640,

        // Input: nothing is ever pressed.
        isKeyDown: () => false, isKeyPressed: () => false, isKeyUp: () => true,
        getCharPressed: () => 0, getClipboardText: () => '', setClipboardText: noop,
        isMouseButtonDown: () => false, getMouseDeltaX: () => 0, getMouseDeltaY: () => 0,
        getMouseWheelMove: () => 0,

        // Models. `loadModel` always "succeeds", so the scene builds a real herd;
        // the terrain mesh is accepted and dropped.
        loadModel: () => models++,
        unloadModel: noop, isModelValid: () => true,
        makeModel: () => 1000 + terrain++,
        modelBounds: () => ({ minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 1.47, maxZ: 0 }),
        modelBoneCount: () => 15,
        modelAnimationCount: () => CLIPS.length,
        modelAnimationName: (_m, i) => CLIPS[i].name,
        modelAnimationFrameCount: (_m, i) => clipFrames[i],
        modelAnimationDuration: (_m, i) => CLIPS[i].dur,
        updateModelAnimation: noop,
        setModelShader: noop, setModelTexture: noop,

        // Shaders, render targets and textures: none exist headlessly, so the
        // scene takes its unlit path. `loadShaderFromMemory` returning -1 is
        // what makes `litShader < 0`.
        loadShaderFromMemory: () => -1, isShaderValid: () => false, getShaderLocation: () => -1,
        beginShaderMode: noop, endShaderMode: noop,
        setShaderValue: noop, setShaderValueVector2: noop, setShaderValueVector3: noop,
        setShaderValueVector4: noop, setShaderValueMatrix: noop, setShaderValueTexture: noop,
        loadRenderTexture: () => -1, isRenderTextureValid: () => false,
        renderTextureColor: () => -1, renderTextureDepth: () => -1,
        renderTextureSize: () => ({ x: 0, y: 0 }),
        beginTextureMode: noop, endTextureMode: noop,
        makeTexture: () => 0,

        // Audio: devices "open" and handles are handed out, but nothing plays.
        initAudioDevice: noop, closeAudioDevice: noop,
        loadSound: () => 0, playSound: noop, stopSound: noop,
        setSoundVolume: noop, setSoundPitch: noop, isSoundPlaying: () => false,
        loadMusic: () => 0, unloadMusic: noop, playMusic: noop, updateMusic: noop,
        stopMusic: noop, pauseMusic: noop, resumeMusic: noop,
        setMusicVolume: noop, setMusicPitch: noop, isMusicPlaying: () => false,
        musicTimeLength: () => 0, musicTimePlayed: () => 0,

        // Drawing: nothing.
        beginDrawing: noop, endDrawing: noop, clearBackground: noop,
        beginMode3D: noop, endMode3D: noop,
        drawCube: noop, drawLine: noop, drawPoint3D: noop, drawBillboard: noop,
        drawModelEx: noop,
        drawRectangle: noop, drawRectangleGradientV: noop, drawRectangleLines: noop,
        drawText: noop, takeScreenshot: noop,

        // raygui: present so the menu code does not throw, never interacted with.
        gui: {},
        guiPanel: noop, guiGroupBox: noop, guiLabel: noop,
        guiButton: () => false, guiProgressBar: () => ({ action: 0, value: 0 }),
        guiToggle: (_x, _y, _w, _h, _t, v) => ({ action: 0, value: v }),
        guiSlider: (_x, _y, _w, _h, _l, _r, v) => ({ action: 0, value: v }),
        guiComboBox: (_x, _y, _w, _h, _t, v) => ({ action: 0, value: v }),
    });
})();

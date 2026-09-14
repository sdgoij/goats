// The harness's entry points into the scene.
//
// Appended after the scene, so it can call anything the scene defines. Each
// function is one Rust/JS crossing: `harnessRun` drives the whole scripted run
// inside the engine and comes back with the observations as one JSON string,
// which is why the frame loop is not re-implemented on the Rust side.
//
// Everything that can fail returns an `{ok, value}` / `{ok, error}` envelope
// rather than throwing, so a failing test reports what the scene actually said
// instead of a bare conversion error.

// Run the scene to the frame budget and return the observations.
//
// `run()` is the scene's own loop -- `sceneInit`, `while (sceneFrame())`,
// `sceneShutdown` -- so the harness drives exactly the loop the game does; the
// stub's `windowShouldClose` decides when it stops.
function harnessRun(total) {
    if (typeof total === "number") harnessSetTotal(total);
    run();
    return harnessObserve();
}

// One command, through the same dispatcher the console and stdin use.
function harnessCommand(line) {
    return sceneCommand(String(line));
}

// Whether the scene has finished loading, so a test can watch the splash.
function harnessReady() {
    return sceneReady();
}

// Steps the scene's `update` hooks `frames` times inside the engine.
//
// A case that simulates minutes of a mod's behaviour would otherwise be thousands
// of Rust/JS crossings; this makes it one.
function harnessStep(frames, dt) {
    for (let i = 0; i < frames; i++) modFrameTick(dt);
    return null;
}

// Deliver a compiled mod's module to the scene. The bytes cross as an
// `ArrayBuffer` rather than as JSON, because that is what the ABI takes: a
// module is content, and the host hands over bytes rather than a path.
function harnessWasmModule(id, bytes) {
    return sceneWasmModule(String(id), bytes);
}

// Call any scene function by name, with JSON-encoded arguments. This is how a
// test drives the seams no command covers: `terrainHeight`, `nearestTuft`,
// `updateFood`, `rainSlowFactor`, and the mod wiring (`sceneMods`,
// `sceneModResult`, `sceneModTuning`, `sceneModDrain`).
function harnessCall(name, argsJson) {
    try {
        const fn = globalThis[name];
        if (typeof fn !== "function") {
            return JSON.stringify({ ok: false, error: "no such scene function: " + name });
        }
        const value = fn.apply(null, JSON.parse(argsJson));
        return JSON.stringify({ ok: true, value: value === undefined ? null : value });
    } catch (error) {
        return JSON.stringify({ ok: false, error: String(error) });
    }
}

// Evaluate a snippet in the scene's scope and return its value.
//
// This exists because some state is reachable only as a top-level `const` -- the
// mod tests drive the `goats` handle directly -- and a direct `eval` in a
// function defined at the scene's own top level sees that lexical scope, the way
// `vm.runInContext` did in the Node harness.
function harnessEval(code) {
    try {
        const value = eval(String(code));
        return JSON.stringify({ ok: true, value: value === undefined ? null : value });
    } catch (error) {
        return JSON.stringify({ ok: false, error: String(error) });
    }
}

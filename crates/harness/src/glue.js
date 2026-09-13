// The harness's entry points into the scene.
//
// Appended after the scene, so it can call anything the scene defines. Each
// function is one Rust/JS crossing: `harnessRun` drives the whole scripted run
// inside the engine and comes back with the observations as one JSON string,
// which is why the frame loop is not re-implemented on the Rust side.

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

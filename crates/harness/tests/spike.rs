//! The M15a spike: the scene boots and runs on Slag, in Rust, with no Node.
//!
//! These are not the ported assertions -- those live in `scene_logic.rs` and
//! `observations.rs`. What is checked here is the footing itself: that the scene
//! evaluates and runs on the engine, that the scripted run is reproducible, that
//! commands cross the boundary, and that two harnesses can run at once. It is
//! deliberately short, so it stays cheap enough to run with the rest of the
//! workspace.

use harness::Harness;

/// Long enough for the load, the gaits, the jump and sleep -- everything the
/// scripted input does before frame 200.
const SHORT: u32 = 220;

/// Runs the short timeline and returns what the stub recorded.
fn short_run() -> harness::Observations {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(SHORT).expect("run the scene")
}

#[test]
fn the_scene_boots_and_runs_on_the_engine() {
    let mut harness = Harness::start().expect("evaluate the scene");
    assert!(
        !harness.ready().expect("sceneReady"),
        "the scene starts unloaded so the host can draw a splash"
    );

    let obs = harness.run(SHORT).expect("run the scene");

    // The splash drew first, one startup step per frame.
    assert!(obs.splash_title, "the splash should name the game");
    assert!(
        obs.splash_step.starts_with("loading "),
        "{}",
        obs.splash_step
    );
    assert!(obs.loading_frames > 0, "the splash should take some frames");

    // Then the world loaded: the goat's model and the herd's.
    assert!(!obs.model_paths.is_empty(), "a model was loaded");
    assert!(
        obs.counters.model_loads >= 2,
        "the goat and its herd: {}",
        obs.counters.model_loads
    );

    // The frame loop ran and drew.
    assert!(!obs.timeline.is_empty(), "frames were recorded");
    assert!(obs.counters.cube_draws > 0, "the world drew cubes");

    // The gaits, the jump and sleep, in the same frames the Node harness used.
    assert!(obs.is_clip(15, "GoatWalk"), "{:?}", obs.clip_at(15));
    assert!(obs.is_clip(40, "GoatTrot"), "{:?}", obs.clip_at(40));
    assert!(obs.is_clip(60, "GoatRun"), "{:?}", obs.clip_at(60));
    assert!(obs.is_clip(70, "GoatJump"), "{:?}", obs.clip_at(70));
    assert!(obs.is_clip(160, "GoatSleep"), "{:?}", obs.clip_at(160));

    // The HUD read-outs are the strings the scene drew.
    let row = obs.row(15).expect("frame 15");
    assert!(row.speed.contains("speed "), "{:?}", row.speed);
}

#[test]
fn the_scripted_run_is_deterministic() {
    let a = short_run();
    let b = short_run();
    assert_eq!(a, b, "the same script must produce the same run");
}

#[test]
fn commands_reach_the_scene_dispatcher() {
    let mut harness = Harness::start().expect("evaluate the scene");
    assert_eq!(harness.command("ping").expect("ping"), "ok pong");

    // `help` is built at load time with `String.prototype.padEnd`, and comes back
    // as one multi-line page -- so this reaches a builtin the engine must have.
    let help = harness.command("help").expect("help");
    assert!(help.starts_with("ok help - commands by topic"), "{help}");
    assert!(help.contains('\n'), "help is a page, not one line: {help}");
    assert!(help.contains("  mods    mod"), "{help}");
}

#[test]
fn two_harnesses_run_at_once() {
    // The engine installs its JIT per context, so two contexts must be able to
    // run on two threads without stepping on each other.
    let left = std::thread::spawn(short_run);
    let right = std::thread::spawn(short_run);
    let (left, right) = (
        left.join().expect("left thread"),
        right.join().expect("right thread"),
    );
    assert_eq!(left, right, "two contexts must agree");
}

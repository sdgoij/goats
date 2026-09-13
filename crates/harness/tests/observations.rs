//! What the stub records, and what a test can drive after the run.
//!
//! The spike proved the scene runs on the engine. These check the other half of
//! the harness: that the observations carry what the ported assertions will need
//! (the terrain mesh, the log-derived numbers, the call tables, the drawn
//! positions) and that a test can still drive the scene afterwards -- a command,
//! a scene function by name, an `eval` into the scene's own scope, and a counter
//! measured between two calls.

use harness::Harness;
use serde_json::json;

/// Long enough for the load, the gaits, the jump and sleep.
const SHORT: u32 = 220;

#[test]
fn the_observations_cover_the_run() {
    let mut harness = Harness::start().expect("evaluate the scene");
    let obs = harness.run(SHORT).expect("run the scene");

    // The terrain mesh, as facts: a 49x49 grid carrying real normals, colours,
    // UVs and several materials, and a surface that is not flat.
    let mesh = obs.mesh.as_ref().expect("the terrain mesh was built");
    assert_eq!(mesh.verts, 49 * 49);
    assert_eq!(mesh.indices, 48 * 48 * 6);
    assert_eq!(mesh.normals, mesh.verts * 3);
    assert_eq!(mesh.colors, mesh.verts * 4);
    assert_eq!(mesh.texcoords, mesh.verts * 2);
    assert!(
        mesh.y_spread > 0.5,
        "the field is not flat: {}",
        mesh.y_spread
    );
    assert!(mesh.materials >= 4, "{} materials", mesh.materials);

    // The scene's own log lines are captured: the herd size and the bots'
    // measurements are reported nowhere else.
    assert!(
        obs.logs.iter().any(|line| line.contains("bot goats")),
        "{:?}",
        obs.logs
    );
    assert_eq!(obs.bot_count, 7);
    assert!(!obs.bot_clip_names.is_empty(), "the bots animated");

    // The shaders the scene compiled are identifiable by handle: the lit pass,
    // the depth pass's vertex shader and the sky's fragment source.
    assert!(
        obs.model_shader_calls.contains(&0),
        "the lit shader was used: {:?}",
        obs.model_shader_calls
    );
    assert!(
        !obs.sky_fs.is_empty(),
        "the sky shader's source was captured"
    );

    // Audio loaded and streamed.
    assert!(!obs.music_loads.is_empty(), "the beds loaded");
    assert!(obs.counters.music_updates > 0, "the streams were fed");

    // The goat idled before the script walked it, and was drawn on the terrain.
    assert!(!obs.player_idles.is_empty(), "{:?}", obs.player_clips);
    let goat = obs.goat_draw.as_ref().expect("the goat was drawn");
    let ground = harness
        .call("terrainHeight", &[json!(goat.x), json!(goat.z)])
        .expect("terrainHeight");
    let ground = ground.as_f64().expect("a height");
    assert!(
        (goat.y - ground).abs() < 0.02,
        "the goat is drawn on the terrain: {} vs {}",
        goat.y,
        ground
    );

    // Every bot was drawn on the terrain under it.
    assert!(!obs.bot_draw.is_empty(), "the herd was drawn");
    for bot in &obs.bot_draw {
        let height = harness
            .call("terrainHeight", &[json!(bot.x), json!(bot.z)])
            .expect("terrainHeight")
            .as_f64()
            .expect("a height");
        assert!(
            (bot.y - height).abs() < 1e-6,
            "a bot stands on the terrain: {} vs {}",
            bot.y,
            height
        );
    }
}

#[test]
fn the_scene_state_is_reachable_from_a_test() {
    let mut harness = Harness::start().expect("evaluate the scene");

    // `eval` sees the scene's top-level scope, including its `const`s -- which is
    // how the mod tests reach the `goats` handle.
    let herd = harness.eval("TUNING.herd.count").expect("read TUNING");
    assert_eq!(herd.as_f64(), Some(7.0));

    // `call` reaches a scene function with JSON arguments.
    let height = harness
        .call("terrainHeight", &[json!(0.0), json!(0.0)])
        .expect("terrainHeight");
    assert_eq!(height.as_f64(), Some(0.0));
    // A belly full of grass eases the rain slowdown; that is the `rainEase` check.
    let empty = harness
        .call("rainSlowFactor", &[json!(0.0)])
        .expect("rainSlowFactor")
        .as_f64()
        .expect("a factor");
    let full = harness
        .call("rainSlowFactor", &[json!(1.0)])
        .expect("rainSlowFactor")
        .as_f64()
        .expect("a factor");
    assert!(
        empty > full,
        "a full belly eases the rain: {empty} vs {full}"
    );

    // A name the scene does not define is reported, not panicked on.
    let missing = harness.call("noSuchSceneFunction", &[]).unwrap_err();
    assert!(missing.contains("no such scene function"), "{missing}");
}

#[test]
fn counters_can_be_reset_and_re_read() {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(SHORT).expect("run the scene");

    // The tuft-draw check, which is how the visual side of eating is proven: draw
    // the field around the origin, eat one tuft, draw it again, and the second
    // pass must draw fewer cubes.
    let tuft = harness
        .call("nearestTuft", &[json!(0.0), json!(0.0), json!(20.0)])
        .expect("nearestTuft");
    assert!(!tuft.is_null(), "a tuft should be in range of the origin");

    let draw = |harness: &mut Harness| {
        harness
            .call(
                "drawTufts",
                &[
                    json!({ "px": 0.0, "pz": 0.0 }),
                    json!(0),
                    json!(576),
                    json!(180),
                ],
            )
            .expect("drawTufts");
        harness.observe().expect("observe").counters.cube_draws
    };

    harness
        .reset_counters(&["cubeDraws"])
        .expect("reset cubeDraws");
    let before = draw(&mut harness);

    harness.call("consumeTuft", &[tuft]).expect("consumeTuft");
    harness
        .reset_counters(&["cubeDraws"])
        .expect("reset cubeDraws");
    let after = draw(&mut harness);

    assert!(before > 0, "the field drew cubes");
    assert!(
        after < before,
        "the eaten tuft stopped being drawn: {before} -> {after}"
    );

    // An unknown counter is an error, not a silent no-op.
    let unknown = harness.reset_counters(&["nope"]).unwrap_err();
    assert!(unknown.contains("unknown counter"), "{unknown}");
}

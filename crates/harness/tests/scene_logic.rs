//! The ported scene suite: `tools/goat_logic_test.js`, in Rust, on Slag.
//!
//! One full 4050-frame run, then the cases the Node harness asserted, reported
//! through [`Checks`] so a failure names itself and the rest still run. This file
//! is the port target for the whole of `goat_logic_test.js`; it grows slice by
//! slice, and until the last slice lands the Node harness stays as the authority
//! for the expected values.
//!
//! The run is long (~35s in a release build) and the frame indices are absolute,
//! so the test is `#[ignore]`d and driven explicitly:
//!
//! ```text
//! cargo test --release -p harness --test scene_logic -- --ignored --nocapture
//! ```

mod support;

use harness::Harness;
use serde_json::json;
use support::{Checks, bool_of, command_json, f64_of};

/// The frames the scripted timeline runs for: the walk, the jump, the death and
/// the restart all happen inside it.
const TOTAL: u32 = 4050;

#[test]
#[ignore = "the full 4050-frame run: ~35s release, ~2min debug"]
fn the_scene_runs_the_scripted_timeline() {
    let started = std::time::Instant::now();
    let mut harness = Harness::start().expect("evaluate the scene");
    // The scene must hand the loop back unloaded, so the host can paint a splash.
    let ready_before = harness.ready().expect("sceneReady");
    let has_load_step = bool_of(
        harness
            .eval("typeof sceneLoadStep === \"function\"")
            .expect("eval"),
    );
    // Read before the scripted input, which presses L and the rest.
    let settings_before = command_json(&mut harness, "settings");
    let obs = harness.run(TOTAL).expect("run the scene");
    let elapsed = started.elapsed();
    let mut checks = Checks::new();

    eprintln!(
        "harness: {} frames in {:?} ({:.1} ms/frame), {} cubes",
        obs.timeline.len(),
        elapsed,
        elapsed.as_secs_f64() * 1000.0 / obs.timeline.len().max(1) as f64,
        obs.counters.cube_draws
    );

    // A throw would have come back as an error from `run` or from a later drive,
    // so reaching here is the case.
    checks.check("no throw", true, "the scene evaluated and ran");
    checks.check(
        "the run reached the end",
        obs.row(4040).is_some(),
        obs.timeline.len(),
    );

    // ---- the splash and the embedded assets ------------------------------
    checks.check(
        "the scene starts unloaded",
        !ready_before && has_load_step,
        (ready_before, has_load_step),
    );
    checks.check(
        "the loader takes one step per frame",
        obs.loading_frames == 9 + 7 - 1,
        obs.loading_frames,
    );
    checks.check(
        "the splash draws a progress bar",
        obs.counters.progress_bar_calls == obs.loading_frames
            && obs.counters.progress_bar_calls > 0,
        (obs.counters.progress_bar_calls, obs.loading_frames),
    );
    checks.check(
        "the splash names the game and step count",
        obs.splash_title && obs.splash_step == "loading 15 / 16",
        (obs.splash_title, obs.splash_step.clone()),
    );
    // Every asset the scene asked for has to be in the client's embedded table,
    // or the binary silently falls back to a file on disk and stops being
    // self-contained.
    let table = embedded_names();
    let mut requested: Vec<String> = Vec::new();
    for path in obs
        .model_paths
        .iter()
        .chain(&obs.music_loads)
        .chain(&obs.sound_loads)
    {
        if !requested.contains(path) {
            requested.push(path.clone());
        }
    }
    let missing: Vec<&String> = requested
        .iter()
        .filter(|path| !table.contains(path))
        .collect();
    checks.check(
        "every requested asset is embedded",
        requested.len() >= 10 && missing.is_empty(),
        missing.clone(),
    );
    checks.check(
        "the embedded table covers model and audio",
        table.len() >= 13,
        table.len(),
    );

    // ---- the gait state machine ------------------------------------------
    // The frames are the scripted input's, so they are the same frames the Node
    // harness checked.
    checks.check(
        "idle at frame 3",
        obs.is_clip(3, "GoatIdle"),
        obs.clip_at(3),
    );
    checks.check(
        "walk at frame 15",
        obs.clip_at(15) == Some("GoatWalk"),
        obs.clip_at(15),
    );
    checks.check(
        "trot at frame 40",
        obs.clip_at(40) == Some("GoatTrot"),
        obs.clip_at(40),
    );
    checks.check(
        "run at frame 60",
        obs.clip_at(60) == Some("GoatRun"),
        obs.clip_at(60),
    );
    checks.check(
        "jump starts at frame 70",
        obs.is_clip(70, "GoatJump"),
        obs.clip_at(70),
    );
    checks.check(
        "landed to idle by frame 145",
        obs.is_clip(145, "GoatIdle"),
        obs.clip_at(145),
    );
    checks.check(
        "sleeping at frame 160",
        obs.is_clip(160, "GoatSleep"),
        obs.clip_at(160),
    );
    checks.check(
        "woke to walk at frame 190",
        obs.clip_at(190) == Some("GoatWalk"),
        obs.clip_at(190),
    );

    // The gaits' speeds come from the clip durations, so they check both the
    // clips and the HUD's arithmetic.
    let walk = obs.speed_at(15);
    checks.check(
        "walk speed ~0.87 m/s",
        walk.is_some_and(|s| (s - 0.873).abs() < 0.01),
        walk,
    );
    let trot = obs.speed_at(40);
    checks.check(
        "trot speed ~1.58 m/s",
        trot.is_some_and(|s| (s - 1.577).abs() < 0.02),
        trot,
    );
    let run = obs.speed_at(60);
    checks.check(
        "run speed ~2.94 m/s",
        run.is_some_and(|s| (s - 2.941).abs() < 0.02),
        run,
    );

    // ---- stats, the clock, and dying -------------------------------------
    let e20 = obs.stat_at(20);
    let e60 = obs.stat_at(60);
    checks.check(
        "energy drains while running",
        matches!((e20, e60), (Some(early), Some(late)) if late.energy < early.energy),
        (e20, e60),
    );

    let c20 = obs.clock_at(20);
    let c1200 = obs.clock_at(1200);
    checks.check(
        "clock advances over time",
        matches!((c20, c1200), (Some(early), Some(late)) if late > early),
        (c20, c1200),
    );

    let death = obs.death_frame;
    checks.check(
        "goat dies of exhaustion",
        (200..3950).contains(&death),
        death,
    );
    let death_frame = u32::try_from(death).ok();
    let held = death_frame.and_then(|frame| obs.clip_at(frame + 5));
    checks.check(
        "death clip held while dead",
        held == Some("GoatDeath"),
        held,
    );
    let dead = death_frame.and_then(|frame| obs.stat_at(frame));
    checks.check(
        "health is zero at death",
        dead.is_some_and(|s| s.health == 0),
        dead,
    );
    checks.check(
        "R restarts into run",
        obs.clip_at(4000) == Some("GoatRun"),
        obs.clip_at(4000),
    );
    checks.check(
        "the player cycles idle variants",
        obs.player_idles.len() >= 2,
        obs.player_idles.clone(),
    );

    // ---- the run finished where it should --------------------------------
    // The console's scripted frames sit after the restart, so these also prove
    // the run reached them rather than stopping early.
    let probe = obs.probe(4016).expect("the console probe at 4016");
    checks.check(
        "the console is open at its probe",
        probe.state.open,
        probe.state.open,
    );
    checks.check(
        "the console kept the command in its history",
        probe.state.history.iter().any(|entry| entry == "ping"),
        probe.state.history.clone(),
    );
    checks.check(
        "the console answered the command",
        probe
            .state
            .lines
            .iter()
            .any(|line| line == "local: ok pong"),
        probe.state.lines.clone(),
    );
    checks.check(
        "the console copied the pasted line",
        obs.clipboard_writes
            .iter()
            .any(|w| w.ends_with("endpointABC")),
        obs.clipboard_writes.clone(),
    );
    checks.check("the herd loaded", obs.bot_count >= 2, obs.bot_count);
    checks.check(
        "the herd was drawn",
        !obs.bot_draw.is_empty(),
        obs.bot_draw.len(),
    );
    checks.check(
        "the bots kept their distance",
        obs.min_gap.is_some(),
        obs.min_gap,
    );

    // ---- weather, lighting and the sky -----------------------------------
    let reported = obs.weather_at(300);
    checks.check(
        "weather text is reported",
        reported.is_some_and(|line| !line.is_empty()),
        reported,
    );
    // `C` forces the next weather, at frames 3000 and 3100.
    let before = obs.weather_at(2999);
    let after = obs.weather_at(3200);
    checks.check(
        "C changes the weather",
        matches!((before, after), (Some(a), Some(b)) if a != b),
        (before, after),
    );
    // It rained at the scripted frame, and rain is slower than dry grass.
    let wet = obs.weather_at(3400);
    checks.check(
        "rain is reported at the test frame",
        wet.is_some_and(|line| line.contains("rain ")),
        wet,
    );
    let slowed = obs.speed_at(3400);
    checks.check(
        "rain slows the goat",
        matches!((slowed, walk), (Some(slow), Some(dry)) if slow < dry - 0.01),
        (slowed, walk),
    );

    checks.check(
        "lighting is active",
        obs.light_at(15) == Some("lit + shadow map"),
        obs.light_at(15),
    );
    checks.check(
        "L toggles lighting off",
        obs.light_at(3210) == Some("off"),
        obs.light_at(3210),
    );

    // ---- the shader passes and the shadow map ----------------------------
    checks.check(
        "model uses the lit shader",
        obs.model_shader_calls.contains(&0),
        obs.model_shader_calls.iter().take(4).collect::<Vec<_>>(),
    );
    checks.check(
        "depth pass uses the depth shader",
        obs.model_shader_calls.contains(&2),
        obs.model_shader_calls.iter().take(6).collect::<Vec<_>>(),
    );
    checks.check(
        "grass casts in the shadow pass",
        obs.counters.shadow_cube_draws > 0,
        obs.counters.shadow_cube_draws,
    );
    let bound = obs
        .model_texture_calls
        .iter()
        .any(|call| call.first() == Some(&1) && call.get(1) == Some(&6));
    checks.check(
        "shadow map bound to the model",
        bound,
        obs.model_texture_calls.iter().take(4).collect::<Vec<_>>(),
    );

    // ---- audio -----------------------------------------------------------
    checks.check(
        "background music plays",
        obs.music_played.contains(&0),
        obs.music_played.iter().take(4).collect::<Vec<_>>(),
    );
    checks.check(
        "music streams are updated",
        obs.counters.music_updates > 0,
        obs.counters.music_updates,
    );
    checks.check(
        "ambience beds load",
        obs.music_loads.len() >= 3,
        obs.music_loads.len(),
    );
    checks.check(
        "the goat bleats on jump",
        obs.counters.sounds_played > 0,
        obs.counters.sounds_played,
    );
    checks.check(
        "audio is reported",
        obs.audio_at(15) == Some("on"),
        obs.audio_at(15),
    );
    checks.check(
        "the sky shader is used",
        obs.sky_at(15) == Some("shader"),
        obs.sky_at(15),
    );

    // ---- the sky fragment shader's own markers ---------------------------
    // These markers only exist in the volumetric march, not in the flat M5 layer
    // it replaced.
    let sky = &obs.sky_fs;
    checks.check(
        "the sky shader marches a volume",
        ["sunTau", "cloudSteps", "slabY", "hg("]
            .iter()
            .all(|marker| sky.contains(marker)),
        sky.len(),
    );
    // The sun and moon discs are sprites drawn over this pass, so a smoothstep on
    // the sun dot here would draw a second disc.
    checks.check(
        "the sky shader leaves the discs to drawCelestial",
        !sky.contains("smoothstep(0.999"),
        sky.find("smoothstep(0.999"),
    );

    // ---- grass is food ---------------------------------------------------
    // `run()` has finished, so the mechanic is exercised through the same command
    // channel the host uses: find a tuft, stand beside it, then eat it.
    let after_run = command_json(&mut harness, "state");
    let bot_eats = after_run["eaten"].as_u64().unwrap_or(0);
    let bot_satiety = f64_of(after_run["satiety"].clone());
    let mut eat = Eat::default();
    harness.command("energy 40").expect("energy");
    let found = command_json(&mut harness, "grass");
    if !found.is_null() {
        eat.found = true;
        // Stand half a metre short of the tuft, facing away, so the eat's facing
        // snap is observable.
        let (x, z) = (f64_of(found["x"].clone()), f64_of(found["z"].clone()));
        harness
            .command(&format!("pos {} {}", x - 0.5, z))
            .expect("pos");
        harness.command("yaw 180").expect("yaw");
        let before = command_json(&mut harness, "state");
        eat.menu = before["foodInReach"] == json!(true);
        let reply = harness.command("eat").expect("eat");
        let after = command_json(&mut harness, "state");
        eat.ate = reply.starts_with("ok");
        eat.energy_rose = f64_of(after["energy"].clone()) > f64_of(before["energy"].clone());
        eat.satiety_rose = f64_of(after["satiety"].clone()) > 0.0;
        // The goat turns onto the tuft (yaw 0 faces +x, where the tuft lies).
        eat.faced = f64_of(after["yaw"].clone()).abs() < 0.2;
        let again = command_json(&mut harness, "grass");
        eat.gone = again.is_null() || again["key"] != found["key"];
        // Run the food clock past the longest regrow delay; the tuft returns.
        harness
            .call("updateFood", &[json!(200.0)])
            .expect("updateFood");
        let regrown = command_json(&mut harness, "grass");
        eat.regrew = !regrown.is_null() && regrown["key"] == found["key"];
    }
    let empty_belly = f64_of(
        harness
            .call("rainSlowFactor", &[json!(0.0)])
            .expect("rainSlowFactor"),
    );
    let full_belly = f64_of(
        harness
            .call("rainSlowFactor", &[json!(1.0)])
            .expect("rainSlowFactor"),
    );
    let rain_ease = empty_belly > full_belly;

    checks.check("grass tufts are found", eat.found, eat.found);
    checks.check(
        "the eat menu is drawn in reach",
        obs.counters.menu_draws > 0,
        obs.counters.menu_draws,
    );
    checks.check("grass in reach shows the eat menu", eat.menu, eat.menu);
    checks.check(
        "eating consumes the nearest tuft",
        eat.ate && eat.gone,
        (eat.ate, eat.gone),
    );
    checks.check("eating turns the goat onto the grass", eat.faced, eat.faced);
    checks.check("eating restores energy", eat.energy_rose, eat.energy_rose);
    checks.check("eating fills the belly", eat.satiety_rose, eat.satiety_rose);
    checks.check(
        "a full belly eases the rain slowdown",
        rain_ease,
        (empty_belly, full_belly),
    );
    checks.check("eaten grass regrows", eat.regrew, eat.regrew);
    let eating_clip = obs.logs.iter().any(|line| line.contains("'GoatEat"));
    checks.check("the model has eating clips", eating_clip, obs.logs.len());
    checks.check("bots graze the field", bot_eats > 0, bot_eats);
    checks.check(
        "bots fill their own belly",
        obs.bot_belly_max > 0.0,
        obs.bot_belly_max,
    );
    checks.check(
        "bots walk to a tuft to eat",
        obs.bot_graze_walks > 0.0,
        obs.bot_graze_walks,
    );
    checks.check(
        "bots do not feed the player",
        bot_satiety == 0.0,
        bot_satiety,
    );
    let bot_eat_clips = obs
        .bot_clip_names
        .iter()
        .filter(|name| name.starts_with("GoatEat"))
        .count();
    checks.check(
        "bots play the eating clip",
        bot_eat_clips >= 1,
        bot_eat_clips,
    );

    // ---- settings and the tuning tree -----------------------------------
    let settings_defaults = f64_of(settings_before["bgm"].clone()) == 90.0
        && f64_of(settings_before["sfx"].clone()) == 90.0
        && settings_before["light"] == json!(true)
        && settings_before["shadow"] == json!("map")
        && settings_before["sky"] == json!(true)
        && settings_before["cloud"] == json!("medium")
        && settings_before["fullscreen"] == json!(true)
        && f64_of(settings_before["herd"].clone()) == 7.0;
    checks.check(
        "settings default to the spec",
        settings_defaults,
        settings_defaults,
    );

    // The settings reach the world, and the herd is really rebuilt.
    for line in [
        "setting light off",
        "setting shadow planar",
        "setting sky off",
        "setting herd 9",
    ] {
        harness.command(line).expect("setting");
    }
    let features = command_json(&mut harness, "features");
    let nine = command_json(&mut harness, "bots")["count"]
        .as_u64()
        .unwrap_or(0);
    harness.command("setting herd 3").expect("setting");
    let three = command_json(&mut harness, "bots")["count"]
        .as_u64()
        .unwrap_or(0);
    let mut applied = features["lighting"] == json!(false)
        && features["shadows"] == json!("planar")
        && features["sky"] == json!(false);
    harness.command("setting fullscreen off").expect("setting");
    let fullscreen_off = command_json(&mut harness, "settings")["fullscreen"] == json!(false);
    harness.command("setting fullscreen on").expect("setting");
    applied = applied && fullscreen_off;

    for line in [
        "setting light on",
        "setting shadow map",
        "setting sky on",
        "setting herd 7",
        "setting cloud low",
    ] {
        harness.command(line).expect("setting");
    }
    let cloud_low = command_json(&mut harness, "settings")["cloud"] == json!("low");
    harness.command("setting cloud high").expect("setting");
    let cloud_high = command_json(&mut harness, "features")["cloud"] == json!("high");
    harness.command("setting cloud medium").expect("setting");
    let cloud_levels = cloud_low
        && cloud_high
        && command_json(&mut harness, "settings")["cloud"] == json!("medium");

    let screen_set = harness.command("ui settings").expect("ui") == "ok ui settings"
        && harness.command("ui").expect("ui") == "ok settings";
    harness.command("ui hud").expect("ui");

    checks.check("settings apply to the world", applied, applied);
    checks.check("herd size grows the herd", nine == 9, nine);
    checks.check("herd size shrinks the herd", three == 3, three);
    checks.check("cloud quality can be set", cloud_levels, cloud_levels);
    checks.check("menu screens can be opened", screen_set, screen_set);

    // The tuning tree: reads and writes are side-effect free apart from the
    // watcher, which is unsubscribed again.
    let tuning_defaults = f64_of(tuning_get(&mut harness, "stats.max")) == 100.0
        && f64_of(tuning_get(&mut harness, "movement.turnRate")) == 1.8
        && f64_of(tuning_get(&mut harness, "weather.rainSlow")) == 0.28
        && f64_of(tuning_get(&mut harness, "lighting.shadow.half")) == 7.0;
    checks.check(
        "tuning tree carries the defaults",
        tuning_defaults,
        tuning_defaults,
    );

    // A set stores the coerced value and is visible through a get.
    let stored = f64_of(
        harness
            .call("tuningSet", &[json!("stats.jumpEnergyCost"), json!(3.5)])
            .expect("tuningSet"),
    );
    let round_trip =
        stored == 3.5 && f64_of(tuning_get(&mut harness, "stats.jumpEnergyCost")) == 3.5;
    harness
        .call("tuningSet", &[json!("stats.jumpEnergyCost"), json!(2.0)])
        .expect("tuningSet");
    checks.check("tuning set/get round-trips", round_trip, stored);

    // A bounded leaf clamps (a camera leaf, so no watcher fires).
    let clamped = f64_of(
        harness
            .call("tuningSet", &[json!("camera.minDist"), json!(0.0)])
            .expect("tuningSet"),
    );
    harness
        .call("tuningSet", &[json!("camera.minDist"), json!(2.2)])
        .expect("tuningSet");
    checks.check("tuning clamps a bounded leaf", clamped == 0.1, clamped);

    // The watcher needs a callback, which no JSON argument can carry, so it runs
    // as one snippet and comes back with what it saw.
    let seen = harness.eval(WATCH_PROBE).expect("eval");
    checks.check(
        "tuning watchers fire and unsubscribe",
        seen == json!("stats.max=120"),
        seen,
    );

    // A nested merge validates every leaf.
    harness
        .call("tuningMerge", &[json!({ "weather": { "windSlow": 0.09 } })])
        .expect("tuningMerge");
    let merged = f64_of(tuning_get(&mut harness, "weather.windSlow"));
    harness
        .call("tuningSet", &[json!("weather.windSlow"), json!(0.07)])
        .expect("tuningSet");
    checks.check("tuning merge validates every leaf", merged == 0.09, merged);

    // A typo, a branch write and a non-finite number are all loud.
    let unknown = throws(&mut harness, "tuningGet(\"stats.nope\")");
    let branch = throws(&mut harness, "tuningSet(\"stats\", 1)");
    let not_finite = throws(&mut harness, "tuningSet(\"stats.max\", NaN)");
    checks.check(
        "tuning rejects unknown, branch and non-finite writes",
        unknown && branch && not_finite,
        (unknown, branch, not_finite),
    );

    // The visual side of eating: the drawn tufts drop when one is eaten.
    let tuft = harness
        .call("nearestTuft", &[json!(0.0), json!(0.0), json!(20.0)])
        .expect("nearestTuft");
    let mut tuft_vanishes = false;
    let mut tuft_drop = 0i64;
    if !tuft.is_null() {
        let drawn = |harness: &mut Harness| -> u32 {
            harness
                .reset_counters(&["cubeDraws"])
                .expect("reset cubeDraws");
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
        let before = drawn(&mut harness);
        harness.call("consumeTuft", &[tuft]).expect("consumeTuft");
        let after = drawn(&mut harness);
        tuft_drop = i64::from(before) - i64::from(after);
        tuft_vanishes = after < before;
    }
    checks.check("eaten grass stops being drawn", tuft_vanishes, tuft_drop);

    // ---- terrain ---------------------------------------------------------
    // One grid with real normals, UVs and material colours, a surface that is not
    // flat, a level spawn bowl, and the goat and the herd drawn on it.
    let mut terrain_error: Option<String> = None;
    let spread = match harness.eval(TERRAIN_SPREAD) {
        Ok(value) => f64_of(value),
        Err(error) => {
            terrain_error = Some(error);
            f64::NAN
        }
    };
    let level = match harness.eval(SPAWN_LEVEL) {
        Ok(value) => bool_of(value),
        Err(error) => {
            terrain_error = Some(error);
            false
        }
    };
    checks.check("no terrain errors", terrain_error.is_none(), terrain_error);
    checks.check("the terrain is not flat", spread > 1.5, spread);
    checks.check("the spawn bowl stays level", level, level);

    let (mesh_ok, mesh_verts) = match obs.mesh.as_ref() {
        Some(mesh) => (
            mesh.verts == 49 * 49
                && mesh.y_spread > 0.5
                && mesh.indices == 48 * 48 * 6
                && mesh.normals == mesh.verts * 3
                && mesh.colors == mesh.verts * 4
                && mesh.texcoords == mesh.verts * 2,
            mesh.verts,
        ),
        None => (false, 0),
    };
    checks.check(
        "the terrain is one grid with normals, UVs and colours",
        mesh_ok,
        mesh_verts,
    );
    let materials = obs.mesh.as_ref().map_or(0, |mesh| mesh.materials);
    checks.check(
        "the terrain mesh carries several materials",
        materials >= 4,
        materials,
    );

    // The goat's placement is judged against the scene's live position, as the
    // Node harness did.
    let settled = command_json(&mut harness, "state");
    let goat_stands = match obs.goat_draw.as_ref() {
        Some(draw) => {
            let ground = f64_of(
                harness
                    .call(
                        "terrainHeight",
                        &[settled["x"].clone(), settled["z"].clone()],
                    )
                    .expect("terrainHeight"),
            );
            (draw.y - ground).abs() < 0.02
        }
        None => false,
    };
    checks.check(
        "the goat stands on the terrain",
        goat_stands,
        obs.goat_draw.as_ref().map(|draw| draw.y),
    );

    let mut herd_stands = !obs.bot_draw.is_empty();
    for bot in &obs.bot_draw {
        let ground = f64_of(
            harness
                .call("terrainHeight", &[json!(bot.x), json!(bot.z)])
                .expect("terrainHeight"),
        );
        if (bot.y - ground).abs() > 1e-6 {
            herd_stands = false;
        }
    }
    checks.check(
        "the herd stands on the terrain",
        herd_stands,
        obs.bot_draw.len(),
    );

    checks.finish();
}

/// The terrain's height range over the sampled field, as one expression.
///
/// The scan is a measurement, not an assertion, so it stays with the run: doing
/// it from Rust would mean two thousand crossings for the same number.
const TERRAIN_SPREAD: &str = "(function () { \
     let low = 1e9; let high = -1e9; \
     for (let x = -60; x <= 60; x += 3) { \
       for (let z = -60; z <= 60; z += 3) { \
         const h = terrainHeight(x, z); \
         if (h < low) low = h; \
         if (h > high) high = h; \
       } \
     } \
     return high - low; })()";

/// Whether the spawn bowl is level: the spawn point and a spot beside it.
const SPAWN_LEVEL: &str =
    "Math.abs(terrainHeight(0, 0)) < 1e-9 && Math.abs(terrainHeight(4, -3)) < 1e-9";

/// What the eating cases found.
#[derive(Default)]
struct Eat {
    found: bool,
    menu: bool,
    ate: bool,
    energy_rose: bool,
    satiety_rose: bool,
    faced: bool,
    gone: bool,
    regrew: bool,
}

/// The client's embedded-asset table: every `"name",` line whose next line is
/// the `include_bytes!` that loads it. `crates/goats/src/main.rs` is the only
/// place the binary's assets are listed.
fn embedded_names() -> Vec<String> {
    const MAIN: &str = include_str!("../../goats/src/main.rs");
    let mut names = Vec::new();
    let mut pending: Option<String> = None;
    for line in MAIN.lines() {
        let trimmed = line.trim();
        if trimmed.contains("include_bytes!") {
            if let Some(name) = pending.take() {
                names.push(name);
            }
            continue;
        }
        pending = quoted(trimmed);
    }
    names
}

/// The string a line is, when the line is only `"name",`.
fn quoted(line: &str) -> Option<String> {
    let inner = line
        .strip_suffix(',')?
        .trim()
        .strip_prefix('"')?
        .strip_suffix('"')?;
    if inner.contains('"') {
        return None;
    }
    Some(inner.to_string())
}

/// One tuning read, as a number.
fn tuning_get(harness: &mut Harness, path: &str) -> serde_json::Value {
    harness
        .call("tuningGet", &[json!(path)])
        .unwrap_or_else(|error| panic!("tuningGet({path}): {error}"))
}

/// Whether a snippet throws, which mirrors the `try/catch` the Node harness used
/// for the writes the tree is supposed to refuse.
fn throws(harness: &mut Harness, code: &str) -> bool {
    let probe = format!(
        "(function () {{ try {{ {code}; }} catch (error) {{ return true; }} return false; }})()"
    );
    bool_of(harness.eval(&probe).expect("eval"))
}

/// The watcher case: it subscribes, sets, unsubscribes and sets again, and comes
/// back with what the watcher saw before it was removed.
const WATCH_PROBE: &str = "(function () { \
     let saw = null; \
     const off = tuningWatch(\"stats.max\", function (path, value) { saw = path + \"=\" + value; }); \
     tuningSet(\"stats.max\", 120); \
     off(); \
     tuningSet(\"stats.max\", 100); \
     return saw; })()";

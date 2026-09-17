//! The ported scene suite: the Node harness `goat_logic_test.js`, in Rust, on
//! Slag.
//!
//! One full 4050-frame run, then the cases the Node harness asserted, reported
//! through [`Checks`] so a failure names itself and the rest still run. The
//! expected values are transcribed from that harness, never re-derived, so a
//! mismatch is a finding to investigate rather than a number to re-baseline.
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
use support::{Checks, bool_of, command_json, f64_of, net_feed, throws, try_command_json};

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
    // Read before the driven blocks below, which set off bangs of their own: this
    // is how many the scripted walk tripped on its own.
    let tripped = harness
        .call("sceneExplosions", &[])
        .ok()
        .and_then(|state| state["blasts"].as_f64())
        .unwrap_or(-1.0);
    let mut checks = Checks::new();

    eprintln!(
        "harness: {} frames in {:?} ({:.1} ms/frame), {} cubes, {tripped} blasts",
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

    // ---- the herd --------------------------------------------------------
    // `minGap` is what the bots logged, so a negative one means they collided.
    checks.check("bot goats load", obs.bot_count >= 2, obs.bot_count);
    checks.check(
        "goats never overlap",
        obs.min_gap.is_some_and(|gap| gap > -0.12),
        obs.min_gap,
    );
    checks.check(
        "bots animate their own models",
        obs.counters.bot_poses > 0,
        obs.counters.bot_poses,
    );
    checks.check(
        "bots get the zoomies (run + jump)",
        obs.counters.bot_jumps > 0,
        obs.counters.bot_jumps,
    );
    checks.check(
        "bots play several idle variants",
        obs.bot_idles.len() >= 2,
        obs.bot_idles.clone(),
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
        // A flung bot is drawn rolled, and it belongs in the air (M19c): the herd
        // trips devices of its own on a long run, so the one frame this records can
        // catch a bot mid-arc. Everything else stands exactly on the terrain.
        if bot.axis_x.abs() + bot.axis_z.abs() > 0.01 {
            continue;
        }
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

    // ---- the network bridge, chat and world sync --------------------------
    // All three are the scene end of the protocol: pure JS, driven with no socket
    // and no peer, because `sceneNetDrain` is what the host calls each frame and
    // `sceneNetEvent` is what it feeds back. Each block is one try/catch in the
    // Node harness, so a failure inside one fails that block's cases rather than
    // the whole test.
    let (net, net_error) = match net_block(&mut harness) {
        Ok(net) => (net, None),
        Err(error) => (Net::default(), Some(error)),
    };
    checks.check("no network bridge errors", net_error.is_none(), net_error);
    checks.check("nothing is queued at rest", net.rest_empty, &net);
    checks.check("host queues an intent and clears it", net.host_queued, &net);
    checks.check("events update the local view", net.view, &net);
    checks.check("events print to the console", net.printed, &net);
    checks.check("a second session is refused", net.refused, &net);
    checks.check("leave queues a close", net.left, &net);
    checks.check("disconnect resets the view", net.reset, &net);
    checks.check("connect without a ticket is an error", net.no_ticket, &net);
    checks.check("connect queues a join", net.joined, &net);
    checks.check("host without a name asks for one", net.prompt_asked, &net);
    checks.check("the prompt answer is used", net.prompt_answered, &net);
    checks.check(
        "connect --pull consents to fetching the host's mods",
        net.pull_flag,
        &net,
    );
    checks.check(
        "a flagged connect still asks for a username",
        net.pull_prompt,
        &net,
    );
    checks.check("muting tells the host to silence voice", net.muted, &net);

    let (chat, chat_error) = match chat_block(&mut harness) {
        Ok(chat) => (chat, None),
        Err(error) => (Chat::default(), Some(error)),
    };
    checks.check("no chat errors", chat_error.is_none(), chat_error);
    checks.check("bare text is chat in a session", chat.bare, &chat);
    checks.check("say is chat, spelled out", chat.say, &chat);
    checks.check("/msg becomes a leading @name", chat.msg, &chat);
    checks.check("a leading @name is chat too", chat.at, &chat);
    checks.check(
        "slash commands still reach commands",
        chat.slash_command,
        &chat,
    );
    checks.check("bare text is an error offline", chat.offline, &chat);
    checks.check("chat lines print, whispers marked", chat.printed, &chat);

    let (sync, sync_error) = match sync_block(&mut harness) {
        Ok(sync) => (sync, None),
        Err(error) => (Sync::default(), Some(error)),
    };
    checks.check("no world sync errors", sync_error.is_none(), sync_error);
    checks.check("a session seed re-keys every stream", sync.seeded, &sync);
    checks.check(
        "a different seed builds a different world",
        sync.seed_differs,
        &sync,
    );
    checks.check("a session publishes the goat pose", sync.pose, &sync);
    checks.check(
        "the pose channel is throttled per frame",
        sync.pose_throttled,
        &sync,
    );
    checks.check(
        "a peer snapshot becomes a remote goat",
        sync.peer_added,
        &sync,
    );
    checks.check("leaving removes the remote goat", sync.peer_left, &sync);
    checks.check("a host publishes its bots", sync.world, &sync);
    checks.check("a client mirrors the server bots", sync.mirror, &sync);
    checks.check(
        "a client mirrors the server weather",
        sync.weather_mirror,
        &sync,
    );
    checks.check(
        "a client adopts the server streams",
        sync.streams_mirror,
        &sync,
    );
    checks.check(
        "a client mirrors the server meadow",
        sync.eaten_mirror,
        &sync,
    );
    checks.check(
        "a client mirrors the server ground",
        sync.craters_mirror,
        &sync,
    );
    checks.check(
        "a snapshot that could not carry the ground keeps it",
        sync.craters_kept,
        &sync,
    );
    checks.check(
        "an empty crater list closes the ground",
        sync.craters_retired,
        &sync,
    );
    checks.check(
        "a mirror spends the devices the host has fired",
        sync.spent_mirror,
        &sync,
    );
    checks.check(
        "a relayed bang lands here once and is not sent back",
        sync.blast_mirror,
        &sync,
    );
    checks.check(
        "the host relays a client's bang and leaves them out",
        sync.reports_blast,
        &sync,
    );
    checks.check("a client reports its own bite", sync.reports_eat, &sync);
    checks.check(
        "a client does not simulate or publish the bots",
        sync.client_not_local && sync.client_is_not_authority,
        &sync,
    );
    checks.check(
        "offline simulates the bots and the weather locally",
        sync.world_local_offline,
        &sync,
    );

    // ---- the console -----------------------------------------------------
    // The scripted input drives it after the restart: backquote opens it at 4010,
    // "ping" is typed at 4012 and submitted at 4014, UP recalls it at 4016, ESC
    // closes at 4018 and 4020 reopens it.
    let at = |i: u32| {
        obs.probe(i)
            .unwrap_or_else(|| panic!("no console probe at frame {i}"))
    };
    checks.check(
        "the console starts closed",
        !at(4008).state.open,
        at(4008).state.open,
    );
    checks.check(
        "backquote opens the console",
        at(4011).state.open,
        at(4011).state.open,
    );
    let typed = at(4016).state.lines.clone();
    checks.check(
        "the console echoes what was typed",
        typed.iter().any(|line| line == "echo: > ping"),
        typed.clone(),
    );
    checks.check(
        "the console runs the command",
        typed.iter().any(|line| line == "local: ok pong"),
        typed.clone(),
    );
    checks.check(
        "the console keeps command history",
        at(4016).state.history.iter().any(|entry| entry == "ping"),
        at(4016).state.history.clone(),
    );
    checks.check(
        "UP recalls the last command",
        at(4016).state.input == "ping",
        at(4016).state.input.clone(),
    );
    checks.check(
        "ESC closes the console",
        !at(4018).state.open,
        at(4018).state.open,
    );
    checks.check(
        "ESC does not open the menu",
        at(4018).ui == "hud",
        at(4018).ui.clone(),
    );
    checks.check(
        "backquote reopens the console",
        at(4021).state.open,
        at(4021).state.open,
    );
    // The overlay must not freeze the world, but must gate the movement keys.
    let (moving, still) = (at(4007), at(4008));
    checks.check(
        "the goat moves while the console is closed",
        moving.x != still.x || moving.z != still.z,
        (moving.x, moving.z, still.x, still.z),
    );
    let (frozen, opened) = (at(4009), at(4011));
    checks.check(
        "the console freezes the goat",
        frozen.x == opened.x && frozen.z == opened.z,
        (frozen.x, frozen.z, opened.x, opened.z),
    );

    // ---- help formatting --------------------------------------------------
    // `help` is a page rather than one line, the console splits a multi-line reply
    // into one entry per row, and anything still too wide wraps.
    let mut help_error: Option<String> = None;
    let help = match help_block(&mut harness) {
        Ok(help) => help,
        Err(error) => {
            help_error = Some(error);
            Help::default()
        }
    };
    checks.check(
        "help is a short page grouped by topic",
        help.paged && help.grouped,
        &help,
    );
    checks.check(
        "a multi-line reply becomes one entry per row",
        help.split_lines,
        &help,
    );
    checks.check(
        "a long console line wraps inside the width",
        help.wrapped,
        &help,
    );
    checks.check(
        "a long token is hard-split without loss",
        help.hard_split,
        &help,
    );
    checks.check(
        "no help formatting errors",
        help_error.is_none(),
        help_error,
    );

    // ---- the clipboard ---------------------------------------------------
    // A ticket is too long to type, so paste has to work; `Ctrl+C` and the `copy`
    // verb are the way back out. The clipboard carries a newline, as one copied
    // from a terminal does, so the paste has to strip it.
    let pasted = at(4032).state.input.clone();
    checks.check(
        "the console pastes and strips the newline",
        pasted.ends_with("endpointABC") && !pasted.contains('\n'),
        pasted,
    );
    checks.check(
        "Ctrl+C copies the line",
        obs.clipboard_writes
            .iter()
            .any(|write| write.ends_with("endpointABC")),
        obs.clipboard_writes.clone(),
    );

    // `obs` is the state at the end of the run, and these two commands come after
    // it, so the clipboard is re-read rather than reused.
    let mut clipboard_error: Option<String> = None;
    let copy_reply = match harness.command("copy hello") {
        Ok(reply) => reply,
        Err(error) => {
            clipboard_error = Some(error);
            String::new()
        }
    };
    let wrote = match harness.observe() {
        Ok(after) => after.clipboard_writes.last().cloned().unwrap_or_default(),
        Err(error) => {
            clipboard_error = clipboard_error.or(Some(error));
            String::new()
        }
    };
    let nothing = match harness.command("copy") {
        Ok(reply) => reply,
        Err(error) => {
            clipboard_error = clipboard_error.or(Some(error));
            String::new()
        }
    };
    checks.check(
        "the copy verb writes the clipboard",
        copy_reply == "ok copy" && wrote == "hello",
        (copy_reply, wrote),
    );
    checks.check(
        "copy with nothing to copy is an error",
        nothing == "error nothing to copy",
        nothing,
    );
    checks.check(
        "no clipboard errors",
        clipboard_error.is_none(),
        clipboard_error,
    );

    // The one-shot gait cases drive frames of their own, past the scripted run,
    // and a jump is the goat's own from the reset frame.
    let (gaits, gait_error) = match gait_block(&mut harness) {
        Ok(gaits) => (gaits, None),
        Err(error) => (Gaits::default(), Some(error)),
    };
    checks.check("no one-shot gait errors", gait_error.is_none(), gait_error);
    checks.check(
        "a jump publishes the fraction through the clip",
        gaits.jump_fraction,
        &gaits,
    );
    checks.check(
        "a peer's one-shot snapshot is stepped, not eased",
        gaits.peer_shot_snapped,
        &gaits,
    );
    checks.check(
        "a peer resumes the loop where the snapshot put it",
        gaits.peer_loop_resent,
        &gaits,
    );

    // ---- explosions --------------------------------------------------------
    // The devices are derived rather than placed, so the cases are about the
    // derivation agreeing with itself and about a goat that walks onto one. The
    // block drives the real frame loop in bursts, which is what a fuse, a landing
    // and a chain need.
    let (fx, fx_error) = match explosions_block(&mut harness) {
        Ok(fx) => (fx, None),
        Err(error) => (Explosions::default(), Some(error)),
    };
    checks.check("no explosion errors", fx_error.is_none(), fx_error);
    checks.check(
        "the field is derived, not stored",
        fx.same_field && fx.empty,
        (fx.same_field, fx.empty),
    );
    checks.check(
        "no device is derived inside `safe`",
        fx.safe_clear,
        fx.safe_clear,
    );
    checks.check("a tripped mine waits for its fuse", fx.fuse, fx.fuse);
    checks.check(
        "the bang damages the goat and spends the device",
        fx.damaged && fx.spent,
        (fx.damaged, fx.spent),
    );
    checks.check(
        "a blast cannot take health below the floor",
        fx.floor,
        fx.floor,
    );
    checks.check(
        "a hop clears a mine and the landing sets it off",
        fx.clearance,
        fx.clearance,
    );
    checks.check("a goat that runs onto a mine trips it", fx.walk, fx.walk);
    checks.check(
        "a trapped tuft replaces the meal",
        fx.trap_meal,
        fx.trap_meal,
    );
    checks.check(
        "a blast sets off the neighbour it reaches, one level deep",
        fx.chain,
        fx.chain,
    );
    checks.check("the bang leaves an effect behind", fx.effect, fx.effect);
    checks.check(
        "a blast throws the goat away from it, and it lands",
        fx.flung,
        fx.flung,
    );
    checks.check(
        "the goat is not in charge while it flies",
        fx.flung_lock,
        fx.flung_lock,
    );
    checks.check(
        "a flung goat rolls, unless the clip is doing the rolling",
        fx.flung_tumble,
        fx.flung_tumble,
    );
    checks.check(
        "a blast throws the herd, and a bot walks away",
        fx.herd_flung,
        fx.herd_flung,
    );
    checks.check(
        "a device that goes off leaves its cell and lands elsewhere",
        fx.relocated,
        fx.relocated,
    );
    checks.check(
        "a bang dishes the ground, and it heals back with the grass",
        fx.craters,
        fx.craters,
    );
    checks.check(
        "a blast hurts a bot as much as it hurts the goat",
        fx.bot_hurt,
        fx.bot_hurt,
    );
    checks.check(
        "a lethal blast kills a bot, and the world snapshot says so",
        fx.bot_death,
        fx.bot_death,
    );
    checks.check(
        "a bot killed in the air lands, still dead",
        fx.bot_lands,
        fx.bot_lands,
    );
    checks.check(
        "a dead bot gets up again, somewhere else",
        fx.bot_respawn,
        fx.bot_respawn,
    );
    checks.check(
        "the flung gait reads as the flung clip, or the jump without one",
        fx.flung_clip,
        fx.flung_clip,
    );
    checks.check(
        "a restart mid-arc clears the fling",
        fx.flung_restart,
        fx.flung_restart,
    );
    checks.check("every bang is heard, once", fx.blast_sound, fx.blast_sound);
    checks.check(
        "the grit a bang throws comes down after it",
        fx.blast_debris,
        fx.blast_debris,
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
/// Whether the spawn's safe radius is clear: no mine in any cell whose centre is
/// inside it. A mine there would end a run at the spawn, which is the one place a
/// restart has to be survivable.
const SAFE_PROBE: &str = "(function () { \
     let found = 0; \
     const safe = TUNING.explosions.safe; \
     const r = Math.ceil(safe / 2) + 1; \
     for (let cx = -r; cx <= r; cx++) { \
       for (let cz = -r; cz <= r; cz++) { \
         const x = cx * 2 + 1; \
         const z = cz * 2 + 1; \
         if (x * x + z * z > safe * safe) continue; \
         if (mineAt(cx, cz)) found += 1; \
       } \
     } \
     return found; })()";

/// What the explosion cases found. One field per case.
#[derive(Debug, Default)]
struct Explosions {
    same_field: bool,
    empty: bool,
    safe_clear: bool,
    fuse: bool,
    damaged: bool,
    spent: bool,
    floor: bool,
    clearance: bool,
    trap_meal: bool,
    chain: bool,
    effect: bool,
    walk: bool,
    flung: bool,
    flung_lock: bool,
    flung_tumble: bool,
    herd_flung: bool,
    relocated: bool,
    craters: bool,
    bot_hurt: bool,
    bot_death: bool,
    bot_lands: bool,
    bot_respawn: bool,
    flung_clip: bool,
    flung_restart: bool,
    blast_sound: bool,
    blast_debris: bool,
}

/// The device state the scene reports: pending fuses, spent devices, blasts so
/// far and live effect instances.
fn explosion_state(harness: &mut Harness) -> Result<(f64, f64, f64, f64), String> {
    let state = harness.call("sceneExplosions", &[])?;
    Ok((
        f64_of(state["pending"].clone()),
        f64_of(state["spent"].clone()),
        f64_of(state["blasts"].clone()),
        f64_of(state["live"].clone()),
    ))
}

/// Drives one burst of the real frame loop. The stub's scripted input replays
/// from wherever the frame counter is reset to, and its first key is at frame 10,
/// so a burst of nine frames or fewer carries none of it -- which is what keeps a
/// case from being walked off its own device.
fn drive_burst(harness: &mut Harness, frames: u32) -> Result<bool, String> {
    harness.reset_frame()?;
    for _ in 0..frames {
        if !bool_of(harness.call("sceneFrame", &[])?) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Drive until the goat is in charge of itself again. Every case here teleports
/// with `pos`, and the modes that own the goat's position -- a meal, a jump, and now
/// a blast's arc (M19c) -- would carry it on from wherever it was instead, so the
/// wait is what makes a teleport stick.
fn wait_mobile(harness: &mut Harness) -> Result<(), String> {
    let mut waited = 0;
    while waited < 48
        && bool_of(harness.eval("mode === \"eat\" || mode === \"jump\" || mode === \"flung\"")?)
    {
        drive_burst(harness, 9)?;
        waited += 1;
    }
    Ok(())
}

/// The mines the `traps` verb reports around the goat, armed ones included.
fn explosion_mines(harness: &mut Harness, range: f64) -> Result<Vec<serde_json::Value>, String> {
    let field = try_command_json(harness, &format!("traps {range}"))?;
    Ok(field["mines"].as_array().cloned().unwrap_or_default())
}

/// The cells a replacement has moved into, as `(cx, cz)`, for the set named (the
/// scene keeps one per kind: `MOVED` for mines, `TRAP_MOVED` for trapped tufts).
fn moved_cells(harness: &mut Harness, set: &str) -> Result<Vec<(f64, f64)>, String> {
    let probe = harness.eval(&format!(
        "(function () {{ const out = []; \
         for (const key of {set}) {{\
           out.push([Math.floor(key / 8192) - 4096, (key % 8192) - 4096]); \
         }} \
         return out; }})()"
    ))?;
    Ok(probe
        .as_array()
        .map(|rows| {
            rows.iter()
                .map(|row| (f64_of(row[0].clone()), f64_of(row[1].clone())))
                .collect()
        })
        .unwrap_or_default())
}

/// Whether the cell `(cx, cz)` holds a mine right now, by the scene's own test.
fn mine_armed(harness: &mut Harness, cx: f64, cz: f64) -> Result<bool, String> {
    let value = harness.eval(&format!("mineArmed({cx}, {cz})"))?;
    Ok(value.as_bool().unwrap_or(false))
}

/// How far west of the target the walking case starts its run. Nine metres at a
/// run is a little over three seconds: a real approach, and short enough that the
/// goat is still moving forward when the fuse lands.
const APPROACH: f64 = 9.0;

/// Bursts of nine frames the approach is allowed. The run is about 185 frames and
/// the fuse is eleven more, so this is slack rather than a target.
const APPROACH_BURSTS: u32 = 32;

/// The live effect instances' positions, as `[x, z]` pairs. The pool stores the
/// trigger's own coordinates, so a match is the bang that landed *there* rather
/// than one that happened nearby.
const EFFECT_SPOTS: &str = "(function () { \
     const out = []; \
     for (let i = 0; i < FX_CAPACITY; i++) { \
       if (FX[i].live) out.push([FX[i].x, FX[i].z]); \
     } \
     return out; })()";

/// How far the first bot is from the player, in metres. A respawn puts it out on the
/// ring `botRespawn` draws (10 to 26 m), so this is what says "somewhere else" rather
/// than "back where it fell".
const BOT_DISTANCE: &str = "(function () { \
     const dx = BOTS[0].x - goat.px; \
     const dz = BOTS[0].z - goat.pz; \
     return Math.sqrt(dx * dx + dz * dz); })()";

/// The mine with a clear run-up `APPROACH` metres west of it, as
/// `(target x, target z, start x)`: neither the start point nor the corridor
/// between the two holds another device, so whatever the goat trips on its way in
/// can only be the target. `None` when the field has no such mine.
fn approach_target(mines: &[serde_json::Value]) -> Option<(f64, f64, f64)> {
    mines.iter().find_map(|mine| {
        let tx = f64_of(mine["x"].clone());
        let tz = f64_of(mine["z"].clone());
        let sx = tx - APPROACH;
        let clear = mines.iter().all(|other| {
            let dx = f64_of(other["x"].clone()) - sx;
            let dz = f64_of(other["z"].clone()) - tz;
            // Anything the goat can reach before the target: level with the run-up
            // (it holds its z, so a device more than a body's width off the line
            // is never tripped) and west of the target. A device east of the
            // target is left alone -- the target's bang still lands first.
            dz.abs() > 2.0 || dx >= APPROACH
        });
        clear.then_some((tx, tz, sx))
    })
}

/// Whether a bang in the effect pool is sitting on (x, z).
fn bang_at(harness: &mut Harness, x: f64, z: f64) -> Result<bool, String> {
    let spots = harness.eval(EFFECT_SPOTS)?;
    Ok(spots.as_array().is_some_and(|list| {
        list.iter().any(|spot| {
            (f64_of(spot[0].clone()) - x).abs() < 0.01 && (f64_of(spot[1].clone()) - z).abs() < 0.01
        })
    }))
}

/// Walks the goat onto the mines it derives, hops over one, eats a trapped tuft,
/// and watches a chain.
fn explosions_block(harness: &mut Harness) -> Result<Explosions, String> {
    let mut out = Explosions::default();
    // Alive, idle and at the spawn, with the scripted timeline's held keys
    // released: it holds W from frame 200 on, so a burst would otherwise walk the
    // goat off the device between the two frames a case needs.
    harness.command("restart")?;
    harness.command("stop")?;
    harness.command("turn stop")?;
    // The console is an overlay and `ctlKeyDown` refuses input while it is open, so
    // the run's console cases leave a goat whose gait is held standing perfectly
    // still. Every case here used to set its position with `pos`, which never
    // noticed; the walking case below is the first that has to be *driven*.
    harness.command("console close")?;

    let field = try_command_json(harness, "traps 40")?;
    out.same_field = field == try_command_json(harness, "traps 40")?;
    let mines = field["mines"].as_array().cloned().unwrap_or_default();
    out.empty = !mines.is_empty();
    out.safe_clear = f64_of(harness.eval(SAFE_PROBE)?) == 0.0;

    let Some(on) = mines.first() else {
        return Ok(out);
    };
    let Some(next) = mines.get(1) else {
        return Ok(out);
    };
    let (mx, mz) = (f64_of(on["x"].clone()), f64_of(on["z"].clone()));
    let (nx, nz) = (f64_of(next["x"].clone()), f64_of(next["z"].clone()));
    let health = |harness: &mut Harness| -> Result<f64, String> {
        Ok(f64_of(harness.eval("stats.health")?))
    };

    // Standing on an armed mine: the first burst trips it, the fuse burns with
    // the health untouched, and the bang lands after it.
    harness.command("heal")?;
    harness.command(&format!("pos {mx} {mz}"))?;
    let before = health(harness)?;
    let (_, spent_before, blasts_before, _) = explosion_state(harness)?;
    let running = drive_burst(harness, 6)?;
    let (pending, spent, blasts, _) = explosion_state(harness)?;
    out.fuse = running
        && pending == 1.0
        && spent > spent_before
        && blasts == blasts_before
        && health(harness)? == before;
    drive_burst(harness, 9)?;
    let (pending, _, blasts, live) = explosion_state(harness)?;
    out.damaged = pending == 0.0 && blasts > blasts_before && health(harness)? < before;
    out.spent = explosion_state(harness)?.1 > spent_before;
    out.effect = live > 0.0;

    // The hop: airborne, the mine is not under the goat's feet, and the landing
    // puts it back. `clearance` (and the jump itself) is what makes that a rule
    // rather than a race.
    harness.command("heal")?;
    harness.command(&format!("pos {nx} {nz}"))?;
    let (_, spent_mark, blasts_mark, _) = explosion_state(harness)?;
    harness.command("jump")?;
    drive_burst(harness, 4)?;
    let jumped = explosion_state(harness)?;
    let airborne = jumped.0 == 0.0 && jumped.1 == spent_mark && jumped.2 == blasts_mark;
    // The jump clip is a little over a second and which variant it picks is the
    // scene's business, so this drives until the hooves are down rather than for a
    // frame count -- then past the landing, so the fuse it starts has burned.
    let mut guarded = 0;
    while bool_of(harness.eval("mode === \"jump\"")?) && guarded < 24 {
        drive_burst(harness, 9)?;
        guarded += 1;
    }
    let landed_on_ground = !bool_of(harness.eval("mode === \"jump\"")?);
    drive_burst(harness, 9)?;
    drive_burst(harness, 6)?;
    let landed = explosion_state(harness)?;
    out.clearance = airborne && landed_on_ground && landed.2 == blasts_mark + 1.0;

    // A trapped tuft replaces the meal. `trap.chance 1` makes every tuft a trap,
    // so the case does not depend on where the default 4% fell.
    harness.eval("goats.tuning.set(\"explosions.trap.chance\", 1)")?;
    harness.command("heal")?;
    let tuft = try_command_json(harness, "grass 40")?;
    if !tuft.is_null() {
        let (tx, tz) = (f64_of(tuft["x"].clone()), f64_of(tuft["z"].clone()));
        harness.command(&format!("pos {tx} {tz}"))?;
        let energy = f64_of(harness.eval("stats.energy")?);
        let belly = f64_of(harness.eval("satiety")?);
        let (_, _, blasts, _) = explosion_state(harness)?;
        let eaten = harness.command("eat")?;
        // The fuse is what makes this observable: the meal is judged before the
        // bang lands.
        out.trap_meal = eaten == "ok eat"
            && f64_of(harness.eval("stats.energy")?) == energy
            && f64_of(harness.eval("satiety")?) == belly;
        drive_burst(harness, 9)?;
        drive_burst(harness, 6)?;
        let after = explosion_state(harness)?;
        out.trap_meal &= after.2 > blasts;
    }
    harness.eval("goats.tuning.set(\"explosions.trap.chance\", 0.04)")?;

    // The floor: absurd damage cannot kill through a blast. The wait is for the arc
    // the *previous* bang started: a flung goat flies on from wherever it was, so a
    // teleport taken mid-arc would not stick.
    wait_mobile(harness)?;
    harness.eval("goats.tuning.set(\"explosions.blast.damage\", 1000)")?;
    harness.command("heal")?;
    harness.command(&format!("pos {mx} {mz}"))?;
    harness.eval("sceneResetDevices()")?;
    drive_burst(harness, 9)?;
    drive_burst(harness, 9)?;
    let floored = health(harness)?;
    out.floor = floored == 1.0;
    harness.eval("goats.tuning.set(\"explosions.blast.damage\", 45)")?;

    // The chain: a dense field, and a mine whose neighbour is also one. One level
    // deep means the first blast sets off exactly the armed devices it reaches.
    wait_mobile(harness)?;
    harness.eval("goats.tuning.set(\"explosions.mine.density\", 0.5)")?;
    harness.command("heal")?;
    harness.command("pos 0 0")?;
    harness.eval("sceneResetDevices()")?;
    let dense = explosion_mines(harness, 40.0)?;
    let radius = f64_of(harness.eval("TUNING.explosions.blast.radius")?);
    let mut chain_case: Option<(f64, f64, usize)> = None;
    for mine in &dense {
        let (x, z) = (f64_of(mine["x"].clone()), f64_of(mine["z"].clone()));
        let neighbours = dense
            .iter()
            .filter(|other| {
                let dx = f64_of(other["x"].clone()) - x;
                let dz = f64_of(other["z"].clone()) - z;
                let d2 = dx * dx + dz * dz;
                d2 > 0.0 && d2 <= radius * radius
            })
            .count();
        if neighbours > 0 {
            chain_case = Some((x, z, neighbours));
            break;
        }
    }
    if let Some((x, z, neighbours)) = chain_case {
        let (_, _, blasts, _) = explosion_state(harness)?;
        harness.command(&format!("pos {x} {z}"))?;
        // The fuse, the chain's own delay, and the neighbours' fuses: three
        // bursts of nine frames is 0.45 s, and the two fuses are 0.33 s.
        for _ in 0..3 {
            drive_burst(harness, 9)?;
        }
        let after = explosion_state(harness)?;
        out.chain = after.2 == blasts + 1.0 + neighbours as f64;
    }
    harness.eval("goats.tuning.set(\"explosions.mine.density\", 0.012)")?;

    // The real approach: the goat runs at a mine from nine metres out and trips it
    // on the way in. Every case above teleports with `pos`, which trips a device
    // only because the trip stamp notices the position changed -- this is the
    // trigger met the way a player meets it, on foot, with the gait held down. Energy is
    // topped up every burst on purpose: an exhausted goat is capped at a walk
    // (`goat.js`), so an unfed one slows to 0.87 m/s and covers less ground than
    // the approach needs.
    harness.command("stop")?;
    harness.eval("sceneResetDevices()")?;
    // Let any fuse still burning from the chain land, then wait for the goat to be
    // free before taking a baseline: the trap case starts a two-and-a-half-second
    // eating clip, a goat mid-meal stays exactly where it is (`goat.js`), and one
    // mid-arc flies on -- so an approach started now would spend most of its budget
    // somewhere else. Waiting here also swallows any bang that lands while it waits.
    drive_burst(harness, 9)?;
    wait_mobile(harness)?;
    harness.command("heal")?;
    let trigger = f64_of(harness.eval("TUNING.explosions.mine.trigger")?);
    // No trapped tufts on the run-up, and the goat's row put back afterwards. The
    // tufts are the trap case's business above; here they would only be a 4% chance
    // of being thrown off the line by something that is not the mine being tested.
    harness.eval("goats.tuning.set(\"explosions.trap.chance\", 0)")?;
    if let Some((tx, tz, sx)) = approach_target(&mines) {
        harness.command(&format!("pos {sx} {tz}"))?;
        harness.command("yaw 0")?;
        harness.command("run")?;
        let mut at_target = false;
        let mut px_end = sx;
        // A frame at a time rather than in bursts: the goat is thrown the moment the
        // bang lands (M19c), so a burst would sample its position after it had
        // already been flung backwards. `px_end` is its last position on foot.
        //
        // The wait is for the *target's* bang and not for the blast counter to move,
        // because the herd walks the same field: `checkTriggers` covers the bots too,
        // so a bot that steps on a device ten metres away would otherwise end the
        // approach early and read as the goat's failure. This case is about the goat
        // arriving, so it watches the goat's own mine.
        harness.reset_frame()?;
        for _ in 0..(APPROACH_BURSTS * 9) {
            px_end = f64_of(harness.eval("goat.px")?);
            harness.command("energy 100")?;
            if !bool_of(harness.call("sceneFrame", &[])?) {
                break;
            }
            if bang_at(harness, tx, tz)? {
                at_target = true;
                break;
            }
        }
        // Two things make this the walking case rather than another teleport: the
        // goat is past the trigger ring because the held gait carried it there,
        // and the bang in the pool is the *target's* coordinates.
        out.walk = at_target && px_end >= tx - trigger;
        // This case is the only one that depends on the *input* state rather than
        // on the device state, and four different overlays can silently freeze a
        // driven goat, so a failure says which part of it failed.
        if !out.walk {
            eprintln!(
                "walk case: at_target={at_target} walked {} of {} (target {tx}), \
                 mode={:?} uiScreen={:?} consoleOpen={:?}, effects={:?}",
                px_end - sx,
                APPROACH,
                harness.eval("mode")?,
                harness.eval("uiScreen")?,
                harness.eval("consoleOpen")?,
                harness.eval(EFFECT_SPOTS)?,
            );
        }
        harness.command("stop")?;
    }
    harness.eval("goats.tuning.set(\"explosions.trap.chance\", 0.04)")?;

    // ---- M19b revised: a device that has gone off moves house ------------------
    //
    // A spent device is not put back where it was: it is gone from its cell for the
    // session, and one replacement is placed on a ring away from that cell, drawn from
    // the cell's own key -- so the field drifts rather than thinning out, and every
    // peer computes the same move without a word on the wire (*The wire* in
    // ROADMAP.md). Driven through `checkTriggers` at the device's own coordinates
    // rather than by walking the goat in: this case is about the move, not the walk.
    harness.command("heal")?;
    harness.command("pos 0 0")?;
    harness.eval("goats.tuning.set(\"explosions.mine.density\", 0.012)")?;
    harness.eval("goats.tuning.set(\"explosions.trap.chance\", 0.04)")?;
    harness.eval("sceneResetDevices()")?;
    let lo = f64_of(harness.eval("TUNING.explosions.relocate.min")?);
    let hi = f64_of(harness.eval("TUNING.explosions.relocate.max")?);
    let (_, spent0, blast0, _) = explosion_state(harness)?;
    let mine_moved = if let Some(mine) = explosion_mines(harness, 40.0)?.first() {
        let mx = f64_of(mine["x"].clone());
        let mz = f64_of(mine["z"].clone());
        let (fcx, fcz) = ((mx / 2.0).floor(), (mz / 2.0).floor());
        let armed_before = mine_armed(harness, fcx, fcz)?;
        // The trip stamp is per unit and the cases above left the goat with one, so it
        // is cleared to make this the goat's own arrival rather than a repeat.
        harness.eval("goat.trip = -1")?;
        harness.eval(&format!("checkTriggers(goat, {mx}, {mz}, false)"))?;
        let gone = !mine_armed(harness, fcx, fcz)?;
        let arrived = moved_cells(harness, "MOVED")?;
        let spent1 = explosion_state(harness)?.1;
        // One left, one arrived, and the ring it arrived on is the tuning's -- a cell
        // either way, since a ring in metres lands wherever it lands in the grid.
        let ringed = arrived.len() == 1 && {
            let dx = arrived[0].0 - fcx;
            let dz = arrived[0].1 - fcz;
            let metres = (dx * dx + dz * dz).sqrt() * 2.0;
            (dx != 0.0 || dz != 0.0) && metres >= lo - 1.5 && metres <= hi + 1.5
        };
        let armed_there = match arrived.first() {
            Some((cx, cz)) => mine_armed(harness, *cx, *cz)?,
            None => false,
        };
        // ...and the fuse still lands: the device left the world, and the bang it owed
        // still arrives. Only the blast count is asserted afterwards -- the herd is
        // walking the same field while these frames run.
        for _ in 0..3 {
            drive_burst(harness, 9)?;
        }
        let banged = explosion_state(harness)?.2 == blast0 + 1.0;
        armed_before && gone && spent1 == spent0 + 1.0 && ringed && armed_there && banged
    } else {
        false
    };
    // The trap half, on the same rule plus one: a trap has to land on a tuft, because a
    // trap without a tuft is not a device.
    let traps = try_command_json(harness, "traps 40")?["traps"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let trap_moved = if let Some(trap) = traps.first() {
        let tx = f64_of(trap["x"].clone());
        let tz = f64_of(trap["z"].clone());
        let (tcx, tcz) = ((tx / 2.0).floor(), (tz / 2.0).floor());
        harness.eval("goat.trip = -1")?;
        harness.eval(&format!("checkTriggers(goat, {tx}, {tz}, false)"))?;
        let gone = !bool_of(harness.eval(&format!("trapAt({tcx}, {tcz})"))?);
        let arrived = moved_cells(harness, "TRAP_MOVED")?;
        let mut on_a_tuft = arrived.len() == 1;
        for (cx, cz) in &arrived {
            // The scene's own derivation, rather than a search from the cell's *centre*:
            // a tuft is anchored at the cell's even corner, so a query from the wrong
            // point reports no tuft on a cell that has one.
            if !bool_of(harness.eval(&format!("tuftInCell({cx}, {cz}) !== null"))?) {
                on_a_tuft = false;
            }
        }
        gone && on_a_tuft
    } else {
        false
    };
    out.relocated = mine_moved && trap_moved;
    if !out.relocated {
        eprintln!(
            "relocation case: mine_moved={mine_moved} trap_moved={trap_moved} \
             lo={lo} hi={hi} moved={} trapped={}",
            harness.eval("MOVED.size")?,
            harness.eval("TRAP_MOVED.size")?,
        );
    }
    harness.command("heal")?;
    harness.command("pos 0 0")?;
    harness.eval("sceneResetDevices()")?;

    // ---- M19c: the blast throws the goat --------------------------------------
    //
    // The bang owns the impulse and the goat owns the flight, and the part a player
    // feels is the input lock: for about a second the goat is not in charge.
    //
    // The clip contract has two flight paths and this drives both, one pass each,
    // because the harness can reach both: its stub model is the real clip list minus
    // `GoatFlung`, so `CLIP.flung` is what picks the path, with the jump action
    // standing in for the clip M19f has yet to land.
    //
    //   * with the clip -- the real path -- the tumble is the clip's own, so the goat
    //     is drawn at its plain yaw and the arc is all the motion there is;
    //   * without it -- the placeholder, and what ships today -- the scene rolls the
    //     goat itself (`flingDraw`), because the jump action has no tumble in it.
    //
    // The flight itself is the same arc either way, ground contact and all: the
    // placeholder clip's hop is 0.4 m and starts and ends at rest, so it cannot be
    // what carries a goat thrown twelve metres -- which is the bug the second pass
    // is here to keep caught.
    out.flung = true;
    out.flung_lock = true;
    out.flung_tumble = true;
    out.blast_debris = true;
    for placeholder in [false, true] {
        let label = if placeholder {
            "the placeholder"
        } else {
            "the real clip"
        };
        harness.command("stop")?;
        harness.command("heal")?;
        // Two bursts before anything is measured, so a fuse the last flight set off
        // on landing has already landed. Nine frames each, which is under the ten the
        // scripted timeline needs before it feeds its first key, so neither move the
        // goat.
        drive_burst(harness, 9)?;
        drive_burst(harness, 9)?;
        harness.eval("sceneResetDevices()")?;
        // ...and the ground with them. Craters *stack* where a device keeps being tripped,
        // and this case's own mine is the one the cases above it have already set off:
        // a take-off from the bottom of a stacked pit makes `py` -- the height above the
        // ground directly below -- read short, which is nothing to do with whether the
        // arc is what lifts the goat. This case is about the arc.
        harness.eval("sceneResetCraters()")?;
        wait_mobile(harness)?;
        harness.eval(if placeholder {
            "CLIP.flung = null"
        } else {
            "CLIP.flung = CLIP.jump"
        })?;
        // Half a metre to the +x side of the device: inside the trigger, and far
        // enough off centre that "away from the blast" has a direction to check.
        harness.command(&format!("pos {} {mz}", mx + 0.5))?;
        // Facing -z (yaw 90): the gait the player holds runs across the blast's own
        // axis, which is what lets a leaked gait tell itself apart from the push.
        harness.command("yaw 90")?;
        harness.command("wake")?;
        harness.command("run")?;
        harness.command("energy 100")?;
        drive_burst(harness, 9)?; // the fuse burns
        let vdrop = f64_of(harness.eval("V_DROP")?);
        let x0 = f64_of(harness.eval("goat.px")?);
        // Frame by frame until the bang, then a few frames of arc. The frames before
        // the bang are the goat still running on the held gait, so they are not the
        // lock's business; only the arc's own frames say whether it held. The wait is
        // for the *goat's* fling rather than for the blast counter to move, for the
        // reason the walk case above spells out -- the herd trips devices of its own.
        // `mode` is set in the frame the bang lands in, before the state machine runs,
        // so none of the arc is missed.
        harness.reset_frame()?;
        let mut fired = false;
        for _ in 0..24 {
            if !bool_of(harness.call("sceneFrame", &[])?) {
                break;
            }
            if bool_of(harness.eval("mode === \"flung\"")?) {
                fired = true;
                break;
            }
        }
        // The grit, at the bang: *queued* for later and not played with the bang,
        // which is the whole sound -- hearing the load land is what says the smoke
        // is a hole in the ground rather than a puff over it. The queue is only
        // read here; whether it drained is the end of the block's business.
        out.blast_debris &= f64_of(harness.eval("DEBRIS_QUEUE.length")?) > 0.0;
        let x_at_bang = f64_of(harness.eval("goat.px")?);
        // The lock, sampled *every* frame of the arc rather than once at the end of
        // it, because a gait that leaked through would put the goat back in "run" on
        // the very next frame (the state machine's `else` branch) and keep it there.
        let mut held = fired;
        for _ in 0..6 {
            if !bool_of(harness.call("sceneFrame", &[])?) {
                break;
            }
            held &= bool_of(harness.eval("mode === \"flung\"")?);
        }
        let flying = bool_of(harness.eval("mode === \"flung\"")?);
        // The axis says the same thing a second way: the held gait is a `run` at yaw
        // 90, which moves the goat in -z and never in x, so any +x at all is the
        // blast's push, away from the device it was standing beside. Its z is not a
        // witness -- the goat had already run into -z, so away from the blast is -z
        // too, and the arc's push there swamps anything a leaked gait would add.
        let pushed = f64_of(harness.eval("goat.px")?) - x_at_bang;
        // Off the ground, and *well* off it: six frames in, a metre is what says this
        // is a throw rather than the hop the placeholder clip does on its own. That
        // hop is the bug this check exists for -- the arc leaning on it left a
        // twelve-metre blast tumbling along the ground with the goat's belly on the
        // grass. `GoatFlung` will have no root motion at all, and the arc has to be
        // what lifts the goat either way.
        let py = f64_of(harness.eval("goat.py")?);
        let carries = py > 1.0;
        let locked = fired && flying && held && pushed > 0.05 && carries;
        if !locked {
            eprintln!(
                "flung lock case ({label}): fired={fired} flying={flying} held={held} \
                 pushed={pushed} py={py} mode={:?} energy={} blasts={}",
                harness.eval("mode")?,
                harness.eval("stats.energy")?,
                explosion_state(harness)?.2,
            );
        }
        out.flung_lock &= locked;
        // The roll, sampled mid-arc from the only place it is visible from outside:
        // the axis and angle the goat was drawn with. The placeholder has no clip of
        // its own, so the scene turns the goat itself and the axis is not the plain
        // +Y the yaw alone would be; with the clip the yaw is all there is, because
        // the clip *is* the tumble and rolling on top of it would double the motion.
        let draw = harness.observe()?.goat_draw;
        let tilted = draw.as_ref().is_some_and(|d| {
            d.axis_x.abs() > 0.01 || d.axis_z.abs() > 0.01 || (d.axis_y - 1.0).abs() > 0.01
        });
        let tumble_ok = if placeholder { tilted } else { !tilted };
        if !tumble_ok {
            eprintln!("flung tumble case ({label}): tilted={tilted} draw={draw:?}",);
        }
        out.flung_tumble &= tumble_ok;
        // Fly it out, keeping the input held the whole way.
        let mut guard = 0;
        while bool_of(harness.eval("mode === \"flung\"")?) && guard < 40 {
            harness.command("energy 100")?;
            drive_burst(harness, 9)?;
            guard += 1;
        }
        let landed = !bool_of(harness.eval("mode === \"flung\"")?);
        let down = f64_of(harness.eval("goat.py")?);
        let x1 = f64_of(harness.eval("goat.px")?);
        // Away from the device and back down: the travel is the blast's (+x is the
        // impulse, since a held run at yaw 90 only moves -z), it is off the ground
        // while it flies, and whatever ended it put it back on the ground.
        let flew = flying && landed && x1 - x0 > 0.5 && (down - vdrop).abs() < 0.15;
        if !flew {
            eprintln!(
                "flung flight case ({label}): flying={flying} landed={landed} \
                 travelled={} down={down} vdrop={vdrop} mode={:?}",
                x1 - x0,
                harness.eval("mode")?,
            );
        }
        out.flung &= flew;
        harness.command("stop")?;
    }
    harness.eval("CLIP.flung = null")?;

    // And the roll's algebra, from a phase chosen rather than from wherever the arc
    // happened to be sampled. Half a turn has to be a half turn about the goat's own
    // *cross* axis -- the model's local +Z, not its forward +X, which would be a
    // barrel roll, and not +Y, which would be a spin. Turned by the yaw the axis
    // moves with it but stays horizontal, and the half turn is still a half turn,
    // which is what keeps the tip following the heading rather than the world.
    //
    // The last number is that rotation about the body's centre, which is what the
    // pivot correction is for: upside down, the origin the model is placed by ends up
    // two pivots above where it started, with the middle of the goat where it was.
    let roll = harness.eval(
        "(function () { \
           const a = flingDraw(0, 0, 0, 0, Math.PI, 0.5); \
           const out = { \
             ax: a.ax, ay: a.ay, az: a.az, deg: a.deg, y: 0, yawed: 0 \
           }; \
           out.y = flingDraw(0, 4, 0, 0, Math.PI, 0.5).y; \
           out.yawed = flingDraw(0, 0, 0, Math.PI / 2, Math.PI, 0.5).ay; \
           return out; \
         })()",
    )?;
    let flat = |key: &str| f64_of(roll[key].clone()).abs() < 1e-9;
    let centred = flat("ax")
        && flat("ay")
        && (f64_of(roll["az"].clone()) - 1.0).abs() < 1e-9
        && (f64_of(roll["deg"].clone()) - 180.0).abs() < 1e-6
        && (f64_of(roll["y"].clone()) - 5.0).abs() < 1e-9
        && flat("yawed");
    if !centred {
        eprintln!("flung roll case: roll={roll:?}");
    }
    out.flung_tumble &= centred;

    // ---- M19c: the herd is thrown too -----------------------------------------
    //
    // A survivable bang's whole reaction on a bot is the arc: it goes up, comes down,
    // and walks on (M19c2, below, is the one that kills it). Driven through `blast()`
    // itself rather than by luring a bot onto a mine -- the herd wanders on its own
    // PRNG, and what is under test is the reaction, not the walking. The bang is placed
    // on the bot, so the falloff is 1 and the throw is the full one.
    if f64_of(harness.eval("BOTS.length")?) > 0.0 {
        harness.eval("blast(\"mine\", BOTS[0].x, BOTS[0].z, 0.25, 0)")?;
        let caught = bool_of(harness.eval("BOTS[0].mode === \"flung\"")?);
        drive_burst(harness, 6)?;
        let up = f64_of(harness.eval("BOTS[0].py")?);
        // The row a client is sent, while it flies: the gait, and the fraction
        // through the arc (which is what a viewer poses and rolls from).
        let row = harness.call("sceneWorldBots", &[])?;
        let broadcast = row[0]["gait"] == json!("flung")
            && f64_of(row[0]["phase"].clone()) > 0.0
            && f64_of(row[0]["phase"].clone()) < 1.0;
        // ...and the drawn bot is off the ground and rolled, which is the half the
        // *draw* owns: `py` above the terrain, on an axis that is not the plain +Y.
        // Found by its own model handle -- the herd is resized on the scripted
        // timeline, and `drawnRows` still holds the rows of models it unloaded.
        let handle = f64_of(harness.eval("BOTS[0].model")?);
        let drawn = harness
            .observe()?
            .bot_draw
            .into_iter()
            .find(|d| d.model as f64 == handle);
        let airborne = drawn.as_ref().is_some_and(|d| {
            let ground = f64_of(
                harness
                    .call("terrainHeight", &[json!(d.x), json!(d.z)])
                    .unwrap_or(json!(0.0)),
            );
            d.y - ground > 0.5
        });
        let rolled = drawn
            .as_ref()
            .is_some_and(|d| d.axis_x.abs() + d.axis_z.abs() > 0.01);
        // Fly it out: the ground it meets ends it, and a bot walks on afterwards.
        let mut guard = 0;
        while bool_of(harness.eval("BOTS[0].mode === \"flung\"")?) && guard < 40 {
            drive_burst(harness, 9)?;
            guard += 1;
        }
        let landed = !bool_of(harness.eval("BOTS[0].mode === \"flung\"")?)
            && f64_of(harness.eval("BOTS[0].py")?) == 0.0;
        let walks_on = bool_of(harness.eval("BOTS[0].mode !== \"dead\"")?);
        out.herd_flung =
            caught && up > 1.0 && broadcast && airborne && rolled && landed && walks_on;
        if !out.herd_flung {
            eprintln!(
                "herd flung case: caught={caught} up={up} broadcast={broadcast} \
                 airborne={airborne} rolled={rolled} landed={landed} walks_on={walks_on} \
                 row={row:?} drawn={drawn:?}",
            );
        }
    }

    // ---- M19a: the herd is hurt, and dies ------------------------------------
    // A bot takes the player's own blast curve and, unlike the player, is not spared
    // by `blast.healthFloor` -- that floor is the promise that a *player's* run cannot
    // be ended by a mine. So a bot can be killed, and it is not gone: the herd keeps
    // the size the setting asks for, so the body lies there for `herd.deathLinger` and
    // then gets up somewhere else. The lethal bang is deliberately aimed at a bot that
    // is still in the air, which is the one path a corpse has physics for: a bot killed
    // mid-arc keeps the arc it had and lands.
    if f64_of(harness.eval("BOTS.length")?) > 0.0 {
        let max_health = f64_of(harness.eval("TUNING.stats.max")?);
        // The herd flung case above charged this bot a bang of its own, and the herd
        // trips devices of its own over the scripted timeline: both are damage now, so
        // the case starts from a whole skin rather than from whatever it walked into.
        harness.eval("BOTS[0].health = TUNING.stats.max")?;
        harness.command("heal")?;
        // A bang it survives: it hurts, and it still throws.
        harness.eval("goats.tuning.set(\"explosions.blast.damage\", 45)")?;
        harness.eval("blast(\"mine\", BOTS[0].x, BOTS[0].z, 0.25, 0)")?;
        let hurt = f64_of(harness.eval("BOTS[0].health")?);
        let thrown = bool_of(harness.eval("BOTS[0].mode === \"flung\"")?);
        out.bot_hurt = hurt > 0.0 && hurt < max_health && thrown;
        if !out.bot_hurt {
            eprintln!("bot hurt case: hurt={hurt} max={max_health} thrown={thrown}",);
        }
        // Two frames in, so the bot is genuinely off the ground when the next bang
        // lands -- and so the death fraction the world snapshot carries is past 0.
        drive_burst(harness, 2)?;
        harness.eval("goats.tuning.set(\"explosions.blast.damage\", 100)")?;
        harness.eval("blast(\"mine\", BOTS[0].x, BOTS[0].z, 0.25, 0)")?;
        drive_burst(harness, 2)?;
        let dead = bool_of(harness.eval("BOTS[0].mode === \"dead\"")?);
        let at_zero = f64_of(harness.eval("BOTS[0].health")?) == 0.0;
        let row = harness.call("sceneWorldBots", &[])?;
        let broadcast = row[0]["gait"] == json!("dead")
            && f64_of(row[0]["phase"].clone()) > 0.0
            && f64_of(row[0]["phase"].clone()) < 1.0;
        // The clip the *bot* posed, not the player's: the death is the death clip, and
        // `bot_clip_names` is the harness's record of what the herd animated.
        let posed = harness
            .observe()?
            .bot_clip_names
            .iter()
            .any(|name| name == "GoatDeath");
        out.bot_death = dead && at_zero && broadcast && posed;
        if !out.bot_death {
            eprintln!(
                "bot death case: dead={dead} at_zero={at_zero} broadcast={broadcast} \
                 posed={posed} row={row:?}",
            );
        }
        // The corpse falls -- the arc it was already on -- and lands still dead. The
        // guard is generous: the flight it was killed into is under a second.
        let mut guard = 0;
        while f64_of(harness.eval("BOTS[0].py")?) > 0.0 && guard < 40 {
            drive_burst(harness, 9)?;
            guard += 1;
        }
        let landed_py = f64_of(harness.eval("BOTS[0].py")?);
        let landed_dead = bool_of(harness.eval("BOTS[0].mode === \"dead\"")?);
        out.bot_lands = landed_py == 0.0 && landed_dead;
        if !out.bot_lands {
            eprintln!("bot corpse case: py={landed_py} dead={landed_dead}");
        }
        // ...and then it gets up somewhere else with a whole skin. The default linger
        // is eight seconds of standing around, so the case shortens it.
        harness.eval("goats.tuning.set(\"herd.deathLinger\", 1)")?;
        guard = 0;
        while bool_of(harness.eval("BOTS[0].mode === \"dead\"")?) && guard < 40 {
            drive_burst(harness, 9)?;
            guard += 1;
        }
        let alive = bool_of(harness.eval("BOTS[0].mode !== \"dead\"")?);
        let healed = f64_of(harness.eval("BOTS[0].health")?) == max_health;
        let away = f64_of(harness.eval(BOT_DISTANCE)?);
        out.bot_respawn = alive && healed && (9.0..=27.0).contains(&away);
        if !out.bot_respawn {
            eprintln!(
                "bot respawn case: alive={alive} healed={healed} away={away} \
                 guard={guard} mode={:?}",
                harness.eval("BOTS[0].mode")?,
            );
        }
        harness.eval("goats.tuning.set(\"herd.deathLinger\", 8)")?;
        harness.eval("goats.tuning.set(\"explosions.blast.damage\", 45)")?;
    }

    // The clip contract, both paths, plus what a peer is told: the flung gait reads
    // as the flung clip when the model has one and as the jump when it does not, it
    // plays once, and the phase that travels is the fraction through the arc -- not
    // `goat.phase`, which stands still for the whole flight.
    harness.eval("mode = \"flung\"")?;
    harness.eval("CLIP.flung = CLIP.jump")?;
    let with_clip = harness.eval("clipRole()")?;
    let peer_with = harness.eval("peerRole({ gait: \"flung\" })")?;
    harness.eval("CLIP.flung = null")?;
    let without_clip = harness.eval("clipRole()")?;
    let peer_without = harness.eval("peerRole({ gait: \"flung\" })")?;
    let one_shot = bool_of(harness.eval("netPeerShot(\"flung\")")?);
    harness.eval("flingTime = 0.25")?;
    harness.eval("flingFlight = 1")?;
    let phase = f64_of(harness.eval("netPeerPhase()")?);
    out.flung_clip = with_clip.as_str() == Some("flung")
        && without_clip.as_str() == Some("jump")
        && peer_with.as_str() == Some("flung")
        && peer_without.as_str() == Some("jump")
        && one_shot
        && (phase - 0.25).abs() < 1e-9;

    // And a restart mid-arc clears it, so a death (or a console restart) cannot
    // leave the next life hovering.
    harness.eval("startFling(9, 0, 5)")?;
    drive_burst(harness, 3)?;
    harness.command("restart")?;
    out.flung_restart = bool_of(
        harness.eval("mode === \"idle\" && flingTime === 0 && flingVX === 0 && flingVY === 0")?,
    );

    // One bang, one sound. The stub counts plays by the path that was loaded, and
    // `blasts` is cumulative and never reset, so this is the whole run: every bang
    // that went off played exactly one of the blast samples, wherever the goat was.
    // The bleats are counted separately -- a flung goat bawls as well, which is the
    // point of the whole feature.
    let played = harness.observe()?.sound_plays;
    let heard: u32 = played
        .iter()
        .filter(|(path, _)| path.contains("explosion"))
        .map(|(_, count)| *count)
        .sum();
    let bangs = explosion_state(harness)?.2 as u32;
    out.blast_sound = bangs > 0 && heard == bangs;
    if !out.blast_sound {
        eprintln!("blast sound case: bangs={bangs} heard={heard} plays={played:?}");
    }

    // ...and the grit it threw came down: the queue drained, the falling samples are
    // among what was heard, and there is at most one fall per bang (every bang queues
    // exactly one, and the queue has a cap, so it can be fewer).
    let grit: u32 = played
        .iter()
        .filter(|(path, _)| path.contains("falling"))
        .map(|(_, count)| *count)
        .sum();
    let drained = f64_of(harness.eval("DEBRIS_QUEUE.length")?) == 0.0;
    out.blast_debris &= drained && grit > 0 && grit <= bangs;
    if !out.blast_debris {
        eprintln!(
            "blast debris case: grit={grit} bangs={bangs} drained={drained} queue={:?}",
            harness.eval("DEBRIS_QUEUE.length")?,
        );
    }

    // ---- M19d: craters --------------------------------------------------------
    //
    // A bang dishes the ground, kills the grass it swallowed, and heals back over
    // `crater.heal` -- shortened here, because the default is four minutes. The dish is
    // a term in `terrainHeight`, so what the case watches is the *ground*: everything
    // that stands on it reads that one function, which is the whole reason it lives
    // there rather than in the mesh.
    harness.command("heal")?;
    harness.command("pos 0 0")?;
    harness.eval("sceneResetCraters()")?;
    // A bang on a tuft, so the grass half of the case is about a tuft that was there:
    // the `grass` verb is how the tuft cases find one.
    let tuft = try_command_json(harness, "grass 40")?;
    if bool_of(harness.eval("sceneCraters().length === 0")?) && tuft["x"].is_number() {
        let tx = f64_of(tuft["x"].clone());
        let tz = f64_of(tuft["z"].clone());
        let depth = f64_of(harness.eval("TUNING.explosions.crater.depth")?);
        let heal = f64_of(harness.eval("TUNING.explosions.crater.heal")?);
        harness.eval("goats.tuning.set(\"explosions.crater.heal\", 2)")?;
        // Nothing else must dig while this case waits for its hole to close: the herd
        // walks the same field, and a bot tripping a device would add a crater with a
        // four-minute life to a loop that is watching for an empty list.
        harness.eval("goats.tuning.set(\"explosions.mine.density\", 0)")?;
        harness.eval("goats.tuning.set(\"explosions.trap.chance\", 0)")?;
        let ground_before = f64_of(harness.call("terrainHeight", &[json!(tx), json!(tz)])?);
        // The goat stands on the tuft before the bang: the mesh is only rebuilt for a
        // crater near the goat (a distant bang must not cost a whole field's vertices),
        // and this case is about the near one -- the hole the player is standing in.
        harness.command(&format!("pos {tx} {tz}"))?;
        harness.eval(&format!("blast(\"mine\", {tx}, {tz}, 0.25, 0)"))?;
        let dug = try_command_json(harness, "craters 30")?;
        let live = f64_of(dug["live"].clone());
        let recorded = harness.call("sceneCraters", &[])?;
        let radius = recorded
            .as_array()
            .and_then(|list| list.first())
            .map(|c| f64_of(c["r"].clone()))
            .unwrap_or(0.0);
        let ground_after = f64_of(harness.call("terrainHeight", &[json!(tx), json!(tz)])?);
        // The dish, at its own centre: the tuning's depth, within the radius' variation.
        let dished = ground_after < ground_before - depth * 0.9;
        // The grass the crater swallowed is gone...
        let bare = harness
            .eval(&format!("nearestTuft({tx}, {tz}, 0.5, false)"))?
            .is_null();
        // ...and the ground's own caches were told rather than left until the goat had
        // walked `terrain.snap` away: dirty now, clean once a frame has run.
        let marked = bool_of(harness.eval("terrainDirty")?);
        drive_burst(harness, 4)?;
        let rebuilt = !bool_of(harness.eval("terrainDirty")?);
        // Then it heals: the ground comes back, and so does the grass -- a tuft returns
        // as the ground closes over it, because a crater's kill is the meadow's own
        // `EATEN` with the crater's heal for a duration.
        let mut guard = 0;
        while f64_of(harness.eval("sceneCraters().length")?) > 0.0 && guard < 40 {
            drive_burst(harness, 9)?;
            guard += 1;
        }
        let closed = f64_of(harness.eval("sceneCraters().length")?) == 0.0;
        let ground_back = f64_of(harness.call("terrainHeight", &[json!(tx), json!(tz)])?);
        let flat = (ground_back - ground_before).abs() < 0.01;
        let regrown = !harness
            .eval(&format!("nearestTuft({tx}, {tz}, 0.5, false)"))?
            .is_null();
        out.craters = live == 1.0
            && radius > 0.5
            && dished
            && bare
            && marked
            && rebuilt
            && closed
            && flat
            && regrown;
        if !out.craters {
            eprintln!(
                "crater case: live={live} r={radius} before={ground_before} \
                 after={ground_after} back={ground_back} dished={dished} bare={bare} \
                 marked={marked} rebuilt={rebuilt} closed={closed} flat={flat} \
                 regrown={regrown} heal was {heal}",
            );
        }
        harness.eval("goats.tuning.set(\"explosions.crater.heal\", 240)")?;
        harness.eval("goats.tuning.set(\"explosions.mine.density\", 0.012)")?;
        harness.eval("goats.tuning.set(\"explosions.trap.chance\", 0.04)")?;
    }

    harness.command("heal")?;
    harness.command("pos 0 0")?;
    Ok(out)
}

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

/// The watcher case: it subscribes, sets, unsubscribes and sets again, and comes
/// back with what the watcher saw before it was removed.
const WATCH_PROBE: &str = "(function () { \
     let saw = null; \
     const off = tuningWatch(\"stats.max\", function (path, value) { saw = path + \"=\" + value; }); \
     tuningSet(\"stats.max\", 120); \
     off(); \
     tuningSet(\"stats.max\", 100); \
     return saw; })()";

/// What the help-formatting cases found. One field per case.
#[derive(Debug, Default)]
struct Help {
    paged: bool,
    grouped: bool,
    split_lines: bool,
    wrapped: bool,
    hard_split: bool,
}

/// A long, indented line, wrapped to a panel narrower than it: it must break into
/// several rows, every row must measure inside the width, and the indentation must
/// survive so the columns still line up.
const WRAP_PROBE: &str = r#"(function () {
    const rows = consoleWrap("      " + Array(80).join("word "), 200, 18);
    return {
        count: rows.length,
        fits: rows.every(function (row) { return consoleTextWidth(row, 18) <= 200; }),
        indented: rows.every(function (row) { return row.slice(0, 6) === "      "; })
    };
})()"#;

/// One long token: it has to be split rather than run off, and nothing may be lost
/// in the split.
const SPLIT_PROBE: &str = r#"(function () {
    const rows = consoleWrap("x".repeat(500), 200, 18);
    return {
        count: rows.length,
        fits: rows.every(function (row) { return consoleTextWidth(row, 18) <= 200; }),
        whole: rows.join("").length === 500
    };
})()"#;

/// Drives the help page and the console's wrapping.
fn help_block(harness: &mut Harness) -> Result<Help, String> {
    let mut help = Help::default();

    let reply = harness.command("help")?;
    let rows: Vec<&str> = reply.split('\n').collect();
    help.paged = reply.starts_with("ok help - commands by topic") && rows.len() >= 5;
    let row = |line: &str| rows.contains(&line);
    help.grouped = row("  basics  help ping")
        && row("  mods    mod")
        && row("  flow    pause resume step quit");

    // The reply reaches the scrollback as one entry per row, which is what makes
    // the page readable rather than one truncated line.
    harness.command("console close")?;
    harness.command("console say help")?;
    let lines = try_command_json(harness, "console")?["lines"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let shown = |line: &str| lines.iter().any(|entry| entry.as_str() == Some(line));
    help.split_lines = shown("local: ok help - commands by topic")
        && shown("local:   basics  help ping")
        && shown("local:   flow    pause resume step quit");
    harness.command("console close")?;

    let wrapped = harness.eval(WRAP_PROBE)?;
    help.wrapped = wrapped["count"].as_u64().is_some_and(|count| count > 1)
        && bool_of(wrapped["fits"].clone())
        && bool_of(wrapped["indented"].clone());
    let split = harness.eval(SPLIT_PROBE)?;
    help.hard_split = split["count"].as_u64().is_some_and(|count| count > 1)
        && bool_of(split["fits"].clone())
        && bool_of(split["whole"].clone());
    Ok(help)
}

/// The queued network intents, drained. The host calls this once a frame.
fn net_drain(harness: &mut Harness) -> Result<String, String> {
    let value = harness.call("sceneNetDrain", &[])?;
    Ok(value.as_str().unwrap_or("").to_string())
}

/// The last pose the scene published: its gait and the phase it carried.
fn last_pose(text: &str) -> (String, f64) {
    let mut found = (String::new(), f64::NAN);
    for line in text.lines() {
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(value) => value,
            Err(_) => continue,
        };
        if value["type"] == json!("pose") {
            found = (
                value["gait"].as_str().unwrap_or("").to_string(),
                f64_of(value["phase"].clone()),
            );
        }
    }
    found
}

/// One remote goat's phase, from the scene's own view of its peers.
fn peer_phase(harness: &mut Harness, name: &str) -> Result<f64, String> {
    let peers = harness.call("scenePeers", &[])?;
    Ok(peers
        .as_array()
        .and_then(|list| list.iter().find(|peer| peer["name"] == json!(name)))
        .map(|peer| f64_of(peer["phase"].clone()))
        .unwrap_or(f64::NAN))
}

/// What the network bridge cases found. One field per case.
#[derive(Debug, Default)]
struct Net {
    rest_empty: bool,
    host_queued: bool,
    view: bool,
    printed: bool,
    refused: bool,
    left: bool,
    reset: bool,
    no_ticket: bool,
    joined: bool,
    prompt_asked: bool,
    prompt_answered: bool,
    pull_flag: bool,
    pull_prompt: bool,
    muted: bool,
}

/// Drives the scene end of the session with no socket and no peer.
fn net_block(harness: &mut Harness) -> Result<Net, String> {
    let mut net = Net {
        rest_empty: net_drain(harness)?.is_empty(),
        ..Net::default()
    };

    let host_reply = harness.command("host bob")?;
    let host_intent = net_drain(harness)?;
    net.host_queued = host_reply == "ok host"
        && host_intent.contains("\"type\":\"host\"")
        && host_intent.contains("\"name\":\"bob\"");
    // Draining clears the queue.
    net.host_queued &= net_drain(harness)?.is_empty();

    net_feed(harness, r#"{"type":"hosting","name":"bob"}"#)?;
    net_feed(harness, r#"{"type":"ticket","ticket":"endpointXYZ"}"#)?;
    net_feed(harness, r#"{"type":"roster","names":["bob","alice"]}"#)?;
    let status = try_command_json(harness, "net")?;
    net.view = status["mode"] == json!("host")
        && status["name"] == json!("bob")
        && status["ticket"] == json!("endpointXYZ")
        && status["roster"].as_array().map_or(0, Vec::len) == 2;

    net_feed(harness, r#"{"type":"joined","name":"alice"}"#)?;
    let echoed = try_command_json(harness, "console")?["lines"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let said = |needle: &str| {
        echoed
            .iter()
            .any(|line| line.as_str().is_some_and(|text| text.contains(needle)))
    };
    net.printed = said("alice joined") && said("roster bob, alice");

    net.refused = harness.command("host bob")? == "error already in a session (leave first)";
    net.left = harness.command("leave")? == "ok leave"
        && net_drain(harness)?.contains("\"type\":\"close\"");

    net_feed(harness, r#"{"type":"disconnected"}"#)?;
    net.reset = try_command_json(harness, "net")?["mode"] == json!("off");

    net.no_ticket = harness.command("connect")? == "error connect expects a ticket";
    net.joined = harness.command("connect endpointABC alice")? == "ok connect"
        && net_drain(harness)?.contains("\"ticket\":\"endpointABC\"");

    // A username prompt: the command asks, the next console line answers. The
    // outbox is cleared first because the join above queued an intent.
    net_drain(harness)?;
    let prompt_reply = harness.command("host")?;
    let prompt = try_command_json(harness, "console")?;
    net.prompt_asked = prompt_reply == "ok name?"
        && prompt["open"] == json!(true)
        && prompt["lines"].as_array().is_some_and(|lines| {
            lines
                .iter()
                .any(|line| line.as_str().is_some_and(|text| text.contains("Username?")))
        });
    harness.command("console say carol")?;
    net.prompt_answered = net_drain(harness)?.contains("\"name\":\"carol\"");

    // `--pull` rides the join as its own field, wherever it sat among the
    // arguments, so the host knows the fetch is consented to (M18d).
    let flagged = harness.command("connect endpointDEF bob --pull")?;
    let intent = net_drain(harness)?;
    net.pull_flag = flagged == "ok connect"
        && intent.contains("\"ticket\":\"endpointDEF\"")
        && intent.contains("\"name\":\"bob\"")
        && intent.contains("\"pull\":true");

    // ...and a flagged connect with no name still asks for one, because the flag
    // is not a name.
    let prompt_reply = harness.command("connect endpointGHI --pull")?;
    harness.command("console say dave")?;
    let intent = net_drain(harness)?;
    net.pull_prompt = prompt_reply == "ok name?"
        && intent.contains("\"name\":\"dave\"")
        && intent.contains("\"pull\":true");

    // Master mute has to reach the host: the voice mixer is Rust's, so the
    // scene's only lever is the gain intent.
    harness.call("setMuted", &[json!(true)])?;
    let muted = net_drain(harness)?;
    net.muted = muted.contains("\"type\":\"voice_gain\"") && muted.contains("\"gain\":0");
    harness.call("setMuted", &[json!(false)])?;
    net_drain(harness)?;
    Ok(net)
}

/// What the chat cases found. One field per case.
#[derive(Debug, Default)]
struct Chat {
    bare: bool,
    say: bool,
    msg: bool,
    at: bool,
    slash_command: bool,
    offline: bool,
    printed: bool,
}

/// Drives the scene end of chat: queueing a line and printing what comes back.
fn chat_block(harness: &mut Harness) -> Result<Chat, String> {
    let mut chat = Chat::default();
    // Pretend to be in a session, so bare text is chat rather than an error.
    net_feed(harness, r#"{"type":"hosting","name":"bob"}"#)?;
    net_drain(harness)?;

    // Bare text is global chat, and queues silently: no `ok` per line.
    let bare = harness.command("hello everyone")?;
    chat.bare = bare.is_empty() && net_drain(harness)?.contains("\"text\":\"hello everyone\"");

    // `say` is the same thing, spelled out.
    let say = harness.command("say hi there")?;
    chat.say = say.is_empty() && net_drain(harness)?.contains("\"text\":\"hi there\"");

    // `/msg` becomes the leading-`@` form the server routes for both sides.
    let msg = harness.command("/msg alice psst")?;
    chat.msg = msg.is_empty() && net_drain(harness)?.contains("\"text\":\"@alice psst\"");

    // A leading `@` typed directly is a whisper too.
    let at = harness.command("@carol yo")?;
    chat.at = at.is_empty() && net_drain(harness)?.contains("\"text\":\"@carol yo\"");

    // The slash forms still reach the commands they name.
    chat.slash_command = harness.command("/who")?.starts_with("ok ");

    // Offline, bare text stays an error, so a typo is caught rather than sent.
    net_feed(harness, r#"{"type":"disconnected"}"#)?;
    chat.offline = harness.command("hello?")? == "error unknown command: hello?";

    // A chat line prints into the scrollback, whispers marked.
    net_feed(
        harness,
        r#"{"type":"chat","from":"alice","text":"hello all","direct":false}"#,
    )?;
    net_feed(
        harness,
        r#"{"type":"chat","from":"alice","text":"psst","direct":true}"#,
    )?;
    let printed = try_command_json(harness, "console")?["lines"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let shown = |needle: &str| {
        printed
            .iter()
            .any(|line| line.as_str().is_some_and(|text| text.contains(needle)))
    };
    chat.printed = shown("net: alice: hello all") && shown("net: dm alice: psst");
    Ok(chat)
}

/// What the world-sync cases found. One field per case.
#[derive(Debug, Default)]
struct Sync {
    seeded: bool,
    seed_differs: bool,
    pose: bool,
    pose_throttled: bool,
    peer_added: bool,
    peer_left: bool,
    world: bool,
    mirror: bool,
    weather_mirror: bool,
    streams_mirror: bool,
    eaten_mirror: bool,
    craters_mirror: bool,
    craters_kept: bool,
    craters_retired: bool,
    spent_mirror: bool,
    blast_mirror: bool,
    reports_blast: bool,
    reports_eat: bool,
    client_not_local: bool,
    client_is_not_authority: bool,
    world_local_offline: bool,
}

/// The snapshot a hosting server sends a client, verbatim.
const WORLD_EVENT: &str = r#"{"type":"world","weather":{"kind":"rain","cloudiness":0.9,"rain_amount":0.8,"wind_x":1.5,"wind_z":-0.5,"wind_sway":1.2,"world_time":21.5},"streams":{"weather":111,"bots":222,"food":333,"audio":444},"eaten":[{"key":4242,"left":12.5}],"bots":[{"index":0,"x":9,"z":9,"yaw":0,"phase":0.5,"gait":"walk","variant":0},{"index":1,"x":-9,"z":-9,"yaw":1,"phase":0.25,"gait":"idle","variant":2}]}"#;

/// The same snapshot with only the two parts M19e added: the ground the host has cratered and
/// the devices it has seen go off. The bots are the same two `WORLD_EVENT` carries -- a case
/// is not allowed to resize the herd on its way past -- and the meadow is empty, because what
/// these cases say about it is `null`, `[]` or a value.
fn world_wire(craters: &str, spent: &str) -> String {
    format!(
        r#"{{"type":"world","weather":{{"kind":"rain","cloudiness":0.9,"rain_amount":0.8,"wind_x":1.5,"wind_z":-0.5,"wind_sway":1.2,"world_time":21.5}},"streams":{{"weather":111,"bots":222,"food":333,"audio":444}},"eaten":[],"bots":[{{"index":0,"x":9,"z":9,"yaw":0,"phase":0.5,"gait":"walk","variant":0}},{{"index":1,"x":-9,"z":-9,"yaw":1,"phase":0.25,"gait":"idle","variant":2}}],"craters":{craters},"spent":{spent}}}"#
    )
}

/// The first armed mine far from the origin, as `{ cx, cz, key }`. Far out because a bang on
/// it must not reach the goat any case here is measuring, and scanned rather than assumed
/// because the field is a hash of the session seed.
const MINE_PROBE: &str = r#"(function () {
    for (let cx = 40; cx < 140; cx++) {
        for (let cz = 40; cz < 140; cz++) {
            if (mineArmed(cx, cz)) return { cx: cx, cz: cz, key: tuftKey(cx, cz) };
        }
    }
    return null;
})()"#;

fn mine_probe(harness: &mut Harness) -> Result<Option<(i64, i64, i64)>, String> {
    let found = harness.eval(MINE_PROBE)?;
    if found.is_null() {
        return Ok(None);
    }
    Ok(Some((
        found["cx"].as_i64().unwrap_or(0),
        found["cz"].as_i64().unwrap_or(0),
        found["key"].as_i64().unwrap_or(0),
    )))
}

/// Drives the seed handshake, the snapshot channel and the mirroring rules.
fn sync_block(harness: &mut Harness) -> Result<Sync, String> {
    let mut sync = Sync::default();

    // A session seed re-keys every stream, reproducibly, and a different seed
    // builds a different world.
    let before = harness.call("sceneStreams", &[])?;
    net_feed(harness, r#"{"type":"session","seed":4242}"#)?;
    let a = harness.call("sceneStreams", &[])?;
    net_feed(harness, r#"{"type":"session","seed":4242}"#)?;
    let b = harness.call("sceneStreams", &[])?;
    net_feed(harness, r#"{"type":"session","seed":99}"#)?;
    let c = harness.call("sceneStreams", &[])?;
    sync.seeded = a["weather"] != before["weather"]
        && a["weather"] == b["weather"]
        && a["bots"] == b["bots"]
        && a["food"] == b["food"]
        && a["audio"] == b["audio"];
    sync.seed_differs = c["weather"] != a["weather"];

    // In a session the local goat is published, once per throttle window and not
    // again in the same frame.
    net_feed(harness, r#"{"type":"hosting","name":"bob"}"#)?;
    let first = net_drain(harness)?;
    sync.pose = first.contains("\"type\":\"pose\"") && first.contains("\"gait\"");
    sync.pose_throttled = !net_drain(harness)?.contains("\"type\":\"pose\"");
    // A host also owns the world and publishes its bots.
    sync.world = first.contains("\"type\":\"world\"")
        && first.contains("\"bots\"")
        && first.contains("\"weather\"");
    // The ground and the fired devices go with it (M19e): a joiner has to see the field as it
    // stands, so a host that published a world without them would be telling every client its
    // ground is flat.
    sync.world = sync.world && first.contains("\"craters\"") && first.contains("\"spent\"");

    // A client's device went off, reported to the host (M19e). The host spends it -- the
    // neighbours must not trip it -- and queues the relay with the reporter's name, so the
    // bridge can leave them out: they have already felt this bang.
    if let Some((cx, cz, key)) = mine_probe(harness)? {
        net_feed(
            harness,
            &format!(r#"{{"type":"blast_report","kind":"mine","key":{key},"by":"alice"}}"#),
        )?;
        let relayed = net_drain(harness)?;
        sync.reports_blast = !bool_of(harness.eval(&format!("mineArmed({cx}, {cz})"))?)
            && relayed.contains("\"type\":\"blast\"")
            && relayed.contains("\"by\":\"alice\"")
            && relayed.contains(&format!("\"key\":{key}"));
    }

    // A snapshot becomes a goat; a later one moves it; leaving removes it.
    net_feed(
        harness,
        r#"{"type":"peer","name":"alice","state":{"x":3,"z":4,"yaw":0,"phase":0,"speed":0,"gait":"idle"}}"#,
    )?;
    net_feed(
        harness,
        r#"{"type":"peer","name":"alice","state":{"x":5,"z":6,"yaw":1,"phase":0.5,"speed":2,"gait":"trot"}}"#,
    )?;
    let peers = harness.call("scenePeers", &[])?;
    sync.peer_added = peers.as_array().is_some_and(|list| {
        list.len() == 1
            && list[0]["name"] == json!("alice")
            && f64_of(list[0]["tx"].clone()) == 5.0
            && f64_of(list[0]["tz"].clone()) == 6.0
            && list[0]["gait"] == json!("trot")
    });
    net_feed(harness, r#"{"type":"left","name":"alice"}"#)?;
    sync.peer_left = harness
        .call("scenePeers", &[])?
        .as_array()
        .is_some_and(|list| list.is_empty());
    net_feed(harness, r#"{"type":"disconnected"}"#)?;

    // A client mirrors the server's bots, sky, streams and meadow, and publishes
    // no world of its own.
    net_feed(harness, r#"{"type":"welcome","name":"eve"}"#)?;
    sync.client_not_local = !bool_of(harness.call("netWorldLocal", &[])?)
        && !bool_of(harness.call("netWeatherLocal", &[])?);
    net_feed(harness, WORLD_EVENT)?;
    let mirrored = harness.call("sceneWorldBots", &[])?;
    sync.mirror = mirrored.as_array().is_some_and(|list| {
        list.len() == 2
            && f64_of(list[0]["x"].clone()) == 9.0
            && f64_of(list[1]["z"].clone()) == -9.0
            && list[1]["gait"] == json!("idle")
    });
    let weather = harness.call("sceneWeatherState", &[])?;
    sync.weather_mirror = weather["kind"] == json!("rain")
        && f64_of(weather["rain_amount"].clone()) == 0.8
        && f64_of(weather["world_time"].clone()) == 21.5;
    let streams = harness.call("sceneStreams", &[])?;
    sync.streams_mirror =
        f64_of(streams["food"].clone()) == 333.0 && f64_of(streams["audio"].clone()) == 444.0;
    let eaten = harness.call("sceneEaten", &[])?;
    sync.eaten_mirror = eaten
        .as_array()
        .is_some_and(|list| list.len() == 1 && f64_of(list[0]["key"].clone()) == 4242.0);
    sync.client_is_not_authority = !net_drain(harness)?.contains("\"type\":\"world\"");

    // The ground is state, not an event (M19e), so it arrives with the world: a client mirrors
    // the host's craters, and `terrainHeight` -- which the goat, the herd, the grass and both
    // shadows all read -- is the ground the host is standing on.
    let (hole_x, hole_z) = (40.0, 41.5);
    let flat = f64_of(harness.call("terrainHeight", &[json!(hole_x), json!(hole_z)])?);
    // The device whose key the snapshot carries, and the one thing about it this end cannot
    // derive from the key alone: that it was armed to begin with.
    let spent_mine = mine_probe(harness)?;
    let spent_json = match spent_mine {
        Some((_, _, key)) => format!(r#"[{{"key":{key},"trap":false}}]"#),
        None => "[]".to_string(),
    };
    net_feed(
        harness,
        &world_wire(r#"[{"x":40.0,"z":41.5,"r":1.6,"depth":0.4}]"#, &spent_json),
    )?;
    let dished = f64_of(harness.call("terrainHeight", &[json!(hole_x), json!(hole_z)])?);
    let listed = harness.call("sceneCraters", &[])?;
    sync.craters_mirror = listed
        .as_array()
        .is_some_and(|list| list.len() == 1 && f64_of(list[0]["depth"].clone()) == 0.4)
        && dished < flat - 0.2;
    // A device the host says has fired leaves the field here too, and its replacement arrives
    // where the cell it left says it should -- so nothing about the move has to travel.
    // A device the host says has fired leaves the field here too. Not *where its replacement
    // went*: a device needs an empty cell on its ring and is simply not replaced when the draws
    // are taken, so the invariant is the one the field's own book-keeping promises -- the cell
    // is not armed and not a replacement's, either way.
    sync.spent_mirror = match spent_mine {
        Some((cx, cz, key)) => {
            !bool_of(harness.eval(&format!("mineArmed({cx}, {cz})"))?)
                && !bool_of(harness.eval(&format!("MOVED.has({key})"))?)
        }
        None => false,
    };

    // `null` is "keep yours": the snapshot could not carry the ground, and clearing it would
    // drop every client into a hole it no longer knows about -- the meadow's own rule.
    net_feed(harness, &world_wire("null", "null"))?;
    sync.craters_kept = harness
        .call("sceneCraters", &[])?
        .as_array()
        .is_some_and(|list| list.len() == 1);

    // An empty list is the opposite claim -- there is no crater here -- and the ground closes.
    net_feed(harness, &world_wire("[]", "[]"))?;
    let closed = f64_of(harness.call("terrainHeight", &[json!(hole_x), json!(hole_z)])?);
    sync.craters_retired = harness
        .call("sceneCraters", &[])?
        .as_array()
        .is_some_and(|list| list.is_empty())
        && (closed - flat).abs() < 0.001;

    // A bang the host relayed (M19e): the hole is dug here, the device is spent here, and
    // nothing is reported back out -- this end did not fire it, and a device fires once.
    net_drain(harness)?;
    let bangs_before = f64_of(harness.call("sceneExplosions", &[])?["blasts"].clone());
    if let Some((cx, cz, key)) = mine_probe(harness)? {
        net_feed(
            harness,
            &format!(
                r#"{{"type":"blast","kind":"mine","key":{key},"x":{},"z":{},"by":"alice"}}"#,
                cx * 2 + 1,
                cz * 2 + 1
            ),
        )?;
        let after = net_drain(harness)?;
        sync.blast_mirror = !after.contains("\"type\":\"blast\"")
            && !bool_of(harness.eval(&format!("mineArmed({cx}, {cz})"))?)
            && f64_of(harness.call("sceneExplosions", &[])?["blasts"].clone())
                == bangs_before + 1.0;
    }

    // A client reports its bite rather than recording it; the meadow is the
    // host's. The world above cleared the meadow, so a tuft is there to eat.
    harness.command("energy 40")?;
    let tuft = try_command_json(harness, "grass")?;
    if !tuft.is_null() {
        let (x, z) = (f64_of(tuft["x"].clone()), f64_of(tuft["z"].clone()));
        harness.command(&format!("pos {} {}", x - 0.5, z))?;
        net_drain(harness)?;
        let reply = harness.command("eat")?;
        sync.reports_eat =
            reply.starts_with("ok") && net_drain(harness)?.contains("\"type\":\"consume\"");
    }
    net_feed(harness, r#"{"type":"disconnected"}"#)?;
    sync.world_local_offline = bool_of(harness.call("netWorldLocal", &[])?)
        && bool_of(harness.call("netWeatherLocal", &[])?);
    Ok(sync)
}

/// What the one-shot gait cases found. One field per case.
#[derive(Debug, Default)]
struct Gaits {
    jump_fraction: bool,
    peer_shot_snapped: bool,
    peer_loop_resent: bool,
}

/// A one-shot gait is posed from its own clock, and `goat.phase` stands still
/// for the whole of it -- so the phase that goes on the wire has to be the
/// fraction through that clip, not the loop phase. The bots always carried it
/// (`netBotPhase`); the goat did not, and a remote goat held one frozen pose
/// right through a jump, a death or a meal.
///
/// Both ends are driven here, with no socket and no peer: the goat's by draining
/// between frames of its own, the peer's by feeding a snapshot.
fn gait_block(harness: &mut Harness) -> Result<Gaits, String> {
    let mut gaits = Gaits::default();

    // Driven from frame 0, where the scripted input holds no keys, so the jump
    // is the goat's own. The pose channel is throttled to one snapshot per
    // window, and only a frame advances the window -- so the two samples straddle
    // three frames each, well inside the jump.
    net_feed(harness, r#"{"type":"hosting","name":"bob"}"#)?;
    net_drain(harness)?;
    harness.reset_frame()?;
    harness.command("resume")?;
    if harness.command("jump")? != "ok jump" {
        return Err("the goat would not jump".to_string());
    }
    let (gait, early) = pose_after(harness, 3)?;
    let (later_gait, late) = pose_after(harness, 3)?;
    gaits.jump_fraction = gait == "jump" && later_gait == "jump" && early > 0.0 && late > early;

    // A peer's one-shot snapshot is stepped straight in -- its phase is a
    // fraction through a clip that does not loop, so there is nothing to ease
    // toward. Leaving one snaps too: the loop resumes where the snapshot put it
    // rather than gliding back from the end of the jump.
    net_feed(
        harness,
        r#"{"type":"peer","name":"alice","state":{"x":1,"z":2,"yaw":0,"phase":0,"speed":0,"gait":"walk"}}"#,
    )?;
    net_feed(
        harness,
        r#"{"type":"peer","name":"alice","state":{"x":1,"z":2,"yaw":0,"phase":0.75,"speed":0,"gait":"jump"}}"#,
    )?;
    gaits.peer_shot_snapped = peer_phase(harness, "alice")? == 0.75;
    net_feed(
        harness,
        r#"{"type":"peer","name":"alice","state":{"x":1,"z":2,"yaw":0,"phase":0.1,"speed":0,"gait":"walk"}}"#,
    )?;
    gaits.peer_loop_resent = peer_phase(harness, "alice")? == 0.1;

    Ok(gaits)
}

/// Drives `frames` frames and returns the pose the scene published after them.
fn pose_after(harness: &mut Harness, frames: u32) -> Result<(String, f64), String> {
    for _ in 0..frames {
        harness.call("sceneFrame", &[])?;
    }
    Ok(last_pose(&net_drain(harness)?))
}

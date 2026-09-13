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
use support::{Checks, bool_of, command_json, f64_of, try_command_json};

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

    // ---- the herd --------------------------------------------------------
    // `minGap` is what the bots logged, so a negative one means they collided.
    checks.check("bot goats load", obs.bot_count >= 2, obs.bot_count);
    checks.check(
        "goats never overlap",
        obs.min_gap.is_some_and(|gap| gap > -0.12),
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

/// The queued network intents, drained. The host calls this once a frame.
fn net_drain(harness: &mut Harness) -> Result<String, String> {
    let value = harness.call("sceneNetDrain", &[])?;
    Ok(value.as_str().unwrap_or("").to_string())
}

/// One event from the host, the way the session feeds the scene.
fn net_feed(harness: &mut Harness, event: &str) -> Result<(), String> {
    harness.call("sceneNetEvent", &[json!(event)]).map(|_| ())
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
    reports_eat: bool,
    client_not_local: bool,
    client_is_not_authority: bool,
    world_local_offline: bool,
}

/// The snapshot a hosting server sends a client, verbatim.
const WORLD_EVENT: &str = r#"{"type":"world","weather":{"kind":"rain","cloudiness":0.9,"rain_amount":0.8,"wind_x":1.5,"wind_z":-0.5,"wind_sway":1.2,"world_time":21.5},"streams":{"weather":111,"bots":222,"food":333,"audio":444},"eaten":[{"key":4242,"left":12.5}],"bots":[{"index":0,"x":9,"z":9,"yaw":0,"phase":0.5,"gait":"walk","variant":0},{"index":1,"x":-9,"z":-9,"yaw":1,"phase":0.25,"gait":"idle","variant":2}]}"#;

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

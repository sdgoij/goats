//! The water table: the fill, the level the weather sets, and the pools it makes.
//!
//! M20a is the field and the fill -- no draw -- so everything a test can hold is a
//! number. `sceneWater()` reports the level, how much of the grid is wet and where
//! the deepest point is; `waterDepthAt(x, z)` reports the depth under a point. The
//! field is a pure function of the ground, so these cases are about that ground:
//! rain fills the hollows, a dry spell empties them exactly, the table walks
//! monotonically with the rain, and a crater -- a hole a blast put in the ground --
//! is just another basin the water fills.
//!
//! The level is *derived* from the weather's `rainAmount`, never integrated over
//! time, which is what lets the two cases drive it with `rainAmount` directly: there
//! is no accumulator to age, so a value set and read in the same tick is the value
//! the frame would use.
//!
//! ```text
//! cargo test --release -p harness --test water -- --nocapture
//! ```

mod support;

use harness::Harness;
use serde_json::{Value, json};
use support::{Checks, command_json, f64_of};

/// Long enough to walk the load steps: the terrain, the textures and the herd.
const FRAMES: u32 = 30;

/// Where the second case cuts its hole: out on the field, clear of the flat spawn
/// bowl (`TUNING.terrain.flat`), so the dish lands on real relief.
const CRATER_X: f64 = 12.0;
const CRATER_Z: f64 = 8.0;

/// `sceneWater`, parsed.
fn water(harness: &mut Harness) -> Value {
    command_json(harness, "water")
}

/// The water depth under a world point.
fn depth(harness: &mut Harness, x: f64, z: f64) -> f64 {
    f64_of(
        harness
            .eval(&format!("waterDepthAt({x}, {z})"))
            .expect("waterDepthAt"),
    )
}

/// Set the rain and push it through the one hook both a local weather step and a
/// mirroring client use, so the table is recomputed the way the frame does it.
fn rain(harness: &mut Harness, amount: f64) {
    harness
        .eval(&format!("rainAmount = {amount}"))
        .expect("set the rain");
    harness
        .call("updateWeatherEffects", &[])
        .expect("updateWeatherEffects");
}

/// `flood <level>`, asserting it was accepted.
fn flood(harness: &mut Harness, level: f64) {
    let reply = harness.command(&format!("flood {level}")).expect("flood");
    assert!(reply.starts_with("ok "), "{reply}");
}

fn flood_off(harness: &mut Harness) {
    let reply = harness.command("flood off").expect("flood off");
    assert!(reply.starts_with("ok "), "{reply}");
}

#[test]
fn the_fill_makes_pools() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    let loaded = water(&mut harness);
    checks.check(
        "the field has relief to pool in",
        loaded["high"].as_f64().unwrap_or(f64::NAN) > loaded["low"].as_f64().unwrap_or(f64::NAN),
        &loaded,
    );
    checks.check(
        "the grid is the terrain's",
        loaded["cells"].as_u64() == Some(2401),
        &loaded,
    );
    checks.check(
        "the system is on by default",
        loaded["enabled"].as_bool() == Some(true),
        &loaded,
    );

    // A rainless sky holds no water: the level sits on the lowest ground, so the
    // lowest vertex reads depth zero and every other cell stands above it.
    rain(&mut harness, 0.0);
    let empty = water(&mut harness);
    checks.check(
        "a dry spell leaves the ground dry",
        empty["wet"].as_u64() == Some(0) && empty["deepest"].as_f64() == Some(0.0),
        &empty,
    );

    // Drizzle below `seep` is still dry; the knob is what keeps a damp morning from
    // flooding the field.
    rain(&mut harness, 0.1);
    let damp = water(&mut harness);
    checks.check(
        "rain below `seep` is still dry",
        damp["wet"].as_u64() == Some(0),
        &damp,
    );

    // A downpour fills every hollow to its spill, so there is water somewhere and a
    // deepest point that is deeper than nothing.
    rain(&mut harness, 1.0);
    let flooded = water(&mut harness);
    checks.check(
        "a downpour fills the hollows",
        flooded["wet"].as_u64().is_some_and(|w| w > 0)
            && flooded["deepest"].as_f64().is_some_and(|d| d > 0.0),
        &flooded,
    );
    checks.check(
        "the deepest point is inside the field it is measured on",
        flooded["deepX"].as_f64().is_some_and(|x| x.abs() <= 49.0)
            && flooded["deepZ"].as_f64().is_some_and(|z| z.abs() <= 49.0),
        &flooded,
    );

    // The table walks with the rain. This is the monotone property the whole
    // rain-to-level mapping is, and the one the drift-free derivation depends on.
    rain(&mut harness, 0.3);
    let lowish = water(&mut harness)["level"].as_f64().unwrap_or(f64::NAN);
    rain(&mut harness, 0.7);
    let highish = water(&mut harness)["level"].as_f64().unwrap_or(f64::NAN);
    rain(&mut harness, 1.0);
    let full = water(&mut harness)["level"].as_f64().unwrap_or(f64::NAN);
    checks.check(
        "more rain means a higher table",
        lowish < highish && highish <= full,
        (lowish, highish, full),
    );

    // ...and a higher table covers more ground: a level at the bottom wets less than
    // one at the top.
    rain(&mut harness, 0.35);
    let narrow = water(&mut harness)["wet"].as_u64().unwrap_or(0);
    rain(&mut harness, 1.0);
    let wide = water(&mut harness)["wet"].as_u64().unwrap_or(0);
    checks.check(
        "a higher table covers more ground",
        narrow < wide,
        (narrow, wide),
    );

    // The level is derived, not integrated: two reads with no frame between them are
    // the same number -- which is the whole reason a peer computing it from the same
    // rain agrees, with nothing on the wire.
    let first = water(&mut harness);
    let second = water(&mut harness);
    checks.check("the slice is a pure read", first == second, &first);

    checks.finish();
}

#[test]
fn a_crater_becomes_a_puddle() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // The ground at the spot before anything is cut into it, and a table a hair above
    // it -- so the spot is barely wet and the dish that follows is a real deepening
    // rather than the field's own noise.
    let ground = f64_of(
        harness
            .eval(&format!("terrainHeight({CRATER_X}, {CRATER_Z})"))
            .expect("terrainHeight"),
    );
    flood(&mut harness, ground + 0.05);
    let before = depth(&mut harness, CRATER_X, CRATER_Z);

    // A bang's dish is a term in `terrainHeight`, so laying one down and rebuilding
    // the mesh is the whole of making the hole; the water follows from the fill, which
    // the rebuild re-runs. The `flood` level survives the rebuild, so the extra depth
    // is the crater's and nothing else's.
    harness
        .call(
            "addCrater",
            &[json!(CRATER_X), json!(CRATER_Z), json!(20240)],
        )
        .expect("addCrater");
    harness
        .eval("terrainEnsure(goat.px, goat.pz)")
        .expect("terrainEnsure");
    let after = depth(&mut harness, CRATER_X, CRATER_Z);

    checks.check(
        "the dish is deeper than the ground it replaced",
        after > before + 0.2,
        (before, after),
    );
    checks.check(
        "the hole is capped at the wading depth",
        after > 0.0 && after <= 0.6 + 1e-6,
        after,
    );

    // `flood off` hands the table back to the weather, and the level stays a real
    // number rather than the override.
    flood_off(&mut harness);
    let released = water(&mut harness);
    checks.check(
        "the table goes back to the weather",
        released["forced"].as_bool() == Some(false) && released["level"].as_f64().is_some(),
        &released,
    );

    checks.finish();
}

/// The stub's row kind for a model draw (`harness_rl.js`'s `LAYER_MODEL`), and the
/// handle it gives the water surface's own program -- the pool is a `makeModel` mesh
/// like the terrain and the celestial spheres, so it shares their handle range and is
/// told apart by the program it is routed to.
const LAYER_MODEL: i64 = 1;
const WATER_SHADER: i64 = 9;

/// Where in one frame's draw order each model of a kind was drawn. An empty
/// `handles` matches any.
fn rows_of(layers: &[[i64; 3]], handles: &[i64]) -> Vec<usize> {
    layers
        .iter()
        .enumerate()
        .filter(|(_, row)| {
            row[0] == LAYER_MODEL && (handles.is_empty() || handles.contains(&row[1]))
        })
        .map(|(position, _)| position)
        .collect()
}

#[test]
fn the_pools_are_drawn() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    let surface = water(&mut harness);
    checks.check(
        "the surface has a program of its own",
        surface["shader"].as_i64() == Some(WATER_SHADER),
        &surface,
    );
    checks.check(
        "the mesh covers ground that can hold water",
        surface["mesh"].as_i64().is_some_and(|m| m >= 0)
            && surface["quads"].as_u64().is_some_and(|q| q > 0),
        &surface,
    );
    checks.check(
        "...and only a decimated share of the grid",
        surface["quads"].as_u64().is_some_and(|q| q < 48 * 48),
        surface["quads"].clone(),
    );

    // The geometry the table is mapped onto. It is printed because a change to `fill`,
    // `seep` or the terrain's relief moves it and nothing else reports it -- and it is
    // the number to read before touching those.
    eprintln!(
        "water: low {} high {} floor {} quads {} of {}",
        surface["low"],
        surface["high"],
        surface["floor"],
        surface["quads"],
        48 * 48
    );

    // Bring the rain, and make sure the lighting is on: the scripted timeline the
    // harness drives presses `L`, and the surface is only drawn in the lit pass.
    harness.command("lighting on").expect("lighting on");
    rain(&mut harness, 1.0);
    let flooded = water(&mut harness);
    checks.check(
        "the table rises into the basins",
        flooded["on"].as_bool() == Some(true)
            && flooded["rise"].as_f64().is_some_and(|rise| rise > 0.05),
        &flooded,
    );
    // The v1 promise: the heaviest rain is still wading depth, wherever the window's
    // relief happens to sit (`TUNING.water.maxDepth`).
    checks.check(
        "...and it stays a wading depth",
        flooded["rise"].as_f64().is_some_and(|rise| rise <= 0.6)
            && flooded["deepest"].as_f64().is_some_and(|deep| deep <= 0.6),
        (&flooded["rise"], &flooded["deepest"]),
    );

    // One frame with the water in, then the same frame without it. Two things have to
    // be handled to make a frame happen at all: `run` leaves the stub's frame budget
    // spent (so `windowShouldClose` reports true and `sceneFrame` returns before it
    // draws -- `reset_frame` is the harness's own door for one more frame), and the
    // scripted timeline presses `L`, while the surface is only drawn in the lit pass.
    // The handles are read *after* the frame, because a crater could have rebuilt the
    // grid during it.
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("one wet frame");
    let wet = harness.observe().expect("observe");
    let mesh = water(&mut harness)["mesh"].as_i64().unwrap_or(-1);
    let ground = harness
        .eval("terrainMesh")
        .expect("terrainMesh")
        .as_i64()
        .unwrap_or(-1);
    let surface_rows = rows_of(&wet.layers, &[mesh]);
    let ground_rows = rows_of(&wet.layers, &[ground]);
    checks.check(
        "the surface is one model draw",
        mesh >= 0 && surface_rows.len() == 1,
        (&surface_rows, mesh),
    );
    checks.check(
        "...drawn over the ground it covers",
        surface_rows
            .first()
            .zip(ground_rows.first())
            .is_some_and(|(surface, ground)| surface > ground),
        (&surface_rows, &ground_rows),
    );

    // A dry field draws no surface at all: `clear` is exactly neutral, which is what
    // keeps the weather's own gait assertions honest.
    rain(&mut harness, 0.0);
    let dry = water(&mut harness);
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("one dry frame");
    let clear = harness.observe().expect("observe");
    checks.check(
        "a dry field draws nothing",
        dry["on"].as_bool() == Some(false) && rows_of(&clear.layers, &[mesh]).is_empty(),
        (&dry, &clear.layers),
    );

    checks.finish();
}

#[test]
fn the_surface_has_waves() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // The chop is a tuning leaf like any other, and it is clamped like one.
    let wave = harness.eval("tuningGet('water.wave')").expect("water.wave");
    let wide = harness
        .eval("tuningSet('water.wave.scale', 999)")
        .expect("a clamp");
    checks.check(
        "the chop is a tree of its own",
        wave["height"].as_f64().is_some_and(|h| h > 0.0)
            && wave["scale"].as_f64().is_some_and(|s| s > 0.0)
            && wave["speed"].as_f64().is_some()
            && wave["wind"].as_f64().is_some(),
        &wave,
    );
    checks.check(
        "...and its knobs are clamped like the rest of the tree",
        wide.as_f64().is_some_and(|s| s <= 8.0),
        wide,
    );
    // Put it back: the harness is this case's own, but the read below is the tree's.
    harness
        .eval("tuningSet('water.wave.scale', 0.6)")
        .expect("restore");

    // Where the chop actually lives. There is no GPU here, so the *source* is what a case
    // can hold: the height field's normal and the fresnel both have to be in it.
    let source = harness.observe().expect("observe").water_fs;
    checks.check(
        "the surface shades from a wave height field",
        source.contains("waterNormal")
            && source.contains("uniform vec3 waterWave")
            && source.contains("uniform float waterTime")
            && source.contains("uniform vec3 waterWind"),
        source.len(),
    );
    checks.check(
        "...and mixes its reflection in by the fresnel term",
        source.contains("uniform float waterFresnel")
            && source.contains("reflect(-viewDir, n)")
            && source.contains("color = mix(color, sky, fres)"),
        source.len(),
    );

    // ...and the frame pushes them, under the names the source declares -- the one thing a
    // stub with no GL can say about a uniform, since a misspelling is silent on both sides
    // (the stub invents an id where a real engine returns -1 and drops the write).
    harness.command("lighting on").expect("lighting on");
    rain(&mut harness, 1.0);
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("one wet frame");
    let obs = harness.observe().expect("observe");
    checks.check(
        "the clock and the fresnel reach the program",
        obs.uniform_values.contains_key("waterTime")
            && obs
                .uniform_values
                .get("waterFresnel")
                .is_some_and(|f| *f > 0.0),
        (
            &obs.uniform_values.get("waterTime"),
            &obs.uniform_values.get("waterFresnel"),
        ),
    );
    checks.check(
        "the chop's own numbers reach it, and the gust is a share",
        obs.uniform_vectors
            .get("waterWave")
            .is_some_and(|w| w.len() == 3 && w[1] > 0.0)
            && obs
                .uniform_vectors
                .get("waterWind")
                .is_some_and(|w| w.len() == 3 && w[2] >= 0.0 && w[2] <= 1.0),
        (
            &obs.uniform_vectors.get("waterWave"),
            &obs.uniform_vectors.get("waterWind"),
        ),
    );
    checks.check(
        "the reflection dims with the sky rather than with the sun alone",
        obs.uniform_vectors
            .get("waterSky")
            .is_some_and(|s| s.len() == 3 && s.iter().all(|c| *c >= 0.0)),
        obs.uniform_vectors.get("waterSky"),
    );

    checks.finish();
}

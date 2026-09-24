//! The water table: the level the weather sets, and the pools it makes.
//!
//! M20a is the field and the level -- no draw -- so everything a test can hold is a
//! number. `sceneWater()` reports the level, how much of the grid is wet and where
//! the deepest point is; `waterDepthAt(x, z)` reports the depth under a point. The
//! field is a pure function of the ground, so these cases are about that ground:
//! rain pools in the hollows, a dry spell empties them exactly, the table walks
//! monotonically with the rain, and a crater -- a hole a blast put in the ground --
//! is just another basin the water pools in.
//!
//! The level is *derived* from the weather's `rainAmount`, never integrated over
//! time, which is what lets the two cases drive it with `rainAmount` directly: there
//! is no accumulator to age, so a value set and read in the same tick is the value
//! the frame would use.
//!
//! ```text
//! cargo test --profile fast -p harness --test water -- --nocapture
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

/// The lattice the window case samples. Two anchors one `TUNING.terrain.snap` apart -- the
/// step the grid takes as the goat walks -- share x `-48..24` and z `-144..-48`; this is
/// that band 12 m inside every edge, so no point on it is draining out of either window.
const SHARED_LO: (f64, f64) = (-36.0, -132.0);
const SHARED_HI: (f64, f64) = (12.0, -60.0);

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
/// mirroring client use, so the table is recomputed the way the frame does it. Nothing has
/// to age: the water's rise carries no memory at all (`waterStep` is the draining half).
fn rain(harness: &mut Harness, amount: f64) {
    harness
        .eval(&format!("rainAmount = {amount}"))
        .expect("set the rain");
    harness
        .call("updateWeatherEffects", &[])
        .expect("updateWeatherEffects");
}

/// Age the water by `seconds` of its own clock -- the frame's step, given whole. The table
/// drains on that clock rather than with the rain, so "the rain has stopped" is not yet
/// "the field is dry".
fn age(harness: &mut Harness, seconds: f64) {
    harness
        .call("waterStep", &[json!(seconds)])
        .expect("waterStep");
}

/// Long enough to settle the water onto the rain's own value whatever `wetDown` is: one step
/// past the time constant takes the follower *to* its target, and a case that walks the rain
/// *down* has no frame loop here to age it through (`waterStep` is the drain's only clock). A
/// fixed number would only be pinning today's default.
const SETTLE: f64 = 1.0e6;

/// The level the rain alone implies: set it, then let the water settle onto it whichever way
/// it has to move. `rain` on its own is enough for a *rise* -- the rise carries no memory --
/// but a fall waits on the water's own clock, so a case that walks the rain *down* has to
/// age it or it reads the shower before this one.
fn rain_settled(harness: &mut Harness, amount: f64) {
    rain(harness, amount);
    age(harness, SETTLE);
}

/// `flood <level>`, asserting it was accepted *and took*. A level is a signed height and
/// this field's water lives below zero, so a write that silently read as "off" is the
/// failure worth a check of its own.
fn flood(harness: &mut Harness, level: f64) {
    let reply = harness.command(&format!("flood {level}")).expect("flood");
    assert!(reply.starts_with("ok "), "{reply}");
    let forced = water(harness)["forced"].as_bool() == Some(true);
    assert!(forced, "flood {level} did not take");
}

fn flood_off(harness: &mut Harness) {
    let reply = harness.command("flood off").expect("flood off");
    assert!(reply.starts_with("ok "), "{reply}");
}

/// A JSON array of numbers as a flat list, NaN for anything that is not a number.
fn numbers(value: &Value) -> Vec<f64> {
    value
        .as_array()
        .map(|list| {
            list.iter()
                .map(|n| n.as_f64().unwrap_or(f64::NAN))
                .collect()
        })
        .unwrap_or_default()
}

/// The ground and the water's depth on the lattice [`SHARED_LO`]..[`SHARED_HI`], as two
/// lists in one order -- one read, so two windows can be compared point for point.
fn sample(harness: &mut Harness) -> (Vec<f64>, Vec<f64>) {
    let probe = format!(
        "(function () {{ const g = [], d = []; \
         for (let z = {}; z <= {}; z += 2) {{ \
         for (let x = {}; x <= {}; x += 2) {{ \
         g.push(terrainHeight(x, z)); d.push(waterDepthAt(x, z)); }} }} \
         return {{ g: g, d: d }}; }})()",
        SHARED_LO.1, SHARED_HI.1, SHARED_LO.0, SHARED_HI.0,
    );
    let read = harness.eval(&probe).expect("sample the shared band");
    (numbers(&read["g"]), numbers(&read["d"]))
}

/// Stand the goat at an anchor and read the shared band from the window that makes.
fn window_at(harness: &mut Harness, x: f64, z: f64) -> (Vec<f64>, Vec<f64>) {
    harness.command(&format!("pos {x} {z}")).expect("pos");
    harness
        .call("terrainEnsure", &[json!(x), json!(z)])
        .expect("terrainEnsure");
    sample(harness)
}

#[test]
fn the_table_makes_pools() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    let loaded = water(&mut harness);
    // The band is the world's, but a window can hold water only where its own ground stands
    // under it -- the same "is there relief to pool in" the measured spills used to answer,
    // asked of the declared band instead.
    checks.check(
        "the field has relief to pool in",
        loaded["high"].as_f64().unwrap_or(f64::NAN) > loaded["ground"].as_f64().unwrap_or(f64::NAN),
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
    rain_settled(&mut harness, 0.0);
    let empty = water(&mut harness);
    checks.check(
        "a dry spell leaves the ground dry",
        empty["wet"].as_u64() == Some(0) && empty["deepest"].as_f64() == Some(0.0),
        &empty,
    );

    // Drizzle below `seep` is still dry; the knob is what keeps a damp morning from
    // flooding the field.
    rain_settled(&mut harness, 0.04);
    let damp = water(&mut harness);
    checks.check(
        "rain below `seep` is still dry",
        damp["wet"].as_u64() == Some(0),
        &damp,
    );

    // A downpour brings the table up over the hollows, so there is water somewhere and a
    // deepest point that is deeper than nothing.
    rain_settled(&mut harness, 1.0);
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
    // rain-to-level mapping is, and the one the drift-free derivation depends on -- read
    // *settled*, since the rain walked down through a downpour to get here (`rain_settled`).
    rain_settled(&mut harness, 0.3);
    let lowish = water(&mut harness)["level"].as_f64().unwrap_or(f64::NAN);
    rain_settled(&mut harness, 0.7);
    let highish = water(&mut harness)["level"].as_f64().unwrap_or(f64::NAN);
    rain_settled(&mut harness, 1.0);
    let full = water(&mut harness)["level"].as_f64().unwrap_or(f64::NAN);
    checks.check(
        "more rain means a higher table",
        lowish < highish && highish <= full,
        (lowish, highish, full),
    );

    // ...and a higher table covers more ground: a level at the bottom wets less than
    // one at the top.
    rain_settled(&mut harness, 0.35);
    let narrow = water(&mut harness)["wet"].as_u64().unwrap_or(0);
    rain_settled(&mut harness, 1.0);
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
    // the mesh is the whole of making the hole; the water follows from the ground, which
    // the rebuild re-measures. The `flood` level survives the rebuild, so the extra depth
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
    // ...and the report is the water's own depth now, not a wading cap held over it: at the
    // dish it is exactly the table minus the ground the crater left. The level is the one
    // `flood` was handed rather than the report's, which rounds to three places. The cap the
    // old check asserted here is `maxDepth`, and it is the *wading* one -- what the drag
    // reads, not how deep a pool is allowed to stand.
    let level = ground + 0.05;
    let floor = f64_of(
        harness
            .eval(&format!("terrainHeight({CRATER_X}, {CRATER_Z})"))
            .expect("terrainHeight"),
    );
    checks.check(
        "the dish holds the table minus the ground it left",
        (after - (level - floor)).abs() < 1e-6,
        (after, level, floor),
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
        "water: ground {} floor {} high {} quads {} of {}",
        surface["ground"],
        surface["floor"],
        surface["high"],
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
    // The band is the promise now. A pool may stand deeper than the goat can wade -- the
    // ceiling that used to hold the *level* down is gone, and `maxDepth` is the wading cap
    // alone (drag, splash, HUD). What holds instead is that the table never leaves the band
    // it declared, whatever the rain does and wherever the goat stands.
    let (floor, high) = (
        f64_of(flooded["floor"].clone()),
        f64_of(flooded["high"].clone()),
    );
    checks.check(
        "...and the table never leaves the band it declared",
        flooded["level"]
            .as_f64()
            .is_some_and(|level| level <= high + 1e-6 && level >= floor - 1e-6),
        (&flooded["level"], &floor, &high),
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
    // keeps the weather's own gait assertions honest. The rain stopping is not the field
    // dries, though -- the table falls on the water's own clock -- so the water is aged
    // far past `TUNING.water.wetDown` first, which is how a spell of clear weather arrives at
    // the same place.
    rain(&mut harness, 0.0);
    age(&mut harness, SETTLE);
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
    // The chop has to be *sampled* honestly as well as drawn: a normal field whose phase one
    // pixel cannot resolve reads as tearing across the water rather than as chop, and what
    // says so is the fade on the screen-space phase.
    checks.check(
        "...and the chop is faded where a pixel cannot resolve it",
        source.contains("fwidth(p1)") && source.contains("smoothstep(0.5, 1.6, phase)"),
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

#[test]
fn the_goat_wades() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    harness.command("lighting on").expect("lighting on");

    // ---- nothing on dry ground, and *exactly* nothing ------------------------
    // The drag is gated on the depth rather than on the weather, so a `clear` frame on
    // dry ground is the frame it has always been: the factors are 1 to the last bit, the
    // grass is not culled, and the weather line gains no water.
    rain(&mut harness, 0.0);
    let dry = water(&mut harness);
    checks.check(
        "dry ground is exactly neutral",
        dry["on"].as_bool() == Some(false)
            && f64_of(harness.eval("waterSpeedFactor()").expect("speed")) == 1.0
            && f64_of(harness.eval("waterDrainFactor()").expect("drain")) == 1.0,
        (&dry["on"], harness.eval("waterSpeedFactor()").ok()),
    );
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("one dry frame");
    let clear = water(&mut harness);
    let clear_text = harness.eval("weatherText").expect("weatherText");
    checks.check(
        "a dry field culls no grass and shows no water line",
        clear["culled"].as_u64() == Some(0) && !clear_text.as_str().unwrap_or("").contains("water"),
        (&clear["culled"], &clear_text),
    );

    // ---- wade: put the goat in the deepest pool -------------------------------
    // The rain is what raises the table here rather than `flood`: the window's *lowest*
    // ground is where the field drains, so a table a quarter of a metre above it ponds
    // nothing at all. A downpour is the level the other cases already prove pools, and the
    // goto is the deepest one it made.
    rain(&mut harness, 1.0);
    let flooded = water(&mut harness);
    checks.check(
        "the rain makes a pool to stand in",
        flooded["deepest"].as_f64().is_some_and(|d| d > 0.0),
        &flooded,
    );
    let (dx, dz) = (
        f64_of(flooded["deepX"].clone()),
        f64_of(flooded["deepZ"].clone()),
    );
    harness.command(&format!("pos {dx} {dz}")).expect("pos");
    let wading = water(&mut harness);
    checks.check(
        "the goat standing in a pool is slowed and works harder",
        wading["goatDepth"].as_f64().is_some_and(|d| d > 0.0)
            && f64_of(harness.eval("waterSpeedFactor()").expect("speed")) < 1.0
            && f64_of(harness.eval("waterDrainFactor()").expect("drain")) > 1.0,
        (
            &wading["goatDepth"],
            harness.eval("waterSpeedFactor()").ok(),
        ),
    );

    // ...and the frame it steps in throws a splash and lays a wake ring, the grass inside
    // the pool is skipped, and the water reaches the weather line. The wake is asserted
    // through the uniform the shader reads, which is the only place it can be seen here.
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("one wet frame");
    let obs = harness.observe().expect("observe");
    let wet = water(&mut harness);
    let ring = obs.uniform_vectors.get("waterRipple0").cloned();
    checks.check(
        "stepping in throws a splash and a ring",
        wet["splashes"].as_u64().is_some_and(|n| n > 0)
            && wet["ripples"].as_u64().is_some_and(|n| n > 0)
            && ring.as_ref().is_some_and(|r| r.len() == 4 && r[3] > 0.0),
        (&wet["splashes"], &wet["ripples"], &ring),
    );
    checks.check(
        "...the grass in the pool is culled",
        wet["culled"].as_u64().is_some_and(|n| n > 0),
        wet["culled"].clone(),
    );
    let wade_text = f64_of(
        harness
            .eval("waterDepthAt(goat.px, goat.pz)")
            .expect("depth"),
    );
    let line = harness.eval("weatherText").expect("weatherText");
    checks.check(
        "...and the HUD says so",
        wade_text > 0.0 && line.as_str().unwrap_or("").contains("water"),
        (&line, wade_text),
    );

    // ---- and it is dry again when the water goes -----------------------------
    // Aged rather than merely rainless: the table holds on after the shower, which is the
    // feature (see `the_water_outlives_the_rain`), and it has to be *exactly* dry at the
    // end of it or the factors do not come back to 1 to the last bit.
    rain(&mut harness, 0.0);
    age(&mut harness, SETTLE);
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("a dry frame");
    let after = water(&mut harness);
    checks.check(
        "taking the water away puts it all back",
        after["on"].as_bool() == Some(false)
            && f64_of(harness.eval("waterSpeedFactor()").expect("speed")) == 1.0
            && after["culled"].as_u64() == Some(0),
        (&after["on"], &after["culled"]),
    );

    checks.finish();
}

#[test]
fn the_goat_does_not_sleep_in_the_water() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // A goat does not sleep in the water, and the question is one question: the mode is
    // refused where the goat stands in a pool, and a goat the water *reaches* is woken --
    // both `waterInWater`, the HUD's own line, so the key, this verb, the sleep that
    // exhaustion forces and a mod's `setMode` cannot disagree about it.
    rain(&mut harness, 1.0);
    let flooded = water(&mut harness);
    let (dx, dz) = (
        f64_of(flooded["deepX"].clone()),
        f64_of(flooded["deepZ"].clone()),
    );
    harness.command(&format!("pos {dx} {dz}")).expect("pos");
    let in_water = harness
        .eval("waterInWater(goat.px, goat.pz)")
        .expect("in water");
    checks.check(
        "the goat is standing in the HUD's own water",
        in_water == json!(true),
        &in_water,
    );

    let refused = harness.command("sleep").expect("sleep");
    let stayed = command_json(&mut harness, "state")["mode"].clone();
    checks.check(
        "a goat in the water is not allowed to sleep",
        refused == "error cannot sleep in the water" && stayed != json!("sleep"),
        (&refused, &stayed),
    );

    // Dry ground, *found* rather than guessed: the table is the weather's and the window
    // is the goat's, so the first point on a lattice the water does not reach is the
    // honest way to ask for one.
    let dry = harness
        .eval(
            "(function () { for (let z = -24; z <= 24; z += 1) { \
             for (let x = -24; x <= 24; x += 1) { \
             if (!waterInWater(x, z)) return [x, z]; } } return null; })()",
        )
        .expect("dry ground");
    let (gx, gz) = (f64_of(dry[0].clone()), f64_of(dry[1].clone()));
    harness.command(&format!("pos {gx} {gz}")).expect("pos");
    // The energy is taken down first, and it is not decoration: a goat at its cap sleeps
    // for a fraction of a second whatever the water does (`sleepEnergyRecover` is 12 a
    // second), and the case is about the water's wake rather than the recovery's.
    harness.eval("stats.energy = 10").expect("energy");
    let slept = harness.command("sleep").expect("sleep");
    let asleep = command_json(&mut harness, "state")["mode"].clone();
    checks.check(
        "...and the same verb works on dry ground",
        slept == "ok sleep" && asleep == json!("sleep"),
        (&slept, &asleep),
    );

    // A frame asleep and still dry, so the wake that follows is the water's: the sleep
    // also ends on its own at the cap, and on any input, and neither has moved here.
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("a dry frame");
    let still = command_json(&mut harness, "state")["mode"].clone();
    checks.check(
        "the goat stays asleep while the ground is dry",
        still == json!("sleep"),
        (&still, harness.eval("stats.energy").ok()),
    );

    // ...and the rain arrives under it. The level is forced rather than waited for -- the
    // table under a goat is the weather's business and this case is about the rule -- and
    // `flood` lifts exactly the level the rain would.
    let ground = f64_of(
        harness
            .eval(&format!("terrainHeight({gx}, {gz})"))
            .expect("ground"),
    );
    flood(&mut harness, ground + 0.3);
    harness.reset_frame().expect("a frame to drive");
    harness
        .call("sceneFrame", &[])
        .expect("the frame the water arrives");
    let woken = command_json(&mut harness, "state")["mode"].clone();
    let at_wake = harness
        .eval("waterInWater(goat.px, goat.pz)")
        .expect("in water");
    checks.check(
        "...and a pool rising under a sleeping goat wakes it",
        at_wake == json!(true) && woken != json!("sleep"),
        (&woken, &at_wake),
    );

    checks.finish();
}

#[test]
fn the_herd_does_not_sleep_in_the_water() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    // The herd is put back, and that is not a detail to skip: `run` ends by closing the
    // window, and `sceneShutdown` is where `unloadBots` is called, so every case in this
    // file starts next to an *empty* meadow however many goats the load built.
    harness.eval("setHerdSize(7)").expect("the herd");

    // The herd are goats too, and the gate is the player's own -- `waterInWater`, the HUD's
    // line. It is legitimate in a bot's *AI* for the reason `net.js` gives: the host is the
    // one simulating the herd, so a peer's own table never decides what a bot does, and the
    // client is handed the host's modes.
    rain(&mut harness, 1.0);
    let flooded = water(&mut harness);
    let (dx, dz) = (
        f64_of(flooded["deepX"].clone()),
        f64_of(flooded["deepZ"].clone()),
    );
    checks.check(
        "the rain makes a pool to put the herd in",
        flooded["deepest"].as_f64().is_some_and(|d| d > 0.0),
        &flooded,
    );

    // The *plan* is sampled rather than waited for, and that is the shape the roll wants:
    // a bot re-plans when its timer runs out and only one roll in ten dozes, so a case that
    // waited for one of seven bots to pick this basin would be testing its own random stream
    // and not the water. Calling `botNewAction` in a loop is the same roll a frame makes,
    // four hundred times over, with the bot standing in the pool.
    let rolls = |harness: &mut Harness| -> (f64, f64) {
        let read = harness
            .eval(&format!(
                "(function () {{ const b = BOTS[0]; b.x = {dx}; b.z = {dz}; \
                 const wet = waterInWater(b.x, b.z); let slept = 0; \
                 for (let i = 0; i < 400; i++) {{ \
                 b.mode = 'idle'; b.timer = 0; botNewAction(b); \
                 if (b.mode === 'sleep') slept += 1; }} \
                 return [wet ? 1 : 0, slept]; }})()",
            ))
            .expect("the plans");
        // `[wet, slept]`, in that order -- which is the order the check below wants them in
        // and not the order they read as names in.
        (f64_of(read[1].clone()), f64_of(read[0].clone()))
    };
    let (wet_slept, in_the_pool) = rolls(&mut harness);
    checks.check(
        "the herd's own plans, rolled standing in the pool, are never a sleep",
        in_the_pool == 1.0 && wet_slept == 0.0,
        (in_the_pool, wet_slept),
    );

    // ...and the same roll on ground the water has left does doze, which is what makes the
    // check above mean anything: the branch it samples is live, and the water is the whole of
    // the difference between them.
    rain(&mut harness, 0.0);
    age(&mut harness, SETTLE);
    let (dry_slept, dry_pool) = rolls(&mut harness);
    checks.check(
        "...while the same plans on dry ground put it to sleep",
        dry_pool == 0.0 && dry_slept > 0.0,
        (dry_pool, dry_slept),
    );

    // The water is put back before the last half, because the check above took it away: the
    // rise carries no memory at all (`waterUpdate`), so one call is a pool again.
    rain(&mut harness, 1.0);

    // The other half of the rule, which is what an exhausted goat meets: a bot already asleep
    // when the water arrives gets up. The plan above is refused; this is the sleep that had
    // already started, and it ends on the frame that finds it.
    let asleep = harness
        .eval(&format!(
            "(function () {{ const b = BOTS[0]; b.x = {dx}; b.z = {dz}; \
             b.mode = 'sleep'; b.timer = 5; return [waterInWater(b.x, b.z), b.mode]; }})()",
        ))
        .expect("put to sleep");
    checks.check(
        "a bot put to sleep in the pool is asleep before the frame",
        asleep[0] == json!(true) && asleep[1] == json!("sleep"),
        &asleep,
    );
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("a frame of herd");
    let after = harness.eval("BOTS[0].mode").expect("mode");
    checks.check("...and is not, after it", after != json!("sleep"), &after);

    checks.finish();
}

#[test]
fn a_stride_in_the_water_throws_a_splash() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    harness.command("lighting on").expect("lighting on");

    // The goat's splash is thrown from `waterActorStep`, which runs off the draw -- so the
    // lit branch is part of the set-up -- and `sceneWater().thrown` counts splashes
    // *thrown*, which is the only way a case can tell an entry from a footfall (the drops
    // themselves come and go in `SPLASH_LIFE`). The herd is not emptied here for the
    // reason the herd case below has to *rebuild* it: `run` ends in `sceneShutdown`, which
    // unloads the bots, so the meadow this case measures is already the goat's alone.
    rain(&mut harness, 1.0);
    let flooded = water(&mut harness);
    let (dx, dz) = (
        f64_of(flooded["deepX"].clone()),
        f64_of(flooded["deepZ"].clone()),
    );
    let thrown = |harness: &mut Harness| water(harness)["thrown"].as_u64().unwrap_or(0);

    // ---- one step in ---------------------------------------------------------
    harness.command(&format!("pos {dx} {dz}")).expect("pos");
    let before = thrown(&mut harness);
    harness.reset_frame().expect("a frame to drive");
    harness
        .call("sceneFrame", &[])
        .expect("the frame it steps in");
    let entered = thrown(&mut harness);
    checks.check(
        "stepping into a pool throws a splash",
        entered > before,
        (before, entered),
    );

    // ---- and standing still throws nothing ------------------------------------
    // The wake is laid by distance travelled rather than by the frame, so a goat grazing
    // in a pool is not a fountain.
    harness.reset_frame().expect("a frame to drive");
    harness
        .call("sceneFrame", &[])
        .expect("a frame on the spot");
    let stood = thrown(&mut harness);
    checks.check(
        "...but standing in one throws nothing",
        stood == entered,
        (entered, stood),
    );

    // ---- and walking through it throws them ------------------------------------
    // *Walking* is what this rule is about, and walking is not a teleport: the gate is
    // `RIPPLE_STEP` (0.45 m) of travel, and a goat covers about two centimetres of that in a
    // frame. So the goat is walked in small steps -- a first version of this case moved it a
    // whole stride in one frame, which is the one thing a frame-vs-ring comparison would also
    // pass, and that is why it passed while a walking goat threw nothing at all.
    let reach = harness
        .eval(&format!(
            "(function () {{ let last = null; for (let d = 0.6; d <= 4; d += 0.1) {{ \
             if (waterDepthAt({dx} + d, {dz}) > 0.06) last = [{dx} + d, {dz}, d]; }} \
             return last; }})()",
        ))
        .expect("a walk inside the pool");
    checks.check(
        "there is a stride of water to walk along",
        reach.is_array() && f64_of(reach[2].clone()) >= 0.9,
        &reach,
    );
    let (rx, rz, span) = (
        f64_of(reach[0].clone()),
        f64_of(reach[1].clone()),
        f64_of(reach[2].clone()),
    );
    let (mut dry_steps, mut kept) = (0u32, 0u32);
    for step in 1..=30u32 {
        let t = f64::from(step) / 30.0;
        let (wx, wz) = (dx + (rx - dx) * t, dz + (rz - dz) * t);
        harness.command(&format!("pos {wx} {wz}")).expect("pos");
        harness.reset_frame().expect("a frame to drive");
        harness.call("sceneFrame", &[]).expect("a walking frame");
        if depth(&mut harness, wx, wz) > 0.04 {
            kept += 1;
        } else {
            dry_steps += 1;
        }
    }
    let walked = thrown(&mut harness);
    checks.check(
        "...and walking it throws one per stride",
        dry_steps == 0 && walked >= stood + 2,
        (dry_steps, kept, stood, walked, span),
    );

    checks.finish();
}

#[test]
fn a_bot_walking_the_pool_throws_a_splash() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    harness.command("lighting on").expect("lighting on");
    // `run` ends in `sceneShutdown`, which unloads the herd: the bots are put back here, and
    // this case is the herd's, so the goat is not moved -- it stays where it loaded, which is
    // also the window the pool is read from. **One** bot, not seven: the others wander in and
    // out of the pool on their own, and an arrival of theirs is a splash this count would
    // take for the walk's.
    harness.eval("setHerdSize(1)").expect("a bot");

    // The herd's half of the splash rule, and its own mark: the bots lay no rings
    // (`RIPPLE_MAX` is three slots), so what a bot crossing a pool throws is *drops*, one
    // set per `RIPPLE_STEP` of its own travel. The goat's walk is the other case's: keeping
    // them apart is what makes either count mean something.
    rain(&mut harness, 1.0);
    let flooded = water(&mut harness);
    let (dx, dz) = (
        f64_of(flooded["deepX"].clone()),
        f64_of(flooded["deepZ"].clone()),
    );
    // A stride of *contiguous* water to cross, measured from the deepest point rather than
    // assumed: the walk below must not reach the pool's edge, or an arrival would be counted
    // as a footfall.
    let run = f64_of(
        harness
            .eval(&format!(
                "(function () {{ let run = 0; for (let d = 0.1; d <= 3; d += 0.1) {{ \
                 if (waterDepthAt({dx} + d, {dz}) > 0.06) run = d; else break; }} \
                 return run; }})()",
            ))
            .expect("a walk in the pool"),
    );
    checks.check("there is water for a bot to walk in", run >= 1.0, run);

    // The bot arrives from wherever the herd built it, and its height above the ground is
    // *eased* rather than set, so the frame it is moved into the pool is not reliably the
    // frame it counts as wet. The splash that arrival throws is therefore given its own
    // frames here, and `wet` in the report is what says it has happened -- without that the
    // arrival lands inside the count below and passes for a footfall, which is exactly how a
    // first version of this case passed on a mark that never fired while walking.
    harness
        .eval(&format!(
            "(function () {{ const b = BOTS[0]; b.x = {dx}; b.z = {dz}; \
             b.mode = 'idle'; b.timer = 9; }})()",
        ))
        .expect("a bot to walk");
    for _ in 0..30 {
        harness.reset_frame().expect("a frame to drive");
        harness.call("sceneFrame", &[]).expect("a settling frame");
    }
    let settled = harness
        .eval("[BOTS[0].wet, BOTS[0].py, waterInWater(BOTS[0].x, BOTS[0].z)]")
        .expect("the bot");
    let goat_before = harness.eval("goat.px + goat.pz").expect("the goat");
    let before = water(&mut harness)["thrown"].as_u64().unwrap_or(0);

    // ...and then the bot is *walked*, ten centimetres at a time, which is what a footfall is
    // made of: a bot's own frame of travel is a hundredth of `RIPPLE_STEP`, so the step is
    // taken by hand here the way the goat is `pos`ed in the case above.
    let steps = (run * 10.0).floor().min(30.0) as u32;
    for step in 1..=steps {
        let wx = dx + 0.1 * f64::from(step);
        harness
            .eval(&format!(
                "(function () {{ const b = BOTS[0]; b.x = {wx}; b.z = {dz}; b.timer = 9; }})()",
            ))
            .expect("a step");
        harness.reset_frame().expect("a frame to drive");
        harness.call("sceneFrame", &[]).expect("a walking frame");
    }
    let after = water(&mut harness)["thrown"].as_u64().unwrap_or(0);
    // The count is the bot's: the goat never moved (a shove would be a splash of its own, and
    // the two of them are metres apart).
    let goat_after = harness.eval("goat.px + goat.pz").expect("the goat");
    checks.check(
        "a bot walking through the pool throws its own splashes",
        settled[0] == json!(true) && after >= before + 2 && goat_after == goat_before,
        (
            before,
            after,
            run,
            steps,
            &settled,
            &goat_before,
            &goat_after,
        ),
    );

    checks.finish();
}

#[test]
fn a_crater_patches_the_water_and_the_bake_exactly() {
    // A rebuild over the rectangles the ground changed in -- one the terrain passes down
    // (`terrainBuildRects`) -- has to leave the mesh and the bake *the same bytes* a
    // whole-grid rebuild would. The patch path writes one number a vertex (the height: `x`,
    // `z`, the normal and the colour are the anchor's) and splices one run of pixels per row
    // of the bake, and both are places where "almost the same" arrives as a surface standing
    // at the wrong height or a reflection marching a slope the ground does not have. Nothing
    // else in this file can hold it: the depths the other cases read come from `T_H`, which
    // both paths share.
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // The water's own bytes: the mesh's three channels, the index list, and the bake's pixels
    // -- summed rather than compared, because they are 20 000 numbers and one string, and the
    // harness moves JSON. A rolled sum of every element is enough to catch a vertex missed, a
    // run spliced at the wrong offset, or a cut that took a different quad.
    let digest = |harness: &mut Harness| -> Vec<f64> {
        numbers(
            &harness
                .eval(
                    "(function () { \
                     let v = 0, n = 0, c = 0, i = 0, b = 0; \
                     for (let k = 0; k < W_VERTS.length; k++) v = (v * 31 + Math.round(W_VERTS[k] * 1000)) % 2147483647; \
                     for (let k = 0; k < W_NORM.length; k++) n = (n * 31 + Math.round(W_NORM[k] * 1000)) % 2147483647; \
                     for (let k = 0; k < W_COL.length; k++) c = (c * 31 + W_COL[k]) % 2147483647; \
                     for (let k = 0; k < W_IDX.length; k++) i = (i * 31 + W_IDX[k]) % 2147483647; \
                     for (let k = 0; k < waterBakeHex.length; k++) b = (b * 31 + waterBakeHex.charCodeAt(k)) % 2147483647; \
                     return [v, n, c, i, b, W_IDX.length, waterBakeHex.length, waterQuads, waterMapFloor, waterMapRange]; \
                     })()",
                )
                .expect("the water's bytes"),
        )
    };
    // ...and the expensive answer to compare it with: the whole grid, rebuilt.
    let whole = |harness: &mut Harness| {
        harness
            .eval("terrainBuildRects([{ i0: 0, i1: T_N - 1, j0: 0, j1: T_N - 1 }])")
            .expect("a whole-grid rebuild");
    };

    let before = digest(&mut harness);
    whole(&mut harness);
    let settled = digest(&mut harness);
    checks.check(
        "a whole-grid rebuild is a fixpoint of itself",
        settled == before,
        (&settled, &before),
    );

    // A bang cuts a hole, which is the ground change a player makes most often -- and the
    // next frame's `terrainEnsure` flushes it as a patch. Two holes, in the two places that
    // choose the bake's path: the lowest ground the window holds, where the dish lowers the
    // field and has to *widen* the span (every texel re-encoded, so the bake is whole), and a
    // middling one, whose dish bottoms out above that new low and whose lip stays under the
    // field's ceiling -- which is the patch path, and what a crater's healing steps take for
    // the rest of their four minutes. (A hole on the *highest* ground is no good for this: a
    // dish's lip is 0.12 m of ground it raises, so that one widens the span too.)
    let low = harness
        .eval(
            "(function () { let best = null, lo = Infinity; \
             for (let z = -44; z <= 44; z += 2) { \
             for (let x = -44; x <= 44; x += 2) { \
             const g = terrainHeight(x, z); if (g < lo) { lo = g; best = [x, z]; } } } \
             return best; })()",
        )
        .expect("the lowest ground");
    let mid = harness
        .eval(
            "(function () { let lo = Infinity, hi = -Infinity; \
             for (let z = -44; z <= 44; z += 2) { \
             for (let x = -44; x <= 44; x += 2) { \
             const g = terrainHeight(x, z); if (g < lo) lo = g; if (g > hi) hi = g; } } \
             for (let z = -44; z <= 44; z += 2) { \
             for (let x = -44; x <= 44; x += 2) { \
             const g = terrainHeight(x, z); \
             if (g > lo + 0.6 && g < hi - 0.2) return [x, z, lo, hi]; } } \
             return null; })()",
        )
        .expect("a middling spot");
    let (lx, lz) = (f64_of(low[0].clone()), f64_of(low[1].clone()));
    let (hx, hz) = (f64_of(mid[0].clone()), f64_of(mid[1].clone()));
    checks.check(
        "there is ground between the floor and the ceiling to dig in",
        mid.is_array(),
        &mid,
    );

    harness
        .eval(&format!("goats.explosions.blast({lx}, {lz}, \"mine\")"))
        .expect("a bang in the low ground");
    let whole_before = water(&mut harness)["bakeWhole"].as_u64().unwrap_or(0);
    harness.reset_frame().expect("a frame to drive");
    harness
        .call("sceneFrame", &[])
        .expect("the frame the patch lands in");
    let patched = digest(&mut harness);
    let whole_after = water(&mut harness)["bakeWhole"].as_u64().unwrap_or(0);
    checks.check(
        "the crater moved the water's mesh",
        patched != before,
        (&patched, &before),
    );
    // ...and it lowered the field's floor, so this bake is whole: a span that widens
    // invalidates every texel already built, which is the one thing a patch may not do.
    checks.check(
        "...a hole that lowers the ground re-bakes the bake whole",
        whole_after > whole_before,
        (whole_before, whole_after, lx, lz),
    );
    whole(&mut harness);
    let rebuilt = digest(&mut harness);
    checks.check(
        "...and the patched mesh and bake are what the whole rebuild is",
        rebuilt == patched,
        (&patched, &rebuilt),
    );

    harness
        .eval(&format!("goats.explosions.blast({hx}, {hz}, \"mine\")"))
        .expect("a bang on the high ground");
    let rect_before = water(&mut harness)["bakeRect"].as_u64().unwrap_or(0);
    harness.reset_frame().expect("a frame to drive");
    harness
        .call("sceneFrame", &[])
        .expect("the frame the patch lands in");
    let spliced = digest(&mut harness);
    let rect_after = water(&mut harness)["bakeRect"].as_u64().unwrap_or(0);
    checks.check(
        "a patch inside the span splices the bake instead of rebuilding it",
        spliced != patched && rect_after > rect_before,
        (rect_before, rect_after, hx, hz),
    );
    whole(&mut harness);
    let whole_again = digest(&mut harness);
    checks.check(
        "...and a spliced bake is what the whole rebuild is, to the byte",
        whole_again == spliced,
        (&spliced, &whole_again),
    );

    checks.finish();
}

#[test]
fn the_table_is_the_same_in_every_window() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    rain(&mut harness, 1.0);

    // Walk a line of anchors east with the rain hard on, the way a player wanders. The table
    // is the *world's* now -- declared in `TUNING.water` -- so one rain is one level in all
    // nine windows, and what changes between them is only the ground each one happens to
    // hold. This case used to ask the opposite question ("does every window hold water?"),
    // which could only be answered by giving every window its own table, and that is exactly
    // what made a pool blink out one step away and come back on the step back.
    let mut levels: Vec<f64> = Vec::new();
    let mut wrong_on: Vec<f64> = Vec::new();
    let mut wet_anywhere = 0u64;
    for i in 0..9 {
        let x = -96.0 + 24.0 * i as f64;
        harness.command(&format!("pos {x} -96")).expect("pos");
        harness
            .call("terrainEnsure", &[json!(x), json!(-96.0)])
            .expect("terrainEnsure");
        let f = water(&mut harness);
        let wet = f["wet"].as_u64().unwrap_or(0);
        wet_anywhere += wet;
        levels.push(f64_of(f["level"].clone()));
        if f["on"].as_bool() != Some(wet > 0) {
            wrong_on.push(x);
        }
    }
    let first = levels.first().copied().unwrap_or(f64::NAN);
    checks.check(
        "one rain is one level, wherever the goat stands",
        levels.iter().all(|level| (level - first).abs() < 1e-9),
        &levels,
    );
    // `on` is the "is there anything to draw" bit, and with the table the world's it is
    // exactly "does this window hold water": something is wet iff the table clears the
    // window's lowest ground, which is the test `waterUpdate` makes.
    checks.check(
        "...and every window's `on` says whether it holds water",
        wrong_on.is_empty(),
        &wrong_on,
    );
    checks.check(
        "...with water under the line somewhere to make it real",
        wet_anywhere > 0,
        wet_anywhere,
    );

    checks.finish();
}

#[test]
fn the_water_at_a_fixed_point_is_the_same_from_two_windows() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    rain(&mut harness, 1.0);

    // The window follows the goat, so one world point gets read from two of them here: two
    // anchors one snap step apart, and a lattice of points well inside both. The water is a
    // fact about the *ground* -- the rain fills the hollows that ground has -- and the ground
    // does not move when the goat does, so two windows have to agree about every point they
    // share. They did not. The table was taken from the window's own extremes, so over this
    // one step the level moved 0.855 m, the wetted count went 50 to 30, and a point whose
    // ground and spill both windows agreed about to the last bit was 0.11 m under water in
    // one and dry in the other: a pool that vanished as the goat walked and came back on the
    // step back. The table is the world's now and this holds. Reading the ground the same way
    // is the control -- a window that disagrees about *that* is failing for a reason this
    // case is not about.
    let (a_ground, a_depth) = window_at(&mut harness, -24.0, -96.0);
    let (b_ground, b_depth) = window_at(&mut harness, 0.0, -96.0);

    checks.check(
        "both windows sampled the same points",
        !a_ground.is_empty()
            && a_ground.len() == a_depth.len()
            && b_ground.len() == b_depth.len()
            && a_ground.len() == b_ground.len(),
        (a_ground.len(), a_depth.len(), b_ground.len(), b_depth.len()),
    );

    let mut moved = 0usize;
    let mut wet = 0usize;
    let mut disagree = 0usize;
    let mut worst = 0.0f64;
    for ((ga, gb), (da, db)) in a_ground
        .iter()
        .zip(b_ground.iter())
        .zip(a_depth.iter().zip(b_depth.iter()))
    {
        if (ga - gb).abs() > 1e-6 {
            moved += 1;
        }
        if *da > 0.0 || *db > 0.0 {
            wet += 1;
            let gap = (da - db).abs();
            if gap > worst {
                worst = gap;
            }
            if gap > 1e-6 {
                disagree += 1;
            }
        }
    }
    checks.check("both windows stand on the same ground", moved == 0, moved);
    checks.check("the shared band has water in it to compare", wet > 0, wet);
    checks.check(
        "...and which window reads a point does not change the water at it",
        disagree == 0,
        (disagree, worst, wet),
    );

    checks.finish();
}

#[test]
fn the_water_outlives_the_rain() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // This case is about the *shape* of the drain -- that a shower's water outlives it and
    // then lets go exactly -- so it pins the time constant it describes rather than
    // borrowing whatever the tree happens to carry.
    harness
        .eval("tuningSet('water.wetDown', 100)")
        .expect("pin the drain");

    // It answers the rain at once -- no frame, no aging: the rise is the half of the water's
    // clock that carries no memory, and so the half that agrees between peers with nothing
    // between them.
    rain(&mut harness, 1.0);
    let full = water(&mut harness);
    checks.check(
        "the table is up the moment the rain is",
        full["on"].as_bool() == Some(true) && full["wetting"].as_f64() == Some(1.0),
        &full,
    );

    // ...and the rain stopping does not take it away. Five seconds in -- a twentieth of
    // `wetDown` -- most of it is still standing.
    rain(&mut harness, 0.0);
    age(&mut harness, 5.0);
    let damp = water(&mut harness);
    checks.check(
        "the rain stopping does not empty it",
        damp["on"].as_bool() == Some(true) && damp["deepest"].as_f64().is_some_and(|d| d > 0.2),
        &damp,
    );

    // ...and left alone it does drain, to the last bit: a rainless field is the field it
    // has always been, which is what the gait cases downstream of `clear` rely on.
    age(&mut harness, SETTLE);
    let dry = water(&mut harness);
    checks.check(
        "...and left alone it drains, exactly",
        dry["on"].as_bool() == Some(false)
            && dry["wetting"].as_f64() == Some(0.0)
            && f64_of(harness.eval("waterSpeedFactor()").expect("speed")) == 1.0,
        &dry,
    );

    checks.finish();
}

#[test]
fn the_reflection_is_a_setting() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // A quality level rather than a feel number: 0 is the sky the surface has always faked,
    // 1 the ground it bakes and marches, 2 the scene it renders mirrored. The middle one is
    // the default because it costs no pass and no state.
    let leaf = harness
        .eval("tuningGet('water.reflection')")
        .expect("water.reflection");
    checks.check(
        "the surface reflects the ground by default",
        leaf.as_f64() == Some(1.0),
        &leaf,
    );
    let wide = harness
        .eval("tuningSet('water.reflection', 9)")
        .expect("a clamp");
    checks.check(
        "...and the tier is clamped to the three there are",
        wide.as_f64() == Some(2.0),
        wide,
    );

    // The frame's answer is the promise, and on this build it can keep a wish of 2: the
    // engine has the render texture the mirror needs.
    let full = water(&mut harness);
    checks.check(
        "the frame reports the tier it is using",
        full["reflect"].as_i64() == Some(2) && full["tier"].as_i64() == Some(2),
        (&full["reflect"], &full["tier"]),
    );

    // The console's own spelling of the tiers -- which is the route the menu's combo box
    // takes as well, so the two cannot disagree about what "ground" means.
    harness
        .command("setting reflect sky")
        .expect("setting reflect");
    let none = water(&mut harness);
    checks.check(
        "...and `setting reflect` writes the leaf",
        none["reflect"].as_i64() == Some(0) && none["tier"].as_i64() == Some(0),
        (&none["reflect"], &none["tier"]),
    );
    harness
        .command("setting reflect ground")
        .expect("setting reflect");
    let ground = water(&mut harness);
    checks.check(
        "...and it can put the reflection back on the ground",
        ground["tier"].as_i64() == Some(1) && ground["heightTex"].as_i64().is_some_and(|t| t >= 0),
        (&ground["tier"], &ground["heightTex"]),
    );

    checks.finish();
}

#[test]
fn the_ground_is_baked_for_the_surface() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // The middle tier's whole cost is one texture, baked from the grid the terrain already
    // has and rebuilt whenever the mesh is -- so there is no pass to count, and the bake is
    // what a case can look at.
    let surface = water(&mut harness);
    checks.check(
        "the ground is baked for the surface to march",
        surface["tier"].as_i64() == Some(1)
            && surface["heightTex"].as_i64().is_some_and(|t| t >= 0),
        (&surface["tier"], &surface["heightTex"]),
    );
    checks.check(
        "...and the mirror waits for the tier that asks for it",
        surface["mirrors"].as_u64() == Some(0) && surface["mirror"].as_i64() == Some(-1),
        (&surface["mirror"], &surface["mirrors"]),
    );

    // The bake is bound where the shader reads it: material map 2 -- the sampler raylib
    // names `texture2`, beside the shadow map's map 1 -- and the stub records every bind
    // with its index, which is the only place a bind is visible without a GPU.
    let height = surface["heightTex"].as_i64().unwrap_or(-1);
    let obs = harness.observe().expect("observe");
    checks.check(
        "the bake is bound to the surface's second map",
        obs.model_texture_calls
            .iter()
            .any(|call| call == &vec![2, height]),
        (&obs.model_texture_calls, height),
    );

    // What the source does with it, which is the half a stub with no GL can hold.
    let source = obs.water_fs.clone();
    checks.check(
        "the surface declares the reflection's own source",
        source.contains("uniform sampler2D texture2")
            && source.contains("uniform vec3 waterMapA")
            && source.contains("uniform vec3 waterMapB")
            && source.contains("uniform float waterReflect")
            && source.contains("uniform vec2 waterScreen"),
        source.len(),
    );
    checks.check(
        "...and marches the reflected ray against it",
        source.contains("vec3 groundReflect(vec3 dir)")
            && source.contains("groundAt(")
            && source.contains("groundTintAt(")
            && source.contains("reflect(-viewDir, n)"),
        source.len(),
    );
    checks.check(
        "...and reads the mirror at the fragment's own screen position",
        source.contains("gl_FragCoord.xy / waterScreen"),
        source.len(),
    );

    // ...and the frame pushes the numbers under the names the source declares. A misspelling
    // is silent on both sides here -- the stub invents an id where a real engine returns -1
    // -- so the pair of checks is what says the uniform is real.
    harness.command("lighting on").expect("lighting on");
    rain(&mut harness, 1.0);
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("one wet frame");
    let wet = harness.observe().expect("observe");
    checks.check(
        "the tier and the bake's own frame reach the program",
        wet.uniform_values
            .get("waterReflect")
            .is_some_and(|t| *t == 1.0)
            && wet
                .uniform_vectors
                .get("waterMapA")
                .is_some_and(|m| m.len() == 3 && m[2] > 0.0)
            && wet
                .uniform_vectors
                .get("waterMapB")
                .is_some_and(|m| m.len() == 3 && m[1] > 0.0),
        (
            &wet.uniform_values.get("waterReflect"),
            &wet.uniform_vectors.get("waterMapA"),
            &wet.uniform_vectors.get("waterMapB"),
        ),
    );
    checks.check(
        "...and so does the viewport the mirror would be read through",
        wet.uniform_vectors
            .get("waterScreen")
            .is_some_and(|s| s.len() == 2 && s[0] > 0.0 && s[1] > 0.0),
        wet.uniform_vectors.get("waterScreen"),
    );

    checks.finish();
}

#[test]
fn the_mirror_pass_draws_the_world() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    harness.command("lighting on").expect("lighting on");

    // The top tier is the only one that costs a second scene submission, and it is the one
    // item in M20 that could move the frame's budget, so what a case can hold about it is
    // that the submission happens: exactly once a frame, and only when the tier asks and
    // there is water to reflect.
    rain(&mut harness, 1.0);
    harness
        .command("setting reflect mirror")
        .expect("setting reflect");
    harness.reset_frame().expect("a frame to drive");
    harness
        .call("sceneFrame", &[])
        .expect("one frame with the mirror");
    let mirrored = harness.observe().expect("observe");
    let water_mesh = water(&mut harness)["mesh"].as_i64().unwrap_or(-1);
    let mirror = water(&mut harness);
    let ground = harness
        .eval("terrainMesh")
        .expect("terrainMesh")
        .as_i64()
        .unwrap_or(-1);
    let ground_rows = rows_of(&mirrored.layers, &[ground]);
    checks.check(
        "the mirror pass ran once, into a target of its own",
        mirror["mirror"].as_i64().is_some_and(|rt| rt >= 0)
            && mirror["mirrors"].as_u64() == Some(1),
        (&mirror["mirror"], &mirror["mirrors"]),
    );
    checks.check(
        "...made at half the viewport across",
        mirror["mirrorW"].as_u64().is_some_and(|w| w > 0)
            && mirror["mirrorH"].as_u64().is_some_and(|h| h > 0),
        (&mirror["mirrorW"], &mirror["mirrorH"]),
    );
    checks.check(
        "...and it draws the world a second time",
        ground >= 0 && ground_rows.len() == 2,
        (&ground_rows, ground),
    );
    checks.check(
        "...for a surface that is still one draw",
        rows_of(&mirrored.layers, &[water_mesh]).len() == 1,
        (&mirrored.layers, water_mesh),
    );

    // A tier below the mirror spends no pass at all, and the surface is drawn anyway: the
    // tier chooses what the reflection shows, not whether there is water.
    harness
        .command("setting reflect ground")
        .expect("setting reflect");
    harness.reset_frame().expect("a frame to drive");
    harness
        .call("sceneFrame", &[])
        .expect("one frame without it");
    let flat = harness.observe().expect("observe");
    let after = water(&mut harness);
    checks.check(
        "a lower tier spends no pass",
        after["mirrors"].as_u64() == Some(1) && after["tier"].as_i64() == Some(1),
        (&after["mirrors"], &after["tier"]),
    );
    checks.check(
        "...and draws the world once, with the surface still in it",
        rows_of(&flat.layers, &[ground]).len() == 1
            && rows_of(&flat.layers, &[water_mesh]).len() == 1,
        (&rows_of(&flat.layers, &[ground]), water_mesh),
    );

    // Nothing to reflect and nothing to reflect in: a dry field runs no pass however the
    // tier is set, which is the same rule the surface itself follows.
    harness
        .command("setting reflect mirror")
        .expect("setting reflect");
    rain(&mut harness, 0.0);
    age(&mut harness, SETTLE);
    harness.reset_frame().expect("a frame to drive");
    harness.call("sceneFrame", &[]).expect("one dry frame");
    let dry = water(&mut harness);
    checks.check(
        "a dry field runs no mirror at all",
        dry["on"].as_bool() == Some(false) && dry["mirrors"].as_u64() == Some(1),
        (&dry["on"], &dry["mirrors"]),
    );

    checks.finish();
}

#[test]
fn the_pools_are_regions() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // Dry: a table on its floor covers nothing, so there is nothing to be a region of.
    rain_settled(&mut harness, 0.0);
    let dry = command_json(&mut harness, "pools");
    checks.check(
        "a dry field has no pools",
        dry["live"].as_u64() == Some(0) && dry["pools"].as_array().is_some_and(|p| p.is_empty()),
        &dry,
    );

    // A downpour. The pools are the connected wet cells, so their cells have to add up to
    // everything the state report calls wet -- one field, two functions, one answer. (The
    // range is wide enough to catch every pool on the grid rather than the goat's own.)
    rain_settled(&mut harness, 1.0);
    let wet = water(&mut harness);
    let all = command_json(&mut harness, "pools 200");
    let pools = all["pools"].as_array().cloned().unwrap_or_default();
    let cells: u64 = pools.iter().filter_map(|p| p["cells"].as_u64()).sum();
    checks.check(
        "the pools are the wet cells and nothing else",
        all["live"].as_u64().is_some_and(|n| n > 0) && wet["wet"].as_u64() == Some(cells),
        (all["live"].clone(), wet["wet"].clone(), cells, pools.len()),
    );

    // ...and the deepest of them is the deepest the field has, which is the other number
    // the two share.
    let deepest = pools
        .iter()
        .filter_map(|p| p["deepest"].as_f64())
        .fold(0.0f64, f64::max);
    checks.check(
        "...and the deepest pool is the field's deepest point",
        (deepest - f64_of(wet["deepest"].clone())).abs() < 1e-3,
        (deepest, &wet["deepest"]),
    );

    // A region's radius is the circle with its own area, so a caller can place a pool
    // without walking its cells -- which is the whole point of reporting it.
    let area = 2.0 * 2.0; // WATER_CELL ^ 2
    let mut wrong = Vec::new();
    for p in &pools {
        let n = p["cells"].as_f64().unwrap_or(0.0);
        let r = p["r"].as_f64().unwrap_or(0.0);
        let back = r * r * std::f64::consts::PI / area;
        if (back.round() - n).abs() > 1e-6 {
            wrong.push((n, r, back));
        }
    }
    checks.check(
        "...and each pool's radius is its own area",
        !pools.is_empty() && wrong.is_empty(),
        (&wrong, pools.len()),
    );

    // A film over the window's lowest ground: the fill tracks the table it is *given*
    // rather than a cached wet set, so the cells add up again at a level the rain did not
    // make. (The expected count is the state report's again -- one field, two functions, one
    // answer, which is why it is worth asserting at two very different tables.)
    let ground = f64_of(water(&mut harness)["ground"].clone());
    flood(&mut harness, ground + 0.15);
    let film = command_json(&mut harness, "pools 200");
    let film_cells: u64 = film["pools"]
        .as_array()
        .map(|ps| ps.iter().filter_map(|p| p["cells"].as_u64()).sum())
        .unwrap_or(0);
    let film_wet = water(&mut harness)["wet"].as_u64().unwrap_or(0);
    checks.check(
        "a film over the lowest ground is one pool at least, and its cells too",
        film["live"].as_u64().is_some_and(|n| n >= 1)
            && film_wet > 0
            && film_wet < wet["wet"].as_u64().unwrap_or(0)
            && film_cells == film_wet,
        (&film["live"], film_cells, film_wet, &wet["wet"]),
    );
    flood_off(&mut harness);

    // ...and every pool is *in the world*: the coordinates it reports are the field's own
    // units rather than the grid's indices, which is the one way a flood fill's output goes
    // quietly wrong (a pool at (3, 17) is a pool at a grid square). The built window is the
    // anchor plus two half-widths, so anything outside it never got converted.
    let x0 = f64_of(harness.eval("terrainAnchorX - WATER_HALF").expect("x0"));
    let z0 = f64_of(harness.eval("terrainAnchorZ - WATER_HALF").expect("z0"));
    let span = f64_of(harness.eval("WATER_N * WATER_CELL").expect("span"));
    let mut outside: Vec<(f64, f64)> = Vec::new();
    for p in &pools {
        for (xs, zs) in [("x", "z"), ("deepX", "deepZ")] {
            let x = p[xs].as_f64().unwrap_or(f64::NAN);
            let z = p[zs].as_f64().unwrap_or(f64::NAN);
            if x < x0 - 1.0 || x > x0 + span + 1.0 || z < z0 - 1.0 || z > z0 + span + 1.0 {
                outside.push((x, z));
            }
        }
    }
    checks.check(
        "...and its own coordinates are the world's, not the grid's",
        !pools.is_empty() && outside.is_empty(),
        (&outside, x0, z0, span),
    );

    checks.finish();
}

#[test]
fn the_seam_a_mod_reads() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    rain(&mut harness, 1.0);

    // `goats.water` (M20f, APIv1.md §4.17) is what a mod gets: the same numbers the frame
    // uses, not a second derivation of them.
    let state = water(&mut harness);
    let level = f64_of(harness.eval("goats.water.level()").expect("level"));
    let depth = f64_of(
        harness
            .eval("goats.water.depthAt(goat.px, goat.pz)")
            .expect("depthAt"),
    );
    checks.check(
        "the seam reads the numbers the frame uses",
        (level - f64_of(state["level"].clone())).abs() < 1e-9
            && (depth - f64_of(state["goatDepth"].clone())).abs() < 1e-3,
        (level, &state["level"], depth, &state["goatDepth"]),
    );
    let seam = harness.eval("goats.water.state()").expect("state");
    checks.check(
        "...and the report it hands over is the console's own",
        seam["level"] == state["level"] && seam["tier"] == state["tier"],
        (&seam["level"], &state["level"]),
    );

    // The door a mod drives the table through: a level by hand, and `clear` to hand it back.
    let forced = f64_of(
        harness
            .eval("goats.water.setLevel(-1.2)")
            .expect("setLevel"),
    );
    let driven = water(&mut harness);
    checks.check(
        "a mod can drive the level",
        (forced + 1.2).abs() < 1e-9
            && driven["forced"].as_bool() == Some(true)
            && (f64_of(driven["level"].clone()) + 1.2).abs() < 1e-3,
        (forced, &driven["level"], &driven["forced"]),
    );
    harness.eval("goats.water.clear()").expect("clear");
    checks.check(
        "...and clear hands it back to the weather",
        water(&mut harness)["forced"].as_bool() == Some(false),
        water(&mut harness)["forced"].clone(),
    );

    // The whole system's switch, which is what `J` presses: off is off, and a dry field
    // means no pools rather than a report about a table nothing is standing on.
    harness.command("water off").expect("water off");
    let off = water(&mut harness);
    checks.check(
        "`water off` is the whole system, and no pools come with it",
        off["enabled"].as_bool() == Some(false)
            && off["on"].as_bool() == Some(false)
            && command_json(&mut harness, "pools")["live"].as_u64() == Some(0),
        &off,
    );
    harness.command("water on").expect("water on");
    checks.check(
        "...and it comes back",
        water(&mut harness)["enabled"].as_bool() == Some(true),
        water(&mut harness)["enabled"].clone(),
    );

    checks.finish();
}

#[test]
fn the_world_snapshot_carries_no_water() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // The claim the whole design rests on (M20f's audit): the water is derived on both ends
    // from the seeded weather, so nothing about it is on the datagram. The scene's own world
    // snapshot is the place that can be checked, and a host is what publishes one.
    harness
        .call(
            "sceneNetEvent",
            &[json!("{\"type\":\"session\",\"seed\":7}")],
        )
        .expect("a session");
    harness
        .call(
            "sceneNetEvent",
            &[json!("{\"type\":\"hosting\",\"name\":\"host\"}")],
        )
        .expect("hosting");
    // The rain hard on, and the goat standing deep enough for the drag to bite: if the water
    // had anything to say to the world, this is the frame it would say it in.
    rain(&mut harness, 1.0);
    let wet = water(&mut harness);
    let drained = harness
        .eval("sceneNetDrain()")
        .expect("the outbox")
        .as_str()
        .unwrap_or("")
        .to_string();
    let world = drained
        .lines()
        .find(|line| line.contains("\"type\":\"world\""))
        .expect("a world snapshot");
    let parsed: Value = serde_json::from_str(world).expect("the world line parses");
    let mut keys: Vec<String> = parsed
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();
    keys.sort();
    checks.check(
        "the world snapshot is the seven things it always was",
        keys == vec![
            "bots", "craters", "eaten", "spent", "streams", "type", "weather",
        ],
        &keys,
    );
    checks.check(
        "...and the water is not one of them",
        wet["on"].as_bool() == Some(true)
            && parsed.get("water").is_none()
            && parsed.get("level").is_none(),
        (&wet["on"], &parsed),
    );

    checks.finish();
}

#[test]
fn the_water_tree_is_clamped() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // Every leaf of the water's tree has a range (M20f), and it is *walked* rather than
    // listed so a knob added later is caught here rather than by a reader: `TUNING_CLAMP` is
    // what a mod's write is checked against, so an unclamped leaf is a mod's lever on the
    // frame. The nested tree (`water.wave`) is walked with it, which is where a leaf added
    // by a later slice will land.
    let unclamped = harness
        .eval(
            "(function () { const out = []; \
             for (const k of Object.keys(TUNING.water)) { \
             const v = TUNING.water[k]; \
             if (typeof v === 'number') { \
             if (TUNING_CLAMP['water.' + k] === undefined) out.push(k); \
             } else if (v !== null && typeof v === 'object') { \
             for (const j of Object.keys(v)) { \
             if (typeof v[j] === 'number' && TUNING_CLAMP['water.' + k + '.' + j] === undefined) { \
             out.push(k + '.' + j); \
             } } } } return out; })()",
        )
        .expect("walk the tree");
    checks.check(
        "every leaf of the water's tree has a range",
        unclamped.as_array().is_some_and(|leaves| leaves.is_empty()),
        &unclamped,
    );

    // ...and the system's own switch is a boolean rather than a knob: anything a mod writes
    // through the console's own route lands on on or off.
    let wide = harness
        .eval("tuningSet('water.enabled', 5)")
        .expect("a clamp");
    checks.check(
        "...and the switch is held to on or off",
        wide.as_f64() == Some(1.0),
        wide,
    );

    checks.finish();
}

#[test]
fn two_peers_derive_the_same_table() {
    let mut checks = Checks::new();

    // The first half of M20f's audit. The claim is that the water needs no field on the wire
    // because both ends *derive* it from the seeded weather, so two contexts -- the same
    // script, the same rain, nothing between them -- have to agree about the whole report,
    // handles and all.
    let left = std::thread::spawn(|| {
        let mut harness = Harness::start().expect("evaluate the scene");
        harness.run(FRAMES).expect("run the scene");
        rain(&mut harness, 1.0);
        water(&mut harness)
    });
    let right = std::thread::spawn(|| {
        let mut harness = Harness::start().expect("evaluate the scene");
        harness.run(FRAMES).expect("run the scene");
        rain(&mut harness, 1.0);
        water(&mut harness)
    });
    let a = left.join().expect("the first peer");
    let b = right.join().expect("the second peer");
    checks.check(
        "two peers with the same rain derive the same table",
        a == b,
        (&a, &b),
    );

    // The second half, and the one number the design admits is an estimate rather than a
    // derivation: the *drain*. The rise is exact (it is `rainAmount` read through a curve),
    // but the follower is stepped by each frame's own `dt`, so two peers whose frames are
    // differently shaped converge on the same level from different directions. This drives
    // the same five minutes of clock in two shapes -- 50 ms frames and hits of five seconds
    // -- and reports the gap, which is the number call 4's quantized level would have to
    // beat to be worth its bytes.
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");
    harness
        .eval("tuningSet('water.wetDown', 600)")
        .expect("the shipped drain");
    let window = 300.0;

    rain(&mut harness, 1.0);
    rain(&mut harness, 0.0);
    let mut clock = 0.0;
    while clock < window {
        age(&mut harness, 0.05);
        clock += 0.05;
    }
    let fine = f64_of(water(&mut harness)["level"].clone());

    // Six thousand steps back to full: the rise carries no memory, so setting the rain to 1
    // again pins the wetting exactly and the second shape starts from the same place.
    rain(&mut harness, 1.0);
    rain(&mut harness, 0.0);
    let mut clock = 0.0;
    while clock < window {
        age(&mut harness, 5.0);
        clock += 5.0;
    }
    let coarse = f64_of(water(&mut harness)["level"].clone());

    let gap = (fine - coarse).abs();
    eprintln!(
        "water: five minutes of drain -- 50 ms frames {fine:.6}, 5 s frames {coarse:.6}, gap {gap:.6} m"
    );
    checks.check(
        "...and the drain stays inside a centimetre however the frames are shaped",
        gap < 0.01 && fine > coarse,
        (fine, coarse, gap),
    );

    checks.finish();
}

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
fn the_fill_makes_pools() {
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

    // A downpour fills every hollow to its spill, so there is water somewhere and a
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

//! The slope's price: uphill costs a goat energy, a descent gives some back, and the
//! air pays nothing.
//!
//! This is the mechanic that gives a goat a reason to fly -- a mountainside is a wall
//! on foot and a shortcut with a bird -- so the cases here are about the rule, not
//! about how a hill looks. The rule is one multiplier on the gait's own drain, taken
//! from the grade along the heading and applied *after* the night, the weather and the
//! water, so it scales the bill the goat was already going to pay rather than
//! replacing it. Two leaves own it (`TUNING.stats.slopeDrainUp`/`slopeDrainDown`,
//! `core.js`), `terrainGrade` (`world.js`) reads the ground, and `slopeDrainScale`
//! (`goat.js`) is the law itself.
//!
//! The cases drive `updateStats` directly, with the frame's own multipliers pinned, so
//! the arithmetic is exact and nothing else in the world can move it -- no device to
//! throw the goat, no menu to freeze it, no rain to add a share of its own. One case
//! then runs a real frame, because the input reaching `updateStats` through
//! `sceneFrame` is the one part a direct call cannot hold.
//!
//! `stats` reports both halves of what the last frame charged, `grade` and `drain`, so
//! the mechanic is inspectable from the console and from a mod. The cases read the raw
//! globals where a comparison has to be sharp, because the verb rounds to two places.
//!
//! ```text
//! cargo test --profile fast -p harness --test slope -- --nocapture
//! ```

mod support;

use harness::Harness;
use serde_json::json;
use support::{Checks, bool_of, command_json, f64_of};

/// Long enough to walk the load steps: the terrain, the textures and the herd.
const FRAMES: u32 = 30;

/// A steep point on the field, with the gradient that climbs it: `{x, z, g, gx, gz}`,
/// where `g` is the grade along `(gx, gz)/g`. The lattice is coarse on purpose -- one
/// steep hillside anywhere is all these cases need, and `terrain.mountainFlat` plus
/// `mountainRamp` put the range well inside it. Asked of the field rather than pinned
/// to a coordinate, so a change to the noise does not quietly turn a case into a walk
/// across a meadow.
const FIND_STEEPEST: &str = "(function () { \
    let best = null; \
    for (let x = -160; x <= 160; x += 8) { \
        for (let z = -160; z <= 160; z += 8) { \
            const gx = terrainGrade(x, z, 1, 0); \
            const gz = terrainGrade(x, z, 0, 1); \
            const g = Math.sqrt(gx * gx + gz * gz); \
            if (best === null || g > best.g) best = { x: x, z: z, g: g, gx: gx, gz: gz }; \
        } \
    } \
    return best; \
})()";

/// One steep point: where it is, how steep, and the unit heading that climbs it.
struct Steep {
    x: f64,
    z: f64,
    grade: f64,
    dx: f64,
    dz: f64,
}

fn steepest(harness: &mut Harness) -> Steep {
    let found = harness.eval(FIND_STEEPEST).expect("search the field");
    let g = f64_of(found["g"].clone());
    let (gx, gz) = (f64_of(found["gx"].clone()), f64_of(found["gz"].clone()));
    Steep {
        x: f64_of(found["x"].clone()),
        z: f64_of(found["z"].clone()),
        grade: g,
        dx: gx / g,
        dz: gz / g,
    }
}

/// The tuning the rule is read from, so a case states the law rather than today's
/// number: move a leaf and the case moves with it.
fn leaf(harness: &mut Harness, path: &str) -> f64 {
    f64_of(
        harness
            .eval(&format!("TUNING.stats.{path}"))
            .expect("the tuning leaf"),
    )
}

/// The grade of the ground along a world heading, straight from the field.
fn grade(harness: &mut Harness, x: f64, z: f64, dx: f64, dz: f64) -> f64 {
    f64_of(
        harness
            .eval(&format!("terrainGrade({x}, {z}, {dx}, {dz})"))
            .expect("terrainGrade"),
    )
}

/// The slope's multiplier at a grade -- the rule `updateStats` applies.
fn scale(harness: &mut Harness, grade: f64) -> f64 {
    f64_of(
        harness
            .eval(&format!("slopeDrainScale({grade})"))
            .expect("slopeDrainScale"),
    )
}

/// The two numbers the last `updateStats` charged: the grade it was read against and
/// the net energy a second it took.
fn charged(harness: &mut Harness) -> (f64, f64) {
    let grade = f64_of(harness.eval("lastGrade").expect("lastGrade"));
    let drain = f64_of(harness.eval("lastDrain").expect("lastDrain"));
    (grade, drain)
}

/// Stand the goat at a point, facing along a world heading, with every other drain
/// multiplier pinned to one -- so what comes back is the gait, the slope and nothing
/// else. The heading is the direction of *travel*: `goat.yaw` 0 walks toward +x and the
/// scene's travel vector is `(cos yaw, -sin yaw)`, so the yaw that walks toward
/// `(dx, dz)` is `atan2(-dz, dx)`.
fn stand(harness: &mut Harness, x: f64, z: f64, dx: f64, dz: f64) {
    harness.command(&format!("pos {x} {z}")).expect("pos");
    let yaw = f64::atan2(-dz, dx).to_degrees();
    harness.command(&format!("yaw {yaw}")).expect("yaw");
    harness.eval("skyLight = 1").expect("a bright sky");
    harness.eval("weatherDrain = 1").expect("a dry coat");
    harness.eval("stats.energy = 50").expect("energy");
}

/// One second of `updateStats` in a mode, as the frame would call it. The dt is a whole
/// second so the rate it returns is the number a case compares against.
fn charge(harness: &mut Harness, mode: &str, move_axis: i64) -> (f64, f64, f64) {
    harness.eval(&format!("mode = \"{mode}\"")).expect("mode");
    harness.eval("stats.energy = 50").expect("energy");
    harness
        .call("updateStats", &[json!(1.0), json!(move_axis)])
        .expect("updateStats");
    let energy = f64_of(harness.eval("stats.energy").expect("energy"));
    let (grade, drain) = charged(harness);
    (grade, drain, 50.0 - energy)
}

/// One frame through the scene's own input path, after the scripted run has ended.
fn frame(harness: &mut Harness) {
    harness.reset_frame().expect("reset the frame gate");
    let ran = bool_of(harness.call("sceneFrame", &[]).expect("sceneFrame"));
    assert!(ran, "the frame did not run");
}

#[test]
fn the_field_has_hills() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");

    // The spawn bowl is the one place the rule costs nothing, and deliberately: a new
    // goat opens its eyes in a meadow, not against a bill.
    let (east, north) = (
        grade(&mut harness, 0.0, 0.0, 1.0, 0.0),
        grade(&mut harness, 0.0, 0.0, 0.0, 1.0),
    );
    checks.check(
        "the spawn meadow is level",
        east == 0.0 && north == 0.0,
        (east, north),
    );

    let steep = steepest(&mut harness);
    println!(
        "steepest sampled: {:.0}% grade at ({}, {})",
        steep.grade * 100.0,
        steep.x,
        steep.z
    );
    checks.check(
        "the mountains are a climb",
        steep.grade > 0.2,
        (steep.x, steep.z, steep.grade),
    );

    // The same hill the other way is the same hill negated: a grade is a signed
    // directional derivative, which is what makes a switchback work.
    let up = grade(&mut harness, steep.x, steep.z, steep.dx, steep.dz);
    let down = grade(&mut harness, steep.x, steep.z, -steep.dx, -steep.dz);
    checks.check(
        "turning round negates the grade",
        (up - steep.grade).abs() < 1e-9 && (down + steep.grade).abs() < 1e-9,
        (up, down, steep.grade),
    );

    // Across the hill is not up it. This is the whole reason the rule is a
    // *directional* derivative rather than `|gradient|`: a goat crossing a slope
    // sideways walks the contour it is standing on.
    let across = grade(&mut harness, steep.x, steep.z, -steep.dz, steep.dx);
    checks.check(
        "a contour costs nothing to walk",
        across.abs() < 1e-9,
        (across, steep.grade),
    );

    checks.finish();
}

#[test]
fn the_slope_scales_the_gait() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    let up = leaf(&mut harness, "slopeDrainUp");
    let down = leaf(&mut harness, "slopeDrainDown");
    checks.check(
        "both leaves are a price",
        up > 0.0 && down > 0.0,
        (up, down),
    );

    checks.check(
        "level ground is the gait's own rate",
        scale(&mut harness, 0.0) == 1.0,
        scale(&mut harness, 0.0),
    );
    checks.check(
        "a climb multiplies the gait",
        (scale(&mut harness, 0.2) - (1.0 + up * 0.2)).abs() < 1e-12,
        (scale(&mut harness, 0.2), up),
    );
    checks.check(
        "a descent divides it",
        (scale(&mut harness, -0.2) - (1.0 - down * 0.2)).abs() < 1e-12,
        (scale(&mut harness, -0.2), down),
    );

    // The floor. The grade at which a descent has given the whole gait back is
    // `-1/slopeDrainDown`, and past it the answer is zero rather than a gain: a hill is
    // not a battery, and walking down one must never be worth more than not walking.
    let free = -1.0 / down;
    checks.check(
        "a steep enough descent is free, and only free",
        scale(&mut harness, free) == 0.0 && scale(&mut harness, free * 2.0) == 0.0,
        (
            free,
            scale(&mut harness, free),
            scale(&mut harness, free * 2.0),
        ),
    );

    // The law holds at every grade, not just the two the arithmetic above probes: the
    // answer never goes negative and never falls as the ground steepens. The tolerance is
    // the floor's own rounding -- `1 + down * grade` lands a few ulps either side of zero
    // at exactly the grade a descent has paid the whole gait back.
    let sweep = harness
        .eval(
            "(function () { let prev = -Infinity; \
             for (let g = -2; g <= 2; g += 0.01) { \
                 const s = slopeDrainScale(g); \
                 if (s < 0 || s < prev - 1e-12) return { ok: false, g: g, s: s, prev: prev }; \
                 prev = s; \
             } \
             return { ok: true, peak: slopeDrainScale(2) }; })()",
        )
        .expect("sweep the grades");
    checks.check(
        "a steeper climb never gets cheaper",
        bool_of(sweep["ok"].clone()),
        &sweep,
    );

    checks.finish();
}

#[test]
fn the_gait_pays_the_slope() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    let up = leaf(&mut harness, "slopeDrainUp");
    let down = leaf(&mut harness, "slopeDrainDown");
    let walk = f64_of(
        harness
            .eval("TUNING.stats.energyDrain.walk")
            .expect("the walk rate"),
    );
    let idle = f64_of(
        harness
            .eval("TUNING.stats.energyDrain.idle")
            .expect("the idle rate"),
    );
    let steep = steepest(&mut harness);

    // Nothing but the ground may move the numbers below: not a puddle under the goat,
    // and not the frame's own multipliers, which `stand` pins.
    for (spot, label) in [((0.0, 0.0), "the meadow"), ((steep.x, steep.z), "the hill")] {
        harness
            .command(&format!("pos {} {}", spot.0, spot.1))
            .expect("pos");
        let wet = f64_of(harness.eval("waterDrainFactor()").expect("water"));
        checks.check(&format!("{label} is dry ground"), wet == 1.0, wet);
    }

    // ...on the level, in every direction. The bowl is level, so this is the one place
    // the rate is exactly the gait's own.
    stand(&mut harness, 0.0, 0.0, 1.0, 0.0);
    let (flat_grade, flat_drain, flat_spent) = charge(&mut harness, "walk", 1);
    checks.check(
        "a walk on the level costs the walk's own rate",
        flat_grade == 0.0 && (flat_drain - walk).abs() < 1e-12 && (flat_spent - walk).abs() < 1e-12,
        (flat_grade, flat_drain, flat_spent, walk),
    );

    // ...uphill, which is the whole point: a mountainside costs more than the meadow.
    stand(&mut harness, steep.x, steep.z, steep.dx, steep.dz);
    let (up_grade, up_drain, _) = charge(&mut harness, "walk", 1);
    let expected_up = walk * (1.0 + up * up_grade);
    checks.check(
        "a walk uphill reads the grade it is climbing",
        up_grade > 0.0 && (up_grade - steep.grade).abs() < 1e-9,
        (up_grade, steep.grade),
    );
    checks.check(
        "a walk uphill costs the slope's share more",
        (up_drain - expected_up).abs() < 1e-9 && up_drain > walk,
        (up_drain, expected_up, walk),
    );

    // ...and downhill, which gives some back. The floor is the gait's own drain: a
    // descent is cheaper than the level at worst, never a refill.
    stand(&mut harness, steep.x, steep.z, -steep.dx, -steep.dz);
    let (down_grade, down_drain, _) = charge(&mut harness, "walk", 1);
    let expected_down = walk * (1.0 + down * down_grade).max(0.0);
    checks.check(
        "a walk downhill reads a descent",
        down_grade < 0.0 && (down_grade + steep.grade).abs() < 1e-9,
        (down_grade, steep.grade),
    );
    checks.check(
        "a walk downhill is cheaper and never a refill",
        (down_drain - expected_down).abs() < 1e-9 && down_drain < walk && down_drain >= 0.0,
        (down_drain, expected_down, walk),
    );

    // Backing down the hill is the descent: the rule reads the ground the goat
    // *travels* over, not the ground it faces, so S on the same hillside is cheap.
    stand(&mut harness, steep.x, steep.z, steep.dx, steep.dz);
    let (back_grade, back_drain, _) = charge(&mut harness, "walk", -1);
    checks.check(
        "backing down a slope is the descent",
        (back_grade + steep.grade).abs() < 1e-9 && back_drain < walk,
        (back_grade, back_drain, steep.grade),
    );

    // Standing still on the hillside costs what standing still costs: the grade is a
    // price on travel, and an idle goat is not travelling.
    stand(&mut harness, steep.x, steep.z, steep.dx, steep.dz);
    let (still_grade, still_drain, _) = charge(&mut harness, "idle", 0);
    checks.check(
        "standing on a hillside is not climbing it",
        still_grade == 0.0 && (still_drain - idle).abs() < 1e-12,
        (still_grade, still_drain, idle),
    );

    // The jump is the same ground with its direction frozen at take-off (`jumpDir`), so
    // it pays the slope of the ground it launched along rather than whichever way the
    // stick happens to point mid-arc -- and its own rate is the idle one, which is what
    // a jump has always cost (`updateStats` has no row for it). The grade is the point
    // here, not the rate: hopping up a hill must not dodge the climb.
    stand(&mut harness, steep.x, steep.z, steep.dx, steep.dz);
    harness.eval("jumpDir = 1").expect("jumpDir");
    let (jump_grade, jump_drain, _) = charge(&mut harness, "jump", 0);
    checks.check(
        "a jump pays the slope it launched along",
        (jump_grade - steep.grade).abs() < 1e-9
            && (jump_drain - idle * (1.0 + up * jump_grade)).abs() < 1e-9,
        (jump_grade, jump_drain, steep.grade, idle),
    );

    // ...and the air pays nothing. Not "less": nothing. The flight burns its own energy
    // inside the crate, and the ground's share of a flying goat's frame is zero -- and
    // it is not even read, which is what `lastGrade` being 0 says.
    stand(&mut harness, steep.x, steep.z, steep.dx, steep.dz);
    let (fly_grade, fly_drain, _) = charge(&mut harness, "fly", 1);
    checks.check(
        "flying over a mountainside pays the ground nothing",
        fly_grade == 0.0 && fly_drain == 0.0,
        (fly_grade, fly_drain),
    );

    checks.finish();
}

#[test]
fn the_frame_pays_the_slope() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(FRAMES).expect("run the scene");

    // Take the scene's steering back: the scripted run may have left a menu open, and a
    // menu freezes the state machine, which would leave the goat standing through the
    // gait this case is about. No devices either -- a bang on the hillside would throw
    // the goat and end the walk that is being charged for.
    harness.command("console close").expect("console");
    harness.command("ui hud").expect("the HUD");
    harness.command("resume").expect("resume");
    harness.command("restart").expect("restart");
    harness
        .eval("goats.tuning.set(\"explosions.enabled\", 0)")
        .expect("no devices");

    // A dry, bright, rainless world: `weatherDrain` is exactly one and the night's
    // multiplier stays out of the bill, so the only thing left in the rate is the gait
    // and the ground. `time 12` needs a frame to reach `skyLight`, which is why the
    // first check is that it did.
    harness.command("weather clear").expect("weather");
    harness.command("time 12").expect("noon");
    harness.eval("rainAmount = 0").expect("no rain");
    harness.command("walk").expect("walk");
    frame(&mut harness);
    let light = f64_of(harness.eval("skyLight").expect("skyLight"));
    checks.check("the frame's sun is up", light >= 0.25, light);

    let up = leaf(&mut harness, "slopeDrainUp");
    let walk = f64_of(
        harness
            .eval("TUNING.stats.energyDrain.walk")
            .expect("the walk rate"),
    );

    // On the level: the frame's own path, the console's held gait, and a rate that is
    // the gait's own.
    harness.command("pos 0 0").expect("pos");
    harness.command("yaw 0").expect("yaw");
    harness.command("heal").expect("heal");
    frame(&mut harness);
    let (flat_grade, flat_drain) = charged(&mut harness);
    let mode = harness.eval("mode").expect("mode");
    checks.check(
        "the frame walks the goat it is told to",
        mode == "walk",
        (mode, flat_grade, flat_drain),
    );
    checks.check(
        "the frame's flat rate is the walk's own",
        flat_grade == 0.0 && (flat_drain - walk).abs() < 1e-9,
        (flat_grade, flat_drain, walk),
    );

    // Up the hill: one more frame, one turn of the goat, and the bill the frame charges
    // is the slope's share on top of the same walk.
    let steep = steepest(&mut harness);
    harness
        .command(&format!("pos {} {}", steep.x, steep.z))
        .expect("pos");
    let yaw = f64::atan2(-steep.dz, steep.dx).to_degrees();
    harness.command(&format!("yaw {yaw}")).expect("yaw");
    harness.command("heal").expect("heal");
    frame(&mut harness);
    let (hill_grade, hill_drain) = charged(&mut harness);
    checks.check(
        "the frame reads the hillside it is walking up",
        (hill_grade - steep.grade).abs() < 1e-9,
        (hill_grade, steep.grade),
    );
    checks.check(
        "the frame charges the slope's share",
        (hill_drain - walk * (1.0 + up * hill_grade)).abs() < 1e-9,
        (hill_drain, walk, hill_grade, up),
    );

    // The console's own readout is the same two numbers, because a mechanic nobody can
    // inspect is a mechanic that will be argued about rather than measured.
    let stats = command_json(&mut harness, "stats");
    checks.check(
        "`stats` reports the grade and the rate",
        stats["grade"]
            .as_f64()
            .is_some_and(|g| (g - hill_grade).abs() < 0.01)
            && stats["drain"]
                .as_f64()
                .is_some_and(|d| (d - hill_drain).abs() < 0.01),
        (&stats, hill_grade, hill_drain),
    );

    checks.finish();
}

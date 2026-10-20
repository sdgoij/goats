//! Captured-bird flight, on the scene's own frame loop.
//!
//! The mechanics live in `crates/flight` and reach the scene through the
//! `__flight` global (`crates/flight-js`). What this file is for is the
//! *integration*: that a running jump with the capability takes off, that the
//! ground controls mean the flight controls in the air, that a release is a fall
//! carrying the crate's damage, that a bot's zoomies hop is the same take-off, and
//! that the scene's own numbers agree with the crate's.
//! the crate's.
//!
//! The harness's scripted keyboard is a fixed timeline (walk at frame 10, run at
//! 50, a jump at 70, ...), which fights a case that wants to choose its own keys.
//! So every world installs an empty touch timeline, which stands the scripted
//! keyboard down (the seam `touch.rs` uses), and then drives the goat through the
//! console: `run`/`back`/`stop`/`turn` write `ctlHeld`, exactly what the real
//! keys write, and `jump`/`release`/`flight on` are the verbs the overlay and a
//! mod use. Frames advance by calling `sceneFrame` the way `scene_logic.rs`'s
//! bursts do, after `run()` has loaded the world.
//!
//! One live world at a time: two stepped contexts in one process abort, so each
//! block owns its [`World`] and drops it before the next opens one.

mod support;

use harness::Harness;
use serde_json::json;
use support::{Checks, f64_of};

/// Enough frames to finish the nine load steps with an empty herd. `run()` ends
/// the scene's own loop, so the cases step it by hand from here.
const LOAD: u32 = 24;

/// A loaded world with no herd and no scripted input.
struct World {
    harness: Harness,
}

impl World {
    fn new() -> World {
        World::with_herd(0)
    }

    /// A loaded world with `herd` bots. `loadTotal` is nine steps plus one per bot,
    /// so `LOAD` still covers a herd of one.
    fn with_herd(herd: u32) -> World {
        let mut harness = Harness::start().expect("evaluate the scene");
        // An empty touch timeline: `touch.js` is inert and the stub's scripted
        // keyboard stands down, so only the console's held keys move the goat.
        harness.touch(&json!([])).expect("the touch surface");
        // The player's cases want no herd -- it is the expensive half of a frame --
        // and the herd's own want exactly one.
        harness
            .eval(&format!("goats.bots.setCount({herd})"))
            .expect("the herd");
        harness.run(LOAD).expect("load the scene");
        // `run()` ends with `sceneShutdown`, which unloads the herd along with the
        // player's model. The tuning leaf is still set, and `loaded` is still true, so
        // naming the count again rebuilds it -- the same call the load step makes.
        if herd > 0 {
            harness
                .eval(&format!("goats.bots.setCount({herd})"))
                .expect("the herd");
        }
        // `run()` stopped at `LOAD`; the hand-driven frames need headroom above
        // it. The clock is reset so a case's own frame indices start at zero.
        harness
            .call("harnessSetTotal", &[json!(1_000_000)])
            .expect("the frame budget");
        harness.reset_frame().expect("the frame clock");
        World { harness }
    }

    /// Advances `frames` frames of the scene's own loop.
    fn step(&mut self, frames: u32) {
        for _ in 0..frames {
            let running = self.harness.call("sceneFrame", &[]).expect("sceneFrame");
            assert_eq!(running, json!(true), "the frame loop stopped mid-case");
        }
    }

    fn eval(&mut self, code: &str) -> serde_json::Value {
        self.harness
            .eval(code)
            .unwrap_or_else(|error| panic!("{code}: {error}"))
    }

    fn number(&mut self, code: &str) -> f64 {
        f64_of(self.eval(code))
    }

    fn flag(&mut self, code: &str) -> bool {
        self.eval(code).as_bool().unwrap_or(false)
    }

    fn text(&mut self, code: &str) -> String {
        self.eval(code).as_str().unwrap_or("").to_string()
    }

    fn mode(&mut self) -> String {
        self.text("mode")
    }

    fn command(&mut self, line: &str) -> String {
        self.harness
            .command(line)
            .unwrap_or_else(|error| panic!("{line}: {error}"))
    }

    /// Grants the captured bird's capability the way the mod does.
    fn arm(&mut self) {
        assert_eq!(self.command("flight on"), "ok flight on");
    }

    /// A running jump: the gameplay path into the air.
    fn take_off(&mut self) {
        assert_eq!(self.command("run"), "ok run");
        assert_eq!(self.command("jump"), "ok jump");
        assert_eq!(
            self.mode(),
            "fly",
            "a running jump with a captured bird takes off"
        );
    }
}

#[test]
fn the_flight_works() {
    let mut checks = Checks::new();
    take_off_cases(&mut checks);
    control_cases(&mut checks);
    release_cases(&mut checks);
    herd_air_cases(&mut checks);
    herd_landing_cases(&mut checks);
    checks.finish();
}

/// Put the only bot into a run with its zoomies clock running and no hop cooldown,
/// which is the state `updateBots` takes off from. Its target is ten metres away, so
/// the speed the take-off gets is the run's own.
fn herd_hop(world: &mut World) {
    world.eval(
        "BOTS[0].mode = 'run'; BOTS[0].zoom = 5; BOTS[0].jumpCool = 0; \
         BOTS[0].timer = 10; BOTS[0].tx = BOTS[0].x + 10; BOTS[0].tz = BOTS[0].z;",
    );
    world.step(2);
}

/// A bot's take-off, its ring autopilot, its airborne guard and its death in the air.
fn herd_air_cases(checks: &mut Checks) {
    let mut world = World::with_herd(1);
    checks.check(
        "the herd has one bot",
        world.number("goats.bots.count()") == 1.0,
        world.number("goats.bots.count()"),
    );

    // ---- no captured bird: the zoomies hop stays a hop --------------------
    herd_hop(&mut world);
    checks.check(
        "a hop with no bird is a jump",
        world.text("BOTS[0].mode") == "jump",
        world.text("BOTS[0].mode"),
    );

    // ---- the grant: the next hop takes off --------------------------------
    world.eval(
        "BOTS[0].mode = 'idle'; BOTS[0].jumpTime = 0; BOTS[0].zoom = 0; \
         BOTS[0].flightCapable = true; BOTS[0].flightCooldown = 0;",
    );
    herd_hop(&mut world);
    checks.check(
        "a hop with a captured bird takes off",
        world.text("BOTS[0].mode") == "fly",
        world.text("BOTS[0].mode"),
    );
    world.step(30);
    let height = world.number("BOTS[0].py");
    checks.check("...and climbs into the ring", height > 0.3, height);
    checks.check(
        "...and the scene calls it airborne",
        world.flag("botAirborne(BOTS[0])"),
        world.flag("botAirborne(BOTS[0])"),
    );

    // ---- a flying bot is not shoved along the ground ----------------------
    world.eval("BOTS[0].x = goat.px; BOTS[0].z = goat.pz;");
    let x = world.number("BOTS[0].x");
    let z = world.number("BOTS[0].z");
    world
        .harness
        .call("resolveGoatCollisions", &[])
        .expect("resolveGoatCollisions");
    let moved = (world.number("BOTS[0].x") - x).abs() + (world.number("BOTS[0].z") - z).abs();
    checks.check("a flyer does not push the herd apart", moved < 1e-6, moved);

    // ---- a death in the air drops the bird and keeps the height ----------
    let height = world.number("BOTS[0].py");
    world.eval("botDie(BOTS[0])");
    checks.check(
        "a bot killed in flight drops the captured bird",
        !world.flag("BOTS[0].flightCapable"),
        world.flag("BOTS[0].flightCapable"),
    );
    world.step(1);
    checks.check(
        "...and the corpse keeps its height",
        height > 0.3
            && world.text("BOTS[0].mode") == "dead"
            && world.number("BOTS[0].py") > height - 0.5,
        (
            world.text("BOTS[0].mode"),
            height,
            world.number("BOTS[0].py"),
        ),
    );
    world.step(120);
    checks.check(
        "...until it meets the ground",
        world.number("BOTS[0].py") <= 0.01,
        world.number("BOTS[0].py"),
    );
}

/// The ring's time is up: the bot noses down, lands, and waits on the ground.
fn herd_landing_cases(checks: &mut Checks) {
    let mut world = World::with_herd(1);
    // A short flight clock, so the case does not wait eighteen seconds.
    world.eval("tuningSet('flight.botTime', 1.5)");
    world.eval("BOTS[0].flightCapable = true;");
    herd_hop(&mut world);
    checks.check(
        "the herd takes off",
        world.text("BOTS[0].mode") == "fly",
        world.text("BOTS[0].mode"),
    );
    world.step(420);
    checks.check(
        "the bot's flight ends on its clock",
        world.text("BOTS[0].mode") != "fly",
        world.text("BOTS[0].mode"),
    );
    checks.check(
        "...it is on the ground",
        world.number("BOTS[0].py") <= 0.01,
        world.number("BOTS[0].py"),
    );
    checks.check(
        "...and waits out the cooldown",
        world.number("BOTS[0].flightCooldown") > 0.0,
        world.number("BOTS[0].flightCooldown"),
    );
    checks.check(
        "...with the bird still aboard",
        world.flag("BOTS[0].flightCapable"),
        world.flag("BOTS[0].flightCapable"),
    );
}

/// The capability is necessary, and only a *running* jump spends it.
fn take_off_cases(checks: &mut Checks) {
    let mut world = World::new();
    checks.check(
        "the scene starts on the ground",
        world.mode() == "idle",
        world.mode(),
    );

    // ---- no capability: a running jump is only a jump ---------------------
    world.command("run");
    world.command("jump");
    checks.check(
        "a running jump with no bird is a jump",
        world.mode() == "jump",
        world.mode(),
    );
    world.step(50);
    checks.check(
        "...and it lands rather than flying",
        world.mode() != "fly",
        world.mode(),
    );

    // ---- capability, but not a running jump ------------------------------
    world.arm();
    // `stop` clears the keys; the mode follows on the next frame.
    world.command("stop");
    world.step(1);
    world.command("jump");
    checks.check(
        "a standing jump does not take off",
        world.mode() == "jump",
        world.mode(),
    );
    world.step(50);

    world.command("walk");
    world.command("jump");
    checks.check(
        "a walking jump does not take off",
        world.mode() == "jump",
        world.mode(),
    );
    world.step(50);
    checks.check(
        "...and the captured bird is still aboard",
        world.flag("flightCapable"),
        world.flag("flightCapable"),
    );

    // ---- the take-off ----------------------------------------------------
    world.command("run");
    let energy = world.number("stats.energy");
    world.command("jump");
    checks.check(
        "a running jump takes off",
        world.mode() == "fly",
        world.mode(),
    );
    let spent = energy - world.number("stats.energy");
    checks.check("...and costs the take-off energy", spent > 1.5, spent);
    world.step(12);
    checks.check(
        "...and the goat climbs off the ground",
        world.number("goat.py") > 0.3,
        world.number("goat.py"),
    );
    checks.check(
        "...and the scene calls it airborne",
        world.flag("goatAirborne()"),
        world.flag("goatAirborne()"),
    );

    // ---- the next life ---------------------------------------------------
    world.command("restart");
    checks.check(
        "restart clears the captured bird",
        !world.flag("flightCapable"),
        world.flag("flightCapable"),
    );
    checks.check(
        "...and puts the goat back on its feet",
        world.mode() == "idle",
        world.mode(),
    );
}

/// W/S/Space/A/D mean pitch, flap and bank while flying.
fn control_cases(checks: &mut Checks) {
    let mut world = World::new();
    world.arm();
    world.take_off();
    world.step(10);

    // Room to dive. The cases only read the sign of the height change, but a
    // take-off from the floor would land before a hold on W had said anything.
    world.eval("goat.py = 24");
    world.step(1);

    // ---- W noses down, S noses up ----------------------------------------
    world.command("run"); // W
    let high = world.number("goat.py");
    world.step(50);
    let pitch = world.number("flightPitch");
    checks.check("W noses down", pitch < -0.3, pitch);
    let low = world.number("goat.py");
    checks.check("...and loses height", low < high - 0.5, (high, low));

    // Two seconds: the pitch has to come all the way from the dive's clamp to
    // the climb's, and the vertical speed follows it a beat later, so a shorter
    // hold spends its first second still sinking.
    world.command("back"); // S
    world.step(120);
    let pitch = world.number("flightPitch");
    checks.check("S noses up", pitch > 0.3, pitch);
    let climbed = world.number("goat.py");
    checks.check("...and gains height", climbed > low + 0.5, (low, climbed));

    // ---- A banks left, D banks right -------------------------------------
    world.command("stop");
    world.step(2);
    let yaw = world.number("goat.yaw");
    world.command("turn left");
    world.step(40);
    let roll = world.number("flightRoll");
    let left = world.number("goat.yaw");
    checks.check("A banks left", roll < -0.2, roll);
    checks.check("...and raises the yaw", left > yaw + 0.1, (yaw, left));

    world.command("turn right");
    world.step(60);
    let roll = world.number("flightRoll");
    let right = world.number("goat.yaw");
    checks.check("D banks right", roll > 0.2, roll);
    checks.check("...and lowers the yaw", right < left, (left, right));
    world.command("turn stop");

    // ---- Space flaps: height, count, energy, cooldown ---------------------
    world.step(30); // level out, and past any flap cooldown
    let flaps = world.number("flightFlaps");
    let energy = world.number("stats.energy");
    let height = world.number("goat.py");
    // In flight the `jump` verb is the flap (the touch overlay's button).
    world.command("jump");
    world.step(2);
    let lifted = world.number("goat.py");
    checks.check(
        "Space lifts the goat",
        lifted > height + 0.05,
        (height, lifted),
    );
    let counted = world.number("flightFlaps");
    checks.check(
        "...counts the flap",
        counted == flaps + 1.0,
        (flaps, counted),
    );
    let paid = energy - world.number("stats.energy");
    checks.check("...and charges for it", paid > 1.0, paid);

    world.command("jump");
    world.step(2);
    let still = world.number("flightFlaps");
    checks.check(
        "the cooldown refuses a second flap",
        still == flaps + 1.0,
        (flaps, still),
    );
    world.step(28); // 0.5 s in all, past the 0.45 s cooldown
    world.command("jump");
    world.step(2);
    let again = world.number("flightFlaps");
    checks.check(
        "...and the next flap after it counts",
        again == flaps + 2.0,
        (flaps, again),
    );

    // ---- the drain -------------------------------------------------------
    let before = world.number("stats.energy");
    world.step(60);
    let after = world.number("stats.energy");
    checks.check(
        "flying drains energy",
        before - after > 2.0,
        (before, after),
    );

    // ---- an empty goat cannot flap ---------------------------------------
    world.eval("stats.energy = 0");
    world.step(30);
    let flaps = world.number("flightFlaps");
    world.command("jump");
    world.step(2);
    let refused = world.number("flightFlaps");
    checks.check(
        "a flap with no energy is refused",
        refused == flaps,
        (flaps, refused),
    );
}

/// E ends the flight; the crate's fall damage lands on contact.
fn release_cases(checks: &mut Checks) {
    let mut world = World::new();
    world.arm();
    world.take_off();
    world.step(6);

    // ---- a low release is free -------------------------------------------
    let health = world.number("stats.health");
    let reply = world.command("release");
    checks.check("E ends the flight", reply == "ok release", reply);
    checks.check(
        "...and the goat falls",
        world.mode() == "fall",
        world.mode(),
    );
    checks.check(
        "...and the bird is gone",
        !world.flag("flightCapable"),
        world.flag("flightCapable"),
    );
    checks.check(
        "...which the scene calls airborne",
        world.flag("goatAirborne()"),
        world.flag("goatAirborne()"),
    );
    let falling = world.number("stats.health");
    checks.check(
        "a fall is not damage per frame",
        falling == health,
        (health, falling),
    );
    world.step(120);
    checks.check(
        "a short fall lands on its feet",
        world.mode() != "fall" && world.mode() != "dead",
        world.mode(),
    );
    checks.check(
        "...with no damage",
        world.number("stats.health") == health,
        (health, world.number("stats.health")),
    );

    // ---- a long release hurts --------------------------------------------
    world.arm();
    world.take_off();
    world.step(4);
    // 40 m up: the fall's impact is well over `safeFall`, and it takes about
    // 1.6 s, so the mid-air reads below have room.
    world.eval("goat.py = 40");
    let health = world.number("stats.health");
    world.command("release");
    world.step(30);
    checks.check(
        "a long fall is still falling",
        world.mode() == "fall",
        world.mode(),
    );
    checks.check(
        "...and has not been hurt yet",
        world.number("stats.health") == health,
        (health, world.number("stats.health")),
    );
    world.step(150);
    checks.check("a long fall lands", world.mode() != "fall", world.mode());
    let hurt = health - world.number("stats.health");
    checks.check("...and hurts", hurt > 10.0, hurt);

    // ---- a lethal fall dies on contact -----------------------------------
    world.command("restart");
    world.arm();
    world.take_off();
    world.step(4);
    world.eval("goat.py = 40; stats.health = 1");
    world.command("release");
    world.step(30);
    checks.check(
        "a lethal fall is not a death in the air",
        world.mode() == "fall",
        world.mode(),
    );
    world.step(150);
    checks.check(
        "...it is one on contact",
        world.mode() == "dead",
        world.mode(),
    );
}

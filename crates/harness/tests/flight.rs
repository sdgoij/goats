//! Captured-bird flight, on the scene's own frame loop.
//!
//! The mechanics live in `crates/flight` and reach the scene through the
//! `__flight` global (`crates/flight-js`). What this file is for is the
//! *integration*: that a running jump with the capability takes off, that the
//! ground controls mean the flight controls in the air, that a release is a
//! fall carrying the crate's damage, and that the scene's own numbers agree with
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
        let mut harness = Harness::start().expect("evaluate the scene");
        // An empty touch timeline: `touch.js` is inert and the stub's scripted
        // keyboard stands down, so only the console's held keys move the goat.
        harness.touch(&json!([])).expect("the touch surface");
        // No bots: the flight is the player's, and the herd is the expensive half
        // of a frame. This also shortens the load to its nine steps.
        harness.eval("goats.bots.setCount(0)").expect("the herd");
        harness.run(LOAD).expect("load the scene");
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
fn the_captured_bird_flies() {
    let mut checks = Checks::new();
    take_off_cases(&mut checks);
    control_cases(&mut checks);
    release_cases(&mut checks);
    checks.finish();
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

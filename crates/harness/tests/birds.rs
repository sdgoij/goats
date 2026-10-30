//! The ported `birds` mod cases: `tools/birds_mod_test.js`, on the engine.
//!
//! The birds mod is the worked example of a mod that adds an entity of its own: it
//! builds its meshes and bakes a texture, runs six animation states with boid
//! flocking, publishes the flock through the world extension, and uses the surface
//! M19g added (`goats.explosions`) to set devices off and to give the goat a little
//! back while a bird sits on it. Nothing here needs the frame loop -- the cases drive
//! `modEmit("update")` and `modEmit("draw3d")` themselves, the way the Node harness
//! did.
//!
//! **One live world at a time, deliberately.** Two live engine contexts with one
//! of them being stepped aborts the process (STATUS_ACCESS_VIOLATION, reliably
//! reproducible from a fresh process), so each case owns its world inside a scope
//! and the determinism case snapshots one world's payload before opening the
//! second. It reads the same as the Node harness's assertion -- two fresh worlds
//! with the same seed publish the same flock -- without ever holding two stepped
//! contexts.
//!
//! A staging failure is fatal, as it was in the Node file, which never wrapped
//! these in a `try`.
//!
//! The flock's `update` is the heaviest JavaScript the suite runs, and in a debug
//! build it overflows the engine's interpreter stack (`README.md` §Troubleshooting:
//! unoptimized builds spend far more stack per activation, so `--release` is where
//! the headroom is). The test is therefore `#[ignore]`d and driven in release,
//! where it is 12s against 79s in debug:
//!
//! ```text
//! cargo test --release -p harness --test birds -- --ignored --nocapture
//! ```

mod support;

use harness::Harness;
use serde_json::json;
use support::{Checks, f64_of, net_feed, try_command_json};

/// The step the cases drive the mod with: the same fixed step the stub reports,
/// so the flock runs at the rate the game would.
const DT: f64 = 1.0 / 60.0;

/// `ST` in the mod, and the body height above the ground that "dry" is measured against
/// (`dryAt` is `goats.water.depthAt <= LEG`). The state index is the fifth number in the
/// row the flock publishes, which is the only per-bird state a case can read from here.
const ST_IDLE: f64 = 0.0;
const ST_WALK: f64 = 1.0;
const BIRD_LEG: f64 = 0.13;

/// The mod's entry, compiled in so a broken fixture fails at build time too.
const BIRDS_SRC: &str = include_str!("../../../mods/birds/mod.js");

/// A world with the birds mod loaded.
struct World {
    harness: Harness,
    id: String,
}

impl World {
    /// A fresh scene with the real fixture loaded the way the host loads it: the
    /// metadata table, the entry inside its wrapper, the result, then the freeze.
    fn new() -> World {
        let mut harness = Harness::start().expect("evaluate the scene");
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../../../mods/birds/mod.json"))
                .expect("the birds manifest");
        let id = manifest["id"].as_str().expect("the birds id").to_string();

        // The asset map the host builds for this mod: its own squawk slot, under opaque
        // names (`read_slot` uses `mod:<id>:<slot>:<index><ext>`; the loader test in
        // `crates/mods` is what checks the declared files are really on disk). The
        // recording `rl` resolves any name it is handed, so these stand in for the bytes
        // the host would register.
        let assets = json!({ "sfx.squawk": [
            format!("mod:{id}:sfx.squawk:0.mp3"),
            format!("mod:{id}:sfx.squawk:1.mp3"),
        ] });
        let table = json!([{
            "id": manifest["id"],
            "name": manifest["name"],
            "version": manifest["version"],
            "api": manifest["api"],
            "side": manifest["side"],
            "enabled": true,
            "hash": "0",
            "assets": assets,
            "tuning": null,
        }]);
        harness
            .call("sceneMods", &[json!(table.to_string())])
            .expect("sceneMods");
        let quoted = serde_json::to_string(&id).expect("a quoted id");
        harness
            .eval(&format!(
                "(function (goats) {{\n{BIRDS_SRC}\n}})(goats.begin({quoted}));"
            ))
            .expect("the birds entry");
        harness
            .call("sceneModResult", &[json!(id), json!(true), json!("")])
            .expect("sceneModResult");
        harness.call("sceneModFreeze", &[]).expect("sceneModFreeze");
        World { harness, id }
    }

    /// The same world with the scene's own frame loop, which is what a *real* jump
    /// needs -- `harnessStep` drives only the mods' update. The mod is loaded first,
    /// then `run()` loads the world exactly as the game does; it ends with
    /// `sceneShutdown`, so the herd is rebuilt and the flock is reseeded by the
    /// updates that follow.
    fn in_frame() -> World {
        World::in_frame_with_herd(0)
    }

    /// The frame-loop world with `herd` bots. The count is set both sides of `run()`:
    /// before because the load steps build the herd, and after because
    /// `sceneShutdown` unloads it.
    fn in_frame_with_herd(herd: u32) -> World {
        let mut world = World::new();
        // The stub's scripted keyboard stands down, so only the console's held keys
        // move the goat -- the same seam `crates/harness/tests/flight.rs` uses.
        world.harness.touch(&json!([])).expect("the touch surface");
        world
            .harness
            .eval(&format!("goats.bots.setCount({herd})"))
            .expect("the herd");
        world.harness.run(24).expect("load the scene");
        if herd > 0 {
            world
                .harness
                .eval(&format!("goats.bots.setCount({herd})"))
                .expect("the herd");
        }
        world
            .harness
            .call("harnessSetTotal", &[json!(1_000_000)])
            .expect("the frame budget");
        world.harness.reset_frame().expect("the frame clock");
        world
    }

    /// Advances the scene's own frame loop, for the cases that need the goat's real
    /// controllers rather than the mods' update alone.
    fn frame(&mut self, frames: u32) {
        for _ in 0..frames {
            let running = self.harness.call("sceneFrame", &[]).expect("sceneFrame");
            assert_eq!(running, json!(true), "the frame loop stopped mid-case");
        }
    }

    /// Runs one console line, failing the case loudly if it throws.
    fn command(&mut self, line: &str) -> String {
        self.harness
            .command(line)
            .unwrap_or_else(|error| panic!("{line}: {error}"))
    }

    fn text(&mut self, code: &str) -> String {
        self.harness
            .eval(code)
            .expect(code)
            .as_str()
            .unwrap_or("")
            .to_string()
    }

    fn number(&mut self, code: &str) -> f64 {
        f64_of(self.harness.eval(code).expect(code))
    }

    fn flag(&mut self, code: &str) -> bool {
        self.harness
            .eval(code)
            .expect(code)
            .as_bool()
            .unwrap_or(false)
    }

    /// Steps the mod's `update` `frames` times.
    fn step(&mut self, frames: u32) {
        self.harness
            .call("harnessStep", &[json!(frames), json!(DT)])
            .expect("harnessStep");
    }

    /// One `draw3d`, with a camera looking at the origin.
    fn draw(&mut self) {
        self.harness
            .call(
                "modEmit",
                &[
                    json!("draw3d"),
                    json!({
                        "x": 0.0, "y": 6.0, "z": 0.0,
                        "targetX": 0.0, "targetY": 1.0, "targetZ": 0.0,
                        "fov": 55.0
                    }),
                ],
            )
            .expect("modEmit draw3d");
    }

    /// The mod's own `birds` command, which reports the flock.
    fn status(&mut self) -> serde_json::Value {
        try_command_json(&mut self.harness, "birds").expect("birds status")
    }

    /// The flock as the host publishes it.
    fn published(&mut self) -> serde_json::Value {
        let id = self.id.clone();
        self.harness
            .call("sceneWorldMods", &[])
            .expect("sceneWorldMods")["data"][id]
            .clone()
    }

    /// The flock as rows, for the geometry the cases do by hand. The payload is
    /// `{rows, riders}` since 1.2.0; the rows are what the geometry reads.
    fn flock(&mut self) -> Vec<serde_json::Value> {
        self.published()
            .get("rows")
            .and_then(|rows| rows.as_array())
            .cloned()
            .unwrap_or_default()
    }

    /// The host's rider map: bird index (as a string key) to the rider's identity.
    fn riders(&mut self) -> serde_json::Value {
        self.published()
            .get("riders")
            .cloned()
            .unwrap_or(serde_json::Value::Null)
    }

    /// Teleports the player, which is how a case moves the flock's home.
    fn teleport(&mut self, x: f64, z: f64) {
        self.harness
            .eval(&format!("goats.player.teleport({x:.2}, {z:.2})"))
            .expect("teleport");
    }

    /// The player's energy and health: what a bird on the goat's back moves.
    fn stats(&mut self) -> (f64, f64) {
        let energy = self
            .harness
            .eval("goats.player.state().energy")
            .expect("energy");
        let health = self
            .harness
            .eval("goats.player.state().health")
            .expect("health");
        (f64_of(energy), f64_of(health))
    }

    /// Empties the herd, so a bot cannot trip a device of its own into a case that is
    /// counting bangs. Called before the load steps run, so no bot is ever created.
    fn no_herd(&mut self) {
        self.harness.eval("goats.bots.setCount(0)").expect("herd");
    }
}

/// A state's count, or zero when the flock is not in it: the Node harness wrote
/// `s.idle || 0`, and a missing key must read as none rather than as a NaN.
fn count(states: &serde_json::Value, name: &str) -> f64 {
    states[name].as_f64().unwrap_or(0.0)
}

/// The first bird's height above the ground under the player: the perch's own height
/// when the goat is standing, plus whatever the goat has climbed.
fn bird_lift(world: &mut World) -> f64 {
    let ground = f64_of(
        world
            .harness
            .eval("goats.world.terrainHeight(goat.px, goat.pz)")
            .expect("ground"),
    );
    f64_of(world.flock()[0][1].clone()) - ground
}

/// How many times the flock's squawk has been heard. The mod declares two files for one
/// slot and picks between them at random, so either opaque name counts.
fn squawks(world: &mut World) -> u32 {
    let id = world.id.clone();
    let obs = world.harness.observe().expect("observe");
    let mut plays = 0;
    for index in 0..2 {
        let name = format!("mod:{id}:sfx.squawk:{index}.mp3");
        plays += obs.sound_plays.get(&name).copied().unwrap_or(0);
    }
    plays
}

#[test]
#[ignore = "a release build: the debug stack cannot take the flock's update (79s debug, 12s release)"]
fn the_birds_mod_works() {
    let mut checks = Checks::new();
    the_cases(&mut checks);
    checks.finish();
}

/// Every case in order, mirroring `birds_mod_test.js`.
fn the_cases(checks: &mut Checks) {
    // ---- build, animate, publish and scatter, on one world -------------------
    {
        let mut world = World::new();
        world.step(1);
        let counters = world.harness.observe().expect("observe").counters;
        checks.check(
            "meshes and a generated texture are built",
            counters.terrain_meshes_built == 3
                && counters.textures_made == 1
                && counters.texture_binds >= 3,
            &counters,
        );

        world.draw();
        let after_draw = world.status();
        let logs = world.harness.observe().expect("observe").logs;
        checks.check(
            "the draw handler does not throw",
            !logs.iter().any(|line| line.contains("handler threw")),
            logs,
        );

        let counters = world.harness.observe().expect("observe").counters;
        checks.check(
            "the flock spawns and draws body plus two wings each",
            after_draw["count"] == json!(6) && counters.models_drawn >= 18,
            (after_draw["count"].clone(), counters.models_drawn),
        );
        checks.check(
            "a `birds` command reports the flock",
            after_draw["local"] == json!(true),
            after_draw["local"].clone(),
        );

        // A minute of simulation, recording which states are reached and the
        // closest two flying birds ever get.
        let mut seen: Vec<String> = Vec::new();
        let mut min_gap = f64::INFINITY;
        for _ in 0..(3600 / 30) {
            world.step(30);
            let status = world.status();
            if let Some(states) = status["states"].as_object() {
                for name in states.keys() {
                    if !seen.iter().any(|seen| seen == name) {
                        seen.push(name.clone());
                    }
                }
            }
            let birds = world.flock();
            for a in 0..birds.len() {
                if birds[a][4] != json!(3) {
                    continue;
                }
                for b in (a + 1)..birds.len() {
                    if birds[b][4] != json!(3) {
                        continue;
                    }
                    let dx = f64_of(birds[a][0].clone()) - f64_of(birds[b][0].clone());
                    let dz = f64_of(birds[a][2].clone()) - f64_of(birds[b][2].clone());
                    min_gap = min_gap.min((dx * dx + dz * dz).sqrt());
                }
            }
        }
        for name in ["idle", "walk", "takeoff", "fly", "land"] {
            checks.check(
                &format!("reaches the {name} state"),
                seen.iter().any(|seen| seen == name),
                &seen,
            );
        }
        checks.check(
            "boid separation keeps flying birds apart",
            min_gap > 0.3,
            min_gap,
        );

        // The published flock has to fit the world datagram budget. Seven numbers a
        // row since protocol 12: the five the flock has always sent, then the attitude
        // a `RIDE` bird inherits from its goat (`FLIGHT.md` §6.2); the rider map beside
        // them is empty unless somebody is aboard.
        let flock = world.published();
        let payload = serde_json::to_string(&flock).expect("the payload");
        let rows = flock.get("rows").and_then(|rows| rows.as_array());
        checks.check(
            "the published flock is one compact record per bird",
            rows.is_some_and(|rows| {
                rows.len() == 6
                    && rows
                        .iter()
                        .all(|row| row.as_array().is_some_and(|row| row.len() == 7))
            }) && flock
                .get("riders")
                .and_then(|r| r.as_object())
                .is_some_and(|r| r.is_empty()),
            (&flock, payload.len()),
        );
        checks.check(
            "the flock payload stays within the world datagram budget",
            payload.len() < 250,
            payload.len(),
        );

        // `scatter` is the command with an observable effect on the flock.
        let before = world.flock()[0].clone();
        let accepted =
            world.harness.command("birds scatter").expect("scatter") == "ok birds scattered";
        let mut moved = false;
        if accepted {
            world.step(1);
            let after = world.published()[0].clone();
            moved = before[0] != after[0] || before[2] != after[2];
        }
        checks.check("`birds scatter` is accepted", accepted, accepted);
        checks.check("`birds scatter` moves a bird", moved, &before);
    }

    // ---- a client mirrors the host ------------------------------------------
    {
        let mut client = World::new();
        net_feed(&mut client.harness, r#"{"type":"welcome","name":"eve"}"#).expect("welcome");
        let mut data = serde_json::Map::new();
        data.insert(
            client.id.clone(),
            json!([[20, 9, -20, 0.5, 3], [26, 9, -26, 0.5, 3]]),
        );
        client
            .harness
            .call("sceneApplyWorldMods", &[json!({ "data": data })])
            .expect("sceneApplyWorldMods");
        client.step(120);
        let mirrored = client.flock();
        checks.check(
            "a client adopts the host flock size",
            mirrored.len() == 2,
            mirrored.len(),
        );
        checks.check(
            "a client eases toward the host snapshot",
            (f64_of(mirrored[0][0].clone()) - 20.0).abs() < 1.5
                && (f64_of(mirrored[0][2].clone()) + 20.0).abs() < 1.5
                && (f64_of(mirrored[1][0].clone()) - 26.0).abs() < 1.5,
            &mirrored[0],
        );
        checks.check(
            "a client keeps the host animation state",
            mirrored[0][4] == json!(3) && mirrored[1][4] == json!(3),
            (mirrored[0][4].clone(), mirrored[1][4].clone()),
        );
        checks.check(
            "a client does not simulate",
            (f64_of(mirrored[0][1].clone()) - 9.0).abs() < 0.6,
            mirrored[0][1].clone(),
        );
    }

    // ---- a flung bird is published as flung -----------------------------------
    // The state is the whole of what travels: the arc, the tumble and the flap are the
    // state clock's, which both ends derive, so a client gets a flung bird out of the
    // same five numbers as any other.
    {
        let mut client = World::new();
        net_feed(&mut client.harness, r#"{"type":"welcome","name":"eve"}"#).expect("welcome");
        let mut data = serde_json::Map::new();
        data.insert(client.id.clone(), json!([[10, 4, 10, 0.0, 6]]));
        client
            .harness
            .call("sceneApplyWorldMods", &[json!({ "data": data })])
            .expect("sceneApplyWorldMods");
        client.step(30);
        let states = client.status()["states"].clone();
        checks.check(
            "a client mirrors a flung bird as flung",
            count(&states, "flung") == 1.0,
            &states,
        );
    }

    // ---- perching ------------------------------------------------------------
    // Birds may land on the player's goat; over two minutes at least one should.
    {
        let mut perch = World::new();
        let mut perched = false;
        for _ in 0..240 {
            perch.step(30);
            if count(&perch.status()["states"], "perch") > 0.0 {
                perched = true;
                break;
            }
        }
        checks.check("a bird perches on a goat", perched, perched);
    }

    // ---- a bird sets off a device, and is thrown by it ------------------------
    // The M19g surface, in the mod that motivated it: a bird walking over a device
    // trips it through the core's own blast path and is flung away. The herd is
    // emptied first, because a bot trips devices of its own and this case counts bangs.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(120);
        let trips_before = f64_of(world.status()["trips"].clone());
        let mines_before = f64_of(world.status()["mineTrips"].clone());
        let traps_before = f64_of(world.status()["trapTrips"].clone());
        let squawks_before = squawks(&mut world);
        let blasts_before = f64_of(
            world
                .harness
                .eval("sceneExplosions().blasts")
                .expect("blasts"),
        );
        let moved_before = f64_of(
            world
                .harness
                .eval("sceneExplosions().moved")
                .expect("moved"),
        );

        let sent = world.harness.command("birds boom mine").expect("boom");
        let accepted = sent == "ok bird sent to the mine";
        world.step(1);
        let flung = world.status();
        checks.check("`birds boom` sends a bird to a mine", accepted, sent);
        checks.check(
            "a bird on a mine trips it, and is flung",
            count(&flung["states"], "flung") >= 1.0
                && f64_of(flung["trips"].clone()) == trips_before + 1.0
                && f64_of(flung["mineTrips"].clone()) == mines_before + 1.0
                && f64_of(flung["trapTrips"].clone()) == traps_before,
            &flung,
        );
        // ...and it goes out with a squawk: one of the two macaw calls its manifest
        // declares, played on the mod's own handle rather than through the core's effects.
        let heard = squawks(&mut world) - squawks_before;
        checks.check("a flung bird squawks once", heard == 1, heard);
        checks.check(
            "the bang goes through the core's own blast path",
            f64_of(
                world
                    .harness
                    .eval("sceneExplosions().blasts")
                    .expect("blasts"),
            ) > blasts_before,
            blasts_before,
        );
        // The device is spent where the bang happened, and its replacement moves in:
        // without that (`modBlast` spends the cell, M19g) the bird would land on the
        // same armed mine and be thrown by it again, and the field would never drift.
        checks.check(
            "the device is spent and its replacement moves in",
            f64_of(
                world
                    .harness
                    .eval("sceneExplosions().moved")
                    .expect("moved"),
            ) > moved_before,
            moved_before,
        );

        // ...and it comes down, and goes back to being a bird.
        world.step(300);
        let landed = world.status();
        checks.check(
            "a flung bird lands and walks on",
            count(&landed["states"], "flung") == 0.0,
            &landed["states"],
        );
    }

    // ---- a query finds the trap it is standing on -----------------------------
    // `sceneTraps` is the surface a mod asks "what is near me" with (`goats.explosions.traps`),
    // and a trap is **not** at its cell's centre: it is on the tuft, which sits at the
    // cell's even corner -- up to 1.4 m away -- plus its own jitter. Filtering the *cell*
    // by that centre (which is where a mine is, and how the mines are found) hides every
    // tuft jittered away from the middle, and a query from right on top of one comes back
    // empty. That is what made "birds trigger mines but not traps" true for most traps.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(120);
        let field = try_command_json(&mut world.harness, "traps 40").expect("traps");
        let traps = field["traps"].as_array().cloned().unwrap_or_default();
        let mut found = 0;
        for trap in &traps {
            let tx = f64_of(trap["x"].clone());
            let tz = f64_of(trap["z"].clone());
            let at = world
                .harness
                .eval(&format!("sceneTraps({tx:.3}, {tz:.3}, 0.6).traps.length"))
                .expect("sceneTraps");
            if f64_of(at) >= 1.0 {
                found += 1;
            }
        }
        checks.check(
            "a trap is reported from its own tuft",
            !traps.is_empty() && found == traps.len(),
            (found, traps.len()),
        );
    }

    // ---- a bird sets off a trapped tuft ---------------------------------------
    // The kind matters as much as the bang: a trap sits on the *tuft*, which is not at
    // its cell's centre, so a bird sent to one is the case that tells a query which
    // reports the trap at its own position but filters the cell by the centre.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(120);
        let trips_before = f64_of(world.status()["trips"].clone());
        let mines_before = f64_of(world.status()["mineTrips"].clone());
        let traps_before = f64_of(world.status()["trapTrips"].clone());
        let sent = world.harness.command("birds boom trap").expect("boom");
        let accepted = sent == "ok bird sent to the trap";
        world.step(1);
        let flung = world.status();
        checks.check(
            "`birds boom trap` sends a bird to a trapped tuft",
            accepted,
            sent,
        );
        checks.check(
            "a bird on a trapped tuft sets it off, and is flung",
            count(&flung["states"], "flung") >= 1.0
                && f64_of(flung["trips"].clone()) == trips_before + 1.0
                && f64_of(flung["trapTrips"].clone()) == traps_before + 1.0
                && f64_of(flung["mineTrips"].clone()) == mines_before,
            &flung,
        );
    }

    // ---- a bird on the goat's back --------------------------------------------
    // The friends: while a bird sits on the player, the goat's energy and health
    // climb. Below the ceiling, because both are clamped at `stats.max` and a goat at
    // full health gives nothing to show; and with the field emptied, so no bird's own
    // bang can take the health back while the case is watching it.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(120);
        world
            .harness
            .eval("goats.tuning.set(\"explosions.mine.density\", 0)")
            .expect("density");
        world
            .harness
            .eval("goats.tuning.set(\"explosions.trap.chance\", 0)")
            .expect("chance");
        world.harness.eval("sceneResetDevices()").expect("reset");
        world
            .harness
            .eval("stats.energy = 40; stats.health = 40")
            .expect("stats");

        // The control: with no bird aboard, the two numbers must not move at all.
        // `harnessStep` drives the mods' update rather than the scene's own frame, so
        // the goat's idle drain is not in this loop -- which makes the gift the only
        // thing that can move it, and that is what the next two checks read.
        let (e0, h0) = world.stats();
        world.step(300);
        let (e1, h1) = world.stats();
        checks.check(
            "nothing moves the goat with no bird on it",
            (e1 - e0).abs() < 0.01 && (h1 - h0).abs() < 0.01,
            (e0, e1, h0, h1),
        );

        let sat = world.harness.command("birds sit").expect("sit") == "ok birds sitting";
        world.step(2);
        let perched = world.status();
        let (e2, h2) = world.stats();
        world.step(300);
        let (e3, h3) = world.stats();
        checks.check(
            "`birds sit` puts a bird on the goat",
            sat && count(&perched["states"], "perch") >= 1.0,
            &perched["states"],
        );
        checks.check(
            "a bird on the goat gives its energy back",
            e3 > e2 + 10.0,
            (e2, e3),
        );
        checks.check("...and its health", h3 > h2 + 5.0, (h2, h3));
    }

    // ---- a bird rides its goat up ---------------------------------------------
    // The perch sits on the goat's *back*, so a goat that leaves the ground takes the
    // bird with it -- a blasted goat, in the game (M19c's arc), which is why the perch
    // reads the goat's own height. The arc itself cannot be flown here: `harnessStep`
    // drives the mods' update rather than the scene's frame, so the height is set and
    // the case reads what the perch does with it.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(120);
        let sat = world.harness.command("birds sit").expect("sit") == "ok birds sitting";
        world.step(2);
        let perched_at = bird_lift(&mut world);
        world.harness.eval("goat.py = 2.4").expect("py");
        world.step(1);
        let flying_at = bird_lift(&mut world);
        checks.check(
            "a bird on a goat that leaves the ground goes with it",
            sat && (flying_at - perched_at - 2.4).abs() < 0.06,
            (perched_at, flying_at),
        );
    }

    // ---- a moving player -----------------------------------------------------
    // A landing must terminate even when the flock's home is moving: chasing a
    // running goat forever once left birds hanging in the air, never settling.
    {
        let mut mover = World::new();
        let mut ground_samples = 0.0;
        let mut land_samples = 0.0;
        for i in 0..120 {
            for k in 0..30 {
                let t = f64::from(i * 30 + k) * DT;
                mover.teleport((t * 0.1).cos() * 25.0, (t * 0.1).sin() * 25.0);
                mover
                    .harness
                    .call("modEmit", &[json!("update"), json!(DT)])
                    .expect("modEmit");
            }
            let states = mover.status()["states"].clone();
            ground_samples +=
                count(&states, "idle") + count(&states, "walk") + count(&states, "perch");
            land_samples += count(&states, "land");
        }
        checks.check(
            "birds settle while the player moves",
            ground_samples > 20.0 && ground_samples > land_samples,
            (ground_samples, land_samples),
        );
    }

    // ---- a herd --------------------------------------------------------------
    // With a herd present the flock still follows the moving player, not the herd:
    // trailing the herd left the birds behind, where they looked like they had
    // vanished.
    {
        let mut herd = World::new();
        for i in 0..6 {
            herd.harness.call("botAdd", &[json!(i)]).expect("botAdd");
        }
        let mut herd_far: f64 = 0.0;
        for i in 0..180 {
            let t = f64::from(i) * 0.5;
            herd.teleport((t * 0.1).cos() * 20.0, (t * 0.1).sin() * 20.0);
            herd.step(30);
            herd_far = herd_far.max(f64_of(herd.status()["far"].clone()));
        }
        let status = herd.status();
        checks.check(
            "the flock follows the player past a herd",
            status["anchor"] == json!("player") && herd_far < 45.0,
            (&status["anchor"], herd_far),
        );
    }

    // ---- determinism ---------------------------------------------------------
    // The same seed runs the same flock. The payload is snapshotted rather than
    // holding both worlds: see the note at the top.
    let first = {
        let mut world = World::new();
        world.step(900);
        world.published()
    };
    let second = {
        let mut world = World::new();
        world.step(900);
        world.published()
    };
    checks.check("the same seed runs the same flock", first == second, first);

    // ---- gather, fly, land and unload ---------------------------------------
    {
        let mut world = World::new();
        world.step(600);
        world.teleport(40.0, -20.0);
        let gathered = world.harness.command("birds gather").expect("gather")
            == "ok birds gathered"
            && f64_of(world.status()["far"].clone()) < 5.0;
        checks.check(
            "`birds gather` brings the flock to the player",
            gathered,
            world.status(),
        );

        let lifted = if world.harness.command("birds fly").expect("fly") == "ok birds flying" {
            world.step(1);
            let status = world.status();
            count(&status["states"], "takeoff") + count(&status["states"], "fly")
                == f64_of(status["count"].clone())
        } else {
            false
        };
        checks.check("`birds fly` lifts the whole flock", lifted, world.status());

        let landed = if world.harness.command("birds land").expect("land") == "ok birds landing" {
            let status = world.status();
            count(&status["states"], "land") == f64_of(status["count"].clone())
        } else {
            false
        };
        checks.check(
            "`birds land` puts the whole flock down",
            landed,
            world.status(),
        );

        let id = world.id.clone();
        world
            .harness
            .call("sceneModEnd", &[json!(id)])
            .expect("sceneModEnd");
        let unloaded = world
            .harness
            .observe()
            .expect("observe")
            .counters
            .models_unloaded;
        checks.check("unloading frees the models", unloaded == 3, unloaded);
    }

    // ---- the water: the flock does not stand under it -------------------------
    // A bird stands on the *ground*, and the ground is under the water wherever a pool is,
    // so a bird already down takes off when the water reaches it and one that walks in
    // takes off on the step that puts its feet under; a descent over a pool gives up
    // rather than settling a centimetre under the surface, which is where the flock used to
    // end up -- a pair of wings and no bird. The seam is `goats.water.depthAt`, a plain
    // function, and it is the only half of the water reachable from here: `harnessStep`
    // drives the mods' update rather than the scene's frame, so `sceneWater()` never
    // advances and the depth has to be read per bird, from the ground each one is over.
    {
        let mut world = World::new();
        world.no_herd();
        world.teleport(0.0, 0.0);
        // The ground, built the way the load builds it. A harness that never runs a scene
        // *frame* gets no grid and therefore no water field at all: `makeTerrain` is the
        // scene's own init for the ground (`terrainDetail` is the handle it makes first,
        // and `terrainEnsure` returns early until it exists), and it is what fills the grid
        // `waterDepthAt` reads. Anchored on the goat, which is why the teleport comes first.
        world.harness.eval("makeTerrain()").expect("makeTerrain");
        // A dry field next, whatever the seeded sky has been doing: the flock is meant to
        // *stand* before the pool arrives, or the check below has nothing to hold.
        world.harness.eval("rainAmount = 0").expect("rain");
        world
            .harness
            .call("waterStep", &[json!(1.0e6)])
            .expect("waterStep");
        world
            .harness
            .eval("goats.water.clear()")
            .expect("the table back");
        world.step(240);
        world.harness.command("birds land").expect("birds land");
        world.step(240);
        let dry = world.status();
        let down = count(&dry["states"], "idle") + count(&dry["states"], "walk");
        checks.check("the flock stands on dry ground", down > 0.0, &dry["states"]);

        // The pool. Big enough that the question cannot be "did the flock happen to be on
        // high ground": the flock is held inside `HOME_R` of its home and turns back at
        // `HOME_R + 6`, so the highest ground over a disc wider than that is the level which
        // puts every bird over water -- measured, with half a metre over the highest of it,
        // rather than guessed.
        let level = f64_of(
            world
                .harness
                .eval(
                    "(function () { const p = goats.player.state(); let hi = -Infinity; \
                     for (let z = -22; z <= 22; z += 1) { \
                     for (let x = -22; x <= 22; x += 1) { \
                     if (x * x + z * z > 22 * 22) continue; \
                     const g = terrainHeight(p.x + x, p.z + z); if (g > hi) hi = g; } } \
                     return hi; })()",
                )
                .expect("the highest ground the flock lives over"),
        );
        world
            .harness
            .eval(&format!("goats.water.setLevel({})", level + 0.5))
            .expect("the pool");

        // The grace, and it is a grace rather than a measurement: a bird that was standing
        // when the water arrived needs the frames a takeoff takes, and this is not a case
        // about the arc.
        world.step(120);

        // Every frame from there, per bird: no bird in a *ground* state with the water over
        // its feet. `perch` is not one of them -- a bird on a goat's back is not standing on
        // the ground -- and `land` is not either, because a descent over water is exactly
        // what is supposed to be given up rather than completed.
        let mut under = 0.0;
        let mut settled = 0.0;
        let mut wet = 0.0;
        for _ in 0..240 {
            world.step(1);
            let states = world.status()["states"].clone();
            settled += count(&states, "idle") + count(&states, "walk");
            for row in world.flock() {
                let st = row[4].as_f64().unwrap_or(-1.0);
                let x = f64_of(row[0].clone());
                let z = f64_of(row[2].clone());
                let depth = f64_of(
                    world
                        .harness
                        .eval(&format!("goats.water.depthAt({x}, {z})"))
                        .expect("depth"),
                );
                if depth > BIRD_LEG {
                    wet += 1.0;
                    if st == ST_IDLE || st == ST_WALK {
                        under += 1.0;
                    }
                }
            }
        }
        checks.check(
            "the pool is over the ground the flock lives on",
            wet > 0.0,
            (wet, level),
        );
        // Both halves of one statement, kept apart so a failure says which: no bird is
        // *standing* in the water, and the flock does not settle on it at all. Without the
        // gate in `stepIdle` and `stepWalk` the flood would simply leave them where they
        // stood -- the flock it reached would go on grazing with its feet under the surface.
        checks.check(
            "no bird stands where the water is over its feet",
            under == 0.0 && settled == 0.0,
            (under, settled, wet),
        );
    }

    // ---- a bird is captured, rides, flies and is released ---------------------
    // The mechanics are the scene's (`crates/flight`); what this block is for is the
    // mod half: the capture *is* a jump, the seat is the goat's back point in 3D, and
    // `E` gives the bird back (`FLIGHT.md` §4). A real jump needs the scene's frame,
    // not `harnessStep`.
    {
        let mut world = World::in_frame();
        world.frame(2);
        let sat = world.command("birds sit") == "ok birds sitting";
        world.frame(1);
        let perched = world.status();
        checks.check(
            "`birds sit` seats a bird before the capture",
            sat && count(&perched["states"], "perch") == 1.0 && perched["captured"] == json!(0),
            &perched,
        );

        // A jump with the bird aboard is the capture. There is no capability yet, so
        // it is an ordinary jump -- and the bird's grant is what comes out of it.
        world.command("stop");
        world.command("jump");
        world.frame(1);
        let caught = world.status();
        checks.check(
            "a jump with a bird on the goat captures it",
            caught["captured"] == json!(1) && caught["riders"] == json!(["player"]),
            &caught,
        );
        checks.check(
            "...and grants the goat the captured bird",
            world.flag("flightCapable"),
            world.flag("flightCapable"),
        );

        // The state waits for the jump to end, then publishes `ride`. The clip's
        // length is the model's, so this waits for the mode rather than for a number.
        for _ in 0..240 {
            if world.text("mode") != "jump" {
                break;
            }
            world.frame(1);
        }
        world.frame(2);
        let riding = world.status();
        checks.check(
            "the bird publishes `ride` when the jump ends",
            count(&riding["states"], "ride") == 1.0,
            &riding["states"],
        );
        checks.check(
            "a ride's row carries the attitude",
            world
                .flock()
                .first()
                .and_then(|row| row.as_array())
                .is_some_and(|row| row.len() == 7),
            world.flock(),
        );

        // Run + jump is the take-off.
        world.command("run");
        world.command("jump");
        world.frame(2);
        checks.check(
            "a run + jump with a captured bird takes off",
            world.text("mode") == "fly",
            world.text("mode"),
        );
        checks.check(
            "...and the scene calls it airborne",
            world.flag("goatAirborne()"),
            world.flag("goatAirborne()"),
        );

        // The seat is the goat's *back point*: the crate's own `backPoint` at the perch
        // height, which is where the goat's mesh rotates. `S` noses up, so after this
        // the seat is not the flat perch any more -- which is the whole point of the
        // rotation.
        world.command("back");
        world.frame(90);
        let pitch = world.number("goats.player.state().pitch");
        checks.check("the flight pitches up on `S`", pitch > 0.2, pitch);
        let seat = world
            .harness
            .eval(
                "(function () { const b = __flight.backPoint(playerFlightState(), 1.15, \
                 goats.tuning.get('explosions.fling.pivot')); \
                 return [b[0], b[1], b[2]]; })()",
            )
            .expect("the crate's back point");
        let seat = seat.as_array().cloned().unwrap_or_default();
        let row = world.flock()[0].clone();
        let off = (f64_of(row[0].clone()) - f64_of(seat[0].clone())).abs()
            + (f64_of(row[1].clone()) - f64_of(seat[1].clone())).abs()
            + (f64_of(row[2].clone()) - f64_of(seat[2].clone())).abs();
        checks.check(
            "the rider sits on the goat's back point",
            seat.len() == 3 && off < 0.25,
            (row, seat),
        );

        // `E` is the release: the bird leaves and the goat falls.
        world.command("release");
        world.frame(2);
        let released = world.status();
        let away = count(&released["states"], "takeoff") + count(&released["states"], "fly");
        checks.check(
            "`E` releases the bird and the goat falls",
            released["captured"] == json!(0) && away >= 1.0,
            &released,
        );
        checks.check(
            "...with the capability gone",
            !world.flag("flightCapable"),
            world.flag("flightCapable"),
        );
        world.frame(240);
        checks.check(
            "...and the goat is back on the ground",
            world.text("mode") != "fall" && world.number("goat.py") <= 0.01,
            (world.text("mode"), world.number("goat.py")),
        );
    }

    // ---- a rider still heals its goat ----------------------------------------
    // The perch's gift is the energy that pays for a flight, and it must not stop when
    // the bird is captured (`FLIGHT.md` §4.5). `harnessStep` drives the mods' update
    // alone, so the goat's own idle drain is not in this loop -- which makes the gift
    // the only thing that can move the two numbers.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(2);
        // The control's own numbers: half-full, so the gift is visible against the
        // clamp rather than hidden by it.
        let _ = world.harness.eval("stats.energy = 40; stats.health = 40");
        let mounted = world.command("birds mount") == "ok bird mounted";
        world.step(2);
        let riding = world.status();
        let (e0, h0) = world.stats();
        world.step(300);
        let (e1, h1) = world.stats();
        checks.check(
            "`birds mount` puts a rider on the goat",
            mounted && count(&riding["states"], "ride") == 1.0,
            &riding["states"],
        );
        checks.check(
            "a rider heals its goat",
            e1 > e0 + 10.0 && h1 > h0 + 5.0,
            (e0, e1, h0, h1),
        );

        // A bird is not a resurrection: the heal is gated on a living goat, and a dead
        // one lets the bird go on the same frame (`updateRiders`).
        let _ = world.harness.eval("mode = 'dead'; stats.health = 0;");
        let (e2, h2) = world.stats();
        world.step(120);
        let (e3, h3) = world.stats();
        let after = world.status();
        checks.check(
            "a rider does not revive a dead goat",
            (e3 - e2).abs() < 0.01 && (h3 - h2).abs() < 0.01 && after["captured"] == json!(0),
            (e2, e3, h2, h3, &after["captured"]),
        );
    }

    // ---- the herd flies too --------------------------------------------------
    // `birds ride 0` is the same grant on a bot; its next zoomies hop is the take-off
    // (`bots.js`), and a landing keeps the bird (`FLIGHT.md` §4.2, §9).
    {
        let mut world = World::in_frame_with_herd(1);
        world.frame(30);
        // A short flight so the landing is in this case rather than eighteen seconds out.
        let _ = world.harness.eval("tuningSet('flight.botTime', 1.5)");
        let rode = world.command("birds ride 0");
        checks.check(
            "`birds ride` puts a bird on a bot",
            rode == "ok bird riding bot 0",
            rode,
        );
        let mut flew = false;
        for _ in 0..240 {
            world.frame(1);
            if world.text("BOTS[0].mode") == "fly" {
                flew = true;
                break;
            }
        }
        checks.check(
            "a bot with a captured bird flies",
            flew,
            world.text("BOTS[0].mode"),
        );
        world.frame(30);
        checks.check(
            "...and climbs into the ring",
            world.number("BOTS[0].py") > 0.3,
            world.number("BOTS[0].py"),
        );
        world.frame(240);
        checks.check(
            "a bot lands with the bird still aboard",
            world.text("BOTS[0].mode") != "fly" && world.flag("BOTS[0].flightCapable"),
            (
                world.text("BOTS[0].mode"),
                world.flag("BOTS[0].flightCapable"),
            ),
        );
    }

    // ---- a bird that lands on a bot is captured by its next hop --------------
    // The herd's capture *is* the hop it takes during a zoomies run (`bots.js`,
    // `FLIGHT.md` §3.3), so a run must not shake a bird off its back -- and a real run
    // hops only every half second or so, because `botNewAction` puts the next hop on
    // cooldown the moment it starts one. `stepPerch` used to leave on the frame its
    // rider's gait changed, which for a bot is the first frame of that run: the bird was
    // gone a second before the hop that would have captured it, so no bot ever captured
    // a bird and the herd never flew.
    {
        let mut world = World::in_frame_with_herd(1);
        world.frame(30);
        let run = || "goats.bots.get(0).zoomies(6)";
        // A run, and its first hop: the next hop is now on cooldown, which is the window
        // a bird has to survive.
        let _ = world.harness.eval(run()).expect("zoomies");
        let mut hopped = false;
        for _ in 0..300 {
            world.frame(1);
            if world.text("BOTS[0].mode") == "jump" {
                hopped = true;
                break;
            }
        }
        checks.check(
            "a bot with the zoomies hops",
            hopped,
            world.text("BOTS[0].mode"),
        );
        let _ = world.harness.eval(run()).expect("zoomies");
        let sat = world.command("birds sit 0");
        world.frame(1);
        let after = world.status();
        checks.check(
            "a bird on a running bot's back stays there",
            sat == "ok bird sitting on bot 0"
                && count(&after["states"], "perch") == 1.0
                && !world.flag("BOTS[0].flightCapable"),
            (sat, after),
        );
        // The hop the run was already heading for is the capture.
        let mut caught = false;
        for _ in 0..300 {
            let _ = world.harness.eval(run());
            world.frame(1);
            if world.flag("BOTS[0].flightCapable") {
                caught = true;
                break;
            }
        }
        checks.check(
            "a bot's run captures the bird on its back",
            caught,
            (world.text("BOTS[0].mode"), world.status()),
        );
        let mut flew = false;
        for _ in 0..300 {
            let _ = world.harness.eval(run());
            world.frame(1);
            if world.text("BOTS[0].mode") == "fly" {
                flew = true;
                break;
            }
        }
        checks.check(
            "...and the bot's next hop is the take-off",
            flew,
            (world.text("BOTS[0].mode"), world.status()),
        );
    }

    // ---- a joiner mirrors a ride ---------------------------------------------
    // The host publishes the seat and the attitude; a client is not told *which* goat
    // a bird chose and does not need to be (`FLIGHT.md` §8).
    {
        let mut world = World::new();
        world.no_herd();
        world.step(1);
        let id = world.id.clone();
        world.harness.eval("netMode = 'client'").expect("client");
        let mut data = serde_json::Map::new();
        data.insert(id, json!([[12.0, 3.0, -4.0, 0.5, 7, 0.3, -0.2]]));
        world
            .harness
            .call("sceneApplyWorldMods", &[json!({ "data": data })])
            .expect("apply");
        world.step(30);
        let row = world.flock()[0].clone();
        checks.check(
            "a client mirrors a `ride` bird's seat and attitude",
            row[4] == json!(7)
                && (f64_of(row[0].clone()) - 12.0).abs() < 0.5
                && (f64_of(row[1].clone()) - 3.0).abs() < 0.5
                && (f64_of(row[2].clone()) + 4.0).abs() < 0.5
                && (f64_of(row[5].clone()) - 0.3).abs() < 0.03
                && (f64_of(row[6].clone()) + 0.2).abs() < 0.03,
            row,
        );
        let _ = world.harness.eval("netMode = 'off'");
    }

    // ---- unload takes the grant with it --------------------------------------
    // The bird granted the capability, so a flock that is unloaded must not leave a
    // goat armed with nothing on its back.
    {
        let mut world = World::new();
        world.harness.call("botAdd", &[json!(0)]).expect("botAdd");
        world.step(2);
        let mounted = world.command("birds mount") == "ok bird mounted";
        let _ = world.harness.eval("BOTS[0].flightCapable = true");
        let id = world.id.clone();
        world
            .harness
            .call("sceneModEnd", &[json!(id)])
            .expect("sceneModEnd");
        checks.check(
            "unloading the flock clears the goat's and the herd's grants",
            mounted && !world.flag("flightCapable") && !world.flag("BOTS[0].flightCapable"),
            (
                mounted,
                world.flag("flightCapable"),
                world.flag("BOTS[0].flightCapable"),
            ),
        );
    }

    // ---- a joiner's goat is captured by the host ----------------------------
    // `FLIGHT.md` §8: the host's flock reads the joiners through `goats.peers`, a jump in
    // a peer's snapshot is the capture, and the rider map tells the peer's own client to
    // grant itself. No wire field changed -- the peer state already carried the mode.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(2);
        // One peer, in the shape `net.js` `netPeerState` takes. A closure keeps the four
        // things that matter (gait, height, pitch, roll) readable.
        let peer = |gait: &str, py: f64, pitch: i32, roll: i32| {
            json!({"type": "peer", "name": "alice", "state": {
                "x": 2.0, "z": -1.0, "yaw": 0.5, "phase": 0.0,
                "gait": gait, "py": py, "pitch": pitch, "roll": roll,
            }})
            .to_string()
        };
        net_feed(&mut world.harness, &peer("idle", 0.0, 0, 0)).expect("peer");
        world.step(1);
        let listed = world.harness.eval("goats.peers.list()").expect("peers");
        checks.check(
            "the host reads a joiner through `goats.peers`",
            listed.as_array().is_some_and(|rows| {
                rows.len() == 1
                    && rows[0]["name"] == json!("alice")
                    && rows[0]["mode"] == json!("idle")
            }),
            listed,
        );

        let sat =
            world.harness.command("birds sit alice").expect("sit") == "ok bird sitting on alice";
        world.step(1);
        let perched = world.status();
        checks.check(
            "`birds sit <peer>` perches a bird on a joiner's goat",
            sat && count(&perched["states"], "perch") == 1.0,
            &perched,
        );

        // The jump is the capture, from the peer's own mode: the host never sees its keys.
        net_feed(&mut world.harness, &peer("jump", 0.0, 0, 0)).expect("jump");
        world.step(1);
        let caught = world.status();
        checks.check(
            "a joiner's jump captures the bird",
            caught["captured"] == json!(1) && caught["riders"] == json!(["alice"]),
            &caught,
        );
        checks.check(
            "the rider map names the joiner",
            world.riders() == json!({"0": "alice"}),
            world.riders(),
        );

        net_feed(&mut world.harness, &peer("run", 0.0, 0, 0)).expect("run");
        world.step(2);
        checks.check(
            "...and the bird rides once the jump ends",
            count(&world.status()["states"], "ride") == 1.0,
            world.status(),
        );

        // The seat is the peer's back point, built from the peer's *broadcast* attitude --
        // the same `backPoint` the crate draws that peer's own goat with. `updatePeers` is
        // the scene's easing, which `harnessStep` does not run, so it is stepped here.
        net_feed(&mut world.harness, &peer("fly", 6.0, 20, -10)).expect("fly");
        let _ = world.harness.eval("updatePeers(10)");
        world.step(1);
        let seat = world
            .harness
            .eval(
                "(function () { const p = goats.peers.list()[0]; \
                 const b = __flight.backPoint([p.x, p.z, \
                 goats.world.terrainHeight(p.x, p.z) + p.y, p.yaw, p.pitch, p.roll, \
                 0, 0, 0, 0, 0, 1], 1.15, \
                 goats.tuning.get('explosions.fling.pivot')); \
                 return [b[0], b[1], b[2]]; })()",
            )
            .expect("the peer's back point");
        let seat = seat.as_array().cloned().unwrap_or_default();
        let row = world.flock()[0].clone();
        let off = (f64_of(row[0].clone()) - f64_of(seat[0].clone())).abs()
            + (f64_of(row[1].clone()) - f64_of(seat[1].clone())).abs()
            + (f64_of(row[2].clone()) - f64_of(seat[2].clone())).abs();
        checks.check(
            "the bird rides the joiner's back point",
            seat.len() == 3 && off < 0.25,
            (row, seat),
        );

        // A peer that leaves is a ride that ends: the flock drops the bird and the map.
        net_feed(
            &mut world.harness,
            &json!({"type": "left", "name": "alice"}).to_string(),
        )
        .expect("left");
        world.step(2);
        let gone = world.status();
        checks.check(
            "a joiner that leaves lets the bird go",
            gone["captured"] == json!(0) && world.riders() == json!({}),
            (&gone, world.riders()),
        );
    }

    // ---- a joiner is armed by the host's rider map ---------------------------
    // The other half of §8: the host publishes *who* is riding, and only that client can
    // arm its own goat. The grant is an edge -- a snapshot still naming the same bird must
    // not undo the joiner's own `E` -- so letting go clears it too.
    {
        let mut world = World::new();
        world.no_herd();
        world.step(1);
        let _ = world.harness.eval("netMode = 'client'; netName = 'alice'");
        let id = world.id.clone();
        let rows = json!([[0.0, 1.15, 0.0, 0.0, 7, 0.0, 0.0]]);
        let mut data = serde_json::Map::new();
        data.insert(
            id.clone(),
            json!({ "rows": rows.clone(), "riders": { "0": "alice" } }),
        );
        world
            .harness
            .call("sceneApplyWorldMods", &[json!({ "data": data })])
            .expect("apply");
        world.step(2);
        let ground = world.number("goats.world.terrainHeight(goat.px, goat.pz)");
        // The goat's own height above that ground, which the seat adds (`player.state().y`:
        // the cube fallback starts a little above it).
        let lift = world.number("goats.player.state().y").max(0.0);
        let row = world.flock()[0].clone();
        checks.check(
            "the host naming this goat grants its capability",
            world.flag("flightCapable"),
            world.flag("flightCapable"),
        );
        checks.check(
            "...and the bird is seated on this goat exactly",
            (f64_of(row[0].clone()) - world.number("goat.px")).abs() < 0.15
                && (f64_of(row[1].clone()) - (ground + lift + 1.15)).abs() < 0.15
                && (f64_of(row[2].clone()) - world.number("goat.pz")).abs() < 0.15,
            (row, ground, lift),
        );

        let mut data = serde_json::Map::new();
        data.insert(id, json!({ "rows": rows, "riders": {} }));
        world
            .harness
            .call("sceneApplyWorldMods", &[json!({ "data": data })])
            .expect("apply");
        world.step(1);
        checks.check(
            "the host letting go clears the grant",
            !world.flag("flightCapable"),
            world.flag("flightCapable"),
        );
    }
}

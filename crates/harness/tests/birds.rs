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

    /// The flock as rows, for the geometry the cases do by hand.
    fn flock(&mut self) -> Vec<serde_json::Value> {
        self.published().as_array().cloned().unwrap_or_default()
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

        // The published flock has to fit the world datagram budget.
        let flock = world.published();
        let payload = serde_json::to_string(&flock).expect("the payload");
        checks.check(
            "the published flock is one compact record per bird",
            flock.as_array().is_some_and(|rows| {
                rows.len() == 6
                    && rows
                        .iter()
                        .all(|row| row.as_array().is_some_and(|row| row.len() == 5))
            }),
            flock.as_array().map_or(0, Vec::len),
        );
        checks.check(
            "the flock payload stays within the world datagram budget",
            payload.len() < 250,
            payload.len(),
        );

        // `scatter` is the command with an observable effect on the flock.
        let before = world.published()[0].clone();
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
}

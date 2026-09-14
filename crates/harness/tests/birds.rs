//! The ported `birds` mod cases: `tools/birds_mod_test.js`, on the engine.
//!
//! The birds mod is the worked example of a mod that adds an entity of its own:
//! it builds its meshes and bakes a texture, runs five animation states with boid
//! flocking, and publishes the flock through the world extension. Nothing here
//! needs the frame loop -- the cases drive `modEmit("update")` and
//! `modEmit("draw3d")` themselves, the way the Node harness did.
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

        let table = json!([{
            "id": manifest["id"],
            "name": manifest["name"],
            "version": manifest["version"],
            "api": manifest["api"],
            "side": manifest["side"],
            "enabled": true,
            "hash": "0",
            "assets": {},
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
}

/// A state's count, or zero when the flock is not in it: the Node harness wrote
/// `s.idle || 0`, and a missing key must read as none rather than as a NaN.
fn count(states: &serde_json::Value, name: &str) -> f64 {
    states[name].as_f64().unwrap_or(0.0)
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
}

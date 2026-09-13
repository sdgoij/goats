//! The headless scene: the same JavaScript the client runs, evaluated against a
//! null `rl` so a dedicated server can own the world with no window.
//!
//! The engine has no dependency on raylib unless the `raylib` feature is on, so
//! this crate builds without it and `headless_rl.js` supplies the `rl` global the
//! scene expects. Everything the simulation reads is real (the clock, the model
//! clip table, the terrain height function); everything that only draws or reads
//! input does nothing. That is enough to run `sceneFrame` at a fixed step and
//! read the bots back out.
//!
//! The scene parts are the client's, in the client's order. `the_scene_list_
//! matches_the_clients` fails if that list and `crates/goats/src/main.rs` drift
//! apart, so the server can never be simulating a different game.

use slag::{Context, HostCallbacks, JsValue};

/// The null `rl` module, evaluated before the scene.
const HEADLESS_RL: &str = include_str!("headless_rl.js");

/// The scene parts, in the running order `crates/goats/src/main.rs` uses. Only
/// the drift test reads it; `SCENE` below is what actually gets evaluated.
#[cfg(test)]
const SCENE_PARTS: &[&str] = &[
    "core.js",
    "model.js",
    "world.js",
    "lighting.js",
    "sky.js",
    "audio.js",
    "weather.js",
    "food.js",
    "bots.js",
    "goat.js",
    "ctl.js",
    "menu.js",
    "console.js",
    "net.js",
    "mods.js",
];

/// The scene, joined exactly as the client joins it: one script, one scope, so
/// every part sees the others' functions and globals.
const SCENE: &str = concat!(
    include_str!("../../goats/src/game/core.js"),
    include_str!("../../goats/src/game/model.js"),
    include_str!("../../goats/src/game/world.js"),
    include_str!("../../goats/src/game/lighting.js"),
    include_str!("../../goats/src/game/sky.js"),
    include_str!("../../goats/src/game/audio.js"),
    include_str!("../../goats/src/game/weather.js"),
    include_str!("../../goats/src/game/food.js"),
    include_str!("../../goats/src/game/bots.js"),
    include_str!("../../goats/src/game/goat.js"),
    include_str!("../../goats/src/game/ctl.js"),
    include_str!("../../goats/src/game/menu.js"),
    include_str!("../../goats/src/game/console.js"),
    include_str!("../../goats/src/game/net.js"),
    include_str!("../../goats/src/game/mods.js"),
);

/// Appended to the scene: the one seam the server needs, a JSON view of the
/// world the session broadcasts. It can be a one-liner because the scene already
/// has `sceneWorldBots`, `sceneWeatherState`, `sceneStreams`, `sceneEaten` and
/// `JSON`.
const GLUE: &str = concat!(
    "\nfunction sceneWorldJson() { return JSON.stringify({",
    " bots: sceneWorldBots(), weather: sceneWeatherState(),",
    " streams: sceneStreams(), eaten: sceneEaten() }); }\n",
);

/// A running headless scene.
pub struct Sim {
    context: Context,
    frame: JsValue,
    world: JsValue,
    consume: JsValue,
}

impl Sim {
    /// Evaluates the scene, seeds it, and initialises it. The caller then drives
    /// [`Sim::step`] at whatever rate it wants; the scene's `dt` is a fixed
    /// 1/60 from the stub.
    pub fn start(seed: u32) -> Result<Sim, String> {
        let mut context = Context::new().map_err(|error| error.to_string())?;
        let callbacks = HostCallbacks {
            // The scene's own `console.log` lines are useful on a server, but
            // they are not the server's log format, so they are tagged.
            console_log: Some(Box::new(|text| eprintln!("[scene] {text}"))),
            ..HostCallbacks::default()
        };
        context.set_host_callbacks(callbacks);
        slag::install_jit(&mut context)?;

        let source = format!("{HEADLESS_RL}\n{SCENE}\n{GLUE}");
        context.eval(&source).map_err(|error| error.to_string())?;

        let seed_fn = scene_function(&context, "sceneUseSeed")?;
        let init = scene_function(&context, "sceneInit")?;
        let frame = scene_function(&context, "sceneFrame")?;
        let world = scene_function(&context, "sceneWorldJson")?;
        let consume = scene_function(&context, "sceneConsume")?;

        context
            .call(
                &seed_fn,
                &JsValue::undefined(),
                &[JsValue::number(seed as f64)],
            )
            .map_err(|error| error.to_string())?;
        context
            .call(&init, &JsValue::undefined(), &[])
            .map_err(|error| error.to_string())?;

        Ok(Sim {
            context,
            frame,
            world,
            consume,
        })
    }

    /// Advances the world one fixed step.
    pub fn step(&mut self) -> Result<(), String> {
        self.context
            .call(&self.frame, &JsValue::undefined(), &[])
            .map_err(|error| error.to_string())?;
        Ok(())
    }

    /// Records a bite a client reported, so the meadow the server broadcasts is
    /// the one everyone actually grazed.
    pub fn consume(&mut self, key: i64) -> Result<(), String> {
        self.context
            .call(
                &self.consume,
                &JsValue::undefined(),
                &[JsValue::number(key as f64)],
            )
            .map_err(|error| error.to_string())?;
        Ok(())
    }

    /// The bots, as a JSON array. The caller decides how often to take it.
    pub fn world_json(&mut self) -> Result<String, String> {
        let value = self
            .context
            .call(&self.world, &JsValue::undefined(), &[])
            .map_err(|error| error.to_string())?;
        value
            .as_string()
            .ok_or_else(|| "sceneWorldJson did not return a string".to_string())
    }
}

/// Looks up a global function by name.
fn scene_function(context: &Context, name: &str) -> Result<JsValue, String> {
    let value = context
        .global()
        .map_err(|error| error.to_string())?
        .get(name)
        .map_err(|error| error.to_string())?;
    if !value.is_undefined() {
        return Ok(value);
    }
    Err(format!("the scene defines no `{name}`"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Runs a world for `steps` frames and returns the bots as JSON.
    fn run_world(seed: u32, steps: usize) -> String {
        let mut sim = Sim::start(seed).expect("start the headless scene");
        for _ in 0..steps {
            sim.step().expect("step");
        }
        sim.world_json().expect("world json")
    }

    #[test]
    fn the_scene_list_matches_the_clients() {
        // The client's `main.rs` is the single source of truth for the running
        // order; this catches a part added there and forgotten here, which would
        // otherwise silently simulate a different game.
        const CLIENT_MAIN: &str = include_str!("../../goats/src/main.rs");
        for part in SCENE_PARTS {
            let wanted = format!("include_str!(\"game/{part}\")");
            assert!(
                CLIENT_MAIN.contains(&wanted),
                "crates/goats/src/main.rs does not include {part}"
            );
        }
        assert_eq!(
            CLIENT_MAIN.matches("include_str!(\"game/").count(),
            SCENE_PARTS.len(),
            "the server and the client disagree on how many scene parts there are"
        );
    }

    #[test]
    fn the_headless_scene_runs_a_herd() {
        // The scene needs ~16 frames to load (9 + the herd) and a few more to
        // settle. Each frame is real work, so this stays small.
        let json = run_world(0x1234_5678, 40);
        assert!(json.starts_with('{'), "expected a world object, got {json}");
        assert!(json.contains("\"bots\":"), "{json}");
        assert!(json.contains("\"weather\":"), "{json}");
        // The bots carry the fields the session broadcasts.
        assert!(json.contains("\"index\":"), "{json}");
        assert!(json.contains("\"gait\":"), "{json}");
        assert!(json.contains("\"phase\":"), "{json}");
        // And the sky, the streams and the meadow do too.
        assert!(json.contains("\"kind\":"), "{json}");
        assert!(json.contains("\"cloudiness\":"), "{json}");
        assert!(json.contains("\"world_time\":"), "{json}");
        assert!(json.contains("\"streams\":"), "{json}");
        assert!(json.contains("\"eaten\":"), "{json}");
    }

    #[test]
    #[ignore = "three fresh sims, and each one re-JITs the scene (~10s); run with -- --ignored"]
    fn the_same_seed_runs_the_same_world() {
        let a = run_world(0x1234_5678, 40);
        let b = run_world(0x1234_5678, 40);
        assert_eq!(a, b, "the same seed must run the same world");
        let c = run_world(0x0fed_cba9, 40);
        assert_ne!(a, c, "a different seed must run a different world");
    }
}

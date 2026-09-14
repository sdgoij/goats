//! The headless scene: the same JavaScript the client runs, evaluated against a
//! null `rl` so a dedicated server can own the world with no window.
//!
//! The engine has no dependency on raylib unless the `raylib` feature is on, so
//! this crate builds without it and `scene::NULL_RL` supplies the `rl` global the
//! scene expects. Everything the simulation reads is real (the clock, the model
//! clip table, the terrain height function); everything that only draws or reads
//! input does nothing. That is enough to run `sceneFrame` at a fixed step and
//! read the bots back out.
//!
//! The scene is the client's: `scene::SCENE` is one list of parts, joined the
//! same way for the client, this server and the test harness, so no two of them
//! can simulate a different game.

use slag::{Context, HostCallbacks, JsValue};

/// Appended to the scene: the seam the server needs, JSON views of what the
/// session broadcasts. They can be one-liners because the scene already has
/// `sceneWorldBots`, `sceneWeatherState`, `sceneStreams`, `sceneEaten`,
/// `sceneWorldMods`, `modWorldActive` and `JSON`.
///
/// Two views, because they travel on two datagrams: the world has a budget the
/// herd and the meadow share, and the world mods have one of their own.
const GLUE: &str = concat!(
    "\nfunction sceneWorldJson() { return JSON.stringify({",
    " bots: sceneWorldBots(), weather: sceneWeatherState(),",
    " streams: sceneStreams(), eaten: sceneEaten() }); }\n",
    "\nfunction sceneModsJson() {",
    " return modWorldActive() ? JSON.stringify(sceneWorldMods()) : \"\"; }\n",
);

/// A running headless scene.
pub struct Sim {
    context: Context,
    frame: JsValue,
    world: JsValue,
    mods: JsValue,
    consume: JsValue,
}

impl Sim {
    /// Evaluates the scene, loads the world mods, seeds it, and initialises it.
    /// The caller then drives [`Sim::step`] at whatever rate it wants; the
    /// scene's `dt` is a fixed 1/60 from the stub.
    pub fn start(seed: u32, loader: &mods::Loader) -> Result<Sim, String> {
        let mut context = Context::new().map_err(|error| error.to_string())?;
        let callbacks = HostCallbacks {
            // The scene's own `console.log` lines are useful on a server, but
            // they are not the server's log format, so they are tagged.
            console_log: Some(Box::new(|text| eprintln!("[scene] {text}"))),
            ..HostCallbacks::default()
        };
        context.set_host_callbacks(callbacks);
        slag::install_jit(&mut context)?;

        let source = format!("{}\n{}\n{GLUE}", scene::NULL_RL, scene::SCENE);
        context.eval(&source).map_err(|error| error.to_string())?;

        // The same mod wiring the client host uses: push the table, evaluate
        // each entry, close registration. It runs before `sceneUseSeed`, so a
        // mod's registered streams are seeded rather than left at their initial
        // value.
        load_mods(&mut context, loader)?;

        let seed_fn = scene_function(&context, "sceneUseSeed")?;
        let init = scene_function(&context, "sceneInit")?;
        let frame = scene_function(&context, "sceneFrame")?;
        let world = scene_function(&context, "sceneWorldJson")?;
        let mods = scene_function(&context, "sceneModsJson")?;
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
            mods,
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

    /// Every world mod's state, or `None` when none is loaded: there is nothing
    /// to send then, and an empty datagram ten times a second is waste.
    pub fn mods_json(&mut self) -> Result<Option<String>, String> {
        let value = self
            .context
            .call(&self.mods, &JsValue::undefined(), &[])
            .map_err(|error| error.to_string())?;
        let text = value
            .as_string()
            .ok_or_else(|| "sceneModsJson did not return a string".to_string())?;
        Ok(if text.is_empty() { None } else { Some(text) })
    }
}

/// Wires the loader's mods into a scene context, exactly as the client host
/// does: the metadata table, then each entry inside its wrapper, then the freeze.
/// A mod that throws is reported, never fatal.
fn load_mods(context: &mut Context, loader: &mods::Loader) -> Result<(), String> {
    let table = loader.table_json();
    call_scene(context, "sceneMods", &[JsValue::string(table)])?;
    for id in loader.ids() {
        let result = match loader.get(&id).and_then(|manifest| manifest.entry_js()) {
            Some(js) => match context.eval(&js) {
                Ok(_) => Ok(()),
                Err(error) => {
                    let message = error.to_string();
                    eprintln!("[mods] {id} failed: {message}");
                    Err(message)
                }
            },
            None => Ok(()),
        };
        match result {
            Ok(()) => call_scene(
                context,
                "sceneModResult",
                &[
                    JsValue::string(id.clone()),
                    JsValue::boolean(true),
                    JsValue::string(""),
                ],
            )?,
            Err(message) => call_scene(
                context,
                "sceneModResult",
                &[
                    JsValue::string(id.clone()),
                    JsValue::boolean(false),
                    JsValue::string(message),
                ],
            )?,
        }
    }
    call_scene(context, "sceneModFreeze", &[])
}

/// Calls one of the scene's host-facing functions, requiring it to exist.
fn call_scene(context: &mut Context, name: &str, args: &[JsValue]) -> Result<(), String> {
    let function = scene_function(context, name)?;
    context
        .call(&function, &JsValue::undefined(), args)
        .map(|_| ())
        .map_err(|error| error.to_string())
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
        let mut sim = Sim::start(seed, &mods::Loader::empty()).expect("start the headless scene");
        for _ in 0..steps {
            sim.step().expect("step");
        }
        sim.world_json().expect("world json")
    }

    #[test]
    fn a_world_mod_extension_reaches_the_world_json() {
        let dir = std::env::temp_dir().join(format!("goats-server-mod-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("dash")).unwrap();
        std::fs::write(
            dir.join("dash").join("mod.json"),
            r#"{ "id": "com.example.dash", "name": "Dash", "version": "1", "api": 1, "side": "world", "entry": "mod.js" }"#,
        )
        .unwrap();
        std::fs::write(
            dir.join("dash").join("mod.js"),
            "goats.world.registerStream(\"dash\", 1234);\n\
             goats.world.extend(\"com.example.dash\", {\n\
               publish: function () { return { active: true }; },\n\
               apply: function () {}\n\
             });\n",
        )
        .unwrap();
        let loader = mods::Loader::discover_with(&dir, mods::AssetMode::HashOnly);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());

        let mut sim = Sim::start(0x1234_5678, &loader).expect("start");
        for _ in 0..40 {
            sim.step().expect("step");
        }
        let json = sim.world_json().expect("world json");
        assert!(
            !json.contains("com.example.dash"),
            "the world must not carry a mod: {json}"
        );
        let mods = sim
            .mods_json()
            .expect("mods json")
            .expect("a mod is loaded");
        assert!(mods.contains("\"active\":true"), "{mods}");
        assert!(
            mods.contains("\"com.example.dash:dash\":"),
            "the stream state must travel: {mods}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_birds_fixture_loads_and_both_datagrams_fit() {
        // The checked-in `mods/birds` mod is the "complex mod" example: it builds
        // its own meshes and textures in JS and publishes its flock through the
        // world extension. This loads the real fixture through the real loader on
        // the headless scene and checks both datagrams fit -- the world without
        // the flock in it, and the flock on its own.
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mods");
        let loader = mods::Loader::discover_with(&dir, mods::AssetMode::HashOnly);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        assert!(
            loader.get("com.github.sdgoij.goats.birds").is_some(),
            "the birds mod must load"
        );

        let mut sim = Sim::start(0x1234_5678, &loader).expect("start");
        for _ in 0..120 {
            sim.step().expect("step");
        }
        let json = sim.world_json().expect("world json");
        assert!(
            !json.contains("com.github.sdgoij.goats.birds"),
            "the flock travels on its own datagram, not the world's: {json}"
        );
        assert!(
            json.len() < proto::MAX_DATAGRAM_BYTES,
            "the world snapshot is {} bytes, over the {} cap",
            json.len(),
            proto::MAX_DATAGRAM_BYTES
        );

        let mods = sim
            .mods_json()
            .expect("mods json")
            .expect("a mod is loaded");
        assert!(
            mods.contains("com.github.sdgoij.goats.birds"),
            "the flock must publish: {mods}"
        );
        assert!(
            mods.len() < proto::MAX_DATAGRAM_BYTES,
            "the mod state is {} bytes, over the {} cap",
            mods.len(),
            proto::MAX_DATAGRAM_BYTES
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

    #[test]
    #[ignore = "three fresh sims, and each one re-JITs the scene (~10s); run with -- --ignored"]
    fn the_same_seed_runs_the_same_modded_world() {
        // A world mod's seeded stream has to be as reproducible as the scene's
        // own: the server's snapshot is what every client mirrors, so a mod
        // that draws from a stream must land on the same numbers everywhere.
        let dir =
            std::env::temp_dir().join(format!("goats-server-mod-seed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("dash")).unwrap();
        std::fs::write(
            dir.join("dash").join("mod.json"),
            r#"{ "id": "com.example.dash", "name": "Dash", "version": "1", "api": 1, "side": "world", "entry": "mod.js" }"#,
        )
        .unwrap();
        std::fs::write(
            dir.join("dash").join("mod.js"),
            "goats.world.registerStream(\"dash\", 99);\n\
             const rnd = goats.rng(\"dash\");\n\
             let n = 0;\n\
             goats.on(\"update\", function () { n += rnd(); });\n\
             goats.world.extend(\"com.example.dash\", {\n\
               publish: function () { return { n: n }; },\n\
               apply: function () {}\n\
             });\n",
        )
        .unwrap();
        let loader = mods::Loader::discover_with(&dir, mods::AssetMode::HashOnly);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());

        // The published state is what has to be reproducible, and it is now on
        // its own the datagram: the world snapshot no longer carries it.
        let run = |seed: u32| {
            let mut sim = Sim::start(seed, &loader).expect("start");
            for _ in 0..40 {
                sim.step().expect("step");
            }
            (
                sim.world_json().expect("world json"),
                sim.mods_json()
                    .expect("mods json")
                    .expect("a mod is loaded"),
            )
        };
        let (a, a_mods) = run(0x1234_5678);
        let (b, b_mods) = run(0x1234_5678);
        assert_eq!(a, b, "the same seed must run the same modded world");
        assert_eq!(a_mods, b_mods, "...including what the mod publishes");
        assert!(
            a_mods.contains("\"com.example.dash\""),
            "the mod must publish: {a_mods}"
        );
        assert!(
            !a.contains("com.example.dash"),
            "and not on the world's datagram: {a}"
        );
        let (c, c_mods) = run(0x0fed_cba9);
        assert_ne!(a, c, "a different seed must run a different modded world");
        assert_ne!(a_mods, c_mods, "...including what the mod publishes");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

//! The scene harness: the client's scene, evaluated on Slag against the
//! recording `rl`, so the tests need no Node, no raylib and no display.
//!
//! The split is deliberate. The fake engine stays JavaScript, because the scene
//! calls `rl` from JavaScript; everything else is here. A test starts a
//! [`Harness`], asks it to run the scripted timeline for a number of frames, and
//! gets the observations back as typed Rust.
//!
//! Running on Slag rather than on a model of it is the point: a binding or a
//! builtin the engine lacks now fails a test instead of passing one. The scene,
//! the two `rl` modules and the running order all come from `crates/scene`, so
//! this crate cannot drift from the client it is testing.
//!
//! The run is one Rust/JS crossing: [`Harness::run`] calls the glue, which drives
//! the scene's own `run()` loop and returns one JSON string. The frame indices
//! are absolute, so a short run sees the same input at the same frames as a long
//! one and simply stops earlier.

use slag::{Context, HostCallbacks, JsValue};

/// The entry points appended after the scene. See the file for what they do.
const GLUE: &str = include_str!("glue.js");

/// A running scene.
pub struct Harness {
    context: Context,
    run_fn: JsValue,
    command_fn: JsValue,
    ready_fn: JsValue,
}

/// One recorded frame, as the stub saw it.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct Frame {
    /// The frame index, counted from the first frame after the scene loaded.
    pub i: u32,
    /// The player goat's clip, from the last `updateModelAnimation`.
    pub clip: Option<String>,
    /// The HUD's speed line.
    pub speed: String,
    /// The HUD's stats line.
    pub stats: String,
    /// The HUD's weather line.
    pub weather: String,
}

/// Everything the stub recorded, read back as one JSON object.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Observations {
    /// Frames spent drawing the splash, before the scene was ready.
    pub loading_frames: u32,
    /// How many models `loadModel` was asked for (the goat, then the herd).
    pub model_loads: u32,
    /// The asset paths `loadModel` was asked for.
    pub model_paths: Vec<String>,
    /// The run, one row per ready frame.
    pub timeline: Vec<Frame>,
    /// The splash drew the game's name.
    pub splash_title: bool,
    /// The splash's `loading N / M` line.
    pub splash_step: String,
    /// Cubes drawn, which the shadow pass and the grass both use.
    pub cube_draws: u32,
    /// Everything written to the clipboard, in order.
    pub clipboard_writes: Vec<String>,
}

impl Observations {
    /// The recorded frame at `i`, if the run reached it.
    pub fn row(&self, i: u32) -> Option<&Frame> {
        self.timeline.iter().find(|frame| frame.i == i)
    }

    /// The player's clip at `i`, if any was recorded.
    pub fn clip_at(&self, i: u32) -> Option<&str> {
        self.row(i).and_then(|frame| frame.clip.as_deref())
    }

    /// Whether the clip at `i` is `base` or one of its numbered variants, the
    /// way the scene picks `GoatIdle` / `GoatIdle2` / `GoatIdle3`.
    pub fn is_clip(&self, i: u32, base: &str) -> bool {
        self.clip_at(i).is_some_and(|clip| clip.starts_with(base))
    }

    /// Every clip the run played, in order.
    pub fn clips(&self) -> Vec<&str> {
        self.timeline
            .iter()
            .filter_map(|frame| frame.clip.as_deref())
            .collect()
    }
}

impl Harness {
    /// Evaluates the two `rl` modules, the scene and the glue. The scene is
    /// evaluated, so a syntax error anywhere in it fails here.
    pub fn start() -> Result<Harness, String> {
        let mut context = Context::new().map_err(|error| error.to_string())?;
        context.set_host_callbacks(HostCallbacks {
            // The scene's own `console.log` lines are worth seeing when a test
            // fails, but they are not the test's output, so they are tagged.
            console_log: Some(Box::new(|text| println!("[scene] {text}"))),
            ..HostCallbacks::default()
        });
        slag::install_jit(&mut context)?;

        let source = format!(
            "{}\n{}\n{}\n{GLUE}",
            scene::NULL_RL,
            scene::HARNESS_RL,
            scene::SCENE
        );
        context.eval(&source).map_err(|error| error.to_string())?;

        let run_fn = global_function(&context, "harnessRun")?;
        let command_fn = global_function(&context, "harnessCommand")?;
        let ready_fn = global_function(&context, "harnessReady")?;
        Ok(Harness {
            context,
            run_fn,
            command_fn,
            ready_fn,
        })
    }

    /// Whether the scene has finished loading.
    pub fn ready(&mut self) -> Result<bool, String> {
        let value = self
            .context
            .call(&self.ready_fn, &JsValue::undefined(), &[])
            .map_err(|error| error.to_string())?;
        value
            .as_boolean()
            .ok_or_else(|| "sceneReady did not return a boolean".to_string())
    }

    /// Runs the scripted timeline for up to `frames` ready frames and returns
    /// what the stub recorded. A harness runs once: the scene's loop ends with
    /// `sceneShutdown`.
    pub fn run(&mut self, frames: u32) -> Result<Observations, String> {
        let value = self
            .context
            .call(
                &self.run_fn,
                &JsValue::undefined(),
                &[JsValue::number(frames as f64)],
            )
            .map_err(|error| error.to_string())?;
        let json = value
            .as_string()
            .ok_or_else(|| "harnessRun did not return a string".to_string())?;
        serde_json::from_str(&json).map_err(|error| error.to_string())
    }

    /// Runs one line through the same dispatcher the console and stdin use.
    pub fn command(&mut self, line: &str) -> Result<String, String> {
        let value = self
            .context
            .call(
                &self.command_fn,
                &JsValue::undefined(),
                &[JsValue::string(line)],
            )
            .map_err(|error| error.to_string())?;
        value
            .as_string()
            .ok_or_else(|| format!("sceneCommand({line:?}) did not return a string"))
    }
}

/// Looks up a global function by name, requiring it to exist.
fn global_function(context: &Context, name: &str) -> Result<JsValue, String> {
    let value = context
        .global()
        .map_err(|error| error.to_string())?
        .get(name)
        .map_err(|error| error.to_string())?;
    if !value.is_undefined() {
        return Ok(value);
    }
    Err(format!("the harness defines no `{name}`"))
}

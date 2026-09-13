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
//! one and simply stops earlier. Anything the run does not cover is driven
//! afterwards through [`Harness::command`], [`Harness::call`] and
//! [`Harness::eval`], exactly as the host and the Node harness drove it.

use std::collections::BTreeMap;

use slag::{Context, HostCallbacks, JsValue};

/// The entry points appended after the scene. See the file for what they do.
const GLUE: &str = include_str!("glue.js");

/// A running scene.
pub struct Harness {
    context: Context,
    run_fn: JsValue,
    command_fn: JsValue,
    ready_fn: JsValue,
    call_fn: JsValue,
    eval_fn: JsValue,
    observe_fn: JsValue,
    reset_fn: JsValue,
}

/// One recorded frame, as the stub saw it.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct Frame {
    /// The frame index, counted from the first frame after the scene loaded.
    pub i: u32,
    /// The player goat's clip, from the last `updateModelAnimation`.
    pub clip: Option<String>,
    /// The HUD's speed line, which also carries the clock, the lighting, the
    /// audio state and the sky state.
    pub speed: String,
    /// The HUD's stats line.
    pub stats: String,
    /// The HUD's weather line.
    pub weather: String,
}

/// Where a model was drawn.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct Draw {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

/// The terrain mesh as facts. The arrays themselves are large and every check
/// only asks how many there are, so they are summarised rather than shipped.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeshFacts {
    /// Vertex count (`vertices.length / 3`).
    pub verts: usize,
    pub indices: usize,
    pub normals: usize,
    pub colors: usize,
    pub texcoords: usize,
    /// The mesh's height range, `max y - min y`.
    pub y_spread: f64,
    /// How many distinct vertex colours it carries.
    pub materials: usize,
}

/// The console's state, as the `console` command reports it.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct ConsoleState {
    pub open: bool,
    pub input: String,
    pub caret: u32,
    pub history: Vec<String>,
    /// One `kind: text` string per scrollback entry.
    pub lines: Vec<String>,
}

/// The console and screen state at a probed frame.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct Probe {
    /// The goat's drawn x, so a test can show movement stops with the console open.
    pub x: Option<f64>,
    pub z: Option<f64>,
    pub ui: String,
    pub state: ConsoleState,
}

/// The counters the stub keeps.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Counters {
    pub model_loads: u32,
    pub bot_poses: u32,
    pub bot_jumps: u32,
    pub music_updates: u32,
    pub sounds_played: u32,
    pub cube_draws: u32,
    pub shadow_cube_draws: u32,
    pub menu_draws: u32,
    pub progress_bar_calls: u32,
    pub terrain_meshes_built: u32,
}

/// Everything the stub recorded, read back as one JSON object.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Observations {
    /// Frames spent drawing the splash, before the scene was ready.
    pub loading_frames: u32,
    pub splash_title: bool,
    pub splash_step: String,
    /// The asset paths `loadModel` was asked for.
    pub model_paths: Vec<String>,
    pub music_loads: Vec<String>,
    pub sound_loads: Vec<String>,
    /// The run, one row per ready frame.
    pub timeline: Vec<Frame>,
    /// The console and screen state at the probed frames, keyed by frame.
    pub probes: BTreeMap<String, Probe>,
    pub counters: Counters,
    /// Which shader handle each model was set to, in order.
    pub model_shader_calls: Vec<i64>,
    /// `[index, texture]` per `setModelTexture`, in order.
    pub model_texture_calls: Vec<Vec<i64>>,
    pub music_played: Vec<i64>,
    /// Every clip name a bot played.
    pub bot_clip_names: Vec<String>,
    pub bot_count: u32,
    /// The closest the bots ever came, from their log line.
    pub min_gap: Option<f64>,
    pub bot_belly_max: f64,
    pub bot_graze_walks: f64,
    pub bot_idles: Vec<String>,
    pub player_idles: Vec<String>,
    /// Every distinct clip the player played, in order.
    pub player_clips: Vec<String>,
    /// The frame the death clip started, or -1.
    pub death_frame: i64,
    pub mesh: Option<MeshFacts>,
    /// Where the goat was drawn, at the end of the run.
    pub goat_draw: Option<Draw>,
    /// Where each bot was last drawn, one entry per bot.
    pub bot_draw: Vec<Draw>,
    /// The sky fragment shader's source, so a test can assert what it contains.
    pub sky_fs: String,
    pub clipboard_writes: Vec<String>,
    /// The scene's own `console.log` lines.
    pub logs: Vec<String>,
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

    /// The probe taken at frame `i`.
    pub fn probe(&self, i: u32) -> Option<&Probe> {
        self.probes.get(&i.to_string())
    }

    /// The HUD's speed at frame `i`, in m/s. The line reads `... speed 0.87 m/s`.
    pub fn speed_at(&self, i: u32) -> Option<f64> {
        let rest = after(&self.row(i)?.speed, "speed ")?;
        rest.get(..rest.find(" m/s")?)?.parse().ok()
    }

    /// The HUD's health and energy at frame `i`.
    pub fn stat_at(&self, i: u32) -> Option<Stats> {
        let line = &self.row(i)?.stats;
        Some(Stats {
            health: int_after(line, "health ")?,
            energy: int_after(line, "energy ")?,
        })
    }

    /// The clock at frame `i`, as minutes since midnight, from the `HH:MM` that
    /// opens the speed line.
    pub fn clock_at(&self, i: u32) -> Option<u32> {
        let (hours, minutes) = self.row(i)?.speed.get(0..5)?.split_once(':')?;
        Some(hours.parse::<u32>().ok()? * 60 + minutes.parse::<u32>().ok()?)
    }

    /// The lighting state at frame `i`.
    pub fn light_at(&self, i: u32) -> Option<&str> {
        one_of(&self.row(i)?.speed, "light ", LIGHT)
    }

    /// The audio state at frame `i`.
    pub fn audio_at(&self, i: u32) -> Option<&str> {
        one_of(&self.row(i)?.speed, "audio ", AUDIO)
    }

    /// The sky state at frame `i`.
    pub fn sky_at(&self, i: u32) -> Option<&str> {
        one_of(&self.row(i)?.speed, "sky ", SKY)
    }

    /// The HUD's weather line at frame `i`.
    pub fn weather_at(&self, i: u32) -> Option<&str> {
        Some(self.row(i)?.weather.as_str())
    }
}

/// The health and energy the HUD reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    pub health: i64,
    pub energy: i64,
}

/// The lighting states the HUD names, longest first so a prefix cannot win.
const LIGHT: &[&str] = &[
    "lit + shadow map",
    "lit + planar shadow",
    "cube shader",
    "lit",
    "off",
];

/// The audio states the HUD names.
const AUDIO: &[&str] = &["muted", "on", "off"];

/// The sky states the HUD names.
const SKY: &[&str] = &["shader", "billboards"];

/// The text after the first `marker` in `line`.
fn after<'a>(line: &'a str, marker: &str) -> Option<&'a str> {
    line.find(marker).map(|at| &line[at + marker.len()..])
}

/// The integer after `marker`, up to the next non-digit.
fn int_after(line: &str, marker: &str) -> Option<i64> {
    let rest = after(line, marker)?;
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    rest.get(..end)?.parse().ok()
}

/// Which of `values` follows `marker`. They are listed longest first, so a value
/// that is a prefix of another cannot win.
fn one_of<'a>(line: &'a str, marker: &str, values: &[&'a str]) -> Option<&'a str> {
    let rest = after(line, marker)?;
    values
        .iter()
        .find(|value| rest.starts_with(**value))
        .copied()
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

        Ok(Harness {
            run_fn: global_function(&context, "harnessRun")?,
            command_fn: global_function(&context, "harnessCommand")?,
            ready_fn: global_function(&context, "harnessReady")?,
            call_fn: global_function(&context, "harnessCall")?,
            eval_fn: global_function(&context, "harnessEval")?,
            observe_fn: global_function(&context, "harnessObserve")?,
            reset_fn: global_function(&context, "harnessResetCounters")?,
            context,
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

    /// The observations again, re-read from the stub. This is how a test sees
    /// what changed after driving the scene itself -- a counter reset, a tuft
    /// drawn, a command run.
    pub fn observe(&mut self) -> Result<Observations, String> {
        let value = self
            .context
            .call(&self.observe_fn, &JsValue::undefined(), &[])
            .map_err(|error| error.to_string())?;
        let json = value
            .as_string()
            .ok_or_else(|| "harnessObserve did not return a string".to_string())?;
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

    /// Calls a scene function by name and returns its value as JSON. The failure
    /// is the scene's own message, not a conversion error.
    pub fn call(
        &mut self,
        name: &str,
        args: &[serde_json::Value],
    ) -> Result<serde_json::Value, String> {
        let args_json = serde_json::to_string(args).map_err(|error| error.to_string())?;
        let value = self
            .context
            .call(
                &self.call_fn,
                &JsValue::undefined(),
                &[JsValue::string(name), JsValue::string(args_json)],
            )
            .map_err(|error| error.to_string())?;
        let reply = value
            .as_string()
            .ok_or_else(|| format!("harnessCall({name:?}) did not return a string"))?;
        envelope(&reply)
    }

    /// Evaluates a snippet in the scene's scope and returns its value as JSON.
    pub fn eval(&mut self, code: &str) -> Result<serde_json::Value, String> {
        let value = self
            .context
            .call(
                &self.eval_fn,
                &JsValue::undefined(),
                &[JsValue::string(code)],
            )
            .map_err(|error| error.to_string())?;
        let reply = value
            .as_string()
            .ok_or_else(|| "harnessEval did not return a string".to_string())?;
        envelope(&reply)
    }

    /// Zeroes named counters, so a test can measure one thing at a time.
    pub fn reset_counters(&mut self, names: &[&str]) -> Result<(), String> {
        let names_json = serde_json::to_string(names).map_err(|error| error.to_string())?;
        let value = self
            .context
            .call(
                &self.reset_fn,
                &JsValue::undefined(),
                &[JsValue::string(names_json)],
            )
            .map_err(|error| error.to_string())?;
        let reply = value
            .as_string()
            .ok_or_else(|| "harnessResetCounters did not return a string".to_string())?;
        if reply == "ok" { Ok(()) } else { Err(reply) }
    }
}

/// Unwraps the `{ok, value}` / `{ok, error}` envelope the glue returns.
fn envelope(reply: &str) -> Result<serde_json::Value, String> {
    let value: serde_json::Value = serde_json::from_str(reply)
        .map_err(|error| format!("unreadable reply {reply:?}: {error}"))?;
    if value.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
        return Ok(value
            .get("value")
            .cloned()
            .unwrap_or(serde_json::Value::Null));
    }
    Err(value
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("the scene reported an error")
        .to_string())
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

//! The GDExtension Godot loads.
//!
//! This crate is the seam between the Godot project in `godot/` and the rest of
//! the repository's Rust. It registers the library with Godot and exposes two
//! nodes:
//!
//! * [`net::NetBridge`] — the networking bridge over `session` and `proto` (see
//!   `godot/PORT.md` section 7).
//! * [`ModHost`] — the mod runtime: Slag, plus the `goats`/`rl` facade a mod
//!   sees (`godot/PORT.md` section 6).
//!
//! Why these are Rust and not GDScript: iroh, the packed `proto` wire, the mod
//! loader and the JavaScript engine are all Rust, and the port's claim to
//! compatibility is that it links *these* rather than reimplementing them.
//!
//! The scene is GDScript (`godot/PORT.md` section 4): Godot owns the loop and
//! the renderer, and JavaScript is kept for mods only.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::rc::Rc;

use godot::prelude::*;
use slag::{Context, HostCallbacks, JsObject, JsValue};

mod net;

/// The JavaScript facade (`goats`, `rl`) evaluated once, before any mod runs.
const PRELUDE: &str = include_str!("prelude.js");

/// The library entry point. Godot calls the `gdext_rust_init` symbol this macro
/// generates, which is what `godot/goat.gdextension` names.
struct GoatsGodot;

#[gdextension]
unsafe impl ExtensionLibrary for GoatsGodot {}

/// A `GString` from anything stringy. `GString` has no `From<String>`, and
/// every message here is built with `format!`.
fn gstring(text: impl AsRef<str>) -> GString {
    GString::from(text.as_ref())
}

// ---------------------------------------------------------------------------
// ModHost: the embedded JavaScript engine, for mods.
// ---------------------------------------------------------------------------

/// Lines the extension has produced for the Godot side to drain: log output and
/// queued draw calls.
///
/// They are queued rather than signalled, because a mod's JavaScript runs inside
/// a `Context` this node owns, and emitting a Godot signal from there would
/// re-enter the node while it is borrowed. Queuing and draining is the same
/// shape the raylib client already uses for the network bridge
/// (`sceneNetEvent` / `sceneNetDrain`).
type LineQueue = Rc<RefCell<Vec<String>>>;

/// The engine and the facade object, built once on first use.
///
/// `Context` owns a JavaScript realm and is not `Send`/`Sync`; it is only ever
/// touched on Godot's main thread, which is what the `unsafe impl`s on
/// [`ModHost`] below assert.
struct Mod {
    context: Context,
    /// The `goats` object, kept so the host can reach `__invoke` and `__fireHud`
    /// without re-evaluating a lookup every call.
    goats: JsObject,
    /// What `crates/mods` discovered, once [`ModHost::load_mods`] has run. The
    /// loader owns the manifests, the ordering and the asset bytes; this crate
    /// only drives it.
    loader: Option<mods::Loader>,
    /// Every loaded mod's assets, by the opaque name a mod addresses them with
    /// (`APIv1.md` section 0: no paths reach a mod). The engine shim will read
    /// these; for now they prove the loader's asset half ran.
    assets: HashMap<String, Vec<u8>>,
}

/// The mod runtime: an embedded Slag context, the `goats`/`rl` facade, and the
/// values the core pushes in each frame.
#[derive(GodotClass)]
#[class(base=Node)]
struct ModHost {
    base: Base<Node>,
    /// Drained by [`ModHost::poll_lines`].
    lines: LineQueue,
    /// The clock the core pushes; a mod reads it through `goats.world.time()`.
    world_time: Rc<RefCell<f64>>,
    /// Built on first use so a node can be created before the engine is wanted.
    module: Option<Mod>,
    /// What became of each mod's entry, by id: `Ok(())` once it evaluated (or
    /// had no entry to run), `Err(text)` when it threw. The *loader* cannot know
    /// this -- a manifest is validated before anything runs -- so only the host
    /// that ran the entry can say it, which is why [`ModHost::mods_json`] merges
    /// it into the table rather than leaving every row `enabled: true`. It is
    /// `crates/goats/src/game/mods.js`'s `sceneModResult`, with the result folded
    /// into `sceneMods`' table instead of a second call from the scene.
    outcomes: HashMap<String, Result<(), String>>,
}

// SAFETY: a `Slag` context and its values are single-threaded, and every method
// below runs on Godot's main thread. gdext requires `Send + Sync` of every
// class; this asserts the invariant the engine itself cannot express. The
// context must not be moved to, or touched from, another thread.
unsafe impl Send for ModHost {}
unsafe impl Sync for ModHost {}

#[godot_api]
impl INode for ModHost {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            lines: LineQueue::default(),
            world_time: Rc::new(RefCell::new(0.0)),
            module: None,
            outcomes: HashMap::new(),
        }
    }
}

#[godot_api]
impl ModHost {
    /// Evaluate a string of JavaScript in the mod realm, after the facade is in
    /// place. Returns `ok` or the engine's error.
    ///
    /// A mod's `entry` is loaded this way. Anything the string defines is
    /// visible to later evaluations but does **not** by itself register with the
    /// host -- a mod registers by calling `goats.command` / `goats.on`, exactly
    /// as `APIv1.md` section 4 describes.
    #[func]
    fn eval_js(&mut self, source: GString) -> GString {
        match self.run(source.to_string()) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Read a file and evaluate it as a mod entry, reporting what was loaded.
    ///
    /// Reading is the host's job, never a mod's (`APIv1.md` section 0: no
    /// filesystem). This is the raw path -- no manifest, no `goats.begin` scope
    /// -- and `load_mod` is the one a real mod comes through.
    #[func]
    fn load_mod_path(&mut self, path: GString) -> GString {
        let path = path.to_string();
        let source = match std::fs::read_to_string(&path) {
            Ok(source) => source,
            Err(error) => return gstring(format!("read {path}: {error}")),
        };
        match self.run(source) {
            Ok(_) => gstring(format!(
                "ok {} bytes",
                std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0)
            )),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Discover the mods in a directory without running any of them.
    ///
    /// This is `crates/mods` doing the work -- every manifest validated, ids
    /// ordered by `loadAfter`, archives unwrapped -- and nothing executed.
    /// Nothing is evaluated until [`ModHost::load_mod`] or
    /// [`ModHost::load_all`].
    #[func]
    fn load_mods(&mut self, dir: GString) -> GString {
        if let Err(error) = self.ensure_booted() {
            return gstring(format!("error: {error}"));
        }
        let dir = dir.to_string();
        let loader = mods::Loader::discover(Path::new(&dir));

        let mut report = format!("{} mod(s) in {dir}", loader.mods().len());
        for error in loader.errors() {
            report.push_str(&format!(
                "\n  ! {}: {}",
                error.path.display(),
                error.message
            ));
        }

        let module = self.module.as_mut().expect("booted above");
        module.loader = Some(loader);
        // A fresh discovery invalidates every previous outcome: the ids may be
        // different mods at different versions, and a stale `failed` is worse than
        // none.
        self.outcomes.clear();
        gstring(report)
    }

    /// The metadata table the core would hand the scene: id, name, version,
    /// side, digest, asset slots and tuning, in load order. This is
    /// `crates/mods`' own `table_json`, verbatim -- no paths, ever -- with one
    /// thing added: a mod whose entry *threw* carries `failed: true` and the
    /// error, which is what `mods.js`'s `sceneModResult` tells the scene so the
    /// Mods screen can name it instead of drawing a healthy row.
    #[func]
    fn mods_json(&mut self) -> GString {
        let Some(loader) = self
            .module
            .as_ref()
            .and_then(|module| module.loader.as_ref())
        else {
            return GString::from("[]");
        };
        let mut table: serde_json::Value =
            serde_json::from_str(&loader.table_json()).unwrap_or_else(|_| serde_json::json!([]));
        if let Some(rows) = table.as_array_mut() {
            for row in rows.iter_mut() {
                let id = row.get("id").and_then(|id| id.as_str()).unwrap_or_default();
                if let Some(Err(error)) = self.outcomes.get(id) {
                    row["failed"] = serde_json::json!(true);
                    row["error"] = serde_json::json!(error);
                }
            }
        }
        gstring(table.to_string())
    }

    /// The opaque names of every asset the loaded mods declared, sorted. These
    /// are what a mod addresses an asset with; the bytes are kept for the
    /// engine shim (`rl.loadSound` and friends) and are not reachable from JS
    /// by path.
    #[func]
    fn asset_names(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        let Some(module) = self.module.as_ref() else {
            return out;
        };
        let mut names: Vec<&String> = module.assets.keys().collect();
        names.sort();
        for name in names {
            out.push(&gstring(name));
        }
        out
    }

    /// Run one mod's entry by id, in its own `goats.begin(id)` scope.
    #[func]
    fn load_mod(&mut self, id: GString) -> GString {
        let id = id.to_string();
        let outcome = self.load_one(&id);
        self.record(&id, &outcome);
        match outcome {
            Ok(report) => gstring(report),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Run every discovered mod's entry, in load order. A mod that throws is
    /// reported and the rest still load -- the isolation `APIv1.md` section 7
    /// promises.
    #[func]
    fn load_all(&mut self) -> GString {
        if let Err(error) = self.ensure_booted() {
            return gstring(format!("error: {error}"));
        }
        let ids = match self
            .module
            .as_ref()
            .and_then(|module| module.loader.as_ref())
        {
            Some(loader) => loader.ids(),
            None => return GString::from("no mods discovered; call load_mods first"),
        };

        let mut report = String::new();
        for id in ids {
            let outcome = self.load_one(&id);
            self.record(&id, &outcome);
            match outcome {
                Ok(line) => report.push_str(&line),
                Err(error) => report.push_str(&format!("{id}: {error}")),
            }
            report.push('\n');
        }
        gstring(report.trim_end())
    }

    /// Invoke a registered command, console-style. Returns the mod's reply, or
    /// an empty string when no such command is registered.
    #[func]
    fn run_command(&mut self, name: GString, line: GString) -> GString {
        let args = [
            JsValue::string(name.to_string()),
            JsValue::string(line.to_string()),
        ];
        match self.call_goats("__invoke", &args) {
            Ok(value) if value.is_null() => GString::new(),
            Ok(value) => gstring(value.as_string().unwrap_or_default()),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Fire the `"hud"` hooks for one frame with the screen size. A mod draws
    /// through `rl`, so the output arrives via [`ModHost::poll_lines`].
    #[func]
    fn emit_hud(&mut self, width: f64, height: f64) -> GString {
        let args = [JsValue::number(width), JsValue::number(height)];
        match self.call_goats("__fireHud", &args) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// The core pushes the in-game clock here each frame; a mod reads it through
    /// `goats.world.time()`. This is the "push the readable values" half of
    /// `godot/PORT.md` section 6, decision 3.
    #[func]
    fn set_world_time(&mut self, hours: f64) {
        *self.world_time.borrow_mut() = hours;
    }

    /// Drain the queued lines: a mod's `console.log`, and its draw calls (which
    /// the Godot side will draw once the shim is more than two members).
    #[func]
    fn poll_lines(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for line in self.lines.borrow_mut().drain(..) {
            out.push(&gstring(line));
        }
        out
    }
}

impl ModHost {
    /// Record what happened to one mod's entry, for [`ModHost::mods_json`] to
    /// read back. A `Result<String, String>` is `load_one`'s answer -- the line to
    /// report, or the error -- and only which half it is survives here.
    fn record(&mut self, id: &str, outcome: &Result<String, String>) {
        let outcome = outcome.as_ref().map(|_| ()).map_err(|error| error.clone());
        self.outcomes.insert(id.to_string(), outcome);
    }

    /// Build the engine and the facade if they are not up yet.
    fn ensure_booted(&mut self) -> Result<(), String> {
        if self.module.is_none() {
            let module = self.build()?;
            self.module = Some(module);
        }
        Ok(())
    }

    /// Create the context, register the native capabilities, evaluate the
    /// facade, and keep the `goats` object.
    fn build(&self) -> Result<Mod, String> {
        let mut context = Context::new().map_err(|e| e.to_string())?;

        // A mod's `console.log` reaches the host, not the terminal.
        let lines = self.lines.clone();
        context.set_host_callbacks(HostCallbacks {
            console_log: Some(Box::new(move |text: &str| {
                lines.borrow_mut().push(format!("log {text}"));
            })),
            ..HostCallbacks::default()
        });

        // `goats.world.time()`: return the value the core last pushed.
        let clock = self.world_time.clone();
        context
            .register_fn(
                "__goatsWorldTime",
                0,
                Box::new(move |_call| Ok(JsValue::number(*clock.borrow()))),
            )
            .map_err(|e| e.to_string())?;

        // `rl.drawText(...)`: queue the draw for Godot. This is the first member
        // of the Godot-backed drawing shim.
        let draws = self.lines.clone();
        context
            .register_fn(
                "__rlDrawText",
                8,
                Box::new(move |call| {
                    let text = call
                        .arg(0)
                        .and_then(|v| call.to_string(&v).ok())
                        .unwrap_or_default();
                    let number = |index: usize| -> f64 {
                        call.arg(index).and_then(|v| v.as_number()).unwrap_or(0.0)
                    };
                    draws.borrow_mut().push(format!(
                        "drawText \"{text}\" at ({:.0}, {:.0}) size {:.0} rgba({:.0}, {:.0}, {:.0}, {:.0})",
                        number(1),
                        number(2),
                        number(3),
                        number(4),
                        number(5),
                        number(6),
                        number(7),
                    ));
                    Ok(JsValue::undefined())
                }),
            )
            .map_err(|e| e.to_string())?;

        // The facade, once, before any mod entry runs.
        context.eval(PRELUDE).map_err(|e| e.to_string())?;
        let goats = context
            .eval("goats")
            .map_err(|e| e.to_string())?
            .as_object()
            .ok_or_else(|| "the prelude did not define `goats`".to_string())?;

        Ok(Mod {
            context,
            goats,
            loader: None,
            assets: HashMap::new(),
        })
    }

    /// Evaluate `source` against a booted engine.
    fn run(&mut self, source: String) -> Result<(), String> {
        self.ensure_booted()?;
        let module = self.module.as_mut().expect("booted above");
        module
            .context
            .eval(&source)
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    /// Call a `goats` member by name, with the facade as `this`.
    fn call_goats(&mut self, member: &str, args: &[JsValue]) -> Result<JsValue, String> {
        self.ensure_booted()?;
        let module = self.module.as_mut().expect("booted above");
        let function = module.goats.get(member).map_err(|e| e.to_string())?;
        let this = module.goats.as_value();
        module
            .context
            .call(&function, &this, args)
            .map_err(|e| e.to_string())
    }

    /// Take one mod's assets and run its entry, both by id.
    ///
    /// The two halves are the loader's: `take_assets` is what makes the bytes
    /// the host's to register, and `entry_js` is what wraps the source in its
    /// own `goats.begin(id)` scope so a reload cannot leak a binding.
    fn load_one(&mut self, id: &str) -> Result<String, String> {
        self.ensure_booted()?;
        let module = self.module.as_mut().expect("booted above");
        let loader = module
            .loader
            .as_mut()
            .ok_or("no mods discovered; call load_mods first")?;

        let assets = loader
            .mods_mut()
            .iter_mut()
            .find(|manifest| manifest.id == id)
            .ok_or_else(|| format!("unknown mod '{id}'"))?
            .take_assets();
        let asset_count = assets.len();
        for asset in assets {
            module.assets.insert(asset.name.clone(), asset.bytes);
        }

        match loader.get(id).and_then(|manifest| manifest.entry_js()) {
            Some(js) => {
                module.context.eval(&js).map_err(|e| e.to_string())?;
                Ok(format!("loaded {id} ({asset_count} asset(s))"))
            }
            // A compiled mod has no entry to run; its module is a separate path.
            None => Ok(format!("{id}: no entry (a compiled mod?)")),
        }
    }
}

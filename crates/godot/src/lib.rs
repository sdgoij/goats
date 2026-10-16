//! The GDExtension Godot loads.
//!
//! This crate is the seam between the Godot project in `godot/` and the rest of
//! the repository's Rust. It registers the library with Godot and exposes two
//! nodes:
//!
//! * [`net::NetBridge`] — the networking bridge over `session` and `proto` (see
//!   `godot/PORT.md` section 7).
//! * [`ModHost`] — the mod runtime: Slag, plus the `goats` facade a mod sees,
//!   including the API's own drawing surface (`godot/PORT.md` section 6).
//!
//! Why these are Rust and not GDScript: iroh, the packed `proto` wire, the mod
//! loader and the JavaScript engine are all Rust, and the port's claim to
//! compatibility is that it links *these* rather than reimplementing them.
//!
//! The scene is GDScript (`godot/PORT.md` section 4): Godot owns the loop and
//! the renderer, and JavaScript is kept for mods only.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::Path;
use std::rc::Rc;

use godot::prelude::*;
use plugin::{PluginSet, Side as PluginSide};
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

/**
 * Lines the extension has produced for the Godot side to drain: log output and
 * queued draw calls.
 *
 * They are queued rather than signalled, because a mod's JavaScript runs inside
 * a `Context` this node owns, and emitting a Godot signal from there would
 * re-enter the node while it is borrowed. Queuing and draining is the same
 * shape the raylib client already uses for the network bridge
 * (`sceneNetEvent` / `sceneNetDrain`).
 */
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
    /// (`APIv1.md` section 0: no paths reach a mod). The engine shim reads these,
    /// and `goats.gfx.model` resolves through them. Shared with the host, because
    /// the capability is registered before the engine boots and a later `load_mod`
    /// is what fills it.
    assets: Rc<RefCell<HashMap<String, Vec<u8>>>>,
}

/// The mod runtime: an embedded Slag context, the `goats`/`rl` facade, and the
/// values the core pushes in each frame.
#[derive(GodotClass)]
#[class(base=Node)]
struct ModHost {
    base: Base<Node>,
    /// Log lines, drained by [`ModHost::poll_lines`].
    lines: LineQueue,
    /// Draw records a mod's `goats.draw` calls produced since the last
    /// [`ModHost::poll_draws`]: one JSON object per call, in the order they were
    /// made, so the scene's `ModHud` paints them in that order.
    draws: LineQueue,
    /// ...and the **world-space** ones, from `goats.gfx.draw`, which go on a seam of
    /// their own because they are painted by a different thing: `ModWorld` places a
    /// node per call where `ModHud` draws a primitive.
    world_draws: LineQueue,
    /// The assets every loaded mod declared, by opaque name. Shared with the engine's
    /// `__goatsHasAsset` capability, which is registered before anything is loaded.
    assets: Rc<RefCell<HashMap<String, Vec<u8>>>>,
    /// The **meshes** a mod built in JavaScript (`goats.gfx.mesh`, `APIv1.md` section 4.19),
    /// by the opaque handle the facade minted. This crate does not build one -- Godot's
    /// `ArrayMesh` is the scene's job (`mod_world.gd`) -- it only holds the arrays until the
    /// scene asks, which is the same division of labour `assets` has for declared bytes.
    meshes: Rc<RefCell<HashMap<String, String>>>,
    /// ...and the **textures** (`goats.gfx.texture`), the same way: the pixels a mod generated,
    /// kept as the hex the facade wrote until the scene makes an `Image` of them.
    textures: Rc<RefCell<HashMap<String, String>>>,
    /// Which texture a mesh draws with (`goats.gfx.bind`): mesh handle -> texture handle. A
    /// binding rather than a field of the mesh's own JSON, because `bind` can be called after
    /// `mesh` and both are looked up by handle.
    bindings: Rc<RefCell<HashMap<String, String>>>,
    /// The metadata table, as the scene builds it for the Mods screen -- with each mod's outcome
    /// merged in. Kept in a cell as well as returned, because `goats.mods()` and `goats.mod`
    /// (`APIv1.md` section 4.1) are capabilities, and a capability cannot borrow the host.
    table: Rc<RefCell<String>>,
    /// The surface the last [`ModHost::emit_hud`] named, which `goats.draw.screen()`
    /// reads back. The *scene* owns the viewport, so this is only the value it
    /// handed in -- the same push-the-readable-values design `PORT.md` section 6
    /// records for the clock.
    screen: Rc<Cell<(f64, f64)>>,
    /// The clock the core pushes; a mod reads it through `goats.world.time()`.
    world_time: Rc<RefCell<f64>>,
    /// The world snapshot the core pushes each frame, as JSON. This is what
    /// `goats.player`, `goats.camera`, `goats.world`, `goats.bots`, `goats.settings`,
    /// `goats.tuning` and `goats.net` read: the general form of the push half of
    /// `godot/PORT.md` section 6, decision 3, where `world_time` above is its first
    /// instance. One object for every group, so a group can grow a member without a
    /// signature here.
    snapshot: Rc<RefCell<String>>,
    /// How many times the snapshot has been replaced. The facade caches the *parsed*
    /// snapshot and re-parses it only when this moves, so a frame's reads share one
    /// parse between them rather than each paying for one.
    pushes: Rc<Cell<u64>>,
    /// The scene's entry point for the API's *functional* members -- `terrainHeight`
    /// today, the writes when they land. They cannot be pushed values, because they are
    /// a question asked of the world rather than an answer told to it. This is the
    /// "callbacks for the rest" half of the same decision.
    scene_call: Rc<RefCell<Option<Callable>>>,
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
    /// The **compiled** mods: a mod that ships a `.wasm` module instead of (or beside) an
    /// entry, decoded, instantiated and driven from Rust by `crates/plugin`. This is the same
    /// `PluginSet` the raylib client and `goatsd` drive, and the same split the rest of this
    /// file makes -- the host owns the store and the module's memory, so a `.wasm` file is
    /// never a path or an `ArrayBuffer` that anybody else holds (`ABIv1.md` section 3.2). It
    /// is a plain field rather than an `Rc`-shared cell because nothing in the JavaScript
    /// facade reaches it: a plugin's imports are served inside `crates/plugin`, not through
    /// Slag.
    plugins: PluginSet,
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
            draws: LineQueue::default(),
            world_draws: LineQueue::default(),
            assets: Rc::new(RefCell::new(HashMap::new())),
            meshes: Rc::new(RefCell::new(HashMap::new())),
            textures: Rc::new(RefCell::new(HashMap::new())),
            bindings: Rc::new(RefCell::new(HashMap::new())),
            table: Rc::new(RefCell::new(String::from("[]"))),
            screen: Rc::new(Cell::new((0.0, 0.0))),
            world_time: Rc::new(RefCell::new(0.0)),
            snapshot: Rc::new(RefCell::new(String::new())),
            pushes: Rc::new(Cell::new(0)),
            scene_call: Rc::new(RefCell::new(None)),
            module: None,
            outcomes: HashMap::new(),
            plugins: PluginSet::new(),
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
        // ...and the identity a mod reads (`goats.mods()`, `goats.mod`) is the table, so it is
        // put in the cell as soon as discovery has run rather than waiting for the scene to ask.
        self.refresh_table();
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
        self.refresh_table();
        let table = self.table.borrow().clone();
        gstring(table)
    }

    /// The opaque names of every asset the loaded mods declared, sorted. These
    /// are what a mod addresses an asset with; the bytes are kept for the
    /// engine shim (`rl.loadSound` and friends) and are not reachable from JS
    /// by path.
    /// The opaque names of every asset the loaded mods declared, sorted. These
    /// are what a mod addresses an asset with, and what `goats.gfx.model` resolves
    /// against; the bytes are handed to the scene by [`ModHost::asset_bytes`].
    #[func]
    fn asset_names(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        let Some(module) = self.module.as_ref() else {
            return out;
        };
        let mut names: Vec<String> = module.assets.borrow().keys().cloned().collect();
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
        self.refresh_table();
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
        // The table before any entry runs, so a mod that asks `goats.mods()` in its own `load`
        // sees the set it is in -- and again at the end, with the outcomes folded in.
        self.refresh_table();
        for id in ids {
            let outcome = self.load_one(&id);
            self.record(&id, &outcome);
            match outcome {
                Ok(line) => report.push_str(&line),
                Err(error) => report.push_str(&format!("{id}: {error}")),
            }
            report.push('\n');
        }
        self.refresh_table();
        gstring(report.trim_end())
    }

    /// Turn one mod on or off for this session -- `APIv1.md` section 4.1's `modSetEnabled`,
    /// between `mods.js`'s toggle and the host's `handle_mod_intent`.
    ///
    /// Off tears the instance down: the facade's `__end` fires the mod's own `shutdown` hook and
    /// drops everything it registered (its hooks, its commands, its streams, its world extensions
    /// and its offered entities -- `mods.js`'s `goatsEnd`), and a compiled module's instance goes
    /// with it. On re-reads the mod from its source and evaluates it fresh, which is what the
    /// reference's `reload_and_eval` does for an enable *and* a reload: an edit on disk takes
    /// effect on the toggle, and a mod that failed its first run gets a clean second chance.
    ///
    /// The session guard is *not* here. A world mod's side is fixed when a host accepts a join, so
    /// changing one mid-session would desync a joiner -- and only the scene knows whether there is
    /// a session, so `Mods::set_enabled` refuses before this is reached ([`ModHost`] has no net).
    #[func]
    fn set_enabled(&mut self, id: GString, enabled: bool) -> GString {
        if let Err(error) = self.ensure_booted() {
            return gstring(format!("error: {error}"));
        }
        let id = id.to_string();
        let known = self
            .module
            .as_ref()
            .and_then(|module| module.loader.as_ref())
            .is_some_and(|loader| loader.get(&id).is_some());
        if !known {
            return gstring(format!("error unknown mod: {id}"));
        }
        if enabled {
            // The reference clears a mod's failure before it re-runs, so a fixed mod reads clean
            // until it throws again -- and the fresh outcome is what `mods_json` will carry.
            self.outcomes.remove(&id);
            if let Some(module) = self.module.as_mut()
                && let Some(loader) = module.loader.as_mut()
            {
                // A read failure falls back to the cached manifest, which is `reload`'s own rule;
                // the flag is set on whichever manifest survived, so the toggle still takes.
                if let Err(error) = loader.reload(&id, mods::AssetMode::Keep) {
                    eprintln!("[mods] {error}");
                }
                loader.set_enabled(&id, true);
            }
            // The table before the entry runs, so `goats.mod` inside it already reads the new flag
            // and a freshly re-enabled mod does not appear loaded until it has run.
            self.refresh_table();
            let outcome = self.load_one(&id);
            self.record(&id, &outcome);
            self.refresh_table();
            match outcome {
                Ok(_) => gstring(format!("ok mod enable {id}")),
                Err(error) => gstring(format!("error {id}: {error}")),
            }
        } else {
            // An id the facade never began answers `error mod not loaded`, which is not a failure
            // worth a line: a disable that has nothing to tear down has still done its job.
            let _ = self.call_goats("__end", &[JsValue::string(id.clone())]);
            self.plugins.remove(&id);
            if let Some(module) = self.module.as_mut()
                && let Some(loader) = module.loader.as_mut()
            {
                loader.set_enabled(&id, false);
            }
            self.refresh_table();
            gstring(format!("ok mod disable {id}"))
        }
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
    /// through `goats.draw`, so the output arrives via [`ModHost::poll_draws`].
    #[func]
    fn emit_hud(&mut self, width: f64, height: f64) -> GString {
        // The surface `goats.draw.screen()` reports, set before the hooks run, so a
        // hook that asks for it gets the frame it is drawing into.
        self.screen.set((width, height));
        let args = [JsValue::number(width), JsValue::number(height)];
        match self.call_goats("__fireHud", &args) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Re-derive the world mods' streams from the session seed (`APIv1.md` section 4.13), which
    /// the scene calls on the `session` event. The scene derives its own four streams from the
    /// same seed at the same moment (`sceneUseSeed`), and a world mod's draws have to come from
    /// the same place or a flock the host simulates is not the flock a joiner computes -- so this
    /// is an *event* and not a snapshot field: the derivation advances per call, and a field
    /// could not tell a repeated seed from the next frame.
    #[func]
    fn use_seed(&mut self, seed: i64) -> GString {
        let args = [JsValue::number(seed as f64)];
        let answer = match self.call_goats("__useSeed", &args) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        };
        // A compiled world mod's streams live *inside* its module rather than in the facade's
        // `modStreams`, so the same seed has to reach them too -- one draw per stream, *after* the
        // scene's own derivation, which is `goatsd`'s own order (`crates/server/src/headless.rs`).
        // A client mod's streams do not re-derive at all (`ABIv1.md` section 3.5), so this is
        // inert for the fixture that ships today.
        self.plugins.seed_all(seed as i32);
        answer
    }

    /// Drive every compiled mod one frame (`ABIv1.md`), and hand back what they produced.
    ///
    /// The reference client's own loop does exactly this once the scene has moved: it pushes the
    /// player's belly in, ticks the modules that are this peer's to tick, and reads two things out
    /// -- the HUD bar a `side: "client"` module reports, and the opaque bytes a `side: "world"` one
    /// published. It is one call rather than three because `ABIv1.md` section 2 is "one crossing per
    /// frame", and because the two documents travel together: a frame either happened or it did not.
    ///
    /// `tick_world` is the mirroring rule. A client that joined a host does not simulate the world
    /// at all, so it must not simulate the world's compiled mods either: its modules are
    /// instantiated and applied to, never stepped. The reference asks its own `netWorldLocal()` for
    /// the same bit. `belly` is the player's fullness (0..1), which only a client module can import
    /// -- a world module that asks for it fails to link (`ABIv1.md` section 3.3).
    ///
    /// The answer is the HUD map a client module reports -- `{id: fill}` -- and it is the empty
    /// string when no compiled mod is loaded: the common case, and the reason a frame with none
    /// costs nothing rather than a JSON round trip. A world module's *published* bytes are not here
    /// and must not be: they are read when the datagram is built ([`ModHost::world_mods_json`]),
    /// which is ten times a second rather than sixty.
    #[func]
    fn drive_wasm(&mut self, dt: f64, tick_world: bool, belly: f64) -> GString {
        if self.plugins.is_empty() {
            return GString::new();
        }
        self.plugins.set_belly(belly as f32);
        self.plugins.tick_all(dt as f32, tick_world);
        // `crates/plugin` builds the bridge as JSON already -- `{id: fill}`, the shape the HUD
        // reads -- so it is parsed back only to be a value the scene can take apart.
        let hud: serde_json::Value = serde_json::from_str(&self.plugins.hud_json())
            .unwrap_or_else(|_| serde_json::json!({}));
        gstring(serde_json::json!({ "hud": hud }).to_string())
    }

    /// What one compiled mod's module reports about itself: the ABI it negotiated, the
    /// capabilities it imports, how many frames it has run, whether it has trapped and its last
    /// `goats.log` line. `null` for a mod that ships no module, which is what `mod info` reads --
    /// the same JSON the raylib client shows through `modWasmInfo`.
    #[func]
    fn wasm_describe(&mut self, id: GString) -> GString {
        match self.plugins.describe_json(id.to_string().as_str()) {
            Some(json) => gstring(json),
            None => GString::from("null"),
        }
    }

    /// The world mods' state as one JSON object -- `{streams, data}` -- or the **empty string** when
    /// there is nothing to send. This is `sceneWorldMods()` and `modWorldActive()` in one call, and
    /// it is a *host's* member: a client mirrors a host's world-mod state and never builds one
    /// (`APIv1.md` section 4.13).
    ///
    /// It is also the one place the two halves of a world mod meet. A JavaScript world mod's state
    /// is the facade's (`__worldModsJson`: each registered stream's state and whatever each
    /// extension's `publish` returned), and a **compiled** one's is this crate's (`crates/plugin`'s
    /// `published_json`: each world module's opaque bytes, base64). The reference merges the same two
    /// at the scene boundary -- `mods.js`'s `sceneWorldMods` folds `rustModPublished` in -- because
    /// there its compiled mods are the JS driver's; here they are Rust's, so the merge is here.
    ///
    /// `""` rather than an empty object is `sceneModsJson`'s own contract (`goatsd`'s headless
    /// host), and it is the useful one: a host publishing ten times a second asks one question -- is
    /// there anything to say -- and a false answer costs no datagram at all.
    #[func]
    fn world_mods_json(&mut self) -> GString {
        if let Err(error) = self.ensure_booted() {
            eprintln!("[mods] world_mods_json: {error}");
            return GString::new();
        }
        let facade = match self.call_goats("__worldModsJson", &[]) {
            Ok(value) => value.as_string().unwrap_or_default().to_string(),
            Err(error) => {
                eprintln!("[mods] __worldModsJson: {error}");
                String::new()
            }
        };
        let compiled: serde_json::Value = serde_json::from_str(&self.plugins.published_json())
            .unwrap_or_else(|_| serde_json::json!({}));
        let nothing_compiled = compiled
            .as_object()
            .map(|map| map.is_empty())
            .unwrap_or(true);
        if facade.is_empty() && nothing_compiled {
            return GString::new();
        }
        let mut state: serde_json::Value = if facade.is_empty() {
            serde_json::json!({ "streams": {}, "data": {} })
        } else {
            serde_json::from_str(&facade)
                .unwrap_or_else(|_| serde_json::json!({ "streams": {}, "data": {} }))
        };
        if let (Some(data), Some(compiled)) = (state.get_mut("data"), compiled.as_object()) {
            for (id, value) in compiled {
                data[id] = value.clone();
            }
        }
        gstring(state.to_string())
    }

    /// Apply a host's world-mod state -- what the `mods` event carried. The facade adopts the
    /// streams and hands each JavaScript extension its own published value, and every compiled world
    /// mod's bytes go into its module through `goats_apply`.
    ///
    /// The same seam [`ModHost::world_mods_json`] reads, in the other direction, and the reason a
    /// joiner does not have to *simulate* a world mod to agree with the host about it: a module that
    /// never runs `goats_update` still moves, through `goats_apply` (`ABIv1.md` section 3.4) -- which
    /// is why a compiled world mod is instantiated on a mirroring client at all.
    #[func]
    fn apply_world_mods(&mut self, json: GString) -> GString {
        let text = json.to_string();
        // The facade first: a JavaScript extension's `apply` is its own, and `crates/plugin` cannot
        // reach it. A throw is the facade's to report (`applyWorldMods` names the mod).
        let _ = self.call_goats("__applyWorldMods", &[JsValue::string(text.clone())]);
        let state: serde_json::Value = match serde_json::from_str(&text) {
            Ok(state) => state,
            Err(error) => return gstring(format!("error: {error}")),
        };
        let Some(data) = state.get("data").and_then(|data| data.as_object()) else {
            return GString::from("ok");
        };
        for (id, value) in data {
            let Some(encoded) = value.as_str() else {
                continue;
            };
            let Some(bytes) = plugin::base64_decode(encoded) else {
                eprintln!("[mods] {id}: the published state is not base64");
                continue;
            };
            if let Err(error) = self.plugins.apply(id, &bytes) {
                // An id no compiled mod owns is a JavaScript extension's, and the facade already had
                // it -- so "unknown plugin" is not a failure worth a line, while a module that
                // trapped adopting the state is.
                if !error.starts_with("unknown plugin") {
                    eprintln!("[mods] {id} apply failed: {error}");
                }
            }
        }
        GString::from("ok")
    }

    /// Fire the `"update"` hooks for one frame, with the step. It is the event both checked-in
    /// examples do their work in, and `dt` is **0 while the world is frozen** -- the menu is open,
    /// the console is up, `P` was pressed -- which is the scene's own `ctlStep` rule and the reason
    /// a mod freezes with the world rather than running on behind it.
    #[func]
    fn emit_update(&mut self, dt: f64) -> GString {
        let args = [JsValue::number(dt)];
        match self.call_goats("__fireUpdate", &args) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Fire the `"shutdown"` hooks, once, as the scene goes down -- `sceneShutdown`'s own event.
    /// It is where a mod frees what it built, which is the one thing a reload cannot do for it.
    #[func]
    fn emit_shutdown(&mut self) -> GString {
        // A compiled mod's instance goes with its mod, and the scene is going down: the module's
        // store is dropped here rather than left to the process, so nothing a plugin owns outlives
        // the frame it was driven in.
        self.plugins = PluginSet::new();
        match self.call_goats("__fireShutdown", &[]) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Fire the `"blast"` hooks, after a bang. The argument is the same JSON object the scene's
    /// own `modEmit("blast", {...})` sends, for `push_world`'s reason: a shape rather than a
    /// signature, so the event can grow a field without a method changing here.
    #[func]
    fn emit_blast(&mut self, json: GString) -> GString {
        let args = [JsValue::string(json.to_string())];
        match self.call_goats("__fireBlast", &args) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        }
    }

    /// Fire the `"tuning"` hooks, after a leaf changed (`APIv1.md` section 4.2). Two arguments
    /// rather than one object, because the event's own signature is `(path, value)`: the path is
    /// a dotted string and the value the coerced leaf, JSON-encoded for `push_world`'s reason --
    /// a shape rather than a signature, so the value can grow without a method changing here.
    #[func]
    fn emit_tuning(&mut self, path: GString, json: GString) -> GString {
        let args = [
            JsValue::string(path.to_string()),
            JsValue::string(json.to_string()),
        ];
        match self.call_goats("__fireTuning", &args) {
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

    /// Replace the world snapshot a mod reads the live world out of: `goats.player`,
    /// `goats.camera`, `goats.world`, `goats.bots`, `goats.settings`, `goats.tuning` and
    /// `goats.net`. One JSON object per frame, built by the scene (`main.gd`'s
    /// `_mod_snapshot`), for the reason `PROTO`'s world is one object: the two ends agree
    /// on a *shape* rather than on an argument list, so a group can grow a member without
    /// a signature here -- the same choice `__goatsDraw`'s records make.
    ///
    /// Pushing a whole snapshot rather than crossing per read is the design
    /// `godot/PORT.md` section 6 records: the hot reads never touch the boundary, and the
    /// extension keeps no second copy of the world to drift from the scene's own.
    #[func]
    fn push_world(&mut self, json: GString) {
        *self.snapshot.borrow_mut() = json.to_string();
        self.pushes.set(self.pushes.get() + 1);
    }

    /// Hand the extension the scene's entry point for the API's functional members. The
    /// scene passes a `Callable` that takes `(name, args_json)` and answers a JSON
    /// object: `{"ok": <value>}` for an answer or `{"err": "<message>"}` for a refusal,
    /// which the facade turns into a returned value or a thrown error.
    ///
    /// A shape rather than a typed method per member, for `push_world`'s reason: the
    /// surface grows on the scene's side without a signature changing here.
    #[func]
    fn set_scene_call(&mut self, callable: Callable) {
        *self.scene_call.borrow_mut() = Some(callable);
    }

    /// The arrays behind a mesh a mod built (`goats.gfx.mesh`), as the JSON the facade
    /// stored -- `{"v": [...], "i": [...], ...}`. Empty for a handle nothing minted, which
    /// is what makes the scene's "no such mesh" case a null it can fall back from.
    #[func]
    fn mesh_data(&mut self, handle: GString) -> GString {
        let data = self.meshes.borrow();
        match data.get(handle.to_string().as_str()) {
            Some(json) => gstring(json),
            None => GString::new(),
        }
    }

    /// The texels behind a texture handle (`goats.gfx.texture`), as the `{size, pixels}` JSON
    /// the facade stored. Empty for a handle nothing minted.
    #[func]
    fn texture_data(&mut self, handle: GString) -> GString {
        let data = self.textures.borrow();
        match data.get(handle.to_string().as_str()) {
            Some(json) => gstring(json),
            None => GString::new(),
        }
    }

    /// The texture handle a mesh was bound to (`goats.gfx.bind`), or empty for one that was
    /// not -- a mesh drawn in its own vertex colours, which is what both mods' bodies are.
    #[func]
    fn mesh_binding(&mut self, handle: GString) -> GString {
        let bindings = self.bindings.borrow();
        match bindings.get(handle.to_string().as_str()) {
            Some(name) => gstring(name),
            None => GString::new(),
        }
    }

    /// Forget a handle a mod freed (`goats.gfx.unload`): its arrays, its pixels and any binding.
    ///
    /// The scene calls this from its own frame rather than the facade calling it directly, and
    /// that is the whole design: a member reached from inside a mod's JavaScript runs while the
    /// host is borrowed, so it could not ask for this (`PORT.md` section 9). A record queued for
    /// the frame's drain can.
    #[func]
    fn forget(&mut self, handle: GString) {
        let handle = handle.to_string();
        self.meshes.borrow_mut().remove(handle.as_str());
        self.textures.borrow_mut().remove(handle.as_str());
        self.bindings.borrow_mut().remove(handle.as_str());
    }

    /// Drain the lines the mods logged since the last call: a mod's
    /// `console.log`, which is what `goats.log` and a bare `console.log` both
    /// reach. A mod's *drawing* is [`ModHost::poll_draws`] instead.
    #[func]
    fn poll_lines(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for line in self.lines.borrow_mut().drain(..) {
            out.push(&gstring(line));
        }
        out
    }

    /// Drain the draw calls the mods made since the last call, as JSON records in
    /// the order they were made. The scene's `ModHud` control parses and paints
    /// them, which is what makes `goats.draw` visible rather than merely counted.
    #[func]
    fn poll_draws(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for line in self.draws.borrow_mut().drain(..) {
            out.push(&gstring(line));
        }
        out
    }

    /// Drain the **world-space** draws (`goats.gfx.draw`) the mods made since the last
    /// call, as JSON records in the order they were made. The scene's `ModWorld` node
    /// places one child per record, which is the 3D half of what [`ModHost::poll_draws`]
    /// does for the 2D one.
    #[func]
    fn poll_draw3d(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for line in self.world_draws.borrow_mut().drain(..) {
            out.push(&gstring(line));
        }
        out
    }

    /// The bytes behind an asset's opaque name, for the scene to make something of:
    /// `goats.gfx.model` hands the name over here, and `mod_world.gd` imports the model
    /// with Godot's own glTF loader. Empty for a name nothing declared.
    #[func]
    fn asset_bytes(&mut self, name: GString) -> PackedByteArray {
        let assets = self.assets.borrow();
        match assets.get(name.to_string().as_str()) {
            Some(bytes) => PackedByteArray::from(bytes.as_slice()),
            None => PackedByteArray::new(),
        }
    }

    /// Fire the `"draw3d"` hooks for one frame, with the camera. This is the pass a
    /// world-space `goats.gfx.draw` is made inside, and the camera is the same seven
    /// numbers the scene's own `modEmit("draw3d", ...)` sends.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn emit_draw3d(
        &mut self,
        x: f64,
        y: f64,
        z: f64,
        target_x: f64,
        target_y: f64,
        target_z: f64,
        fov: f64,
    ) -> GString {
        let args = [
            JsValue::number(x),
            JsValue::number(y),
            JsValue::number(z),
            JsValue::number(target_x),
            JsValue::number(target_y),
            JsValue::number(target_z),
            JsValue::number(fov),
        ];
        match self.call_goats("__fireDraw3d", &args) {
            Ok(_) => GString::from("ok"),
            Err(error) => gstring(format!("error: {error}")),
        }
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

    /// The metadata table with every entry's outcome merged in: `crates/mods`' own
    /// `table_json` (no paths, ever) plus `failed`/`error` on a mod whose entry threw and
    /// `loaded`, which only the host that ran an entry can answer. This is `mods.js`'s
    /// `sceneModResult` folded into `sceneMods`, and it is what [`ModHost::refresh_table`] puts in
    /// the cell. `enabled` is the loader's own flag, from the manifest the toggle moves.
    fn merged_table(&self) -> serde_json::Value {
        let Some(loader) = self
            .module
            .as_ref()
            .and_then(|module| module.loader.as_ref())
        else {
            return serde_json::json!([]);
        };
        let mut table: serde_json::Value =
            serde_json::from_str(&loader.table_json()).unwrap_or_else(|_| serde_json::json!([]));
        if let Some(rows) = table.as_array_mut() {
            for row in rows.iter_mut() {
                let id = row
                    .get("id")
                    .and_then(|id| id.as_str())
                    .unwrap_or_default()
                    .to_string();
                let enabled = row
                    .get("enabled")
                    .and_then(|on| on.as_bool())
                    .unwrap_or(true);
                let outcome = self.outcomes.get(&id);
                // `loaded` is the reference's `meta.loaded`: an enabled mod whose entry ran (or
                // which had none to run). A mod that is off is never loaded, whatever its last run
                // did -- the line `modSetEnabled`'s disable writes.
                row["loaded"] = serde_json::json!(enabled && matches!(outcome, Some(Ok(()))));
                if let Some(Err(error)) = outcome {
                    row["failed"] = serde_json::json!(true);
                    row["error"] = serde_json::json!(error);
                }
            }
        }
        table
    }

    /// Keep the cell `goats.mods()` and `goats.mod` read in step with the table. Called where
    /// the table can have changed: after discovery, before an entry runs (so a mod can see the
    /// set it is in) and again once its outcome is known.
    fn refresh_table(&mut self) {
        let json = self.merged_table().to_string();
        *self.table.borrow_mut() = json;
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

        // A mod's `console.log` reaches the host, not the terminal -- and so do its warnings and
        // its errors, each carrying the word it was said with, because `goats.warn` is not the
        // same thing to a player reading the console as `goats.log`.
        let lines = self.lines.clone();
        let warned = self.lines.clone();
        let failed = self.lines.clone();
        context.set_host_callbacks(HostCallbacks {
            console_log: Some(Box::new(move |text: &str| {
                lines.borrow_mut().push(format!("log {text}"));
            })),
            console_warn: Some(Box::new(move |text: &str| {
                warned.borrow_mut().push(format!("warn {text}"));
            })),
            console_error: Some(Box::new(move |text: &str| {
                failed.borrow_mut().push(format!("error {text}"));
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

        // `goats.draw.*`: queue one draw record for Godot to paint (`ModHud` in the
        // scene). One capability for every primitive, and the record is JSON: the two
        // sides agree on a *shape* rather than an argument list, so the shim can grow a
        // primitive without a signature here. This is the API's own drawing surface
        // rather than raylib's, which is the point of having one (`PORT.md` section 6).
        let draws = self.draws.clone();
        context
            .register_fn(
                "__goatsDraw",
                1,
                Box::new(move |call| {
                    let record = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    draws.borrow_mut().push(record);
                    Ok(JsValue::undefined())
                }),
            )
            .map_err(|e| e.to_string())?;

        // `goats.gfx.draw.*`: the **world-space** records, on their own seam, because
        // they are painted by a different thing than `goats.draw`'s are -- `ModWorld`
        // places a node per call and `ModHud` draws a primitive.
        let world_draws = self.world_draws.clone();
        context
            .register_fn(
                "__goatsDraw3d",
                1,
                Box::new(move |call| {
                    let record = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    world_draws.borrow_mut().push(record);
                    Ok(JsValue::undefined())
                }),
            )
            .map_err(|e| e.to_string())?;

        // `goats.gfx.model(name)`: does anything declare this name? A `null` from the
        // facade is a mod comparing against `null`, which is the documented way to tell a
        // handle from a name that resolves to nothing.
        let assets = self.assets.clone();
        context
            .register_fn(
                "__goatsHasAsset",
                1,
                Box::new(move |call| {
                    let name = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    Ok(JsValue::boolean(
                        assets.borrow().contains_key(name.as_str()),
                    ))
                }),
            )
            .map_err(|e| e.to_string())?;

        // `goats.draw.screen()`: the surface the frame's own `emit_hud` named. Two
        // values rather than one object, because the crossing is the cost and a
        // `screen()` call is rare.
        let screen_w = self.screen.clone();
        context
            .register_fn(
                "__goatsScreenW",
                0,
                Box::new(move |_call| Ok(JsValue::number(screen_w.get().0))),
            )
            .map_err(|e| e.to_string())?;
        let screen_h = self.screen.clone();
        context
            .register_fn(
                "__goatsScreenH",
                0,
                Box::new(move |_call| Ok(JsValue::number(screen_h.get().1))),
            )
            .map_err(|e| e.to_string())?;

        // The readable world: the snapshot the core last pushed, as JSON the facade parses.
        // Two calls rather than one because the parse is what costs: `__goatsPush` is the
        // counter the facade compares to decide whether its cached parse is still the
        // frame's, so a frame's reads share one `JSON.parse` instead of each paying one.
        let snapshot = self.snapshot.clone();
        context
            .register_fn(
                "__goatsSnapshot",
                0,
                Box::new(move |_call| Ok(JsValue::string(snapshot.borrow().clone()))),
            )
            .map_err(|e| e.to_string())?;
        let pushes = self.pushes.clone();
        context
            .register_fn(
                "__goatsPush",
                0,
                Box::new(move |_call| Ok(JsValue::number(pushes.get() as f64))),
            )
            .map_err(|e| e.to_string())?;

        // The functional members: every `goats` call that is not a read of a pushed value
        // goes here and is answered by the scene's own `Callable`. One capability for the
        // lot, on `__goatsDraw`'s pattern -- a JSON request and a JSON answer, so the two
        // ends agree on a shape and the surface can grow on the scene's side alone.
        let scene_call = self.scene_call.clone();
        context
            .register_fn(
                "__goatsCall",
                2,
                Box::new(move |call| {
                    let name = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    let args = call
                        .arg(1)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    // The `Callable` is taken out of the borrow before the call, because the
                    // scene's own code runs inside it and a re-entrant `set_scene_call` would
                    // otherwise find the cell borrowed.
                    let callable = scene_call.borrow().clone();
                    let answer = match callable {
                        Some(callable) if callable.is_valid() => {
                            let result = callable.callv(&varray![name, args]);
                            result.try_to::<GString>().unwrap_or_default().to_string()
                        }
                        _ => {
                            "{\"err\":\"the scene has no entry point for goats calls\"}".to_string()
                        }
                    };
                    Ok(JsValue::string(answer))
                }),
            )
            .map_err(|e| e.to_string())?;

        // A mod's *own* geometry and images (`goats.gfx.mesh` / `texture` / `bind`, `APIv1.md`
        // section 4.19). The facade mints the handle and these keep the data until the scene
        // asks; nothing is *built* here, because the renderer is Godot's and an `ArrayMesh` is
        // not a thing this crate is allowed to know about (`godot/PORT.md` section 6's split).
        // Three capabilities and three readers, the shape `assets` already has.
        let meshes = self.meshes.clone();
        context
            .register_fn(
                "__goatsStoreMesh",
                2,
                Box::new(move |call| {
                    let handle = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    let json = call
                        .arg(1)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    meshes.borrow_mut().insert(handle, json);
                    Ok(JsValue::boolean(true))
                }),
            )
            .map_err(|e| e.to_string())?;
        let textures = self.textures.clone();
        context
            .register_fn(
                "__goatsStoreTexture",
                2,
                Box::new(move |call| {
                    let handle = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    let json = call
                        .arg(1)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    textures.borrow_mut().insert(handle, json);
                    Ok(JsValue::boolean(true))
                }),
            )
            .map_err(|e| e.to_string())?;
        let bindings = self.bindings.clone();
        context
            .register_fn(
                "__goatsBind",
                2,
                Box::new(move |call| {
                    let mesh = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    let texture = call
                        .arg(1)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    bindings.borrow_mut().insert(mesh, texture);
                    Ok(JsValue::boolean(true))
                }),
            )
            .map_err(|e| e.to_string())?;

        // A mod's identity (`APIv1.md` section 4.1): the API major and the game's version, once
        // -- they cannot change -- and the mod table, which can. The table is read out of the
        // shared cell rather than the loader because a capability cannot borrow the host, which
        // is the same reason `assets` is an `Rc`.
        context
            .register_fn(
                "__goatsIdentity",
                0,
                Box::new(|_call| {
                    Ok(JsValue::string(
                        serde_json::json!({
                            "api": mods::MOD_API,
                            "game": env!("CARGO_PKG_VERSION"),
                        })
                        .to_string(),
                    ))
                }),
            )
            .map_err(|e| e.to_string())?;
        let table = self.table.clone();
        context
            .register_fn(
                "__goatsMods",
                0,
                Box::new(move |_call| Ok(JsValue::string(table.borrow().clone()))),
            )
            .map_err(|e| e.to_string())?;
        let table = self.table.clone();
        context
            .register_fn(
                "__goatsModInfo",
                1,
                Box::new(move |call| {
                    let id = call
                        .arg(0)
                        .and_then(|value| call.to_string(&value).ok())
                        .unwrap_or_default();
                    let rows: serde_json::Value = serde_json::from_str(&table.borrow())
                        .unwrap_or_else(|_| serde_json::json!([]));
                    let row = rows.as_array().and_then(|rows| {
                        rows.iter().find(|row| {
                            row.get("id").and_then(|value| value.as_str()) == Some(id.as_str())
                        })
                    });
                    // `goats.mod` is `{id, name, version, side}` and nothing else: a mod's own
                    // identity, which is what `mods.js`'s `modInfo` answers too.
                    let info = match row {
                        Some(row) => serde_json::json!({
                            "id": row.get("id"),
                            "name": row.get("name"),
                            "version": row.get("version"),
                            "side": row.get("side"),
                        }),
                        None => serde_json::Value::Null,
                    };
                    Ok(JsValue::string(info.to_string()))
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
            // The same map the host holds, so `__goatsHasAsset` sees what a later
            // `load_mod` puts here.
            assets: self.assets.clone(),
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
            module
                .assets
                .borrow_mut()
                .insert(asset.name.clone(), asset.bytes);
        }

        // A compiled mod ships a module rather than an entry, and the two are read together
        // because a mod may have both (`ABIv1.md` section 3). The bytes are *taken* here --
        // cloned out of the manifest, so the loader's borrow ends before the plugin set is
        // touched -- because the plugin host owns the module's store and memory from here on,
        // and a `.wasm` file is never a path or an `ArrayBuffer` that anybody else holds.
        let compiled = loader.get(id).and_then(|manifest| {
            manifest
                .wasm
                .as_ref()
                .map(|wasm| (wasm.bytes.clone(), manifest.side))
        });

        let mut note = match loader.get(id).and_then(|manifest| manifest.entry_js()) {
            Some(js) => {
                module.context.eval(&js).map_err(|e| e.to_string())?;
                format!("loaded {id} ({asset_count} asset(s))")
            }
            // A mod with no entry and no module is data only, which is a success: the manifest,
            // the assets and the tuning tree are the whole of it.
            None => format!("loaded {id} ({asset_count} asset(s), no entry)"),
        };
        if let Some((bytes, side)) = compiled {
            // An ABI this build does not know, a missing import or a file that is not a module
            // fails *here*, before any of the mod's code runs, and is named like any other broken
            // entry -- the row carries it and the rest still load (`ABIv1.md` section 3.6,
            // `APIv1.md` section 7). An existing instance goes first, which is what a reload
            // wants and what `add_plugin` does in the raylib client.
            self.plugins.remove(id);
            let side = match side {
                mods::Side::Client => PluginSide::Client,
                mods::Side::World => PluginSide::World,
            };
            self.plugins
                .add(id, &bytes, side)
                .map_err(|error| format!("{id}: {error}"))?;
            note = format!("loaded {id} ({asset_count} asset(s), a compiled module)");
        }
        Ok(note)
    }
}

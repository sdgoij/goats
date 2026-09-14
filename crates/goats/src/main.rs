//! A tiny "GOAT" sandbox written in JavaScript, driven through the `rl` host
//! module's 3D surface.
//!
//! The goat model and every sound the scene plays are embedded into the binary
//! (see `ASSETS`) so the game needs no files on disk: the host registers each
//! one with `register_raylib_asset`, and `rl.loadModel`/`rl.loadSound`/
//! `rl.loadMusic` look the bytes up by name before falling back to the
//! filesystem. The scene script is split across `crates/goats/src/game/*.js`
//! and concatenated into one script here, so the parts share a single top-level
//! scope.
//!
//! The host owns the frame loop -- the scene exposes `sceneInit`/`sceneFrame`/
//! `sceneShutdown` instead of running itself -- so it can interleave commands
//! read from stdin between frames. Each command line goes to the scene's
//! `sceneCommand` and its response is written to stdout; everything the engine
//! logs goes to stderr, so stdout stays a clean one-line-in, one-line-out
//! command channel.
//!
//! The host also loads mods. `--mods <dir>` (or `$GOATS_MODS`, or `mods/` next
//! to the executable, or `mods/` in the working directory) is scanned by the
//! `mods` crate, the manifests are validated and ordered, every asset is
//! registered with the engine under an opaque name, and each entry is evaluated
//! against the scene's `goats` global. See `APIv1.md`; the scene end is
//! `crates/goats/src/game/mods.js`.
//!
//! Run: `cargo run --release`

mod audio;
mod net;

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

use mods::watch::ModWatcher;
use mods::{AssetMode, Loader};
use plugin::{PluginSet, Side as PluginSide};
use slag::{Context, HostCallbacks, JsValue};

/// Every asset the scene loads, embedded so the binary is self-contained. The
/// name is exactly the path the scene hands to `rl.loadModel`/`rl.loadSound`/
/// `rl.loadMusic`, and the engine resolves the bytes by that name before
/// falling back to the filesystem. The WAV ambience beds are shipped as Ogg
/// Vorbis: 71 MB of PCM would dwarf the rest of the binary, while the Ogg loops
/// are 3.6 MB for the same 60 s at the same sample rate.
///
/// The headless harness (`crates/harness/tests/scene_logic.rs`) parses this table
/// and checks every path the scene requests against it, so the two cannot drift
/// apart -- a path missed here would silently load from disk instead.
static ASSETS: &[(&str, &[u8])] = &[
    // The animated goat (walk / trot / run / jump / idle / sleep / eat / death).
    (
        "goat_animated.glb",
        include_bytes!("../../../goat_animated.glb"),
    ),
    // The background track and the two weather beds (60 s loops).
    (
        "sfx/jkstudios-rage-2-187959.mp3",
        include_bytes!("../../../sfx/jkstudios-rage-2-187959.mp3"),
    ),
    (
        "sfx/WE Heavy Outside Rain 1.ogg",
        include_bytes!("../../../sfx/WE Heavy Outside Rain 1.ogg"),
    ),
    (
        "sfx/WE Light Wind Whistle 1.ogg",
        include_bytes!("../../../sfx/WE Light Wind Whistle 1.ogg"),
    ),
    // The bleats, picked at random with a little pitch variation.
    (
        "sfx/dragon-studio-goat-baa-390303.mp3",
        include_bytes!("../../../sfx/dragon-studio-goat-baa-390303.mp3"),
    ),
    (
        "sfx/dragon-studio-goat-kid-bleating-390290.mp3",
        include_bytes!("../../../sfx/dragon-studio-goat-kid-bleating-390290.mp3"),
    ),
    (
        "sfx/dragon-studio-goat-sound-390298.mp3",
        include_bytes!("../../../sfx/dragon-studio-goat-sound-390298.mp3"),
    ),
    (
        "sfx/dragon-studio-goat-sound-effect-390305.mp3",
        include_bytes!("../../../sfx/dragon-studio-goat-sound-effect-390305.mp3"),
    ),
    (
        "sfx/mightuser-1-goat-sound-effect-259473.mp3",
        include_bytes!("../../../sfx/mightuser-1-goat-sound-effect-259473.mp3"),
    ),
    (
        "sfx/freesound_community-happy-goat-6463.mp3",
        include_bytes!("../../../sfx/freesound_community-happy-goat-6463.mp3"),
    ),
    // Thunder for the heavy-rain phase.
    (
        "sfx/WE Thunder 1.ogg",
        include_bytes!("../../../sfx/WE Thunder 1.ogg"),
    ),
    (
        "sfx/WE Thunder 26.ogg",
        include_bytes!("../../../sfx/WE Thunder 26.ogg"),
    ),
    (
        "sfx/WE Thunder 29.ogg",
        include_bytes!("../../../sfx/WE Thunder 29.ogg"),
    ),
];

/// The scene, joined from `crates/goats/src/game/` in the running order
/// `crates/scene` owns. The list lives there and nowhere else, so the client,
/// the headless server and the test harness all evaluate the same script in the
/// same order.
use scene::SCENE;

/// One of the scene's global functions, resolved by name.
fn scene_function(context: &Context, name: &str) -> JsValue {
    context
        .global()
        .unwrap_or_else(|error| panic!("global object: {error}"))
        .get(name)
        .unwrap_or_else(|error| panic!("scene global {name}: {error}"))
}

/// One of the scene's global functions, if it defines it. The network bridge
/// uses this: a scene that predates it leaves the host doing no networking
/// rather than refusing to start.
fn scene_function_if_present(context: &Context, name: &str) -> Option<JsValue> {
    let value = context.global().ok()?.get(name).ok()?;
    if value.is_undefined() {
        None
    } else {
        Some(value)
    }
}

const USAGE: &str = "\
goats [--mods DIRECTORY] [--no-mods] [--watch]

  --mods DIRECTORY   load mods from DIRECTORY instead of the default search
                     ($GOATS_MODS, then mods/ next to the executable, then
                     mods/ in the current directory)
  --no-mods          ignore every mod
  --watch            reload a mod when its files change on disk (development)
  -h, --help         this text";

/// How long to wait for an editor's burst of writes to settle before reloading.
const WATCH_SETTLE: Duration = Duration::from_millis(250);

/// What the command line asked for.
struct Options {
    mods_dir: Option<PathBuf>,
    no_mods: bool,
    watch: bool,
    help: bool,
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut options = Options {
        mods_dir: None,
        no_mods: false,
        watch: false,
        help: false,
    };
    let mut args = args;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => options.help = true,
            "--no-mods" => options.no_mods = true,
            "--watch" => options.watch = true,
            "--mods" => {
                options.mods_dir = Some(PathBuf::from(
                    args.next().ok_or("--mods needs a directory")?,
                ));
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(options)
}

/// An absolute form of `dir`, so watcher events (which are absolute) match the
/// paths discovery recorded. Windows canonical paths carry a `\\?\` verbatim
/// prefix that event paths do not, so it is stripped.
fn canonical_dir(dir: &Path) -> PathBuf {
    let canonical = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    #[cfg(windows)]
    {
        let text = canonical.to_string_lossy();
        if let Some(stripped) = text.strip_prefix(r"\\?\") {
            return PathBuf::from(stripped);
        }
    }
    canonical
}

/// The mods directory: an explicit flag, else `$GOATS_MODS`, else `mods/` next
/// to the executable, else `mods/` in the working directory. An explicit flag
/// is honoured even if it does not exist, so the loader can explain why.
fn resolve_mods_dir(options: &Options) -> Option<PathBuf> {
    if options.no_mods {
        return None;
    }
    if let Some(dir) = &options.mods_dir {
        return Some(dir.clone());
    }
    if let Some(dir) = std::env::var_os("GOATS_MODS") {
        if !dir.is_empty() {
            return Some(PathBuf::from(dir));
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let candidate = parent.join("mods");
            if candidate.is_dir() {
                return Some(candidate);
            }
        }
    }
    let candidate = PathBuf::from("mods");
    if candidate.is_dir() {
        return Some(candidate);
    }
    None
}

/// Call one of the scene's optional host-facing functions, logging (not
/// panicking) when it is absent or throws. A scene without the mod surface
/// simply ignores mods.
fn call_scene(context: &mut Context, name: &str, args: &[JsValue]) {
    let function = match scene_function_if_present(context, name) {
        Some(function) => function,
        None => return,
    };
    if let Err(error) = context.call(&function, &JsValue::undefined(), args) {
        eprintln!("[mods] {name}: {error}");
    }
}

/// The world-mod set this client presents: every `side: "world"` mod, by
/// identity and content hash, in id order. Client-side mods are local and never
/// travel; a host compares this set with every joiner's and refuses a mismatch.
fn world_mod_refs(loader: &Loader) -> Vec<session::ModRef> {
    let mut mods: Vec<session::ModRef> = loader
        .mods()
        .iter()
        .filter(|manifest| manifest.side == mods::Side::World)
        .map(|manifest| session::ModRef {
            id: manifest.id.clone(),
            version: manifest.version.clone(),
            hash: manifest.hash,
        })
        .collect();
    mods.sort_by(|a, b| a.id.cmp(&b.id));
    mods
}

fn report_mod(context: &mut Context, id: &str, ok: bool, error: &str) {
    call_scene(
        context,
        "sceneModResult",
        &[
            JsValue::string(id),
            JsValue::boolean(ok),
            JsValue::string(error),
        ],
    );
}

/// Load one mod's entry into the running scene. A missing entry is a success (a
/// data-only mod); a throwing entry is reported, never fatal.
fn eval_entry(context: &mut Context, loader: &Loader, id: &str) {
    call_scene(context, "sceneModEnd", &[JsValue::string(id)]);
    let js = match loader.get(id).and_then(|manifest| manifest.entry_js()) {
        Some(js) => js,
        None => {
            report_mod(context, id, true, "");
            return;
        }
    };
    match context.eval(&js) {
        Ok(_) => report_mod(context, id, true, ""),
        Err(error) => {
            let message = error.to_string();
            eprintln!("[mods] {id} failed: {message}");
            report_mod(context, id, false, &message);
        }
    }
}

/// One enable/disable/reload the console asked for.
fn handle_mod_intent(
    context: &mut Context,
    loader: &mut Loader,
    plugins: &Rc<RefCell<PluginSet>>,
    line: &str,
) {
    let intent: serde_json::Value = match serde_json::from_str(line) {
        Ok(intent) => intent,
        Err(error) => {
            eprintln!("[mods] unreadable intent: {error}");
            return;
        }
    };
    let kind = intent
        .get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let id = intent
        .get("id")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    if id.is_empty() {
        eprintln!("[mods] intent without an id: {line}");
        return;
    }
    match kind {
        "disable" => {
            call_scene(context, "sceneModEnd", &[JsValue::string(id)]);
            plugins.borrow_mut().remove(id);
        }
        "enable" | "reload" => reload_and_eval(context, loader, plugins, id),
        other => eprintln!("[mods] unknown intent '{other}'"),
    }
}

/// Re-read a mod from its source (a directory or a zip) and evaluate it, so an
/// edit takes effect without a restart. A read failure falls back to the cached
/// copy rather than leaving the mod unloadable.
fn reload_and_eval(
    context: &mut Context,
    loader: &mut Loader,
    plugins: &Rc<RefCell<PluginSet>>,
    id: &str,
) {
    if let Err(error) = loader.reload(id, AssetMode::Keep) {
        eprintln!("[mods] {error}");
    }
    // The entry is evaluated fresh; its tuning tree is merged again, so a
    // `tuning.json` edit lands too. Assets are re-read for the digest but not
    // re-registered, so an asset change still needs a restart.
    if let Some(json) = loader
        .get(id)
        .and_then(|manifest| manifest.tuning_json.clone())
    {
        call_scene(
            context,
            "sceneModTuning",
            &[JsValue::string(id), JsValue::string(json)],
        );
    }
    eval_entry(context, loader, id);
    // A compiled mod re-instantiates from the re-read bytes; its old instance is
    // dropped first. It has no entry, so this is the whole of the reload.
    let compiled = loader.get(id).and_then(|manifest| {
        manifest
            .wasm
            .as_ref()
            .map(|wasm| (manifest.side, wasm.bytes.clone()))
    });
    if let Some((side, bytes)) = compiled {
        plugins.borrow_mut().remove(id);
        let side = match side {
            mods::Side::Client => PluginSide::Client,
            mods::Side::World => PluginSide::World,
        };
        if let Err(error) = plugins.borrow_mut().add(id, &bytes, side) {
            eprintln!("[mods] {id} failed: {error}");
            call_scene(
                context,
                "sceneModResult",
                &[
                    JsValue::string(id),
                    JsValue::boolean(false),
                    JsValue::string(error),
                ],
            );
        }
    }
}

fn main() {
    let options = match parse_args(std::env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("goats: {message}\n{USAGE}");
            std::process::exit(2);
        }
    };
    if options.help {
        println!("{USAGE}");
        return;
    }

    // Discover mods before the window opens: a bad manifest is reported now,
    // and the assets have to be in the engine's registry before the scene loads.
    // The directory is made absolute so the watcher's event paths, which are
    // absolute, can be matched against a mod's source.
    let mods_dir = resolve_mods_dir(&options).map(|dir| canonical_dir(&dir));
    let mut loader = match &mods_dir {
        Some(dir) => {
            eprintln!("[mods] scanning {}", dir.display());
            Loader::discover(dir)
        }
        None => Loader::empty(),
    };
    for error in loader.errors() {
        eprintln!("[mods] {error}");
    }

    // `--watch` reloads a mod when its files change on disk. It is a development
    // aid for the local client: a world mod is part of the compatibility set
    // fixed at join, so a server should not watch.
    let watcher = if options.watch {
        match &mods_dir {
            Some(dir) => match ModWatcher::new(dir) {
                Ok(watcher) => {
                    eprintln!("[mods] watching {} for changes", dir.display());
                    Some(watcher)
                }
                Err(error) => {
                    eprintln!("[mods] {error}");
                    None
                }
            },
            None => {
                eprintln!("[mods] --watch has nothing to watch (no mods directory)");
                None
            }
        }
    } else {
        None
    };

    let world_mods = world_mod_refs(&loader);

    let mut context = Context::new().unwrap();
    let callbacks = HostCallbacks {
        console_log: Some(Box::new(|text| eprintln!("[js] {text}"))),
        ..HostCallbacks::default()
    };
    context.set_host_callbacks(callbacks);
    slag::install_jit(&mut context).unwrap();
    context.install_raylib().unwrap();
    // Register every embedded asset before the scene runs; the loaders resolve
    // these names to the bytes above rather than reading from disk.
    for &(name, data) in ASSETS {
        context.register_raylib_asset(name, data);
    }
    // Mod assets go in under opaque names, so the scene resolves them without a
    // path. `register_raylib_asset` wants `&'static`, so the bytes are leaked
    // for the life of the process; the loader gives up its copy here.
    for manifest in loader.mods_mut() {
        for asset in manifest.take_assets() {
            let name: &'static str = Box::leak(asset.name.into_boxed_str());
            let data: &'static [u8] = Box::leak(asset.bytes.into_boxed_slice());
            context.register_raylib_asset(name, data);
        }
    }
    // The scene only defines its frame functions here; the loop below drives it.
    context.eval(SCENE).unwrap();

    // Hand the scene the metadata table, load every entry in order, then close
    // registration. A scene without the mod surface ignores all of this.
    let table = loader.table_json();
    call_scene(&mut context, "sceneMods", &[JsValue::string(table)]);
    for id in loader.ids() {
        eval_entry(&mut context, &loader, &id);
    }
    // A compiled mod ships a module rather than an entry. The Rust host (M17b)
    // instantiates and drives it, so the bytes never cross into JavaScript as a
    // path or an ArrayBuffer: the host owns the module's `Store` and memory.
    let plugins = Rc::new(RefCell::new(PluginSet::new()));
    for manifest in loader.mods() {
        let Some(wasm) = manifest.wasm.as_ref() else {
            continue;
        };
        let side = match manifest.side {
            mods::Side::Client => PluginSide::Client,
            mods::Side::World => PluginSide::World,
        };
        if let Err(error) = plugins.borrow_mut().add(&manifest.id, &wasm.bytes, side) {
            eprintln!("[mods] {} failed: {error}", manifest.id);
            call_scene(
                &mut context,
                "sceneModResult",
                &[
                    JsValue::string(manifest.id.clone()),
                    JsValue::boolean(false),
                    JsValue::string(error),
                ],
            );
        }
    }
    call_scene(&mut context, "sceneModFreeze", &[]);
    if !loader.mods().is_empty() {
        eprintln!("[mods] {} discovered", loader.mods().len());
    }
    // The set a joiner has to match, hashes included: a refusal names both ends,
    // and this is the line it is read against.
    eprintln!("[mods] world set: {}", session::describe_mods(&world_mods));

    let init = scene_function(&context, "sceneInit");
    let frame = scene_function(&context, "sceneFrame");
    let shutdown = scene_function(&context, "sceneShutdown");
    let command = scene_function(&context, "sceneCommand");
    // The seams the Rust plugin host uses each frame.
    let scene_dt = scene_function(&context, "sceneDt");
    let net_world_local = scene_function(&context, "netWorldLocal");
    let set_wasm_published = scene_function(&context, "sceneSetWasmPublished");
    let scene_belly = scene_function(&context, "sceneBelly");
    let set_wasm_hud = scene_function(&context, "sceneSetWasmHud");

    // The apply seam: a mirroring client's JS scene hands a peer's published
    // state back to the Rust host through this native function.
    {
        let plugins_for_apply = Rc::clone(&plugins);
        context
            .register_fn(
                "sceneWasmApply",
                2,
                Box::new(move |call| {
                    let id = call
                        .arg(0)
                        .and_then(|value| value.as_string())
                        .unwrap_or_default();
                    let data = call
                        .arg(1)
                        .and_then(|value| value.as_string())
                        .unwrap_or_default();
                    if let Some(bytes) = plugin::base64_decode(&data) {
                        let _ = plugins_for_apply.borrow_mut().apply(&id, &bytes);
                    }
                    Ok(JsValue::undefined())
                }),
            )
            .map_err(|error| error.to_string())
            .unwrap();
    }

    // The describe seam: `mod info` asks the Rust host for a plugin's ABI,
    // imports, frame count and log through this native function.
    {
        let plugins_for_describe = Rc::clone(&plugins);
        context
            .register_fn(
                "sceneWasmDescribe",
                1,
                Box::new(move |call| {
                    let id = call
                        .arg(0)
                        .and_then(|value| value.as_string())
                        .unwrap_or_default();
                    let json = plugins_for_describe
                        .borrow()
                        .describe_json(&id)
                        .unwrap_or_else(|| "null".to_string());
                    Ok(JsValue::string(json))
                }),
            )
            .map_err(|error| error.to_string())
            .unwrap();
    }

    // Draining stdin on a reader thread keeps both sides non-blocking: the loop
    // never stalls on input, and a command never waits for a frame.
    let (lines, pending) = std::sync::mpsc::channel::<String>();
    std::thread::Builder::new()
        .name("stdin".into())
        .spawn(move || {
            for line in std::io::stdin().lock().lines() {
                match line {
                    Ok(line) => {
                        if lines.send(line).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        })
        .unwrap();

    context.call(&init, &JsValue::undefined(), &[]).unwrap();

    // The network bridge. Both entry points live in the scene (`net.js`); the
    // host only moves lines between the frame loop and the runtime thread.
    let net_event = scene_function_if_present(&context, "sceneNetEvent");
    let net_drain = scene_function_if_present(&context, "sceneNetDrain");
    let mod_drain = scene_function_if_present(&context, "sceneModDrain");
    let mut net = net::Net::start(world_mods);
    let mut voice = audio::Voice::start(&mut net);

    // Watched mods whose files changed recently, waiting for the writes to stop.
    let mut settling: HashMap<String, Instant> = HashMap::new();

    loop {
        while let Ok(line) = pending.try_recv() {
            if line.trim().is_empty() {
                continue;
            }
            match context.call(&command, &JsValue::undefined(), &[JsValue::string(line)]) {
                Ok(response) => {
                    if let Some(text) = response.as_string() {
                        println!("{text}");
                        let _ = std::io::stdout().flush();
                    }
                }
                // A throwing command must not take the game down: report it on
                // the response channel and keep running.
                Err(error) => {
                    println!("error {error}");
                    let _ = std::io::stdout().flush();
                }
            }
        }

        // Networking events land on the frame boundary, like commands do.
        if let Some(handler) = &net_event {
            while let Some(line) = net.next_event() {
                if let Err(error) =
                    context.call(handler, &JsValue::undefined(), &[JsValue::string(line)])
                {
                    eprintln!("[net] sceneNetEvent: {error}");
                }
            }
        }

        let running = context
            .call(&frame, &JsValue::undefined(), &[])
            .unwrap()
            .as_boolean()
            .unwrap_or(false);
        if !running {
            break;
        }

        // The Rust host drives its compiled mods after the world has moved, at
        // the scene's own `dt` (which a menu freeze holds at 0). A mirroring
        // client does not tick world mods.
        let dt = context
            .call(&scene_dt, &JsValue::undefined(), &[])
            .ok()
            .and_then(|value| value.as_number())
            .unwrap_or(0.0);
        let world_local = context
            .call(&net_world_local, &JsValue::undefined(), &[])
            .ok()
            .and_then(|value| value.as_boolean())
            .unwrap_or(true);
        // The player's belly fullness is a client-local reading the compiled
        // mods reach through `goats.belly`; it is pushed in before the tick so
        // the module's own `goats_hud` model is one frame old at most.
        let belly = context
            .call(&scene_belly, &JsValue::undefined(), &[])
            .ok()
            .and_then(|value| value.as_number())
            .unwrap_or(0.0);
        plugins.borrow_mut().set_belly(belly as f32);
        plugins.borrow_mut().tick_all(dt as f32, world_local);
        let published = plugins.borrow().published_json();
        let _ = context.call(
            &set_wasm_published,
            &JsValue::undefined(),
            &[JsValue::string(published)],
        );
        let hud = plugins.borrow_mut().hud_json();
        let _ = context.call(
            &set_wasm_hud,
            &JsValue::undefined(),
            &[JsValue::string(hud)],
        );

        // Mod enable/disable/reload intents the console queued. The host
        // re-reads and evaluates the entry, exactly as it did at startup.
        if let Some(drain) = &mod_drain {
            match context.call(drain, &JsValue::undefined(), &[]) {
                Ok(value) => {
                    if let Some(text) = value.as_string() {
                        for line in text.lines() {
                            let line = line.trim();
                            if !line.is_empty() {
                                handle_mod_intent(&mut context, &mut loader, &plugins, line);
                            }
                        }
                    }
                }
                Err(error) => eprintln!("[mods] sceneModDrain: {error}"),
            }
        }

        // A watched mod file changed. Coalesce the burst an editor produces and
        // reload once the writes have settled, so a half-written file is never
        // evaluated.
        if let Some(watcher) = &watcher {
            let now = Instant::now();
            for path in watcher.take_changed() {
                for id in loader.mods_touching(&path) {
                    settling.insert(id, now);
                }
            }
            let mut ready: Vec<String> = settling
                .iter()
                .filter(|(_, at)| now.duration_since(**at) >= WATCH_SETTLE)
                .map(|(id, _)| id.clone())
                .collect();
            ready.sort();
            for id in ready {
                settling.remove(&id);
                eprintln!("[mods] {id} changed on disk; reloading");
                reload_and_eval(&mut context, &mut loader, &plugins, &id);
            }
        }

        // The scene's queued intents leave on the same boundary. The voice gain
        // is the audio module's rather than the runtime thread's, so it is
        // intercepted here and never reaches `net`.
        if let Some(drain) = &net_drain {
            match context.call(drain, &JsValue::undefined(), &[]) {
                Ok(value) => {
                    if let Some(text) = value.as_string() {
                        for line in text.lines() {
                            let line = line.trim();
                            if line.is_empty() {
                                continue;
                            }
                            if let Some(gain) = net::voice_gain(line) {
                                voice.set_gain(gain);
                            } else {
                                net.send(line);
                            }
                        }
                    }
                }
                Err(error) => eprintln!("[net] sceneNetDrain: {error}"),
            }
        }

        // Decoded voice reaches raylib here, on the frame thread.
        voice.pump();
    }
    drop(voice);
    context.call(&shutdown, &JsValue::undefined(), &[]).unwrap();
    eprintln!("done");
}

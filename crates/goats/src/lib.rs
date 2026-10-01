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

// WASM.md D4: a browser has no UDP socket for `iroh` and no host for `cpal`'s
// capture stream, so both modules -- and the services they wrap -- are compiled
// out of a wasm build rather than stubbed.
#[cfg(not(target_arch = "wasm32"))]
mod audio;
#[cfg(not(target_arch = "wasm32"))]
mod net;

// The phone's touch surface, installed as the `android` global, and the JNI half
// of the Java `Activity` behind P2's keyboard, clipboard and insets. Android only:
// the desktop client, the server and the harness get no such global, and the
// scene's guard is written on its absence (ANDROID.md D1). Public because
// `crates/android` -- the cdylib the framework loads -- has to keep the two
// by-name JNI entry points reachable, and they are defined here.
#[cfg(target_os = "android")]
pub mod android;

// The browser's surface, minimal for now (WASM.md D1): installed only on a wasm
// target, so the scene can branch on `typeof web` and size its window for a tab.
#[cfg(target_arch = "wasm32")]
pub mod web;

use std::cell::RefCell;
// `HashMap` and `BufRead` are the watcher's settle map and the stdin reader's
// line loop; both are desktop-only (WASM.md D4/D6).
#[cfg(not(target_arch = "wasm32"))]
use std::collections::HashMap;
#[cfg(not(target_arch = "wasm32"))]
use std::io::BufRead;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::rc::Rc;
#[cfg(not(target_arch = "wasm32"))]
use std::time::{Duration, Instant};

#[cfg(not(target_arch = "wasm32"))]
use mods::watch::ModWatcher;
use mods::{AssetMode, Loader};
#[cfg(not(target_arch = "wasm32"))]
use plugin::{PluginSet, Side as PluginSide};
use slag::{Context, HostCallbacks, JsValue};

// The compiled-mod host (M17b) is a `wasmtime`-shaped host, and `wasmtime` has no
// wasm32 build. A wasm build keeps the same call shape with a type that carries
// no state, and the few sites that would drive a module are `cfg`-gated where
// they stand (WASM.md D4).
#[cfg(target_arch = "wasm32")]
#[derive(Default)]
struct PluginSet;

#[cfg(target_arch = "wasm32")]
impl PluginSet {
    fn new() -> PluginSet {
        PluginSet
    }

    // The frame body calls these every frame and the seam that mirrors their
    // output into the scene reads them back, so a wasm build answers with the
    // empty set rather than forking the loop (WASM.md D4).
    fn set_belly(&mut self, _fullness: f32) {}

    fn tick_all(&mut self, _dt: f32, _world_local: bool) {}

    fn published_json(&self) -> String {
        "{}".to_string()
    }

    fn hud_json(&mut self) -> String {
        "{}".to_string()
    }
}

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
    // The bangs, one picked per blast and faded with its distance.
    (
        "sfx/dragon-studio-explosion-sound-effect-425455.mp3",
        include_bytes!("../../../sfx/dragon-studio-explosion-sound-effect-425455.mp3"),
    ),
    (
        "sfx/dragon-studio-loud-explosion-425457.mp3",
        include_bytes!("../../../sfx/dragon-studio-loud-explosion-425457.mp3"),
    ),
    (
        "sfx/freesound_community-medium-explosion-40472.mp3",
        include_bytes!("../../../sfx/freesound_community-medium-explosion-40472.mp3"),
    ),
    (
        "sfx/soundreality-explosion-fx-343683.mp3",
        include_bytes!("../../../sfx/soundreality-explosion-fx-343683.mp3"),
    ),
    (
        "sfx/universfield-epic-cinematic-explosion-454857.mp3",
        include_bytes!("../../../sfx/universfield-epic-cinematic-explosion-454857.mp3"),
    ),
    // The grit a bang throws, played a beat after the bang itself.
    (
        "sfx/freesound_community-falling-rock-105396.mp3",
        include_bytes!("../../../sfx/freesound_community-falling-rock-105396.mp3"),
    ),
    (
        "sfx/freesound_community-gravel-stone-dirt-debris-falling-small-1-3-36216.mp3",
        include_bytes!(
            "../../../sfx/freesound_community-gravel-stone-dirt-debris-falling-small-1-3-36216.mp3"
        ),
    ),
    (
        "sfx/freesound_community-stones-falling-6375.mp3",
        include_bytes!("../../../sfx/freesound_community-stones-falling-6375.mp3"),
    ),
    (
        "sfx/universfield-heavy-object-falling-291096.mp3",
        include_bytes!("../../../sfx/universfield-heavy-object-falling-291096.mp3"),
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
goats [--mods DIRECTORY] [--no-mods] [--watch] [--pull] [--gc-trace]

  --mods DIRECTORY   load mods from DIRECTORY instead of the default search
                     ($GOATS_MODS, then mods/ next to the executable, then
                     mods/ in the current directory)
  --no-mods          ignore every mod
  --watch            reload a mod when its files change on disk (development)
  --pull             fetch the world mods a host runs and this client lacks when
                     a join is refused for them, install them, and retry once;
                     also serve this client's own world mods to a fetching joiner
  --gc-trace         print one line per collection to stderr, from the engine's
                     own telemetry (level, pause_us, live, swept, young): the
                     pause structure, which a frame average cannot see
  -h, --help         this text";

/// How long to wait for an editor's burst of writes to settle before reloading.
/// The watcher is desktop-only (WASM.md D6).
#[cfg(not(target_arch = "wasm32"))]
const WATCH_SETTLE: Duration = Duration::from_millis(250);

/// What the command line asked for.
struct Options {
    mods_dir: Option<PathBuf>,
    no_mods: bool,
    watch: bool,
    pull: bool,
    gc_trace: bool,
    help: bool,
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut options = Options {
        mods_dir: None,
        no_mods: false,
        watch: false,
        pull: false,
        gc_trace: false,
        help: false,
    };
    let mut args = args;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => options.help = true,
            "--no-mods" => options.no_mods = true,
            "--watch" => options.watch = true,
            "--pull" => options.pull = true,
            "--gc-trace" => options.gc_trace = true,
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
    if let Some(dir) = std::env::var_os("GOATS_MODS")
        && !dir.is_empty()
    {
        return Some(PathBuf::from(dir));
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(parent) = exe.parent()
    {
        let candidate = parent.join("mods");
        if candidate.is_dir() {
            return Some(candidate);
        }
    }
    let candidate = PathBuf::from("mods");
    if candidate.is_dir() {
        return Some(candidate);
    }
    // `--pull` promises to install what it fetches, so it needs somewhere to put
    // it: a client with no mods directory gets the default one rather than a
    // feature that cannot work. Nothing is written until a mod is actually
    // fetched.
    if options.pull {
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
///
/// There is no joiner to compare with in a browser, and `session` is not in a
/// wasm build's dependency set (WASM.md D4).
#[cfg(not(target_arch = "wasm32"))]
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

/// Instantiate a compiled mod's module in the plugin host (M17b). The Rust host
/// owns the module's `Store` and memory, so the bytes never cross into JavaScript
/// as a path or an ArrayBuffer. An existing instance is dropped first: a mod's
/// module goes with its mod, and that is what a reload does too.
#[cfg(not(target_arch = "wasm32"))]
fn add_plugin(
    context: &mut Context,
    plugins: &Rc<RefCell<PluginSet>>,
    id: &str,
    side: mods::Side,
    bytes: &[u8],
) {
    let side = match side {
        mods::Side::Client => PluginSide::Client,
        mods::Side::World => PluginSide::World,
    };
    plugins.borrow_mut().remove(id);
    if let Err(error) = plugins.borrow_mut().add(id, bytes, side) {
        eprintln!("[mods] {id} failed: {error}");
        report_mod(context, id, false, &error);
    }
}

/// The archives this client can serve a fetching joiner (M18d): every world mod in
/// its distributable form, which is the shape the loader reads back. `goatsd` has
/// the same walk over its own loader; a session hosted from this client is the same
/// host to a joiner either way, so it serves the same thing. A wasm build has no
/// session to serve (WASM.md D4).
#[cfg(not(target_arch = "wasm32"))]
fn mod_archives(loader: &Loader) -> Vec<(session::ModRef, Vec<u8>)> {
    loader
        .mods()
        .iter()
        .filter(|manifest| manifest.side == mods::Side::World)
        .filter_map(|manifest| match mods::archive_source(&manifest.source) {
            Ok(bytes) => Some((
                session::ModRef {
                    id: manifest.id.clone(),
                    version: manifest.version.clone(),
                    hash: manifest.hash,
                },
                bytes,
            )),
            Err(error) => {
                eprintln!(
                    "[mods] could not package {} for a fetch: {error}",
                    manifest.id
                );
                None
            }
        })
        .collect()
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
            // A compiled mod's instance goes with its mod, where there is a
            // compiled-mod host to hold one (WASM.md D4).
            #[cfg(not(target_arch = "wasm32"))]
            plugins.borrow_mut().remove(id);
        }
        "enable" | "reload" => reload_and_eval(context, loader, plugins, id),
        other => eprintln!("[mods] unknown intent '{other}'"),
    }
    #[cfg(target_arch = "wasm32")]
    let _ = plugins;
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
    // dropped first. It has no entry, so this is the whole of the reload. A wasm
    // build has no compiled-mod host to re-instantiate anything in (WASM.md D4).
    #[cfg(not(target_arch = "wasm32"))]
    {
        let compiled = loader.get(id).and_then(|manifest| {
            manifest
                .wasm
                .as_ref()
                .map(|wasm| (manifest.side, wasm.bytes.clone()))
        });
        if let Some((side, bytes)) = compiled {
            add_plugin(context, plugins, id, side, &bytes);
        }
    }
    #[cfg(target_arch = "wasm32")]
    let _ = plugins;
}

/// Is this changed path a mod archive that arrived from a host (M18d)? The
/// watcher's business is a mod the player is editing, and a pulled archive is
/// neither editable in place nor theirs: without this, installing one under
/// `--watch` would reload the mod a moment after it was loaded. Neither the
/// watcher nor a pull exists in a browser (WASM.md D4/D6).
#[cfg(not(target_arch = "wasm32"))]
fn pulled_archive(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with(pull::PREFIX))
}

/// Load the mods a pull just installed (M18d).
///
/// The scene builds its mod table once and closes registration
/// (`sceneModFreeze`), so a mod that arrives later goes in through
/// `sceneModAdd` -- and the rest is the boot path, in the order that makes it
/// work: the metadata first (so the entry resolves the asset names it declared
/// and reads its tuning tree), then the bytes registered with the engine, then
/// the entry itself, then a compiled mod's module.
///
/// The host's `loader` is replaced by a fresh walk, because a pulled mod is a file
/// discovery has never seen: `Loader` has no way to add one. A pull is a
/// networking feature and a wasm build has none (WASM.md D4).
#[cfg(not(target_arch = "wasm32"))]
fn load_pulled(
    context: &mut Context,
    loader: &mut Loader,
    plugins: &Rc<RefCell<PluginSet>>,
    mods_dir: Option<&Path>,
    ids: &[String],
) {
    let Some(dir) = mods_dir else {
        eprintln!("[mods] a mod was pulled but there is no mods directory to load it from");
        return;
    };
    *loader = Loader::discover(dir);
    for error in loader.errors() {
        eprintln!("[mods] {error}");
    }
    for id in ids {
        add_pulled_mod(context, loader, plugins, id);
    }
}

/// Add one mod the scene has not seen before, exactly as `ids` names it.
#[cfg(not(target_arch = "wasm32"))]
fn add_pulled_mod(
    context: &mut Context,
    loader: &mut Loader,
    plugins: &Rc<RefCell<PluginSet>>,
    id: &str,
) {
    let Some(manifest) = loader
        .mods_mut()
        .iter_mut()
        .find(|manifest| manifest.id.as_str() == id)
    else {
        eprintln!("[mods] {id} was pulled but is not in the mods directory");
        return;
    };
    let table = serde_json::to_string(&manifest.json()).unwrap_or_else(|_| "{}".to_string());
    // The bytes are handed over before the entry runs: an entry's `rl.loadModel`
    // resolves the opaque name it declared, and a mod that loaded nothing would
    // be a silent half-join. The boot path registers every mod's assets before
    // any entry runs for the same reason.
    let assets = manifest.take_assets();
    let compiled = manifest
        .wasm
        .as_ref()
        .map(|wasm| (manifest.side, wasm.bytes.clone()));
    call_scene(context, "sceneModAdd", &[JsValue::string(table)]);
    for asset in assets {
        let name: &'static str = Box::leak(asset.name.into_boxed_str());
        let data: &'static [u8] = Box::leak(asset.bytes.into_boxed_slice());
        context.register_raylib_asset(name, data);
    }
    eval_entry(context, loader, id);
    if let Some((side, bytes)) = compiled {
        add_plugin(context, plugins, id, side, &bytes);
    }
}

/// The client's entry point: read the environment's arguments, load the mods,
/// open the window and own the frame loop.
///
/// It is a plain function rather than `fn main` so that the Android `cdylib` in
/// `crates/android` can reach it: raylib's `android_main` calls a C-ABI
/// `main`, which a binary crate cannot define without colliding with the Rust
/// runtime's own.
pub fn run() {
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
    let mods_dir = resolve_mods_dir(&options).map(|dir| {
        // A client that will pull needs somewhere to install, and `--pull` on a
        // fresh install has just named the default directory. Creating it now
        // keeps the scan below from reporting a directory that is only missing
        // because nothing has been fetched yet.
        if options.pull
            && !dir.is_dir()
            && let Err(error) = std::fs::create_dir_all(&dir)
        {
            eprintln!("[mods] {}: {error}", dir.display());
        }
        canonical_dir(&dir)
    });
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
    // fixed at join, so a server should not watch. A tab has no notification API
    // and no filesystem to watch (WASM.md D6).
    #[cfg(not(target_arch = "wasm32"))]
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

    // The join-time world set exists to be compared with a joiner's; a browser has
    // nobody to compare with (WASM.md D4).
    #[cfg(not(target_arch = "wasm32"))]
    let world_mods = world_mod_refs(&loader);
    if options.pull && options.no_mods {
        // Not a contradiction worth refusing to start over: `--no-mods` is the
        // stronger statement, and a pull with nowhere to install is simply off.
        eprintln!("[mods] --pull is off: --no-mods leaves no mods directory to install into");
    }

    let mut context = Context::new().unwrap();
    // The engine's per-collection telemetry, through the embedding context -- the
    // engine's own `Context::set_gc_trace`, so no crate of its internals is named
    // here. One line per collection on stderr (`gc-trace minor pause_us=...
    // live=...->... swept=... young=...`), which is the pause structure a frame
    // average cannot show; turned on before the scene loads so that is traced too
    // (PERF.md, appendix B).
    // A browser has no argv of its own, but `web/index.html` builds
    // `Module.arguments` from the URL query string (`?gctrace=1`), so the same
    // `--gc-trace` flag reaches `parse_args` here as on the desktop (WASM.md,
    // risk 1).
    if options.gc_trace {
        context.set_gc_trace(true);
        println!("[gc] tracing every collection to stderr");
    }
    let callbacks = HostCallbacks {
        console_log: Some(Box::new(|text| eprintln!("[js] {text}"))),
        ..HostCallbacks::default()
    };
    context.set_host_callbacks(callbacks);
    // The JIT is the desktop's and the phone's: a wasm sandbox grants no RWX
    // memory, and the engine compiles `install_jit` out without that feature
    // (WASM.md D2).
    #[cfg(not(target_arch = "wasm32"))]
    slag::install_jit(&mut context).unwrap();
    context.install_raylib().unwrap();
    // The touch surface, before the scene is evaluated and before the first frame:
    // the scene's controls are inert without it (`touch.js` asks `typeof android`
    // every frame rather than at load, so the harness can install one later).
    #[cfg(target_os = "android")]
    android::install(&mut context);
    // The browser surface, before the scene is evaluated and before the first frame,
    // exactly as `android` is (WASM.md D1).
    #[cfg(target_arch = "wasm32")]
    web::install(&mut context);
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
    #[cfg(not(target_arch = "wasm32"))]
    for manifest in loader.mods() {
        if let Some(wasm) = manifest.wasm.as_ref() {
            add_plugin(
                &mut context,
                &plugins,
                &manifest.id,
                manifest.side,
                &wasm.bytes,
            );
        }
    }
    call_scene(&mut context, "sceneModFreeze", &[]);
    if !loader.mods().is_empty() {
        eprintln!("[mods] {} discovered", loader.mods().len());
    }
    // The set a joiner has to match, hashes included: a refusal names both ends,
    // and this is the line it is read against. There is no joiner in a browser
    // (WASM.md D4).
    #[cfg(not(target_arch = "wasm32"))]
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
    // state back to the Rust host through this native function. Only a compiled
    // mod has state to apply, so a wasm build registers no seam (WASM.md D4).
    #[cfg(not(target_arch = "wasm32"))]
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
    #[cfg(not(target_arch = "wasm32"))]
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
    // never stalls on input, and a command never waits for a frame. A tab has no
    // stdin -- a command comes from the DOM or the in-game console -- and no
    // threads to spawn one on, so the wasm build keeps the channel and never puts
    // anything in it: the receive side below is then inert without the loop
    // forking (WASM.md D4).
    #[cfg(not(target_arch = "wasm32"))]
    let (lines, pending) = std::sync::mpsc::channel::<String>();
    #[cfg(target_arch = "wasm32")]
    let (_no_stdin, pending) = std::sync::mpsc::channel::<String>();
    #[cfg(not(target_arch = "wasm32"))]
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

    // Which GLSL dialect the scene's shaders have to be in. The engine's raylib
    // build is what decides -- GL 3.3 on the desktop, GLSL ES 3.00 on Android and
    // in the browser, where `crates/goats/Cargo.toml` turns on the `opengl_es_30`
    // feature -- and the scene cannot read that from JS, so the client tells it
    // before the first frame (ANDROID.md D2, WASM.md D5). The desktop dialect is
    // the scene's own default, so only the ES3 targets have anything to say.
    #[cfg(any(target_os = "android", target_arch = "wasm32"))]
    {
        let set_glsl_dialect = scene_function(&context, "setGlslDialect");
        context
            .call(
                &set_glsl_dialect,
                &JsValue::undefined(),
                &[JsValue::boolean(true)],
            )
            .unwrap();
    }

    context.call(&init, &JsValue::undefined(), &[]).unwrap();

    // The network bridge. Both entry points live in the scene (`net.js`); the
    // host only moves lines between the frame loop and the runtime thread. A
    // browser has no transport to bridge to, so the wasm build takes neither the
    // bridge nor the voice service that rides on it (WASM.md D4); `mod_drain` is
    // the scene's own queue and stays.
    let mod_drain = scene_function_if_present(&context, "sceneModDrain");
    #[cfg(not(target_arch = "wasm32"))]
    let net_event = scene_function_if_present(&context, "sceneNetEvent");
    #[cfg(not(target_arch = "wasm32"))]
    let net_drain = scene_function_if_present(&context, "sceneNetDrain");
    // The mods directory travels with the bridge: a refused join may fetch into
    // it and retry, and a join we host may serve it (M18d).
    #[cfg(not(target_arch = "wasm32"))]
    let mut net = net::Net::start(
        world_mods,
        net::Pull {
            mods_dir: mods_dir.clone(),
            always: options.pull,
        },
    );
    #[cfg(not(target_arch = "wasm32"))]
    let mut voice = audio::Voice::start(&mut net);

    // Watched mods whose files changed recently, waiting for the writes to stop.
    #[cfg(not(target_arch = "wasm32"))]
    let mut settling: HashMap<String, Instant> = HashMap::new();

    // One frame, as a closure over everything above. Both targets drive this same
    // body: the desktop from the `while` below, whose blocking wait its stdin
    // reader thread makes meaningful, and the browser from
    // `emscripten_set_main_loop_arg`, where returning is what lets the browser
    // composite and `requestAnimationFrame` becomes the cadence (WASM.md D3).
    // `mut` is the desktop's: it calls the closure in place from the `while`
    // below, where the wasm path moves it into a `Box` instead.
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut step = move || -> bool {
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
        #[cfg(not(target_arch = "wasm32"))]
        if let Some(handler) = &net_event {
            while let Some(line) = net.next_event() {
                // A pull's mods are the one event with host work behind it: they
                // have to be in the scene before the retried join's world is, and
                // that world is what comes next on this same stream.
                if let Some(ids) = net::pulled_ids(&line) {
                    load_pulled(
                        &mut context,
                        &mut loader,
                        &plugins,
                        mods_dir.as_deref(),
                        &ids,
                    );
                }
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
            // The scene asked to stop. The shutdown runs here rather than after
            // the call, so the desktop's `while` and the browser's callback cannot
            // diverge on the way out -- and nothing is moved out of the closure,
            // which is what keeps it callable in a loop (the voice and the net
            // stop when it drops, with `run`).
            context.call(&shutdown, &JsValue::undefined(), &[]).unwrap();
            eprintln!("done");
            return false;
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
        #[cfg(not(target_arch = "wasm32"))]
        if let Some(watcher) = &watcher {
            let now = Instant::now();
            for path in watcher.take_changed() {
                if pulled_archive(&path) {
                    continue;
                }
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
        #[cfg(not(target_arch = "wasm32"))]
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
        #[cfg(not(target_arch = "wasm32"))]
        voice.pump();
        true
    };

    // Hand the frame cadence to whoever owns it (WASM.md D3). The desktop keeps
    // the blocking loop, whose stdin reader thread makes the wait meaningful. The
    // browser owns its own cadence, so the wasm build stores the step and returns
    // -- `web/index.html` calls `goats_frame` back once per `requestAnimationFrame`.
    #[cfg(target_arch = "wasm32")]
    install_step(Box::new(step));

    #[cfg(not(target_arch = "wasm32"))]
    while step() {}
}

/// The browser's frame entry, exported for `web/index.html` to call once per
/// `requestAnimationFrame` (WASM.md D3).
///
/// The state is the step `run()` installed. A wasm build is single-threaded, so a
/// thread-local is the only place it has to live between `run()` returning and
/// this being called. Returns 1 while the scene asks for another frame, 0 once it
/// is done -- `shutdown` has already run inside the step by then.
///
/// The export exists rather than an `emscripten_set_main_loop_arg` callback on
/// purpose: a Rust function pointer handed to Emscripten's main-loop JS came back
/// as a null function in the glue. Driving the loop from the page keeps the whole
/// thing on names, not pointers.
#[cfg(target_arch = "wasm32")]
#[unsafe(no_mangle)]
pub extern "C" fn goats_frame() -> i32 {
    FRAME.with(|slot| {
        let mut slot = slot.borrow_mut();
        match slot.as_mut() {
            Some(step) => i32::from(step()),
            None => 0,
        }
    })
}

#[cfg(target_arch = "wasm32")]
fn install_step(step: Box<dyn FnMut() -> bool>) {
    FRAME.with(|slot| *slot.borrow_mut() = Some(step));
}

#[cfg(target_arch = "wasm32")]
thread_local! {
    static FRAME: std::cell::RefCell<Option<Box<dyn FnMut() -> bool>>> =
        std::cell::RefCell::new(None);
}

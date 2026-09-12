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
//! Run: `cargo run --release`

mod net;

use std::io::{BufRead, Write};

use slag::{Context, HostCallbacks, JsValue};

/// Every asset the scene loads, embedded so the binary is self-contained. The
/// name is exactly the path the scene hands to `rl.loadModel`/`rl.loadSound`/
/// `rl.loadMusic`, and the engine resolves the bytes by that name before
/// falling back to the filesystem. The WAV ambience beds are shipped as Ogg
/// Vorbis: 71 MB of PCM would dwarf the rest of the binary, while the Ogg loops
/// are 3.6 MB for the same 60 s at the same sample rate.
///
/// The headless harness (`tools/goat_logic_test.js`) parses this table and
/// checks every path the scene requests against it, so the two cannot drift
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

/// The scene, joined from `crates/goats/src/game/` in the order listed here.
/// `concat!` needs the parts spelled out, so this list *is* the running order --
/// and it is the
/// single source of truth for it: the headless harness (`tools/goat_logic_test.js`)
/// parses this same list, so the two cannot drift apart.
const SCENE: &str = concat!(
    include_str!("game/core.js"),
    include_str!("game/model.js"),
    include_str!("game/world.js"),
    include_str!("game/lighting.js"),
    include_str!("game/sky.js"),
    include_str!("game/audio.js"),
    include_str!("game/weather.js"),
    include_str!("game/food.js"),
    include_str!("game/bots.js"),
    include_str!("game/goat.js"),
    include_str!("game/ctl.js"),
    include_str!("game/menu.js"),
    include_str!("game/console.js"),
    include_str!("game/net.js"),
);

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

fn main() {
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
    // The scene only defines its frame functions here; the loop below drives it.
    context.eval(SCENE).unwrap();

    let init = scene_function(&context, "sceneInit");
    let frame = scene_function(&context, "sceneFrame");
    let shutdown = scene_function(&context, "sceneShutdown");
    let command = scene_function(&context, "sceneCommand");

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
    let mut net = net::Net::start();

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

        // The scene's queued intents leave on the same boundary.
        if let Some(drain) = &net_drain {
            match context.call(drain, &JsValue::undefined(), &[]) {
                Ok(value) => {
                    if let Some(text) = value.as_string() {
                        for line in text.lines() {
                            if !line.trim().is_empty() {
                                net.send(line);
                            }
                        }
                    }
                }
                Err(error) => eprintln!("[net] sceneNetDrain: {error}"),
            }
        }
    }
    context.call(&shutdown, &JsValue::undefined(), &[]).unwrap();
    eprintln!("done");
}

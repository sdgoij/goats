//! A tiny "GOAT" sandbox written in JavaScript, driven through the `rl` host
//! module's 3D surface.
//!
//! The goat is the animated `.glb` baked from the Blender rig, embedded into
//! the binary so the model needs no files on disk (`rl.loadModel` learns about
//! embedded assets the same way `rl.loadTexture` does). The scene script is
//! split across `src/game/*.js` and concatenated into one script here, so the
//! parts share a single top-level scope.
//!
//! The host owns the frame loop -- the scene exposes `sceneInit`/`sceneFrame`/
//! `sceneShutdown` instead of running itself -- so it can interleave commands
//! read from stdin between frames. Each command line goes to the scene's
//! `sceneCommand` and its response is written to stdout; everything the engine
//! logs goes to stderr, so stdout stays a clean one-line-in, one-line-out
//! command channel.
//!
//! Run: `cargo run --release`

use std::io::{BufRead, Write};

use slag::{Context, HostCallbacks, JsValue};

/// The animated goat (walk / trot / idle clips), baked from the Blender rig.
static GOAT_GLB: &[u8] = include_bytes!("../goat_animated.glb");

/// The scene, joined from `src/game/` in the order listed here. `concat!` needs
/// the parts spelled out, so this list *is* the running order -- and it is the
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
);

/// One of the scene's global functions, resolved by name.
fn scene_function(context: &Context, name: &str) -> JsValue {
    context
        .global()
        .unwrap_or_else(|error| panic!("global object: {error}"))
        .get(name)
        .unwrap_or_else(|error| panic!("scene global {name}: {error}"))
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
    context.register_raylib_asset("goat_animated.glb", GOAT_GLB);
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
        let running = context
            .call(&frame, &JsValue::undefined(), &[])
            .unwrap()
            .as_boolean()
            .unwrap_or(false);
        if !running {
            break;
        }
    }
    context.call(&shutdown, &JsValue::undefined(), &[]).unwrap();
    eprintln!("done");
}

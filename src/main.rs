//! A tiny "GOAT" sandbox written in JavaScript, driven through the `rl` host
//! module's 3D surface.
//!
//! The goat is the animated `.glb` baked from the Blender rig, embedded into
//! the binary so the model needs no files on disk (`rl.loadModel` learns about
//! embedded assets the same way `rl.loadTexture` does). The scene script is
//! split across `src/game/*.js` and concatenated into one script here, so the
//! parts share a single top-level scope.
//!
//! Run: `cargo run --release`

use slag::{Context, HostCallbacks};

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
    include_str!("game/bots.js"),
    include_str!("game/goat.js"),
);

fn main() {
    let mut context = Context::new().unwrap();
    let callbacks = HostCallbacks {
        console_log: Some(Box::new(|text| println!("[js] {text}"))),
        ..HostCallbacks::default()
    };
    context.set_host_callbacks(callbacks);
    slag::install_jit(&mut context).unwrap();
    context.install_raylib().unwrap();
    context.register_raylib_asset("goat_animated.glb", GOAT_GLB);
    context.eval(SCENE).unwrap();
    println!("done");
}

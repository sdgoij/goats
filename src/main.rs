//! A tiny "GOAT" sandbox written in JavaScript, driven through the `rl` host
//! module's 3D surface.
//!
//! The goat is the animated `.glb` baked from the Blender rig, embedded into
//! the binary so the demo needs no files on disk (`rl.loadModel` learns about
//! embedded assets the same way `rl.loadTexture` does).
//!
//! Run: `cargo run --release`

use slag::{Context, HostCallbacks};

/// The animated goat (walk / trot / idle clips), baked from the Blender rig.
static GOAT_GLB: &[u8] = include_bytes!("../goat_animated.glb");

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
    context.eval(include_str!("goat.js")).unwrap();
    println!("done");
}

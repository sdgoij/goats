//! Builds the Raylib client's scene snapshot.
//!
//! The client used to start by evaluating `scene::SCENE`. This script evaluates
//! it once, here, and writes the realm's state to `$OUT_DIR/scene.snapshot`,
//! which `src/lib.rs` embeds and restores at startup -- the shape a Deno binary
//! boots from `SnapshotCreator::create_blob`.
//!
//! What a blob carries is the realm's *state*, not host callbacks: the engine's
//! `write_snapshot` refuses a realm that holds one. The build-time realm
//! therefore has no raylib, no `__flight`, and no `console` or timers -- the
//! last two are installed by `Context::new` as Rust closures and are deleted
//! before the write, and the reading `Context::new` puts its own back. The
//! runtime also installs the real `rl` and `__flight` *before* restoring, so
//! every function the blob carries resolves those names against the host that
//! is actually running.
//!
//! The stub `rl` in `scene::SNAPSHOT_RL` is only what the scene's top level
//! reads while it runs (`rl.color`, `rl.KEY_GRAVE`, `typeof rl.makeModel`). It
//! is deleted before the write, so it can never shadow the real module, and a
//! top-level read it does not cover fails the build here rather than surfacing
//! as a wrong constant at play time.
//!
//! A blob records the pointer width and byte order it was written with, and the
//! reader refuses any other. Only a 64-bit little-endian target gets one; a
//! 32-bit target (the browser client) evaluates the joined source at startup,
//! exactly as before.

use std::path::PathBuf;

fn main() {
    // The snapshot is the scene, so a part or the stub changing has to rebuild
    // it. `scene::PARTS` is the running order `crates/scene` owns; listing it
    // here means a part added to that list and not to the directory is still
    // picked up.
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../scene/src/lib.rs");
    println!("cargo:rerun-if-changed=../scene/src/snapshot_rl.js");
    for part in scene::PARTS {
        println!("cargo:rerun-if-changed=../scene/src/{part}");
    }
    println!("cargo:rustc-check-cfg=cfg(goats_scene_snapshot)");

    let width = std::env::var("CARGO_CFG_TARGET_POINTER_WIDTH").unwrap_or_default();
    let endian = std::env::var("CARGO_CFG_TARGET_ENDIAN").unwrap_or_default();
    if width != "64" || endian != "little" {
        return;
    }

    let blob = snapshot().unwrap_or_else(|error| panic!("goats: scene snapshot: {error}"));
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("scene.snapshot");
    std::fs::write(&out, blob).expect("goats: write scene.snapshot");
    println!("cargo:rustc-cfg=goats_scene_snapshot");
}

/// Evaluate the scene and write the realm the client restores.
///
/// The blob is read back in a fresh context before it is handed to the compiler:
/// a snapshot that does not restore, or that brought the stub `rl` with it,
/// fails the build rather than a launch.
fn snapshot() -> Result<Vec<u8>, String> {
    let mut writer = slag::Context::new().map_err(|error| error.to_string())?;
    // `Context::new` installs `console` and the timers as host callbacks. A
    // blob cannot carry one, and the reading `Context::new` installs its own,
    // so they go before the scene is evaluated.
    writer
        .eval(DELETE_HOSTS)
        .map_err(|error| error.to_string())?;
    writer
        .eval(scene::SNAPSHOT_RL)
        .map_err(|error| format!("the snapshot `rl` stub: {error}"))?;
    writer
        .eval(scene::SCENE)
        .map_err(|error| format!("the scene: {error}"))?;
    // The stub has done its work. Leaving it in the blob would define `rl` on
    // the reading realm's global *after* the real module was installed, which
    // would quietly hand the scene a throwaway colour helper for a renderer.
    writer
        .eval("delete globalThis.rl;")
        .map_err(|error| format!("removing the snapshot `rl` stub: {error}"))?;
    let blob = writer.write_snapshot()?;

    let mut reader = slag::Context::new().map_err(|error| error.to_string())?;
    reader.read_snapshot(&blob)?;
    let ok = reader
        .eval(
            "typeof sceneInit === 'function' && typeof sceneFrame === 'function' \
             && typeof rl === 'undefined'",
        )
        .map_err(|error| error.to_string())?;
    if ok.as_boolean() != Some(true) {
        return Err(
            "the restored realm is missing the scene's frame functions, or kept the `rl` stub"
                .into(),
        );
    }
    Ok(blob)
}

/// The host-callback globals the engine's `Context::new` installs. The scene's
/// top level does not log or schedule anything, so they are deleted rather than
/// stubbed: one that is used anyway fails the build with a `ReferenceError`.
const DELETE_HOSTS: &str = "\
    delete globalThis.console; \
    delete globalThis.setTimeout; delete globalThis.setInterval; \
    delete globalThis.clearTimeout; delete globalThis.clearInterval;";

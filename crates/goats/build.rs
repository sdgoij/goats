//! Writes the Raylib client's scene snapshot.
//!
//! The evaluation itself lives in `scene-snapshot`, which is a build
//! dependency: see that crate for why it is not done here (in short, a
//! build-dependency named `slag` would pick up this crate's
//! `gpu-skinning = ["slag/gpu-skinning"]` edge and build a desktop raylib in a
//! host build, which is what broke the web build). This script only decides
//! whether this target can carry a blob, writes it, and tells `src/lib.rs` to
//! embed it.
//!
//! A blob records the pointer width and byte order it was written with, and the
//! reader refuses any other. Only a 64-bit little-endian target gets one; a
//! 32-bit target (the browser client) evaluates the joined source at startup,
//! exactly as before.

use std::path::PathBuf;

fn main() {
    // The snapshot is the scene, so a part or the stub changing has to rebuild
    // it. `PARTS` is the running order `crates/scene` owns; listing it here
    // means a part added to that list and not to the directory is still picked
    // up.
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../scene/src/lib.rs");
    println!("cargo:rerun-if-changed=../scene/src/snapshot_rl.js");
    for part in scene_snapshot::PARTS {
        println!("cargo:rerun-if-changed=../scene/src/{part}");
    }
    println!("cargo:rustc-check-cfg=cfg(goats_scene_snapshot)");

    let width = std::env::var("CARGO_CFG_TARGET_POINTER_WIDTH").unwrap_or_default();
    let endian = std::env::var("CARGO_CFG_TARGET_ENDIAN").unwrap_or_default();
    if width != "64" || endian != "little" {
        return;
    }

    let blob =
        scene_snapshot::build().unwrap_or_else(|error| panic!("goats: scene snapshot: {error}"));
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("scene.snapshot");
    std::fs::write(&out, blob).expect("goats: write scene.snapshot");
    println!("cargo:rustc-cfg=goats_scene_snapshot");
}

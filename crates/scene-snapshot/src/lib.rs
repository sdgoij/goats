//! The scene snapshot the Raylib client boots from, evaluated at build time.
//!
//! [`build`] is what `crates/goats/build.rs` calls: it evaluates `scene::SCENE`
//! once, here, and answers the realm as a blob, which the client embeds and
//! restores at startup -- the shape a Deno binary boots from
//! (`SnapshotCreator::create_blob`).
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
//! top-level read it does not cover fails the client's build here rather than
//! surfacing as a wrong constant at play time.
//!
//! This crate exists, rather than the evaluation living in `crates/goats`'s own
//! build script, because a build script's dependencies are host binaries and
//! Cargo's `dep/feature` syntax names a dependency regardless of kind. With
//! `slag` as the client's build-dependency, the client's
//! `gpu-skinning = ["slag/gpu-skinning"]` edge would reach it too, and the
//! snapshot writer would build a *desktop* raylib -- which is what broke the
//! web build on a runner without wayland-scanner. The client's build script
//! depends on this crate instead, and this crate's `slag` has no features of
//! its own.

use slag::Context;

/// The scene parts, in the order [`scene::SCENE`] joins them. Re-exported so
/// the client's build script can list them for `cargo:rerun-if-changed`.
pub use scene::PARTS;

/// Evaluate the scene and answer the realm as a snapshot blob.
///
/// The blob is read back in a fresh context before it is handed over: one that
/// does not restore, or that brought the stub `rl` with it, is an error rather
/// than a launch that fails later.
pub fn build() -> Result<Vec<u8>, String> {
    let mut writer = Context::new().map_err(|error| error.to_string())?;
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

    let mut reader = Context::new().map_err(|error| error.to_string())?;
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

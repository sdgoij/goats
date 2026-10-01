//! The browser's surface (WASM.md D1), installed as the `web` global.
//!
//! W0's is the minimum that is honest to install: an empty object, so the scene
//! can branch on `typeof web === "object"` and size its window like an embedded
//! video rather than a desktop window. The real surface -- the console text
//! bridge, the audio-unlock gesture, fullscreen -- fills this object in with W2.

use slag::Context;

pub fn install(context: &mut Context) {
    let surface = context.create_object().expect("the web object");
    context
        .set_global("web", surface.as_value())
        .expect("the web global");
}

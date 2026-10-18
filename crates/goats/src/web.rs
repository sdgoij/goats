//! The browser surface: the one global a scene branches on to know it is in a
//! page (`WASM.md` W0).
//!
//! W0's is the minimum that is honest to install: an empty object, so the scene
//! can branch on `typeof web === "object"` and size its window like an embedded
//! video rather than a desktop window. The real surface -- the console text
//! bridge, the audio-unlock gesture, fullscreen -- fills this object in with W2.
//!
//! `embedded` is the one property that says the page owns the frame: the shell
//! (`godot/web/index.html`) shows the client in a 16:9 stage, so the scene must
//! not open the tab fullscreen on boot. The player can still ask for it with F11
//! or the menu.
//!
//! `width` and `height` are the pixel size the page hands over when it owns the
//! size. The page cannot hand them over through `globalThis`: the game script
//! runs in the engine's own JavaScript context, where the page's `Module` is not
//! visible, so `web/index.html` names the size on the command line instead
//! (`--viewport WxH`, which Emscripten builds from `Module.arguments`). Without
//! it -- a standalone tab -- the client keeps the video-sized column it has
//! always had.

use slag::{Context, JsValue};

/// The reference client's standalone browser column, and the fallback when the
/// page does not name a size.
const DEFAULT_WIDTH: f64 = 854.0;
const DEFAULT_HEIGHT: f64 = 480.0;

/// Install the surface. `viewport` is the page's size in CSS pixels, when it
/// named one (`--viewport`).
pub fn install(context: &mut Context, viewport: Option<(f64, f64)>) {
    let surface = context.create_object().expect("the web object");
    let (width, height) = viewport.unwrap_or((DEFAULT_WIDTH, DEFAULT_HEIGHT));
    let _ = surface.set("embedded", JsValue::boolean(true));
    let _ = surface.set("width", JsValue::number(width));
    let _ = surface.set("height", JsValue::number(height));
    context
        .set_global("web", surface.as_value())
        .expect("the web global");
}

//! The desktop client: the binary, and nothing else.
//!
//! Everything lives in the library (`src/lib.rs`) so that the Android `cdylib`
//! (`crates/android`) reaches the same entry point. On Android there is no
//! `argv` and no stdin, so what this file would parse and drive does not exist
//! there -- see `ANDROID.md`.
//!
//! The browser's entry is this binary too (WASM.md D7): Emscripten calls the
//! program's `main` directly, so no `cdylib` is needed.
//!
//! The one browser need that Rust cannot supply lives in the fork's raylib:
//! `WindowShouldClose`'s unconditional `emscripten_sleep` is guarded there, so a
//! main-loop build does not abort in it (WASM.md D3). Defining that symbol away
//! from here was tried and is wrong -- it collides with Emscripten's own runtime,
//! which dereferences it as a null function the moment the main loop is set up.

fn main() {
    goats::run();
}

// The browser's frame entry lives in the library (`goats::goats_frame`) and is
// exported for `web/index.html` to call on `requestAnimationFrame` (WASM.md D3).
// Nothing in Rust calls it, so this reference is what keeps the linker from
// dropping the symbol as dead before the page ever asks for it.
#[cfg(target_arch = "wasm32")]
#[used]
static KEEP_GOATS_FRAME: extern "C" fn() -> i32 = goats::goats_frame;

//! The Rust-side plugin host (M17b): instantiate and drive a compiled mod's
//! `.wasm` module from Rust through the engine's `Store`, with no JavaScript in
//! front of the plugin. Implementation lands after the workspace dependency
//! refactor.

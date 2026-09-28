//! The desktop client: the binary, and nothing else.
//!
//! Everything lives in the library (`src/lib.rs`) so that the Android `cdylib`
//! (`crates/android`) reaches the same entry point. On Android there is no
//! `argv` and no stdin, so what this file would parse and drive does not exist
//! there -- see `ANDROID.md`.

fn main() {
    goats::run();
}

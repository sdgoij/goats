//! The link arguments the Android `.so` needs that a manifest cannot express.
//!
//! raylib's Android backend compiles `android_native_app_glue` into
//! `libraylib.a`, and `ANativeActivity_onCreate` is the symbol the platform's
//! `NativeActivity` looks up with `dlsym`. Three things have to line up for that
//! to work, and each one was a separate failure:
//!
//! 1. Nothing in this crate references the glue, so the linker drops the archive
//!    member -- and with it `android_main`, and with that the C-ABI `main` in
//!    `src/lib.rs`. `-u` forces the member in. (`llvm-nm` then shows `T
//!    ANativeActivity_onCreate` inside `libraylib.a`.)
//!
//! 2. rustc links a `cdylib` through a version script that localizes everything
//!    but the crate's own exported symbols, so the glue arrives as a *local*
//!    symbol -- `llvm-nm` on the finished `.so` shows `t`, and the dynamic table
//!    holds only three entries. `dlsym` searches the dynamic table, so the app
//!    would link and then fail to start, with nothing on stderr.
//!
//! 3. Neither `-Wl,--export-dynamic-symbol=...` nor `-Wl,--export-dynamic`
//!    undoes that: a version script's `local:` pattern is not overridden by
//!    them. A version script of our own, passed last so it is the one that
//!    applies, is what promotes the name.

fn main() {
    let is_android = std::env::var("CARGO_CFG_TARGET_OS")
        .map(|os| os == "android")
        .unwrap_or(false);

    if !is_android {
        return;
    }

    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR is set for a build script");
    let script = std::path::Path::new(&out_dir).join("android-entry.ver");
    std::fs::write(
        &script,
        "{\n  global:\n    ANativeActivity_onCreate;\n    main;\n};\n",
    )
    .expect("write the version script");

    println!("cargo:rustc-link-arg=-uANativeActivity_onCreate");
    println!(
        "cargo:rustc-link-arg=-Wl,--version-script={}",
        script.display().to_string().replace('\\', "/")
    );
}

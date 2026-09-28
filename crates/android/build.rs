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
//!
//! `JNI_OnLoad` is deliberately not one of ours. Two JNI entry points are found by
//! *name* instead (`Java_dev_sdgoij_goats_GoatsActivity_nativeInit` and
//! `..._nativeText`), because registering them from `JNI_OnLoad` needs
//! `FindClass`, and `NativeActivity` loads this library with `System.load` -- the
//! calling class is the framework's, so its loader is the boot one and the app's
//! own class cannot be found through it. The by-name path resolves through the
//! activity's class later, where the loader is never in question, and it is still a
//! *name* the version script has to promote.

fn main() {
    let is_android = std::env::var("CARGO_CFG_TARGET_OS")
        .map(|os| os == "android")
        .unwrap_or(false);

    if !is_android {
        return;
    }

    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR is set for a build script");
    let script = std::path::Path::new(&out_dir).join("android-entry.ver");
    // `-u` for each, besides the script: nothing in Rust references a symbol only
    // the Java VM looks up, so `--gc-sections` would discard it before the script
    // could promote it.
    let entries = [
        "ANativeActivity_onCreate",
        "Java_dev_sdgoij_goats_GoatsActivity_nativeInit",
        "Java_dev_sdgoij_goats_GoatsActivity_nativeText",
        "main",
    ];
    let mut contents = String::from("{\n  global:\n");
    for entry in entries {
        contents.push_str(&format!("    {entry};\n"));
        println!("cargo:rustc-link-arg=-u{entry}");
    }
    contents.push_str("};\n");
    std::fs::write(&script, contents).expect("write the version script");

    println!(
        "cargo:rustc-link-arg=-Wl,--version-script={}",
        script.display().to_string().replace('\\', "/")
    );
}

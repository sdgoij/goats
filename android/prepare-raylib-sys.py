#!/usr/bin/env python3
"""Materialise the patched `raylib-sys` the Android build needs, inside the repo.

Usage: prepare-raylib-sys.py

`Cargo.toml` patches `raylib-sys` to `android/build/raylib-sys`, so that path has
to exist before cargo can resolve anything -- including a plain desktop
`cargo build`. This script creates it: a pristine copy of the published crate,
straight from the cargo registry, with our Android repairs applied. Nothing is
read from outside the project except the dependency cache every Rust build
already uses, and `android/build/` is gitignored, so the copy is a build product
rather than something to review.

Android-only. Four are on the crate's build path:

1. The API level is read from the last dash-component of the target triple, which
   a modern `aarch64-linux-android` does not have, so `ANDROID_PLATFORM` became
   the literal string `android` -- and the NDK concatenated that into the LLVM
   triple (`aarch64-none-linux-androidandroid`), losing the sysroot. Not a
   warning: a hard configure failure (`crtbegin_dynamic.o` not found).
2. cmake-rs copies the `cc`-detected compiler's args into `CMAKE_C_FLAGS`, and
   `cc` guesses a bare `--target=aarch64-linux-android`. That lands after the
   toolchain's API-qualified flag and therefore wins.
3. raylib's top-level CMake raises `FATAL_ERROR "Cannot disable both Wayland and
   X11"` for any UNIX-ish platform but DRM/Web. CMake counts Android as UNIX, and
   the crate forced both GLFW backends off for Android, so nothing configured.
4. `is_android` was `cfg!(target_os = "android")`, which in a build script is the
   *host's* OS -- so every Android-specific decision was dead when
   cross-compiling, including an X11 link that fired on a Linux host and would
   have put `-lX11` into the `.so` on CI.

More are in raylib's Android platform layer:
5. `SetupFramebuffer` letterboxes a request smaller than the display. That is a
   desktop idea: on Android the window *is* the panel, so the client's 1000x640
   desktop window became a 640px strip of a 1080px-tall screen (`renderOffset`
   376,0) and, against the portrait panel read at init, a strip in the bottom
   third (0,1510).
6. `APP_CMD_CONFIG_CHANGED` was an empty stub whose comment said "Check screen
   orientation here!". Android rotates an activity only after its native window
   exists, so the rotation that follows `InitPlatform` was never noticed.
7. The phone's back button is reported as `KEY_ESCAPE` rather than raylib's own
   `KEY_BACK`, which the engine does not export and the scene therefore cannot
   read -- and with no escape key on a phone, the console, once open, had no way
   out. The event is still eaten, so the OS never finishes the activity.

The GLFW-symbol note lives in the client (`crates/android`), not here, and all of
this is in that platform file or the crate's build path, so the desktop build is
untouched.
"""

import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEST = os.path.join(HERE, "build", "raylib-sys")

# ---------------------------------------------------------------------------
# build.rs

PARSE_OLD = """            let android_platform = target.split("-").last().expect("fail to parse the android version of the target triple, example:'aarch64-linux-android25'");
            let abi_version = android_platform
                .split("-")
                .last()
                .expect("Could not get abi version. Is ANDROID_PLATFORM valid?");
"""

PARSE_NEW = """            // The API level is the number the NDK bakes into the LLVM triple and
            // the sysroot path. Take it, in order of authority, from
            // ANDROID_PLATFORM (what `cargo ndk -P` and CI set), then from the
            // triple's own suffix (`aarch64-linux-android25`), then from a floor
            // -- never from a bare `android`, which the toolchain appends to
            // `aarch64-none-linux-android` and breaks the sysroot lookup with
            // (`aarch64-none-linux-androidandroid`, no crtbegin_dynamic.o).
            let api_level = env::var("ANDROID_PLATFORM")
                .ok()
                .map(|platform| platform.trim_start_matches("android-").to_string())
                .filter(|platform| !platform.is_empty())
                .or_else(|| {
                    target
                        .split('-')
                        .last()
                        .and_then(|last| last.strip_prefix("android"))
                        .filter(|level| !level.is_empty())
                        .map(str::to_string)
                })
                .unwrap_or_else(|| "24".to_string());
            let android_platform = format!("android-{api_level}");
            let abi_version = api_level;
"""

CFLAGS_OLD = """                .define("ANDROID_PLATFORM", android_platform)
                .define("CMAKE_TOOLCHAIN_FILE", &toolchain_file)
"""

CFLAGS_NEW = """                .define("ANDROID_PLATFORM", android_platform)
                // cmake-rs copies the `cc`-detected compiler's args into
                // CMAKE_C_FLAGS, and `cc` guesses a bare
                // `--target=aarch64-linux-android` for android triples. That
                // lands *after* the toolchain's own
                // `--target=aarch64-none-linux-android24` and therefore wins, so
                // clang looks for the crt objects in the unqualified sysroot dir
                // and the C-compiler test fails with "cannot open
                // crtbegin_dynamic.o". Defining the flag variables (to nothing)
                // stops cmake-rs from injecting them and leaves the toolchain's
                // API-qualified flags in charge.
                .define("CMAKE_C_FLAGS", "")
                .define("CMAKE_CXX_FLAGS", "")
                .define("CMAKE_ASM_FLAGS", "")
                .define("CMAKE_TOOLCHAIN_FILE", &toolchain_file)
"""

X11_OLD = """            // X11 linking
            #[cfg(not(any(feature = "wayland", target_os = "android", feature = "drm")))]
            {
                println!("cargo:rustc-link-search=/usr/local/lib");
                println!("cargo:rustc-link-lib=X11");
            }
"""

X11_NEW = """            // X11 linking. Gated on the runtime `platform` rather than on
            // `cfg!(target_os = "android")`: that cfg is the *host*'s OS in a
            // build script, so on a Linux host targeting Android it is false and
            // this links X11 into the Android .so.
            #[cfg(not(any(feature = "wayland", feature = "drm")))]
            if platform != Platform::Android {
                println!("cargo:rustc-link-search=/usr/local/lib");
                println!("cargo:rustc-link-lib=X11");
            }
"""

IS_ANDROID_OLD = """    let is_android = cfg!(target_os = "android"); // skip linking to x11 & wayland
"""

IS_ANDROID_NEW = """    // NOTE: `cfg!(target_os = ...)` is the *host* here, because a build script is
    // compiled for the host -- so every Android-specific decision below was
    // silently dead. Take the target from cargo instead.
    let is_android = env::var("CARGO_CFG_TARGET_OS")
        .map(|os| os == "android")
        .unwrap_or(false);
"""

GLFW_GUARD_OLD = """    let force_x11 = cfg!(feature = "software_renderer");
    cmake.define("GLFW_BUILD_WAYLAND", bstr(cfg!(feature = "GLFW_BUILD_WAYLAND") && !is_android));
    cmake.define(
        "GLFW_BUILD_X11",
        bstr((cfg!(feature = "GLFW_BUILD_X11") || force_x11) && !is_android),
    );
"""

GLFW_GUARD_NEW = """    //
    // Android is the same shape and the same fix: CMake counts it as UNIX and its
    // PLATFORM matches neither DRM nor Web, so the guard fires, while GLFW is never
    // compiled for Android at all (rglfw.c is desktop-only). Note that the `&& !is_android`
    // below is what used to force both backends off on Android, i.e. what tripped the
    // guard in the first place.
    let force_x11 = cfg!(feature = "software_renderer") || is_android;
    cmake.define("GLFW_BUILD_WAYLAND", bstr(cfg!(feature = "GLFW_BUILD_WAYLAND") && !is_android));
    cmake.define(
        "GLFW_BUILD_X11",
        bstr(cfg!(feature = "GLFW_BUILD_X11") || force_x11),
    );
"""

GLDISPATCH_OLD = """        #[cfg(feature = "opengl_es_30")]
        {
            builder.define("OPENGL_VERSION", "ES 3.0");
            println!("cargo:rustc-link-lib=GLESv2");
            println!("cargo:rustc-link-lib=GLdispatch");
        }
"""

GLDISPATCH_NEW = """        #[cfg(feature = "opengl_es_30")]
        {
            builder.define("OPENGL_VERSION", "ES 3.0");
            println!("cargo:rustc-link-lib=GLESv2");

            // GLdispatch is a GLVND library, which is desktop Linux only.
            // Android has no such thing: its ES 2.0 *and* ES 3.x entry points
            // live in libGLESv2.so, which the Android arm of `link()` asks for
            // by itself. Emitting this unconditionally made the feature unusable
            // for the one platform it was wanted on.
            if env::var("CARGO_CFG_TARGET_OS").map(|os| os != "android").unwrap_or(true) {
                println!("cargo:rustc-link-lib=GLdispatch");
            }
        }
"""

# ---------------------------------------------------------------------------
# platforms/rcore_android.c

CONTEXT_OLD = """    const EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
"""

CONTEXT_NEW = """    const EGLint contextAttribs[] = {
        // Match the config chosen just above. On an ES3 build that asks for
        // EGL_OPENGL_ES3_BIT, and a client version of 2 alongside it yields an
        // ES 2.0 context: raylib's own #version 300 es shaders happen to be
        // accepted anyway (this driver is lenient about that), but ES3-only
        // entry points are not guaranteed -- core VAOs, glVertexAttribDivisor,
        // glDrawArraysInstanced -- and rlgl's ES3 path calls them.
        EGL_CONTEXT_CLIENT_VERSION, (rlGetVersion() == RL_OPENGL_ES_30) ? 3 : 2,
        EGL_NONE
    };
"""

PANEL_OLD = """        if ((CORE.Window.screen.width == 0) || (CORE.Window.screen.height == 0))
        {
            CORE.Window.screen.width = CORE.Window.display.width;
            CORE.Window.screen.height = CORE.Window.display.height;
        }
"""

PANEL_NEW = """        // (Android) The window *is* the panel, so a request smaller than the display
        // is not a request for a letterboxed window. raylib's border-bar maths below
        // would otherwise pin the client's 1000x640 desktop window size to a 640px
        // strip of a 1080px-tall screen, with renderOffset left holding the rest.
        //
        // This is the `== 0` case that used to live here, widened: on Android there
        // is exactly one window and it is the display, which is also what a caller
        // asking for 0 was asking for.
        CORE.Window.screen.width = CORE.Window.display.width;
        CORE.Window.screen.height = CORE.Window.display.height;
"""

CONFIG_OLD = """        case APP_CMD_CONFIG_CHANGED:
        {
            //AConfiguration_fromAssetManager(platform.app->config, platform.app->activity->assetManager);
            //print_cur_config(platform.app);

            // Check screen orientation here!
        } break;
"""

CONFIG_NEW = """        case APP_CMD_CONFIG_CHANGED:
        {
            //AConfiguration_fromAssetManager(platform.app->config, platform.app->activity->assetManager);
            //print_cur_config(platform.app);

            // This is where raylib's own TODO said "Check screen orientation here!",
            // and it is where a phone's rotation lands: the manifest asks for
            // landscape, but the surface exists in portrait first, so InitPlatform
            // reads that portrait size and the rotation happens afterwards with
            // nothing to notice it.
            //
            // The framebuffer then keeps the pre-rotation aspect. A 1000x640
            // request against the 1080x2322 panel this was found on computes
            // renderOffset.y = 1510, so the scene is a letterboxed strip low on the
            // screen and its render buffer is the wrong size too.
            //
            // On Android the window *is* the screen, so the panel's size is the
            // answer. Only the size state is touched: re-running
            // InitGraphicsDevice() here would recreate the EGL surface and
            // invalidate every shader and texture the scene has loaded.
            if (platform.app->window != NULL)
            {
                int width = ANativeWindow_getWidth(platform.app->window);
                int height = ANativeWindow_getHeight(platform.app->window);

                if ((width > 0) && (height > 0) &&
                    ((width != CORE.Window.display.width) || (height != CORE.Window.display.height)))
                {
                    EGLint displayFormat = 0;
                    eglGetConfigAttrib(platform.device, platform.config, EGL_NATIVE_VISUAL_ID, &displayFormat);

                    CORE.Window.display.width = width;
                    CORE.Window.display.height = height;
                    CORE.Window.screen.width = width;
                    CORE.Window.screen.height = height;

                    SetupFramebuffer(CORE.Window.display.width, CORE.Window.display.height);

                    CORE.Window.render.width = CORE.Window.screen.width;
                    CORE.Window.render.height = CORE.Window.screen.height;
                    CORE.Window.currentFbo.width = CORE.Window.render.width;
                    CORE.Window.currentFbo.height = CORE.Window.render.height;

                    ANativeWindow_setBuffersGeometry(platform.app->window, CORE.Window.render.width, CORE.Window.render.height, displayFormat);

                    TRACELOG(LOG_INFO, "DISPLAY: Panel resized to %ix%i", CORE.Window.display.width, CORE.Window.display.height);
                }
            }
        } break;
"""

BACKKEY_OLD = """    KEY_BACK,           // AKEYCODE_BACK
"""

BACKKEY_NEW = """    // (Android) The phone's back button *is* the desk's escape. raylib maps it to
    // its own KEY_BACK and eats the event so the OS never finishes the activity --
    // but KEY_BACK is not one of the key names the engine exports to the scene, so
    // the scene cannot read it, and a phone has no escape key. The console, once
    // open, had no way to close. Reporting back as KEY_ESCAPE reaches the escape
    // handling the scene already has (`console.js`, `goat.js`).
    KEY_ESCAPE,         // AKEYCODE_BACK
"""

# (name, file, old, new, marker that proves it is already applied)
PATCHES = [
    ("read the API level from the environment or the triple", "build.rs", PARSE_OLD, PARSE_NEW, "let api_level = env::var(\"ANDROID_PLATFORM\")"),
    ("stop cmake-rs injecting a bare --target", "build.rs", CFLAGS_OLD, CFLAGS_NEW, ".define(\"CMAKE_ASM_FLAGS\", \"\")"),
    ("keep X11 out of an Android link", "build.rs", X11_OLD, X11_NEW, "if platform != Platform::Android {"),
    ("take the target OS from cargo, not the host", "build.rs", IS_ANDROID_OLD, IS_ANDROID_NEW, "env::var(\"CARGO_CFG_TARGET_OS\")"),
    ("satisfy raylib's Wayland/X11 guard on Android", "build.rs", GLFW_GUARD_OLD, GLFW_GUARD_NEW, "cfg!(feature = \"software_renderer\") || is_android"),
    ("keep the desktop GLVND library off an Android link", "build.rs", GLDISPATCH_OLD, GLDISPATCH_NEW, "GLdispatch is a GLVND library"),
    ("fill the panel instead of letterboxing", "raylib/src/platforms/rcore_android.c", PANEL_OLD, PANEL_NEW, "The window *is* the panel, so a request smaller than the display"),
    ("ask for an ES3 context when the build is ES3", "raylib/src/platforms/rcore_android.c", CONTEXT_OLD, CONTEXT_NEW, "(rlGetVersion() == RL_OPENGL_ES_30) ? 3 : 2"),
    ("notice the rotation in APP_CMD_CONFIG_CHANGED", "raylib/src/platforms/rcore_android.c", CONFIG_OLD, CONFIG_NEW, "Panel resized to %ix%i"),
    ("report the phone's back button as escape", "raylib/src/platforms/rcore_android.c", BACKKEY_OLD, BACKKEY_NEW, "The phone's back button *is* the desk's escape"),
]


def registry_source() -> str | None:
    cargo_home = os.environ.get("CARGO_HOME") or os.path.join(os.path.expanduser("~"), ".cargo")
    found = sorted(glob.glob(os.path.join(cargo_home, "registry", "src", "*", "raylib-sys-*")))
    return found[-1] if found else None


def apply_patches(root: str) -> None:
    for name, relative, old_text, new_text, marker in PATCHES:
        path = os.path.join(root, relative)
        with open(path, "rb") as handle:
            data = handle.read()

        newline = b"\r\n" if b"\r\n" in data else b"\n"
        old = old_text.replace("\n", newline.decode()).encode()
        new = new_text.replace("\n", newline.decode()).encode()

        if marker.encode() in data:
            print(f"  already applied: {name}")
            continue

        found = data.count(old)
        if found != 1:
            raise SystemExit(f"  FAILED: {name} (pattern matched {found} times in {relative})")

        with open(path, "wb") as handle:
            handle.write(data.replace(old, new))
        print(f"  applied: {name}")


def main() -> int:
    if os.path.isdir(DEST):
        print(f"{DEST} is already there; patching in place")
    else:
        source = registry_source()
        if source is None:
            print("no raylib-sys in the cargo registry; fetching it")
            subprocess.run(["cargo", "fetch"], cwd=ROOT, check=True)
            source = registry_source()
        if source is None:
            raise SystemExit("still no raylib-sys source. Run `cargo fetch` in the workspace first.")

        print(f"copying {source}\n     to {DEST}")
        shutil.copytree(
            source,
            DEST,
            ignore=shutil.ignore_patterns(
                # Registry bookkeeping and a library's lock file: none of it means
                # anything to a path dependency, and none of it should show up in
                # a diff against the published crate.
                ".git",
                ".cargo-checksum.json",
                ".cargo-ok",
                ".cargo_vcs_info.json",
                "Cargo.lock",
            ),
        )

    apply_patches(DEST)
    print(f"raylib-sys is prepared at {DEST}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

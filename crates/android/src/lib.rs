//! The Android entry point.
//!
//! raylib's Android backend defines `android_main` and calls
//! `extern int main(int, char**)` (`rcore_android.c:322`); this is that symbol.
//! `ANativeActivity_onCreate` -- what the platform really starts -- is forced in
//! by `build.rs`, which is what pulls the glue that calls `android_main` out of
//! `libraylib.a`.
//!
//! `argc`/`argv` are ignored deliberately: Android passes neither, and the
//! client reads its options from `std::env::args()` and its commands from stdin,
//! both of which are empty there. Giving the platform's own surface -- touch,
//! the JNI `Context` that names the mods directory, keyboard, insets -- its
//! globals is the rest of P0/P1 in `ANDROID.md`.

#[cfg(target_os = "android")]
use core::ffi::c_void;
use core::ffi::{c_char, c_int};

#[unsafe(no_mangle)]
pub extern "C" fn main(_argc: c_int, _argv: *mut *mut c_char) -> c_int {
    #[cfg(target_os = "android")]
    stdio_to_logcat::redirect();
    goats::run();
    0
}

// ---------------------------------------------------------------------------
// stdout/stderr -> logcat.
//
// An app process's fds 1 and 2 point at /dev/null, so every line the client
// writes is discarded -- including the scene's `[js]` diagnostics, which are
// P0's entire result (`ANDROID.md`: "the shaders fail, and `[js]` on stderr
// lists exactly which ones"). raylib's own TRACELOG reaches logcat by itself
// (`rcore.c:1897`, tag `raylib`); ours had nowhere to go.
//
// `log.redirect-stdio` would do this from outside, but it has to be set before
// the zygote forks the process and is not settable on a stock device. So the two
// descriptors are re-pointed at a pipe, and a thread pumps it into logcat.

#[cfg(target_os = "android")]
mod stdio_to_logcat {
    use core::ffi::{c_char, c_int};
    use std::ffi::{CStr, CString};
    use std::io::{BufRead, BufReader};
    use std::os::fd::FromRawFd;

    unsafe extern "C" {
        fn __android_log_write(prio: c_int, tag: *const c_char, text: *const c_char) -> c_int;
    }

    /// `ANDROID_LOG_INFO` from `<android/log.h>`.
    const INFO: c_int = 4;

    /// The tag every line from the client gets in logcat. Distinctive on
    /// purpose: `goats` also appears in a few hundred system lines per minute.
    const TAG: &CStr = c"goats-client";

    pub fn redirect() {
        for fd in [1, 2] {
            let mut ends = [0 as c_int; 2];
            // SAFETY: `ends` is two ints, which is exactly what `pipe` writes.
            if unsafe { libc::pipe(ends.as_mut_ptr()) } != 0 {
                continue;
            }
            let (read, write) = (ends[0], ends[1]);
            // SAFETY: both descriptors are ours, and `dup2` is the whole point:
            // it makes `fd` refer to the pipe's write end. The original
            // `/dev/null` is closed for us by `dup2`.
            if unsafe { libc::dup2(write, fd) } < 0 {
                unsafe {
                    libc::close(read);
                    libc::close(write);
                }
                continue;
            }
            unsafe { libc::close(write) };

            std::thread::spawn(move || {
                // SAFETY: this is the pipe's read end and nothing else owns it;
                // taking it into a `File` is just how Rust reads a descriptor.
                let file = unsafe { std::fs::File::from_raw_fd(read) };
                for line in BufReader::new(file).lines() {
                    let Ok(line) = line else { break };
                    let Ok(text) = CString::new(line) else {
                        continue;
                    };
                    // SAFETY: both are NUL-terminated and outlive the call.
                    unsafe { __android_log_write(INFO, TAG.as_ptr(), text.as_ptr()) };
                }
                // If this ever returns, writes to fd 1/2 block once the pipe
                // buffer fills, and the game hangs rather than dying loudly.
                // That is a fair trade for a debug surface, but it is why the
                // loop only exits on an I/O error.
            });
        }
    }
}

// ---------------------------------------------------------------------------
// A shim for two GLFW symbols the *engine* reaches for.
/// Never called: no `JNI_OnUnload` is registered, and the VM only calls this one
/// if it exists, so it exists to say so.
///
/// # Safety
///
/// As above.
#[unsafe(no_mangle)]
#[cfg(target_os = "android")]
pub unsafe extern "C" fn JNI_OnUnload(_vm: *mut c_void, _reserved: *mut c_void) {}

// ---------------------------------------------------------------------------
// A shim for two GLFW symbols the *engine* reaches for.
//
// `window_content_scale()` in slag (`crates/runtime/src/raylib.rs`) declares and
// calls `glfwGetCurrentContext`/`glfwGetWindowContentScale` itself -- its
// desktop HiDPI correction, needed because raylib's `GetWindowScaleDPI` returns
// (1, 1) as soon as fullscreen is set and `GetWindowHandle` returns NULL on
// Wayland. On desktop those resolve out of the GLFW that raylib bundles. Android
// has no GLFW, so they stayed undefined and the platform refused the library:
//
//     dlopen failed: cannot locate symbol "glfwGetCurrentContext"
//
// The engine's own NULL guard turns that into "no correction", which is exactly
// the right answer here -- there is no GLFW window on Android -- so these only
// have to *exist*, and they answer as the guard expects. The real fix is a
// `cfg(not(target_os = "android"))` around that read in slag; this is the P0
// shim that lets the port move (ANDROID.md).

/// No GLFW window exists here, which is what the caller's guard tests for.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "C" fn glfwGetCurrentContext() -> *mut c_void {
    core::ptr::null_mut()
}

/// Never called while the above returns NULL, but it has to resolve at load
/// time all the same. Answers "no scaling", the desktop guard's default.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "C" fn glfwGetWindowContentScale(
    _window: *mut c_void,
    xscale: *mut f32,
    yscale: *mut f32,
) {
    unsafe {
        if !xscale.is_null() {
            *xscale = 1.0;
        }
        if !yscale.is_null() {
            *yscale = 1.0;
        }
    }
}

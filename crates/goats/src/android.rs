//! The Android touch surface: what a phone's screen has that `rl` does not.
//!
//! The engine's `rl` module is keyboard, mouse, gamepad and clipboard. raylib's
//! Android backend *does* collect touch points -- and maps `touch[0]` onto the
//! mouse, which is why the scene's camera drag already works on a phone -- but
//! none of it reaches JavaScript: `rl` has no `getTouchPointCount` and no
//! `getTouchPosition` (ANDROID.md section 3). The client links `raylib-sys`
//! directly already, for the audio streams, so the missing surface is a handful of
//! native functions installed as the `android` global -- and installed only under
//! `cfg(target_os = "android")`, so the desktop client, the headless server and
//! the test harness never see it. The scene guards on its absence.
//!
//! The scene end is `crates/goats/src/game/touch.js`; the decision is D1 in
//! ANDROID.md.
//!
//! Gestures are deliberately *not* part of this. `SUPPORT_GESTURES_SYSTEM` is off
//! in this raylib build, so `GetGesturePinchVector` and the rest sit behind a
//! `#if` that never runs and would read zero. `pinch(i, j)` returns the distance
//! between two named pointers instead -- stateless, and named rather than "the
//! first two", because the fingers free to pinch are not always those (a thumb on
//! the stick is a pointer too).

use core::ffi::c_void;
use std::sync::{Mutex, Once, OnceLock};

use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::{JNIEnv, JavaVM};
use slag::{Context, JsValue};

/// Install the `android` global.
///
/// Called before the scene is evaluated, since the scene looks for the global as
/// it loads. Every failure here is fatal: a surface that half-installed would
/// show up as a control that does nothing.
pub fn install(context: &mut Context) {
    let surface = context.create_object().expect("the android object");

    surface
        .set(
            "touchCount",
            context
                .create_function(
                    "touchCount",
                    0,
                    Box::new(|_call| {
                        // SAFETY: raylib's own input state, which the Android backend
                        // fills from the motion events; no pointer is dereferenced.
                        let count = unsafe { raylib_sys::GetTouchPointCount() };
                        Ok(JsValue::number(count as f64))
                    }),
                )
                .expect("a host function"),
        )
        .expect("touchCount on the android object");

    // `touchAt(index, out)`: whether that pointer is down, with `out` filled in --
    // `x` and `y` in screen pixels, `id` the pointer's identity. The identity is
    // what lets the scene follow *one* finger across frames: the indices in
    // raylib's array compact when a finger in the middle of them lifts, ids do not.
    // The `out` object keeps the call allocation-free, since it runs per finger per
    // frame.
    surface
        .set(
            "touchAt",
            context
                .create_function(
                    "touchAt",
                    2,
                    Box::new(|call| {
                        let index = call
                            .arg(0)
                            .and_then(|value| value.as_number())
                            .unwrap_or(-1.0);
                        let Some((x, y, id)) = pointer(index as i32) else {
                            return Ok(JsValue::boolean(false));
                        };
                        if let Some(out) = call.arg(1).and_then(|value| value.as_object()) {
                            let _ = out.set("x", JsValue::number(x));
                            let _ = out.set("y", JsValue::number(y));
                            let _ = out.set("id", JsValue::number(id));
                        }
                        Ok(JsValue::boolean(true))
                    }),
                )
                .expect("a host function"),
        )
        .expect("touchAt on the android object");

    // `pinch(i, j)`: the distance between two pointers, in screen pixels, or 0 when
    // either index is past the last finger down. The scene keeps the last value and
    // turns the change into the zoom the wheel would have given, so the gesture
    // stays frame-paced by the caller rather than by this function's call count.
    surface
        .set(
            "pinch",
            context
                .create_function(
                    "pinch",
                    2,
                    Box::new(|call| {
                        let first = call
                            .arg(0)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0);
                        let second = call
                            .arg(1)
                            .and_then(|value| value.as_number())
                            .unwrap_or(1.0);
                        Ok(JsValue::number(spread(first as i32, second as i32)))
                    }),
                )
                .expect("a host function"),
        )
        .expect("pinch on the android object");

    // P2's five: the soft keyboard, the clipboard, the insets, and the text the IME
    // has committed. They are the Activity's (`GoatsActivity.java`) and the JNI
    // calls below are the only way to them; the scene's guards stay on the global,
    // because the global is always there and the Activity arrives a moment later.
    surface
        .set(
            "keyboard",
            context
                .create_function(
                    "keyboard",
                    1,
                    Box::new(|call| {
                        let show = call
                            .arg(0)
                            .and_then(|value| value.as_boolean())
                            .unwrap_or(false);
                        Ok(JsValue::boolean(set_keyboard(show)))
                    }),
                )
                .expect("a host function"),
        )
        .expect("keyboard on the android object");

    surface
        .set(
            "takeTyped",
            context
                .create_function(
                    "takeTyped",
                    0,
                    Box::new(|_call| Ok(JsValue::string(take_typed()))),
                )
                .expect("a host function"),
        )
        .expect("takeTyped on the android object");

    surface
        .set(
            "clipboardGet",
            context
                .create_function(
                    "clipboardGet",
                    0,
                    Box::new(|_call| Ok(JsValue::string(clipboard_get()))),
                )
                .expect("a host function"),
        )
        .expect("clipboardGet on the android object");

    surface
        .set(
            "clipboardSet",
            context
                .create_function(
                    "clipboardSet",
                    1,
                    Box::new(|call| {
                        let text = call
                            .arg(0)
                            .and_then(|value| value.as_string())
                            .unwrap_or_default();
                        Ok(JsValue::boolean(clipboard_set(&text)))
                    }),
                )
                .expect("a host function"),
        )
        .expect("clipboardSet on the android object");

    // `inset(edge)`: one of the system's four edges, in screen pixels -- 0 left,
    // 1 top, 2 right, 3 bottom. Four calls rather than one object because a host
    // function can read its arguments but cannot build a JS object; the scene asks
    // for all four when the panel changes size, which is not a hot path.
    surface
        .set(
            "inset",
            context
                .create_function(
                    "inset",
                    1,
                    Box::new(|call| {
                        let edge = call
                            .arg(0)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0);
                        Ok(JsValue::number(inset(edge as i32) as f64))
                    }),
                )
                .expect("a host function"),
        )
        .expect("inset on the android object");

    context
        .set_global("android", surface.as_value())
        .expect("the android global");
}

/// One pointer, in the screen pixels every `rl` 2D call uses, with its raylib
/// point id. `None` past the last finger down.
fn pointer(index: i32) -> Option<(f64, f64, f64)> {
    // SAFETY: raylib's own input state, filled by the Android backend from the
    // motion events; no pointer is dereferenced. The index is checked against the
    // count before anything reads it.
    let count = unsafe { raylib_sys::GetTouchPointCount() };
    if index < 0 || index >= count {
        return None;
    }
    // SAFETY: `index` is inside the count `GetTouchPointCount` reported, which is
    // what the getters bound their own array read by.
    let position = unsafe { raylib_sys::GetTouchPosition(index) };
    // SAFETY: as above.
    let id = unsafe { raylib_sys::GetTouchPointId(index) };
    Some((position.x as f64, position.y as f64, id as f64))
}

/// The distance between two pointers, or 0 when either is past the last finger
/// down.
fn spread(first: i32, second: i32) -> f64 {
    match (pointer(first), pointer(second)) {
        (Some(a), Some(b)) => ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt(),
        _ => 0.0,
    }
}

// ---------------------------------------------------------------------------
// The Java handshake (P2).
//
// The soft keyboard, the clipboard and the window insets are all Java objects, so
// P2 grows an `Activity` of its own -- `android/java/dev/sdgoij/goats/
// GoatsActivity.java` -- and this is the native half of it. The Activity announces
// itself through `nativeInit` and is kept as a global reference, which is what
// every question below is asked through, and what `ndk-context` wants before
// cpal's AAudio host will open a stream (P4).
//
// The two entry points are found by *name* (`Java_dev_sdgoij_goats_
// GoatsActivity_nativeInit`), which is JNI's own convention and the reason there
// is no `JNI_OnLoad`: registering a table from there needs `FindClass`, and
// `NativeActivity` loads the library with `System.load` -- so the calling class is
// the framework's, its loader is the *boot* one, and the app's own class cannot be
// found from it. The by-name path is resolved through the activity's class later,
// where the loader is never in question. Both names are exported by `build.rs`.
//
// The direction matters. Typed text is *pushed*: an IME commits whole strings, so
// there is nothing in raylib's queue to read and the Activity forwards them into
// `TYPED` for the scene to drain. The keyboard, the clipboard and the insets are
// *pulled*, one JNI call each, only when the scene asks. Everything tolerates the
// Activity not existing yet -- the game's loop runs on the glue's own thread and
// can ask before `onCreate` returns -- and "nothing yet" is a better answer than a
// crash.

static VM: OnceLock<JavaVM> = OnceLock::new();
/// The Activity every call is made through. Replaceable, not a `OnceLock`: an
/// Activity can be created more than once in one process, and each is the one to
/// ask.
static ACTIVITY: Mutex<Option<GlobalRef>> = Mutex::new(None);
/// `ndk_context::initialize_android_context` panics if it is called twice.
static NDK_CONTEXT: Once = Once::new();
/// What the IME has committed and the scene has not read: `\n` to submit, `\b` to
/// rub out, everything else as itself.
static TYPED: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// `GoatsActivity.nativeInit()`: the one thing Java hands over, the Activity
/// itself. The `JavaVM` comes with it -- no `JNI_OnLoad` needed, and the pointer
/// is the one `ndk-context` wants.
///
/// # Safety
///
/// Called by the VM with a valid environment and receiver.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_sdgoij_goats_GoatsActivity_nativeInit(
    mut env: JNIEnv,
    this: JObject,
) {
    // The engine materialises file-backed assets (models, sounds, music) into
    // `std::env::temp_dir()` -- raylib's loaders take a path and pick a decoder
    // from its extension. On Android that is `TMPDIR` or Rust's own fallback,
    // `/data/local/tmp`, which is `0771 shell:shell`: unwritable, so the first
    // model load dies with `EACCES`. The framework *does* set `TMPDIR` to the app's
    // cache and Java sees it, but the native library's `getenv` does not on the
    // newer OS this was found on; a *native* `setenv` is what the engine observes.
    // So take the cache dir from the Activity and point `TMPDIR` at it, here,
    // before the scene loads. The window is not up until `onCreate` returns, so
    // the game's thread is still blocked in `InitWindow` and no asset has loaded.
    if let Some(cache) = cache_dir(&mut env, &this) {
        // SAFETY: `nativeInit` runs once, during `onCreate`, on the main thread,
        // and the scene's own threads are not reading the environment yet -- the
        // game's thread is blocked in `InitWindow` until the window exists.
        unsafe { std::env::set_var("TMPDIR", cache) };
    }

    let Ok(global) = env.new_global_ref(&this) else {
        return;
    };
    let Ok(vm) = env.get_java_vm() else {
        return;
    };
    // `ndk-context` is where cpal's AAudio host looks its `JavaVM` and `Context`
    // up, and the Activity is exactly what it wants. Harmless before P4: nothing
    // reads it until a stream is opened.
    //
    // It *panics* if it is initialised twice, and an Activity can be created more
    // than once in one process -- a configuration change the manifest does not
    // claim, "don't keep activities", a second launch -- so this is the
    // process-wide one-shot, and the first Activity is the right one to keep.
    let context = global.as_raw() as *mut c_void;
    if !context.is_null() {
        NDK_CONTEXT.call_once(|| {
            // SAFETY: the VM outlives the process and the reference is kept in
            // `ACTIVITY` below, so both pointers stay valid.
            unsafe {
                ndk_context::initialize_android_context(vm.get_java_vm_pointer().cast(), context)
            }
        });
    }
    // A recreated Activity replaces the one every call goes through, or the
    // keyboard and the clipboard would be asked of a window that is gone.
    if let Ok(mut slot) = ACTIVITY.lock() {
        *slot = Some(global);
    }
    let _ = VM.set(vm);
    eprintln!("[android] the activity is attached");
}

/// The Activity's cache directory, which is what `TMPDIR` should be -- or `None`
/// if the Activity cannot answer, in which case the caller leaves the
/// environment alone rather than guessing a path.
fn cache_dir(env: &mut JNIEnv, activity: &JObject) -> Option<std::ffi::OsString> {
    let file = env
        .call_method(activity, "getCacheDir", "()Ljava/io/File;", &[])
        .ok()?
        .l()
        .ok()?;
    let path = env
        .call_method(&file, "getAbsolutePath", "()Ljava/lang/String;", &[])
        .ok()?
        .l()
        .ok()?;
    let path = JString::from(path);
    let path = env.get_string(&path).ok()?;
    Some(std::ffi::OsString::from(
        path.to_string_lossy().into_owned(),
    ))
}

/// `GoatsActivity.nativeText(String)`: one committed string, pushed.
///
/// # Safety
///
/// Called by the VM with a valid environment, class and string.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_sdgoij_goats_GoatsActivity_nativeText(
    mut env: JNIEnv,
    _class: JClass,
    text: JString,
) {
    let Ok(text) = env.get_string(&text) else {
        return;
    };
    let Ok(mut queue) = TYPED.lock() else {
        return;
    };
    queue.extend_from_slice(text.to_string_lossy().as_bytes());
}

/// `android.takeTyped()`: everything the IME has committed since the last call.
fn take_typed() -> String {
    let Ok(mut queue) = TYPED.lock() else {
        return String::new();
    };
    if queue.is_empty() {
        return String::new();
    }
    String::from_utf8(std::mem::take(&mut queue)).unwrap_or_default()
}

/// Run `call` against the Activity, or `None` before Java has handed it over.
/// The thread is attached for the length of the call: the game's frame loop runs
/// on a thread the VM has never seen.
fn with_activity<T>(call: impl FnOnce(&mut JNIEnv, &JObject) -> Option<T>) -> Option<T> {
    let vm = VM.get()?;
    let activity = ACTIVITY.lock().ok()?;
    let activity = activity.as_ref()?;
    let mut env = vm.attach_current_thread().ok()?;
    call(&mut env, activity.as_obj())
}

/// `android.keyboard(show)`: whether the request reached the Activity.
fn set_keyboard(show: bool) -> bool {
    with_activity(|env, activity| {
        Some(
            env.call_method(activity, "setKeyboard", "(Z)V", &[JValue::Bool(show as u8)])
                .is_ok(),
        )
    })
    .unwrap_or(false)
}

/// `android.clipboardGet()`: the clipboard's text, or an empty string -- which is
/// also what an empty clipboard is.
fn clipboard_get() -> String {
    with_activity(|env, activity| {
        let value = env
            .call_method(activity, "clipboardGet", "()Ljava/lang/String;", &[])
            .ok()?;
        let text = JString::from(value.l().ok()?);
        env.get_string(&text)
            .ok()
            .map(|text| text.to_string_lossy().into_owned())
    })
    .unwrap_or_default()
}

/// `android.clipboardSet(text)`: whether it was put there.
fn clipboard_set(text: &str) -> bool {
    with_activity(|env, activity| {
        let value = env.new_string(text).ok()?;
        env.call_method(
            activity,
            "clipboardSet",
            "(Ljava/lang/String;)V",
            &[JValue::Object(&value)],
        )
        .ok()
        .map(|_| true)
    })
    .unwrap_or(false)
}

/// `android.inset(edge)`: one of the system's edges in screen pixels, or 0 before
/// the Activity can say. The edges are 0 left, 1 top, 2 right, 3 bottom.
fn inset(edge: i32) -> i32 {
    with_activity(|env, activity| {
        env.call_method(activity, "inset", "(I)I", &[JValue::Int(edge)])
            .ok()
            .and_then(|value| value.i().ok())
    })
    .unwrap_or(0)
}

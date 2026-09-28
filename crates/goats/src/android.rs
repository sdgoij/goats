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

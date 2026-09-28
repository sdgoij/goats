//! The touch controls (P1), on the harness's scripted touch surface.
//!
//! A phone's only input is its screen, and the scene's controls are a keyboard, a
//! mouse and a wheel. `crates/goats/src/game/touch.js` is the bridge -- a stick, a
//! jump button and a menu button -- and the client's `android` global is the
//! surface under it (`crates/goats/src/android.rs`, installed only under
//! `cfg(target_os = "android")`).
//!
//! The harness has no touchscreen, so it installs its own surface and scripts the
//! pointers: `Harness::touch` takes `[[frame, [[id, x, y], ...]], ...]`. A case
//! that scripts touches is driving the phone's input, so the scripted *keyboard* in
//! `harness_rl.js` stands down for it -- otherwise two input paths would be moving
//! the same goat, and neither would be measured.
//!
//! The cases assert through the seams the overlay is built on rather than through
//! the picture: `ctlHeld` (the table the stick writes), `goat.px`/`goat.yaw` (what
//! the movement did with it), `camYaw`/`camDist` (what the drag and the pinch did
//! to the camera) and `uiScreen` (what the menu button opened). The one exception
//! is the circle count, which is how "the controls were on screen" is read back.
//!
//! One live world at a time, as in `skinning.rs`: a second stepped context in the
//! same process aborts, so each harness is scoped and dropped before the next.

mod support;

use harness::Harness;
use serde_json::json;
use support::Checks;

/// Past the splash (nine load steps plus a bot per step) with enough frames left
/// for a gait change, a drag and a jump.
const FRAMES: u32 = 160;

fn number(harness: &mut Harness, expression: &str) -> f64 {
    harness
        .eval(expression)
        .ok()
        .and_then(|value| value.as_f64())
        .unwrap_or(f64::NAN)
}

fn flag(harness: &mut Harness, expression: &str) -> bool {
    harness
        .eval(expression)
        .ok()
        .and_then(|value| value.as_bool())
        .unwrap_or(false)
}

/// A control's centre, read from the scene rather than restated here, so retuning
/// the layout moves the cases with it.
fn spot(harness: &mut Harness, name: &str) -> (f64, f64) {
    let x = number(harness, &format!("touchLayout().{name}.x"));
    let y = number(harness, &format!("touchLayout().{name}.y"));
    assert!(x.is_finite() && y.is_finite(), "no layout for {name}");
    (x, y)
}

#[test]
fn the_touch_controls_drive_the_goat() {
    let mut checks = Checks::new();

    // ---- no surface: the guard every other host is under --------------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let obs = harness.run(90).expect("run the scene");
        checks.check(
            "a host with no touch surface draws no controls",
            obs.touch_circles == 0,
            obs.touch_circles,
        );
        checks.check(
            "...and the overlay knows it has none",
            !flag(&mut harness, "touchPointer.present"),
            flag(&mut harness, "touchPointer.present"),
        );
        checks.check(
            "...and the goat drew anyway",
            obs.goat_draw.is_some(),
            obs.goat_draw,
        );
    }

    // ---- the stick: a gait, and a turn -------------------------------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let (sx, sy) = spot(&mut harness, "stick");
        // Half a stick forward walks; a full push, later, runs; then let go.
        harness
            .touch(&json!([
                [20, [[1, sx, sy - 40.0]]],
                [60, [[1, sx, sy - 120.0]]],
                [110, []],
            ]))
            .expect("touches");
        let obs = harness.run(FRAMES).expect("run the scene");

        checks.check(
            "the controls are drawn when there is a surface",
            obs.touch_circles > 0,
            obs.touch_circles,
        );
        checks.check(
            "a half-pushed stick walks and a full one runs",
            obs.player_clips.contains(&"GoatWalk".to_string())
                && obs.player_clips.contains(&"GoatRun".to_string()),
            &obs.player_clips,
        );
        let px = number(&mut harness, "goat.px");
        checks.check("...and the goat went forward", px > 1.0, px);
        checks.check(
            "...and letting go left no key held",
            !flag(&mut harness, "ctlHeld[87] === true"),
            flag(&mut harness, "ctlHeld[87] === true"),
        );
    }

    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let (sx, sy) = spot(&mut harness, "stick");
        let cam_before = number(&mut harness, "camYaw");
        // Straight left: the turn keys, not strafe.
        harness
            .touch(&json!([[20, [[1, sx - 120.0, sy]]], [100, []]]))
            .expect("touches");
        harness.run(FRAMES).expect("run the scene");

        let yaw = number(&mut harness, "goat.yaw");
        checks.check(
            "a stick pushed sideways turns the goat",
            yaw.abs() > 0.05,
            yaw,
        );
        let cam_after = number(&mut harness, "camYaw");
        checks.check(
            "a thumb on the stick is not a camera drag",
            (cam_after - cam_before).abs() < 1.0e-9,
            (cam_before, cam_after),
        );
    }

    // ---- a script's hold survives a thumb lifting --------------------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let (sx, sy) = spot(&mut harness, "stick");
        // The way `command("walk")` holds W: the stick takes the same key, so its
        // release has to put back what it found rather than clear the table.
        harness
            .eval("ctlHeld[87] = true")
            .expect("the script's hold");
        harness
            .touch(&json!([[20, [[1, sx, sy - 120.0]]], [80, []]]))
            .expect("touches");
        harness.run(140).expect("run the scene");

        checks.check(
            "a thumb lifting off the stick gives back a script's key",
            flag(&mut harness, "ctlHeld[87] === true"),
            flag(&mut harness, "ctlHeld[87] === true"),
        );
    }

    // ---- the camera: a free drag, and a pinch ------------------------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let before = number(&mut harness, "camYaw");
        // A finger in the middle of the panel, clear of every control.
        harness
            .touch(&json!([
                [20, [[7, 500.0, 300.0]]],
                [60, [[7, 700.0, 300.0]]],
                [100, []],
            ]))
            .expect("touches");
        harness.run(FRAMES).expect("run the scene");

        let after = number(&mut harness, "camYaw");
        checks.check(
            "a free finger drags the camera the way the mouse does",
            (after - before).abs() > 0.1,
            (before, after),
        );
    }

    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let before = number(&mut harness, "camDist");
        // Two free fingers spreading apart.
        harness
            .touch(&json!([
                [20, [[7, 400.0, 300.0], [8, 440.0, 300.0]]],
                [40, [[7, 300.0, 300.0], [8, 540.0, 300.0]]],
                [80, []],
            ]))
            .expect("touches");
        harness.run(FRAMES).expect("run the scene");

        let after = number(&mut harness, "camDist");
        checks.check(
            "two free fingers pinch, and spreading them zooms in",
            after < before - 0.05,
            (before, after),
        );
    }

    // ---- the buttons --------------------------------------------------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let (jx, jy) = spot(&mut harness, "jump");
        harness
            .touch(&json!([[20, [[1, jx, jy]]], [30, []]]))
            .expect("touches");
        let obs = harness.run(FRAMES).expect("run the scene");
        checks.check(
            "the jump button jumps",
            obs.player_clips.contains(&"GoatJump".to_string()),
            &obs.player_clips,
        );
    }

    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let (mx, my) = spot(&mut harness, "menu");
        harness
            .touch(&json!([[20, [[1, mx, my]]], [40, []]]))
            .expect("touches");
        harness.run(120).expect("run the scene");

        let screen = harness
            .eval("uiScreen")
            .ok()
            .and_then(|value| value.as_str().map(str::to_string));
        checks.check(
            "the menu button opens the menu ESC opens",
            screen.as_deref() == Some("main"),
            screen,
        );
    }

    checks.finish();
}

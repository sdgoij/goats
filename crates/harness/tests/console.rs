//! The console on a phone (P2): the soft keyboard's text, and the Activity's
//! clipboard.
//!
//! A soft keyboard commits whole strings rather than key presses, so raylib's
//! character queue never sees them (`ANDROID.md` section 3) and the client's
//! `android` global carries them instead: `GoatsActivity`'s `InputConnection`
//! forwards each commit into a queue the scene drains, with `\n` for the enter
//! key and `\b` for backspace, the two edits a text-only channel still has to
//! carry. The clipboard is the Activity's too, because raylib's binding on Android
//! is a stub that reports "not implemented on target platform".
//!
//! The harness's `android` surface is the same one `touch.rs` installs
//! (`Harness::touch`), extended with the Java-side members: `type_text` is the
//! IME committing a string, `set_insets` is the device saying where its cut-out
//! and gesture bars are, and the stub's clipboard is separate from raylib's on
//! purpose -- so a case can say *which* one a paste and a copy went through.
//!
//! One live world at a time, as in `skinning.rs`: a second stepped context in the
//! same process aborts, so each harness is scoped and dropped before the next.

mod support;

use harness::Harness;
use serde_json::json;
use support::Checks;

fn string(harness: &mut Harness, expression: &str) -> String {
    harness
        .eval(expression)
        .ok()
        .and_then(|value| value.as_str().map(str::to_string))
        .unwrap_or_default()
}

fn number(harness: &mut Harness, expression: &str) -> f64 {
    harness
        .eval(expression)
        .ok()
        .and_then(|value| value.as_f64())
        .unwrap_or(f64::NAN)
}

/// A scene with the phone's surface installed and no fingers on it: the touch
/// ring is irrelevant here, but the Java members are not.
fn phone(checks: &mut Checks) -> Harness {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.touch(&json!([])).expect("the touch surface");
    // The scene reads the surface off the global as it runs, so these are the
    // predicates `touch.js` and `console.js` guard on -- and unlike
    // `touchPointer.present`, which only a frame sets, they hold now.
    checks.check(
        "the scene sees the phone's surface",
        harness
            .eval("consoleTouchText() && consoleTouchClipboard()")
            .ok()
            .and_then(|value| value.as_bool())
            .unwrap_or(false),
        "consoleTouchText() && consoleTouchClipboard()",
    );
    harness
}

#[test]
fn the_console_speaks_java() {
    let mut checks = Checks::new();

    // ---- the keyboard comes and goes with the console -----------------------
    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        let obs = harness.run(60).expect("run the scene");

        checks.check(
            "opening the console asks for the soft keyboard",
            obs.keyboard_calls >= 1 && obs.keyboard_shown,
            (obs.keyboard_calls, obs.keyboard_shown),
        );
        // The controls and the keyboard are the same half of the panel: the overlay
        // stands down while the console is up, and it never drew at all here.
        checks.check(
            "...and the touch overlay gives way to it",
            obs.touch_circles == 0,
            obs.touch_circles,
        );
    }

    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        harness.eval("consoleClose()").expect("close it");
        let obs = harness.run(40).expect("run the scene");
        checks.check(
            "closing it puts the keyboard away",
            obs.keyboard_calls >= 2 && !obs.keyboard_shown,
            (obs.keyboard_calls, obs.keyboard_shown),
        );
    }

    // ---- the IME's text ------------------------------------------------------
    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        harness.type_text("pi").expect("the IME commits");
        harness.run(30).expect("run the scene");
        let line = string(&mut harness, "consoleInput");
        checks.check("a committed string lands in the line", line == "pi", line);
    }

    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        // `\b` is the keyboard's backspace: the channel carries text, so the two
        // edits that do something are characters in it.
        harness.type_text("pinx\x08").expect("the IME commits");
        harness.run(30).expect("run the scene");
        let line = string(&mut harness, "consoleInput");
        checks.check("and its backspace rubs one out", line == "pin", line);
    }

    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        harness.type_text("ping\n").expect("the IME commits a line");
        harness.run(40).expect("run the scene");
        let line = string(&mut harness, "consoleInput");
        let history = string(&mut harness, "JSON.stringify(consoleHistory)");
        checks.check(
            "an enter submits the line and clears it",
            line.is_empty() && history.contains("ping"),
            (line, history),
        );
    }

    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        // The phone's back button (`GoatsActivity.onBackPressed`) rides the same
        // channel as escape, because a phone has no escape key to close the console
        // with. Queued before the run: the frame drains it (`console.js`).
        harness.type_text("\u{1b}").expect("the back button");
        let obs = harness.run(30).expect("run the scene");
        let open = harness
            .eval("consoleOpen")
            .ok()
            .and_then(|value| value.as_bool())
            .unwrap_or(true);
        checks.check(
            "the phone's back button closes the console",
            !open && !obs.keyboard_shown,
            (open, obs.keyboard_shown),
        );
    }

    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        // A new touch on the game closes it: with the keyboard up that is the way
        // out that does not depend on the back button being delivered.
        harness
            .touch(&json!([[20, [[1, 500.0, 300.0]]]]))
            .expect("the tap");
        let obs = harness.run(40).expect("run the scene");
        let open = harness
            .eval("consoleOpen")
            .ok()
            .and_then(|value| value.as_bool())
            .unwrap_or(true);
        checks.check(
            "a tap on the game closes the console",
            !open && !obs.keyboard_shown,
            (open, obs.keyboard_shown),
        );
    }

    // ---- the Activity's clipboard -------------------------------------------
    {
        let mut harness = phone(&mut checks);
        harness.eval("consoleToggle()").expect("open the console");
        let obs = harness.run(40).expect("run the scene");
        let reply = harness.command("copy ticket-123").expect("copy");
        harness.eval("consolePaste()").expect("paste");
        let line = string(&mut harness, "consoleInput");

        checks.check(
            "`copy` reports through the Activity's clipboard",
            reply.starts_with("ok"),
            reply,
        );
        checks.check(
            "...and a paste reads back what it wrote",
            line == "ticket-123",
            line,
        );
        checks.check(
            "...not through raylib's, which does nothing on Android",
            obs.clipboard_writes.is_empty(),
            &obs.clipboard_writes,
        );
    }

    // ---- without a phone, the engine's own clipboard is still the one -------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let reply = harness.command("copy hi").expect("copy");
        let obs = harness.observe().expect("observe");
        checks.check(
            "a host with no touch surface still copies through the engine",
            reply.starts_with("ok") && obs.clipboard_writes == vec!["hi".to_string()],
            (reply, &obs.clipboard_writes),
        );
    }

    // ---- the system's insets move the controls ------------------------------
    {
        let mut harness = phone(&mut checks);
        // A cut-out on the right and a gesture bar along the bottom, as this phone
        // has in landscape.
        harness.set_insets([0, 0, 140, 80]).expect("insets");
        harness.run(40).expect("run the scene");

        let width = number(&mut harness, "touchLayout().w");
        let jump_x = number(&mut harness, "touchLayout().jump.x");
        let jump_r = number(&mut harness, "touchLayout().jump.r");
        checks.check(
            "the controls clear the system's own edges",
            width - (jump_x + jump_r) >= 140.0,
            (width, jump_x, jump_r),
        );
    }

    checks.finish();
}

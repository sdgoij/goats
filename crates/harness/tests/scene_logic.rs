//! The ported scene suite: `tools/goat_logic_test.js`, in Rust, on Slag.
//!
//! One full 4050-frame run, then the cases the Node harness asserted, reported
//! through [`Checks`] so a failure names itself and the rest still run. This file
//! is the port target for the whole of `goat_logic_test.js`; it grows slice by
//! slice, and until the last slice lands the Node harness stays as the authority
//! for the expected values.
//!
//! The run is long (~35s in a release build) and the frame indices are absolute,
//! so the test is `#[ignore]`d and driven explicitly:
//!
//! ```text
//! cargo test --release -p harness --test scene_logic -- --ignored --nocapture
//! ```

mod support;

use harness::Harness;
use support::Checks;

/// The frames the scripted timeline runs for: the walk, the jump, the death and
/// the restart all happen inside it.
const TOTAL: u32 = 4050;

#[test]
#[ignore = "the full 4050-frame run: ~35s release, ~2min debug"]
fn the_scene_runs_the_scripted_timeline() {
    let started = std::time::Instant::now();
    let mut harness = Harness::start().expect("evaluate the scene");
    let obs = harness.run(TOTAL).expect("run the scene");
    let elapsed = started.elapsed();
    let mut checks = Checks::new();

    eprintln!(
        "harness: {} frames in {:?} ({:.1} ms/frame), {} cubes",
        obs.timeline.len(),
        elapsed,
        elapsed.as_secs_f64() * 1000.0 / obs.timeline.len().max(1) as f64,
        obs.counters.cube_draws
    );

    // A throw would have come back as an error from `run` or from a later drive,
    // so reaching here is the case.
    checks.check("no throw", true, "the scene evaluated and ran");
    checks.check(
        "the run reached the end",
        obs.row(4040).is_some(),
        obs.timeline.len(),
    );

    // ---- the gait state machine ------------------------------------------
    // The frames are the scripted input's, so they are the same frames the Node
    // harness checked.
    checks.check(
        "idle at frame 3",
        obs.is_clip(3, "GoatIdle"),
        obs.clip_at(3),
    );
    checks.check(
        "walk at frame 15",
        obs.clip_at(15) == Some("GoatWalk"),
        obs.clip_at(15),
    );
    checks.check(
        "trot at frame 40",
        obs.clip_at(40) == Some("GoatTrot"),
        obs.clip_at(40),
    );
    checks.check(
        "run at frame 60",
        obs.clip_at(60) == Some("GoatRun"),
        obs.clip_at(60),
    );
    checks.check(
        "jump starts at frame 70",
        obs.is_clip(70, "GoatJump"),
        obs.clip_at(70),
    );
    checks.check(
        "landed to idle by frame 145",
        obs.is_clip(145, "GoatIdle"),
        obs.clip_at(145),
    );
    checks.check(
        "sleeping at frame 160",
        obs.is_clip(160, "GoatSleep"),
        obs.clip_at(160),
    );
    checks.check(
        "woke to walk at frame 190",
        obs.clip_at(190) == Some("GoatWalk"),
        obs.clip_at(190),
    );

    // The gaits' speeds come from the clip durations, so they check both the
    // clips and the HUD's arithmetic.
    let walk = obs.speed_at(15);
    checks.check(
        "walk speed ~0.87 m/s",
        walk.is_some_and(|s| (s - 0.873).abs() < 0.01),
        walk,
    );
    let trot = obs.speed_at(40);
    checks.check(
        "trot speed ~1.58 m/s",
        trot.is_some_and(|s| (s - 1.577).abs() < 0.02),
        trot,
    );
    let run = obs.speed_at(60);
    checks.check(
        "run speed ~2.94 m/s",
        run.is_some_and(|s| (s - 2.941).abs() < 0.02),
        run,
    );

    // ---- stats, the clock, and dying -------------------------------------
    let e20 = obs.stat_at(20);
    let e60 = obs.stat_at(60);
    checks.check(
        "energy drains while running",
        matches!((e20, e60), (Some(early), Some(late)) if late.energy < early.energy),
        (e20, e60),
    );

    let c20 = obs.clock_at(20);
    let c1200 = obs.clock_at(1200);
    checks.check(
        "clock advances over time",
        matches!((c20, c1200), (Some(early), Some(late)) if late > early),
        (c20, c1200),
    );

    let death = obs.death_frame;
    checks.check(
        "goat dies of exhaustion",
        (200..3950).contains(&death),
        death,
    );
    let death_frame = u32::try_from(death).ok();
    let held = death_frame.and_then(|frame| obs.clip_at(frame + 5));
    checks.check(
        "death clip held while dead",
        held == Some("GoatDeath"),
        held,
    );
    let dead = death_frame.and_then(|frame| obs.stat_at(frame));
    checks.check(
        "health is zero at death",
        dead.is_some_and(|s| s.health == 0),
        dead,
    );
    checks.check(
        "R restarts into run",
        obs.clip_at(4000) == Some("GoatRun"),
        obs.clip_at(4000),
    );
    checks.check(
        "the player cycles idle variants",
        obs.player_idles.len() >= 2,
        obs.player_idles.clone(),
    );

    // ---- the run finished where it should --------------------------------
    // The console's scripted frames sit after the restart, so these also prove
    // the run reached them rather than stopping early.
    let probe = obs.probe(4016).expect("the console probe at 4016");
    checks.check(
        "the console is open at its probe",
        probe.state.open,
        probe.state.open,
    );
    checks.check(
        "the console kept the command in its history",
        probe.state.history.iter().any(|entry| entry == "ping"),
        probe.state.history.clone(),
    );
    checks.check(
        "the console answered the command",
        probe
            .state
            .lines
            .iter()
            .any(|line| line == "local: ok pong"),
        probe.state.lines.clone(),
    );
    checks.check(
        "the console copied the pasted line",
        obs.clipboard_writes
            .iter()
            .any(|w| w.ends_with("endpointABC")),
        obs.clipboard_writes.clone(),
    );
    checks.check("the herd loaded", obs.bot_count >= 2, obs.bot_count);
    checks.check(
        "the herd was drawn",
        !obs.bot_draw.is_empty(),
        obs.bot_draw.len(),
    );
    checks.check(
        "the bots kept their distance",
        obs.min_gap.is_some(),
        obs.min_gap,
    );

    checks.finish();
}

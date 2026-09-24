//! SCRATCH PROBE -- temporary, deleted before anything is committed.
mod support;

use harness::Harness;
use support::command_json;

fn rain(harness: &mut Harness, amount: f64) {
    harness
        .eval(&format!("rainAmount = {amount}"))
        .expect("set the rain");
    harness
        .call("updateWeatherEffects", &[])
        .expect("updateWeatherEffects");
}

/// One row: the rain, the level it makes, and how the field answered.
fn row(harness: &mut Harness, amount: f64) {
    rain(harness, amount);
    let f = command_json(harness, "water");
    eprintln!(
        "    rain {amount:4.2}  level {:>8}  rise {:>7}  wet {:>4}  deepest {:>6}  (floor {:>8} high {:>6})",
        f["level"], f["rise"], f["wet"], f["deepest"], f["floor"], f["high"],
    );
}

/// Empty the table the way the frame's own step would, so a sweep starts from dry. A step
/// past any time constant: `waterUpdate` only ever raises `waterWet`, so without this the
/// next sweep inherits the last one's flood.
fn settle(harness: &mut Harness) {
    rain(harness, 0.0);
    harness
        .call("waterStep", &[serde_json::json!(1.0e6)])
        .expect("waterStep");
}

/// The sweep, for one pair of knobs: the table's `fill` share and the wading cap.
fn sweep(harness: &mut Harness, fill: f64, max_depth: f64) {
    settle(harness);
    harness
        .command(&format!("tune water.fill {fill}"))
        .expect("tune fill");
    harness
        .command(&format!("tune water.maxDepth {max_depth}"))
        .expect("tune maxDepth");
    eprintln!("\nfill {fill}, maxDepth {max_depth}:");
    for step in 1..=20 {
        row(harness, step as f64 / 20.0);
    }
}

#[test]
fn probe_the_rise_against_the_rain() {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(30).expect("run the scene");
    let f = command_json(&mut harness, "water");
    eprintln!(
        "the spawn window: low {} high {} pond {} floor {}",
        f["low"], f["high"], f["pond"], f["floor"]
    );

    // As shipped: `fill` 0.17 against the wading cap, which is where the ROADMAP's own
    // table was measured.
    sweep(&mut harness, 0.17, 0.6);
    // The same cap, with room for the table to walk.
    sweep(&mut harness, 0.5, 0.6);
    // ...and with the cap lifted out of the way, which is M20g's move.
    sweep(&mut harness, 0.5, 8.0);
    sweep(&mut harness, 1.0, 8.0);
}

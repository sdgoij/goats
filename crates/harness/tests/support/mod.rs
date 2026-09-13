//! Shared test support.
//!
//! The Node harness collected every case and reported them together, so one
//! failure did not hide the rest and a long run was not thrown away at the first
//! problem. [`Checks`] keeps that: a test records each case, and `finish` prints
//! them all and fails once if any of them did not hold.
//!
//! Not every helper is used by every test binary, so the toolbox is not held to
//! the dead-code lint.
#![allow(dead_code)]

use harness::Harness;

/// Runs a command and parses the JSON after its `ok `.
///
/// A staging error is fatal: the cases it feeds cannot be judged, and a quiet
/// `false` would read as a scene bug rather than a broken drive.
pub fn command_json(harness: &mut Harness, line: &str) -> serde_json::Value {
    let reply = harness
        .command(line)
        .unwrap_or_else(|error| panic!("{line}: {error}"));
    let json = reply
        .strip_prefix("ok ")
        .unwrap_or_else(|| panic!("{line} said {reply:?}"));
    serde_json::from_str(json)
        .unwrap_or_else(|error| panic!("{line}: unreadable {json:?}: {error}"))
}

/// A JSON boolean as a Rust one, defaulting to false.
pub fn bool_of(value: serde_json::Value) -> bool {
    value.as_bool().unwrap_or(false)
}

/// A JSON number as an `f64`, defaulting to NaN so comparisons fail rather than
/// silently reading as zero.
pub fn f64_of(value: serde_json::Value) -> f64 {
    value.as_f64().unwrap_or(f64::NAN)
}

/// One reported case.
struct Check {
    name: String,
    ok: bool,
    got: String,
}

/// Collects the cases a test checked.
#[derive(Default)]
pub struct Checks {
    rows: Vec<Check>,
}

impl Checks {
    pub fn new() -> Checks {
        Checks::default()
    }

    /// Records a case. `got` is printed only when the case fails.
    pub fn check(&mut self, name: &str, ok: bool, got: impl std::fmt::Debug) {
        self.rows.push(Check {
            name: name.to_string(),
            ok,
            got: format!("{got:?}"),
        });
    }

    /// Prints every case, then fails the test if any of them did not hold.
    pub fn finish(self) {
        let mut failed = 0;
        for check in &self.rows {
            if check.ok {
                println!("PASS  {}", check.name);
            } else {
                failed += 1;
                println!("FAIL  {}  (got {})", check.name, check.got);
            }
        }
        if failed == 0 {
            println!("ALL PASS ({})", self.rows.len());
        } else {
            panic!("{failed} of {} checks failed", self.rows.len());
        }
    }
}

//! Shared test support.
//!
//! The Node harness collected every case and reported them together, so one
//! failure did not hide the rest and a long run was not thrown away at the first
//! problem. [`Checks`] keeps that: a test records each case, and `finish` prints
//! them all and fails once if any of them did not hold.

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

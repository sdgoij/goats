//! The kernel benchmark: JavaScript against wasm, on the same arithmetic, so
//! "wasm is slow" stops being folklore.
//!
//! Three arms, because the JIT is opt-in (`slag::install_jit`) and it matters
//! which one is on: plain JavaScript, JavaScript with the JIT installed the way
//! the client installs it, and wasm on the interpreter. A compiled-wasm arm
//! needs the `compile` feature, which no Goat crate can reach today (see M17's
//! upstream prerequisite), so it is measured from the slag workspace instead and
//! the wasm interpreter row is the bridge between the two measurements.
//!
//! The kernel is the shape of the `birds` flock's `stepFly` -- one O(n^2)
//! neighbour accumulation per frame, alignment plus cohesion plus separation --
//! reduced to what every arm can run identically (`fixtures/wasm/c/bench.c`).
//! Two deliberate omissions: no trigonometry, because core wasm has no
//! `sin`/`cos` and the measurement would become a measurement of the host's
//! math; and no imports, so nothing here is measuring a capability.
//!
//! Both arms are JavaScript-driven, which is today's shape (M17a): the wasm arm
//! therefore includes one JS-to-wasm call per frame, and the JavaScript arm is
//! given its *best* case -- contiguous `Float32Array` storage, no objects and no
//! allocation in the loop. If wasm loses here, it loses worse against idiomatic
//! mod code.
//!
//! The reported figure is nanoseconds per agent-pair per frame, so the sizes are
//! comparable and the scaling is visible.
//!
//! Run it with:
//!
//! ```sh
//! cargo test --release --offline -p harness --test plugin_bench -- --ignored --nocapture
//! ```
//!
//! It is `#[ignore]`d because it is a timing, not a correctness, test: the
//! assertions are sanity checks (both arms ran, and they computed the same
//! numbers), never a threshold that a noisy machine could fail.

use std::path::{Path, PathBuf};
use std::time::Instant;

use slag::Context;

/// The sizes to sweep. 6 is the `birds` flock; the rest are what a mod might ask
/// for, and 1024 is where an O(n^2) kernel starts to hurt at all.
const SIZES: [u32; 4] = [6, 64, 256, 1024];

/// Roughly how much work a single (arm, size) run should do, in agent-pairs.
/// Big enough for the JIT to warm up and for a timer to have resolution;
/// small enough that a sweep over four sizes and two arms finishes quickly.
const PAIRS_TARGET: u64 = 2_000_000;

/// Frames of warm-up before the timed run, so the JavaScript arm is measured
/// after the JIT has had a chance to compile the loop.
const WARMUP: u32 = 2;

/// One frame's step, at 60 Hz.
const DT: f64 = 0.016;

/// The shared JavaScript: the initial state and a checksum, so both arms
/// provably start from the same numbers and are compared on the numbers they
/// end with. The record is `{x, z, vx, vz}`, 16 bytes, laid out by `bench.c`.
const HELPERS: &str = r#"
// `base` is a float index, so the same helper serves a Float32Array of its own
// and a view over a wasm module's memory at an arbitrary offset.
function initAgents(view, base, count) {
  for (var i = 0; i < count; i++) {
    var b = base + i * 4;
    view[b + 0] = (i * 37 % 29) * 0.5;
    view[b + 1] = (i * 53 % 31) * 0.5;
    view[b + 2] = 0;
    view[b + 3] = 0;
  }
}

function checksum(view, base, count) {
  var sum = 0;
  for (var i = 0; i < count * 4; i++) { sum += view[base + i]; }
  return sum;
}
"#;

/// The JavaScript arm's kernel: the same arithmetic in the same order as
/// `bench.c`, on typed-array storage.
const JS_KERNEL: &str = r#"
function jstep(a, base, count, dt) {
  for (var i = 0; i < count; i++) {
    var ib = base + i * 4;
    var ax = a[ib + 0], az = a[ib + 1];
    var aliX = 0, aliZ = 0, cohX = 0, cohZ = 0, sepX = 0, sepZ = 0;
    var nA = 0, nC = 0, nS = 0;
    for (var j = 0; j < count; j++) {
      if (j === i) { continue; }
      var jb = base + j * 4;
      var dx = ax - a[jb + 0], dz = az - a[jb + 1];
      var d2 = dx * dx + dz * dz;
      if (d2 < 121) {
        cohX += a[jb + 0]; cohZ += a[jb + 1];
        aliX += a[jb + 2]; aliZ += a[jb + 3];
        nC++; nA++;
      }
      if (d2 > 1e-4 && d2 < 10.24) {
        var d = Math.sqrt(d2);
        var w = (3.2 - d) / d;
        sepX += dx * w; sepZ += dz * w;
        nS++;
      }
    }
    if (nC > 0) { cohX /= nC; cohZ /= nC; }
    if (nA > 0) { aliX /= nA; aliZ /= nA; }
    if (nS > 0) { sepX /= nS; sepZ /= nS; }
    var vx = a[ib + 2] + (cohX * 0.5 + aliX * 1.0 + sepX * 1.5) * dt;
    var vz = a[ib + 3] + (cohZ * 0.5 + aliZ * 1.0 + sepZ * 1.5) * dt;
    a[ib + 2] = vx; a[ib + 3] = vz;
    a[ib + 0] = ax + vx * dt; a[ib + 1] = az + vz * dt;
  }
}
"#;

fn frames_for(n: u32) -> u32 {
    let per_frame = u64::from(n) * u64::from(n);
    (PAIRS_TARGET / per_frame).clamp(5, 2000) as u32
}

fn bench_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("fixtures")
        .join("wasm")
        .join("bench.wasm")
}

/// Evaluate `script`, returning how long it took in milliseconds and the number
/// it evaluated to. `eval` includes the script's own parse, which is the same
/// order of magnitude for both arms and negligible at these frame counts.
fn timed(context: &mut Context, script: &str) -> (f64, f64) {
    let start = Instant::now();
    let value = context.eval(script).expect("the benchmark script");
    let millis = start.elapsed().as_secs_f64() * 1000.0;
    let checksum = context.to_number(&value).expect("a checksum");
    (millis, checksum)
}

/// The JavaScript arm: `frames` calls of a JS function over its own array.
/// `jit` installs the JIT the way the client and the server do.
fn run_js(n: u32, frames: u32, jit: bool) -> (f64, f64) {
    let mut context = Context::new().expect("a Slag context");
    if jit {
        slag::install_jit(&mut context).expect("the jit");
    }
    context.eval(HELPERS).expect("the helpers");
    context.eval(JS_KERNEL).expect("the js kernel");

    let setup = format!(
        "var JN = {n}; var JD = {DT}; var JF = new Float32Array(JN * 4);\n\
         initAgents(JF, 0, JN);\n"
    );
    context.eval(&setup).expect("the js setup");
    // Warm-up, then a fresh state to time from.
    context
        .eval(&format!(
            "for (var f = 0; f < {WARMUP}; f++) jstep(JF, 0, JN, JD);"
        ))
        .expect("the js warm-up");
    context
        .eval("initAgents(JF, 0, JN);")
        .expect("the js reset");

    timed(
        &mut context,
        &format!(
            "for (var f = 0; f < {frames}; f++) jstep(JF, 0, JN, JD);\n\
             checksum(JF, 0, JN);"
        ),
    )
}

/// The wasm arm: `frames` calls of the module's exported `bench`, which is one
/// JS-to-wasm crossing per frame. Instantiation is outside the timing -- it is a
/// load cost, not a frame cost. The driver loop runs with the JIT installed, as
/// the client's would.
fn run_wasm(bytes: &[u8], n: u32, frames: u32) -> (f64, f64) {
    let mut context = Context::new().expect("a Slag context");
    slag::install_jit(&mut context).expect("the jit");
    let buffer = context
        .array_buffer_from_bytes(bytes)
        .expect("an ArrayBuffer for the module");
    context
        .set_global("BENCH_BYTES", buffer)
        .expect("set BENCH_BYTES");
    context.eval(HELPERS).expect("the helpers");

    let setup = format!(
        "var WB = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(BENCH_BYTES)), {{}});\n\
         var WP = WB.exports.bench_buffer();\n\
         var WV = new Float32Array(WB.exports.memory.buffer);\n\
         var WBASE = WP / 4;\n\
         var WN = {n}; var WD = {DT};\n\
         initAgents(WV, WBASE, WN);\n"
    );
    context.eval(&setup).expect("the wasm setup");
    context
        .eval(&format!(
            "for (var f = 0; f < {WARMUP}; f++) WB.exports.bench(WP, WN, WD);"
        ))
        .expect("the wasm warm-up");
    context
        .eval("initAgents(WV, WBASE, WN);")
        .expect("the wasm reset");

    timed(
        &mut context,
        &format!(
            "for (var f = 0; f < {frames}; f++) WB.exports.bench(WP, WN, WD);\n\
             checksum(WV, WBASE, WN);"
        ),
    )
}

#[test]
#[ignore = "a timing, not a correctness test: run with --release -- --ignored --nocapture"]
fn js_and_wasm_run_the_same_kernel() {
    let bytes = std::fs::read(bench_path())
        .unwrap_or_else(|error| panic!("read {}: {error}", bench_path().display()));

    println!();
    println!("plugin kernel: one O(n^2) neighbour pass per frame, f64 with f32 storage");
    println!("               (the flock's stepFly shape; js is given its best case)");
    println!("               ns per agent-pair per frame, release build, lower is better");
    println!();
    println!(
        "    n   frames    js interp       js+jit         wasm    wasm/(js+jit)               sum"
    );
    println!(
        "  ---   ------    ---------       ------         ----    -------------               ---"
    );

    for n in SIZES {
        let frames = frames_for(n);
        let pairs = f64::from(frames) * f64::from(n) * f64::from(n);

        let (plain_ms, plain_sum) = run_js(n, frames, false);
        let (jit_ms, jit_sum) = run_js(n, frames, true);
        let (wasm_ms, wasm_sum) = run_wasm(&bytes, n, frames);

        let plain_ns = plain_ms * 1e6 / pairs;
        let jit_ns = jit_ms * 1e6 / pairs;
        let wasm_ns = wasm_ms * 1e6 / pairs;
        let ratio = wasm_ns / jit_ns;

        // Every arm must have computed the same world: same inputs, same
        // arithmetic, same order. A relative tolerance rather than equality, so
        // a codegen-level difference in the last bits (FMA contraction, say) is
        // visible in the printed sums without failing a benchmark on a machine
        // the repository cannot see.
        for (arm, sum) in [("js interp", plain_sum), ("js+jit", jit_sum)] {
            let drift = (sum - wasm_sum).abs() / sum.abs().max(1.0);
            assert!(
                drift < 1e-6,
                "n={n}: {arm} and wasm disagree: {sum} vs {wasm_sum}"
            );
        }

        assert!(
            [plain_ns, jit_ns, wasm_ns]
                .iter()
                .all(|ns| ns.is_finite() && *ns > 0.0),
            "n={n}: a timing is not a number: {plain_ms} / {jit_ms} / {wasm_ms} ms"
        );

        println!(
            "  {n:>3}   {frames:>6}   {plain_ns:>9.2}ns   {jit_ns:>9.2}ns   {wasm_ns:>9.2}ns   {ratio:>11.2}x   {wasm_sum:>17.3}",
        );
    }

    println!();
}

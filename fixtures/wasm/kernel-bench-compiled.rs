// The interpreter arm of the kernel benchmark, and the Rust-hosted call cost.
//
// This file is not part of any build: it belongs to the *slag* workspace, which
// the Goat repository never commits. It is kept here so the figures in
// ROADMAP.md M17 that the Goat-side benchmark cannot produce are reproducible
// rather than folklore.
//
// Since `perf(wasm): run the compiled wasm path by default on native targets`,
// the compiled path is what a native embed gets, and
// `crates/harness/tests/plugin_bench.rs` measures it through the JS API. This
// test is the other side of the boundary: `Store::set_compile(false)` for the
// interpreter -- which is what a wasm32 host would run, and which the JS API
// cannot ask for -- and `Store::invoke` for the per-call cost from Rust rather
// than from JavaScript.
//
// To reproduce:
//
//   1. copy this file to `slag/crates/wasm/tests/kernel_bench.rs`
//   2. from `slag/`:
//        cargo test --release -p wasm --features compile --test kernel_bench -- --nocapture
//   3. delete it again
//
// Both arms print the arena's checksum and the test asserts they are equal, which
// is not a formality now that compiled is the default: two hosts agree on a world
// mod only if the two codegen paths agree.

#![cfg(feature = "compile")]

use std::time::Instant;

use wasm::exec::{ExternVal, Store};
use wasm::values::Value;
use wasm::{decode, validate};

/// The frame counts the Goat-side benchmark used when this was written: the two
/// overlap on 6, 64 and 1024, which is where their checksums are compared.
const SIZES: [(i32, u32); 4] = [(6, 2000), (64, 488), (256, 30), (1024, 5)];
const WARMUP: u32 = 2;

fn dt_bits() -> u64 {
    0.016f64.to_bits()
}

/// The arena's contents, summed in `f32`, so the two code paths can be shown to
/// have produced the same state -- and so this run can be checked against the
/// Goat-side one, which prints the same figure.
fn state_sum(store: &Store, instance: usize, ptr: i32, count: i32) -> f64 {
    let cell = match store.export(instance, "memory") {
        Some(ExternVal::Memory(cell)) => cell,
        _ => panic!("the module should export its memory"),
    };
    let bytes = store.memory_bytes(cell).expect("the memory bytes");
    let mut sum = 0.0f64;
    for i in 0..(count as usize * 4) {
        let offset = ptr as usize + i * 4;
        let word = u32::from_le_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ]);
        sum += f64::from(f32::from_bits(word));
    }
    sum
}

fn run(bytes: &[u8], count: i32, frames: u32, compiled: bool) -> (f64, f64) {
    let module = decode(bytes).expect("decode");
    validate(&module).expect("validate");
    let mut store = Store::new();
    store.set_compile(compiled);
    let mut resolve = |_module: &str, _field: &str| -> Option<ExternVal> { None };
    let instance = store
        .instantiate(&module, &mut resolve)
        .expect("instantiate");

    let seed = store
        .exported_func(instance, "bench_seed")
        .expect("bench_seed");
    let buffer = store
        .exported_func(instance, "bench_buffer")
        .expect("bench_buffer");
    let bench = store.exported_func(instance, "bench").expect("bench");

    store.invoke(instance, seed, &[]).expect("seed");
    let ptr = match store.invoke(instance, buffer, &[]).expect("buffer").first() {
        Some(Value::I32(ptr)) => *ptr,
        other => panic!("bench_buffer returned {other:?}"),
    };

    let args = [Value::I32(ptr), Value::I32(count), Value::F64(dt_bits())];
    for _ in 0..WARMUP {
        store.invoke(instance, bench, &args).expect("warm-up");
    }
    // Back to the seed, so the timed run is exactly `frames` from the initial
    // state -- matching the Goat-side benchmark, whose sums are compared with
    // these.
    store.invoke(instance, seed, &[]).expect("reseed");

    let start = Instant::now();
    for _ in 0..frames {
        store.invoke(instance, bench, &args).expect("bench");
    }
    let millis = start.elapsed().as_secs_f64() * 1000.0;
    (millis, state_sum(&store, instance, ptr, count))
}

#[test]
fn the_kernel_interpreted_against_compiled() {
    let bytes = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../fixtures/wasm/bench.wasm"
    ))
    .expect("read bench.wasm");

    println!();
    println!("plugin kernel, wasm only: ns per agent-pair per frame, lower is better");
    println!();
    println!("    n   frames   interpreter     compiled    compiled/interp              sum");
    println!("  ---   ------   -----------     --------    ---------------              ---");

    for (count, frames) in SIZES {
        let pairs = f64::from(frames) * f64::from(count) * f64::from(count);
        let (interp_ms, interp_sum) = run(&bytes, count, frames, false);
        let (compiled_ms, compiled_sum) = run(&bytes, count, frames, true);

        // If the compiled path were skipping the work, this is what would catch
        // it: the same inputs have to leave the same state.
        assert_eq!(
            interp_sum, compiled_sum,
            "n={count}: the interpreted and compiled runs disagree"
        );

        let interpreted = interp_ms * 1e6 / pairs;
        let compiled = compiled_ms * 1e6 / pairs;
        println!(
            "  {count:>3}   {frames:>6}   {interpreted:>9.2}ns   {compiled:>6.2}ns   {:>13.2}x   {interp_sum:>16.3}",
            interpreted / compiled
        );
    }

    println!();
}

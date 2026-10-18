# Slag's wasm collector keeps the heap in its root set

**Status:** fixed upstream in `0851f8401b06108234f7bbd8c23ca88f01eb1799`
— `fix(gc): bound the wasm stack scan at the stack top`. Reproduced on the
previous revision `c12091cc9b76e21a1bd0953cbc4b2f7f5d1f70e4` (`0.2.0`) and
verified on the fix, 2026-10-18. Affects every
`wasm32-unknown-emscripten` build; native builds are not affected.

**Claim.** On wasm, the collector's conservative stack scan is rooted at the
current frame and bounded by the end of the module's linear memory, not by the
top of the real stack. The dlmalloc heap and static data are therefore inside
the root set. Every heap growth widens the scan; addresses sitting in the heap
keep dead boxes alive; `live` climbs while `swept` stays at zero and the pause
grows with the heap.

The same program on native reclaims normally, which is why this cannot be seen
in the desktop client or in the game's JavaScript.

## Reproduction

A standalone crate — no goats, no Godot, no browser or mods.

`Cargo.toml`:

```toml
[package]
name = "gc-repro"
version = "0.1.0"
edition = "2024"

[dependencies]
slag = { git = "https://github.com/sdgoij/slag", rev = "c12091cc9b76e21a1bd0953cbc4b2f7f5d1f70e4" }
```

`src/main.rs`:

```rust
fn main() {
    let mut context = slag::Context::new().expect("a context");
    // Collect rarely enough to see the heap grow between traces, and often
    // enough to get a handful of lines out of a short run.
    context.set_nursery_threshold(65536);
    context.set_gc_trace(true);
    context
        .eval(
            "function frame(n) {
                 let sink = 0;
                 for (let i = 0; i < n; i++) {
                     const o = { i: i, s: 'abcdef' + i, a: [i, i + 1, i + 2] };
                     sink += o.a[0];
                 }
                 return sink;
             }",
        )
        .expect("the frame function");
    for frame in 0..60 {
        context.eval("frame(20000)").expect("a frame");
        if frame % 10 == 0 {
            eprintln!("frame {frame}");
        }
    }
}
```

The loop allocates and drops four objects per iteration; nothing is retained by
the program. Sixty frames of twenty thousand iterations grow the heap enough to
show the difference.

### Native control

```sh
cargo run --release
```

```
gc-trace minor pause_us=45 live=6797->4751 swept=2046 young=2050 remembered=0 stack_words=1500
gc-trace minor pause_us=40 live=6801->4755 swept=2046 young=2050 remembered=0 stack_words=1500
```

`swept` is non-zero, `live` oscillates around a few thousand, `stack_words` is
the real stack (~1500 words), and the pause is tens of microseconds.

### wasm

```sh
export EMSDK=...            # an activated emsdk
export EM_CONFIG="$EMSDK/.emscripten"
export EM_WORKAROUND_PYTHON_BUG_34780=1
export CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc.bat   # Windows
export EMCC_CFLAGS="-O2 -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=8388608 -sEXIT_RUNTIME=1"
cargo build --release --target wasm32-unknown-emscripten
node target/wasm32-unknown-emscripten/release/gc-repro.js
```

```
gc-trace minor pause_us=560000 live=4168804->4168804 swept=0 young=65601 remembered=0 stack_words=196785793
gc-trace minor pause_us=608430 live=5234990->5234990 swept=0 young=66176 remembered=0 stack_words=247346817
gc-trace minor pause_us=736839 live=5903221->5903221 swept=0 young=68225 remembered=0 stack_words=272625989
```

`live` climbs from ~8k to ~6M, `swept=0`, `stack_words` follows the linear
memory (196M → 272M words), and each collection pauses 560–780 ms.
`ALLOW_MEMORY_GROWTH` is required: without it the linear memory cannot grow and
the scan has nothing to widen over.

### After the fix

The same page with `?gctrace=1` on `0851f84` (reference client, shell):

```
gc-trace minor pause_us=0    live=63623->62784 swept=839   young=1026  stack_words=2624
gc-trace major pause_us=3000 live=62784->45837 swept=16947 young=0     stack_words=2638
gc-trace minor pause_us=1000 live=92321->51833 swept=40488 young=46484 stack_words=2040
gc-trace minor pause_us=1000 live=91746->72216 swept=19530 young=20258 stack_words=1748
```

`swept` is non-zero again, `live` oscillates instead of climbing, the scan is
~2k words instead of hundreds of millions, and pauses are 0–3 ms instead of
0.6–0.8 s. On the machine, the Godot client runs at ~80 fps and the reference
client at ~40 — 2–4× their pre-fix rates.

## Cause

`crates/crux/src/heap.rs` at `c12091c`, the wasm arm of `stack_bounds()`:

```rust
/// wasm32: the shadow stack lives in the module's linear memory (rustc's
/// wasm layout), and wasm has no OS stack API to query. Scan from the
/// current frame to the end of the current memory. The region above the
/// real stack top is the dlmalloc heap and static data that share linear
/// memory; the conservative scan only ever retains (never falsely frees),
/// so the wider region is safe — it just widens retention. See the GC-7
/// note in .notes/gc-plan.md: capturing the module-initial stack pointer
/// would bound the scan to the actual stack.
#[cfg(target_arch = "wasm32")]
fn stack_bounds() -> Option<(usize, usize)> {
    let probe = 0usize;
    let sp = &probe as *const usize as usize;
    let end = core::arch::wasm32::memory_size::<0>().saturating_mul(65536);
    (end > sp).then_some((sp, end))
}
```

The native arms stop at the thread's real stack (Windows
`GetCurrentThreadStackLimits`, Linux `pthread_getattr_np`); that is why the
control run scans 1500 words and sweeps, and the wasm run scans the whole heap.

The collector is a mark-sweep with a conservative stack scan, so it never frees
a box whose address appears as a word in the scanned region. With the heap in
that region, a dead box's own fields, a free list, or any stale word holding
its address marks it live. The result is the `live` climb and `swept=0`, and the
pause is proportional to the memory being scanned.

## The fix

This is what landed in `0851f84`. Bound the wasm scan to the real stack. Capture
the module-initial stack pointer (or the stack top; Emscripten exposes the stack
range, e.g. `__stack_high`, and rustc's wasm layout puts the shadow stack in
linear memory) once at startup and use it as the scan's `high`:

```rust
#[cfg(target_arch = "wasm32")]
fn stack_bounds() -> Option<(usize, usize)> {
    static STACK_HIGH: OnceLock<usize> = OnceLock::new();
    let high = *STACK_HIGH.get_or_init(|| /* module-initial stack top */);
    let probe = 0usize;
    let sp = &probe as *const usize as usize;
    (high > sp).then_some((sp, high))
}
```

With the high bound at the real stack top, the heap is no longer in the root
set, `swept` returns to non-zero, and the pause stops growing with the heap.

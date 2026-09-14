# Plugin ABI fixtures

One ABI, two languages. `c/plugin.c` (clang, `wasm32`, `-nostdlib`, no WASI) and
`rust/src/lib.rs` (`wasm32-unknown-unknown`) implement the same plugin ABI and
must agree on every number they produce.

They exist to test one question before the design is taken further: **can the ABI
be written so that it is not shaped like Rust?** If only the language the host
happens to be written in can target the surface conveniently, the ABI has failed
at the only job the idea exists for -- letting a mod author write in whatever
language they like. A mod author in a third language would hit the same
ambiguities the two fixtures would disagree about.

The specification is [`ABIv1.md`](../../ABIv1.md); the test is
`crates/harness/tests/plugin_abi.rs`; the plan is M17 in
[`ROADMAP.md`](../../ROADMAP.md).

## The artifacts are checked in

`plugin-c.wasm` and `plugin-rust.wasm` are a few hundred bytes each and are
committed, so neither the test nor CI needs a wasm toolchain. They are the only
thing the test reads; the sources are here so the artifacts are reproducible.

`bench.wasm` (`c/bench.c`) is the same idea for the *performance* question: one
O(n^2) neighbour pass per frame, the shape of the `birds` flock's `stepFly`, with
no trigonometry and no imports so it measures compute rather than the host. It is
what `crates/harness/tests/plugin_bench.rs` drives; M17 in `ROADMAP.md` has the
numbers.

`build.sh` rebuilds all three. It needs:

- `clang` with a wasm32 target -- the `wasm-ld` linker ships with LLVM;
- `rustup target add wasm32-unknown-unknown`.

The Rust fixture is detached from the goats workspace (`[workspace]` in its
`Cargo.toml`) because it targets wasm32 while the workspace builds for the host;
it is compiled by `build.sh`, never by `cargo build --workspace`.

## Why these two languages

C is the lingua franca of wasm ABIs and the toolchain most likely to be present
anywhere; it also keeps the fixture honest about needing no runtime, no libc and
no WASI. Rust is the language the host is written in, so it is the one case where
a Rust-shaped ABI would go unnoticed. Two languages with nothing in common but
the specification is the smallest set that can catch that.

## The compiled measurement

`bench.wasm` is also run against the `wasm` crate's Cranelift backend, which no
Goat crate can reach today (no feature pass-through -- M17's upstream
prerequisite). `kernel-bench-compiled.rs` is that throwaway test, kept here so
the compiled figure in `ROADMAP.md` M17 is reproducible rather than folklore.
It belongs to the slag workspace: copy it to
`slag/crates/wasm/tests/kernel_bench.rs`, run
`cargo test --release -p wasm --features compile --test kernel_bench --
--nocapture` from `slag/`, then delete it. The Goat-side benchmark prints the
same state checksum, which is how the two runs are shown to agree.

## Deliberate properties

- **No WASI.** A plugin that tries to open a file does not get policed, it fails
  to link -- the I/O wall of `APIv1.md` section 0 becomes structural.
- **No clock import.** A world mod that cannot read wall time cannot desync.
- **`i32`/`f32`/`f64` only.** No `i64`: the first fixture declared
  `goats_init(seed: i64)` and a JS host rejected the call with "Cannot convert a
  Number to a BigInt". Discovered by running it.
- **One crossing per frame.** The host writes the record array into the module's
  memory, calls `goats_update` once, reads the results back out -- so the
  interpreter's speed applies to the inner loop, not to every entity.

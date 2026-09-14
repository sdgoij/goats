#!/bin/sh
# Rebuild the two plugin-ABI fixtures.
#
# The `.wasm` artifacts are checked in, so the test and CI need no wasm
# toolchain at all; this script is only how they are regenerated when the ABI or
# a fixture changes. Re-run it, then re-run the test.
#
# Needs: clang with a wasm32 target (ships with LLVM; `wasm-ld` comes with it),
# and `rustup target add wasm32-unknown-unknown`.
set -e
cd "$(dirname "$0")"

echo "== plugin-c.wasm =="
clang \
  --target=wasm32 \
  -nostdlib \
  -O2 \
  -Wl,--no-entry \
  -Wl,--export-memory \
  -o plugin-c.wasm \
  c/plugin.c

echo "== bench.wasm =="
clang \
  --target=wasm32 \
  -nostdlib \
  -O2 \
  -Wl,--no-entry \
  -Wl,--export-memory \
  -o bench.wasm \
  c/bench.c

echo "== plugin-rust.wasm =="
cd rust
cargo build --release --target wasm32-unknown-unknown
cd ..
cp rust/target/wasm32-unknown-unknown/release/plugin_rust.wasm plugin-rust.wasm

ls -l plugin-c.wasm plugin-rust.wasm bench.wasm

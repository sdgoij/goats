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

echo "== mods/wasm/plugin.wasm =="
clang \
  --target=wasm32 \
  -nostdlib \
  -O2 \
  -Wl,--no-entry \
  -Wl,--export-memory \
  -o ../../mods/wasm/plugin.wasm \
  c/mod.c

# The same source with the client-side visual surface (goats.belly / goats_hud)
# compiled out, so the world-mod tests have a module that links under a host that
# does not grant the client-only `belly` import.
echo "== world.wasm (no client HUD) =="
clang \
  --target=wasm32 \
  -nostdlib \
  -O2 \
  -DWANT_HUD=0 \
  -Wl,--no-entry \
  -Wl,--export-memory \
  -o world.wasm \
  c/mod.c

# The same module built against a future ABI, so the host's version refusal has
# something real to refuse.
echo "== mod-abi2.wasm =="
clang \
  --target=wasm32 \
  -nostdlib \
  -O2 \
  -DABI_VERSION=2 \
  -Wl,--no-entry \
  -Wl,--export-memory \
  -o mod-abi2.wasm \
  c/mod.c

echo "== plugin-rust.wasm =="
cd rust
cargo build --release --target wasm32-unknown-unknown
cd ..
cp rust/target/wasm32-unknown-unknown/release/plugin_rust.wasm plugin-rust.wasm

ls -l plugin-c.wasm plugin-rust.wasm bench.wasm mod-abi2.wasm world.wasm ../../mods/wasm/plugin.wasm

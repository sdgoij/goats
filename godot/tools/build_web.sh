#!/usr/bin/env sh
#
# Build the GDExtension for the browser (Emscripten) and put the side module where
# the descriptor loads it (`godot/WEB.md`).
#
#   godot/tools/build_web.sh            # release (the only profile a page ships)
#
# Needs emsdk active ('. <emsdk>/emsdk_env.sh') and a nightly toolchain with
# `rust-src`: gdext's wasm support is behind `experimental-wasm` (the `web`
# feature on `crates/godot`), and the link flags below are `-Z` ones. Set
# `WEB_TOOLCHAIN` to pin a dated nightly (CI does); the default is `nightly`.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
godot_dir=$root/godot
target=wasm32-unknown-emscripten
lib=goats_godot.wasm
toolchain=${WEB_TOOLCHAIN:-nightly}

if [ -z "${EMSDK:-}" ] && [ -z "${EMSCRIPTEN:-}" ]; then
    echo "build_web.sh: activate emsdk first -- '. <emsdk>/emsdk_env.sh'" >&2
    exit 1
fi

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) linker=emcc.bat ;;
    *) linker=emcc ;;
esac

# Emscripten's `.bat` wrapper documents this: rustc's inherited stdin can hang
# python.exe on Windows (Python bug 34780). The wrapper's opt-in workaround is
# what makes a cargo-driven emcc link return at all.
export EM_WORKAROUND_PYTHON_BUG_34780=1
export CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=$linker

# The flags a Godot web extension needs:
#
# - `panic=abort` keeps `_Unwind_*` and the `__cpp_exception` wasm-EH tag out of
#   the module. Godot cannot import that tag, and a module that names it fails
#   at `WebAssembly.instantiate` before anything runs.
# - `SIDE_MODULE=2` is how Godot loads an extension: the main module is the
#   engine, and this one is linked beside it.
# - `default-visibility=hidden` keeps this extension's symbols private; two Rust
#   extensions in one game would otherwise merge globals.
export RUSTFLAGS="-C panic=abort -C link-args=-sSIDE_MODULE=2 -C llvm-args=-enable-emscripten-cxx-exceptions=0 -Z default-visibility=hidden -Z link-native-libraries=no"

echo "build_web.sh: $target -> $lib ($toolchain)"
cargo "+$toolchain" build -Zbuild-std --release --target "$target" \
    --manifest-path "$root/Cargo.toml" -p goats-godot --features web

src=$root/target/$target/release/$lib
dest=$godot_dir/addons/goats_godot/bin/web

if [ ! -f "$src" ]; then
    echo "build_web.sh: expected the module at $src" >&2
    exit 1
fi

mkdir -p "$dest"
cp "$src" "$dest/"
echo "build_web.sh: copied $target/release/$lib -> addons/goats_godot/bin/web/"

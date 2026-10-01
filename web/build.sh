#!/usr/bin/env bash
#
# The browser build (WASM.md W0). One command, from a checkout, to a directory a
# static server can hand out.
#
# Emscripten is the linker: `cargo build --target wasm32-unknown-emscripten` ends
# in `emcc`, and raylib's cmake configure runs under `emcmake`. That is why
# `emsdk` has to be active, and why the fork's `build.rs` names those two on
# Windows, where the SDK ships `emcc.bat`/`emcmake.bat` and a bare
# `Command::new("emcmake")` is not found (WASM.md, "The build, concretely").
#
# Usage: web/build.sh [check | client [profile] | serve]     (default: client)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$HERE/dist"
TARGET=wasm32-unknown-emscripten

# ---- emsdk, and the two variables it does not set for us --------------------
# The gate is the SDK variable, not `emcc`: the fork's `build.rs` reads exactly
# this one and refuses a wasm build without it, and on Windows `command -v emcc`
# is not a usable probe anyway -- the SDK ships only `emcc.bat`, which Git Bash's
# `command -v` will not resolve from a bare name.
if [ -n "${EMSCRIPTEN:-}" ]; then
    EMSCRIPTEN_DIR="$EMSCRIPTEN"
elif [ -n "${EMSDK:-}" ]; then
    # The SDK's own layout. `em-config` would find this, but it is not part of
    # every emsdk build -- this one ships only the `.bat`/`.py` wrappers.
    EMSCRIPTEN_DIR="$EMSDK/upstream/emscripten"
else
    echo "web: activate emsdk first -- '. <emsdk>/emsdk_env.sh'" >&2
    exit 1
fi

SYSROOT="$EMSCRIPTEN_DIR/cache/sysroot"

# `raylib-sys` *requires* this for a wasm target and panics without it, so it is
# not optional. The rest is this project's:
#
# - `MIN/MAX_WEBGL_VERSION=2` -- WebGL 2 is the context, for the reason the
#   phone settled on ES 3.0: the scene's fourteen `#version 330` programs all
#   fail soft, and the dialect layer already emits `300 es` (WASM.md section 3).
#   raylib's own CMakeLists carries these two for the app it links, but the
#   client does its own link, so they have to be here as well -- without them the
#   browser hands out WebGL 1 and every shader fails with "unsupported shader
#   version 300".
# - `FULL_ES3` is the same request one level down: the ES3-only entry points
#   (core VAOs, instancing) that rlgl's ES3 path calls.
# - `EXPORTED_RUNTIME_METHODS` -- raylib's own CMakeLists names `ccall`, and the
#   web backend also reaches for `Module.requestFullscreen` through the JS glue;
#   without it the module aborts with "'requestFullscreen' was not exported".
# - `STACK_SIZE` is not optional: Emscripten's default is 64 KiB and the engine
#   overflows it inside `Context::new`, before the first script runs.
# - `ALLOW_MEMORY_GROWTH` is for a heap that is a JS engine's.
#
# Deliberately *not* here: `-sASYNCIFY`. The blocking `run()` loop yields with
# `emscripten_sleep`, which needs async support, so ASYNCIFY is the quick way to
# legalise it -- but this emsdk's binaryen fails the `--asyncify` wasm-opt pass on
# this Rust's output (the problem upstream's `fix/emsdk-binaryen-121-for-rust188`
# branch names), and the plan wants D3's `emscripten_set_main_loop_arg` callback
# anyway: no async instrumentation at all.
export EMCC_CFLAGS="${EMCC_CFLAGS:--O3 -sUSE_GLFW=3 -sASSERTIONS=1 -sWASM=1 -sGL_ENABLE_GET_PROC_ADDRESS=1 -sEXPORTED_RUNTIME_METHODS=ccall,requestFullscreen -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 -sSTACK_SIZE=8388608 -sALLOW_MEMORY_GROWTH=1}"

# bindgen has to be told the target's sysroot or `math.h` is not found at all --
# the same note ANDROID.md carries for the NDK's headers.
export BINDGEN_EXTRA_CLANG_ARGS="${BINDGEN_EXTRA_CLANG_ARGS:---target=$TARGET --sysroot=$SYSROOT}"

case "${1:-client}" in
    check)
        echo "web: emscripten  $EMSCRIPTEN_DIR"
        echo "web: sysroot     $SYSROOT"
        [ -d "$SYSROOT" ] || { echo "web: no sysroot there" >&2; exit 1; }
        echo "web: EMCC_CFLAGS $EMCC_CFLAGS"
        cargo metadata --format-version 1 >/dev/null
        echo "web: cargo resolves the workspace"
        ;;
    client)
        PROFILE="${2:-release}"
        cargo build --profile "$PROFILE" -p goats --target "$TARGET"

        # A static directory: the page, the glue and the module. `goats.js` is
        # what Emscripten emits beside the `.wasm` when the target links.
        mkdir -p "$DIST"
        cp "$ROOT/target/$TARGET/$PROFILE/goats.js" "$DIST/"
        cp "$ROOT/target/$TARGET/$PROFILE/goats.wasm" "$DIST/"
        cp "$HERE/index.html" "$DIST/"
        echo "web: staged in $DIST"
        echo "web: serve it with:  web/build.sh serve"
        ;;
    serve)
        # A plain static host is enough while the build is single-threaded: no
        # `SharedArrayBuffer`, so no COOP/COEP headers (WASM.md section 5).
        echo "web: http://localhost:8000/   (Ctrl-C to stop)"
        python -m http.server 8000 --directory "$DIST"
        ;;
    *)
        echo "web: usage: $(basename "$0") [check | client [profile] | serve]" >&2
        exit 2
        ;;
esac

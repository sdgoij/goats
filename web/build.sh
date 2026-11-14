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
# Usage: web/build.sh [check | client [profile] | serve | smoke]  (default: client)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$HERE/dist"
TARGET=wasm32-unknown-emscripten

# `smoke` drives an already-built `dist` over the DevTools protocol, so it needs
# Node and a browser, not emsdk. Hand it off before the SDK check below.
if [ "${1:-client}" = "smoke" ]; then
    exec node "$HERE/smoke.js"
fi

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
export EMCC_CFLAGS="${EMCC_CFLAGS:--O3 -sUSE_GLFW=3 -sWASM=1 -sGL_ENABLE_GET_PROC_ADDRESS=1 -sEXPORTED_RUNTIME_METHODS=ccall,requestFullscreen,FS -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 -sSTACK_SIZE=8388608 -sALLOW_MEMORY_GROWTH=1 -sFORCE_FILESYSTEM=1}"

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
        # The repository's mods ride into the virtual filesystem at `/mods`, which
        # is the directory `resolve_mods_dir` looks for -- so the browser client
        # discovers birds, fatguy and the rest exactly as the desktop binary does.
        # A preload is a *link* argument, not a compile one: `RUSTFLAGS` is what
        # makes rustc hand it to emcc for the final module, and changing it here
        # is also what makes a rebuild pick up an edited mod.
        if command -v cygpath >/dev/null 2>&1; then
            mods_src="$(cygpath -m "$ROOT/mods")"
        else
            mods_src="$ROOT/mods"
        fi
        export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=--preload-file=$mods_src@/mods"
        cargo build --profile "$PROFILE" -p goats --target "$TARGET"

        # A static directory: the page, the glue and the module. `goats.js` is
        # what Emscripten emits beside the `.wasm` when the target links, and
        # `goats.data` is the preloaded filesystem when there is one.
        mkdir -p "$DIST"
        cp "$ROOT/target/$TARGET/$PROFILE/goats.js" "$DIST/"
        cp "$ROOT/target/$TARGET/$PROFILE/goats.wasm" "$DIST/"
        # The preloaded filesystem. Emscripten names this side file after the
        # linker's *output*, and where that output lands is rustc's decision, not
        # ours -- it moved between toolchains with no change in this repository.
        # 1.99 links in `deps/` and leaves `deps/goats.data` beside the objects;
        # 1.100 links into a `build/` scratch directory
        # (`build/goats/<hash>/out/goats.js`) and uplifts only the `.js` and
        # `.wasm` to the profile root, abandoning `goats.data` back in there.
        # Neither place is a name to hard-code, so collect every `.data` the link
        # could have left and take the newest. A missing one is a real failure
        # (the client would boot with no mods), so it says what it did see.
        plain="$ROOT/target/$TARGET/$PROFILE"
        data=""
        newest_data() {
            for candidate in "$@"; do
                [ -f "$candidate" ] || continue
                if [ -z "$data" ] || [ "$candidate" -nt "$data" ]; then
                    data="$candidate"
                fi
            done
        }
        newest_data "$plain/goats.data" "$plain"/deps/*.data "$plain"/build/goats/*/out/goats.data
        # Last resort before giving up: anywhere under the profile, in case a
        # later toolchain moves the link again.
        if [ -z "$data" ]; then
            newest_data $(find "$plain" -name '*.data' -type f 2>/dev/null)
        fi
        if [ -n "$data" ]; then
            cp "$data" "$DIST/goats.data"
            echo "web: preloaded ${data#"$plain"/} -> goats.data"
        else
            rm -f "$DIST/goats.data"
            echo "web: warning: no goats.data: the link preloaded nothing" >&2
            echo "web: what the link left behind in ${plain#"$ROOT"/}:" >&2
            find "$plain" \( -name 'goats*' -o -name '*.data' \) -print 2>/dev/null \
                | sed 's|^|web:   |' >&2 || true
        fi
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
        echo "web: usage: $(basename "$0") [check | client [profile] | serve | smoke]" >&2
        exit 2
        ;;
esac

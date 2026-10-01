# The browser client (WebAssembly)

A proposal for running the *client* (`crates/goats`) in a browser tab, the way
`crates/android` runs it on a phone. `goatsd` is out of scope for the reason
`ANDROID.md` gives -- a headless host needs no window, and a browser tab is a
worse server than the machine already hosting one -- and so is anything that
needs a peer-to-peer socket (see Non-goals).

The short version: **the graphics half is closer than Android's was, and the
host half is further.** raylib's raster is Emscripten-native, and the in-tree
`raylib-sys` the workspace already patches to has a `Platform::Web` arm that
cmake-builds raylib for `wasm32-unknown-emscripten`, links Emscripten's GLFW and
can be asked for the same `#version 300 es` dialect the phone needed. The scene
is JavaScript that already runs with no window (M15) and draws through one `rl`
surface that three implementations already replace. What is *not* close is the
Rust host wrapped around it: `run()` reads `env::args()`, drains stdin on a
thread, starts an `iroh` runtime on another, opens a microphone and watches
`mods/` with inotify, and a tab has none of those. And the scene runs on *Slag*,
whose JS path is a JIT -- and a wasm sandbox cannot execute generated machine
code. That last one is the least feared of the three: the engine already ships a
wasm embedding (`crates/slag/examples/wasm_binding`, with a live demo in
`slag/docs/`) and states the rule in its own source -- *a wasm embed must run the
interpreter* (`wasm/src/lib.rs:13-16`).

| Layer | State | Cost |
| --- | --- | --- |
| Raster | `Platform::Web` in the patched `raylib-sys`, and the GLSL dialect layer (Android D2) already emits `300 es` | done -- raylib builds, links and runs for wasm; the one link repair was a GLVND name (`web/build.sh raylib`) |
| Host | `run()` is a blocking loop around three platform services a tab does not have | the real work |
| Engine | Slag builds, links and runs under Emscripten (the engine's own demo, and `web/build.sh probe`, green); its JIT is RWX and cannot exist in the sandbox | drop `jit`, run the interpreter; the frame cost is risk 1 |
| Networking, voice | `iroh` is QUIC over UDP; `cpal` has no wasm host | out of scope for the first browser build |

## Non-goals

- **The server.** `crates/server` stays desktop, and stays the thing you host on.
- **A networked browser client.** `iroh` needs a UDP socket, and nothing in a
  browser exposes one. A tab that joins a session needs a relay or a
  WebTransport/WebSocket bridge in front of `goatsd` -- a milestone of its own,
  not a line in this one.
- **Voice.** `cpal` has no wasm host; capture would be `getUserMedia` and an
  `AudioWorklet`, and `libopus_sys` would need a wasm libopus. Playback is a
  different story and stays.
- **Touch-first or desktop-first.** The page is the same build either way;
  `touch.js` already exists and the web backend already reports touch, so a
  phone browser is a case to check, not a port to write.
- **A second scene.** The 12.8k lines in `crates/goats/src/game/` are the game on
  every target. The port is at the two seams that only exist when there is a
  browser: the host and the `rl` implementation behind it.

## What already exists

Verified against the vendored `raylib-sys 6.0.0` in `android/build/raylib-sys/`
-- the same crate the workspace `[patch]`es to, so a web build uses it too.

| Thing | Where | What it gives us |
| --- | --- | --- |
| A web build path for raylib | `raylib-sys/build.rs:649-655` (`target.contains("wasm")` -> `Platform::Web`), `:207` (`PLATFORM=Web`), `:305-308` (copies `libraylib.bc` to `libraylib.a`) | cmake builds raylib's own `PLATFORM_WEB`; the Emscripten bitcode archive is what links |
| The Emscripten link flags | `raylib/src/CMakeLists.txt:70-76` | `-sUSE_GLFW=3`, `-sEXPORTED_RUNTIME_METHODS=ccall`, and for the ES3 build `-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2` |
| A WebGL 2 (ES3) raster | `raylib/cmake/LibraryConfigurations.cmake:70-75` and `:196-213`; `rcore_web_emscripten.c:1214-1224` | `OPENGL_VERSION="ES 3.0"` maps to `GRAPHICS_API_OPENGL_ES3`, which the backend turns into a WebGL 2.0 context -- the same feature the phone uses, `opengl_es_30` |
| The loop shape the client already has | `rcore_web_emscripten.c:131-145` | `WindowShouldClose()` returns false and sleeps for the browser under ASYNCIFY; its comment names the two supported shapes, and the scene already calls it once a frame (`goat.js:504-505`) |
| Touch | `rcore_web_emscripten.c:1668-1750` | multi-touch with stable identifiers, and a single touch feeds the mouse exactly as Android's does -- so `touch.js` and the P1 device pass transfer |
| The clipboard | `rcore_web_emscripten.c:775-881` | `SetClipboardText`/`GetClipboardText` are *implemented* (on Android they are stubs) |
| Embedded assets | `ASSETS` (`lib.rs:62-159`) and `register_raylib_asset` | the model and every sound are `include_bytes!`, so a web build ships them in the wasm data segment as the phone ships them in the `.so` |
| An embedder-defined JS surface | `Context::register_fn` (the M17 seam) | the client can install a `web` global the way it installs `android` (D1) |
| The dialect layer | Android D2; `crates/harness/tests/es3.rs` | `glsl()`/`loadGlsl` already produce `300 es`, which is what a WebGL 2 context wants -- no new shader work |
| The scene without a window | M15 (`crates/harness`) | the whole scene already runs with no raylib at all, so the port is not a scene port |
| Slag on wasm | `crates/slag/examples/wasm_binding/` -- its own doc: `cargo build -p slag --example wasm_binding --target wasm32-unknown-unknown --release` | the engine compiles to wasm with no wasm-bindgen, exports a C ABI (`slag_alloc`/`slag_dealloc`, `slag_eval`, `slag_drain`, `slag_next_timeout_ms`, `slag_reset`, the `slag_result_*` trio) and instantiates from a page; `slag/docs/` is the working demo, and `web/build.sh probe` is the same engine on `wasm32-unknown-emscripten` -- green |
| The engine already anticipates Emscripten | `runtime/src/time.rs:10-13` (std clocks when `target_os = "emscripten"`, so *no* `env` clock imports there), `crux/src/heap.rs:1594-1600` (a wasm32 stack-bounds arm) | the target this port needs is branched on in the engine, not only the bare `wasm32-unknown-unknown` the demo builds |
| The interpreter-only rule, written down | `wasm/src/lib.rs:13-16` (`compile_error!`: "a wasm embed must run the interpreter"); `slag/src/lib.rs:31-32` (`install_jit` exists only with `jit`); `jit/src/code_buffer.rs:5-28` (RWX via `region`) | the one engine change the client needs -- drop `jit` for wasm -- is a feature the engine already leaves optional and off by default |
| A DOM host, in the engine | `examples/wasm_binding/dom.rs` (property get/set, by-id, create/append, classes, `addEventListener`, `dataset`, `copy_text`, `localStorage`) | the precedent for D1's `web` surface, and `storage_get`/`storage_set` is the persistence gap's answer |
| raylib builds for Web | `web/build.sh raylib` -- green (2026-09-29) | `PLATFORM=Web` with `GRAPHICS_API_OPENGL_ES3`, `libraylib.a` linked into a wasm module that *runs*: the raster question is settled rather than hoped |

## The gaps

### 1. Host and the frame loop

`run()` (`lib.rs:572`) is four desktop services around a frame loop:

- **Arguments and stdin.** `parse_args(env::args())` (`:573`) and the stdin
  reader thread (`:779-794`). A tab has neither; a command comes from the DOM,
  or from the scene's own in-game console (`console.js`), which is already the
  path the phone uses.
- **The mods directory and its watcher.** `resolve_mods_dir` and
  `Loader::discover` (`:589-608`) read `mods/`; `ModWatcher` (`:616-635`,
  `:945-966`) needs inotify. Emscripten gives a real POSIX-shaped virtual FS, so
  a *preloaded* `mods/` works unchanged, but a watcher has nothing to watch
  (D6).
- **Networking and voice.** `Net::start` (`:823`) spawns a thread and builds a
  multi-threaded tokio runtime (`net.rs:263-286`), and `Voice::start` (`:830`)
  opens cpal (`audio.rs:481-526`). Both are compiled out for the browser (D4).
- **The loop itself.** This is the one piece that is *almost* already right, and
  it is worth being precise about why. The scene is frame-shaped by
  construction: `sceneInit`/`sceneFrame`/`sceneShutdown` (`goat.js:477-1018`),
  with `sceneFrame` ending in `rl.endDrawing()` and starting in
  `rl.windowShouldClose()` -- which on web is the backend's `emscripten_sleep`
  yield point. So the *scene* is web-shaped today; it is the Rust wrapper that
  interleaves stdin and networking around it that is not. raylib's own comment
  (`rcore_web_emscripten.c:136-138`) names the two ways to wrap it, and D3 picks
  one.

### 2. The engine on wasm

The scene does not run on the browser's JavaScript engine; it runs on **Slag** --
and Slag in a browser is not a hypothesis. The engine already ships a wasm
embedding: `crates/slag/examples/wasm_binding` builds for
`wasm32-unknown-unknown` with no wasm-bindgen, exports a C ABI (`slag_eval`,
`slag_drain`, `slag_next_timeout_ms`, `slag_alloc`, the `slag_result_*` trio) and
is driven by the page in `slag/docs/`. So the *shape* -- an engine instance in a
wasm module, with a JS host on the other side -- is proven, and two things in the
engine point at the target this port needs specifically: the clock falls back to
`std::time` whenever `target_os = "emscripten"` (`runtime/src/time.rs:10-13`; the
`env.slag_host_now_*` imports are for the bare target only), and the heap has a
`wasm32` stack-bounds arm (`crux/src/heap.rs:1594-1600`). Neither the demo nor
those arms *are* the Emscripten link -- W0 is where that gets its answer -- but
the plan no longer has to assume it.

What the engine does rule out, it rules out explicitly. The JIT's code buffer is
read-write-execute memory (`jit/src/code_buffer.rs:5-28`, via `region`), which a
wasm sandbox does not grant, and the engine says as much in its own source: the
wasm-body compile path carries a `compile_error!` reading "a wasm embed must run
the interpreter" (`wasm/src/lib.rs:13-16`). `install_jit` itself exists only when
the `jit` feature is on (`slag/src/lib.rs:31-32`), and the feature is optional and
off by default (`slag/Cargo.toml:27-29`). So the client's one engine change is a
target-specific `slag` dependency that does not name `jit` -- the same shape
`crates/goats/Cargo.toml:63-66` already uses to give Android its own `raylib-sys`
-- and the unconditional `install_jit(...).unwrap()` at `lib.rs:660` becomes
conditional. Naming `jit` on `wasm32` is not merely useless, it would not build:
the JIT's `region` dependency has no wasm32 backend, which is the engine's own
stated reason for the interpreter-only rule.

The performance question is the real one, and none of the above touches it. The
engine's frame on the *JIT* is already ~7.5 ms against ~0.47 ms on Node (ROADMAP
open question 21); a browser running the same scene on the *interpreter inside
wasm* is the worst case of both worlds, and it is the reason D2's alternative --
let the browser's own, heavily optimised JS engine run the scene -- is a real
option rather than a heresy.

### 3. Raster

WebGL 2 is the target, for the reason the phone settled on ES 3.0: every one of
the scene's fourteen `#version 330` programs is custom, they all fail soft, and
the dialect layer already emits `300 es`. WebGL 1 / ES 2 is not a floor worth
landing on. Three things to check rather than assume:

- **The ES3 link line -- answered.** `opengl_es_30` emits `-lGLESv2` and, for a
  non-Android target, `-lGLdispatch` (`build.rs:178-191`). Emscripten's sysroot
  has a stub for the first and none for the second: `-lGLESv2` and `-lglfw`
  resolve, and `-lGLdispatch` fails with `wasm-ld: error: unable to find library
  -lGLdispatch` (`web/build.sh raylib` reports all three). The fix is therefore
  the one Android already made, widened: the gate at `build.rs:188-190` says
  *not Android* today and has to say *not Android and not wasm*. No new name, no
  new repair.
- **`SUPPORT_GPU_SKINNING`.** Android turns `gpu-skinning` *off* because GLES 2
  has eight vertex attribute slots and the skinned programs want nine. WebGL 2
  has sixteen, so the browser should be able to keep it -- but that is a W0
  measurement, not an assumption.
- **Timing.** The web `GetTime` returns `emscripten_get_now()*1000`
  (`rcore_web_emscripten.c:963-968`), which reads as microseconds where the
  desktop returns seconds. The scene's cadence comes from `getFrameTime` and
  `setTargetFPS`, so this is a thing to look at on the first page, not to
  reason about from the source.

### 4. Input, the console and the clipboard

- **The keyboard, and the character queue.** The web backend's
  `EmscriptenKeyboardCallback` fills `currentKeyState` but leaves the character
  queue *commented out*, under a `TODO` (`rcore_web_emscripten.c:1469-1479`).
  This is the same symptom the phone had -- a console that shows nothing while
  you type -- but a much cheaper cause: where Android's NDK exposed no
  key-to-character call at all (ANDROID.md §3), here the event carries the
  character and the fix is in the fork's C. Until it lands, the console is
  read-only. **Risk 3.**
- **Touch** is already wired, with stable identifiers, so `touch.js` and the
  Android P1 pass transfer to a phone browser; the single-touch-feeds-the-mouse
  behaviour (and therefore the "the overlay has to take the pointer away from
  the camera" rule) is the same.
- **The clipboard** is implemented, where Android's was a stub. But the DOM's
  clipboard APIs are asynchronous and permission-gated, so a synchronous
  `GetClipboardText` is the thing to check -- `copy` reads the ticket back
  immediately.

### 5. The rest, briefly

- **Networking** is the one thing the port cannot carry. `session`'s transport is
  `iroh`, which is QUIC over UDP; no browser API opens a UDP socket, and iroh
  does not target wasm. So `net.rs` compiles out entirely and the browser build
  is single-player (D4). Everything downstream goes with it: chat, the roster,
  the world snapshot, mod sync (M18) and the host status page.
- **Voice** is the other. Playback is fine -- raylib's web audio is miniaudio
  over WebAudio, which just needs a user gesture to unlock the `AudioContext` --
  but capture has no host.
- **Threads.** Emscripten threads need `-pthread`, `SharedArrayBuffer` and the
  COOP/COEP headers, which rules out a plain static host. Every thread the client
  spawns is one a tab does not want -- stdin, the net runtime, `notify`, cpal's
  callback -- so if all four are compiled out, the browser build is
  single-threaded and needs no isolation headers. That is the shape to aim for.
- **Mods and the filesystem.** The loader is pure Rust over paths, and
  Emscripten's virtual FS is POSIX-shaped, so a preloaded `mods/` works
  unchanged (D6). A mod the player *adds* is a file-picker or fetch problem,
  exactly as it is on the phone (ANDROID.md risk 7).
- **Persistence.** No XDG/`%APPDATA%`; localStorage or IndexedDB. The netplay
  secret key (M10, cross-cutting "Persistence") is moot while networking is out.
- **Size.** The GLB (4.8 MB) and the Ogg beds (3.6 MB) are `include_bytes!` data
  segments beside raylib, the interpreter and the scene. A first `.wasm` will be
  tens of megabytes uncompressed, and brotli plus `-Os` are the levers. It is a
  number to watch, not a blocker -- but it is the number a browser punishes that
  a download does not.

## Decisions

**D1 -- The web surface lives in the client, not in Slag.** The same shape as
ANDROID.md D1: a `web` global installed with `Context::register_fn` only when
`cfg(target_arch = "wasm32")`, carrying what the DOM gives and raylib's surface
does not -- the first user gesture that unlocks the `AudioContext`, a text-input
bridge for the console (the precedent is P2's `android.takeTyped()`), a
fullscreen/pointer-lock request, and the "the player dropped this mod in" fetch.
The scene guards on absence (`typeof web === "object"`), so the desktop, the
server and the harness are untouched. The engine already has such a surface to
copy from: `examples/wasm_binding/dom.rs` is a full DOM host behind a
`slag_host_has_dom()` switch, and it is deliberately an *example*, outside
`crates/runtime` -- the same reasoning, that a platform surface is the
embedder's, not the engine's.

**D2 -- The scene runs on Slag in wasm.** The tempting alternative is to let the
browser's own JS engine run the scene, since the scene *is* JavaScript and the
`rl` surface is already an interface with three implementations. It would delete
the engine port, delete the interpreter's cost, and be dramatically faster. It
is not taken, for three reasons: the mod system (M17) is built on the engine's
`WebAssembly` global and its embedder surface; the harness's parity with the
client is the thing that keeps the two from simulating different games, and a
new `rl` implementation in JS would be a second one to keep in step; and
`install_raylib` is real marshalling of raylib's structs, which a browser `rl`
would have to reimplement against the wasm module's exports. Keeping Slag is the
choice that preserves one scene, one engine and one harness. It is also the
largest cost in the plan (risk 1), and if the interpreter proves too slow, the
alternative is where the port goes -- and the *scene* does not change either way,
which is what makes the alternative a fallback rather than a rewrite. The
engine's own demo is worth noting for that fallback: it already runs a Slag
instance from a page, so half of the alternative's host exists; what it does not
do is put raylib beside it.

**D3 -- The loop is a frame callback, not a synchronous loop under ASYNCIFY.**
raylib's web backend documents both (`rcore_web_emscripten.c:131-145`): the
client's `loop` would stand almost unchanged under `-sASYNCIFY`, or a
`UpdateDrawFrame`-shaped callback registered with `emscripten_set_main_loop`.
ASYNCIFY buys that by instrumenting every function in the module -- raylib, the
interpreter, all of Rust -- in size and speed, to save restructuring one
function; and the host already has the callback shape one level down. So the
wasm path registers a frame entry with `emscripten_set_main_loop_arg` and
returns, and `sceneFrame`'s `false` calls `emscripten_cancel_main_loop`.
`WindowShouldClose`'s `emscripten_sleep(12)` then becomes a no-op and
`requestAnimationFrame` is the cadence. `-sASYNCIFY` is the fallback if some
startup step turns out to need a blocking wait.

**D4 -- Networking and voice are compiled out.** Not deferred with a stub that
half-works: `net.rs` and the capture half of `audio.rs` are behind
`cfg(not(target_arch = "wasm32"))`, because an `iroh` runtime and a cpal stream
have no wasm implementation to construct. The scene already guards both --
`net.js` against a missing bridge, `audio.js` against a missing capture -- so the
browser build is a coherent single-player game rather than a networked one with
holes. Playback stays.

**D5 -- The dialect is the ES3 one.** WebGL 2 is the context, so
`setGlslDialect(true)` -- today under `cfg(target_os = "android")`
(`lib.rs:796-812`) -- extends to the wasm target. One scene, three dialects:
`330` on the desktop, `300 es` on the phone and in the browser.

**D6 -- The mods directory is preloaded, not special-cased.** `--preload-file
mods` puts the directory in Emscripten's virtual FS, and the loader reads it
exactly as it reads the desktop's, so the release's two example mods load and one
loader is kept rather than a browser-only asset path. `--watch` and a *fetched*
world mod stay desktop concerns (the latter goes out with networking, D4).

**D7 -- Shipping is a static directory and a `web` job.** Unlike Android, this
needs no entry crate: raylib's Android backend calls a C-ABI `main`, which is why
the phone build is a `cdylib` in `crates/android`, but Emscripten's runtime calls
the program's `main` directly, so the client's own `bin` is the entry for
`wasm32-unknown-emscripten`. The artifact is an `index.html` shell (raylib's
`shell.html`, whose canvas id must match what `platform.canvasId` expects), the
generated `.js`, the `.wasm` and the preloaded `mods/`; the CI job mirrors
`android`'s and uploads `goats-web.zip`.

## Slices

Each slice ends somewhere observable in a tab.

**W0 -- Pixels.** The `.wasm` and a canvas: raylib initializes, the goat GLB
loads with its 14 clips, the terrain and water meshes upload, and the frame loop
runs. This is the slice that settles the two open questions -- does Slag build
for wasm and run the scene on its interpreter (risk 1), and does the ES3 link
line come together (risk 2) -- and if risk 1 fails, this is where the port
changes shape into D2's alternative. The unit is `web/` (the shell and the build
script), the `cfg(target_arch = "wasm32")` host path, and whatever `raylib-sys`
or Slag needs.

Half of that is already done, and `web/` is where it lives. `web/build.sh probe`
builds the engine for `wasm32-unknown-emscripten`, links it through `emcc`, and
runs its own self-test under Node -- **`wasm-probe: ok`** (2026-09-29). The link
is clean, which is evidence in itself: the Emscripten path needs none of the
`env.slag_host_now_*` imports the bare target does (`time.rs:10-13`). Two things
it cost, both now in "The build, concretely": Emscripten's 64 KiB default stack
overflows in `Context::new`, and `cargo run` cannot execute the generated `.js`
on Windows. So risk 1 is answered at the level of *does it build and run*, and
what W0 still owns is the client beside raylib -- the interpreter's frame cost,
the client's `cfg(target_arch = "wasm32")` host path, and one line of fork.

The raylib half is `web/build.sh raylib`, and it is green: raylib's cmake
configures for `PLATFORM=Web`, the ES3 build compiles, the module links, and it
runs -- `wasm-probe-raylib: raylib linked and ran` (2026-09-29). It cost three
things, none of them in the client: the link line's one missing name
(`-lGLdispatch`, the GLVND library Android already had gated off); two
build-system repairs for cmake-rs on Windows (a spawnable `EMCMAKE`, and the flag
variables defined so cmake-rs stops injecting ` /c emcc.bat ...`); and bindgen's,
which needs the target's sysroot or `math.h` is not found at all. All three are
landed -- the last as an environment variable in `web/build.sh`, the first two as
patches 8 and 9 of `android/prepare-raylib-sys.py`.

**W1 -- Input.** The keyboard (driving `sceneCommand`, which is what the scene's
console reads), the camera drag, pointer lock, and the character-queue repair.
A page you can walk around on.

**W2 -- The console and the clipboard.** The `web` text bridge (D1) and the
character queue, so `help`, `tuning` and the rest work. The ticket flow
(`copy`/paste) is moot without networking, but the console is the game's whole
debug surface on every other target and must not be a read-only shell here.

**W3 -- Look right.** `setGlslDialect(true)` on the wasm target, the ES3/WebGL 2
build, the skinned programs and the shadow map. Mostly a canary: the dialect is
already written, so what this proves is that WebGL 2 accepts the whole set and
that GPU skinning survives, as it did on the phone.

**W4 -- Touch.** `touch.js` on a phone browser: the stick, the buttons, the
camera, the pinch. The backend already reports touch, so this is a device pass
rather than new code.

**W5 -- Ship.** The `web` job in `.github/workflows/ci.yml`, the artifact,
README's Web section and the `ROADMAP.md` milestone (M22) pointing back here.

## What can be tested without a browser

As on the phone, the testable half is the half that would otherwise rot:

- **The dialect layer (D5)** is a pure function of the shader source and
  `crates/harness/tests/es3.rs` is already it -- the ES3 pass and the `300 es`
  checks cover the web build's shaders exactly as they cover the phone's.
- **The `web` surface (D1)** is driven through the recording `rl` in
  `crates/scene`, the way `touch.rs` installs and scripts the `android` surface
  (`Harness::touch`, `set_insets`, `type_text`, `crates/harness/src/lib.rs:491-509`).
  A `web` case asserts a typed line reaches the console, a gesture unlocks audio,
  and a run with no surface draws nothing.
- **The capability guards**: that a scene booted without `web` (desktop, server,
  harness) touches nothing browser-shaped -- the same case shape as
  `typeof rl.loadShaderFromMemory !== "function"`.
- **The build itself** is the CI job, which is a real gate: an Emscripten build
  that does not link is caught on every push, on a runner with no browser
  attached.

## The build, concretely

- **`python android/prepare-raylib-sys.py` first**, for the reason ANDROID.md
  gives: the workspace patches `raylib-sys` into `android/build/`, so no cargo
  command resolves until that path exists -- the web build uses the same crate.
- **`emsdk`, activated** (`. <emsdk>/emsdk_env.sh`; on Windows `emcc` is
  `emcc.bat`, so nothing is on `PATH` until this runs), and the target installed:
  `rustup target add wasm32-unknown-emscripten` -- **for the toolchain the
  checkout pins**, since `slag/rust-toolchain.toml` names 1.96.0 and a target
  added to the default toolchain is simply not there. `web/build.sh probe` is the
  check that this environment is right.
- **`EMCC_CFLAGS`**, which `raylib-sys` *requires* for a wasm target and panics
  without (`build.rs:559-580`); its own suggested value is the recipe:
  `-O3 -sUSE_GLFW=3 -sASSERTIONS=1 -sWASM=1 -sASYNCIFY -sGL_ENABLE_GET_PROC_ADDRESS=1`.
  Under D3, `-sASYNCIFY` is likely droppable; `-sUSE_GLFW=3` and
  `-sGL_ENABLE_GET_PROC_ADDRESS=1` are not (the backend registers its own GL
  proc-address loader, `rcore_web_emscripten.c:1263`).
- **Three repairs the Web build needed**, all landed -- patches 8 and 9 of
  `android/prepare-raylib-sys.py`, and one environment variable in `web/build.sh`.
  The link one is the `GLdispatch` gate above. The build ones are cmake-rs's:
  it hard-wraps the configure in `emcmake` and spawns the wrapper by bare name,
  and Windows ships only `emcmake.bat` -- which a Rust `Command` *can* run, but
  only when it is named (`Command::new("emcmake")` is not found) -- so the fork
  names `EMCMAKE`/`EMMAKE`; and it fills each `CMAKE_<lang>_FLAGS` from the
  `cc`-detected compiler unless the variable is already defined (`set_compiler`
  checks `self.defined` first), which on Windows comes out as
  ` /c emcc.bat -ffunction-sections ...` and makes clang read two missing files,
  once per source. The third is bindgen's: libclang has to be told the target's
  sysroot or `math.h` is not found at all, so `web/build.sh` exports
  `BINDGEN_EXTRA_CLANG_ARGS` with `--target=wasm32-unknown-emscripten` and
  Emscripten's `cache/sysroot` -- the same note ANDROID.md carries for the NDK.
- **A target-specific `slag` dependency.** The client's
  `features = ["jit", "raylib", "raygui"]` (`crates/goats/Cargo.toml:37`) stands
  for native; the wasm target needs its own `slag` line without `jit`, the way the
  same file already gives Android a `raylib-sys` of its own.
- **`cargo build --release -p goats --target wasm32-unknown-emscripten`.**
  `--release` for ANDROID.md's reason, which is doubly true here: `dev`'s
  `opt-level` becomes raylib's `CMAKE_BUILD_TYPE`, and the interpreter is the
  frame.
- **Raise the wasm stack.** `-sSTACK_SIZE=8388608` is not optional: Emscripten's
  default is 64 KiB and the engine overflows it inside `Context::new`, before the
  first script runs. The probe also carries `-sALLOW_MEMORY_GROWTH=1`, for a heap
  that is a JS engine's. Neither is in `raylib-sys`'s own suggested `EMCC_CFLAGS`
  -- and cargo does not track that variable, so a stale link will not pick a
  change to it up: clean the package after editing it.
- **Run the `.js` with `node`, not `cargo run`.** On Windows `cargo run` cannot
  execute Emscripten's generated `.js` (`%1 is not a valid Win32 application`,
  os error 193); the module is fine, it just needs a JS host.
- **Serve it, do not open it.** The `.wasm` fetch, the WebGL context and (if
  threads are ever wanted) the isolation headers all need an origin, so the
  build script drops a one-file server beside the artifacts; `file://` will not
  work.

## Risks and the calls to confirm

1. **Is the interpreter fast enough in a browser?** *Answered, with the blocker
   moved.* `web/probe` builds, links and runs Slag under
   `wasm32-unknown-emscripten` and prints `wasm-probe: ok` (2026-09-29), and the
   full client now runs the scene in a tab at ~59-60 fps on Firefox
   (SpiderMonkey), so the interpreter's steady-state cost does not drop frames.
   What drops them is the *collector*: with `?gctrace=1` (the page maps it to
   `--gc-trace`) the engine's per-collection telemetry shows a minor collection
   roughly once a second, each pausing **~350-400 ms**
   (`gc-trace minor pause_us=345000 ...`), which is the input jank -- camera,
   keys and audio all read on the render thread. The finding is in the rest of
   that line, not the pause itself: `swept=0` (a full collection that reclaims
   nothing) and a `live` set that only climbs (`8073 → 1.4M+` boxes), while the
   conservatively-scanned region (`stack_words`) grows `11M → 145M → 222M` words
   and is re-scanned every pass. This is a **Slag GC defect** -- the engine is
   pinned in `Cargo.lock`, and its `Context`/collector is the lever -- not a web
   or goats issue (PERF.md appendix B has the baseline and protocol). A second,
   independent variable is the browser engine: the same wasm runs ~3x slower
   under Chromium/V8 than SpiderMonkey (~20 fps), so Firefox is the reference
   target for now. The GC trace is off by default and toggled per load with
   `?gctrace=1`. The collector's cadence is also a client lever: the engine's
   `Context::set_nursery_threshold` (the young cohort that paces a minor,
   `agent.rs:2108`; default 8192) is exposed here as `--nursery-threshold N`
   and `?nursery=N`. A larger value collects less often -- fewer of the ~350 ms
   pauses, at the cost of more live memory -- and the right value is the next
   thing to measure.
2. **The ES3 link line, and raylib itself on wasm.** *Answered and closed.*
   `-lGLESv2` and `-lglfw` resolve under Emscripten; `-lGLdispatch` does not, and
   the fix is the gate Android already had (`raylib-sys/build.rs:188-190`)
   widened to `wasm32` -- one line, of the kind ANDROID.md's D4 is a list of.
   With it, raylib's cmake configures for `PLATFORM=Web`, the ES3 build compiles,
   the module links and it *runs* (`web/build.sh raylib` ends in
   `wasm-probe-raylib: raylib linked and ran`). The other two costs were
   build-system rather than port costs -- a spawnable `EMCMAKE` and the flag
   variables cmake-rs was injecting into -- and they are patches 8 and 9.
3. **The character queue.** The web backend fills key state and not characters
   (`rcore_web_emscripten.c:1469-1479`), so the console types nothing until the
   `TODO` is done. Unlike Android this is fixable in our own fork's C, but it is
   a fork repair either way -- and a candidate for upstream.
4. **Timing.** `GetTime`'s web units (`:963-968`) look wrong; the scene reads
   `getFrameTime`/`setTargetFPS` instead, so this is a thing to measure on the
   first page rather than trust.
5. **Size.** The embedded model and audio are the same bytes the desktop ships,
   now in a download. Brotli and `-Os` are the levers; a ceiling and a first-load
   budget are what W5 needs to decide.
6. **Mobile browsers.** Safari's WebGL 2 support, its memory ceiling and iOS's
   `AudioContext` gesture policy are the reasons W4 is a device pass and not a
   checkbox. A phone browser may end up the *best* target, not the worst -- the
   backend reports touch and the overlay exists -- but it should not be assumed.
7. **What "playable" means.** A frame target and a device class, so W3's raster
   decisions -- skinning, shadow cadence, the cloud preset -- are a choice rather
   than a guess. The desktop and the phone each answered this for their own
   hardware; the browser answers it for a laptop GPU inside a canvas.

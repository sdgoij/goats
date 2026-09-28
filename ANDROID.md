# The Android client

A proposal for running the *client* (`crates/goats`) on Android. The headless
host is out of scope: `goatsd` needs no display and no window, and a phone is a
worse server than the machine it is already on.

The short version: the host layer is much closer than it looks — raylib has an
Android backend that calls our existing `main()`, the engine's JIT is Cranelift,
every asset is already `include_bytes!`, and `cpal` ships an AAudio host. The
work is in three places, and only one of them is graphics:

| Layer | State | Cost |
| --- | --- | --- |
| Host: entry point, packaging, the frame loop | raylib does most of it | days |
| Raster: an ES2 floor, then GLES 3.0 | scene's GLSL is `#version 330` throughout, but the port is a JS dialect layer | a small raylib fork, not new shaders |
| Input and UI: touch, soft keyboard, on-screen controls | `rl` has no touch surface at all | the real work |

This document says what exists, what the gaps are, the calls to make before
starting, and a slice order that puts a picture on a phone screen early.

## Non-goals

- **The server.** `crates/server` stays desktop (and stays the thing you host on).
- **iOS.** Much of this proposal transfers — Metal/GLES, `cpal`'s coreaudio host,
  a `UIWindow` instead of a `NativeActivity` — but nothing here is written for it,
  and the packaging story is different enough to be its own document.
- **A rewrite of the scene.** The 12.8k lines of JS in `crates/goats/src/game/`
  already run without a window (M15), so the port is aimed at the two seams that
  only exist when there *is* a window: the shaders and the input.
- **Store submission.** The deliverable is an APK artifact and a device that
  plays; Play-facing work (signing, AAB, privacy declarations) is named only
  where it forces a decision.

## What already exists

Verified against the local `slag/` checkout and the vendored `raylib-sys 6.0.0`.

| Thing | Where | What it gives us |
| --- | --- | --- |
| An Android build path for raylib | `raylib-sys/build.rs`: `platform_from_target` selects `Platform::Android` when the triple contains `android` | NDK toolchain file, `ANDROID_ABI`, `-DPLATFORM_ANDROID`, links `log android EGL GLESv2 OpenSLES c m` and the cmake-built `libraylib.a` |
| `android_native_app_glue` | `raylib/cmake/LibraryConfigurations.cmake`, Android branch | the glue is compiled *into* `libraylib.a`; `-Wl,--no-undefined` is stripped for us |
| An entry point that is already ours | `rcore_android.c:322` — raylib defines `android_main` and calls `extern int main(int, char**)` | the client's `while !windowShouldClose()` loop (`crates/goats/src/main.rs:556`) is already the right shape |
| Touch as mouse | `rcore_android.c:1455-1470` | `touch[0]` drives `MOUSE_BUTTON_LEFT`, `Mouse.currentPosition` and `previousPosition` |
| A JIT for arm64 | `slag/crates/jit/src/compiler.rs:82`, `cranelift_native::builder()` | the host ISA, not a hardcoded x86-64; `runtime/src/stack.rs` already has a `target_os = "android"` arm |
| Assets | `ASSETS` in `main.rs` | nothing to ship beside the APK |
| Playback audio | raylib vendors miniaudio → AAudio/OpenSL ES | music, ambience and the voice stream |
| Mic capture | `cpal 0.18.2` has an `aaudio` host, with `jni`/`ndk`/`ndk-context` deps | M13b's capture path exists for Android |
| An embedder-defined JS surface | `Context::register_fn`, `Context::set_global`, `Context::define_accessor` (`slag/crates/runtime/src/embed.rs`) | the client can install its own globals — the same seam `sceneWasmApply` uses today |
| Direct raylib access from the client | `raylib-sys` is already a direct dependency of `crates/goats` | the touch bindings do not need an engine release |

## The gaps

### 1. Host and packaging

- **The entry symbol.** raylib's `android_main` calls `main`, and nothing forces
  the glue to be pulled out of `libraylib.a`: `raylib-sys` emits no
  `-u ANativeActivity_onCreate` (and `GetAndroidApp` is not in the bindings —
  it is deliberately absent from `raylib.h`). So the client owns the link args,
  and the crate has to be a `cdylib` with a C-ABI `main`.
- **Arguments and stdin don't exist.** `main.rs` reads `--mods`, `--pull`,
  `--watch`, `--gc-trace` from `env::args()`, and reads commands from a stdin
  thread. On Android there is no argv and stdin is `/dev/null`.
- **The mods directory.** `resolve_mods_dir` falls back to
  `std::env::current_exe()`'s parent (`main.rs:266`), which on Android is
  `app_process`, not us.
- **`gpu-skinning` cannot be switched per target.** It is declared in
  `crates/goats/Cargo.toml`'s `slag` features, and Cargo features do not vary by
  target. Android wants it *off* (see below), so it has to become a feature of
  the `goats` crate with `default = ["gpu-skinning"]`, the same shape Slag uses
  for its own `gpu-skinning`.
- **The toolchain.** The NDK is installed (`%LOCALAPPDATA%\Android\android-ndk-r30`,
  r30 / 30.0.16248370) and is what `ANDROID_NDK_HOME` points at, as are `adb`
  (1.0.41), `cmake`, `ninja`, `java` and the `aarch64-linux-android` Rust
  target. Still missing: `cargo ndk` and a Gradle wrapper, so `cargo ndk` has to
  be installed and Gradle fetched by the project.

### 2. Raster

raylib's Android branch hardcodes `GRAPHICS_API_OPENGL_ES2`
(`raylib/cmake/LibraryConfigurations.cmake:77-79`), but `raylib-sys` chooses the
graphics API itself with an `OPENGL_VERSION` define (`build.rs:157-184`) — and
that define is applied *before* the platform match, so it reaches Android. The
ES3 choice is therefore a feature rather than a fork: `opengl_es_30` sets
`OPENGL_VERSION="ES 3.0"`. It is not usable as it stands (it also emits
`-lGLdispatch`, a GLVND library Android does not have), but that is one line in
D4's fork. raylib 6.0 has the rest: `GRAPHICS_API_OPENGL_ES3` includes
`<GLES3/gl3.h>` and swaps in a GLSL ES 3.00 default shader (`rlgl.h:191-192`,
`876`, `5021`), and cmake maps `-DOPENGL_VERSION="ES 3.0"` to it
(`LibraryConfigurations.cmake:194-212`). The link line is a red herring either
way, since `libGLESv2.so` *is* the ES 3.x library on Android: there is no
`libGLESv3.so`.

GLES 2 is still the floor P0 lands on, and it is not a target this scene can
look like itself on: the whole lighting model, the volumetric sky, the water
surface, the shadow map and the skinned model are custom programs, and every one
of them is `#version 330` — 14 sources across 7 programs:

| Program | Sources | Ships as |
| --- | --- | --- |
| lit / lit-skinned | `litVertex(skin)`, `LIT_FS` | the scene's core look |
| unlit / unlit-skinned | `unlitVertex(skin)`, `UNLIT_FS` | the fallback "cube shader" |
| shadow / shadow-skinned | `shadowVertex(skin)`, `SHADOW_FS` | the shadow-map depth pass |
| depth / depth-skinned | `depthVertex(skin)`, `DEPTH_FS` | the water's depth prepass |
| water | `WATER_VS`, `WATER_FS` | pools, chop, fresnel |
| celestial | `CELESTIAL_VS`, `CELESTIAL_FS` | sun and moon |
| sky | `SKY_VS`, `SKY_FS` (in `sky.js`) | clouds, atmosphere, stars |

Three things soften this. First, every one of them **already fails soft**: the
scene logs and keeps the gradient, the billboards, the planar shadow, so an ES2
build runs, it just looks like an earlier milestone. Second, the shadow map packs
distance into colour rather than using a depth texture, so it is ES2-shaped by
accident. Third, the sources are *assembled in JS* (`litVertex(false)` and
`litVertex(true)` share a head and a body), which is exactly the place a
dialect layer belongs.

The ES2 floor costs less than that list suggests, and one of its items is not in
the scene at all. It is real for the **8 vertex attribute slots against the 9**
that `SUPPORT_GPU_SKINNING` needs, and real for having no `layout(location=)` to
pin the skinning attributes where raylib's default shader expects them. It is
*not* real for `gl_FragDepth`: that word appears nowhere — the depth prepass
packs distance into colour (`DEPTH_FS`, `lighting.js:1021-1031`) and the water
merely reads a varying (`in float fragDepth`, `lighting.js:314`) — and
`textureLod` and attribute blocks are unused too. On the dialect side the
sources are already close: every fragment program writes `out vec4 finalColor`
and calls `texture()` rather than `gl_FragColor`/`texture2D`, so D2's layer is
the `#version` line, a precision qualifier and little else.

ES3, which is where P3 goes, has an unknown of its own, and it is the first
thing to test on hardware. `rlGetVersion()` is compile-time (`rlgl.h:2707-2728`),
so an ES3 build makes the Android backend ask for an `EGL_OPENGL_ES3_BIT` config
(`rcore_android.c:936`) — and then request `EGL_CONTEXT_CLIENT_VERSION, 2`
regardless (`rcore_android.c:949`). An ES 2.0 context against raylib's own
`#version 300 es` shaders is that branch contradicting itself; if the driver does
not simply tolerate it, D4's fork grows a second line. See risk 2.

### 3. Input and UI

The `rl` surface exposes keys, mouse and clipboard, and **no touch or gesture
bindings at all** — no `GetTouchPointCount`, no `GetTouchPosition`, no
`GetGesturePinchDelta`. What that means today:

- Orbit camera: probably works. `goat.js:594` drags with `MOUSE_BUTTON_LEFT` and
  `getMouseDeltaX/Y`, and raylib feeds both from `touch[0]`.
- Zoom: dead. `camDist -= getMouseWheelMove() * 0.4`, and the Android backend
  zeroes `currentWheelMove` every frame.
- Movement, gait and jump: dead. ~30 `KEY_*` bindings — `W`/`S`, both shifts,
  both controls, `SPACE`, and 13 `isKeyPressed` toggles (`L`, `K`, `B`, `T`,
  `M`, `C`, `V`, `F11`, `ESCAPE`, …).
- The console (`console.js`): dead, and needs a soft keyboard, which arrives as
  `commitText` text rather than key events — `getCharPressed` will not see it.
- Clipboard: `SetClipboardText`/`GetClipboardText` are **stubs on Android**
  ("not implemented on target platform"), so the console's paste and `copy`
  (the ticket flow) are dead too.

### 4. The rest, briefly

- **Voice**: `cpal`'s AAudio host needs `ndk_context` initialised and
  `RECORD_AUDIO` granted at runtime. Nothing in a raw `NativeActivity` does
  either.
- **Networking**: `iroh 1.2.0` depends on `netwatch` and, by default, on
  `portmapper`. Android's SELinux policy and missing `/etc/resolv.conf` mean both
  network-change detection and DNS discovery have to be *verified on a device*,
  not assumed. `INTERNET` is not optional.
- **Perf**: `setTargetFPS(60)` against a 1080p-class panel with a 12-to-22-step
  volumetric sky raymarch. The Low cloud preset exists; a mid-range phone is
  unlikely to hold 60 with the default.
- **HUD**: `rl.getScreenWidth/Height` layout has no concept of a notch or a
  gesture bar.

## Decisions

**D1 — The Android surface lives in the client, not in Slag.** Touch, the soft
keyboard, clipboard and insets become client-registered globals
(`android.touchCount()`, `android.touchAt(i, out)`, `android.pinch()`,
`android.keyboard(show)`, `android.takeTyped()`, `android.clipboardGet/Set()`,
`android.insets()`) installed with `Context::register_fn` only when
`cfg(target_os = "android")`. The client already links `raylib-sys` directly for
audio streams, so this needs no engine change and no engine release, and it keeps
`crates/scene` — the bundle shared with `goatsd` and the harness — free of
platform code. The scene guards with the pattern it already uses for the keymap
and for `loadShaderFromMemory`:

```js
const hasTouch = typeof android === "object" && android !== null;
```

**D2 — The GLSL dialect is a pure JS translation.** One function in the scene,
`glsl(source)`, called at boot: it replaces the `#version 330` line, injects
`precision highp float;` and the `out vec4` the fragment sources need, and maps
`texture2D`→`texture`, `varying`→`in`/`out`, `attribute`→`in`. Desktop keeps
`330`; Android gets `300 es`; one source, two dialects, no doubled shader files.
Because it is pure JS and the shader sources are already assembled from arrays,
**the translation is testable in the existing harness** — no GPU, no device.

**D3 — `gpu-skinning` becomes a `goats` feature.** `default = ["gpu-skinning"]`
so every current build is unchanged, and the Android build passes
`--no-default-features`. The scene already branches on `rl.GPU_SKINNING`, the CPU
path is the one the harness covers, and this keeps the flag "in both builds
measurable" the way `crates/goats/Cargo.toml` already argues for.

**D4 — A patched `raylib-sys`, kept in the project.** `Cargo.toml` patches
`raylib-sys` to `android/build/raylib-sys`, which `android/prepare-raylib-sys.py`
materialises: a pristine copy of the published crate from the cargo registry,
with the repairs the P0 probe proved necessary applied to it. Nothing outside the
repository is read but the dependency cache every Rust build already uses, and
the copy is gitignored, so it is a build product rather than something to review.
Run the script once in a fresh clone — cargo cannot resolve the workspace until
that path exists. Seven patches: five on the crate's build path and two in
raylib's Android platform layer.

1. **The platform parse** (`build.rs:206`). The API level is taken from the last
dash-component of the triple, which `aarch64-linux-android` does not have, so
`ANDROID_PLATFORM`/`CMAKE_SYSTEM_VERSION` become `"android"` and the NDK
concatenates that into the LLVM triple (`aarch64-none-linux-androidandroid`),
losing the sysroot — a hard configure failure (`crtbegin_dynamic.o` not found),
not a warning. It also pins the API level when the triple has one
(`...-android25`), which `cargo ndk` does not produce either.
2. **`CMAKE_C_FLAGS`.** cmake-rs copies the `cc`-detected compiler's args into
`CMAKE_C_FLAGS`, and `cc` guesses a bare `--target=aarch64-linux-android` for
android triples. That lands *after* the toolchain's API-qualified
target and wins, so the C-compiler test cannot find the crts. Defining the flag
variables empty leaves the toolchain's own flags in charge.
3. **The GLFW guard.** raylib's top-level CMake fatals on "Cannot disable both
Wayland and X11" for any UNIX-ish platform but DRM/Web; CMake counts Android as
UNIX and `build.rs:731-735` forces both backends off for it, so an Android build
with `default-features = false` cannot configure at all.
4. **`is_android` is the host's OS** (`build.rs:718`). It is
`cfg!(target_os = "android")`, and a build script is compiled for the host, so
every Android-specific decision in it is dead when cross-compiling.
5. **And so is the X11 link** (`build.rs:485`), gated on that same cfg: on a
Linux host — i.e. the CI runner — it would link `-lX11` into the Android `.so`.
6. **The framebuffer is the panel.** `SetupFramebuffer` letterboxes a request
smaller than the display, which is a desktop idea: the client's 1000×640 window
became a 640px strip of the panel (`renderOffset` 376,0) and, against the
portrait size read at init, a strip in the bottom third (0,1510). The branch now
takes the display as the screen, which is what its own `== 0` case was for.
7. **A rotation after `InitPlatform` is noticed.** `APP_CMD_CONFIG_CHANGED` was
an empty stub whose comment said "Check screen orientation here!", and Android
only rotates an activity once its native window exists — so the change was
dropped. It now re-reads the window and re-runs the setup, touching size state
only: re-running `InitGraphicsDevice` would recreate the EGL surface and
invalidate every shader and texture the scene has loaded.

And the ES3 link line: `opengl_es_30` must stop emitting `-lGLdispatch` on
Android. All of this belongs upstream; the script is only how it gets applied
until then, and the sibling fork it was developed in stays as the PR candidate.

**D5 — The client owns its directory.** On Android, `--mods` is not available, so
the mods directory is the app's files dir (`/data/data/<pkg>/files/mods`) and the
default is resolved from the JNI `Context`, not from `current_exe`. Mod watching
(`notify`/inotify) keeps working there; `--watch` stays a desktop flag.

**D6 — A hand-rolled Gradle project, not `cargo-apk`.** We need Java anyway: an
`Activity` subclass is how the soft keyboard, the clipboard and the runtime
permission request are reached, and how the `Activity`/JVM handshake that
`ndk-context` wants is made. That rules out a generated manifest. `cargo ndk`
builds the `.so` into `jniLibs`; Gradle assembles the APK. `AndroidManifest`
declares a `NativeActivity` with `configChanges` for orientation, the
`glEsVersion="0x00030000"` feature once D4 lands, and `INTERNET` + `RECORD_AUDIO`.

**D7 — Landscape, and no keyboard until asked for.** The scene's window is
1000×640. The soft keyboard is shown only when the console opens, through
`android.keyboard(true)`, and its text is drained by the console through
`android.takeTyped()` rather than by `getCharPressed`.

## Slices

Each slice ends somewhere observable on a device.

**P0 — Pixels.** *Done, on a Galaxy S20 5G (Exynos 990, Mali-G77, Android 13).*
The game runs: raylib initializes (`PLATFORM: ANDROID: Initialized successfully`),
the goat GLB loads with all 14 clips, the terrain and water meshes upload, the
Vulkan-free GLES context comes up (`Renderer: Mali-G77`), and the frame loop
starts at the scene's 1000×640 upscaled to 1080×2322. The shaders fail exactly
as predicted — softly, and by name:

    SHADER: [ID 7] Compile error: 0:1: P0007: Language version '330' unknown,
            this compiler only supports up to version '320 es'
    [js] lighting: lit shader failed to compile - falling back to the cube shader
    [js] sky: shader failed to compile - keeping the gradient and billboards

The unit is `crates/android` (the C-ABI `main`, its link arguments, the
stdio redirect and the GLFW shim), D4's fork, and the recipe below. Packaging is
hand-rolled for now (`android/build-apk.sh`: aapt2, zipalign, apksigner); the
Gradle project waits for the Java Activity in P2/D6. Two things P0 taught the
plan: the device's driver accepts **GLSL ES 3.20**, a higher floor than D2
assumed, and the activity only keeps running while the screen is awake.

**P1 — Touch.** The `android.*` touch surface, plus a new scene part
(`crates/goats/src/game/touch.js`, the 18th) drawing a stick, a jump button and
a menu button, and driving the *existing* seams: movement writes `ctlHeld`
(`ctl.js:19`, already "the keys a script holds down"), toggles go through
`sceneCommand("lighting")` and friends. Camera keeps the free drag; zoom becomes
`android.pinch()`.

**P2 — The keyboard and the clip.** The Java `Activity`, `android.keyboard`,
`android.takeTyped`, `android.clipboardGet/Set`, console integration, and the
ticket flow (`copy`/paste) working through them.

**P3 — Look right.** D4's `raylib-sys` patch, the ES3 graphics API, D2's
`glsl()` layer, and the skinned programs reconciled with a GPU-skinning-free
build. The volumetric sky, water and shadow map come back; the Android defaults
for the cloud preset and shadows are chosen from what the device holds.

**P4 — Voice and session.** `ndk-context`, the `RECORD_AUDIO` request, then a
phone joining a desktop host over iroh: the real test of `netwatch`,
`portmapper` and DNS discovery on Android.

**P5 — Ship.** A CI job extending `.github/workflows/ci.yml` that builds the
`.so` and the APK and uploads it as an artifact, the README's Android section,
and a `ROADMAP.md` milestone for whatever this becomes.

Rough sizing, one developer with a device in hand: P0 is a couple of days now
that risk 1 is answered — what is left there is the client's `cdylib`, the Gradle
project and the first APK on a device — P1 is a few, P2 is a few, P4 and P5
shorter unless iroh misbehaves. P3 is still the long pole, but it is a week of *fork and device*,
not of shaders: D2's dialect layer is a pure function the harness can check
(below), so what stands is the ES3 context (risk 2), the skinned programs
reconciled against a GPU-skinning-free build, and defaults a mid-range phone
holds.

## What can be tested without a phone

The port's testable half is larger than it looks, and it is the half that would
otherwise rot:

- **The dialect layer (D2)** is a pure function of the shader source. The harness
  can assert that the ES3 output contains no `texture2D`, no `varying`, no
  bare `gl_FragColor`, and that the `#version` line is first — for all 14
  sources, on every run.
- **The touch overlay (P1)** can be driven through the recording `rl` stub in
  `crates/scene`: script a touch sequence, assert the goat's gait, the camera's
  yaw and the console's state, exactly as the existing scripted timeline does.
- **The capability guards**: that a scene booted without `android` (server,
  harness, desktop) touches nothing Android-shaped — the same shape as the
  existing `typeof rl.loadShaderFromMemory !== "function"` cases.
- **The build itself** is the CI job, which is a real gate: an Android build that
  does not link is caught on every push, on a runner with no phone attached.

## The build, concretely

None of this is discoverable from the failure messages alone:

- **`python android/prepare-raylib-sys.py` first.** The workspace patches
  raylib-sys to a path in `android/build/` that this creates, so no cargo command
  in the workspace resolves until it has run — desktop included.
  `android/build-apk.sh` runs it for you.
- **`rustup target add aarch64-linux-android`**, once per machine.
- **`ANDROID_NDK_HOME`** must point at the real NDK, which here is
  `%LOCALAPPDATA%\Android\android-ndk-r30`.
- **`CMAKE_GENERATOR=Ninja`.** Without it CMake picks the Visual Studio
  generator, which routes the build through VS's own registered NDK (a stale
  r23 on this machine) and targets `x86_64`.
- **`CC_`, `CXX_`, `AR_`, `RANLIB_aarch64-linux-android`** must name the NDK's
  `aarch64-linux-android26-clang.cmd` and friends. Without them `cc` looks for
  `aarch64-linux-android-clang`, then falls back to whatever `clang` is on
  `PATH`, and the C shims fail on `stdio.h`. Those names contain dashes, so they
  need `env`, not a bare shell assignment.
- **`ANDROID_PLATFORM=26`.** `libopus_sys` insists on an API level explicitly,
  and 26 is the floor regardless (risk 6).
- **`BINDGEN_EXTRA_CLANG_ARGS`** with `--target=aarch64-linux-android26` and the
  NDK sysroot, or bindgen parses `raylib.h` for the host and `math.h` is not
  found.
- **`CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER`** pointing at the same
  versioned wrapper.

`cargo ndk` would supply much of that, but on Windows 4.1.2 sets `CLANG_PATH` to
an extension-less `clang` (so bindgen ignores it) *and* exports its own
`BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android`, which is more specific than
`BINDGEN_EXTRA_CLANG_ARGS` and carries an unversioned `--target`. Its API-level
flag is also `-P` now, not `-p`. Hand-rolled, the whole client builds and links
in about a minute once the graph is warm.

### On the device

P0's surprises, none of them in a manifest:

- **The framebuffer has to be the panel, and the fork now makes it so.** raylib's
  `SetupFramebuffer` *letterboxes* a request smaller than the display — a desktop
  idea. The client's 1000×640 window became a 640px strip of the 1080px-tall
  panel (`Viewport offsets: 376, 0`), and against the portrait size read at init
  it was `0, 1510`: the bottom third of the screen that P0 first shipped with.
  Two Android-only repairs, applied by `android/prepare-raylib-sys.py` and
  listed in D4: that branch takes the display as
  the screen, and `APP_CMD_CONFIG_CHANGED` — an empty stub whose comment said
  "Check screen orientation here!" — now re-reads the window and re-runs the
  setup, because Android only rotates an activity *after* its native window
  exists. Screen and render are now 2322×1080 with offsets 0,0.

  Two consequences for the rest of the plan. The scene's 1000×640 is a desktop
  window size that Android now ignores, so anything reading it must read
  `rl.getScreenWidth/Height` instead — and the logical size is the panel, which
  means §4's notch and gesture-bar problem is live from P1 on.
- **Editing raylib's C in the fork does not trigger a rebuild.** `raylib-sys`'s
  build script declares `rerun-if-changed=binding/binding.h` and its own
  binding header, but not the raylib sources under `raylib/src/`, so cargo
  happily kept a stale `libraylib.a` and the fix appeared to do nothing. Touch
  `binding/binding.h` (the declared trigger) or clean the package after a
  C-level edit.
- **The client has no output without help.** An app's fds 1 and 2 are
  `/dev/null`, so every `println!`/`eprintln!` — the scene's `[js]` diagnostics
  above all — is discarded. `crates/android/src/lib.rs` re-points them at a
  pipe that a thread pumps into logcat under the tag `goats-client`. raylib's own
  TRACELOG arrives there anyway (`rcore.c:1897`).
- **The engine reaches into GLFW.** `window_content_scale()`
  (`slag/crates/runtime/src/raylib.rs`) calls `glfwGetCurrentContext` and
  `glfwGetWindowContentScale` directly for its desktop HiDPI correction. Android
  has no GLFW, so those stayed undefined and `dlopen` refused the library
  outright ("cannot locate symbol"). The same file shims them to the answer that
  call's NULL guard already expects; the real fix is a
  `cfg(not(target_os = "android"))` in Slag, and therefore a Slag PR.
- **The screen must be awake.** With the display dozing the activity sits paused,
  raylib stops after `PLATFORM: ANDROID: Initialized successfully`, and nothing
  looks wrong. `adb shell input keyevent KEYCODE_WAKEUP` and
  `wm dismiss-keyguard` before launching.
- **The emulator needs 12 GB free**, and the one here is x86_64 (with a 16 KB
  page-size image) while the build is arm64-v8a — so it could not have run this
  `.so` even after freeing space. The phone is the easier target; an emulator
  leg means adding x86_64 to the build.

## Risks and the calls to confirm

1. **The link.** *Answered on 2026-09-28.* raylib cross-builds for
   `aarch64-linux-android`, and the whole client now links as an `ELF64` /
   `AArch64` `cdylib` — raylib with its full feature set, `libopus`,
   `cpal`/AAudio, `iroh`, `slag`/Cranelift and all. The price is D4's repair
   list, not a redesign. Getting the *entry point* into the dynamic table is a
   three-step story of its own, written down in `crates/android/build.rs`:
   `-u` pulls the glue out of `libraylib.a`, and a version script of the crate's
   own — passed last, because neither `--export-dynamic-symbol` nor
   `--export-dynamic` overrides rustc's `local: *` — is what puts
   `ANativeActivity_onCreate` where `dlsym` can find it. Without that last step
   the `.so` links happily and exposes three dynamic symbols, and the app would
   fail to start with nothing on stderr.
2. **ES2 as a floor, and whether an ES3 context is reachable at all.** Is P0's
   fallback look acceptable as an intermediate, or does the port go straight to
   ES3? Going straight means shaders are the first problem you debug, on a
   device, with no fallback picture to compare against. Before choosing ES3,
   settle the contradiction in `rcore_android.c`: the backend asks for an ES3
   renderable (`:936`) but requests `EGL_CONTEXT_CLIENT_VERSION, 2` (`:949`), so
   an ES3 build may get an ES 2.0 context that cannot compile raylib's own
   `#version 300 es` shaders. That single line decides whether D4's fork is two
   changes or three.
3. **Where the clipboard lives.** Client-side `android.clipboard*`, or an engine
   change that makes `rl.setClipboardText` work on Android? The former is free,
   the latter is correct — and it is a Slag PR either way.
4. **How the Activity reaches Rust.** A `Java_..._create` JNI call passing the
   `Activity` (explicit, needs Java) versus reading `GetAndroidApp()` and walking
   the `android_app` we are not allowed to see in the bindings (no Java, but we
   would be hand-declaring a struct raylib owns).
5. **Voice capture.** `cpal`+AAudio as-is, or capture added to the engine's audio
   surface? `cpal` is already wired and only needs the context and the
   permission, so it should stay — but if `ndk_context` fights the plan, this is
   the pressure valve.
6. **Minimum spec.** *The API level is not free: 26.* `cpal`'s AAudio host
   links `-laaudio`, and the NDK only ships `libaaudio.so` from API 26 up (24
   and 25 have no stub), so voice capture sets the floor — which is still
   essentially every device in use. Open: which ABIs to ship (arm64-v8a alone,
   or x86_64 as well so emulators work), and whether the emulator gets a CI job
   at all — emulator GPU jobs are flaky, and the value is small next to a real
   device.
7. **Mods on a phone.** Bundled example mods only, or a file-picker import and a
   place to put a fetched world mod? This is the difference between a demo and a
   client.
8. **What "playable" means.** A frame target and a device class, so P3's graphics
   defaults are a decision rather than a guess.

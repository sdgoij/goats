# The Godot client in the browser

This is the **Godot** client's WebAssembly build. It is not the raylib client's
browser build -- that one is [`../WASM.md`](../WASM.md), and the two share the
Slag engine and the assets but nothing of the host. Here Godot is the host: its
loop, its renderer, its audio, its UI, and a GDExtension that carries the mod
runtime. So the differences from the raylib port are the ones Godot brings, not
the ones `WASM.md` describes.

## What runs

A **single-player** game, the same world the desktop client runs: the terrain,
the meadow, the herd, the weather, the water, the HUD and the console. JavaScript
mods run on Slag's **interpreter** (the JIT needs RWX memory a wasm sandbox does
not grant), so the mod API and any imported JavaScript mod work (see
[Mods in the browser](#mods-in-the-browser) for where they live).

What is **not** there, by construction of a tab rather than by choice:

| Area | Why |
| --- | --- |
| Networking (`host`, `join`, roster, chat, world datagrams, mod sync) | `session` is iroh, which is QUIC over UDP; a browser exposes no UDP socket. |
| Voice | Capture is `cpal`, and the codec is native libopus. |
| Compiled `.wasm` mods | `crates/plugin` needs a module host a tab does not have. |

The scene is unchanged: `NetBridge` keeps its class and every method, but the
`wasm32` arm (`crates/godot/src/net_web.rs`) has no transport behind it and
answers the same "no session" an offline desktop scene gets. `main.gd` creates it
as it always does.

## Mods in the browser

A tab has no filesystem, so the browser does not walk a `mods/` directory. The
sources are the build's own zips and `user://mods/<folder>/` (Godot persists the
latter to IndexedDB), and both reach Rust as bytes:

- `godot/tools/package_web.sh` stages the release's two mods -- **birds** (world)
  and **fatguy** (client) -- as zips under `res://bundled_mods/`, and the Web
  preset's `bundled_mods/*` filter packs them. A zip keeps the mod's raw bytes:
  Godot would otherwise import a `.glb`/`.mp3` and the loader would never see the
  file the manifest names.
- `mods.gd` reads the bundled zips with `ZIPReader`, then walks `user://mods/`.
  Each mod becomes a dictionary of manifest-relative names to
  `PackedByteArray`s, handed to `ModHost::load_mod_files`. Bundled first, user
  second: the loader replaces by id, so an edited copy saved through the editor
  wins on the next boot.
- `crates/mods` has a `ModSource::Memory` and `Manifest::from_files` for exactly
  this. The manifest, digest, assets, tuning and load order come from the same
  parser a directory or a zip goes through; nothing is re-implemented in
  GDScript.
- `ModHost::reload_mod_files` adds or replaces a mod and runs its entry. A known
  id is torn down first (`__end`, as a disk reload does), and an unknown one is
  inserted and run, so one call is enough for a new buffer.
- `mods.gd` also installs the editor bridge on `window`: `goatsModsSave`,
  `goatsModsReload`, `goatsModsRead` and `goatsModsState`. A save/reload request
  is JSON `{name, files: {relative name: base64}}`; every answer is returned and
  also published on `window.goatsModsLast`. `goatsModsRead` opens a saved copy
  first and falls back to the bundled zip, so the editor can customize a build's
  own mod.

An import is the editor's job: Godot's `ZIPReader` extracts a picked archive into
that same dictionary, and a save writes it under `user://mods`. Compiled `.wasm`
mods remain out -- a tab has no module host (`crates/plugin`).

## Building the extension

The extension is a **side module** for Emscripten, and its build is
`godot/tools/build_web.sh`:

```sh
. <emsdk>/emsdk_env.sh               # EMSDK (or EMSCRIPTEN) must be set
rustup toolchain install nightly     # once
rustup component add rust-src --toolchain nightly
rustup target add wasm32-unknown-emscripten --toolchain nightly
sh godot/tools/build_web.sh
```

CI pins both halves instead of taking the newest of each: **Emscripten 5.0.7**
(emsdk) and **`nightly-2026-08-29`** (the nightly the port was checked against).
The latter is selected with `WEB_TOOLCHAIN=nightly-2026-08-29`, which
`build_web.sh` passes to `cargo`; without it the script uses `nightly`.

It builds `-p goats-godot --features web` for `wasm32-unknown-emscripten` and
copies the module to `godot/addons/goats_godot/bin/web/`, which is where
`goat.gdextension`'s `web.*.wasm32` entries point.

The `web` feature enables gdext's `experimental-wasm`, its
`experimental-wasm-nothreads`, and **`lazy-function-tables`**. The last is not an
optimization: without it, gdext's eager function table makes the wasm link run
for many minutes instead of seconds.

The flags, and what each is for:

| Flag | Why |
| --- | --- |
| `-C panic=abort` | Keeps `_Unwind_*` and the `__cpp_exception` wasm-EH tag out. Godot cannot import that tag, and a module that names it fails at `WebAssembly.instantiate` before anything runs. |
| `-C link-args=-sSIDE_MODULE=2` | A Godot web extension is a side module. |
| `-Z default-visibility=hidden` | Keeps this extension's symbols private, so two Rust extensions cannot merge globals. |
| `-C llvm-args=-enable-emscripten-cxx-exceptions=0` | No C++ exception lowering. |

Two Windows-specific things, both in the script:

- `CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc.bat`. emsdk ships only the
  `.bat` wrapper, and rustc's default linker name `emcc` does not resolve.
- `EM_WORKAROUND_PYTHON_BUG_34780=1`. Emscripten's wrapper documents it: a
  cargo-driven link inherits the parent's stdin, and `python.exe` can hang on it
  (Python bug 34780). Without this the link sits forever.

`-Zbuild-std` is used as gdext recommends, and `-Z` flags require the nightly
toolchain.

## Exporting

`godot/export_presets.cfg` has a **`Web`** preset. Its two essential options are
`variant/extensions_support=true` (which selects Godot's `web_dlink` templates --
the ones that can load side modules) and `variant/thread_support=false` (a
single-threaded build needs no `SharedArrayBuffer`, so it needs no COOP/COEP
headers).

The export is **packaged under a shell page**, `godot/web/index.html`:

```sh
GODOT=/path/to/Godot sh godot/tools/package_web.sh
# -> target/godot-web/
#      index.html            the shell (16:9 frame, client switcher, mod editor)
#      client/index.html     the Godot export
#      client/index.pck      ...
```

`package_web.sh` runs the headless export into `client/` and copies the shell
beside it. The export itself writes `index.html`, `index.js`, `index.wasm`, the
engine's own `index.side.wasm`, the project's `index.pck`, and the extension as
`goats_godot.wasm` (about 7.7 MB). Set `GODOT` to the editor binary; it defaults
to `godot` on `PATH`. The extension must already exist -- run
`godot/tools/build_web.sh` first.

## The shell page

`godot/web/index.html` is deliberately plain HTML/CSS/JS with no build step and
no dependencies. It keeps the client out of the whole viewport: the game is an
`<iframe>` in a `width: min(100%, 1120px); aspect-ratio: 16 / 9` stage, about the
size of a YouTube player, with a fullscreen button that preserves the ratio.

The page is also the seam for two things that are planned, not built:

- **Client switcher.** `CLIENTS` names each client's entry point. Only `godot`
  (`client/index.html`) is enabled; the reference client's option is disabled
  until its browser build lands under `reference/`.
- **Mod editor.** The panel and its layout exist, but its controls are disabled:
  import / customize / create / save / export need the mod API and a storage
  story wired to the running client first. Keeping the scaffold honest is
  cheaper than promising controls that do nothing.

## Serving

Any static server. With no threads, no isolation headers are required:

```sh
python -m http.server 8000 --directory target/godot-web
# http://localhost:8000/
```

The URL serves the shell; the Godot client is at `/client/` inside it. To compare
the clients later, put the reference export under `target/godot-web/reference/`
and enable its option.

## Publishing

`.github/workflows/ci.yml` has two jobs for the browser build. **`web`** runs on
every push and pull request once `test` and `godot` are green: it installs the
pinned Emscripten and nightly, builds the extension, packages `dist-web/`, checks
the four files a blank frame would come from (the shell, the `.pck`, the engine's
side module and the extension), and uploads the directory as the Pages artifact.
**`deploy-web`** runs only for a push to `main` or a manual dispatch, and
publishes it with `actions/deploy-pages@v5`.

GitHub Pages has to be pointed at Actions once, in the repository:

> **Settings -> Pages -> Build and deployment -> Source: GitHub Actions**

The site is then `https://<owner>.github.io/goats/`. Every path in the shell is
relative, so the project-page subpath needs no base-URL configuration; the client
is `/goats/client/index.html`. A pull request builds the page but does not deploy
it, and a `v*` tag does not deploy it either -- the release jobs are separate.

## The renderer

Godot's web platform only runs the **Compatibility** (WebGL 2) renderer. The
project keeps Forward+ on desktop and adds a feature-tag override in
`project.godot`:

```ini
renderer/rendering_method="forward_plus"
renderer/rendering_method.web="gl_compatibility"
```

The web build therefore uses the same scene, materials and shaders through a
different renderer. The Compatibility backend is the one place a visual
difference is expected, and the first thing to look at if the browser frame is
not the desktop frame.

## Known gaps

- **Mods.** The build's own **birds** and **fatguy** travel as zips in
  `res://bundled_mods/`; user edits and imports live in `user://mods` (IndexedDB)
  and win by id. Compiled `.wasm` mods are still out.
- **Audio needs a gesture.** Web audio only starts after a user interaction; a
  headless run reports streams that cannot be sampled until the page is clicked.
- **Microphone.** Voice chat is compiled out on wasm (`session`, `pull`, `voice`),
  so `voice.gd` returns from `_ready` in the browser instead of building the
  capture bus. That early return is not optional: `AudioServer.add_bus()` passes
  `at_position = -1` to Godot's web audio library, whose `Bus.addAt`/`Bus.move`
  then insert the new bus at the *front* of its array. The following
  `set_bus_mute(1, true)` lands on the reordered master bus, muting the whole game.
  If voice is ever enabled on the web, add the bus with
  `AudioServer.set_bus_count(AudioServer.bus_count + 1)` instead, which appends
  without the move, or fix `Bus.addAt` upstream.
- **Size.** The engine's own side module is ~44 MB uncompressed (inherent to
  Godot's `dlink` web template), the extension ~7.7 MB and the packed project
  ~15 MB. Brotli is the decompression story a host applies.
- **Threads.** This build is single-threaded. A threaded export needs a second
  build with `-pthread`/`+atomics` and
  `godot/experimental-wasm-nothreads` removed, plus the `.threads.wasm32`
  entries the gdext book describes.
- **CI.** There is no `web` job yet; the desktop jobs in `../.github/workflows/ci.yml`
  do not build this target.

## What a run looks like

Loading the export in a browser prints, in order:

```
Initialize godot-rust (API v4.7.stable.official, runtime v4.7.2.stable.official, ...)
Godot Engine v4.7.2.stable.official...
OpenGL API OpenGL ES 3.0 (WebGL 2.0) - Compatibility - ...
Build configuration: Emscripten ..., single-threaded, GDExtension support.
offline: no GOATSD_TICKET, so there is no session to mirror
```

The first line is the extension; the `Compatibility` one is the renderer override;
the last is the scene running with the stubbed bridge. The world renders: terrain,
sky, the local goat and the herd, the HUD and the weather line.

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
| Hosting, swarm discovery | The gateway is a session *client*; a tab cannot own a session or join the gossip topic. |
| Mod sync (pull) | A tab has nowhere to install a fetched mod; the gateway refuses `pull`. |
| Voice | Capture is `cpal`, and the codec is native libopus. |
| Compiled `.wasm` mods | `crates/plugin` needs a module host a tab does not have. |

The scene is unchanged: `NetBridge` keeps its class and every method. The
`wasm32` arm (`crates/godot/src/net_web.rs`) puts a `WebSocketPeer` behind it and
speaks the same JSON lines to `goatsd --gateway`; the page passes the URL with
`--gateway=` (`?gateway=ws://host:port`, persisted in `localStorage`). Hosting
answers with an error, and the swarm and voice calls are silent -- the parts a
file:// tab cannot own yet. The join, chat, poses, world and mod events are the
same ones a desktop scene gets.

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
  `goatsModsReload`, `goatsModsRead` and `goatsModsState`, plus the panel's
  console and tuning calls (`goatsConsoleState`, `goatsConsoleRun`,
  `goatsTuningState`, `goatsTuningWrite`). A save/reload request
  is JSON `{name, files: {relative name: base64}}`; every answer is returned and
  also published on `window.goatsModsLast`. `goatsModsRead` opens a saved copy
  first and falls back to the bundled zip, so the editor can customize a build's
  own mod.
- `goatsConsoleState` is `{version, open, prompt, history, lines}`; the page
  polls `version` and reads the ring only when it moves. `goatsConsoleRun`
  submits through the same `Console.submit` the overlay's Enter key uses, so the
  command echoes into the in-game scrollback too.
- `goatsTuningState` is `{version, tree, clamp, int, last}` -- the live tree,
  the client's own `INT`/`CLAMP` tables, and the last write's answer.
  `goatsTuningWrite` takes `{path, value}` and returns `{ok, value}` or
  `{err}` from `Tuning.write`, the same validated path a mod uses.

The shell's Mod editor owns import and export: it reads a picked `.zip` with its
own reader (`DecompressionStream` for deflate entries) and writes one with stored
entries, then hands the files to `goatsModsSave`. The same dictionary is what a
drop of files or a folder augments. Compiled `.wasm` mods remain out -- a tab has
no module host (`crates/plugin`).

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
#      index.html            the shell (16:9 stage, client switcher, mod editor)
#      client/index.html     the Godot export
#      client/index.pck      ...
#      reference/index.html  the raylib client, when web/dist exists
```

`package_web.sh` runs the headless export into `client/`, copies the shell
beside it, and copies the raylib client's own build from `web/dist/` into
`reference/` when it is there. The export itself writes `index.html`, `index.js`,
`index.wasm`, the engine's own `index.side.wasm`, the project's `index.pck`, and
the extension as `goats_godot.wasm` (about 7.7 MB). Set `GODOT` to the editor
binary; it defaults to `godot` on `PATH`. The extension must already exist -- run
`godot/tools/build_web.sh` first.

The packaging moment is also a build stamp. `package_web.sh` replaces
`__BUILD__` in the shell, which puts it on `client/index.js`,
`client/goats_godot.wasm`, `reference/goats.js` and the reference module, and it
writes the same stamp into the Godot export's `mainPack` URL (`index.pck?v=`). A
normal reload revalidates the shell but not the 16 MB pack underneath it, so
without the stamp a rebuild was only visible after a hard refresh; with it, the
rebuilt pack is a new URL.

## The shell page

`godot/web/index.html` is deliberately plain HTML/CSS/JS with no build step and
no dependencies. It keeps the client out of the whole viewport: the game draws
into a `<canvas>` in a `width: min(100%, 1120px); aspect-ratio: 16 / 9` stage,
about the size of a YouTube player, with a fullscreen button that preserves the
ratio.

**There is no iframe and no start gate.** The selected client boots into this
page's canvas on arrival: the Godot option loads `client/index.js` and starts the
export's own `Engine` with `executable: "client/index"` and
`mainPack: "client/index.pck?v=..."`; the reference option sets `Module` and
loads `reference/goats.js`. One engine per document is the rule -- two wasm
runtimes cannot share a global scope -- so switching clients is a top-level
navigation (`?client=...`), which boots the new client on arrival.

The canvas is the client's alone: there is no shell overlay. Godot draws its own
boot progress into the shell's `#status` (the export's progress bar), and a
failed load is reported there for either client. Because nothing waits for a
click, a browser may keep audio locked until the first interaction, which is its
own rule.

The page is the seam for two things:

- **Client switcher.** `CLIENTS` names each client's boot and its standalone
  page. A `HEAD` probe on `reference/goats.js` enables the reference option only
  when that build is packaged -- a Godot-only package leaves it disabled rather
  than loading a 404.
- **Mod editor.** A DevTools-style dock on the right edge of the page: drag its
  left edge to resize, maximize it, `Ctrl+Shift+E` toggles it, and the width, tab
  and open state are remembered in `localStorage`. While the 16:9 stage can stay
  at least 480 px wide the dock takes its width out of `main`, so the stage
  shrinks and moves left; below that the dock overlays the page instead. Four
  tabs:
  - **Console** mirrors the game's scrollback (and the page's own `console`, for
    the host), with a source filter, text or `/regex/` search, follow, clear,
    command history, and the pending question as the input's placeholder.
  - **Files** lists the running client's mod table (with enable/disable through
    the `mod enable`/`mod disable` verbs), a file tree, and a line-numbered,
    syntax-highlighted editor. Files can be created, renamed and deleted; files
    or folders dropped on the pane are added to the open mod (a dropped `.zip`
    is imported); Import/Export read and write stored `.zip` archives.
  - **Details** is a form over `mod.json` (id, name, version, api, side,
    description, entry, assets) with the same validation the loader applies.
  - **Tuning** is the live tree with the clients' own `INT`/`CLAMP` bounds,
    filter, per-leaf reset, and "write tuning.json", which writes only the
    leaves changed from the session's starting values.

  Both clients expose the same eight globals: `goatsModsState`, `goatsModsRead`,
  `goatsModsSave`, `goatsModsReload`, `goatsConsoleState`, `goatsConsoleRun`,
  `goatsTuningState`, `goatsTuningWrite`. `mods.gd` installs them for the Godot
  client, and the reference build's `goats_*` exports behind
  `installReferenceMods` for the raylib one. Run reloads the buffer without
  keeping it; Save writes the whole mod. The reference build has no `user://`,
  so the page keeps every saved file -- assets included -- in IndexedDB and
  writes them back into `/mods` in `preRun`. The Godot client's own `user://mods`
  is already IndexedDB-backed.

`?client=reference` selects the reference client (default: Godot).

### The reference client

The second option is the raylib client's own WebAssembly build (`WASM.md`). It is
built separately, with its own link flags and the stable toolchain. The build
preloads the repository's `mods/` into the module's virtual filesystem
(`goats.data`), so the browser client discovers the same mods the desktop binary
does, and the shell's editor reaches it through the `goats_mods_*` exports.

```sh
sh web/build.sh client        # -> web/dist/{index.html,goats.js,goats.wasm,goats.data}
sh godot/tools/package_web.sh # stages it as reference/ when present
```

The shell's probe then enables **Reference (raylib / WASM)**. The shell passes
the stage's pixel size on the wasm side's command line (`--viewport WxH` through
`Module.arguments`, surfacing as `web.width`/`web.height`), and `sceneInit`
calls `rl.initWindow` at that size. The wasm cannot read the shell's globals --
the game script runs in the engine's own JS context, where `Module` is not
visible -- so argv is the channel. The standalone page (`reference/index.html`)
keeps the 854x480 column; the shell's canvas gets the stage size. Its mod
loading and voice are the reference client's own story (`WASM.md`); its
networking goes through the same `goatsd --gateway` WebSocket as the Godot
client.

## Serving

Any static server. With no threads, no isolation headers are required:

```sh
python -m http.server 8000 --directory target/godot-web
# http://localhost:8000/
```

The URL serves the shell; the Godot client is at `/client/` and the reference
client at `/reference/`. Both are plain relative paths, so the same directory
works at a site root or a project subpath.

## Publishing

`.github/workflows/ci.yml` has two jobs for the browser build. **`web`** runs on
every push and pull request once `test` and `godot` are green: it installs the
pinned Emscripten, the Godot nightly and a stable toolchain for the reference
client, builds both extensions, packages `dist-web/`, checks the files a blank
frame or a dead switcher option would come from, and uploads the directory as
the Pages artifact. **`deploy-web`** runs only for a push to `main` or a manual
dispatch, and publishes it with `actions/deploy-pages@v5`.

GitHub Pages has to be pointed at Actions once, in the repository:

> **Settings -> Pages -> Build and deployment -> Source: GitHub Actions**

The site is then `https://<owner>.github.io/goats/`. Every path in the shell is
relative, so the project-page subpath needs no base-URL configuration; the Godot
client is `/goats/client/index.html` and the reference client
`/goats/reference/index.html`. A pull request builds the page but does not deploy
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

# Slag Goat

[![CI](https://github.com/sdgoij/goats/actions/workflows/ci.yml/badge.svg)](https://github.com/sdgoij/goats/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/sdgoij/goats?include_prereleases&sort=semver&label=release)](https://github.com/sdgoij/goats/releases)

A JavaScript-driven 3D goat sandbox. A rigged, animated goat authored in Blender
is loaded and played back inside the [Slag](https://github.com/sdgoij/slag)
JavaScript engine through its raylib host module (`rl`).

Almost everything that moves is JavaScript: `crates/goats/src/main.rs` is a thin
host that embeds the model and evaluates the scene from
`crates/goats/src/game/`, which drives the gait state machine, camera, HUD and
the heightfield terrain.

Prebuilt binaries for Windows x86-64 and Linux x86-64/AArch64 are attached to
each [release](https://github.com/sdgoij/goats/releases); to build it yourself:

```
cargo run --release
```

## Demo

A short clip of the sandbox in motion:

<video src="goats.mp4" controls muted loop width="100%"></video>

*If the player above does not appear, [`goats.mp4`](goats.mp4) opens on its file
page, where GitHub plays it.*

## Features

- Skinned glTF goat with eleven baked clips: `GoatIdle` / `GoatIdle2` /
  `GoatIdle3`, `GoatWalk`, `GoatTrot`, `GoatRun`, `GoatJump` / `GoatJump2`,
  `GoatSleep` / `GoatSleep2` and `GoatDeath`. Idle, sleep and jump have variants,
  so the player cycles through them and each bot settles on its own.
- State machine covering idle / walk / trot / run / jump / **sleeping** / **dead**,
  with a script-controlled jump arc taken from the clip's root motion.
- **Health and energy.** Energy drains faster the harder the goat works; at zero
  it is exhausted (capped at a walk, bleeding health) until it sleeps. Sleep
  restores energy and health; zero health is fatal.
- **Sleeping and death** with their own clips: the goat's real eyelids close
  while sleeping (a `LidL`/`LidR` bone pair), and on death it buckles and topples
  right over onto its side, where the cartoon X-eyes appear.
- **Day/night cycle**: a clock drives a gradient sky, the sun and moon arcing
  overhead, a star field and a scene-wide ambient tint. Hold `T` to
  fast-forward the clock.
- **Weather**: a seeded state machine walks `clear → cloudy → rain → clearing`,
  forced to the next state with `C`. Rain falls as wind-slanted streaks, the
  grass sways with gusty noise, and overcast greys the sky. Rain and wind bite
  into gameplay: a soaked goat moves up to ~30% slower and burns energy faster,
  on top of the existing night penalty. Press `B` to switch the sky between the
  cloud shader and the billboard fallback.
- **Volumetric sky (M5/M5b)**: the sky is one full-screen shader. Per pixel it
  rebuilds the camera ray, shades an analytic atmosphere (the hour-of-day
  gradient, a forward-scattered glow that widens as the sun drops, a horizon
  haze), and raymarches a slab of cloud between `CLOUD_BASE` and `CLOUD_TOP`.
  The density field is fBm domain-warped in 2D and sheared with height, so the
  billows have structure instead of being an extrusion; every sample marches a
  few steps toward the sun, so the bases darken and the tops stay lit;
  transmittance is Beer-Lambert with a Henyey-Greenstein phase term for the
  bright rim on the sun's side, and a powder term keeps dense interiors from
  glowing. A thin, wind-sheared cirrus layer sits above the cumulus, and
  distance haze blends far cloud into the horizon. The **Clouds** setting (Low /
  Medium / High — 6 / 12 / 22 march steps) trades quality for speed; `B`
  switches to the billboard fallback.
- **Heightfield terrain**: the ground is a 3-octave noise field built into a
  48x48-quad mesh (`rl.makeModel`) and drawn in one call, so it carries real
  per-vertex normals, UVs and colours. It spans +/-48 units around the goat and
  rebuilds once the goat has moved 24. Materials (grass, dark grass, sand, mud,
  rock) are per-vertex colours chosen from height, slope and patchiness noise,
  modulated by a tiling detail texture; a level spawn bowl keeps the start flat.
  The goat, the herd, the grass and both shadows all read `terrainHeight`, so
  nothing floats or sinks. A cube-per-cell version of this measured 41 fps
  against 56 for the flat plane, which is why it is one mesh; without the
  `makeModel` binding the ground falls back to the flat slab.
- **Real lighting and shadows (M4/M4b)**: a small custom GLSL program lights
  the scene. A directional sun (or moon at night) driven by the clock, plus a
  hemispheric ambient term, shades the goat and the terrain per fragment. The
  goat and the grass inside the light's box cast shadows from a depth pass
  rendered in the light's view, sampled with a 3x3 PCF kernel — so the goat
  self-shadows and the terrain takes a proper perspective shadow, including from
  nearby tufts. Press `L` to toggle lighting and `K` to cycle the shadow
  between the map, the planar fallback and off. Falls back to the M2/M3
  ambient-tint look if the engine lacks the shader bindings.
- **Audio**: a background music loop plus weather ambience and goat
  vocalisations. The track and the rain/wind beds are streamed `Music` (they loop
  natively and cost almost no memory); bleats and thunder are short `Sound`
  effects with a little pitch variation. Rain and wind volume follow the weather,
  thunder rumbles once the rain is heavy, and the goat bleats on jump, sleep,
  waking and death. Press `M` to mute. Every clip is embedded in the binary (the
  long ambience beds are shipped as Ogg Vorbis), so the game needs no files on
  disk.
- **No foot skating**: each gait's ground speed is derived from the clip's
  authored stride and stance fraction rather than hand-tuned
  (`speed = stride / (duty * clipDuration)`).
- **A bot herd**: six autonomous goats wander around the player, each with its
  own procedural mottled fleece, body size and temperament. They graze, stroll,
  trot, and now and then get the zoomies — a run punctuated by jumps. Goats
  collide, so nothing walks through anything else (the player can shove bots
  aside). Nearby bots cast into the shadow map; distant ones get a contact blob.
  Their AI runs on a private PRNG so the seeded weather the harness asserts on is
  untouched.
- Orbit + zoom camera, a procedural grass field that follows the goat so it never
  runs out, and a health/energy HUD.
- A cube-skeleton fallback (voxel body + 2-bone-IK legs) if the model cannot be
  loaded.

## Controls

| Input | Action |
| --- | --- |
| `W` / `S` | walk forward / backward |
| `Ctrl` + `W` / `S` | trot |
| `Shift` + `W` / `S` | run |
| `Space` | jump |
| `Z` | sleep / wake |
| `R` | restart after death |
| `T` (hold) | fast-forward the clock |
| `C` | force the next weather state |
| `L` | toggle the lit shader / shadows |
| `K` | cycle shadows: map / planar / off |
| `M` | mute / unmute the audio |
| `B` | toggle the sky shader / billboard clouds |
| `A` / `D` | turn left / right |
| mouse drag | orbit the camera |
| arrow keys | orbit the camera (keyboard fallback) |
| mouse wheel | zoom |
| `P` | pause / resume |
| `` ` `` | open / close the console |
| `Esc` | main menu / resume |

## Multiplayer

Sessions are peer-to-peer over [iroh](https://github.com/n0-computer/iroh): no
account and no central server, the connection is encrypted, and a peer is
addressed by its key. One player hosts; everyone else joins with the host's
ticket.

- **Host from the game**: press `` ` `` for the console and type `host`. It asks
  for a username, then prints a ticket. The ticket also goes to stderr, because
  text in the game window cannot be selected.
- **Join**: `connect <ticket>` in the console; it asks for a username. Names are
  first come, first served, so a duplicate becomes `bob #2`.
- **Paste, don't type**: the console reads the clipboard on Ctrl+V, so the ticket
  can be pasted. `copy` puts the ticket you were given back on the clipboard, and
  Ctrl+C copies the current line.
- **Standalone server**: `cargo run --release -p server` runs `goatsd`, a
  headless host that prints its ticket and logs joins, leaves, the roster and
  chat. Stop it with Ctrl-C.
- **Chat**: in a session, type a line with no leading slash to say it to
  everyone. `@name <text>` (or `say` / `msg <name> <text>`) is a 1:1 whisper, and
  the console marks it as one. Offline, bare text is an error, and `who` lists
  the roster.
- **See each other**: every player's goat is relayed to the others about 20 times
  a second, so you can watch them move. Snapshots are unreliable datagrams and
  the scene interpolates between them.
- `leave` ends the session.

Chat is rate limited to a short burst and each line is capped and stripped of
control characters, so a session cannot be flooded by one player. Movement is
client-authoritative: the server relays each player's own goat rather than
simulating it.

It is LAN-only for now: the endpoint binds local sockets with no relay, so it
reaches other machines on the same network and not the wider internet. Internet
play (n0's relays and hole punching) is a one-line change in the session crate.

The world is shared by seed, which the host picks at `host` and sends with the
welcome; every client derives the weather, food regrowth and bleat streams from
it. It is not yet fully server-owned: the bots still simulate on each client, so
they can drift apart once players interact with them.

The headless server is a lobby at present: it holds the session and relays goats
and chat, but does not simulate the world.

## Requirements

- Rust with edition 2024 support (tested with 1.98).
- A GPU/driver exposing OpenGL 3.3.
- Network access on the first build: Slag is a **git dependency**.
- On Linux, the development packages raylib and its Wayland GLFW backend need
  (Slag compiles GLFW itself): `cmake`, `pkg-config`, a C toolchain,
  `clang` + `libclang-dev` for bindgen, `libasound2-dev`, `libwayland-dev` +
  `libwayland-bin` + `wayland-protocols` + `libxkbcommon-dev`, and the Mesa/EGL
  headers. `.github/workflows/ci.yml` carries the exact `apt-get` list.

## Building

The client's manifest, `crates/goats/Cargo.toml`, pins Slag from GitHub:

```toml
slag = { git = "https://github.com/sdgoij/slag", features = ["jit", "raylib", "raygui"] }
```

To build against a local checkout of the engine instead, swap in the commented
path dependency (the `slag/` directory in this repo is ignored by git and is
exactly such a checkout):

```toml
slag = { path = "../../slag/crates/slag", features = ["jit", "raylib", "raygui"] }
```

Then:

```sh
cargo run --release   # recommended
cargo run             # debug builds work too; see "Troubleshooting"
```

## Releases

`.github/workflows/ci.yml` runs on every push and pull request:

- **Logic tests** on `ubuntu-latest` and `windows-latest`: `node --check` over
  the scene parts and the tool scripts, then the headless harness
  (`node tools/goat_logic_test.js`).
- **Builds** for the three supported targets, each uploaded as a workflow
  artifact:

| Target | Runner | Archive |
| --- | --- | --- |
| Windows x86-64 | `windows-latest` | `goats-windows-x86_64.zip` |
| Linux x86-64 | `ubuntu-latest` | `goats-linux-x86_64.tar.gz` |
| Linux AArch64 | `ubuntu-24.04-arm` | `goats-linux-aarch64.tar.gz` |

Pushing a `v*` tag publishes all three archives as a GitHub Release; an ordinary
push only builds and keeps the artifacts. Because the model and every sound are
embedded, an archive is just the two executables (the game and `goatsd`) plus
this readme and the licence.
The AArch64 job uses GitHub's hosted arm64 runners, which a public repository
gets on the free plan.

## Layout

| Path | What it is |
| --- | --- |
| `Cargo.toml` | The workspace manifest: `crates/goats` (its `default-members`, so `cargo run` means the client) plus the networking crates |
| `crates/goats/src/main.rs` | Rust host: installs the JIT + raylib, registers the embedded assets, joins and evaluates the scene |
| `crates/goats/src/net.rs` | The network bridge: JSON lines between the frame loop and a tokio runtime thread |
| `crates/goats/src/game/*.js` | The scene, split into 14 parts (core, model, world, lighting, sky, audio, weather, food, bots, goat, ctl, menu, console, net) |
| `crates/server/` | `goatsd`: the standalone headless host (a session lobby for now) |
| `crates/session/` | The peer-to-peer transport and session state machine: iroh, tickets, the join handshake and the roster |
| `crates/proto/` | The session protocol: message types, framing and name rules (no iroh or tokio) |
| `sfx/` | Music, weather ambience and goat vocalisations (embedded into the binary; the long beds are Ogg) |
| `goat_animated.glb` | Exported model (11 clips, textures embedded) — embedded into the binary |
| `goat.blend` | Blender source: armature rig, actions, materials (its `.blend1` auto-backup is git-ignored) |
| `goats.mp4` | The demo clip for the README (22 s, 1280×720, H.264) |
| `tex/` | Knitted-fleece textures (diffuse / normal / roughness / displacement / AO) |
| `tools/inspect_glb.py` | Dump a GLB's images, textures, materials and animations |
| `tools/goat_logic_test.js` | Headless Node harness for the scene (stubs `rl`) |
| `.github/workflows/ci.yml` | Tests, release builds and tag publishing |
| `slag/` | Optional local Slag checkout (git-ignored) |

## How it is wired

`crates/goats/src/main.rs` is small:

```rust
let mut context = Context::new().unwrap();
context.set_host_callbacks(callbacks);          // forwards console.log -> [js]
slag::install_jit(&mut context).unwrap();
context.install_raylib().unwrap();
context.register_raylib_asset("goat_animated.glb", GOAT_GLB);
context.eval(SCENE).unwrap();                    // the whole scene
```

The scene is split for readability but compiled as one script: `SCENE` is a
`concat!` of the parts in the order they are listed, so every part shares a
single top-level scope (functions hoist across the whole thing, and the
top-level `const`s run in file order). That `concat!` list is the only place the
order lives — the headless harness parses it out of
`crates/goats/src/main.rs`, so adding a part is just adding the file to
`crates/goats/src/game/` and one line to that list.

The model bytes are compiled in with `include_bytes!`, so the model needs no
files on disk at runtime (the audio does — see `sfx/`). `model.js` finds the
clip it wants by name via the `rl` surface (`modelAnimationCount` /
`modelAnimationName`), so a missing clip degrades to the walk rather than failing.

Networking is the one thing JavaScript cannot do here, so it lives in Rust behind
a line-based bridge: `net.rs` runs the session on its own tokio thread, and each
frame the host hands the scene its events with `sceneNetEvent(line)` and takes
the scene's queued intents back with `sceneNetDrain()`, without ever awaiting in
the frame loop. `net.js` is the scene end of that channel; the console commands
are `host`, `connect <ticket>`, `who`, `leave`, `say` and `msg` (with bare text
and a leading `@name` both routed to chat). Chat and roster travel on reliable
streams, one message per stream; goat snapshots travel as unreliable datagrams,
which `net.js` turns into a remote goat per peer and eases toward the latest one.

## Model pipeline

`goat.blend` holds a 15-bone armature (`Root`, `Spine`, `Neck`, `Head`, `Tail`,
the `LidL`/`LidR` eyelids and four two-bone legs). The leg bones swing on their
local Z axis, so each gait is authored as a 2-link IK problem: hoof targets in
the sagittal plane are solved for thigh and shank angles. The clips bake their
forward travel as in-place motion; the script moves the goat at the matching
speed. The three locomotion gaits sit at roughly **0.87 / 1.58 / 2.94 m/s** for
walk / trot / run, selected with no modifier, `Ctrl` and `Shift` respectively.

The eyelids are two spherical caps over the eyes, each weighted to a lid bone
whose head sits at the eye centre and whose axis points along +X, so a rotation
about the bone's local Y (the hinge) sweeps the cap down over the eye. Closing is
−90° on `LidL` and +90° on `LidR`; every clip keys the pair, closed only in
`GoatSleep`, because raylib resets a bone only when a clip animates it.
`tools/goat_eyelids.py` rebuilds them and re-exports.
`tools/goat_states.py` rebuilds the recumbent `GoatSleep` and the collapsing
`GoatDeath` clips the same way, auto-grounding each so the lowest mesh vertex
rests on the ground -- the death clip now rolls all the way onto the goat's side,
with a per-frame ground correction because the roll pivots on the goat's edge.
`tools/goat_variants.py` adds the `GoatIdle2` / `GoatIdle3` / `GoatSleep2` /
`GoatJump2` variants.

Export to GLB with every action as its own clip, shifted to start at `t = 0` so
loops are exact:

```python
bpy.ops.export_scene.gltf(
    filepath="goat_animated.glb",
    export_format="GLB",
    use_selection=True,            # only the mesh + armature
    export_animations=True,
    export_animation_mode="ACTIONS",
    export_anim_slide_to_zero=True,
    export_skins=True,
    export_def_bones=False,        # keep non-deform bones (Root carries the jump arc)
    export_yup=True,
)
```

Textures are embedded in the GLB. They come from ambientCG / Poly Haven; the
`acg_*.json`, `ambientcg_*.json` and `ph_*.json` files are the original asset
metadata from that step.

## The `rl` model surface

Playing a skinned, animated model needed new bindings in Slag's raylib
module (committed upstream in `sdgoij/slag`):

```
loadModel  makeModel  isModelValid  unloadModel
setModelShader  setModelTexture
drawModel  drawModelEx   modelBounds
modelAnimationCount  modelBoneCount
modelAnimationName   modelAnimationFrameCount  modelAnimationDuration
updateModelAnimation
```

`rl.makeModel(vertices[, indices[, normals[, colors[, texcoords]]]])` builds a
model from flat number arrays and returns a handle in the same registry as
`loadModel`, so every other binding here applies to it unchanged. That is what
makes the heightfield possible: terrain drawn from immediate-mode geometry gets
raylib's default normal `(0, 0, 1)` and texcoord `(0, 0)`, so it cannot be lit or
textured. The arrays are allocated with raylib's allocator, so `unloadModel`
frees them exactly once.

Two raylib build features are required and are enabled by the dependency:
`SUPPORT_FILEFORMAT_GLTF` (so `.glb` loads at all) and `SUPPORT_FILEFORMAT_JPG`
(glTF textures are usually JPEG; without it stb_image compiles with
`STBI_NO_JPEG` and every embedded JPEG decodes to an empty image).

`rl.isModelValid` reports whether the handle is live rather than forwarding
raylib's `IsModelValid`, which rejects *any* skinned model in a CPU-skinning
build because the bone VBOs are never uploaded without `SUPPORT_GPU_SKINNING`.

## The `rl` shader surface

M4's lighting needs a second set of Slag bindings (also upstream in
`sdgoij/slag`):

```
loadShaderFromMemory  isShaderValid  unloadShader  getShaderLocation
beginShaderMode  endShaderMode
setShaderValue  setShaderValueVector2/3/4  setShaderValueMatrix
setShaderValueTexture
loadRenderTexture  isRenderTextureValid  unloadRenderTexture
beginTextureMode  endTextureMode
renderTextureSize  renderTextureColor  renderTextureDepth
setModelTexture
```

Two consequences shape the scene. raylib's default shader is unlit and
`DrawMesh` binds the *material's* shader, ignoring `beginShaderMode` — so the
goat and the terrain are routed through the lit program with `setModelShader`,
while the grass and the cube fallback use `beginShaderMode`. (A model draw also
resets the batch shader when it finishes, which is why the terrain is drawn
outside the grass's shader-mode block.) And because this is a
CPU-skinning build, raylib already deforms positions *and* normals on the CPU
before upload, so the lit shader needs no bone matrices.

The shadow is a depth pass rendered in the light's view, compared in the lit
shader with a 3x3 PCF kernel. Depth is packed across the render texture's RGB
(its depth attachment is only a renderbuffer, so it is not samplable) and stored
as `1 - depth` so the cleared-black background reads as "far". The shadow map is
handed to the *model* draw through a material map — `setModelTexture` puts it in
every material's map 1, which `DrawMesh` binds to unit 1 and feeds the `texture1`
sampler from. That is the only reliable route, since `setShaderValueTexture`
picks a unit that the model's own maps then overwrite; the grass and the cube
fallback (batch path) have no materials and use `setShaderValueTexture` directly.
The grass tufts
inside the light's box go in through the same depth pass, but via the batch path
(`beginShaderMode`) and drawn before the goat so its depth wins
on overlap; tufts outside the box cannot project into the map, so they are
culled. The field itself is generated per 2-unit cell from a hash of the cell, so
it follows the goat and never leaves bare ground behind. `K` cycles the map, a
planar fallback (the earlier M4 look) and off.

The M5/M5b sky reuses the same bindings. It is a full-screen pass
(`beginShaderMode` + `drawRectangle`) whose fragment shader reads `gl_FragCoord`,
so the fragment side is independent of raylib's own projection; the JS side
passes the camera basis, fov, hour-of-day colours, sun direction/colour, wind and
cloudiness, the slab geometry and the march step count as uniforms. That step
count is an `int` uniform (`SHADER_UNIFORM_INT`), so the shader's loop bound
follows the Clouds setting rather than being baked in. `B` falls back to the M2
gradient and the noise-puff billboards.

## The `rl` audio surface

The sound effects and music needed a small audio surface (also upstream):

```
initAudioDevice  closeAudioDevice
loadSound  playSound  stopSound  setSoundVolume  isSoundPlaying  setSoundPitch
loadMusic  unloadMusic  playMusic  updateMusic  stopMusic  pauseMusic
resumeMusic  setMusicVolume  setMusicPitch  isMusicPlaying
musicTimeLength  musicTimePlayed
```

`Music` streams from disk (the wind and rain beds are ~10 MB each) and loops
natively, while `Sound` is fully decoded and meant for short effects. Music
needs `updateMusic` every frame to keep the stream fed. `SUPPORT_FILEFORMAT_MP3`
and `SUPPORT_FILEFORMAT_OGG` are enabled on raylib-sys; without them the
compressed effects decode to nothing. Embedded assets keep their extension when
materialised to a temp file, since raylib picks the decoder from it.

Audio is loaded from `sfx/` at runtime rather than embedded, so the binary stays
small — run from the repository root (as `cargo run` does).

## Tests and tools

```sh
# Drive the scene headlessly through every state, stats and death
node tools/goat_logic_test.js

# Inspect the model's clips, textures and materials
python tools/inspect_glb.py goat_animated.glb

# Re-author the sleep/death clips and re-export (run inside Blender)
#   exec(open("tools/goat_states.py").read())

# Re-author the idle/sleep/jump variants and re-export (run inside Blender)
#   exec(open("tools/goat_variants.py").read())

# The engine's raylib surface test (from the Slag checkout)
cargo test -p runtime --features raylib --lib raylib
```

## Troubleshooting

- **`Maximum call stack size exceeded` in a debug build.** Slag's stack guard
  stops deep JS recursion from overflowing the native stack. Unoptimized builds
  spend far more stack per activation, so keep per-frame helper calls shallow —
  the scene computes its HUD read-outs once in `run()` rather than nesting them
  inside `drawHud()`. Build `--release` for headroom.
- **Goat renders untextured.** The `SUPPORT_FILEFORMAT_JPG` feature is missing
  from the raylib build (see above).
- **Fur looks stretched.** The Blender materials tile the fleece with a Mapping
  node, which exports as `KHR_texture_transform`; raylib ignores that extension,
  so the UV scaling is lost. Bake the tiling into the mesh UVs before export if
  it matters.
- **The local engine checkout won't build.** Its `unicode` crate needs the
  `test262` submodule; a full `git submodule update --init` is large, and a
  sparse checkout of just
  `test/built-ins/RegExp/property-escapes/generated/` is enough. The default git
  dependency avoids this entirely.

## License

MIT.

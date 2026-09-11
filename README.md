# Slag Goat

A JavaScript-driven 3D goat sandbox. A rigged, animated goat authored in Blender
is loaded and played back inside the [Slag](https://github.com/sdgoij/slag)
JavaScript engine through its raylib host module (`rl`).

Almost everything that moves is JavaScript: `src/main.rs` is a thin host that
embeds the model and evaluates the scene from `src/game/`, which drives the gait
state machine, camera, HUD and terrain.

```
cargo run --release
```

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
- **Procedural sky (M5)**: the sky is one full-screen shader. Per pixel it
  rebuilds the camera ray, draws the hour-of-day gradient, and samples animated
  value-noise fBm on a flat cloud layer — the ray-to-plane projection is what
  gives the clouds their parallax toward the horizon. Clouds are lit by
  comparing density against a sample taken toward the sun, so they brighten on
  the sun's side and pick up its dawn/dusk colour.
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
  waking and death. Press `M` to mute. Audio loads from `sfx/` on disk and is
  skipped if a file is missing.
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
| `Esc` | quit |

## Requirements

- Rust with edition 2024 support (tested with 1.98).
- A GPU/driver exposing OpenGL 3.3.
- Network access on the first build: Slag is a **git dependency**.

## Building

The default `Cargo.toml` pins Slag from GitHub:

```toml
slag = { git = "https://github.com/sdgoij/slag", features = ["jit", "raylib", "raygui"] }
```

To build against a local checkout of the engine instead, swap in the commented
path dependency (the `slag/` directory in this repo is ignored by git and is
exactly such a checkout):

```toml
slag = { path = "./slag/crates/slag", features = ["jit", "raylib", "raygui"] }
```

Then:

```sh
cargo run --release   # recommended
cargo run             # debug builds work too; see "Troubleshooting"
```

## Layout

| Path | What it is |
| --- | --- |
| `src/main.rs` | Rust host: installs the JIT + raylib, embeds the GLB, joins and evaluates the scene |
| `src/game/*.js` | The scene, split into 9 parts (core, model, world, lighting, sky, audio, weather, bots, goat) |
| `sfx/` | Music, weather ambience and goat vocalisations (loaded at runtime) |
| `goat_animated.glb` | Exported model (11 clips, textures embedded) — embedded into the binary |
| `goat.blend` | Blender source: armature rig, actions, materials (its `.blend1` auto-backup is git-ignored) |
| `tex/` | Knitted-fleece textures (diffuse / normal / roughness / displacement / AO) |
| `tools/inspect_glb.py` | Dump a GLB's images, textures, materials and animations |
| `tools/goat_logic_test.js` | Headless Node harness for the scene (stubs `rl`) |
| `slag/` | Optional local Slag checkout (git-ignored) |

## How it is wired

`src/main.rs` is small:

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
order lives — the headless harness parses it out of `src/main.rs`, so adding a
part is just adding the file to `src/game/` and one line to `src/main.rs`.

The model bytes are compiled in with `include_bytes!`, so the model needs no
files on disk at runtime (the audio does — see `sfx/`). `model.js` finds the
clip it wants by name via the `rl` surface (`modelAnimationCount` /
`modelAnimationName`), so a missing clip degrades to the walk rather than failing.

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
loadModel  isModelValid  unloadModel
setModelShader
drawModel  drawModelEx   modelBounds
modelAnimationCount  modelBoneCount
modelAnimationName   modelAnimationFrameCount  modelAnimationDuration
updateModelAnimation
```

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
goat is routed through the lit program with `setModelShader`, while the terrain
(immediate-mode cubes) uses `beginShaderMode`. And because this is a
CPU-skinning build, raylib already deforms positions *and* normals on the CPU
before upload, so the lit shader needs no bone matrices.

The shadow is a depth pass rendered in the light's view, compared in the lit
shader with a 3x3 PCF kernel. Depth is packed across the render texture's RGB
(its depth attachment is only a renderbuffer, so it is not samplable) and stored
as `1 - depth` so the cleared-black background reads as "far". The shadow map is
handed to the *model* draw through a material map — `setModelTexture` puts it in
every material's map 1, which `DrawMesh` binds to unit 1 and feeds the `texture1`
sampler from. That is the only reliable route, since `setShaderValueTexture`
picks a unit that the model's own maps then overwrite; the terrain (batch path)
has no materials and uses `setShaderValueTexture` directly. The grass tufts
inside the light's box go in through the same depth pass, but via the batch path
(`beginShaderMode`, like the terrain) and drawn before the goat so its depth wins
on overlap; tufts outside the box cannot project into the map, so they are
culled. The field itself is generated per 2-unit cell from a hash of the cell, so
it follows the goat and never leaves bare ground behind. `K` cycles the map, a
planar fallback (the earlier M4 look) and off.

The M5 sky reuses the same bindings. It is a full-screen pass (`beginShaderMode`
+ `drawRectangle`) whose fragment shader reads `gl_FragCoord`, so the fragment
side is independent of raylib's own projection; the JS side passes the camera
basis, fov, hour-of-day colours, sun direction/colour, wind and cloudiness as
uniforms. `B` falls back to the M2 gradient and the noise-puff billboards.

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

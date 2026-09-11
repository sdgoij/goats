# Slag Goat

A JavaScript-driven 3D goat sandbox. A rigged, animated goat authored in Blender
is loaded and played back inside the [Slag](https://github.com/sdgoij/slag)
JavaScript engine through its raylib host module (`rl`).

Almost everything that moves is JavaScript: `src/main.rs` is a thin host that
embeds the model and evaluates `src/goat.js`, which drives the gait state
machine, camera, HUD and terrain.

```
cargo run --release
```

## Features

- Skinned glTF goat with five baked clips: `GoatIdle`, `GoatWalk`, `GoatRun`,
  `GoatJump`, `GoatTrot`.
- Gait state machine — idle / walk / run / jump — with a script-controlled jump
  arc taken from the clip's root motion.
- **No foot skating**: each gait's ground speed is derived from the clip's
  authored stride and stance fraction rather than hand-tuned
  (`speed = stride / (duty * clipDuration)`).
- Orbit + zoom camera, a culled grass field, and an on-screen HUD.
- A cube-skeleton fallback (voxel body + 2-bone-IK legs) if the model cannot be
  loaded.

## Controls

| Input | Action |
| --- | --- |
| `W` / `S` | walk forward / backward |
| `Shift` + `W` / `S` | run |
| `Space` | jump |
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
| `src/main.rs` | Rust host: installs the JIT + raylib, embeds the GLB, evaluates the scene |
| `src/goat.js` | The scene: gait state machine, jump, camera, HUD, grass |
| `goat_animated.glb` | Exported model (5 clips, textures embedded) — embedded into the binary |
| `goat.blend` | Blender source: armature rig, actions, materials |
| `tex/` | Knitted-fleece textures (diffuse / normal / roughness / displacement / AO) |
| `tools/inspect_glb.py` | Dump a GLB's images, textures, materials and animations |
| `tools/goat_logic_test.js` | Headless Node harness for `goat.js` (stubs `rl`) |
| `slag/` | Optional local Slag checkout (git-ignored) |

## How it is wired

`src/main.rs` is ~25 lines:

```rust
let mut context = Context::new().unwrap();
context.set_host_callbacks(callbacks);          // forwards console.log -> [js]
slag::install_jit(&mut context).unwrap();
context.install_raylib().unwrap();
context.register_raylib_asset("goat_animated.glb", GOAT_GLB);
context.eval(include_str!("goat.js")).unwrap();  // the whole scene
```

The model bytes are compiled in with `include_bytes!`, so the demo needs no
files on disk at runtime. `goat.js` finds the clip it wants by name via the `rl`
surface (`modelAnimationCount` / `modelAnimationName`), so a missing clip
degrades to the walk rather than failing.

## Model pipeline

`goat.blend` holds a 13-bone armature (`Root`, `Spine`, `Neck`, `Head`, `Tail`
and four two-bone legs). The leg bones swing on their local Z axis, so each
gait is authored as a 2-link IK problem: hoof targets in the sagittal plane are
solved for thigh and shank angles. The clips bake their forward travel as
in-place motion; the script moves the goat at the matching speed.

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

## Tests and tools

```sh
# Drive goat.js headlessly through idle -> walk -> run -> jump -> walk
node tools/goat_logic_test.js

# Inspect the model's clips, textures and materials
python tools/inspect_glb.py goat_animated.glb

# The engine's raylib surface test (from the Slag checkout)
cargo test -p runtime --features raylib --lib raylib
```

## Troubleshooting

- **`Maximum call stack size exceeded` in a debug build.** Slag's stack guard
  stops deep JS recursion from overflowing the native stack. Unoptimized builds
  spend far more stack per activation, so keep per-frame helper calls shallow —
  `goat.js` computes its HUD read-outs once in `run()` rather than nesting them
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

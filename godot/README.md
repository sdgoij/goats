# Godot

`godot/` is the Godot project for the port of the Slag Goat sandbox. It holds
**only Godot-specific content**: the project, the scenes, the GDScript, the
assets, and the GDExtension descriptor. The Rust behind the extension is a
member of the root workspace at `crates/godot` (see below), and `PORT.md` is the
plan.

## Layout

| Path | What it is |
| --- | --- |
| `project.godot` | The project: Forward+, 4.7, and the glTF import defaults |
| `goat.gdextension` | Tells Godot to load the library built from `crates/godot` |
| `addons/goats_godot/bin/` | Where `crates/godot/build.sh` copies the built library (git-ignored) |
| `assets/goat_animated.glb` | A copy of the repository-root model, so the project is self-contained |
| `scenes/herd.tscn` | The main scene and the port's first world: a client that joins a session and mirrors the host's herd |
| `src/main.gd` | The frame loop: it joins a session, drains the bridge each frame, reads the keyboard, drives the world's clock and weather, and (as a probe) reports whether the mirror converged |
| `src/player_goat.gd` | The local goat: `goat.js`'s gait state machine, movement and stats — the goat you drive |
| `src/hud.gd` | The state, health, energy and clock, as one `Label` until stage 6's `Control` tree |
| `src/herd.gd` | The mirrored herd: one real goat per bot the host simulates, standing on the scene's ground |
| `src/terrain.gd` | The heightfield, transcribed from `world.js` and measured against it |
| `src/terrain_mesh.gd` | The ground, drawn: the scene's 48x48 grid as one `ArrayMesh`, rebuilt as the anchor drifts |
| `src/grass.gd` | The meadow, drawn: `weather.js`'s `tuftField` as a `MultiMesh`, following the goat and thinning where it has grazed |
| `src/meadow.gd` | The meadow as food: the cell hash, the nearest tuft, bites and regrowth (`food.js`) |
| `src/sky.gd` | The day/night curve, the sun's arc, the light and the ambient, transcribed from `world.js` and `lighting.js` and measured against them |
| `src/sky.gdshader` | The sky, drawn: `sky.js`'s raymarched cloud slab as a `shader_type sky` |
| `tools/` | Headless verification scripts, and `interop.sh` |

`crates/godot` is the GDExtension itself — the only crate in the tree that can
see Godot. It exposes `NetBridge` (the networking bridge over `session` and
`proto`: `host`, `join`, `say`, `pose`, `leave`, `poll_events`, `shutdown`) and
`ModHost`
(the embedded Slag engine plus the `goats`/`rl` facade a mod sees; the facade is
`crates/godot/src/prelude.js`, and the loader it drives is the `crates/mods`
crate). It is a workspace member rather than a project of its own so it inherits
`workspace = true` dependencies and shares the root `Cargo.lock`, which is what
lets it link the client's `session`/`proto`/`plugin` crates unchanged.

> **Workspace note.** Because it is a member, `cargo test --workspace --exclude
> goats` (the README's fast-test command) now also compiles the Godot codegen and
> pulls the `godot` crate family into the workspace graph. A bare `cargo build`
> is unaffected — `default-members` is still `crates/goats`. If the codegen cost
> should not sit on that path, add `--exclude goats-godot` there.

## Building and verifying

```sh
# Build the extension and copy it into the project.
crates/godot/build.sh            # debug
crates/godot/build.sh release    # release

# Then, once, so Godot scans the descriptor and registers the library:
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot --import
```

Eleven headless gates, all `SceneTree` scripts that exit non-zero on failure:

```sh
# The model imports with every clip, bone, surface and texture the game needs.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_model.gd

# The GDExtension loads, registers its classes, and answers from Rust.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_extension.gd

# The embedded engine runs the repository's mods and calls back into the host.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_mods.gd

# Two Godot peers meet over iroh: host, join, roster, chat, goat snapshots.
# This one brings up real endpoints, so it takes ~20-30 s.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_net.gd

# The heightfield against the JavaScript one (it has to agree with the host).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_terrain.gd

# The drawn ground: the scene's 48x48 grid, its winding, its normals, its drift.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_terrain_mesh.gd

# The sky's curve, the sun's arc, the light and the ambient, against the JS ones.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_sky.gd

# The meadow: `tuftField`'s 32-bit cell hashes, positions, culls and flags.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_grass.gd

# The meadow as food: the same hash through the eating path, plus the search, a
# bite and the regrowth window.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_meadow.gd

# The local goat: the gait speeds from the model's own clips, and 2200 frames of a
# scripted input tape run through the scene's state machine and the port's.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_goat.gd

# The keyboard reaches the goat: the real scene, keys held down the way a real
# keyboard does it, where the goat ended up, and that a goat standing still poses
# its idle clip.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_input.gd
```

All eleven pass against Godot 4.7.2 today.

> **Run the gates under a timeout.** A GDScript file that fails to compile can
> make Godot *loop* rather than error — with no output at all — so a gate that
> never returns looks exactly like one that is thinking. `timeout 200` around
> each is what makes that distinguishable.

> **Reference scripts by path, not by class name, in a `.tscn`.** A `class_name`
> script or a GDExtension class used as a *node type* cannot be resolved while
> the import pass that registers it is still running, and a scene cached from
> such a pass silently loses the node. Both `Terrain` and the bridge are declared
> as plain types with a `script = ExtResource(...)`, and the bridge is built with
> `ClassDB.instantiate` from `main.gd`.

## Looking at it

Nothing here can see. A headless run has no rasteriser, so the gates check data —
winding, normals, heights, the palette, the wire — and **two bugs in this port
were invisible in every one of those and obvious in a single image**: a triangle
wound the way raylib winds it (Godot culls it, so the ground was simply not
there) and a sun pointing at the sky. `tools/screenshot.gd` renders the scene and
writes `shot.png`:

```sh
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --path godot \
    --script res://tools/screenshot.gd --resolution 1280x720
```

It opens a window for about half a second, needs a GPU, and is deliberately **not
a gate**: it cannot run in CI and it asserts nothing. Pressing play in the editor
is the same view. `godot/tools/interop.sh shot` is the same idea against a live
session, long enough for a host's herd to arrive (see below).

What it shows is the scene's own world: the scene's goat, the scene's ground, the
scene's meadow, the scene's sky and the scene's light — the world derived, not
received, with a host's herd mirrored in beside yours when there is one. What is
still Godot's rather than the scene's is the *lighting model*: the terrain, the
grass and the goat are lit by Godot materials under a `DirectionalLight3D` with
Godot's shadows, not by the scene's own lit program and hand-rolled shadow map
(`PORT.md` section 5). The port's colours also run through Godot's linear pipeline,
which the sky compensates for and the ground does not (`PORT.md` section 9). And the
HUD is one `Label` rather than the scene's bars, action menu and console: the words
are the scene's, the layout is stage 6.

Two environment variables stage what there is no UI for yet: `GOATS_HOUR` pins the
clock and `GOATS_CLOUD` the cloudiness, so an hour or an overcast sky can be
looked at before the weather state machine exists. Both are ignored while a
session is up, because the host owns the weather.

## Running against the shipping host

`tools/interop.sh` starts the real `goatsd` and points a Godot client at it. It
is a script rather than a `verify_*.gd` gate because it has to orchestrate two
processes, and every outcome is evidence:

```sh
# Build the server first; the script does not.
cargo build --release -p server

# goatsd --no-mods: the client joins, chats and mirrors the world.
godot/tools/interop.sh

# goatsd with the repository's mods/: the client is refused by mod digest.
godot/tools/interop.sh refuse

# The mirror scene: joins, places the host's herd from live snapshots, and
# reports whether the mirror converged. This one runs the project's main scene
# rather than a probe script, so it is the closest thing here to the game.
godot/tools/interop.sh herd

# No server at all: the scene must boot and keep running. Needs no goatsd.
godot/tools/interop.sh offline

# ...and render it: the real scene against a live host, in a window, ten seconds
# in, with the herd standing on the ground. Needs a GPU and writes godot/shot.png.
godot/tools/interop.sh shot
```

It reads `GODOT_BIN` and `GOATSD_BIN` if the defaults do not fit.

## Running the scene

Pressing play with no `GOATSD_TICKET` is the normal way to play it: **a session is
optional**, and the scene says so and then runs. What you get is a goat you drive,
on the ground the game's own heightfield describes, in a meadow it can eat, under
the scene's own sky.

```
W / S          walk forward / backward
A / D          turn
SHIFT          run            CTRL   trot
SPACE          jump
E              eat the grass in reach
Z              sleep / wake
R              restart, once dead
mouse drag     orbit the camera
mouse wheel    zoom
arrow keys     the camera, if you have no mouse
F11            fullscreen
```

It is the scene's own keyboard (`sceneFrame`), read with the same rates and the
same camera clamps. Health, energy, exhaustion and the sleep that follows it are the
scene's too, so standing still costs energy and a hard run costs more — sleep, or
eat, before it runs out.

To play with somebody, point it at a host:

```sh
# A herd to look at, without touching the editor.
godot/tools/interop.sh herd

# Or join one: paste a ticket from a host and set GOATSD_TICKET in the
# environment, and the scene joins on startup. Your goat is published to the
# session about twenty times a second, so a raylib client sees it.
```

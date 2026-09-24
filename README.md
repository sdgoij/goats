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
- **Day/night cycle**: a clock drives a gradient sky, the sun and moon as two
  spheres on the light's own line arcing overhead (the moon phases as the real sun
  lights it, and the sun carries a glare), with the clouds passing in front of
  either of them, a star field and a scene-wide ambient tint. Hold `T` to
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
- **Pools on the low ground (M20a-M20d′)**: when it rains the water pools in the field's hollows, filling quickly and then draining on its own clock, so a shower leaves puddles behind it rather than taking them away with it. The surface is a mesh that carries the ground under it and each basin's own depth, the water table is anchored to the lowest ground that can actually *hold* water -- so a gully that drains away leaves the pools above it alone -- and it is capped so a pool is always wading depth. The level is a single number a frame and the mesh only rebuilds when the ground does -- and a crater a bang leaves becomes a puddle. It takes the same sun, shadow and blast light as the terrain; its body is tinted and its alpha faded by the water's own depth (a puddle reads thin, a pool deep, and the edge is a band rather than a line); and the surface carries a chop: a wave field short enough that it lives in the fragment shader's normal, driven by the same gust the grass sways to, dying away in shallow water and fading out with the distance -- a pixel that spans a crest would read as tearing rather than as chop. The fresnel is what sells it -- reflective along the surface, transparent seen from above -- and it reflects the hour's own sky. Wading costs the goat speed and energy, and the HUD says by how much; a hoof in the water leaves a ring and a splash (the herd's too), and the grass under a pool is culled rather than standing out of it. It is drawn in the lit pass, so the `L` toggle hides it (the field is still simulated). The reflections are M20e.
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
  disk. The explosives are `Sound`s too: the bang is picked and pitched, faded by
  distance, pooled three deep so two bangs overlap rather than one restarting the
  other, and a chain is quieter at every link. `sfx.fuse`, `sfx.trap` and
  `sfx.blast.close` are declared slots -- read by the trigger and the close-range mix
  -- that ship empty until samples arrive, and a mod can fill any of them like any
  other slot. There is no panning: the engine's `rl` surface has no listener and no
  per-sound position, so a bang behind the goat sounds like one in front -- the mixer
  in `crates/goats/src/audio.rs` is where that would change.
- **No foot skating**: each gait's ground speed is derived from the clip's
  authored stride and stance fraction rather than hand-tuned
  (`speed = stride / (duty * clipDuration)`).
- **A bot herd**: seven autonomous goats wander around the player, each with its
  own procedural mottled fleece, body size and temperament. They graze, stroll,
  trot, and now and then get the zoomies — a run punctuated by jumps. Goats
  collide, so nothing walks through anything else (the player can shove bots
  aside). Nearby bots cast into the shadow map; distant ones get a contact blob.
  Their AI runs on a private PRNG so the seeded weather the harness asserts on is
  untouched. Eating with a belly that is already 85% full gives a little health
  back with the meal (`food.fullBelly` / `fullBellyHeal`) — for the player and the
  herd alike, which is how a bot recovers from the minefield it lives in.
- **Landmines and boobytraps**: the field is *derived* from the session seed rather
  than stored, so every peer agrees where the devices are with nothing new on the
  wire. Walking onto a mine flings the goat and dishes a real crater into
  `terrainHeight` -- bowl, lip and all -- which swallows the grass inside it and
  heals back over; a trapped tuft looks like a meal and replaces it, for the herd as
  much as for the player. The bang throws grit and smoke drawn from a boot-generated
  flipbook, knocks the camera, lights the ground and chains one level to the next
  device. A spent device moves house rather than re-arming, so the field drifts, and
  the bots take the same damage and die to it.
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
- **Joining a modded host**: a `side: "world"` mod is part of the session's
  compatibility set, so a client missing one is refused, and the error names the
  ids. The refusal is also where you ask for them -- `connect <ticket> --pull`
  fetches exactly what is missing, verifies each archive against the identity the
  host announced, installs it beside your own mods as `mods/pulled-<id>.zip`, and
  retries the join once. `goats --pull` makes that the default for every join, and
  a host with a mods directory serves its world mods over the same ticket, so a
  session hosted from a game window syncs a joiner the way `goatsd` does. Nothing
  is ever fetched without that flag or command: a mod is code, and installing one
  is the player's decision. Deleting the `pulled-*` files is the uninstall, and
  `pulled.json` next to them says which host each came from.
- **Paste, don't type**: the console reads the clipboard on Ctrl+V, so the ticket
  can be pasted. `copy` puts the ticket you were given back on the clipboard, and
  Ctrl+C copies the current line.
- **Standalone server**: `cargo run --release -p server` runs `goatsd`, a
  headless host. It runs the world itself and prints its ticket, the seed, and
  joins, leaves, the roster and chat. Stop it with Ctrl-C. `--listen host:port`
  (`-l`) also serves a small status page with the ticket, the wire protocol
  version, the connected-client count, the mods this host is running (with their
  versions), and a download link for each of the client and the whole mods set
  (`--download URL` to point the client link elsewhere); without `--listen`, no
  HTTP server is started.
- **Chat**: in a session, type a line with no leading slash to say it to
  everyone. `@name <text>` (or `say` / `msg <name> <text>`) is a 1:1 whisper, and
  the console marks it as one. Offline, bare text is an error, and `who` lists
  the roster.
- **See each other**: every player's goat is relayed to the others about 20 times
  a second, so you can watch them move. Snapshots are unreliable datagrams and
  the scene interpolates between them.
- **Voice chat**: hands-free -- there is no push-to-talk key. A detector decides
  when you are actually speaking and gates the microphone, so idle room noise is
  never sent, and your voice goes out as Opus on the same unreliable datagram
  channel as the poses. Decoded voice is mixed into one raylib stream, so `M`
  mutes it along with the rest of the audio. A microphone is optional: without
  one the game still plays everyone else, and `GOATS_VOICE_LOOPBACK=1` plays your
  own microphone back for testing.
- **A shared world**: the bots, the weather and the meadow are simulated only by
  whoever hosts -- the game window that ran `host`, or `goatsd` -- and broadcast
  together about 10 times a second. Everyone else mirrors them, so the herd stays
  where the host put it, everyone sees the same storm at the same time of day,
  and the grass one player eats is gone for the others too.
- `leave` ends the session.

Chat is rate limited to a short burst and each line is capped and stripped of
control characters, so a session cannot be flooded by one player. Voice frames
are capped and burst-limited on the relay the same way. Player movement is
client-authoritative: the host relays each player's own goat rather than
simulating it, while the bots it owns outright.

The endpoint binds with n0's public relays plus DNS discovery, so a ticket works
across networks: paste one and it dials, with nothing to configure. The trade is
that address lookup goes through n0, and a session falls back to their relays
when no direct path between the two machines can be found. Verified: two clients
on a home network joined a `goatsd` on a remote VPS over n0.

The sky and the meadow are the server's as well: the weather state machine, its
easing, the day/night clock, the PRNG streams and the eaten grass all run only on
whoever hosts, and ride the same broadcast as the bots. Joining *replaces* the
client's world with the server's -- it does not keep the one it generated before
connecting -- and a client reports the tufts it eats, so the host's meadow is the
one everyone actually grazed. A client still works out its own goat's speed and
energy drain from the server's weather, because those depend on how full its own
belly is. `C` (force weather) and `T` (fast-forward) are host/offline only.

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
slag = { git = "https://github.com/sdgoij/slag", features = ["jit", "raylib", "raygui", "gpu-skinning"] }
```

To build against a local checkout of the engine instead, swap in the commented
path dependency (the `slag/` directory in this repo is ignored by git and is
exactly such a checkout):

```toml
slag = { path = "../../slag/crates/slag", features = ["jit", "raylib", "raygui", "gpu-skinning"] }
```

`gpu-skinning` is the one feature that changes what you *see*: it makes raylib
skin an animated model in the material's shader instead of on the CPU, which takes
the herd off the frame's critical path (`PERF.md` §7b: `bots` 5.5 → 0.5 ms with
7 goats). Dropping the word builds the CPU-skinning client the scene also supports,
which is how those two columns were measured.

Then:

```sh
cargo run             # `dev`: seconds to build, quick enough to play -- the loop
cargo run --release   # the profile the game ships, and the one PERF.md measures
```

## Releases

`.github/workflows/ci.yml` runs on every push and pull request:

- **Scene tests** on `ubuntu-latest` and `windows-latest`: `cargo test
  --workspace --exclude goats` (the mod loader, the protocol, the session and the
  harness's fast cases), then `cargo test --release -p harness -- --ignored`,
  which runs the whole scene on Slag -- the scripted timeline, the mod cases and
  both checked-in fixtures. No Node, no raylib, no display.
- **Builds** for the three supported targets, each uploaded as a workflow
  artifact:

| Target | Runner | Archive |
| --- | --- | --- |
| Windows x86-64 | `windows-latest` | `goats-windows-x86_64.zip` |
| Linux x86-64 | `ubuntu-latest` | `goats-linux-x86_64.tar.gz` |
| Linux AArch64 | `ubuntu-24.04-arm` | `goats-linux-aarch64.tar.gz` |

Pushing a `v*` tag publishes all three archives as a GitHub Release; an ordinary
push only builds and keeps the artifacts. Because the model and every sound are
embedded, an archive is the two executables (the game and `goatsd`), this
readme, the licence, the mod API reference (`APIv1.md`) and two example mods in
`mods/`: `birds.zip` (a world mod) and `fatguy.zip` (a client mod, with a model
and sounds of its own). Both ship zipped, so the released game loads them on the
first run -- a self-test of `.zip` mod loading. Delete either, or run with
`--no-mods`, for an unmodded game.
The AArch64 job uses GitHub's hosted arm64 runners, which a public repository
gets on the free plan.

## Layout

| Path | What it is |
| --- | --- |
| `Cargo.toml` | The workspace manifest: `crates/goats` (its `default-members`, so `cargo run` means the client) plus the networking, scene and harness crates |
| `crates/goats/src/main.rs` | Rust host: installs the JIT + raylib, registers the embedded assets, joins and evaluates the scene |
| `crates/goats/src/net.rs` | The network bridge: JSON lines between the frame loop and a tokio runtime thread |
| `crates/goats/src/audio.rs` | Voice chat: `cpal` capture, the speech gate, Opus coding, and one raylib stream its callback fills |
| `crates/goats/src/game/*.js` | The scene, split into 17 parts (core, model, world, water, lighting, sky, audio, weather, food, bots, goat, ctl, menu, console, net, mods, explosions) |
| `crates/scene/` | The scene bundle: the ordered parts, the joined script and the two `rl` stubs (the null one for `goatsd`, the recording one for the harness) |
| `crates/harness/` | The scene tests: the Rust harness that runs the scene on Slag, with no Node (M15) |
| `crates/mods/` | The mod loader: discovery, manifest validation, ordering and asset reads (pure Rust, no engine) |
| `crates/pull/` | Mod sync (M18): fetch a host's world mods over the fetch ALPN, verify each with the loader, and install it beside the player's own |
| `mods/` | Checked-in example mods: `example/` (a command, a HUD hook, an asset override), `birds/` (a procedural world mod) and `fatguy/` (a client mod with a model of its own and a chain of bad luck) |
| `crates/server/` | `goatsd`: the standalone headless host, which runs the world on a null `rl` |
| `crates/server/src/web.rs` | The optional status page: ticket, protocol version, client count, the mod list and a `mods.zip` download, behind `--listen` |
| `crates/session/` | The peer-to-peer transport and session state machine: iroh, tickets, the join handshake and the roster |
| `crates/proto/` | The session protocol: message types, framing and name rules (no iroh or tokio) |
| `sfx/` | Music, weather ambience and goat vocalisations (embedded into the binary; the long beds are Ogg) |
| `goat_animated.glb` | Exported model (14 clips, textures embedded) — embedded into the binary |
| `goat.blend` | Blender source: armature rig, actions, materials (its `.blend1` auto-backup is git-ignored) |
| `goats.mp4` | The demo clip for the README (22 s, 1280×720, H.264) |
| `tex/` | Knitted-fleece textures (diffuse / normal / roughness / displacement / AO) |
| `tools/inspect_glb.py` | Dump a GLB's images, textures, materials and animations |
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

The scene is split for readability but compiled as one script: `crates/scene`
owns the ordered list, and `SCENE` is a `concat!` of exactly those parts, so
every part shares a single top-level scope (functions hoist across the whole
thing, and the top-level `const`s run in file order). That list is the only place
the order lives — the client, the headless server and the Rust harness all read
it — so adding a part is just adding the file to `crates/goats/src/game/` and one
line to the list in `crates/scene/src/lib.rs`.

`goatsd` evaluates the same scene, from the same list, against a stub `rl`
(`crates/scene/src/null_rl.js`) instead of installing raylib: drawing and input
do nothing, but the clock, the clip table and the terrain function are real, so
the bots and the weather move exactly as they do in the game. Because there is
one list, the two cannot silently simulate different games.

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
streams, one message per stream, as JSON: a frame is small and infrequent, and
worth being able to read in a log. Goat snapshots, the server's world, the world
mods' state and voice travel as unreliable binary datagrams, because those are
what has a 1200-byte budget -- `proto`'s `wire` module is the packed, quantized
form (a bot is 10 bytes there against 86 as JSON). The world mods have a datagram
of their own, so a big mod cannot push the world out. `net.js` turns a snapshot into
a remote goat per peer and a
mirrored herd, and eases toward the latest of each. Voice rides the same datagram
channel, but it never reaches the scene: `net.rs` forwards captured and received
frames to `audio.rs` on a side channel, because Opus bytes are not a line.

## Mods

Drop a directory with a `mod.json` into `mods/` next to the executable (or in
the working directory) and it is discovered at startup: the manifest is
validated, its assets are read and registered under opaque names, and its entry
is evaluated inside a per-mod `goats` handle. A mod can also ship as a single
`.zip` with `mod.json` at its root. `--mods DIR` / `$GOATS_MODS` re-point the
search and `--no-mods` ignores it. In the console, `mod list`,
`mod info <id>`, `mod enable|disable|reload <id>` and `mod key` cover the set,
and the main menu's **Mods** screen toggles them for the session.

While developing a mod, `goats --watch` reloads it when its files change on
disk (the platform's native notification API, not polling), and `mod enable` /
`mod reload` re-read the code from disk too. Editing the entry or `tuning.json`
takes effect without a restart; an asset change still needs one.

Mods also arrive *during* a session. The world mods a host runs are part of the
compatibility set fixed at the join, so a client missing one cannot join at all --
and that refusal is what offers to fix itself: see
[Multiplayer](#multiplayer). What the scene does with a mod that arrives this way
is `sceneModAdd`, and it is the boot path: the metadata lands, the declared asset
slots re-point, the `tuning.json` merges and the entry is evaluated inside its own
registration window, so a late mod is a mod like any other. What does not change is
the freeze: registration opens for that mod and nothing else, and an asset the
scene already loaded stays as it was.

Mods are trusted code with one wall: no filesystem. All I/O is the Rust host's,
and the scene sees only opaque asset names. A mod gets the hook API `goats`
(events, commands, accessors, registries, world extension) plus the engine's
`rl` surface, so it can build geometry and textures in JavaScript. `goats.explosions`
is part of that surface: a mod can read the derived device field (a mine detector is
a mod), set a bang off through the core blast path, take the core devices out of the
field, and hook the `"blast"` event -- `APIv1.md` §4.15.

Three examples ship in `mods/`. `example/` is the small one: a console command, a
HUD clock, a generated `sfx.bleat` override and a `tuning.json`. `birds/` is the
large one: a `side: "world"` flock with a procedural body and wings, a generated
feather texture, seven states (idle, walk, take-off, fly, land, perch, flung), boids
flocking while flying, and multiplayer sync through `world.extend`. It also ships two
macaw calls (its only files) and reaches into the world through the surface M19g added
for mods: a bird sets off the device it walks over, is thrown by it with a squawk, and
one sitting on the goat's back gives the goat
energy and health back. `fatguy/` is the client-side one: a fat guy with a small
guitar who runs for his life, with a model of his own in a slot of his own
(`mods/fatguy/assets/fat_guy.glb`, built by the Blender script beside it), two sound
slots of his own, contact with the goats *and* with the birds' flock (through
`goats.entities`), and a chain of device bangs he is unlucky enough to land on.
All three are
exercised without a window by the scene suite (`crates/harness/tests/mods.rs`
and `birds.rs`), and the two that a release ships are also loaded from a zip by
`crates/mods`'s own cases.

`APIv1.md` is the reference for the manifest, the `goats` surface, the
compatibility handshake and the non-goals.

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
setModelCpuSkinning
drawModel  drawModelEx   modelBounds
modelAnimationCount  modelBoneCount
modelAnimationName   modelAnimationFrameCount  modelAnimationDuration
updateModelAnimation
GPU_SKINNING
```

`rl.GPU_SKINNING` is not a call: it says which way raylib was built (a build
switch, since it also decides the mesh layout at load), and the scene branches on it
rather than assuming. On a `gpu-skinning` build an animated model can only be drawn
through a shader that declares the bone inputs and `boneMatrices`, and
`rl.setModelCpuSkinning(model, true)` is the per-model way back to the CPU pass for
one that cannot be.

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
outside the grass's shader-mode block.) And the lit program depends on who skins:
on the default build raylib deforms positions *and* normals on the CPU before
upload, so the shader needs no bone data, while a `gpu-skinning` build hands the
same job to the shader — which is why each of the three vertex shader families is
compiled twice and the goat is routed to the skinned one (`PERF.md` §7b).

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
# The whole scene suite on the engine: gaits, stats, death, weather, the bot
# herd, the menu, the console, the mods and both fixtures (205 cases).
# `--profile fast` is `release` minus the link it pays for its 13% (see Cargo.toml),
# for local runs only -- CI gates on `--release`, the same build that ships.
cargo test --profile fast -p harness -- --ignored --nocapture

# The fast tests: the mod loader, the protocol, the session, and the harness's
# spike and observation cases
cargo test --workspace --exclude goats

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
- **`goatsd` (or the client) crashes with a stack overflow before it starts.**
  The same thing, one level up: the scene is evaluated on the main thread, and
  Windows gives that thread 1 MiB, which a *debug* build exceeds while loading
  the scene. It is not about mods — `goatsd --no-mods` does it too — and it is
  only in debug: `cargo run --release -p server` starts normally. Rust's test
  threads get more stack, which is why the tests pass.
- **A join is refused with `world mods do not match`.** Both ends print their set
  at startup — `goatsd: world set: <id>@<version>#<hash>` and the client's
  `[mods] world set: ...` — and the refusal names both sides' versions and
  hashes. The usual cause is the same mod hashing differently on two platforms,
  which line endings used to cause; the loader normalises them now, so a mismatch
  means the content really is different (a stale checkout, or a mod edited on one
  side). `mod info <id>` shows the local hash at any time. When it is a mod you
  simply do not have, the refusal says so and `connect <ticket> --pull` fetches it
  (or the host's status page hands you its `mods.zip`). A `differing` one is not
  fetchable: a pull never replaces a mod you already have, so one of you has to
  update.
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
- **Nobody can hear you, or you hear nobody.** Check the microphone before the
  network: a muted device, the OS microphone privacy switch (Windows: "Let
  desktop apps access your microphone") and another application holding the
  microphone all deliver *digital silence*, which the speech gate then correctly
  refuses to send -- the far end hears nothing and the sending side never logs a
  frame. `GOATS_VOICE_DEBUG=1` prints a two-second `rms`/`peak` heartbeat, and a
  `peak` of `0.0000` while you talk means the audio is silent at the OS.
  `GOATS_VOICE_LOOPBACK=1` plays the microphone back through the whole chain on
  one machine, which tells a one-window problem apart from a session one.

## License

MIT.

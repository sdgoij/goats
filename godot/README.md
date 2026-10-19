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
| `assets/sfx/` | The 21 sound files `core.js`'s slot table names, copied for the same reason (Godot exports only `res://`) |
| `scenes/herd.tscn` | The main scene and the port's first world: a client that joins a session and mirrors the host's herd |
| `src/main.gd` | The frame loop: it joins a session, drains the bridge each frame, reads the keyboard, drives the world's clock and weather, and (as a probe) reports whether the mirror converged |
| `src/player_goat.gd` | The local goat: `goat.js`'s gait state machine, movement and stats — the goat you drive |
| `src/hud.gd` | The HUD, drawn: `goat.js`'s `drawHud` — the bars, the read-out, the action prompt, the weather and status lines and the damage pulse (M23) |
| `src/console.gd` | The console, drawn: `console.js`'s ring, line, caret, history, wrap and panel — the overlay that is not a menu (M24) |
| `src/commands.gd` | The command vocabulary: `ctl.js`'s `sceneCommand`, about sixty verbs, the same words the host's stdin channel drives (M24) |
| `src/menu.gd` | The menu, drawn: `menu.js`'s four screens — main, settings, mods, keymap — as a layout a gate can hold, with the Escape walk (M25) |
| `src/settings.gd` | `core.js`'s `SETTINGS` as one object the console, the menu and the HUD all read and write (M25) |
| `src/tuning.gd` | The tuning tree `goats.tuning` reads *and writes* (`APIv1.md` §4.10): every leaf is a `static var` on the module that owns it, `get`/`set`/`merge` are a view of those constants and never a second copy, a write is validated against the value it replaces and routed back to its owner — a subset, and an absent path throws |
| `src/mods.gd` | The mod runtime the scene drives: the extension's `ModHost`, the `mods/` directory (or `user://mods` in a tab, handed over as bytes with the browser's save/reload bridge), the table the Mods screen draws, the first refusal a mod's console verb gets, the per-frame push of the world snapshot a mod reads (`goats.player`, `world`, `bots`, `settings`, `tuning`, `net`, and the built-in half of `goats.assets`), and the per-frame drive of the **compiled** mods `crates/plugin` instantiates (stages 1 and 8) |
| `src/mod_hud.gd` | The mods' drawing, painted: `goats.draw`'s records (`APIv1.md` §4.18) as a `Control` over the game's HUD (stage 1) |
| `src/mod_world.gd` | The mods' drawing, placed: `goats.gfx`'s records (`APIv1.md` §4.19) as a node per call, models imported at runtime with Godot's glTF loader and a mod's **own** mesh built from its arrays into an `ArrayMesh` (stage 1, 8) |
| `src/mod_audio.gd` | The mods' sound: `goats.sfx` (`APIv1.md` §4.20) — every sound the loaded mods declared decoded at boot, played through a pool of players, and a *built-in* slot's own name loaded from `res://` on demand (stage 8) |
| `src/herd.gd` | The mirrored herd: one real goat per bot the host simulates, standing on the scene's ground |
| `src/peers.gd` | The mirrored peers: one real goat per *player* the server relays, eased from their snapshots (M21) |
| `src/bots.gd` | The herd's own AI: `bots.js`'s temperaments, grazing, zoomies, dozing, fleece and push-apart — the scene simulating its own goats when there is no host to mirror |
| `src/terrain.gd` | The heightfield, transcribed from `world.js` and measured against it |
| `src/terrain_mesh.gd` | The ground, drawn: the scene's 48x48 grid as one `ArrayMesh`, rebuilt as the anchor drifts |
| `src/terrain_mirror.gdshader` | The ground, drawn for the mirror: the same mesh under `cull_front`, with a cut at the waterline (M20e) |
| `src/grass.gd` | The meadow, drawn: `weather.js`'s `tuftField` as a `MultiMesh`, following the goat and thinning where it has grazed |
| `src/meadow.gd` | The meadow as food: the cell hash, the nearest tuft, bites and regrowth (`food.js`) |
| `src/explosions.gd` | The devices: the derived minefield, the trapped tufts, the fuse, the bang and the effects (`explosions.js`) |
| `src/craters.gd` | The holes a bang leaves, as a term in the heightfield, healing over four minutes |
| `src/sky.gd` | The day/night curve, the sun's arc, the light and the ambient, transcribed from `world.js` and `lighting.js` and measured against them. The client's sky is rendered by Sky3D and driven from this file's clock and arc |
| `src/sky.gdshader` | The reference sky, drawn: `sky.js`'s raymarched cloud slab as a `shader_type sky`. Kept as the fallback; Sky3D draws the client's sky |
| `addons/sky_3d/` | Sky3D (vendored, MIT): the atmosphere, clouds, fog, stars and sun/moon discs. `main.gd`'s `_set_up_sky` and `_apply_sky` own the hand-off |
| `src/weather.gd` | The weather: `weather.js`'s state machine, the values a session mirrors and the rain's own integration |
| `src/celestial.gd` | The two bodies: `world.js`'s `celestialPlacement` as real sun and moon spheres, with the sun's additive glare. Out of the frame while Sky3D draws its own discs; kept for the fallback |
| `src/rain.gd` | The rain, drawn: `weather.js`'s `drawRain` streaks as a screen-space overlay under the HUD |
| `src/audio.gd` | The sound: `audio.js`'s ten slots, the variety PRNG, the bang attenuation, the weather beds and the mute (M22) — and `built_in()`, the built-in half of the asset slot table (`APIv1.md` §4.11) the mod facade merges with what the mods declared |
| `src/voice.gd` | Voice chat's device half (M13b): the microphone (`AudioStreamMicrophone` on a muted capture bus) and the ear (an `AudioStreamGenerator` at the wire's 48 kHz). The *codec* is the bridge's (`voice.rs`, over a shared `crates/voice`) |
| `src/water.gd` | The water: `water.js`'s hydrostatic table over the terrain grid, and the drag and drain of wading in it |
| `src/water_mesh.gd` | The water's surface as an `ArrayMesh`: the grid's ground, cut to the quads that can ever be wet |
| `src/water.gdshader` | The surface, drawn: `WATER_VS`'s vertex lift, `WATER_FS`'s absorption, `WATER_FS`'s chop and `WATER_FS`'s wake, under Godot's own light and reflection |
| `src/water_splash.gd` | The splashes, drawn: `water.js`'s pooled drops off a fixed `SPLASH_MAX` slot table, as one `MultiMeshInstance3D` |
| `src/water_reflect.gd` | The reflection's setting: `water.js`'s three tiers, the leaf's clamp and the promise a build can keep |
| `src/water_mirror.gd` | The reflection's pass: `renderWaterMirror`'s second camera, in a `SubViewport` sharing the scene's world (M20e) |
| `web/index.html` | The shell the browser build is served in: the client in a 16:9 stage, the client switcher, and the mod editor dock (`WEB.md`) |
| `tools/` | Headless verification scripts, `interop.sh`, and the web build/package scripts (`build_web.sh`, `package_web.sh`) |

`crates/godot` is the GDExtension itself — the only crate in the tree that can
see Godot. It exposes `NetBridge` (the networking bridge over `session` and
`proto`: `host`, `join`, `say`, `consume`, `pose`, `world`, `blast`, `leave`,
`poll_events`, `shutdown` — `host` and `join` also carry this client's world-mod
set, so the join handshake compares the same `crates/mods` digest the raylib client
presents — and voice, M13b: `push_voice`, `pull_voice`,
`set_voice_gain` and `voice_state`, whose codec is a shared `crates/voice` and whose
`voice.rs` resamples and frames what the scene's capture bus hands over) and `ModHost`
(the embedded Slag engine plus the `goats` facade a mod sees: the API's drawing surfaces
`goats.draw`/`goats.gfx`, the readable groups -- `player`, `camera`, `world`, `bots`,
`settings`, `tuning`, `net` -- which it answers out of the world snapshot the scene pushes
every frame, and `goats.assets`/`goats.sfx`/`goats.entities`, whose halves it resolves: the built-in
asset slots out of that same snapshot, the declared ones out of the mod table, and an entity offer
out of another mod's own callback (`push_world`, `set_scene_call`), and the **world-mod set and
state** a session needs: `world_mod_refs` for the join digest and
`world_mods_json`/`apply_world_mods` for the datagram). The facade is
`crates/godot/src/prelude.js`, and the loader it drives is the `crates/mods`
crate; `mods.gd` in the scene is its only client). It is a workspace member rather
than a project of its own so it inherits
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

Thirty-six headless gates, all `SceneTree` scripts that exit non-zero on failure. `tools/gates.sh`
runs every gate that needs no server -- discovered rather than listed, so a new one is picked up
existing, with a timeout each:

```sh
sh godot/tools/gates.sh              # GODOT_BIN=…, GATE_TIMEOUT=… if the defaults do not fit
```

...and one at a time, which is how a single failure is debugged:

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

# ...and a mod discovered from **memory** -- the browser's and the editor's source, with no
# directory behind it -- is validated, run, edited and reloaded through the same parser.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_mod_source.gd

# ...and the *scene* runs them: the runtime `main.gd` wires, the failures the host names in
# the table the Mods screen draws, and a mod's own verb reaching the console (stage 1).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_scene_mods.gd

# ...and a mod toggles off and on for the session: the Mods screen's own Enable/Disable, the
# verb and the stream that follow the mod, and the session guard a world mod is refused by
# (stage 8's `modSetEnabled`).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_mod_toggle.gd

# ...and a *compiled* mod -- one that ships a `.wasm` module and no JavaScript at all -- loads,
# is driven by the scene's own frame, reports a HUD bar and a wrong-ABI module is refused by name
# (stage 8's last slice, `ABIv1.md`).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_wasm_mod.gd

# ...and a mod's `goats.gfx` draws become nodes in the world: a cube of its own size where it
# asked, and the repository's own fatguy glTF imported at runtime, with the tree holding
# exactly the last frame's draws (stage 1).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_mod_gfx.gd

# ...and a *mod* reads its own identity and the live world back: `goats.api`/`game`/`mod`,
# the mod table, `log`/`warn`/`error`, every world group -- the goat, the camera, the
# weather and the wind, the herd, the settings, the session and the tuning tree -- against
# the scene's own values, from inside a `hud` hook where a mod actually reads them, with
# `terrainHeight` crossing the callback seam; the **writes** land on the scene's own fields,
# the tuning tree among them (a clamp, an int, a nested leaf, a merge, a leaf the scene owns,
# and the `tuning` event that follows); the **asset slots**
# (both halves, and the two code-side writes staged in an entry of their own)
# and the **entities** one mod offers another -- both halves of the first, and the second from
# a *different* mod's handle -- and a world mod's **streams** against the reference's own
# derivation (stage 8).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_mod_surface.gd

# ...and a *mod* builds its own geometry: a mesh from flat arrays and an image from its own
# pixels become an `ArrayMesh` and an `ImageTexture`, wound for this client's culling and
# placed with an axis-angle rather than a yaw, and `goats.gfx.unload` frees one -- so a mod
# that generates its shapes reads the API and not the engine's `rl` (stage 8).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_mod_mesh.gd

# ...and a *mod* plays its own sound: a declared asset name resolves to a decoded stream with
# a length, a name nothing declared answers null, a *built-in* name resolves the same way,
# and the play reaches a player -- the API's answer to `loadSound`/`playSound`, and the last
# engine capability either example read (stage 8).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_mod_audio.gd

# Two Godot peers meet over iroh: host, join, roster, chat, goat snapshots -- and then a
# third joins, so the world a host publishes, a client's adopted snapshot and both
# directions of a bang (M19e) are all held against the shipping crates. This one brings
# up real endpoints, so it takes ~20-30 s.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_net.gd

# The *scene's* world payload -- `_world_payload`, which is `net.js`'s six
# `scene*`/`netWorld*` functions in one place -- field for field against `proto`'s
# structs, and then through `NetBridge.world`, the method that is the schema check.
# No socket: this is the half `verify_net.gd` cannot reach.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_hosting.gd

# The heightfield against the JavaScript one (it has to agree with the host).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_terrain.gd

# The drawn ground: the scene's 48x48 grid, its winding, its normals, its drift.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_terrain_mesh.gd

# The sky's curve, the sun's arc, the light and the ambient, against the JS ones.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_sky.gd

# The Sky3D hand-off: the addon is the scene's sky, its clock is the port's, and
# the weather reaches its cloud covers.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_sky3d.gd

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

# The devices: the minefield's derivation, where a fired device moves, the crater
# dish -- and a goat standing on a mine, end to end.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_devices.gd

# The weather: 5400 frames of the state machine and the C key, the two bodies over an
# hour x cloudiness grid, and the rain's pool after every drop has wrapped.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_weather.gd

# The water: a scripted rain history through the table, the depth at five probes, the
# HUD line, the two bisect handles, the chop's own wind and wave clock -- and that the
# goat's speed and drain use it.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_water.gd

# The water's surface: the cut that decides which quads can ever be wet, all 2304 of
# them, and the winding Godot needs to draw them at all.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_water_mesh.gd

# The herd: 3780 frames of `bots.js`'s own AI -- a spawn, a grazing walk and a bite, a
# shower, a flung bot, a killed one and its respawn, the push-apart, and the water
# waking a sleeper -- with every bot's position, yaw, phase, timer, mode, satiety,
# health and clip compared frame for frame.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_bots.gd

# The mirror: what a world snapshot does to the herd a *client* sees. A list is adopted and
# its length is the flock's, a shorter one drops the goats the host no longer names, an
# **empty** one is a herd of none (the host's size is a setting, so zero is a legitimate
# world), and a world that leaves `bots` out keeps what this end has -- which is
# `netApplyWorld`'s own early return, and the one place the two cases differ.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_herd.gd

# How a fraction through a clip becomes the frame a goat is drawn at: `model.js` `poseModelOn`,
# which is a **clamp** -- a phase of 1.0 is the clip's *last* frame -- held against all four
# places that pose a goat (the local one, a bot, a peer and a mirrored bot) and against the
# loop's own far edge. It is also where the port's spelling of it shows: Godot *stops* a player
# sought to exactly its length, so the last frame is asked for a hair short of the end.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_pose.gd

# The wake: 120 frames of rings and drops (eighteen of them dry), the two water tests
# told apart where they disagree, and the grass a deep pool hides against `water.js` and
# `weather.js`.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_water_wake.gd

# The HUD: `drawHud`'s state word over every move/mode/pause, the status line's composition, the
# weather line's terms, a bar's fill and the damage pulse's two numbers -- against `goat.js`'s own.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_hud.gd

# The audio: `audio.js`'s variety PRNG, its variant/copy rule, the bang attenuation and the
# chain, and the two gains the menu will drive -- against `audio.js`'s own.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_audio.gd

# The peers: `net.js`'s mirror of the other *players* -- the one-shot gaits, the role table
# over every model that could lack a clip, and the three easing lines -- against `net.js`'s own.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_peers.gd

# The reflection: the leaf and its clamp, the wish/promise a build keeps, the setting's own
# words, what each tier's pass draws, and that the tier reaches the surface's material and
# the pass under the names the shader actually declares.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_water_reflect.gd

# The console: the shell's ring, line, caret, history, wrap and panel arithmetic against
# `console.js` and `drawConsole`; the vocabulary's pure rules (`help`, `ctlArg`, `ctlRound`,
# the wrap, the panel's own numbers) against `ctl.js`; and then the same vocabulary run
# against the *live* scene, verb by verb (M24).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_console.gd

# The menu: four screens at four viewport sizes against `menu.js`'s own layout arithmetic
# (kind, word and rectangle for every panel, group, label, button, toggle, slider and combo),
# the keymap table and the Escape walk, every interactive control hit at its own centre and
# clicked, one real click pushed through the viewport to the scene's own menu — and then every
# control run against the *live* scene, asserted against the world rather than against the
# setting (M25).
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_menu.gd

# Voice (M13b): a 440 Hz tone into one host's codec, Opus frames down a real iroh
# session, and the *same* tone 11 520 samples later out the other -- then the master
# mute, which silences the samples without silencing the decoding. A microphone cannot
# be gated, so this is the codec and the wire rather than the two devices themselves.
"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --headless --path godot \
    --script res://tools/verify_voice.gd
```

All thirty-five pass against Godot 4.7.2 today. Five more need a live session and are run by
`tools/interop.sh` instead: `verify_interop.gd` (join and refuse), `verify_peers_live.gd`
(two clients, `interop.sh pair`), the herd-death pair — `verify_herd_death.gd` (a client's own
death and respawn against `goatsd`, `interop.sh death`) and `verify_herd_host.gd` (the same question
with this scene *hosting*, `interop.sh hostdeath`) — and `verify_host_reference.gd`, the same host
the *reference* client joins (`interop.sh jsjoin`, which needs a window).

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
received. Offline the picture carries the scene's own **herd** as well: seven goats of
different sizes and coats, each on its own coat's mottled fleece (`bots.gd`), standing
on the ground with Godot's shadows. In a session the seven goats are the host's,
mirrored in beside yours (`herd.gd`) — and they wear the authored fleece rather than a
coat, because the mirror is the one slice that does not know which spec a bot was born
with until it also reads the host's seed table. What is
still Godot's rather than the scene's is the *lighting model*: the terrain, the
grass and the goat are lit by Godot materials under a `DirectionalLight3D` with
Godot's shadows, not by the scene's own lit program and hand-rolled shadow map
(`PORT.md` section 5). The port's colours also run through Godot's linear pipeline;
the sky and the ground/grass/bot albedos convert their authored sRGB for it
(`PORT.md` section 9). The sky
and its two bodies are Sky3D's now — the port's own `celestial.gd` discs are out of
the frame, and the addon draws its sun and moon in the sky shader so the clouds can
cover them — while `sky.gd` still owns the clock, the arc and the `light` factor gameplay
reads. The rain is a `Control` drawing the scene's own streaks, and
the water is a `spatial` shader carrying the scene's vertex lift, its absorption, its
chop and its wake under Godot's own light and reflection — the rings are three `vec4`
uniforms and the splashes are a `MultiMeshInstance3D` (`water_splash.gd`), a deep pool
thins the meadow where it hides it (`grass.gd`), and the reflection is the port's **own
mirrored pass** (`water_mirror.gd`) — the goat, the herd and, on a second draw of the ground
itself, the shore — because Godot's `ssr_enabled` does not reach a transparent surface (M20e).
The sound is `audio.js`'s ten slots (`audio.gd`, M22): a bleat is one of six samples at a random
pitch, a bang falls off with the distance past its own radius and drops its grit a beat later,
and the three beds swell with the weather — the one part of this port a picture cannot show, and
so the one whose gate can hold only the rules rather than the result. Voice (`voice.gd`, M13b) sits
on that shelf beside it: its codec is gated (`verify_voice.gd` carries a tone end to end), but the
*microphone and the ear themselves* need a sound card, so no run here can hear them either.
And the HUD is one `Control` drawing `drawHud` — the bars, the read-out, the action prompt, the
weather and status lines and the damage pulse, at the scene's own pixel coordinates; and the
**console** is a second one drawing `drawConsole` — a translucent panel over the top half, the
scrollback's last visible rows in the scene's own five colours, then the line and its caret
(M24). It is the overlay that is not a menu: it never touches the world, and `main.gd` keeps the
keyboard out of the goat while it is up, so one player opening it pauses nobody. And the **menu**
is a third — `menu.js`'s four screens drawn at the scene's own arithmetic, with a `Settings`
object the console, the menu and the HUD all share (M25). It is the opposite of the console in the
one way that matters: a menu *is* a `uiScreen` value, so it freezes the world by `dt` while the
console must not, and the scene draws the HUD *or* a menu rather than one over the other — the
dimmed world behind a panel has no read-out on it at all. What is left of the UI is the `Mods`
screen's list, which waits on the scene loading mods (stage 1).

**Nine** environment variables stage what there is no console or menu for yet: `GOATS_HOUR` pins the
clock, `GOATS_CLOUD` the cloudiness and `GOATS_FLOOD` the water's level — the last of
those is `water.js`'s own `flood <h>` console verb, and it is the only way to *see* a
pool, because a downpour floods the hollows and nothing else, and with `GOATS_CAM` aimed
the same flood is the only way to *see* a wake follow the goat. `GOATS_REFLECT=sky|ground|mirror`
is the water's reflection (`setting reflect`'s own words, M20e), and it is a *second camera*
rather than a march: `sky` runs no pass and stands on the sky alone, which is what shipped
before M20e; the default `ground` runs the pass drawing the ground and not the goat; and
`mirror` runs the pass drawing everything but the surface and the meadow, so the goat is in
the water. (The ground is a second draw of the terrain's own mesh, because a heightfield's
quads face away from a camera under it — `terrain_mirror.gdshader`.) It is
grazing-angle-strong and near-invisible from above, which is what the
scene's own fresnel says: `GOATS_CAM=0.7,0.10,6` is the aim that shows it. `GOATS_WEATHER` pins the
state machine's *state*, which is what a downpour needs — the rain is drawn and not
measured, so only a picture can judge it; `GOATS_CAM=yaw,pitch[,dist]` aims the camera,
which is the only way to photograph the two bodies, because they sit on the light's line
*behind* the boot camera and a person would drag the mouse; and `GOATS_BOOM` sets off a
bang beside the goat a moment into the run, which is how a bang and the hole it leaves
can be *looked* at rather than measured. All of them are ignored while a session is up,
because the host owns the world.

Six of those seven are now a *console verb* as well, which is what they were standing in for:
`time <h>` for `GOATS_HOUR`, `setting cloud` for `GOATS_CLOUD`, `weather <state>` for
`GOATS_WEATHER`, `camera <yaw> <pitch> <dist>` for `GOATS_CAM`, `flood <h>` for `GOATS_FLOOD`
and `setting reflect` for `GOATS_REFLECT`. Only `GOATS_BOOM` maps to no verb. The last two are
about *looking*: **`GOATS_CONSOLE=<line>`** runs a console line at boot with the panel open, and
**`GOATS_UI=<screen>`** opens one of the menu's four screens at boot, because a headless gate has
no rasteriser and the panels are the one part of this port only a picture can judge.
`GOATS_CONSOLE=help` and `GOATS_UI=settings` are what `shot.png` carries.

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

# The same scene *twice* against one host: two clients whose goats face each other,
# which is the only way to see a `peer` -- a peer frame is somebody else's goat, so
# one client can never produce one (M21).
godot/tools/interop.sh pair

# The mirror through a client's *own* death: joins the shipping host, dies the way a player
# dies, lies there, and asks whether the herd it mirrors moved across each window -- the
# death and the respawn both.
godot/tools/interop.sh death

# ...and the same question with *this* scene hosting: the host probe prints its ticket, a
# joiner is handed it, and both ends are read -- because a herd freezes on a client either
# because the host stopped publishing or because it published a herd that stood still.
godot/tools/interop.sh hostdeath

# The host the *reference* (raylib/JavaScript) client joins: this scene hosts, prints its
# ticket, and the shipping client is pointed at it over its own stdin/stdout console. Every
# other mode is Godot with Godot or Godot with `goatsd`, so this is the one that turns a stale
# extension or a `PROTOCOL_VERSION` mismatch -- which leaves the client silently un-joined --
# red. Needs a window, like `shot`.
godot/tools/interop.sh jsjoin

# No server at all: the scene must boot and keep running, and its own herd with it.
# Needs no goatsd.
godot/tools/interop.sh offline

# ...and render it: the real scene against a live host, in a window, ten seconds
# in, with the herd standing on the ground. Needs a GPU and writes godot/shot.png.
godot/tools/interop.sh shot
```

It reads `GODOT_BIN`, `GOATSD_BIN` and `GOATS_BIN` (the reference client, `jsjoin`) if the
defaults do not fit.

## Building the client

The extension (`crates/godot/build.sh`) is a *developer* build: Godot loads it out of the project
while you work. The **client** a player gets is a Godot **export**, which packs the project, the
assets and the extension library into one directory:

```sh
# The library the export bundles, for the target platform, into the descriptor's own path.
sh crates/godot/build.sh release

# `export_presets.cfg` has one preset per target the reference client ships for -- `Windows
# Desktop`, `Linux x86_64`, `Linux arm64` -- plus `Web`, which is the Godot client's own
# (see `WEB.md`). Their names say the platform and the architecture. The templates for the
# editor's own version are installed once (`Editor > Manage Export Templates`, or the
# `.tpz` unpacked into the editor's `export_templates/`).
Godot --headless --path godot --export-release "Windows Desktop" dist/goats.exe
Godot --headless --path godot --export-release "Linux x86_64"   dist/goats
```

The client is **`goats`** -- the same name the raylib client's binary has, and `goats.exe` on
Windows: the export's output path is what names the binary, not the project's own "Slag Goat".
Beside it the export writes its `.pck` (the preset leaves `embed_pck` off), the extension library the
descriptor names for that platform (`goats_godot.dll`, `libgoats_godot.so`) copied in, and, on
Windows, `goats.console.exe`, the preset's console wrapper.

A client that *boots* without the bridge is as broken as one that does not boot, so there is a smoke
check. The console wrapper on Windows and the plain binary on Linux -- an export is GUI-subsystem on
Windows, and a shell that launches one does not wait for it:

```sh
./dist/goats.console.exe --headless --quit-after 120   # ...`dist/goats` on Linux
# Initialize godot-rust (API v4.7.stable.official, runtime v4.7.2.stable.official, ...)
# offline: no GOATSD_TICKET, so there is no session to mirror
```

The first line is the extension loading; the second is the scene running. Both, and a zero exit, are
what CI asserts.

## The browser

The Godot client also runs in a tab: `crates/godot` builds as an Emscripten side
module, `export_presets.cfg`'s `Web` preset packs it, and the project switches to
Godot's Compatibility renderer under the `web` feature tag. `WEB.md` is the whole
of it -- the build script, the flags, what is compiled out and why, and how to
serve the result. The networking transport is gated out for `wasm32`, but the
browser still joins a session: it speaks the native bridge's JSON lines to
`goatsd --gateway` over a WebSocket (`WEB.md`). Hosting, voice and compiled mods
remain native; the scene itself is unchanged and runs offline without a
gateway.

The export is wrapped in `godot/web/index.html`, a dependency-free shell that
frames the client at a 16:9 stage (YouTube-player sized), carries a client
switcher, and docks the mod editor (Console, Files, Details, Tuning) along the
right edge of the page. The switcher's second entry is the raylib client's own
browser build (`sh web/build.sh client` -> `web/dist/`), which
`godot/tools/package_web.sh` stages as `reference/` when it is present; a HEAD
probe leaves the option disabled for a Godot-only package. The export goes into
`client/` and the shell to the root of the served directory.

Mods in a tab are the build's own **birds** and **fatguy** (staged as zips by
`package_web.sh`) plus anything in `user://mods` (IndexedDB-backed): `mods.gd`
hands each to `ModHost::load_mod_files`, and `crates/mods` parses the same
manifest a directory does through its in-memory source. The page's dock talks to
the client over `window.goatsModsSave` / `goatsModsReload` / `goatsModsRead` /
`goatsModsState`, plus `goatsConsoleState` / `goatsConsoleRun` and
`goatsTuningState` / `goatsTuningWrite`; `WEB.md` has the request shapes.

## Continuous integration

`.github/workflows/ci.yml` runs the port for the same three desktop targets the reference client
ships for -- `windows-x86_64`, `linux-x86_64`, `linux-aarch64` -- in two desktop jobs plus a browser
job, and in this order:

* **`godot`** (every push and pull request, and only once the scene's own Rust tests are green:
  `needs: test`) is the *tests*: the extension built in release, Godot installed by release and
  digest, one `--import` pass so the descriptor is registered, `tools/gates.sh` (36 gates) and the
  session modes that need no window (`tools/interop.sh join refuse herd pair death hostdeath pull
  offline`). The extension and every gate log are uploaded, so a red run can be read without
  reproducing it.
* **`web`** (every push and pull request, and only once `test` and `godot` are green) is the
  *browser build*: Emscripten 5.0.7 and a pinned nightly build the extension; the Web export and
  the shell page are packaged under `dist-web/` and uploaded as a GitHub Pages artifact.
  **`deploy-web`** (a push to `main`, or a manual run) publishes it to GitHub Pages -- the shell at
  the site root, the client under `/client/`. Pull requests build the page but do not deploy it.
* **`godot-build`** (on `v*` tags and by hand, and only once `godot` is green) is the *release build*:
  the same extension, the export templates, the export above, the smoke check, and a package with
  what a reference release carries -- `goats`, `goatsd`, `README.md`, `LICENSE.md`, `APIv1.md`, and
  `mods/` with the two example mods zipped and the same `README.txt` -- plus the `.pck` and the
  extension library the Godot client itself needs.

The two modes that need a display -- `shot`, which renders a window, and `jsjoin`, whose joiner is
the raylib reference client -- are left to a machine that has one. The reference client's fourth
release target, Android, is not one the port has: there is no touch layer and no Android preset here.

## Running the scene

Pressing play with no `GOATSD_TICKET` is the normal way to play it: **a session is
optional**, and the scene says so and then runs. What you get is a goat you drive, on
the ground the game's own heightfield describes, in a meadow it can eat, under the
scene's own sky — and **a herd of seven goats of its own**, with their own temperament,
coat and opinions (`bots.gd`). They graze, stroll, trot, occasionally sprint, rarely
doze, wander around you and come back when they drift too far. They eat the same tufts
you do, so the meadow thins for them too; a bang throws and can kill them; and they
push each other — and you — apart rather than walking through anybody.

Join a session and the herd stops being yours: the host owns the bots' AI, and the
scene mirrors the seven goats it is sent instead (`herd.gd`). Your own goat is the same
either way. If somebody *else* joins too, their goat arrives as a peer and is mirrored
beside you (`peers.gd`, M21) -- and a bite you take in a session is reported to the host,
whose meadow owns it.

```
W / S          walk forward / backward
A / D          turn
SHIFT          run            CTRL   trot
SPACE          jump
E              eat the grass in reach
Z              sleep / wake
R              restart, once dead
C              the next weather state (offline only; for previewing the cycle)
T (hold)       fast-forward the clock
L              toggle lighting      K    cycle shadows
B              the sky shader       J    the water
mouse drag     orbit the camera
mouse wheel    zoom
arrow keys     the camera, if you have no mouse
P              freeze the world (the view keeps running)
M              mute
F11            fullscreen
`              the console (type `help`)
ESC            the main menu (`ESC` again resumes; from a sub-screen it goes back)
```

It is the scene's own keyboard (`sceneFrame`), read with the same rates and the
same camera clamps. Health, energy, exhaustion and the sleep that follows it are the
scene's too, so standing still costs energy and a hard run costs more — sleep, or
eat, before it runs out.

Backquote opens the **console**: the same shell `console.js` draws, with the same sixty-odd
verbs the host's stdin channel takes, so `help`, `state`, `weather rain`, `camera 90 20 6`,
`flood -0.9`, `setting reflect mirror`, `grass`, `traps`, `craters`, `walk`, `step 10` and the
rest all work while the world keeps running. It is an overlay and not a menu — nothing about
it pauses anything — and it swallows the gameplay keys while it is up, so typing never moves
the goat. In a session it is also the chat box: anything that is not a verb is a line said,
and `connect <ticket>` / `leave` / `who` / `copy` are how a session is driven by hand.

**Escape** opens the **menu**: `menu.js`'s four screens, `main` first and then `Settings`,
`Mods`, `Keymap` and the `` ` ``-equivalent `Console` button, plus `Quit`. A menu freezes the
world and takes the keyboard and the mouse, and every control on the two screens that matter
does something real — the audio gains, the lighting, the shadow map, the sky program, the cloud
quality, the water's reflection, fullscreen and the herd's size. The `Mods` screen now lists
what the runtime found (`mods.gd`, stage 1): a row per mod with its version and side, `FAILED`
and the error on the ones whose entry threw, and an Enable/Disable button wired to the runtime's own
`modSetEnabled` -- a toggle turns a mod off for the session, and a world mod is refused while a
session is up. `mod list`, `mod key`, `mod enable` and `mod disable` in the console answer from the
same table, and `mod key` prints the world-mod digest a host's refusal names.

**Mods are loaded from `mods/` at boot**, the directory the raylib client reads:
`GOATS_MODS` if it is set, else `mods/` beside the project, else `mods/` beside the executable;
`GOATS_NO_MODS` skips the search; `GOATS_WATCH` starts the file watcher. Every entry is evaluated in its own `goats` handle, and one
that throws costs its own row rather than the load -- of the repository's five, all five load: the
examples no longer read `rl` at all, and the flock's last missing member (`goats.world.extend`) is
in. A mod's `console.log` reaches the
console and a mod's registered verb reaches the console first, so `hello world` answers the
example's `hello`.

**A mod is re-read from disk on a command or on its own** (`APIv1.md` §2.5). `mod reload <id>` --
and an enable of a mod that is already loaded, which is the same action -- tears the live instance
down (its `shutdown` hook, its hooks, its commands and its registrations), reads the manifest,
entry, tuning and assets again, and runs it again; a `tuning.json` edit lands with it. `GOATS_WATCH`
starts the file watcher, which reloads a mod about 250 ms after its files stop changing, so editing
a mod's source re-runs it without a restart.

**A mod turns off and on for the session** (`modSetEnabled`, `APIv1.md` §4.1). The Mods screen's
Enable/Disable button and the console's `mod enable`/`mod disable` go through `Mods.set_enabled`,
which tears the mod's instance down -- its `shutdown` hook first, then its hooks, its commands, its
streams, its world extensions and its offered entities -- and re-reads and re-runs it on the way
back: an edit on disk takes effect on the toggle and a mod that failed its first run gets a clean
second chance. A *world* mod may not change mid-session, because the host fixed the compatibility
set at join and changing one would desync a joiner; a client one toggles whenever a player likes.
It is session-only, as the screen says: a restart restores the `mods/` directory.

**A mod may also ship a `.wasm` module and no JavaScript** (`ABIv1.md`): the fifth of the
repository's mods does exactly that. `crates/godot` links `crates/plugin` -- the same host the
raylib client and `goatsd` drive -- so the module is decoded, instantiated against the capabilities
its own import list asks for, and stepped from Rust, and `mods.gd`'s frame is what drives it. The
two things a module produces are scene values: the HUD bar a `side: "client"` module reports (drawn
by `hud.gd` as `belly (wasm)`) and the opaque bytes a `side: "world"` one published, which the host
puts on the **mods datagram** beside the JavaScript world mods' streams and rows (the merge is
`ModHost::world_mods_json`, its `data` folding in each compiled module's bytes). `mod info
<id>` shows what the module made of itself -- its ABI, its imports, its frame count, its last log
line -- and `verify_wasm_mod.gd` holds the whole path, including the refusal of a module built for
another ABI.

**A mod draws through the API's own surfaces, and the port paints them** (`APIv1.md` §4.18, §4.19):
the example's HUD clock is a `goats.draw.text` line, which becomes a record the extension queues
and `mod_hud.gd` paints over the game's HUD; `goats.gfx.draw.cube` and `draw.model` from a
`draw3d` hook become nodes in the world, with a model's glTF imported at runtime from the asset
the mod declared. That is deliberately the API's own surface rather than the engine's — there is
no `rl` in this build at all, because `rl` is raylib, and a mod written against it is a mod
written against one client. A mod's **own** geometry and images are in too now: `goats.gfx.mesh`
takes the flat vertex arrays the heightfield is built from, `goats.gfx.texture` a `size`×`size`
block of pixels, `goats.gfx.bind` draws one in the other, and `goats.gfx.draw.mesh` places it with
an **axis and an angle** rather than a yaw — so a mod that generates its shapes reads the API and
never the engine library. A mod's own **sound** is in too (`goats.sfx`): `load(name)` resolves an
opaque asset name to a handle or `null` and `play(handle, volume, pitch)` sounds it, and
`goats.gfx.unload` frees a shared mesh — so between them `birds` and `fatguy` have **no engine
capability left to read** -- and as of the rework they do not read it: both examples are API-only,
which is what makes them the *same* files on both clients, and what is left is the members on this
side (`world.extend`, `goats.water`, two `player` writes) rather than a rewrite on theirs.

**A mod reads the live world through the API's own accessors** (`APIv1.md` §4.5–4.12). The
scene builds one snapshot of the world each frame — the goat, the camera, the weather and the
wind, the herd, the settings, the session and the tuning tree — and the extension keeps it, so
`goats.player.state()`, `goats.world.weather()`, `goats.bots.list()` and the rest answer out of
the last frame without a crossing per read. `goats.world.terrainHeight(x, z)` is the exception,
because it is a *function* of the world rather than a value: it calls back into the scene's own
`Terrain.height_at`, craters and all. The **asset slots** are in as well (`goats.assets`, §4.11),
and they are the one group with two owners: the *built-in* half is the scene's (`audio.gd`
derives it from the table it plays from, so the game's own files are named in one place) and the
*declared* half is the host's, in the mod table — and the facade merges them the way the
reference client does, fills replacing and joins appending. `get`/`all` answer for a built-in
name exactly as for a mod's, so the name they hand back resolves through `goats.gfx.model` and
`goats.sfx.load`: a mod can ask the game for its own model or its own bleats without knowing a
path. And **one mod can see another's things** (`goats.entities`, §4.16): a mod `offer`s the
entities it simulates as `[x, y, z, r]` rows from a live callback, any mod `near(x, z, range)`s
another's, and the two are the whole of it — no scene-level entity system, and nothing on the wire,
because what travels is what a mod chooses to publish through `world.extend`. A callback that
throws costs only its own mod's rows and is named on the console, which is what the port's `catch`
has to be shaped around (see `PORT.md` §9: a host call inside a `catch` trips Slag's environment
stack, so the failure is recorded and said after the loop). A `side: "world"` mod also gets its
own **seeded stream** (`goats.world.registerStream` / `goats.rng`, §4.13), derived from the session
seed through the same `sceneUseSeed` moment the scene derives its own four at. Its state then
travels on the **mods datagram** -- a second datagram of the mods' own, so a greedy mod loses only
its own state -- and a joiner *adopts* the streams and takes the rows each extension published
through `world.extend`, so the flock a host simulates is the flock a joiner goes on computing rather
than a second one. **The writes are in** for every group the scene owns (`APIv1.md` §4.5–§4.12): a
mod teleports and turns the goat, sets its mode and restarts it; moves the camera (partial, with
the API's own clamps); sets any setting -- `herd` included -- through the scene's own
`applySettings`; drives the clock and the weather (local-only, and they answer `false` for a client,
which is what the API documents); says a chat line; and resizes the herd and works its four bot
handles; and **retunes the game** (`goats.tuning.set`/`merge`, §4.10). Each crosses the same
`Callable` seam `terrainHeight` does -- `main.gd`'s `_mod_call` -- so a slider in the menu, a line in
the console and a mod's call are one code path. `explosions.armed` is in too: the request belongs to
the *mod* that made it, so `armed(false)` takes the core devices out of the derivation and a mod
that unloads hands the field back. **The tuning tree is writable**: every leaf is a `static var` on
the module that owns it, a write is validated against the value it replaces (`tuningCoerce`: finite
numbers, the leaf's clamps and integer-ness, an array stays an array) and written back to that
module, a mod's `tuning.json` merges before its entry runs, and every change is said as the `tuning`
event by the frame that follows it. The tree is a subset of the API's, and a path this build has not
got throws. The two slot writes (`assets.override`/`add`) are in too, gated the way the reference
client gates them: legal only while a mod's *own entry* runs, and refused anywhere else with its own
`registration is closed` (`APIv1.md` §4.11). **Registration closes** when the load is over: the scene
calls `goats.freeze()` once every entry has run, so `goats.frozen()` answers `true` and a hook, a
verb, a registry or a slot write asked for after that is refused -- unless it is the mod's own entry
again, which a reload re-opens.

To play with somebody, point it at a host:

```sh
# A herd to look at, without touching the editor.
godot/tools/interop.sh herd

# Or join one: paste a ticket from a host and set GOATSD_TICKET in the
# environment, and the scene joins on startup. Your goat is published to the
# session about twenty times a second, so a raylib client sees it.
```

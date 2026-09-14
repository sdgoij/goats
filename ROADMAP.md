# Roadmap & Wishlist

Planned work for the goat sandbox, roughly in dependency order. This is the
wishlist plus the technical path for each item; milestones are checked off as
they land.

Guiding principles:

- **Gameplay lives in JavaScript.** The scene, rules and stats stay in
  `crates/goats/src/game/`; engine work is limited to small, generic additions
  like a few 3D primitives and shader plumbing.
- **Blender is the source of truth for the goat.** New poses are authored as
  clips in `goat.blend` and re-exported, exactly like walk / trot / run / jump.
- **Verify numerically.** Every animation is checked for ground contact, IK
  soundness and loop closure, and every state machine change gets a case in the
  scene harness (`crates/harness/tests/`, `tools/goat_logic_test.js` before M15).

Effort is a rough size: **S** ≈ an afternoon, **M** ≈ a few days, **L** ≈ a week
or more.

---

## What is possible today vs. what needs engine work

The `rl` surface currently exposes window/frame control, 2D text and shapes
(`drawRectangle`, `drawCircle`, `drawLine`, `drawPixel`), 3D cubes and grid,
models with skins and animations, textures, audio, and input. That already
covers more than it first appears:

| Capability | Today? | How / why not |
| --- | --- | --- |
| Recolor the sky, dim the scene | ✅ | lerp `clearBackground`; `drawModelEx` `tint` multiplies albedo |
| Soft blob shadow under the goat | ✅ approx | flattened dark `drawCube`, no shadow map needed |
| Stars | ✅ approx | a few hundred tiny `drawCube`s on a celestial sphere |
| Sun / moon | ✅ approx | a small sphere model drawn with `drawModelEx` |
| Rain streaks | ✅ (2D) | `drawLine` overlay angled to match the wind |
| Grass sway / wind | ✅ | offset the existing tuft cubes with a wind field |
| HUD bars, clock, icons | ✅ | `drawRectangle` + `drawText` |
| New states + clips (sleep, dead) | ✅ | same Blender → GLB → `updateModelAnimation` pipeline |
| X-eyes / closed eyes | ✅ | real eyelids (`LidL`/`LidR`) for sleep; X-eye sprite for death |
| Weather and night ambience audio | ✅ | `loadSound` / `playSound` / `setSoundVolume` |
| Real directional lighting | ✅ | custom lit shader (M4) |
| Cast shadows (shadow map) | ✅ approx | planar projection (M4); a depth map is M4b |
| Camera-facing billboards | ✅ | `drawBillboard` / `drawBillboardRec` (M0) |
| 3D rain drops / splashes | ✅ | `drawLine3D` / `drawPoint3D` (M0) |
| Read a bone's world transform | ✅ | `modelBonePosition` / `modelBoneTransform` (M0) |
| Photoreal / volumetric clouds | ✅ approx | raymarched slab, self-shadowed, with a phase function (M5b); not full radiative transfer |
| Text input (character entry) | ❌ | the surface has `isKeyPressed` but no `getCharPressed` (M9) |
| Voice playback | ✅ Rust-side | the `rl` surface has no audio streams, but `raylib_sys` exposes them and the client already links raylib, so Rust plays into a stream directly (M13a) |
| Networking | Host only | the JS engine has no sockets; `iroh` lives in the Rust host and reaches the scene over the command bridge (M10) |
| Mod support | ✅ | `crates/mods/` loads a `mods/` directory into a versioned `goats` hook API; world mods are hashed into the join handshake (M14, see `APIv1.md`) |

The practical consequence: **stats, sleep and death needed no engine work at all**,
and day/night plus a first pass of weather needed only the M0 primitives. With M0
and the M4 shader bindings landed upstream, even the volumetric cloud shader
(M5b) needed no new bindings -- the M4 surface already carried everything it
uses.

---

## Milestones

| # | Milestone | Depends on | Size | Why this order |
| --- | --- | --- | --- | --- |
| **M0** | Engine primitives: 3D shapes, billboards | — | S–M | ✅ **Done** — landed upstream |
| **M1** | Stats, `sleeping`, `dead` states | — | M | ✅ **Done** |
| **M2** | Day/night cycle (approximate lighting) | M0 (sun/moon) | M | ✅ **Done** |
| **M3** | Weather phase 1: clouds, 2D rain, wind, audio | M0 | M | ✅ **Done** (audio in M3b) |
| **M3b** | Weather and goat audio | M3 | S | ✅ **Done** |
| **M4** | Shaders: real lighting + cast shadows | M0 | L | ✅ **Done** (incl. M4b shadow map) |
| **M5** | Weather phase 2: sky shader clouds | M4 | L | ✅ **Done** (2.5D shader) |
| **M5b** | Volumetric clouds: raymarched slab | M5 | M | ✅ **Done** (self-shadowed, phase function, cirrus) |
| **M6** | Weather affects gameplay | M3 | S | ✅ **Done** (rain slows, wet drains energy) |
| **M7** | Bot herd | M1, M4 | M | ✅ **Done** (collides, grazes, zoomies) |
| **M8** | Heightfield terrain + materials | M4 (lighting) | M | ✅ **Done** (engine `makeModel`) |
| **M9** | In-game console + character input | `getCharPressed` (upstream) | S–M | ✅ **Done** (engine binding + console; live keystroke check pending) |
| **M9b** | Console clipboard: paste a ticket | M9 | S | ✅ **Done** |
| **M10** | Networking foundation: workspace, proto/session/server, join by ticket | M9 | L | ✅ **Done** (the two-window session check still needs a display) |
| **M11** | Chat: global, DMs, system lines | M10 | S–M | ✅ **Done** |
| **M12** | World sync: seed handshake + goat snapshots | M10 | M–L | ✅ **Done** (players sync; server-owned bots/weather are M12b) |
| **M12b** | Server-owned world: headless `goatsd` scene, bots/weather/meadow authority | M12 | L | ✅ **Done** (the world is the server's; the players are the open axis) |
| **M13a** | Voice playback sink: a per-peer raylib stream from Rust | M12b | S | ✅ Available through `raylib_sys`; no engine binding needed |
| **M13b** | Voice: capture, VAD, Opus, media channel, playback | M13a | L | ✅ **Done** |
| **M13c** | Voice polish: jitter buffer, PLC, mute/volume, attenuation | M13b | M | Per-peer controls and the talking indicator |
| **M14a** | Tuning registry: lift the gameplay `const`s into `goats.tuning` | — | M | ✅ **Done** — the tree + `tuningGet/Set/Merge/Watch` live in `core.js`; herd size is now `TUNING.herd.count` |
| **M14b** | Mod loader: `mods/` discovery, manifest, host asset registry, console verbs | M9 | M | ✅ **Done** — the pure loader is `crates/mods/`; the host wiring and the scene part are in place |
| **M14c** | `goats` API v1: events, commands, accessors | M14a, M14b | L | ✅ **Done** — the hook surface; registries and asset slots split into M14c2 |
| **M14c2** | Content registries + mutable asset slots: `bots.register`, `clips.register`, `assets.override` | M14c | M | ✅ **Done** — declared assets apply automatically; clips are gait-only |
| **M14d** | World mods + net compatibility: seed streams, world extension, join handshake | M14c, M12b | M–L | ✅ **Done (handshake)** — the digest and refusal; the snapshot extension is M14d2 |
| **M14d2** | World-mod simulation: `goats.rng`, `world.extend`, snapshot merging, `goatsd` evaluates mods | M14d | M | ✅ **Done** — streams + extension state travel in the snapshot's `mods` field |
| **M14e** | Mods menu, sample mod, smoke test, CI | M14c | S–M | ✅ **Done** — session-only Mods screen, `mods/example/` fixture, the mod smoke test, CI syntax-check, a world-mod determinism test |
| **M14f** | Example: a full world mod, `birds` (own model, animations, flocking) | M14d2 | M | ✅ **Done** — procedural meshes + generated texture, five animation states, boids, synced through `world.extend`; the birds fixture test |
| **M14g** | Mod developer workflow: `--watch`, reload from disk, `.zip` mods | M14f | S–M | ✅ **Done** — a `notify` watcher, `Loader::reload`, and directory-or-zip mod sources |
| **M15** | Rust harness: run the scene tests on Slag, drop Node | M12b, M14 | M–L | ✅ **Done** — 205 cases on the engine, and Node is gone from CI, `tools/` and the docs |
| **M16** | The world datagram: binary, quantized, bounded; world mods on their own | M12b, M15 | M–L | ✅ **Done** — binary and quantized, shed in a defined order, the mods on their own datagram, and a guard so the budget cannot erode again (M16c deferred on the numbers) |
| **M17** | Compiled mods: WebAssembly plugins, any language, capabilities by construction | M14g, M15 | M–L | **Planned** — the engine already has the wasm core and the JS API; the work is the ABI, the host and the policy (M17a–d), plus one upstream re-export |

---

## M0 — Engine prerequisites ✅ Done (landed upstream)

Small, generic additions to `crates/runtime/src/raylib.rs`, following the same
window-thread-guarded, arity-checked pattern as the existing bindings, each with
a case in the `rl` surface test. All of the following shipped:

**3D primitives** — for the sun, moon, stars, rain and the X-eyes:

| Binding | Arity | Use |
| --- | --- | --- |
| `drawSphere` | 5 | sun / moon |
| `drawSphereEx` | 7 | moons with rings, planets |
| `drawLine3D` | 7 | 3D rain streaks, X-eyes |
| `drawPoint3D` | 4 | stars, spray, dust motes |
| `drawTriangle3D` | 10 | lightning bolts, splash fans |

**Billboards** — for clouds and sprites that always face the camera:

| Binding | Arity | Use |
| --- | --- | --- |
| `drawBillboard` | 6 | cloud puffs, sun/moon glow |
| `drawBillboardRec` | 11 | sub-rect of a cloud atlas |

**Bone queries** — for effects that ride the skeleton:

| Binding | Arity | Use |
| --- | --- | --- |
| `modelBonePosition` | 2 | attach X-eyes / a "Zzz" sprite to the head bone |
| `modelBoneTransform` | 2 | position + orientation for the same |

**HUD polish**: `drawTextEx`, `drawRectangleLines`, `drawRectangleGradientV`,
`measureTextEx`.

Implementation notes:

- Billboards need a whole `Camera3D` while the surface only exposes the
  individual `beginMode3D` fields, so the binding caches the camera on
  `beginMode3D` and replays it.
- The bone queries read `currentPose` in **model space**. raylib zero-fills the
  runtime pose at load, so before the first `updateModelAnimation` they fall
  back to the bind pose.
- `measureTextEx` returns `{ x, y }`; the bone queries return objects too.

Verified: the surface test covers every new name, and throwaway probes rendered
each draw binding in a live window and dumped the goat's 13-bone skeleton
(rest head y = 1.160, posed head y = 1.080).

---

## M1 — Stats, sleeping, dead ✅ Done

The whole feature set here is JavaScript plus two Blender clips, so it shipped
before any engine work.

What landed: health/energy with the drain/recover table below, an explicit sleep
toggle (`Z`) plus auto-sleep when exhausted and idle, a recumbent `GoatSleep`
clip, a `GoatDeath` collapse that holds its final pose, and the eyes — the X-eye
billboards placed at eye points baked from the rig, plus (later, replacing the
closed-eye sprite) a real `LidL`/`LidR` eyelid pair that `GoatSleep` closes. The
dead state offers `R` to restart.

### Goat stats

```js
const stats = { health: 100, energy: 100 };   // both 0..100
```

Proposed starting numbers (tunable):

| Situation | Energy | Health |
| --- | --- | --- |
| Idle | −0.4 / s | +0.1 / s (only while energy > 20) |
| Walking | −1.0 / s | — |
| Trotting | −2.0 / s | — |
| Running | −4.0 / s | — |
| Jump (flat cost) | −2.0 | — |
| Sleeping | **+12 / s** | **+2 / s** |
| Exhausted (energy 0) | — | **−3 / s** |
| Night, below 0 °C (M2) | −1.0 / s faster | −0.5 / s |

Rules:

- Energy drains faster with speed, so running everywhere is unsustainable.
- At **energy 0** the goat is *exhausted*: capped at a walk and slowly losing
  health, which is the pressure that makes sleeping matter.
- **Sleeping** is the only fast recovery, and the only way to recover health
  meaningfully.
- At **health 0** the goat dies (see below).
- HUD: two bars plus a small clock (M2), built from `drawRectangle`/`drawText`.

### `sleeping` state + clip

Blender: a new `GoatSleep` clip — the goat lies down (root lowered, legs folded
under the body), the neck curls and the head tucks, with slow deep breathing and
the occasional ear or tail twitch. Author with the same 2-link leg IK used for
the gaits so the folded legs sit on the ground believably.

Eyes closed: **done with real eyelids.** A `LidL`/`LidR` bone pair, each with a
spherical-cap shell over its eye, was added by `tools/goat_eyelids.py`; closing
is −90°/+90° about the bone's hinge and `GoatSleep` keys them shut. The cheap
alternative (a second `goat_eyes_closed.glb` skinned to the head) was not needed.
Every clip keys the pair, open except `GoatSleep`, because raylib only resets a
bone that a clip animates.

JS:

- Enter sleep on a player key (only when grounded and not already dead), or
  automatically when energy hits 0.
- While sleeping the goat ignores movement input; the camera eases in a little.
- Wake on any movement key or when energy is full.
- HUD shows `Zzz` and the recovery rate.

Acceptance: energy visibly drains while running; auto-sleep triggers at 0;
sleeping restores energy and health; waking returns to idle.

### `dead` state + pose

Blender: a `GoatDeath` clip that collapses (the goat rolls onto its side, legs
splay, head goes back) and holds the final pose. A 1–1.5 s collapse followed by
a long hold is enough.

"X eyes": the goofy crossed-out eyes. Shipped as a **billboard sprite** at eye
points baked from the death pose — no new bindings, and it rides the head via
those baked positions. (The closed-eye sprite that used to sit alongside it is
gone now that the goats have real eyelids.) Alternatives if it ever needs to be
real geometry instead:

1. Bake the X into the main mesh on a separate material and hide/show it — needs
   material visibility, i.e. shaders. Defer.
2. Draw two `drawLine3D` Xs per eye from `modelBonePosition(head)` — tiny code,
   but needs the M0 bone query.

JS: health ≤ 0 → `dead`; controls disabled; HUD shows the cause; offer a
restart / respawn key. Decide whether death is permanent for the session.

Acceptance: draining health to 0 plays the collapse, holds the dead pose with X
eyes, ignores input, and can be restarted.

---

## M2 — Day/night cycle ✅ Done

Goal: a clock drives the sky, the light and the celestial bodies, and the world
looks meaningfully different at night.

What landed: an interpolated sky curve (colour + light factor by the hour)
drawn as a full-screen vertical gradient; a scene-wide ambient tint multiplied
into the model, terrain and fallback goat; a sun and moon arcing east to west on
a celestial sphere; a fixed star field that fades in at dusk; a cheap blob
shadow; and a night-drain hook (energy costs 1.6x in the cold). Hold `T` to
fast-forward the clock. The HUD shows the time of day.

- **Clock**: `world.time` in hours `[0, 24)`, advancing at a configurable rate
  (e.g. 1 game day = 6 real minutes). `rl.getTime()` already exists for the
  elapsed-time base.
- **Sky**: keyframe `clearBackground` through night → dawn → day → dusk,
  interpolating smoothly. A gradient can be faked once
  `drawRectangleGradientV` exists, or by drawing a tall 2D rect before 3D.
- **Approximate lighting**: tint the goat and terrain by the ambient colour
  (`drawModelEx` tint multiplies albedo; recolor the ground and tuft cubes).
  Cheap, and reads as "dimmer and bluer at night" without shaders.
- **Sun and moon**: two bodies on opposite sides of a celestial sphere, arcing
  across the sky as the clock turns, drawn with `drawSphere`.
- **Stars**: a fixed field on the celestial sphere, faded in after dusk and out
  before dawn, drawn with `drawPoint3D`.
- **Blob shadow**: a flattened dark cube under the goat that shortens toward
  noon and disappears at night — cheap depth cue until M4.
- **Gameplay hooks** (optional, pairs with M1): colder at night drains energy
  faster; the goat prefers to sleep at night.

Acceptance: over one full cycle the sky colour and scene tint change smoothly,
the sun and moon arc across the sky, stars fade in and out, and the shadow
tracks the time of day.

---

## M3 — Weather phase 1 ✅ Done

Goal: believable clouds, rain and wind, with audio (see M3b).

Shipped in the scene (`crates/goats/src/game/`):

- **Weather state machine**: a seeded xorshift32 walks `clear → cloudy → rain →
  clearing` with per-state hold times, targets for cloudiness and rain, and a
  smooth ease toward the target so transitions cross-fade rather than pop.
  `C` forces the next state (handy for demos and the harness).
- **Clouds**: 46 procedural noise-puff billboards (`drawBillboard`, texture made
  once at startup from value noise) fill a wrapping 100-unit box around the goat,
  drift with the wind, and are tinted by the time of day. Cloud *cover* gates
  which puffs appear, so cover rises before rain. Overcast also lerps the sky
  gradient toward grey. This is lighter than the planned `sky.glb` dome and needed
  no new assets; the shader dome is deferred to M5.
- **Rain**: 160 screen-space streaks (`drawLine`) angled along the wind, count
  scaled by rain intensity. The pool size is the cost knob — 300 drops dropped the
  debug build to ~30 fps, so it sits at 160 (a full storm holds 59–60 fps in
  `--release`). 3D drops with splashes will use the M0 primitives if wanted.
- **Wind**: one global gusty vector (`WIND_BASE` 1.6 m/s plus noise) that drives
  cloud drift, rain angle and **grass sway** — each tuft cube leans on a sine
  scaled by the gust, with a second segment up close.

Acceptance met: weather transitions blend rather than pop; rain falls at the
wind angle; grass sways with gusts; audio tracks the intensity (M3b). Verified
code-side via the scene harness (`crates/harness/tests/scene_logic.rs`; the
clock, weather text and `C` are covered); visual look is **not** machine-verified.

### M3b — Weather and goat audio ✅ Done

Shipped with the `Music` bindings (streaming, native looping) and `Sound`
effects. A background track loops under everything at a low volume; the rain and
wind beds stream at a volume tied to the weather intensity; thunder plays on a
cooldown once the rain is heavy; and the goat bleats on jump, sleep, waking and
death, with a little random pitch so repeats differ. `M` mutes. All of it loads
from `sfx/` on disk and is skipped if a file is missing. MP3/OGG decoding was
enabled on raylib-sys for the compressed effects.

---

## M4 — Real lighting and shadows (shaders)

raylib's core has no light system, so this shipped a small lit shader and the
plumbing to drive it.

Bindings added upstream in `sdgoij/slag`:

| Binding | Purpose |
| --- | --- |
| `loadShaderFromMemory`, `isShaderValid`, `unloadShader` | compile and manage the GLSL |
| `getShaderLocation` | cache uniform locations |
| `beginShaderMode` / `endShaderMode` | bind the lit shader around immediate-mode draws |
| `setShaderValue`, `setShaderValueVector2/3/4`, `setShaderValueMatrix`, `setShaderValueTexture` | per-frame uniforms |
| `setModelShader` | point a model's materials at a shader (`DrawMesh` ignores `beginShaderMode`) |
| `setModelTexture` | point a material map at a texture (how the shadow map reaches a model draw) |
| `loadRenderTexture`, `isRenderTextureValid`, `unloadRenderTexture`, `beginTextureMode`, `endTextureMode`, `renderTextureSize`, `renderTextureColor`, `renderTextureDepth` | offscreen passes and shadow maps |

Shipped in the scene (`crates/goats/src/game/`):

- **Directional lighting.** A custom program lights the scene per fragment from a
  sun (or the moon after dusk) driven by the M2 clock, with a hemispheric ambient
  term so night is dim blue rather than black. The goat is routed through it with
  `setModelShader`; the terrain (immediate-mode cubes) goes through
  `beginShaderMode`. `L` toggles the whole thing; a missing-binding check falls
  back to the M2/M3 ambient-tint look.
- **CPU skinning needed no bone matrices.** raylib deforms positions *and*
  normals on the CPU in this build and uploads them, so the lit shader works on
  the animated goat with plain `vertexPosition`/`vertexNormal` — the roadmap's
  bone-matrix risk did not materialise.
- **Cast shadows.** A depth pass renders the goat from the light's point of view
  into a render texture, and the lit shader compares depths with a 3x3 PCF
  kernel, so the goat self-shadows and the terrain takes a perspective-correct
  shadow. Depth is packed across RGB and stored as `1 - depth`. `K` cycles the
  shadow map, a planar fallback and off.

Acceptance: the goat and terrain are lit by the sun/moon and the goat casts a
shadow that tracks the day/night cycle. Code-side this is verified (three
shaders compile, no GL/JS errors, 59–60 fps in release by day and night); the
*look* and shadow correctness are not machine-verified.

### M4b — Shadow map ✅ Done

A depth-only pass with `lightVP` (a JS-built orthographic light matrix passed
via `setShaderValueMatrix`), sampled in the lit program with a 3x3 PCF blur.
Two raylib details shaped it: a render texture's depth attachment is a
renderbuffer (not samplable), so depth is packed into the colour attachment's
RGB; and `DrawMesh` binds a model's material maps over any unit
`setShaderValueTexture` picks, so the shadow map rides in material map 1 via
`setModelTexture` for the model, while the terrain (batch path) uses
`setShaderValueTexture`.

What it adds over the planar fallback: self-shadowing (the goat's legs and head
on its body) and a correct shadow on any non-flat receiver. The grass inside the
light's box casts into the same pass (the batch path, like the terrain, drawn
before the goat), so nearby tufts ground the goat in the field; tufts outside the
box are culled because they cannot project into the map. The field is generated
per 2-unit cell from a hash of the cell around the goat, so it is effectively
infinite and never leaves bare ground behind. Limits: a single 1024² map
covering a 14-unit box, so the shadow softens at distance and clips when the
goat leaves the box.

---

## M5 — Weather phase 2: procedural sky ✅ Done (2.5D)

The cloud layer is now a full-screen sky shader rather than billboards.
Per pixel it rebuilds the camera ray from the camera basis, draws the
hour-of-day gradient, and samples animated value-noise fBm on a flat cloud layer
at `CLOUD_HEIGHT`; the ray-to-plane projection is what compresses the clouds
toward the horizon (the parallax). Clouds are shaded by comparing the density
against a sample taken toward the sun, so they brighten on the sun's side and
pick up its dawn/dusk colour, and they dim and grey with night and overcast.
`B` falls back to the M2 gradient and the noise-puff billboards.

Cost is a 4-octave fBm, twice per sky pixel (the second sample is the sun-side
lighting term). Release holds 60 fps in daylight and 56–58 in the worst case
(night, stars, heavy rain); the earlier billboards were a little cheaper but much
less convincing.

**Deferred:** true volumetrics (raymarching a participating medium). The roadmap
flagged this as a research stretch; the 2.5D shader is the realistic target and
is what shipped. (Overtaken by M5b, below.)

---

## M5b — Volumetric clouds ✅ Done

The flat layer was replaced by a marched slab, which is what turns the clouds
from a moving texture into a volume:

- **Shape.** `cloudDensity` fBm-domain-warps the 2D field (`fbm2(q + warp*0.75)`)
  and shears it with height, so the billows are billows rather than an extrusion,
  and the layer parallaxes correctly. A soft base and a rounded top come from an
  analytic height profile; the coverage threshold falls as `cloudiness` rises, so
  the sky goes from a few puffs to solid overcast; high-frequency erosion (only
  evaluated near a surface, where it reads) frays the edges.
- **Light.** Each sample marches three steps toward the sun with a cheaper
  two-octave density, giving real self-shadowing -- dark bases, lit tops. A
  Henyey-Greenstein phase function adds the forward-scattering rim on the sun's
  side, and a Beer-Powder term keeps dense interiors from glowing. Transmittance
  is Beer-Lambert, composited front to back.
- **Depth.** A thin, wind-sheared cirrus layer sits above the cumulus, and
  distance haze blends far cloud into the horizon colour instead of aliasing.
- **Anti-aliasing.** The steps grow exponentially with distance (`growth` up to
  1.4), so samples stay dense near the camera and stretch where a cloud covers
  fewer pixels, and the high-frequency erosion fades out with distance. There is
  deliberately *no* per-pixel jitter on the march start: randomising the offset
  per pixel is itself what reads as pixelated noise.
- **Bodies.** The sun and moon discs are *not* drawn here. `drawCelestial`
  (world.js) already puts textured sprites over this pass, so a disc in the
  shader doubles it; the shader adds only the wide atmospheric glow.
- **Atmosphere.** The gradient gained a forward-scattered glow that widens as the
  sun approaches the horizon, the sun/moon disc, and a horizon haze band.

Cost is step-count bound, so it is a setting: **Clouds — Low / Medium / High**
(6 / 12 / 22 march steps). At 2560x1440 release sits at the 60 fps cap on Low
and Medium; High read ~55, which is inside run-to-run noise (the billboard
fallback read 55 in the same run), so the knob is there for weaker GPUs rather
than for the default.

Verified numerically rather than by eye: the shader compiles, the harness asserts
the march is what gets installed (and that no disc has crept back in), and frame
statistics behave -- overcast is flatter than broken cloud (luma sd 0.090 vs
0.121), dusk dim with a still-lit sky band, and night dark with no glow. The
aliasing fix was measured the same way: mean high-frequency energy in the sky
band fell 74-97% horizontally across the three quality levels, which pins the
speckle on the march rather than on the noise field. Whether it *looks* right is
still an eyeball call.

**Still a stretch:** true radiative transfer (raymarching the atmosphere proper,
multiple scattering).

### Investigated: temporal reprojection (not shipped)

Temporal accumulation is the textbook way to trade march quality for frame
history: render the sky into one of two ping-pong targets, reproject the previous
frame through the previous camera basis, blend, and let a *per-frame* jitter
(rather than a per-pixel one) resolve the stepping.

It was implemented, measured, and **deliberately reverted**. Two findings:

- **It no longer solves the problem it exists for.** With the deterministic march
  (exponential stepping, no per-pixel jitter) the static image already measures
  0.00032 mean high-frequency energy in the sky band at Medium -- lower than the
  pre-alias-fix High (0.00321). An accumulator needs a per-frame jitter to have
  anything to average, and reintroducing it *raises* static noise to 0.00082
  while costing ~10% of the frame (60 -> 54 fps at 2560x1440): nothing to gain,
  measurable loss.
- **It cannot be done correctly on the current engine surface.** The history
  sampler costs a texture unit, and raylib's batch system has only
  `RL_DEFAULT_BATCH_MAX_TEXTURE_UNITS = 4`. `rlSetUniformSampler` *silently does
  nothing* once they are full, so the sky's two samplers (history + present)
  starve the lit shader's bindings: the terrain's albedo sampler ends up reading
  the sky target, darkening the whole ground by a uniform ~9% (ground luma 0.611
  -> 0.554 with the camera frozen, and unchanged by turning shadows off, which
  is what fingered the albedo sampler rather than the shadow one).

What would unblock it:

1. **Do not sample through `setShaderValueTexture`.** The engine's `drawTexture`
   blits a render texture through raylib's normal batch path, so drawing the
   history as the quad and sampling `texture0` should cost no registry slot.
   That is the route to try first, and needs no engine change.
2. **A per-pixel reprojection depth.** Carrying it in the target's alpha does not
   survive raylib's alpha-blended 2D drawing; it needs `BLEND_ALPHA_PREMULTIPLY`
   (or no blending) exposed, or a second target. Failing that, the slab geometry
   (`(cloudBase - camY) / dir.y`) is a serviceable depth proxy.

---

## M6 — Weather affects gameplay ✅ Done

Being wet and cold is now a resource cost, which ties the weather to the M1
stats:

- **Rain and wind slow the goat**: up to `RAIN_SLOW` (28%) plus `WIND_SLOW` (7%)
at full rain, applied to every gait and to the jump take-off speed.
- **Being soaked drains energy faster**: up to +65% (`WET_DRAIN`) plus wind, on
top of the existing night penalty.
- Both are gated on `rainAmount`, so `clear` stays exactly neutral — which also
  keeps the gait-speed assertions in the harness exact.

The HUD weather line reports the current slowdown, and the harness checks that a
deterministically-rainy frame walks slower than a dry one.

---

## M7 — Bot herd ✅ Done

Six autonomous goats wander the world around the player. Each has its own
procedural mottled fleece (a JS-built texture, so no new assets), its own body
scale, and its own temperament (`bold` biases how fast it moves, `lazy` how often
it stops). A small state machine picks between grazing, strolling, trotting, the
occasional sprint and the odd doze, steering to a wander target and turning back
toward the player once it drifts past a comfortable radius. A run is a "zoomies"
burst: the bot hops every second or so, which reads as a young goat tearing
about. Goats also collide — every pair is pushed apart (bots yield fully to the
player, and split the push with each other), so nothing can walk through
anything else.

Each bot owns a model handle rather than sharing one. That is forced by this
CPU-skinning build: `updateModelAnimation` writes the deformed vertices into the
model's own meshes, so two goats can only hold different poses if they have
different models. Bots inside the shadow map's box are drawn into the depth pass
and cast real shadows; the rest get a small contact blob so distant goats stay
grounded. The bots use a private PRNG, so they cannot shift the seeded weather
stream the harness asserts on.

Cost: seven models loaded and skinned twice per frame in the worst case. Release
holds 59–60 fps; debug drops to ~38-43 (the flattened bot AI also keeps the debug
stack guard happy). The harness asserts the herd loads, animates, never
overlaps, and jumps.

---

## Animation variants & the side-fall death ✅ Done

To give the herd some individuality:

- **Idle variants.** `GoatIdle2` is a grazing idle (head down, weight shifting),
  `GoatIdle3` an alert one (head up, big held looks left and right). The player
  advances its idle variant each time it settles back into idle; every bot
  cycles its own variant on each new action, so the herd shows all of them.
- **Sleep / jump variants.** `GoatSleep2` curls the head the other way with
  slower breathing; `GoatJump2` is a bigger bound -- deeper crouch, higher arc
  and a proper leg tuck at the apex.
- **Death falls onto its side.** `GoatDeath` now rolls about the forward axis
  until the goat is genuinely on its side (the old clip only slumped ~10°).
  Because the roll pivots on the goat's edge rather than its centreline, the clip
  emulates a ground-level pivot and then applies a per-frame ground correction
  (the leg IK depends on the root height, so one pass does not settle).

All authored in Blender by `tools/goat_states.py` (sleep/death) and
`tools/goat_variants.py` (idle/sleep/jump variants); the model now carries 11
clips, and a mismatch between the two scripts' grounding passes is why the death
clip needed a small residual (max ~0.18) to keep the lowest vertex on the ground.

---

## M8 — Heightfield terrain + materials ✅ Done

The ground is no longer a flat plane. It is a 3-octave value-noise field
(`terrainShape`) scaled by a ramp that keeps a bowl around the spawn level, so
the goat starts on flat grass and the relief eases in over `TERRAIN_RAMP` units.
`terrainHeight(x, z)` is the single source of truth for the ground: the goat, the
herd, the grass, the eyes and both shadows all read it.

**One mesh, not cubes.** A cube per cell was built first and reverted. On the
same probe at 2560x1440 it cost ~14 us per cube, so ~450 cells ran 41 fps
against 56 for the flat plane — a practical ceiling of ~100 cells, roughly a
tenth of what a good-looking heightfield needs. Immediate-mode triangles are no
better: `drawCube`/`drawTriangle3D` leave raylib's default normal `(0, 0, 1)` and
texcoord `(0, 0)`, so a triangle heightfield is lit as if every face pointed +Z
and cannot carry a world-mapped texture at all.

So the terrain is a 48x48-quad grid built through a new engine binding,
`rl.makeModel(vertices, indices, normals, colors, texcoords)`, which returns a
handle in the same registry as `loadModel` — so `drawModelEx`, `setModelShader`,
`setModelTexture` and `unloadModel` all apply unchanged, and the shadow map binds
through material map 1 exactly as the goat's does. The grid spans +/-48 units and
is rebuilt once the goat has moved `TERRAIN_SNAP` (24) units; between rebuilds
the whole terrain is a single `drawModelEx`.

**Materials without a splat map.** Per-vertex colours carry the material —
grass / dark grass / sand / mud / rock, picked from height, slope and a
patchiness noise — and a tiling procedural detail texture supplies the grain. The
lit shader already computes `texture0 * colDiffuse * fragColor`, so this needed no
shader change and no extra texture units, which matters here: the batch has a
4-unit budget and `rlSetUniformSampler` silently no-ops once it is full (see
M5b). Adjacent cells interpolate, so material boundaries come out as gradients.

**Cost.** The mesh is free — one draw, 4608 triangles, 55-58 fps at 1440p
against 56-59 for the flat plane, i.e. within noise. The cost was the per-cell
noise: `drawTufts` samples the field ~500 times a frame, measured at ~2 ms/frame.
A per-cell height cache (`TERRAIN_CELL_H`, keyed like the grass's eaten-cell map
and cleared past 32k entries) removes it. The rebuild resamples the whole
2401-vertex grid — at the ~4 us per field sample that 2 ms implies, roughly
13 ms, so it drops one frame every `TERRAIN_SNAP` units of travel, felt only at a
run.

**Verified numerically, not by eye.** The harness gained seven checks: the field
is not flat, the spawn bowl is level, the mesh is one grid with per-vertex normals
/ colours / UVs and a varying height, it carries at least four distinct materials,
and both the goat and every bot are drawn exactly at `terrainHeight` under them.
Two rendered frames
were decoded to confirm the ground region is green-dominant with 0% sky pixels
(so it is neither culled nor missing), and that the detail texture is sampled at
all: replacing it with white raised the ground's mean luma 104.6 -> 119.5 at the
same time of day, which is the texture's own mean. (Comparing frames from
different times of day instead showed a similar shift from the rising sun alone,
which is a reminder to A/B within one scripted run.)

**Deferred.** Water (the field has hollows but no lakes or streams); per-material
textures (needs a splat map and a careful look at the texture-unit budget); and
drawing the terrain into the depth pass so hills cast onto each other — the
normals already shade slopes, and terrain self-shadowing brings acne that only a
screenshot review could judge.

---

## M9 — In-game console + character input

✅ **Done.** The console is the input substrate for chat and a dev tool in its
own right, so it landed before any networking. It was one new JS part plus two
small engine bindings; no workspace change was needed — the repository only
splits into `crates/` when M10 starts.

### Engine prerequisite (upstream Slag)

One addition to `crates/runtime/src/raylib.rs`, arity-checked like the rest, with
a case in the `rl` surface test:

| Binding | Arity | Use |
| --- | --- | --- |
| `getCharPressed` | 0 | one UTF-32 codepoint per queued key press, `0` when drained — read in a loop until it returns 0 |
| `guiTextBox` (optional) | 6 | raygui-owned single-line fields; not needed for the console, only if the username/ticket dialogs (M10) want one |

### JS plumbing

A new part, `crates/goats/src/game/console.js`, appended after `menu.js` (part
13/13), plus one line in the crate host's `concat!` — which also updates the
part list in `core.js`'s header comment and the README Layout row (`12 parts`
→ `13`).

- **`consoleOpen` is an overlay flag, not a `uiScreen` value.** Menus freeze the
  world (`dt` is forced to 0 while one is open); the console must *not* pause,
  especially once multiplayer lands. It draws over the HUD and the game keeps
  running behind it.
- **Suppress gameplay input while open.** Both existing gates — `ctlKeyDown`
  (ctl.js: movement, the arrow-orbit keys, `T`) and `press` (menu.js: `P`, `C`,
  `L`, `K`, `M`, `F11`, `B`, `R`, `Z`, `E`, `Space`) — become
  `uiScreen === "hud" && !consoleOpen && ...`. The inline mouse-wheel zoom check
  in `goat.js` needs the same guard, and the `Escape` menu toggle must defer to
  the console while it is open (close the console, not open the menu).
- **Keys.** Backquote (`` ` ``, `KEY_GRAVE` = 96) toggles; `Enter` submits;
  `Backspace` edits the line; `Up`/`Down` walk the history.
- **Submit routes through the existing `sceneCommand` dispatcher**, so every verb
  that already exists (`settings`, `time`, `bots`, `weather`, `spawn` …) works in
  the console for free, and its `ok`/`error` reply is echoed into the scrollback.
- **Two output streams.** A scrollback ring buffer (~200 lines) that keeps local
  command replies visually distinct from network/system lines (`<name> text`), so
  M10/M11 can push the latter without a second buffer.
- **A host→scene entry point** — `sceneNetEvent(line)`, resolved by the host
  exactly like the other `scene*` functions — so Rust can print into the console
  without evaluating a fresh script. If an older engine build lacks the hook the
  scene degrades to no console output rather than throwing (the same pattern as
  the shader fallbacks).
- `drawConsole` is an overlay built from existing bindings
  (`drawRectangle`/`drawText`), independent of `uiScreen`.

### Harness

The driver already scripts input by filling the `keys`/`pressed` maps per frame,
so the console slots straight in:

- add `KEY_GRAVE: 96`, `KEY_BACKSPACE: 259`, `KEY_ENTER: 257` to the constants
  and a scriptable `rl.getCharPressed` queue;
- cases: open, type `ping`, submit (assert `ok pong` reaches the scrollback); a
  held `W` must not move the goat while the console is open; `Up` recalls the
  last command; `Escape` closes the console instead of opening the menu.

Acceptance: backquote opens and closes; every printable key lands in the line;
`Enter` runs the command and echoes `ok`/`error`; no gameplay binding fires
while it is open; the harness covers open, type, submit, history and
suppression.

**What landed.** `getCharPressed` and `KEY_GRAVE` (96) added to the engine's
raylib surface (upstream Slag; exercised locally through the `./slag` path
dependency, which must not be committed). `crates/goats/src/game/console.js` as
part 13/13, which renumbered the other twelve headers. The console gate in
`ctlKeyDown` and
`press`; Escape precedence and the mouse-wheel guard in the frame loop; a
`console` verb on the dispatcher (`open` / `close` / `toggle` / `say`, plus a
query returning the input, caret, history and scrollback); and the README and
keymap rows. One detail worth keeping: raylib queues a character for every
printable key whether or not it is read, so the toggle drains that backlog —
otherwise the console would open full of the `wasd` typed while playing.

**Verified.** The engine surface test passes
(`cargo test -p runtime --features raylib,raygui installs_the_rl_surface`), the
game builds against the local checkout, and the harness gained eleven checks —
open, type `ping`, submit, `ok pong` in the scrollback, history recall, Escape
closing the console without opening the menu, reopen, and the goat moving while
closed but frozen while open — taking it to 88 passing checks.
**Not verified here:** an actual keystroke in a live window (this environment has
no display), which is the one check left for a machine with a GPU.

---

## M9b — Console clipboard (paste a ticket)

A ticket is forty-odd characters of base32, and asking a person to type one is
asking for a typo. So the console reads the clipboard on Ctrl+V; `copy` with no
argument puts the ticket you were given back onto it; Ctrl+C copies the current
line.

Two more engine bindings carry it: `getClipboardText` and `setClipboardText`,
which are raylib's own clipboard. Without them the console says the binding is
missing rather than silently doing nothing. The paste path drops control
characters -- a ticket copied out of a terminal arrives with a newline -- and
respects the input's length limit, so a stray paste cannot overflow the field.

Verified: the harness sets a stub clipboard, presses Ctrl+V and Ctrl+C on
scripted frames, and checks the pasted line plus both writes back (five checks),
taking it to 105. The rl surface test covers the two new bindings.

**Pending:** nothing. The bindings landed upstream (Slag `d8dd8c4`), so the
clipboard works in a normal build; `Cargo.lock` pins that rev.

---

## M10 — Networking foundation: workspace, iroh, join by ticket

All of it moves to Rust, because the JS engine has no sockets: the scene never
touches the network, it only emits intents and consumes events.

**Landed.** The workspace (`crates/goats`, `proto`, `session`, `server`), the
`proto` wire types and framing, the iroh transport carrying the join handshake
and the roster, the host bridge, the `goatsd` binary and the username prompt. A
tokio thread owns the session; the frame loop feeds the scene its events with
`sceneNetEvent` and takes the scene's queued intents back with `sceneNetDrain`,
never awaiting. The host assigns and de-dupes the name, answers `Welcome` with
the canonical name and the current roster, and broadcasts `Roster` on every join
and leave. Headless tests drive real loopback endpoints for the session and the
scene end of the bridge, so none of it needs a network or a display.

The one check left is a real two-window session on a machine with a display: run
the client twice, `host` in one and `connect <ticket>` in the other.

**Repository.** Convert to a Cargo workspace, mirroring Slag's layout:

```
crates/goats     client + the JS scene (moved from src/)
crates/proto     serde message types; no iroh/tokio; testable in isolation
crates/session   session/server logic on tokio + iroh; no window
crates/server    bin `goatsd`: session + a headless frame loop
```

**Transport.** `iroh`, pinned exactly (1.2.0 at the time of writing). One ALPN
per major protocol version (`goats/1`) so a mismatched build fails cleanly
instead of deserialising garbage. Joining is copy-pasting an `iroh-tickets`
ticket. LAN/direct is the default and contacts no third party;
`GOATS_INTERNET=1` swaps the preset to `presets::N0`, which reaches peers over
n0's public relays with DNS lookup. Self-hosting `iroh-relay` remains a later
option (see the open questions). `bevy_iroh` is worth **trialling** and pinning — it
advertises replication, rooms, presence and voice, which is exactly the shape we
want — but it is Bevy-shaped and days old, so plain `iroh` plus our own
`session` layer is the fallback, not a rewrite.

**Host bridge.** A Tokio runtime on its own thread owns the `Endpoint`; the
synchronous frame loop drains an `mpsc` at frame boundaries and **never awaits**,
so the render loop cannot stall. Rust→JS is `sceneNetEvent(line)`; JS→Rust is one
more host callback. Keeping it line/JSON matches the existing command channel and
stays stubbable by the harness.

**Client-as-host.** A client hosting a game is just an endpoint that accepts the
same ALPN and runs `session` in-process, so "Host" and "Join" share one code
path. Host quitting ends the session (no migration).

**The headless server runs the same JS.** `goatsd` will evaluate the identical
scene against a **null `rl` host module** — no window, no GL — the trick
the scene harness (`crates/harness`, `tools/goat_logic_test.js` before M15)
already proves works: terrain, weather, bots and food
simulate with every draw/audio call no-op'd, while `rl.color` and the
model/texture builders return usable handles. That keeps one world model instead
of a Rust re-implementation, and means the server needs no GPU. Watch the one
binding the sim genuinely needs: `getFrameTime`, which the server replaces with a
fixed timestep.

**Deferred, deliberately.** `goatsd` is a lobby for now. Relaying presence does
not need the simulation, and there is no consumer for a headless world until
world sync (M12) exists to send it, so the null-`rl` scene is where M12 starts
rather than something to build against nothing.

**Protocol basics.** A version/`hello` handshake, the username prompt (server
owns the canonical name), a roster, and input validation — message-size caps and
finite positions, since a `NaN` leaked into an interpolated transform poisons the
render.

Acceptance: two clients and one `goatsd` can each host or join by ticket; the
roster shows names; the console prints join/leave; `proto` round-trips and the
`session` state machine are covered by headless tests (iroh's `test-utils` /
loopback endpoints need no real network).

---

## M11 — Chat

Cheap once M10's channel exists, and it exercises it in both directions.

**Landed.** `ClientMessage::Chat` and the server's `Chat`/`Joined`/`Left`/
`Notice` replies carry chat over the existing per-message stream, and the server
ows routing: a bare line goes to everyone (the sender included), a leading
`@name` goes only to that player (and the host, when the host is the sender or
the target), and an unknown name comes back as a `Notice`. The sender reaches
the session through `Host::say` / `Client::say`, queued from the scene as a
`Say` intent, so the frame loop still never awaits. The console handles the
typing: bare text is chat in a session, `@name text` / `say` / `msg <name>
<text>` are the DM spellings, a leading `/` is stripped so `/who` is `who`, and
an empty command reply prints nothing so a queued chat line is silent. Names
are canonical on the server, chat is sanitised and capped at 512 bytes, and a
burst of 5 lines per 3s per player is the rate limit.

**Verified.** `cargo test --workspace` (the loopback bridge test now carries a
global line and a whisper end to end), the scene suite (then the Node harness,
113 checks -- the console's chat and command routing among them; now
`crates/harness/tests/scene_logic.rs`) and clippy. The live
two-window check also passed: two clients, one hosting, and global chat and a
whisper both arrived in the other window.

- Global: bare text broadcasts.
- 1:1: a **leading** `@name text` is a DM, with `/msg name text` as the
  unambiguous form. Deliberately not parsing `@` mid-message, so a sentence that
  merely mentions a name does not leak as a DM.
- Commands: `who`, `help`; system lines for join/leave. `/nick` (renaming)
  is not implemented yet — names are fixed for the life of the session.
- Names are not unique, so the server assigns the canonical one: cap the length,
  strip control characters/ANSI, de-duplicate (`Bob`, then `Bob #2`).
- DMs are filtered by the server, not broadcast.
- Rate-limit and cap message length; unbounded chat is a trivial DoS and a
  bandwidth sink.

---

## M12 — World sync

- **The world is shared by seed.** Terrain, grass and the initial layout are pure
  functions of position, and the assets are embedded and identical, so the host
  sends a session seed at join and every client generates the same world — no
  asset transfer and, more importantly, only goats need syncing.
- The current seeds are hardcoded constants (`botRngState`, `audioSeed`, the
  weather `rnd()` stream); they become a session seed. Note this touches the
  harness, which asserts the exact weather a seeded stream produces.
- **Authority.** Player goats are client-authoritative and relayed by the host —
  simple and low-latency, trusting clients, which is the right call for a
  sandbox. Bots and weather are server-owned: bots collide with players, so they
  diverge the moment anyone interacts.
- **Transport.** Unreliable datagrams at ~15–20 Hz carrying
  `(id, x, z, yaw, mode, phase, speed, name)`; remote goats interpolate ~100 ms
  behind. Reliable streams carry join/roster/chat only.
- **Deferred:** client-side prediction/reconciliation, server-authoritative
  movement and lag compensation. Also settle `P` (pauses locally today) and the
  death/restart flow, both of which must become server-owned or be disabled.

**Landed (player sync).** The wire version is 2 (M12b raises it to 3, when the
datagram channel gains a tag). `Welcome` carries the session
seed, which the host mixes from the clock at `host` and both ends hand to the
scene as the first event; `sceneUseSeed` derives the weather, bot, food and
audio xorshift streams from it with one draw each. Offline the streams keep
their old constants, so the harness is untouched. `PeerState`/`PeerFrame` and a
`Gait` enum carry the transforms, and both the host and each client publish
their own goat every third frame (~20 Hz) on QUIC datagrams, which the server
relays tagged with the sender's canonical name — a client sends the state alone,
so it cannot move someone else's goat. Non-finite states are dropped rather than
relayed. The scene keeps one goat model per peer (the same per-goat ownership
the bots use), eases position, yaw and phase toward the newest snapshot on the
short way around, and drops the model when the peer leaves.

**Follow-on.** At this point the bots and the weather were still simulated on
every client, so once two players interacted with a bot the goats drifted. That
is what M12b addresses for the bots.

**Verified.** `cargo test --workspace` (proto 12, session 7 — the new relay test
sends real datagrams through a real host — goats 4), the scene suite (then the
Node harness at ALL PASS, 120 checks -- the seed, pose-cadence and peer checks;
now `crates/harness/tests/scene_logic.rs`), `cargo fmt
--all -- --check` and `cargo clippy --workspace --all-targets -- -D warnings`
clean. The visual check — two windows, each seeing the other's goat move — still
needs a display.

---

## M12b — Server-owned world

**Landed.** The wire version is 3: a `Datagram` enum now tags the transform
channel, because it carries two kinds of traffic. `BotState` and `WorldState`
carry the server's bots, and `Host::publish_world` broadcasts them about 10 times
a second; the client's datagram reader emits `Event::World`. A client mirrors
what it receives and does not run the bot AI at all (`netWorldLocal` gates
`updateBots`), while the host — the game window that ran `host`, or `goatsd` —
simulates the herd and publishes it. The relay accepts only `Datagram::Peer` from
a client, so a client cannot move the bots.

The sky followed the bots, on the same snapshot. `WeatherState` carries the
state the machine is in, the eased cloudiness and rain, the wind and the
day/night clock; the wire version is 4. The host runs `updateWeather`/
`updateWind`; a client takes the scalars (`applyWeatherState`) and still
recomputes its own goat's speed and drain every frame, because those depend on
its own belly. Clouds, rain particles and grass sway stay local and relative to
the viewer, which is why the wind reaches them but their positions do not cross
the wire; the rain keeps its own PRNG stream so a client, which never advances
`rngState`, still gets varied streaks without disturbing the seeded weather. `C`
and `T` are host-only now, since a client forcing either would just be
overwritten.

The headless half is `crates/server/src/headless.rs`: it evaluates the client's
exact scene parts, in the client's order, against a null `rl`
(`crates/server/src/headless_rl.js`) instead of installing raylib, then drives
`sceneFrame` at a fixed 1/60 and reads the world back as JSON. A test asserts the
server's part list matches `crates/goats/src/main.rs`, so the two cannot silently
diverge. `goatsd` seeds the sim from the session seed before `sceneInit`, so the
world is generated from it rather than adopted after the fact — which closes the
"the initial layout does not agree" gap the player-sync note left open. It
behaves like a server in the small ways as well: SIGINT stops it, and SIGTERM on
Unix, so Ctrl-C and `kill` work and the close is bounded so a quiet peer cannot
wedge the shutdown. Confirmed on the VPS.

**Landed (the meadow).** The world snapshot gained the PRNG streams and the
eaten cells, and joining now *replaces* a client's world rather than merging it
with the one it had generated before connecting. The streams the server sends
are its current values, not the seed it started from, so a stream a client still
draws from continues where the server is; the snapshot keeps re-adopting them,
so the two cannot drift. The meadow has to travel as state because the stream
only picks a regrow duration at eat time — which is also why a client *reports*
its bites (`ClientMessage::Consume`, its own rate limit) and the host's scene
records them, instead of the client counting its own meadow down: otherwise the
next snapshot would resurrect the tuft it just ate. Wire version 5.

**Still open.** The world is the server's now; the *players* are not. Player
goats remain client-authoritative, and the stats and the pause/death flow that
were built for single player (`stats.energy`, `satiety`, `P`, restart) are still
local, so they carry across a join and are not part of a session — open questions
9 and 13. That is also where the interaction latency lives: a remote goat eases
toward its newest snapshot and is never extrapolated, so it sits ~100 ms behind
and bumping or racing it feels soft, and the world snapshot's 10 Hz cadence
bounds how fast a bot's reaction or a fresh eaten patch shows. Both are the
accepted price of trusting the client for movement, and both are exactly what
prediction/reconciliation (question 9) would remove — deferred until it matters.
Separately, the scene does the full render-side work every step (all no-ops, but
real JavaScript): a release build keeps up with 60 Hz, a debug one does not, so
`goatsd` wants `--release`.

**Verified.** `cargo test --workspace` — proto 14, session 9, goats 4, server 2
plus 1 `#[ignore]`d (three fresh sims, each re-JITing the scene, is ~35 s) — the
harness at ALL PASS (128, including the host-publishes, client-mirrors, streams,
meadow and bite-report checks), `cargo fmt --all -- --check` and `cargo clippy
--workspace --all-targets -- -D warnings` clean. The live check passed too: a
real session syncs the world — a tuft eaten in one window disappeared in the
other, so the bite was reported, the host's scene recorded it, and the next
snapshot carried it across. Interaction works, with the latency above.

---

## M13 — Voice chat

Split into three: the sink, the feature, and the polish. No upstream engine work
is needed after all.

### M13a — Playback sink: `raylib_sys` from Rust (no engine binding)

The plan assumed `rl` would need new audio-stream bindings, but the client
already links raylib through the `raylib` feature, and `raylib_sys` exposes the
whole AudioStream API through bindgen — `LoadAudioStream`, `IsAudioStreamProcessed`,
`UpdateAudioStream`, `PlayAudioStream`, `IsAudioStreamPlaying`,
`SetAudioStreamVolume`, `UnloadAudioStream`. So the decoded PCM can go straight
into a per-peer raylib stream from Rust: it still passes through raylib's mixer
and the device the scene opens with `rl.initAudioDevice()`, with no new `rl`
surface and no upstream change.

One seam to respect: the scene owns the audio *settings*, so `M` and
`SETTINGS.sfx` have to reach Rust. The scene queues a small intent (`voice`
volume) and the module uses it as the master gain; distance attenuation needs
positions, which also live in the scene, so per-peer gain joins that intent in
M13c. Until then voice plays at the master level.

### M13b — Voice: capture, detection, codec, media channel, playback ✅ Done

- Capture: `cpal` in the client (the headless `goatsd` only relays), downmixed to
  mono and resampled to 48 kHz by a small linear resampler.
- Detection: there is **no push-to-talk key**. An energy gate with an adaptive
  noise floor, a 300 ms hold and a 40 ms pre-roll decides when a frame is speech,
  so idle room noise never leaves the machine and word onsets are not clipped.
  This is the hand-rolled version of what games usually do with WebRTC or Silero
  VAD; the gate is separated from the thread so it is unit-tested.
- Codec: `libopus_sys` with `bundled` (compiles libopus from source, no system
  dependency) behind a thin wrapper in `crates/goats/src/audio.rs`; ~24 kbps,
  20 ms frames (960 samples at 48 kHz mono).
- Transport: a `Voice` datagram beside the peer and world ones, tagged with the
  sender's name by the relay like a pose, with its own burst limit. It is the
  roadmap's generic "media" channel, so the transform channel does not change.
  Wire version 6: a version-5 relay does not know the variant, decodes it as an
  error and drops it, so the bump turns that silence into a failed handshake.
  JSON carries the frame, with the payload base64 (a ~60-byte packet, so the
  overhead is tolerable at ≤4 players); a binary envelope is a later optimisation,
  not a redesign.
- Playback: decoded PCM into one raylib `AudioStream` (M13a) whose callback
  drains a single mix queue, so every speaker shares a stream and raylib asks for
  exactly the frames it needs. raylib's per-stream API is a virtual double buffer
  that is easy to feed wrong -- a short write is zero-filled, and a feed loop can
  leave one half permanently empty -- so the callback, the API meant for
  generated audio, is used instead. The client names `raylib-sys` directly,
  because Slag does not re-export it.
- Mute: the scene's master mute reaches the module as a `voice_gain` intent and
  becomes the stream gain, so `M` silences voice along with everything else.

Verified: unit tests for the gate, the resampler, the mix and the gain intent;
the harness asserts that muting queues the intent; an `#[ignore]`d device test
drives the real mixer headlessly and asserts the callback drains the mix at the
device rate, and a second one checks the microphone itself is not delivering
digital silence (a muted device, the OS privacy switch and another application
holding it all look like that, and all of them read as "voice is broken" on the
far end); `cargo test --workspace`, `cargo fmt --all -- --check` and `cargo
clippy --workspace --all-targets -- -D warnings` clean. `GOATS_VOICE_LOOPBACK=1`
plays the microphone back through the whole chain on one machine, which tells a
one-window problem apart from a session one.

Confirmed live: two clients, one of them hosting, hear each other. Getting there
cost three playback fixes that this section now records -- gating on
`IsAudioStreamProcessed` dropped every packet that arrived while the mixer was
mid-block, writing short into a half-buffer zero-filled the rest of it, and the
double buffer itself resets to half 0 the moment both halves are free -- and the
last stretch of "still nothing" turned out to be the microphone, not the code:
Windows was handing the client digital silence, which the gate correctly refused
to send. That is why the mic check and loopback exist.

### M13c — Voice polish

Jitter buffer and Opus PLC for loss, per-peer mute/volume, distance attenuation
(positions are already exchanged, so it is nearly free), and a talking indicator
on the roster. Uplink is the limit: full mesh is ~24–32 kbps upstream *per peer*,
so it suits ≤4 players; beyond that the host should mix and relay.

---

## M14 — Modding support

Mod support lets players add code, content and tuning without forking the
game. The full contract is `APIv1.md`; this section is the milestone plan, the
decisions behind it and the constraints that shape it.

**Decisions (settled).**

- **Trust model:** mods are trusted code, but **`fs` stays off**. JavaScript
  never touches the filesystem; the Rust host discovers, reads and validates,
  and hands the scene opaque asset names. All I/O goes through Rust.
- **Format:** script mods against a versioned `goats` hook API (the `APIv1.md`
  design), not raw monkey-patching of scene internals. Data-only packs
  (assets + tuning, no `entry`) are the same format with no code.
- **Multiplayer:** world mods work in a session. `side: "world"` mods are a
  compatibility set, hashed and checked in the join handshake; `side:
  "client"` mods are local and unhashed.
- **Persistence:** none yet. Enablement is per session; a restart restores the
  `mods/` directory's default.
- **Asset replacement:** allowed, through logical asset slots the host
  resolves. A mod may point `model.goat` or `sfx.music` at its own file.

**Where it lives.**

| Piece | Path |
| --- | --- |
| The API + registries (new scene part) | `crates/goats/src/game/mods.js` |
| Loader: discovery, manifest validation, ordering, hashing, asset reads | `crates/mods/` (pure crate, no engine) |
| Loader wiring, asset registration, entry evaluation | `crates/goats/src/main.rs` |
| The same loader on the server | `crates/server/src/` (`goatsd --mods`) |
| `ModRef` and the join handshake | `crates/proto/src/lib.rs`, `crates/session/`, `net.js` |
| Mod console verbs + Mods screen | `crates/goats/src/game/ctl.js`, `menu.js` |
| Fixture and tests | `mods/example/`, `crates/harness/tests/mods.rs` |

**Phases.**

- **M14a — Tuning registry. ✅ Done.** Every gameplay constant moved into one
  mutable tree (`TUNING`, `core.js`) the scene reads directly, with
  `tuningGet`/`tuningSet`/`tuningMerge`/`tuningWatch` as the validated write
  path (a typo, a branch write or a non-finite number throws; bounded leaves
  clamp). Defaults are byte-for-byte the old constants, so the vanilla run is
  unchanged; `tools/goat_logic_test.js` gained six tuning cases (135 pass).
  Herd size is now `TUNING.herd.count`, written by the menu and the console
  through `tuningSet`, with a watcher that resizes the herd. This is the
  prerequisite for the loader's `tuning.json` and for `goats.tuning`.
- **M14b — Loader. ✅ Done.** The pure loader is its own crate,
  `crates/mods/`: it discovers mod directories, parses and validates `mod.json`
  (api major, id, side, size caps, no paths escaping the mod directory), orders
  them by id with a deterministic `loadAfter` topological sort (missing deps and
  cycles are warnings, not failures), reads entries/tuning/assets into memory,
  and computes the FNV-1a compatibility hash. It has no engine dependency, so it
  is unit-tested without a window (8 tests) and `goatsd` can reuse it in M14d.
  The client wires it up in `main.rs`: `--mods <dir>` / `$GOATS_MODS` / `mods/`
  next to the exe or in the CWD, `--no-mods`, assets leaked to `'static` and
  registered under opaque `mod:<id>:<slot>` names (no path ever reaches JS), the
  metadata table pushed with `sceneMods(json)`, each entry evaluated inside a
  scoped wrapper, then `goats.freeze()`. The scene part `mods.js` holds the
  table, the minimal `goats` lifecycle, and the `mod
  list|info|key|enable|disable|reload` verbs; the console queues host intents
  and the frame loop drains them with `sceneModDrain()`, so enable/disable/reload
  genuinely re-read and re-evaluate. Events, commands, registries and the
  accessors are M14c.
- **M14c — `goats` API v1 (the hook surface). ✅ Done.** The per-mod wrapper and
  reload lifecycle; `goats.on` for the whole event set (`load ready update
  draw3d hud draw command weather mode spawn despawn session world tuning
  shutdown`), fired from the frame loop and the simulation; `goats.command`
  registration plus `command` observers (built-ins always win, reserved names
  refused); `goats.run(text)`; and the `player` / `camera` / `world` /
  `bots` / `settings` / `tuning` / `net` accessors. Registration closes at
  `goats.freeze()`, and a reload re-opens it for the mod being reloaded. The
  contract is `APIv1.md` §4.
- **M14c2 — Content registries and asset slots. ✅ Done.** The built-in asset
  names moved out of `const` into `ASSET_SLOTS` (core.js); `loadGoat`, `botAdd`,
  `addPeer` and `makeAudio` read the slot, and a mod's declared `assets` map is
  applied when the host pushes the table, in load order, so a **data-only pack
  replaces `model.goat` or `sfx.music` with no code at all**. `goats.bots.register`
  appends to `TUNING.herd.spec`; `goats.clips.register` retunes a walk / trot /
  run gait (`asset` is refused with a message until the model work, since
  swapping one clip's source is a different job); `goats.assets.override`
  re-points a slot at an opaque asset name. All three are pre-freeze.
- **M14d — World-mod digest and join handshake. ✅ Done.** A `side: "world"` mod
  is identified by `ModRef { id, version, hash }` -- the loader's FNV-1a hash
  over the id, the version, the entry's text, the `tuning.json` tree and every
  asset's bytes -- and the set travels in `ClientMessage::Hello`; the host
  compares it with `proto::compare_world_mods` and refuses a mismatch with an
  `Error` naming the missing, extra and differing ids, waiting for the peer to
  read it before the connection drops. `PROTOCOL_VERSION` is `7` (M16b raises
  it to `8`); `session` gains `Host::start_with_mods` /
  `Client::join_with_mods`; the client bridge sends the client's set when
  hosting or joining; and `goatsd --mods`/`--no-mods` discovers mods (the shared
  `crates/mods` loader) and requires the set of every joiner. The server does
  not simulate the mods yet -- M14d2 does that -- but the gate is real, so a
  client with different world mods cannot silently diverge.

  A digest taken over text was a portability trap, and the first user hit it: at
  the same commit (`0ab6137`) a Windows build hashed `mods/birds/mod.js` from a
  CRLF worktree while the Linux build hashed the LF blob, so a client and a
  `goatsd` that agreed on everything refused each other with `world mods do not
  match (differing com.github.sdgoij.goats.birds)` -- and the Windows and Linux
  release archives shipped a `birds.zip` that differed for the same reason. The
  digest is now the same number on every platform: `read_source_text` normalises
  `\r\n` to `\n` before an entry or a tuning tree is hashed or evaluated
  (JavaScript does not care which line ending ends a statement, so a mod's
  identity does not either), and `.gitattributes` pins `eol=lf`, so a checkout
  is the same bytes everywhere and the archives agree. The tuning tree joined
  the inputs at the same time, because a world mod whose `tuning.json` differs
  while its code does not is exactly the silent divergence the digest exists to
  catch. A refusal names both sides now -- `(host 1.0.0#bf1f98a740460a01, you
  1.0.0#3c9d2e5f10ab7742)` -- and `goatsd` and the client each log their set at
  startup (`goatsd: world set: <id>@<version>#<hash>`), which is what made the
  diagnosis one look rather than a guess. Opaque assets are still compared byte
  for byte, since the loader cannot know what they are. `mods/birds` itself is
  pinned at `bf1f98a740460a01` by a test, because a release ships it and an
  older client refuses a server whose birds differs.
- **M14d2 — World-mod simulation. ✅ Done.** `goats.world.registerStream` and
  `goats.rng` own a seeded PRNG stream per `side: "world"` mod; `sceneUseSeed`
  re-derives them from the session seed, and their state travels in the
  snapshot's `mods.streams` so a joiner continues rather than replays.
  `goats.world.extend(id, { publish, apply })` contributes JSON to
  `sceneWorldMods()`, which the host merges into the snapshot (a `mods` field on
  the proto `WorldState`, a generic JSON value bounded by the datagram cap) and
  `netApplyWorld` applies on a client through `sceneApplyWorldMods`. The server
  now **evaluates its mods** into the headless world, before `sceneUseSeed`, so
  a `goatsd --mods` world actually runs them; the loader gained
  `AssetMode::HashOnly` so the server hashes assets for the digest without
  keeping a mod's model in memory. APIv1 §4.13 is the reference.
- **M14e — UI and tests. ✅ Done.** The main menu gained a session-only
  **Mods screen** (`menu.js`): it lists what the host found with an Enable /
  Disable toggle each, writing the same flags `mod enable|disable` do, and a
  `side: "world"` mod cannot be toggled while in a session because the set was
  fixed at join. The `ui` console verb accepts `mods`. A checked-in
  `mods/example/` fixture documents the manifest and backs the fixture block of
  `crates/harness/tests/mods.rs` (`tools/mod_smoke_test.js` when this landed): it
  registers a command, draws a HUD clock, declares
  an `sfx.bleat` override (a tiny committed WAV) and ships a `tuning.json` with
  one valid leaf and one deliberate typo. That test evaluates the real
  scene plus that fixture the way the host does and asserts the command
  dispatches, the asset slot re-points, the known tuning leaf merges while the
  unknown path only warns, the `hud` hook runs, a throwing handler is isolated,
  and a reload leaves no duplicate handler or command. That last path exposed a
  gap: `tuning.json` was read by the loader but never applied -- `Manifest::json`
  now carries the tree and `sceneMods` merges it. CI ran a `node --check`
  syntax check over `mods/**/*.js` and the smoke test (both M15e's to remove),
  and a world-mod determinism test
  mirrors `the_same_seed_runs_the_same_world`. The harness gained the Mods
  screen and `modSetEnabled` cases (158 total) but still uses synthetic tables
  only, so the vanilla assertions are unchanged.
- **M14f — A full example world mod: `birds`. ✅ Done.** `mods/birds/` is the
  worked example of a mod that adds an entity of its own rather than patching
  an existing one. It builds a low-poly body and two wings with `rl.makeModel`,
  bakes a feather texture with `rl.makeTexture`, and poses the parts with
  quaternions reduced to the single axis-angle `drawModelEx` accepts. Five
  states -- idle (standing on the ground, or perched on a player's or a bot's
  goat), walk, take-off, fly and land -- with boids flocking while flying, a
  seeded stream and `world.extend` so the host simulates and clients ease to the
  published positions. It is `side: "world"`, so the flock is shared. Two
  engine facts it documented: models must be built lazily on the first
  `update`/`draw3d` (an entry runs before the window exists, and `makeTexture`
  needs the GL context), and `drawModelEx`'s one axis-angle means yaw, pitch,
  roll and wing flap are composed into a quaternion per part.
  `crates/harness/tests/birds.rs` (`tools/birds_mod_test.js` when this landed)
  drives the mod with a stub `rl` and asserts the
  meshes build, every state is reached, separation holds, a bird perches, a
  client mirrors instead of simulating, and two fresh worlds agree; a `server`
  test loads the real fixture through the real loader and checks the whole world
  still fits one datagram.
- **M14g — Mod developer workflow. ✅ Done.** Three things that make iterating on
  a mod bearable. `goats --watch` starts a `notify` watcher on the mods
  directory -- the platform's native API (inotify / kqueue /
  `ReadDirectoryChangesW`), not polling -- coalesces an editor's burst of writes
  and reloads the affected mod. `mod enable` / `mod reload` now re-read the mod
  **from disk** before evaluating it (`Loader::reload`), so code and
  `tuning.json` edits land without a restart; assets are re-read for the digest
  but not re-registered, so a model or sound change still needs one. And a mod
  may ship as a single `.zip` with `mod.json` at its root: `ModSource { Dir |
  Zip }` is what discovery records, and entry, tuning and assets are read
  through it, so a zip hashes identically to the equivalent directory. Only the
  zip crate's `deflate` feature is enabled, which keeps the new dependency tree
  to `flate2`/`miniz_oxide`. `--watch` is client-only: a `side: "world"` mod is
  fixed at join, so a server must not change it under its peers.

**Constraints to respect.** The scene is one flat global scope joined by
`concat!`, so `goats.freeze()`, not the loader, is what keeps registrations
sane. Embedded assets win over disk (`AssetFile::open` checks the registry
first), so replacement goes through slots rather than same-named files. The
client and the server evaluate the same parts, so a world mod has to work
against the null `rl` in `crates/scene/src/null_rl.js` and guard on
capability as the scene already does. Direct `rl.load*` with a path is allowed
-- a mod may point raylib at a file the slots do not cover -- but `goats.assets`
slots are the portable route, since the host owns resolution.

---

## M15 — Rust harness: the scene tests run on Slag

The three Node harnesses (`tools/goat_logic_test.js`, `tools/mod_smoke_test.js`,
`tools/birds_mod_test.js`) are the project's test suite, and they are the last
thing that needs Node. They also test the scene against a **model of the
engine**, so they cannot catch a binding or a builtin the real engine lacks.
`crates/server` already proves the alternative works: `headless.rs` evaluates the
client's exact scene on Slag against a null `rl`, with no window and no raylib.
M15 moves the harness onto that footing, so `cargo test` is the whole gate and
the tests run on the engine that actually ships.

**Decisions (settled).**

- **One scene list.** A new dependency-free `crates/scene` owns the ordered
  list, the joined script and the `rl` stubs; the client, the server and the
  harness all read it. `crates/goats/src/main.rs` stops carrying its own
  `concat!` list, and the server's client/server drift test goes with it: a
  single source cannot drift.
- **Assertions in Rust.** Only the fake engine stays JavaScript, and only
  because it has to -- the scene calls `rl` from JavaScript. The driver and every
  assertion are Rust.
- **No Node, in any way.** The end state has no `setup-node`, no `node` step and
  no `tools/*_test.js`. Slag's builtin surface already covers what the stubs use,
  `Proxy` included (verified in the linked engine: `Proxy`, its traps,
  `Proxy.revocable`, `Reflect` and `String.prototype.padEnd` all work), so the two
  mod tests' catch-all stubs port as they are rather than being rewritten as
  explicit enumerations.
- **No Node oracle.** The expected values -- magic frames, gait speeds, clip
  names -- are already written into the current checks, so the port transcribes
  them verbatim. A mismatch is a finding to investigate, not a number to
  re-baseline.
- **A strict stub.** The harness's `rl` returns packed numbers from `color` and
  checks that every argument of a draw or model call is a number -- the guard
  `birds_mod_test.js` already carries, which is what caught an object colour
  reaching `drawCube` and aborting the birds on the client.
- **The cost is accepted.** See below; the harness doubles as Slag's performance
  workload.

**What it costs (measured).**

| Suite | Cases | Node/V8 | Slag, release | Slag, debug |
| --- | --- | --- | --- | --- |
| `scene_logic.rs` (4050 frames) | 141 | 1.9 s | **31 s** | 113 s |
| `mods.rs` (60 frames) | 38 | — | 1.9 s | ~6 s |
| `birds.rs` (driven by hand, no timeline) | 26 | — | 11 s | does not fit the stack |

The engine's own Rust is what is slow unoptimized, so the long runs are
`#[ignore]`d and driven in `--release`, while the short ones are part of a plain
`cargo test`. That is the price of dropping Node, and it is also the first time
the engine's speed is visible as a number: the same workload is what Slag's own
`--jit-bench` measures, so engine work now shows up here.

**What the port taught us about the engine.** Three findings, all of them
engine characteristics rather than harness bugs:

- **Naming a hot function's parameters costs ~25%.** The recording stub's
  `drawCube` is deliberately written parameterless (`drawCube: function () { … }`):
  30.6 s for the run against 38 s for the same 1.4M calls with its six parameters
  named. `arguments` inside a `function` is worse still (107 s in one experiment),
  so the natural way to write a recording stub is the slow way. The strictness the
  parameters would have bought lives on `drawModelEx` instead, which is called a
  few thousand times rather than a million.
- **A debug build cannot take the flock.** `birds.rs` passes in release and fails
  exactly one case in debug with `RangeError: Maximum call stack size exceeded`,
  thrown inside the mod's `update`: unoptimized builds spend far more stack per
  activation (`README.md` §Troubleshooting), and the deepest script in the suite
  runs out of it. So the file is `#[ignore]`d for a reason that is not just
  speed.
- **Two stepped engine contexts abort the process.** Two `Context`s with one of
  them being stepped dies with `STATUS_ACCESS_VIOLATION`, reproducible from a
  fresh process in ten lines; creating and dropping twelve *serially* is fine, as
  is 24k updates across them. The harness therefore holds **one live context at a
  time** -- which is why `birds.rs` scopes each world rather than keeping two, and
  why a new case in an existing binary has to reuse the harness instead of
  starting a second one. Tests inside one binary share a process, so parallel
  `#[test]`s each wanting a scene would hit this.

**Where it lives.**

| Piece | Path |
| --- | --- |
| The scene list, the joined script and both `rl` stubs | `crates/scene/` |
| The harness: driver, glue, observations | `crates/harness/` |
| The ported assertions | `crates/harness/tests/` |
| The fixtures the tests load | `mods/example/`, `mods/birds/` |

`crates/harness` depends on `slag` with only the `jit` feature, exactly as
`crates/server` does, so the tests build without raylib and without a display.

**Phases.**

- **M15a — Single-source the scene; spike the harness. ✅ Done.** `crates/scene`
  owns the ordered list, the `SCENE` `concat!` and both `rl` stubs -- `null_rl.js`,
  moved off the server, and the recording `harness_rl.js` -- so the client, the
  headless server and the harness share one copy and the client/server drift test
  is gone. `crates/harness` evaluates the scene on Slag (the `jit` feature only:
  no raylib, no display), drives the scene's own `run()` loop and reads the
  observations back as one JSON string. The spike pins the footing: the scripted
  gaits land on the same frames the Node harness used, the run is deterministic,
  `help` survives as a multi-line page (which exercises `padEnd` on the real
  engine), and two contexts run on two threads at once. The three Node harnesses
  were repointed at `crates/scene` so they stay green as the cross-check, and
  `main.rs` still owns the embedded-asset table their checks read.
- **M15b — The stub, the timeline and the probes. ✅ Done.** The recording `rl`
  now covers the whole surface the assertions need: the per-frame timeline and the
  console probes, the model/shader/texture/audio call tables, the terrain mesh,
  where the goat and each bot were drawn, the scene's own `console.log` lines, and
  a counter set a test can zero between measurements. `Observations` carries it as
  typed Rust, plus `observe` (re-read after driving the scene), `call` (any scene
  function by name), `eval` (into the scene's own scope) and `reset_counters`,
  each returning an `{ok, value}` envelope so a failure reports what the scene
  said rather than a conversion error. Two engine details surfaced, both worth
  knowing: the host `console.log` is a native function with no
  `Function.prototype` (so it cannot be forwarded with `.apply`), and `Math.min` /
  `Math.max` are natives of the same kind. Because the stub's shaders are valid,
  the harness takes the real lit and shadow paths as the Node harness did: the
  same run draws 1.49M cubes and costs 35.5s (8.8 ms/frame).
- **M15c — The assertions. ✅ Done** (the mod cases are M15d). 141 cases in
  `scene_logic.rs`, on one 4050-frame run reported through a collector, so a
  failure names itself and the rest still run -- the Node harness's reporting,
  kept. Ported: the gaits, stats and death; weather, lighting, the sky shader and
  audio; the splash and the embedded-asset table; grass, eating and the terrain;
  the settings and the tuning tree; the console and the clipboard; the network
  bridge, chat and world sync; the herd's animation; and the help page's
  formatting. The expected values are transcribed, never re-derived, and a
  name-by-name comparison against the Node harness's case list is what confirmed
  the coverage -- it caught three bot cases that had been missed.
- **M15d — The mod tests. ✅ Done.** The 24 mod cases in `goat_logic_test.js` (the
  `goats` lifecycle, commands and observers, events, the tuning hook, the
  accessors, the registries, the world extension and the Mods screen) are
  `crates/harness/tests/mods.rs`, joined there by the 14 cases of
  `mod_smoke_test.js` in its `fixture_block`, which loads the checked-in
  `mods/example/` fixture the way the host does -- compiled in with `include_str!`,
  so a broken fixture fails the build as well as the case. The host-side half of
  the smoke test is consolidated rather than duplicated: the loader's own 18 tests
  already cover manifests, ordering, zips, reload and the watcher, and the
  fixture-specific half (manifest well-formed, declared asset a real RIFF wav) is
  two lines. `birds_mod_test.js`'s 26 cases are `crates/harness/tests/birds.rs`.
  Two things the port settled: the fixture block runs **last**, because
  `goats.freeze()` is one-way and the table block is the case that asserts it was
  open before it froze; and the HUD-hook cases stand in for `rl.drawText` with an
  `eval` probe, the way the Mods-screen cases already stand in for the raygui
  calls, so `modEmit("hud", …)` reaches only the mod's handler and the count is
  the same fact the Node harness measured.
- **M15e — Node is gone. ✅ Done.** `setup-node`, the `node --check` glob and the
  three `node` steps are out of `.github/workflows/ci.yml`. The `test` job is now
  two Rust steps: `cargo test --workspace --exclude goats` (the client crate
  links raylib, and the build job is the one that installs the toolchain that
  needs) and `cargo test --release -p harness -- --ignored --nocapture` for the
  scene suite. The three `tools/*_test.js` files are deleted, and `README.md`,
  `APIv1.md` §10 and the cross-cutting notes here no longer mention them.

The Python tools stay: `tools/inspect_glb.py`, `goat_states.py` and
`goat_variants.py` are Blender and model-authoring scripts, not tests, and have
nothing to do with the harness.

**Constraints to respect.** The port has to keep the assertions' *meaning*, not
just make them pass: the magic frame indices (the rain speed at frame 3400, the
console probes at frame 4007+) encode real behaviour, and re-deriving them would
turn the suite into a description of whatever the code happens to do. The strict
stub is deliberately stricter than the server's null `rl`, so a test that needs
the looser behaviour should say why. And the harness is one long deterministic
run and therefore one test; splitting it into parallel scenarios is an optional
later step, and it changes the frame indices, so it must not land in the same
change as the port.

---

## M16 — The world datagram: binary, quantized and bounded

The world snapshot is JSON, sent ~10×/s (the pose channel is ~20 Hz and voice
~50 Hz), and it is **already over budget in vanilla play** -- before any mod is
involved. Measured on the headless scene, encoding the real `Datagram::World`
(`crates/server`, one 150 s run, released build):

| Configuration | bots | meadow | mods | datagram | headroom |
| --- | --- | --- | --- | --- | --- |
| herd 7 (the default), empty meadow | 602 | 2 | 24 | 886 | +314 |
| herd 7, meadow at 10 cells | 602 | 320 | 24 | **1202** | **-2** |
| herd 10 (the clamp), empty meadow | 866 | 2 | 24 | 1150 | +50 |
| herd 7 + the `birds` flock | 602 | 2 | 235 | 1097 | +103 |
| herd 10 + a 20x5 mod payload | 866 | 2 | 403 | **1529** | **-329** |

The meadow is not a corner case: it is where the bot herd's own grazing puts it.
The same run reports `eaten` at 6 cells after 25 s and 10 after 150 s -- entries
expire only after `TUNING.food.regrowMin..regrowMax`, 40-90 s -- so a default
session crosses the cap about two minutes in and then oscillates across it.
Crossing means `Host::broadcast` returns silently: every client freezes at the
last good snapshot, and just before that the world arrives in fits. Nothing logs
it, and the same failure takes down the whole snapshot whatever field caused it,
so one greedy mod evicts everyone's world rather than losing its own state.

**All four levers, plus a binary wire.** The levers compose, and the format
change is what buys the most -- it also *subsumes* "make the JSON smaller", since
there is no point hand-tuning key names that are about to disappear.

**Why not protobuf.** protobuf earns its keep with a schema two independent
implementations share, and it costs `protoc` at build time (or a hand-rolled
`prost` derive) plus a second set of types. Here both ends are the same Rust
crate from the same build behind a `PROTOCOL_VERSION` gate, and the types are
already `serde`-typed: a serde-based compact codec -- **postcard** (`varint`, pure
Rust, no build step) or **bincode 2** -- gets the same win from the same derives,
with `serde_json` kept for the frames and the JS bridge. Two obstacles have to be
handled whichever way it goes:

- `Datagram` carries `#[serde(tag = "kind")]`, and an internally tagged enum needs
  a self-describing format to deserialize. It becomes a one-byte tag (or an
  externally tagged enum), which is also cheaper.
- `WorldState::mods` is a `serde_json::Value`, and a non-self-describing format
  cannot decode one (`deserialize_any`). That is not a loss: the transport has no
  schema for what a mod publishes, and the payload only ever enters and leaves
  Rust as JSON. It travels as **length-prefixed JSON bytes** (`RawValue`, so the
  client can splice it into the bridge JSON without re-encoding) -- which is also
  the argument for M16d.

**The frames stay JSON.** The control streams carry chat text, tickets and names,
ride the JS bridge (which is JSON by construction), and are read by humans when a
session misbehaves. Their bytes are not the problem; the 10 Hz datagram is.

**What it is worth (measured).** The "before" column is what the same fixture
encoded to as JSON when M16a landed -- *including* the world mods, which travelled
inside the world then. These are read off `datagram_size` and `encode_datagram`
in a test, not estimated.

| Configuration | JSON | binary + quantized |
| --- | --- | --- |
| herd 7 (the default), empty meadow, no mod | 886 | **119** |
| herd 7, meadow at 20 cells, no mod | ~1470 | **239** |
| herd 10 (the clamp), meadow at 20 cells, no mod | ~1600 | **269** |
| the `birds` flock, on the mods datagram | 1097 (with the flock in the world) | **155** |
| one bot, inside a world | 86 | **10** |
| one peer pose | ~120 | **17** |
| one voice frame, a 60-byte Opus payload | ~104 | **69** |

The rows marked `~` are extrapolated from the measured ones (six bytes a meadow
cell, 211 for the flock); everything else was read off `datagram_size` and
`encode_datagram`. The headline is the herd-7 pair: at 886 bytes that shape used
to fit only with an empty meadow, and at 119 it fits with room for eighteen of
them. M16d did not make the bytes fewer -- the flock's 155 is what it always cost,
since a mod's payload was already opaque JSON -- but it made them *separate*: a
session with the flock now spends 119 on the world and 155 on the mods instead of
274 in one datagram, where either could push the other out.

A bot was 86 bytes of JSON (`{"index":0,"x":1.234,"z":-12.345,"yaw":0.5,
"phase":0.123,"gait":"walk","variant":0}`) and is 10 as a quantized record: an
`i16` of centimetres each for `x`/`z`/`yaw`, a `u8` for the animation clock, the
gait's variant byte, and the rest varint.

**Phases.**

- **M16a — Make the snapshot budget-aware. ✅ Done.** The failure was silent and
  total, so this landed first and stands alone. The shedding is in Rust, not in
  the scene: `proto::fit_world(&mut WorldState, budget)` measures the real
  encoded datagram and trims it -- the meadow first, then world-mod state, never
  the bots, the sky or the streams -- returning a `WorldOutcome` that names what
  happened (`Whole`, `MeadowShed`, `ModsShed`, `TooLarge { size }`, `NotFinite`),
  with `describe()` holding the wording so the client host and `goatsd` say the
  same thing. Both get it through `Host::publish_world`, which now returns the
  outcome, and the two callers report it **on the change** rather than ten times
  a second. The plan's `sceneNetBudget(maxWorldBytes)` turned out to be
  unnecessary: the snapshot only exists as a `WorldState` on the Rust side, where
  its encoded size is exact, so the scene never needs the number and there is no
  constant to keep in step with `proto`'s.

  Two things the work settled along the way. **Shedding has to mean "keep", not
  "empty"**: `WorldState::eaten` is now `Option<Vec<EatenCell>>`, and a snapshot
  that could not carry the meadow omits the field, which `applyEaten` reads as
  "keep the one you have". Sending it as an empty list would put back every tuft
  the host had eaten -- and since a client picks its eat target with
  `nearestTuft` and reports the key, a client that believes a tuft is there
  cannot eat it, which would have made the shed meadow a gameplay bug rather than
  a cosmetic one. A world mod's `null` already meant the same thing, so only the
  meadow needed the change. And **a refused world is handed back untouched**, so
  the `TooLarge` size it reports is what the irreducible parts come to on their
  own. Seven `proto` tests (the measured over-cap fixture, the shed order, the
  refusal, and the round trip of a meadow that is missing rather than empty) and
  a `session` test that an over-budget world still reaches a client without its
  meadow.
- **M16b — A binary datagram channel. ✅ Done.** `crates/proto/src/wire.rs` is
  the packed form, and postcard is the codec: a variant byte where
  `#[serde(tag = "kind")]` cost twenty, and the entity fields quantized -- `x`/`z`
  at 1 cm as `i16`, `yaw` at 1/10000 of a turn, `phase` at 1/255, `speed` at
  1/256 m/s, `EatenCell::left` in quarter-seconds as `u16`. `WeatherState` and
  `Streams` ride as they are: neither carries an entity count, so postcard's
  fixed-width fields are already the right size. `WorldState::mods` travels as
  opaque JSON bytes, which is what it always was -- the transport has no schema
  for a mod's payload -- and it is also why M16d is the natural next step. The
  two codecs are named for their channels (`encode_frame`/`decode_frame` for the
  JSON control stream, `encode_datagram`/`decode_datagram` for this one), and
  `PROTOCOL_VERSION` is 8: a version-7 peer would fail to decode every datagram,
  so the two would agree on a session and then see nothing move. `base64` is gone
  from the crate, because the voice payload is the bytes now, and
  `Error::NotFinite` is what an encoder returns when a datagram carries a NaN --
  quantization would otherwise turn one into an unrelated number, which for a
  position is a peer teleporting across the field.

  Two properties the tests pin, because both are easy to lose in a later edit:
  **a quantized field saturates rather than wraps** (`1e30` and `NaN` land on the
  edge of the range, not somewhere else in it) and **the encoding is idempotent**
  (a relay decodes a peer's frame and re-encodes it with the name stamped on, so
  `decode`-then-`encode` has to return the same bytes or a value drifts every
  hop). The `session` tests now assert the wire's resolution at the integration
  level -- positions to 1 cm, the clock to 1/255 -- with everything the wire does
  not touch (the gait, the variant, the sky, the streams, a mod's bytes) still
  exact. The M16e guard was restated at the same time: the worst case a player can
  reach without a mod fits **whole**, with room for a greedy mod, and it takes a
  deliberately greedy one to force a shed at all.
- **M16c — The meadow at its own cadence. Deferred, deliberately.** A tuft that
  returns in 40-90 s does not need 100 ms resolution, so `eaten` could travel on
  a slower tick and stop its size being coupled to the world's rate. The
  measurement says it is not worth a protocol field: a meadow cell is six bytes,
  and the map is bounded by the regrow window rather than by session length --
  the steady state is however many bites the herd takes in a minute, eight to ten
  cells with the default seven bots. The real version of this is a delta with a
  periodic full resync, which is a protocol of its own, and nothing today
  justifies it. M16e's guard is what would say when something does.
- **M16d — World mods get their own datagram. ✅ Done.** `Datagram::Mods`
  carries `{ streams, data }` -- exactly what `sceneWorldMods()` returns, opaque
  as ever -- and the scene queues it beside the world snapshot, only while a
  world mod is loaded. `WorldState` lost its `mods` field, so `fit_world` lost
  its second shed step, and the mods gained a `fit_mods` of their own: there is
  nothing to shed *inside* that payload (the transport cannot tell one mod's
  contribution from another's), so it is a size check and a report, and the
  per-mod answer -- a datagram each, so a greedy mod loses only its own state --
  remains open. Alongside it, `goats.world.publishRows(rows)` is the compact way
  to publish a table: rows of finite numbers rounded to three decimals, at most
  64 rows of 8, with a `NaN` thrown at the publisher -- where the log names the
  mod -- rather than becoming a `null` at every peer, and a warning when one
  table passes ~600 bytes. The `birds` fixture publishes through it now. The
  callback dropped its `name` argument from the plan: `rows` alone says it, and
  the diagnostics already carry the mod's id.
- **M16e — A guard so the budget cannot silently erode again. ✅ Done.** The
  guard is three tests, and they are the ones to read before adding a field to
  `WorldState`:
  - `proto::the_vanilla_world_fits_with_room_to_spare` builds the worst case a
    player can reach without a mod -- the herd at its clamp and a meadow well
    along -- and requires it to fit *whole* in under a third of the budget, so
    the next field has to argue for its bytes.
  - `proto::an_over_budget_mods_state_is_reported_rather_than_dropped_in_silence`
    and its neighbour hold the mods' side: the flock's shape fits its own
    datagram, and a state over the cap is refused with the size named.
  - `server::the_birds_fixture_loads_and_both_datagrams_fit` runs the real
    fixture through the real loader on the headless scene and checks both, plus
    that the flock is **not** in the world: the separation M16d bought cannot be
    undone by a later edit without a red test.

  The stale comment in `food.js` -- "does not regrow within a session", which the
  40-90 s regrow contradicts -- is fixed, and the map's bound is written down
  where the map is.

**Where it lives.**

| Piece | Path |
| --- | --- |
| The wire types, the two codecs, the tag and the caps | `crates/proto/` |
| The datagram paths (world, pose, voice, mods) | `crates/session/` |
| The snapshot assembly, the shed order and the mods datagram | `crates/goats/src/game/net.js`, `mods.js` |
| The shed order, the outcome, and the two reporters | `crates/proto/`, `crates/session/`, `crates/goats/src/net.rs`, `crates/server/src/main.rs` |
| The worst-case guard | `crates/server/src/headless.rs`, `crates/harness/tests/` |

**Constraints to respect.** `MAX_DATAGRAM_BYTES` stays 1200: it is the IPv6
minimum-MTU-safe value and both ends refuse anything larger, so raising it trades
a bug for an MTU-dependent one. Quantization must not lose anything observable to
a player -- the fields chosen are all below the resolution the sim reads back at
-- and a quantized field that saturates has to clamp rather than wrap. The mods
datagram must stay optional: a vanilla session should pay nothing for it.

---

## M17 — Compiled mods: WebAssembly

**Why.** M14 gave the game a mod API, but mods are JavaScript: an entry is
evaluated into the scene and that is the only way in. That excludes anyone whose
work lives in Rust, C, Zig, Go or AssemblyScript, and it excludes the libraries
they would bring. Wasm is the one way to lift that without giving up the property
`APIv1.md` section 0 is built on -- that a mod gets no filesystem, no path, no
socket and no engine internals.

**Why not speed.** The honest answer is that this is not (yet) a performance
feature. Slag runs wasm on an interpreter; the Cranelift wasm-to-native path
exists but is off by default until its equivalence gate holds corpus-wide, while
the JavaScript path has had years of optimization and the client already enables
its JIT. If speed were the goal, the first move would be more JS optimization.
The ABI is therefore designed so speed is not a premise: see the coarse crossing
below. See `PLUGIN-ABI.md`.

**What already exists, and what that means.** Slag's `wasm` crate is a full
WebAssembly core engine -- decoder, validator, interpreter, SIMD, GC,
exceptions, tail calls -- built cut-by-cut against the pinned official `waspec`
submodule, with the embedding API (`Store`, `Instance`, `Memory`, `Value`) already
shaped for a host: `external_host` + `start`/`resume`/`abandon` exist precisely
to suspend a run around a host call. The WebAssembly **JS API is a default-on
runtime feature** (`runtime/wasm`, installed as the `WebAssembly` global) and
`goats` does not turn defaults off, so **the shipped client and the headless
harness already have it**. `crates/slag/examples/wasm_smoke.rs` instantiates a
module and calls an export from JS today. So the engine is not the work; the ABI,
the host and the policy are.

**The proof that the ABI is not Rust-shaped.** `fixtures/wasm/` holds one ABI
implemented twice -- `c/plugin.c` (clang, `wasm32`, `-nostdlib`, no WASI) and
`rust/src/lib.rs` (`wasm32-unknown-unknown`) -- as checked-in artifacts of 733 and
335 bytes, so the test and CI need no wasm toolchain.
`harness::plugin_abi` loads both through the `WebAssembly` global with a JS host
stub and requires that both negotiate the same ABI version, declare exactly the
imports `goats.log` and `goats.rng` (read off the module, not assumed), log the
string the host reads out of *their* memory, and return **the same `vx` values,
byte for byte**, given the same host-provided randomness. Two toolchains agreeing
on a computed result is what says a mod author in a third language would not hit
an ambiguity.

It also found one thing by failing: an `i64` parameter is a `BigInt` across the
JS boundary, so the ABI is `i32`/`f32`/`f64` only.

**Decisions.**

1. **The import list is the API.** A plugin's power is the length of its import
   list, granted at instantiation. A missing import fails to *link*
   (`unlinkable`), so default-deny is structural rather than a check someone can
   forget. The list is inspectable without running the module.
2. **No WASI.** A plugin that tries to open a file does not get policed, it does
   not link. Section 0's I/O wall becomes a property of the linker.
3. **One coarse crossing per frame.** The host writes a record array into the
   module's linear memory, calls `goats_update(ptr, count, dt)` **once**, and
   reads the results back out. This is what makes a slow interpreter tolerable:
   the gap applies to the inner loop -- the part `compile` exists to fix -- not
   to every entity. It also means buffer layout is part of the ABI.
4. **No clock import**, so a world mod that cannot read wall time cannot desync.
   Arithmetic is specified in the ABI, not implied: `vx' = f32(f64(vx) + rng(i) *
   f64(dt))`, one draw per record, ascending.
5. **No `dlopen`.** Not deferred -- out of scope for the mod system. No stable
   Rust ABI, per-platform artifacts, a library that can never be unloaded safely
   (so `--watch` dies), a segfault that takes the game with it, and native math
   diverging per platform. Wasm is a stable ABI with an independent
   specification, and one artifact serves all three release targets.
6. **A world mod's wasm runs the interpreter**, and `compile` stays opt-in, per
   the engine's own equivalence-gate rule: two hosts must agree on the world
   whatever codegen path they built.

**Engine prerequisite (upstream Slag).** From `goats`, the `wasm` crate is not
reachable: `slag`'s own dependencies are `crux`/`runtime`/`jit`, the `wasm` crate
hangs off `runtime` behind a feature, and `Context` exposes no instantiation API.
The zero-JS shape therefore needs either a re-export of the engine surface from
`slag`, or a second dependency on the same git revision (Cargo unifies it, but the
two declarations then move in lockstep forever). Same shape as M9's upstream
prerequisite.

- **M17a — The ABI and wasm as a primitive.** The host hands a mod's `.wasm`
  over as bytes, never a path, the way every other asset already crosses; the
  scene's `WebAssembly` does the rest, so a mod ships wasm plus JS glue and
  receives the existing events. Deliverables: `PLUGIN-ABI.md`, the two-language
  fixture and its test (done), a fixture mod that uses them, and the Mods screen
  reporting what the module declares it wants.
- **M17b — The Rust-side host.** Drive the module's exports from Rust, with the
  deterministic subset of `goats` (`rng`, `publish`/`apply`, world queries)
  implemented in Rust, so a plugin needs no JavaScript at all. This is the shape
  that delivers the promise, and it is the one that needs the prerequisite above.
  Reload becomes "drop the instance, instantiate again", extending M14g's
  `--watch` to compiled mods.
- **M17c — World-side plugins in the compatibility set.** The digest covers the
  artifact's bytes **and** the ABI version, and section 6.4's determinism rules
  gain the corresponding line. The open question is host-provided math: core wasm
  has no `sin`/`cos`, so either the host supplies them (and its platform `libm`
  becomes a divergence hazard) or plugins bring their own -- and the scene's JS
  world mods have the same hazard through `Math.*` today, so it should be decided
  once for both.
- **M17d — The performance debt, paid or priced.** Enable `wasm --features
  compile` in the client behind a flag, keep the equivalence gate, and record the
  number (below). Until this lands, the honest claim is "another language", not
  "faster".

**What to measure.** A benchmark kernel -- the boid inner loop at N entities, the
shape `birds` already exercises -- run three ways: JavaScript under the JIT, wasm
on the interpreter, wasm via `compile`. Three numbers in a test, so "wasm is slow"
is falsifiable and the day it stops being true is visible. Until then the
repository should not claim a compiled mod is cheaper than a JavaScript one.

**Constraints to respect.** The ABI is frozen by version negotiation, not by
convention: `goats_abi()` is called first and a version the host does not know is
refused the way a wrong `api` major already is. Scalars stay `i32`/`f32`/`f64`. A
plugin must not be able to reach the scene's state -- if a capability needs it,
that is a decision about the API, not an implementation detail of the bridge. And
with no instruction budget in the engine, a runaway plugin hangs the frame
exactly as a `while (true)` does; that is a known gap, not a solved problem.

**Where it will live.**

| Piece | Path |
| --- | --- |
| The ABI specification | `PLUGIN-ABI.md` |
| The two-language proof, sources and artifacts | `fixtures/wasm/` |
| The ABI test | `crates/harness/tests/plugin_abi.rs` |
| The plugin host (M17b) and the digest input (M17c) | `crates/plugin/` (new), `crates/mods/` |

---

## Cross-cutting work

- **Host status page.** ✅ **Done.** `goatsd --listen host:port` serves a small
  hand-rolled HTTP page (`crates/server/src/web.rs`) with the ticket, the number
  of connected clients -- taken from the session's roster events, so it excludes
  the host -- and a client download link (`--download URL`, defaulting to the
  GitHub releases page). Without `--listen` no HTTP server starts, which keeps a
  headless host's footprint to the session alone. `GET /info` returns the same
  facts as JSON.
- **Splitting the scene.** ✅ **Done.** The scene is
  `crates/goats/src/game/*.js` in fifteen parts (core, model, world, lighting,
  sky, audio, weather, food, bots, goat, ctl, menu, console, net, mods), joined in
  the order listed by `crates/scene`. The host concatenates them and evaluates the
  result as one script, so every part shares a single top-level scope and the
  engine still needs no module system; M15a moved the list out of
  `crates/goats/src/main.rs` into `crates/scene`, so the client, the server and
  the harness share one copy instead of each parsing their own.
- **Workspace.** ✅ **Done.** The repo is a Cargo workspace: `crates/goats` (the
  client and the JS scene, and its `default-members`, so `cargo run` means the
  client), `crates/proto` (the wire types, framing and name rules, with no iroh
  or tokio), `crates/session` (the iroh transport and session state machine) and
  `crates/server` (`goatsd`). The assets stay at the repo root and the client
  reaches them with `include_bytes!("../../../…")`.
- **Host bridge.** ✅ **Done.** The JS↔Rust boundary is line/JSON in both
  directions: `sceneCommand` in, `sceneNetEvent(line)` for networking events, and
  `sceneNetDrain()` out — the host calls it each frame and it returns and clears
  the scene's queued intents. The scene cannot call the host directly, because
  the public `slag` API registers no native functions; that is what makes the
  drain the shape it is. The synchronous frame loop never awaits: the tokio
  runtime and the session live on their own thread.
- **Persistence.** Saving stats and time of day would make death and long
  sessions meaningful. Needs a small host-side file API or an in-memory
  restart-only model. The same API has to hold the netplay endpoint's secret key
  (M10): lose it and the player loses their identity.
- **Audio.** Weather beds, a bleat on jump/death, an ambient night layer.
  Bindings already exist.
- **HUD.** Bars, clock, weather icon, a death screen. `drawRectangle`/`drawText`
  plus `drawTextEx` and `drawRectangleGradientV` from M0.
- **Repo hygiene.** The Blender `*.blend1` auto-backup is git-ignored and
  untracked (`goat.blend1` stays on disk for Blender but is not in the repo).
- **Validation.**
  - Extend the scene harness (`crates/harness/tests/scene_logic.rs`) with a
    simulated clock: assert energy
    drains at the right rates, sleep recovers, starvation damages health, and
    health 0 enters `dead`.
  - Reuse the animation checks (FK error, ground contact, loop closure) for the
    new `GoatSleep` and `GoatDeath` clips.
  - Give every new engine binding a throwaway probe and a case in the `rl`
    surface test (done for M0).
  - Blender renders of new clips for visual review.

---

## Open questions

1. ~~**How photorealistic?**~~ **Settled:** a raymarched cloud slab (M5b) over an
   analytic atmosphere, tuned by the Clouds setting. True radiative transfer and
   volumetric atmosphere scattering remain a possible later experiment, not a
   plan.
2. ~~**Eyelids:**~~ **Done:** real eyelids — a `LidL`/`LidR` bone pair with
   spherical-cap shells, closed by the `GoatSleep` clip. The swapped
   closed-eye sprite is gone.
3. **Death:** is it permanent for the run, or a respawn at the last safe spot?
   Save the session or not?
4. ~~**Does weather affect gameplay?**~~ **Settled:** yes (M6) — rain and wind
   slow the goat and drain energy faster.
5. **Weather determinism:** currently seeded, so a run is reproducible and the
   harness is stable. Keep, or make it random per run?
6. ~~**Scene splitting?**~~ **Settled:** thirteen files in
   `crates/goats/src/game/`, joined in the order listed in
   `crates/goats/src/main.rs`.
7. ~~**Shadow scope:**~~ **Done:** the goat *and* the grass inside the shadow
   box cast into the depth pass. Tufts outside the box are culled (their shadow
   could not be sampled anyway). Props would follow the same path if added. One
   1024² cascade is still enough while the world stays a single goat-sized field;
   a larger world would want cascades or a bigger map.
8. **What does the terrain gain next?** Water is the obvious visual gap (the
   field has hollows but no lakes or streams), but a splat-map material upgrade
   and scattered props (rocks, trees) on the same field are both cheaper, and
   nothing yet justifies leaving the level spawn bowl.
9. **Authority model.** Client-authoritative player goats relayed by the host
   (simple, low-latency, trusts the client) is what we ship first;
   server-authoritative movement, prediction and reconciliation wait until the
   sandbox actually needs them.
10. ~~**Reach.**~~ **Settled and verified:** LAN/direct is the default and needs
    no third party at all; `GOATS_INTERNET=1` swaps the preset to `presets::N0`
    (n0's public relays plus DNS discovery) for internet reach. A `goatsd` on a
    remote VPS accepted two clients from a home network over it. Two things
    learned in the doing: a default (`Minimal`) host is not WAN-reachable even
    through its ticket — it surfaced as a connect timeout — and the switch has to
    be on **both** ends, not just the host, because `RelayMode::Disabled` also
    disables dialing relays. Whether the established path ended up direct or
    relayed was not logged.
11. **Bots and weather in multiplayer.** Server-owned (recommended — bots
    collide with players, so they diverge the moment anyone interacts) or
    cosmetic per client?
12. **Join method.** Copy-pasting an `iroh-tickets` ticket is v1; a short room
    code needs a rendezvous service (`pkarr`, `iroh-gossip-rendezvous`) — later,
    or never?
13. **Death and pause in multiplayer.** `P` freezes the world locally and death
    offers a local restart; both must become server-owned or be disabled.
14. **`bevy_iroh`.** Trial it and pin a version: it advertises exactly the
    replication/rooms/presence we want, but it is Bevy-shaped and days old. Fall
    back to a hand-rolled session layer over plain `iroh` if it does not fit.
15. ~~**Mod trust model?**~~ **Settled:** mods are trusted code, but `fs` stays
    off and JavaScript never touches the filesystem -- the Rust host does all
    I/O and hands the scene opaque asset names (`APIv1.md` §7).
16. ~~**Can mods work in a session?**~~ **Settled:** yes -- `side: "world"`
    mods are a compatibility set hashed into the join handshake, while
    `side: "client"` mods are local and unhashed (M14d, `APIv1.md` §6).
17. ~~**Mod format: raw patching or an API?**~~ **Settled:** a versioned
    `goats` hook API, with data-only packs (assets + tuning, no code) as the
    same format (`APIv1.md`).
18. ~~**Mod persistence?**~~ **Settled:** not yet -- enablement is per session
    and a restart restores the `mods/` directory's default.
19. ~~**May a mod replace built-in assets?**~~ **Settled:** yes, through
    logical asset slots the host resolves (`APIv1.md` §3.3).
20. ~~**Room for world-mod state in the world datagram?**~~ **Settled: and it is
    not only about mods.** Measured, the snapshot is over its 1200-byte cap in
    vanilla play once the meadow has ~10 eaten cells -- about two minutes into a
    session -- and the overflow is dropped silently, taking the whole world with
    it. M16 gives it a binary, quantized wire, a shed order with a log, its own
    cadence for the meadow, and a datagram of its own for world mods, so the
    world and a mod can no longer evict each other.
21. **Slag performance.** Now measurable instead of guessed: the harness runs on
    the engine (M15), where the 4050-frame scene costs ~7.6 ms/frame against
    ~0.47 ms on Node, so CI's test step goes from ~2 s of Node to ~45 s of
    release Rust. Profiling the frame loop, and comparing the JIT against the
    interpreter on a realistic workload, is a self-contained task -- and it has
    already paid for itself once: naming a hot function's parameters costs ~25%
    (M15, "What the port taught us about the engine").

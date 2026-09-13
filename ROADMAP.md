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
  soundness and loop closure, and every state machine change gets a case in
  `tools/goat_logic_test.js`.

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
| **M13b** | Voice: capture, VAD, Opus, media channel, playback | M13a | L | ✅ **Done** (needs a live two-client listen) |
| **M13c** | Voice polish: jitter buffer, PLC, mute/volume, attenuation | M13b | M | Per-peer controls and the talking indicator |

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
code-side via `tools/goat_logic_test.js` (clock, weather text and `C` are
covered); visual look is **not** machine-verified.

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
`tools/goat_logic_test.js` already proves works: terrain, weather, bots and food
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
global line and a whisper end to end), `node tools/goat_logic_test.js` (113
checks, including the console's chat and command routing) and clippy. The live
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
sends real datagrams through a real host — goats 4), `node tools/goat_logic_test.js`
at ALL PASS (120, including the seed, pose-cadence and peer checks), `cargo fmt
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
device rate; `cargo test --workspace`, `cargo fmt --all -- --check` and `cargo
clippy --workspace --all-targets -- -D warnings` clean. `GOATS_VOICE_LOOPBACK=1`
plays the microphone back through the whole chain on one machine, which is how
the chain is checked without a peer; the two-client listen still needs a run on
two machines with microphones.

### M13c — Voice polish

Jitter buffer and Opus PLC for loss, per-peer mute/volume, distance attenuation
(positions are already exchanged, so it is nearly free), and a talking indicator
on the roster. Uplink is the limit: full mesh is ~24–32 kbps upstream *per peer*,
so it suits ≤4 players; beyond that the host should mix and relay.

---

## Cross-cutting work

- **Splitting the scene.** ✅ **Done.** The scene is
  `crates/goats/src/game/*.js` in thirteen parts (core, model, world, lighting,
  sky, audio, weather, food, bots, goat, ctl, menu, console), joined in the order
  listed in `crates/goats/src/main.rs`. The host concatenates them and evaluates
  the result as one script, so every part shares a single top-level scope and the
  engine still needs no module system; the headless harness parses the same list
  out of the same file.
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
  - Extend `tools/goat_logic_test.js` with a simulated clock: assert energy
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

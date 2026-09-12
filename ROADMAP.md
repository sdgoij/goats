# Roadmap & Wishlist

Planned work for the goat sandbox, roughly in dependency order. This is the
wishlist plus the technical path for each item; milestones are checked off as
they land.

Guiding principles:

- **Gameplay lives in JavaScript.** The scene, rules and stats stay in `src/game/`;
  engine work is limited to small, generic additions like a few 3D primitives and
  shader plumbing.
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

Shipped in the scene (`src/game/`):

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

Shipped in the scene (`src/game/`):

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
- **Atmosphere.** The gradient gained a forward-scattered glow that widens as the
  sun approaches the horizon, the sun/moon disc, and a horizon haze band.

Cost is step-count bound, so it is a setting: **Clouds — Low / Medium / High**
(6 / 12 / 22 march steps). At 2560x1440 release sits at the 60 fps cap on Low
and Medium; High read ~55, which is inside run-to-run noise (the billboard
fallback read 55 in the same run), so the knob is there for weaker GPUs rather
than for the default.

Verified numerically rather than by eye: the shader compiles, the harness asserts
the march is what gets installed, and frame statistics show overcast flatter
than broken cloud (luma sd 0.090 vs 0.121), dusk dim with a still-lit sky band,
and night dark with no glow. Whether it *looks* right is an eyeball call.

**Still a stretch:** true radiative transfer (raymarching the atmosphere proper,
multiple scattering) and temporal reprojection to buy back step count.

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

## Cross-cutting work

- **Splitting the scene.** ✅ **Done.** The scene is `src/game/*.js` in nine
  parts (core, model, world, lighting, sky, audio, weather, bots, goat), joined in the
  order listed in `src/main.rs`. The host concatenates them and evaluates the
  result as one script, so every part shares a single top-level scope and the
  engine still needs no module system; the headless harness parses the same list
  out of `src/main.rs`.
- **Persistence.** Saving stats and time of day would make death and long
  sessions meaningful. Needs a small host-side file API or an in-memory
  restart-only model.
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
6. ~~**Scene splitting?**~~ **Settled:** nine files in `src/game/`, joined in
   the order listed in `src/main.rs`.
7. ~~**Shadow scope:**~~ **Done:** the goat *and* the grass inside the shadow
   box cast into the depth pass. Tufts outside the box are culled (their shadow
   could not be sampled anyway). Props would follow the same path if added. One
   1024² cascade is still enough while the world stays a single goat-sized field;
   a larger world would want cascades or a bigger map.

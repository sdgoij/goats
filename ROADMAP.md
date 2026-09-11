# Roadmap & Wishlist

Planned work for the goat sandbox, roughly in dependency order. This is the
wishlist plus the technical path for each item; milestones are checked off as
they land.

Guiding principles:

- **Gameplay lives in JavaScript.** The scene, rules and stats stay in `goat.js`;
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
| X-eyes / closed eyes | ✅ approx | a second model drawn only in that state |
| Weather and night ambience audio | ✅ | `loadSound` / `playSound` / `setSoundVolume` |
| Real directional lighting | ❌ | needs shaders (raylib core has no light system) |
| Cast shadows (shadow map) | ❌ | needs shaders **and** render textures |
| Camera-facing billboards | ✅ | `drawBillboard` / `drawBillboardRec` (M0) |
| 3D rain drops / splashes | ✅ | `drawLine3D` / `drawPoint3D` (M0) |
| Read a bone's world transform | ✅ | `modelBonePosition` / `modelBoneTransform` (M0) |
| Photoreal / volumetric clouds | ❌ | needs shaders; a genuine stretch |

The practical consequence: **stats, sleep and death need no engine work at all**,
and day/night plus a first pass of weather need only the M0 primitives. With M0
landed upstream, the only remaining engine work is shaders: real lighting, cast
shadows and the photoreal cloud shader.

---

## Milestones

| # | Milestone | Depends on | Size | Why this order |
| --- | --- | --- | --- | --- |
| **M0** | Engine primitives: 3D shapes, billboards | — | S–M | ✅ **Done** — landed upstream |
| **M1** | Stats, `sleeping`, `dead` states | — | M | ✅ **Done** |
| **M2** | Day/night cycle (approximate lighting) | M0 (sun/moon) | M | ✅ **Done** |
| **M3** | Weather phase 1: clouds, 2D rain, wind, audio | M0 | M | ✅ **Done** (audio deferred to M3b) |
| **M4** | Shaders: real lighting + cast shadows | M0 | L | Biggest engine lift; changes how everything renders |
| **M5** | Weather phase 2: shader clouds (photoreal stretch) | M4 | L | Only sensible once shaders exist |

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
clip, a `GoatDeath` collapse that holds its final pose, and the eye sprites —
closed-eye and X-eye billboards placed at eye points baked from the rig, rather
than the second-model approach originally sketched below. The dead state offers
`R` to restart.

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

Eyes closed: the current rig has no eyelids, so the cheap route is a second
small model (`goat_eyes_closed.glb`) skinned to the head bone and drawn only
while sleeping; the thorough route is to model eyelids and add an eyelid bone.
Recommend the second model now, eyelids if the look isn't convincing.

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

"X eyes": the goofy crossed-out eyes. Options, cheapest first:

1. **Second model, skinned to the head bone** (`goat_eyes_x.glb`) that is only
   drawn in the dead pose. No new bindings; the same `updateModelAnimation`
   frame keeps it glued to the head. **Recommended.**
2. Bake the X geometry into the main mesh on a separate material and hide/show
   it — needs material visibility, i.e. shaders. Defer.
3. Draw two `drawLine3D` Xs per eye from `modelBonePosition(head)` — tiny code,
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

Goal: believable clouds, rain and wind. Audio is the remaining piece (M3b).

Shipped in `goat.js`:

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
wind angle; grass sways with gusts. Not yet met: audio (needs generated sound
assets). Verified code-side via `tools/goat_logic_test.js` (clock, weather text
and `C` are covered); visual look is **not** machine-verified.

### M3b — Weather audio (remaining)

Looping wind and rain beds (`loadSound` + `playSound` + `setSoundVolume`), volume
and pitch tied to intensity, optional thunder. Bindings already exist; what is
missing is the sound assets to embed.

---

## M4 — Real lighting and shadows (shaders)

The big one. raylib's core has no light system, so this means shipping a small
lit shader and the plumbing to drive it.

New bindings:

| Binding | Purpose |
| --- | --- |
| `loadShaderFromMemory` | compile the project's GLSL |
| `getShaderLocation` | cache uniform locations |
| `beginShaderMode` / `endShaderMode` | bind the lit shader around `drawModelEx` |
| `setShaderValue` / `setShaderValueVector3` / `setShaderValueVector4` | per-frame uniforms (light direction, colour, time) |
| `loadRenderTexture`, `beginTextureMode`, `endTextureMode` | shadow map pass |

Work:

- A directional sun/moon light (position, colour, intensity) driven by M2's clock.
- Ambient + hemispheric term so night isn't pitch black.
- A shadow-map pass from the light's point of view, sampled in the lit shader,
  with a PCF blur for soft edges.
- Terrain, goat and any props all draw through the lit shader; switch the blob
  shadow off once cast shadows land.

Risks: shadow acne/bias tuning, CPU-skinned models with custom shaders (the
bone matrices must be passed through), and keeping the trimmed raylib feature
set workable.

Acceptance: the goat and terrain are lit by the sun/moon and cast soft shadows
that track the day/night cycle.

---

## M5 — Weather phase 2: photorealistic clouds

Stretch goal. Replace the cloud-texture dome with a sky shader: noise-based
cloud coverage animated over time, lit by the M4 sun so clouds pick up dawn and
dusk colours, with a parallax layer for the horizon.

This is where "photorealistic" gets genuinely hard — true volumetrics would mean
raymarching a participating medium, which is a large performance and complexity
jump. Recommend treating this as an experimental branch and deciding on the
look before committing to it. A good-looking 2.5D sky shader is the realistic
target; raymarched volumetrics are a research stretch.

---

## Cross-cutting work

- **Splitting the scene.** `goat.js` is already 565 lines and this roadmap
  roughly triples it. Recommended: split into a few files (`world`, `goat`,
  `weather`, `stats`, `hud`) evaluated in order by the host, unless and until
  the engine grows a module system. Worth deciding early.
- **Persistence.** Saving stats and time of day would make death and long
  sessions meaningful. Needs a small host-side file API or an in-memory
  restart-only model.
- **Audio.** Weather beds, a bleat on jump/death, an ambient night layer.
  Bindings already exist.
- **HUD.** Bars, clock, weather icon, a death screen. `drawRectangle`/`drawText`
  plus `drawTextEx` and `drawRectangleGradientV` from M0.
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

1. **How photorealistic?** A 2.5D sky shader is achievable; raymarched
   volumetric clouds are a much larger project. Where do we stop?
2. **Eyelids:** model real eyelids (and a lid bone), or just swap in a
   closed-eye model?
3. **Death:** is it permanent for the run, or a respawn at the last safe spot?
   Save the session or not?
4. **Does weather affect gameplay** (rain slows the goat, cold at night drains
   energy), or is it purely cosmetic at first?
5. **Weather determinism:** seeded so a run is reproducible for tests, or fully
   random?
6. **Scene splitting:** how many files, and does the host evaluate a list of
   scripts in order?
7. **Shadow scope:** only the goat and terrain, or everything including grass?

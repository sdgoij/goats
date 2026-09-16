# Frame-cost profile — Slag Goat on Slag

Where a frame's time actually goes, measured in the running client, and what that
says about optimising the engine. Two engine revisions were compared because the
game lost ~7 fps when it moved to the second one; §6 shows that the loss was the
build rather than the revision, which is itself the most actionable finding here.

## 0. TL;DR

- **The frame is CPU-bound in the scene, not GPU-bound.** The buffer swap
  (`boundary`) costs 0.07–0.08 ms. There is no hidden GPU wait to find.
- **The biggest single cost is the herd: 5.4 ms/frame for 7 goats.** It is
  per-bot CPU skinning (`updateModelAnimation` deforms the mesh) plus one model
  draw per bot. No other phase is close.
- **The grass field is second: 4.2 ms** for ~370 immediate-mode cube draws per
  frame (plus 0.9 ms more in the shadow pass, which draws the same grass again).
- **Mods cost ~2.0 ms/frame** of that budget (`mods_upd` + `mods_draw3d`) with
  four mods loaded.
- **Engine `8a4209fa` is not shown to be slower.** It measured 17% slower, and
  then the *same source* — verified byte-identical — measured as fast as the old
  engine, depending only on how cargo built it. See §6.
- **A ±20% build-to-build spread is larger than anything else found here**, and it
  lives in the engine's compiled code: the pure-JS interpreter loop is identical
  between those two binaries, while every path that enters native code is 13–29%
  slower in the slow one. **`codegen-units = 1` + `lto = "thin"` removes it** and
  lands on the fast side, for ~7× the build time (§6).
- **The lever for the engine is the crossing itself.** A frame here is thousands
  of `rl.*` reads and calls, each of which measures in the microseconds. That is
  what to attack — and it is 2–3× bigger than the build spread, so it shows through
  either way.

## 1. What was measured, and how

| | |
| --- | --- |
| Binary | `cargo build --release -p goats`, the real client (window, vsync, audio) |
| Scene | the game as it stands, 7 bots, 4 mods, default settings, lit shader + shadow map on |
| Run | ~90 s each: load, `perf probe` ×3 after warm-up, `perf on`, 60–70 s of frames |
| Machine | one Windows box, same shell, same protocol for every run |
| Weather | offline and seeded, so the runs follow the same weather timeline and the windows line up |
| Resolution | per phase, ms/frame, averaged over 240-frame windows |

Engine revisions compared:

| revision | what it is |
| --- | --- |
| `2dba2c5e` | what `main` pinned before this work ("move the engine to 2dba2c5e") |
| `8a4209fa` | `feat(raylib): complete the rl surface's blending, textures and images` — the commit M19 needs (M19a), and the one the drop arrived with |

A third configuration was used to isolate the engine from the scene: the M19
scene code on the **old** engine. That runs at the old engine's speed, so the
scene-side changes are not the cause.

| configuration | fps |
| --- | --- |
| `main` (old engine `2dba2c5e`, git dep, no M19) | 56–62 |
| M19 scene, old engine, git dep | 55–61 |
| M19 scene, old engine, **path** dep | 55–60 |
| M19 scene, new engine `8a4209f`, **path** dep | 52–60 |
| M19 scene, new engine `8a4209f`, git dep | 45–49 |
| M19 scene, new engine, git dep, `tune explosions.enabled 0` | 46–54 |

## 2. Instrumentation

A `perf` verb was added to the console (this is a benchmark, not a feature):

```text
perf on          log the phase breakdown every 240 frames
perf             print the breakdown now and reset the window
perf probe       run the micro-probe: 4 loops of 20 000 iterations each
```

The phase marks live in `sceneFrame` (`crates/goats/src/game/goat.js`), in
`renderShadowMap` (`lighting.js`) and in the grass loop (`weather.js`); the block
itself is at the end of `goat.js`. Each mark is two `rl.getTime()` calls, so
turning the probe off leaves one boolean test per mark.

Two things to read the numbers with:

- **A phase time is submission plus whatever is synchronous inside the call.**
  The frame is vsynced, so a healthy frame is quantised to 16.7 ms; the
  breakdown decomposes the *budget*, and `boundary` is where the leftover waits.
- **`boundary` being 0.07 ms is the headline fact about the renderer**: the GPU
  keeps up, and the frame is long because our own CPU work is.

## 3. The frame, phase by phase

Representative steady-state window (n=240), ms/frame. Both columns are cargo
**git-dependency** builds — read §6 before reading them as a comparison of
revisions: the same source built as a path dependency lands on the *old*
column's numbers.

| phase | old `2dba2c5e` | new `8a4209fa` | Δ |
| --- | ---: | ---: | ---: |
| food (nearest tuft, each frame) | 0.08 | 0.10 | +0.02 |
| weather (state machine + wind) | 0.17 | 0.23 | +0.06 |
| clouds_upd (volumetric cloud state) | 0.99 | 1.27 | **+0.28** |
| audio | 0.19 | 0.22 | +0.03 |
| food_upd | 0.09 | 0.12 | +0.03 |
| fx_upd (mines + effects) | 0.18 | 0.22 | +0.04 |
| light (ambient + light + shadow state) | 0.20 | 0.23 | +0.03 |
| input (keys, mouse, camera) | 0.16 | 0.23 | +0.07 |
| goat_sim (gait state machine + movement) | 0.35 | 0.50 | **+0.15** |
| goat_pose (player skinning) | 0.78 | 0.80 | +0.02 |
| bots_ai (7 bots) | 0.20 | 0.28 | +0.08 |
| collide (goat vs herd, 2 passes) | 0.60 | 0.80 | **+0.20** |
| mods_upd (mod `update` hooks) | 0.85 | 1.00 | **+0.15** |
| *update subtotal* | *4.93* | *6.11* | *+1.18* |
| sky2d (sky shader or gradient) | 0.23 | 0.32 | +0.09 |
| shadow_grass (grass in the shadow pass) | 0.64 | 0.87 | **+0.23** |
| shadow_goat | 0.05 | 0.07 | +0.02 |
| shadow_bots (7 bots in the shadow pass) | 0.85 | 0.90 | +0.05 |
| stars | 0.07 | 0.10 | +0.03 |
| **tufts (grass, main pass)** | **3.48** | **4.16** | **+0.68** |
| goat (model + eyes) | 0.04 | 0.05 | +0.01 |
| **bots (7 skinned models)** | **5.37** | **5.38** | +0.01 |
| mods_draw3d (mod `draw3d` hooks) | 0.81 | 1.13 | **+0.32** |
| endmode3d | 0.08 | 0.09 | +0.01 |
| hud / mods_hud / ui | 0.32 | 0.40 | +0.08 |
| *draw subtotal* | *12.34* | *13.95* | *+1.60* |
| boundary (buffer swap) | 0.07 | 0.08 | +0.01 |
| **total** | **17.3** | **20.1** | **+2.8** |
| fps | 55–58 | 46–51 | −7 |

Phase times not listed individually (`rain_upd`, `rain2d`, `terrain`, `goat`,
`peers`, `fx`, `clouds`, `mod2d`, `shadow_tail`) are each ≤0.17 ms and weather-
dependent: `rain_upd` and `rain2d` rise to ~1.6 and ~1.0 ms while it rains.

Measured draw volume: **368–380 cube draws per frame** (grass, main and shadow
passes together).

## 4. The engine crossing (micro-probe)

Four loops, 20 000 iterations each, in one function, three consecutive probes
after the JIT has settled. Nanoseconds per iteration *as reported by the probe*.

| loop | old | new | Δ |
| --- | --- | --- | --- |
| `sink += i * 3` (nothing native) | 648 / 769 / 699 | 676 / 676 / 647 | **unchanged** |
| `sink += rl.getFPS()` (a native call) | 3131 / 3138 / 3184 | 3604 / 4141 / 3419 | **+12…+31%** |
| `sink += rl.WHITE` (a property read) | 5639 / 5553 / 5603 | 7713 / 6151 / 6935 | **+10…+37%** |
| `sink += Math.sin(i)` | 3244 / 3192 / 3226 | 3942 / 3679 / 4339 | **+14…+34%** |

**Read the rows relatively, not absolutely.** The arithmetic loop reports ~0.7 µs
per iteration, which no JIT'd loop would; the whole probe function contains
native calls, so it is executed by the interpreter and the absolute numbers
carry that overhead. What survives the caveat is the comparison:

- The **pure-JS floor is identical** on both revisions (0.65–0.77 µs).
- Everything that **touches the engine** — a call, a property read, even
  `Math.sin` — got **10–40% slower**, subtracting the floor: a crossing went from
  ~2.4 µs to ~2.9–3.4 µs, and a property read from ~4.9 µs to ~5.5–7.0 µs.
- A property read on `rl` measuring *more* than a call suggests those constants
  are not plain data. If they are native accessors, every `rl.KEY_W`-style read
  in the scene is a crossing.

## 5. Where our usage spends the frame

Top items, the slow git build of §3 beside the profile this repo now ships (§6):

| # | item | slow build | shipped | what it is |
| --- | --- | ---: | ---: | --- |
| 1 | `bots` | 5.38 | 5.37 | 7 bots: pose (CPU skinning) + model draw each |
| 2 | `tufts` | 4.16 | 2.77 | the grass field, ~370 immediate-mode cubes/frame |
| 3 | `clouds_upd` | 1.27 | 0.75 | volumetric cloud *state*, in JS, every frame |
| 4 | `mods_upd` | 1.00 | 0.72 | mods' `update` hooks |
| 5 | `mods_draw3d` | 1.13 | 0.68 | mods' `draw3d` hooks (the flock is the big one) |
| 6 | `shadow_bots` | 0.90 | 0.09–2.3 | the herd again, in the shadow pass (very variable) |
| 7 | `goat_pose` | 0.80 | 0.78 | the player's own CPU skinning |
| 8 | `collide` | 0.80 | 0.49 | goat-vs-herd resolution, two passes |
| 9 | `shadow_grass` | 0.87 | 0.49 | the grass again, in the shadow pass |
| 10 | `goat_sim` | 0.50 | 0.28 | gait state machine + movement |
| | *everything else* | ~2.0 | ~1.3 | weather, audio, food, input, hud, sky, stars, fx, terrain |

The order is the same either way; only the scale moves — except `bots`, which does
not move at all. That is the shape of the remaining work: one item is real per-call
work (CPU skinning of the herd) and everything else is the price of crossing into
the engine.

Two things stand out for the near term:

- **The grass is paid for twice.** `tufts` (4.16) + `shadow_grass` (0.87) = 5.0 ms
  for one visual idea, and 5.4 ms for the herd is the same order again.
- **Mods cost 2.0 ms/frame** with four mods, which is more than the shadow pass
  and more than the cloud state. Worth attributing per mod before adding more.

`shadow_bots` is worth a separate look: it ranged from 0.14 to 2.40 ms across
windows in the same run, which is a 17× spread on what should be a constant
amount of work.

## 6. The `8a4209f` "regression" is a build artifact

The first conclusion drawn from §3 was that engine `8a4209f` costs 17% of the
frame. **That does not survive checking.**

The commit touches exactly one code file, `crates/runtime/src/raylib.rs`
(+600/−68); no `Cargo.toml`, no new dependency. Its source is byte-identical to
what cargo's git checkout holds for the same revision — `diff -rq
--strip-trailing-cr` over the whole `crates/` tree reports no difference — so the
only source difference between the two builds is line endings (the git checkout
is LF, a Windows checkout is CRLF).

Building that one source two ways, and alternating the two binaries in a single
session:

| binary (both built from `8a4209f`) | `tufts` | `mods_draw3d` | fps |
| --- | ---: | ---: | ---: |
| cargo **path** dependency | 3.47–3.49 | 0.82–0.84 | 52–55 |
| cargo **git** dependency | 4.48–4.81 | 1.07–1.15 | 45–49 |
| *path again* | 3.48–3.49 | 0.83 | 52–55 |
| *git again* | 4.48–4.81 | 1.07–1.10 | 45–49 |

The micro-probe on those two binaries:

| loop | path build | git build | Δ |
| --- | ---: | ---: | ---: |
| `sink += i * 3` (nothing native) | 654–795 | 611–718 | **unchanged** |
| `sink += rl.getFPS()` | 3154–3167 | 3532–3881 | +13…+23% |
| `sink += rl.WHITE` | 5495–5632 | 6626–6982 | +18…+27% |
| `sink += Math.sin(i)` | 3188–3353 | 4039–4107 | +22…+29% |

And the full matrix for the engine revisions:

| engine source | dependency kind | fps | `tufts` |
| --- | --- | ---: | ---: |
| `2dba2c5e` (old) | git | 55–61 | 3.48 |
| `2dba2c5e` (old) | path | 55–60 | 3.52 |
| `8a4209f` (new) | path | 52–60 | 3.46–3.49 |
| `8a4209f` (new) | git | 45–49 | 4.48–4.81 |

What this says:

- The slow binary is **not** explained by its source: the same source built the
  other way is as fast as the old engine.
- Being a git dependency is **not** the cause either: the *old* source built as a
  git dependency is fast.
- The difference is in what the source was **compiled into**, not in what it does:
  the pure-JS interpreter loop is identical in both binaries, while every path
  that enters native code is 13–29% slower.
- Three of four builds are fast, which is what an unlucky code layout looks like,
  and there is a known mechanism for it: cargo passes a crate hash
  (`-C metadata`) that includes the package's **source id**, and that hash feeds
  codegen-unit partitioning. At the default `codegen-units = 16`, the same source
  is therefore split into different units, inlined differently and laid out
  differently. The two binaries differ by 1,536 bytes — the size of a few embedded
  path strings at these path lengths.

So the earlier attribution is withdrawn: `8a4209f` is not shown to be slower. The
honest statement is that **this engine currently has a build-to-build spread on
native dispatch that is larger than any source change we can measure** — which is
worth acting on in its own right, because it makes a real regression and an
unlucky build indistinguishable from the outside.

Two observations from trying to pin it:

- Adding an inert item to the engine (`fn layout_pad_a() -> u64`) did **not** move
  the fast build (57–60 fps). The sensitivity is real but not triggered by every
  change, which is exactly what makes it hard to control from outside.
- The one build that is consistently slow is reproducible: rebuilding the git
  dependency reproduces 45–49 fps and `tufts ≈ 4.0–4.8`, so it is not noise
  between runs — it is that binary.

### The experiment, run

Adding `codegen-units = 1` to `[profile.release]` and rebuilding the *same* source
(git dependency, `8a4209f`) recovers the whole spread:

| | slow build (16 CGUs) | fast build (path dep) | `codegen-units = 1` |
| --- | ---: | ---: | ---: |
| fps | 45–49 | 52–60 | **51–56** |
| `tufts` | 4.01–4.81 | 3.46–3.49 | **3.49–3.54** |
| `collide` | 0.80 | 0.60 | **0.59–0.60** |
| `goat_sim` | 0.50 | 0.34 | **0.34–0.35** |
| `clouds_upd` | 1.20–1.28 | 0.99 | **0.95–0.96** |
| `mods_draw3d` | 1.07–1.20 | 0.81 | **0.87–0.89** |
| probe `rl.getFPS()` | 3532–3881 | 3154–3167 | **3113–3161** |
| probe `rl.WHITE` | 6626–6982 | 5495–5632 | **5447–5592** |
| probe `Math.sin(i)` | 4039–4107 | 3188–3353 | **3013–3267** |
| probe `i * 3` | 611–718 | 654–795 | **662–714** |

So the mechanism is confirmed in effect even if the exact code movement is not
visible: putting the engine in one codegen unit removes the freedom the crate hash
was exploiting, and the build lands on the fast side, reproducibly.

Both LTO modes were then measured against one codegen unit alone:

| | 16 CGUs | 1 CGU | **1 CGU + thin LTO** | 1 CGU + fat LTO |
| --- | ---: | ---: | ---: | ---: |
| fps | 45–49 | 51–56 | **55–62** | 57–61 |
| `tufts` | 4.01–4.81 | 3.49–3.54 | **2.77–2.82** | 2.85–2.92 |
| `collide` | 0.80 | 0.59–0.60 | **0.49–0.51** | 0.51–0.53 |
| `goat_sim` | 0.50 | 0.34–0.35 | **0.27–0.29** | 0.29–0.30 |
| `clouds_upd` | 1.20–1.28 | 0.95–0.96 | **0.75–0.77** | 0.76–0.82 |
| `bots` | 5.36–5.40 | 5.45–5.48 | **5.37–5.45** | 5.52–5.66 |
| `boundary` | 0.08 | 0.22 | **0.07–0.15** | 0.19–0.81 |
| build | ~30 s | 2 m 35 s | **3 m 27 s** | 6 m 22 s |

The frame lands at ~16.3 ms either way, so the two LTO modes are a tie on frame
time. Thin is kept because its phases are consistently a little lower, it does not
regress `bots`, and it builds in half the time. Note `boundary` in the fat build:
at 0.19–0.81 ms the frame has come close enough to the 16.7 ms budget that the
swap starts absorbing the slack — a different problem from the one this document
opened with.

The profile removes the *disqualifying* spread (the 13–29% one); it does not make
the measurement perfectly stable. Re-measuring the thin build later gave `bots`
6.04–6.09 with `boundary` 0.41–1.08 and 59–63 fps — one phase still varies by
~12% between builds, but the frame is now at the vsync cap, so it no longer shows
in the frame rate.

One thing that did **not** move in any of the four builds: `bots` (5.36–5.66
throughout). The herd's cost is inside `updateModelAnimation` and `drawModelEx` —
real work per call, not crossing overhead — so no build flag can touch it. At
5.4 ms of a 16.3 ms frame it is now the whole game.

## 6b. What survives from the original attribution

Everything in §3–§5: the phase profile is of a *binary*, not of a source change,
and it was measured on a build whose input was unchanged between the phases. The
per-phase shape (herd 5.4 ms, grass 4.2 ms, mods 2.0 ms, shadow pass ~1.9 ms) is
unchanged, and `boundary ≈ 0.08 ms` is unaffected.

What does not survive is the claim that the *engine commit* is the cause. The
table in §3 should be read as "this build is faster than that build", not as
"this revision is faster than that revision".

## 7. Recommendations

### 7.1 Engine

0. **Keep the release profile as it is: `codegen-units = 1` + `lto = "thin"`**
   (§6). Together they recovered the whole build spread and then some: the same
   engine source and the same scene went from 45–49 fps to 55–62, with every phase
   improving except the herd's own work. Cost: ~3 m 27 s per release build.
   `lto = "fat"` is a tie on frame time and twice the build.
1. **Attack the per-crossing cost.** A frame here is thousands of `rl.*` reads
   and calls, and the probe puts a crossing in the microseconds. Every phase in
   the table is bounded by it. Concrete things to check: whether each call builds
   an arguments array or formats anything on the success path; whether the texture
   registry's `Mutex` is taken per draw; whether `rl`'s constants are plain data
   (they are registered with `create_data_property`, so that one is likely fine).
3. **GPU skinning.** CPU skinning is what makes the herd cost 5.4 ms and what
   forces one model per goat (`updateModelAnimation` deforms the mesh itself, so
   two goats cannot share one). Bone matrices as uniforms would collapse both the
   cost and the memory.
4. **A batched immediate-mode path.** ~370 `drawCube` crossings per frame for the
   grass; anything that lets the scene submit N quads in one crossing (or a mesh
   it can rebuild) removes them.

### 7.2 Scene

1. **Draw the grass once.** Build the visible field as a mesh instead of ~370
   immediate-mode cubes, and/or cut the shadow pass's grass (`shadow_grass`,
   0.87 ms, draws the same grass the main pass already drew).
2. **Attribute the mods.** 2.0 ms/frame for four mods; measure per mod and per
   hook before adding a fifth.
3. **`clouds_upd` is 1.27 ms of JS state per frame** while the cloud *marching*
   lives in the shader. Worth checking whether the update can run at a lower rate
   or be amortised.
4. **`collide` (0.80 ms)** and **`mods_upd` (1.00 ms)** are unglamorous but real;
   both are pure JS and cheap to shave.
5. Keep the herd honest: `bots_ai` is 0.28 ms while `bots` (pose + draw) is
   5.38 ms. The AI is not the problem; the rendering of it is.

## 8. Caveats

- One machine, one scene, one spot in the meadow, vsync on. The numbers are a
  CPU-budget decomposition, not a GPU profile.
- Phase times are the scene's own view: submission plus synchronous work. GPU
  time would appear in `boundary`, and `boundary` is 0.07 ms.
- Weather-dependent phases (`rain_upd`, `rain2d`, cloud state) vary by design;
  the windows quoted here are dry ones, and the runs are seeded so they line up.
- The micro-probe's absolute magnitudes include interpreter overhead (§4); use
  it for the comparison, not the absolute cost of a call.
- **The engine comparison in §3/§6 is between builds, not between revisions.**
  The same source built two ways differs by 13–29% on native dispatch; treat any
  single-revision comparison as provisional until the build is stabilised.
- `perf on` itself costs two `rl.getTime()` calls per mark (~36 marks/frame);
  it is a measurement overhead of the same order as one crossing per mark.

## Appendix A — raw windows

New engine (`8a4209fa`), `perf on` windows in order (three shown at the start of
the run, then the steady state):

```text
[...] clouds_upd 1.28 collide 0.81 shadow_grass 0.87 tufts 4.20 bots 5.40 mods_draw3d 1.11 cubes/frame 368 fps 48
[...] clouds_upd 1.27 collide 0.80 shadow_grass 0.86 tufts 4.17 bots 5.37 mods_draw3d 1.13 cubes/frame 364 fps 47
[...] clouds_upd 1.20 collide 0.81 shadow_grass 0.89 tufts 4.12 bots 5.43 mods_draw3d 1.12 cubes/frame 371 fps 45
```

Old engine (`2dba2c5e`), same protocol:

```text
[...] clouds_upd 0.99 collide 0.60 shadow_grass 0.63 tufts 3.48 bots 5.37 mods_draw3d 0.81 cubes/frame 369 fps 57
[...] clouds_upd 1.02 collide 0.60 shadow_grass 0.63 tufts 3.47 bots 5.37 mods_draw3d 0.81 cubes/frame 369 fps 57
[...] clouds_upd 0.98 collide 0.59 shadow_grass 0.62 tufts 3.47 bots 5.37 mods_draw3d 0.81 cubes/frame 369 fps 57
```

Probes, three consecutive each:

```text
old  {"callNs":3130.86,"propNs":5639.07,"jsNs":3244.21,"arithNs":648.43,"fps":53}
old  {"callNs":3137.59,"propNs":5552.95,"jsNs":3192.19,"arithNs":768.51,"fps":53}
old  {"callNs":3183.88,"propNs":5603.14,"jsNs":3225.85,"arithNs":698.78,"fps":53}
new  {"callNs":3603.81,"propNs":7713.00,"jsNs":3941.80,"arithNs":675.56,"fps":54}
new  {"callNs":4140.84,"propNs":6151.41,"jsNs":3679.09,"arithNs":676.07,"fps":54}
new  {"callNs":3418.88,"propNs":6934.52,"jsNs":4339.37,"arithNs":646.99,"fps":55}
```

Fps measurements (80 s runs, `frame … fps` log lines):

```text
main, old engine, no M19     56 62 58 58 58 61 62 61 59 59 59 60 61 60 59 59 58
M19 scene, old engine        60 57 61 61 61 61 61 61 60 61 60 61 60 61 59 56 55
M19 scene, new engine        53 50 49 50 50 52 54 53 51 55 56 56 49 48 48 50
```

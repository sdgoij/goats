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
  draw per bot. No other phase is close. *(0.5 ms once the client ran on a
  `gpu-skinning` build — §7b.)*
- **The grass is second: ~2.0 ms/frame** (1.76 visible + 0.28 in the shadow pass,
  down from 5.0) for ~370 immediate-mode cube draws — and the shadow pass draws the
  same grass again.
- **Mods cost ~0.9 ms/frame** (`mods_upd` + `mods_draw3d`) with four mods loaded,
  down from 2.0.
- **Rain scales with a count the weather sets, and used to be the third cost**: in a
  full downpour `rain_upd` was 0.89–0.95 ms for ~600 drops; it is 0.08–0.09 now. What
  is left of the rain is `rain2d` (0.62), one `drawLine` crossing per drop.
- **Every small phase in the table carries a ~0.03 ms floor** — `perfMark` is two
  engine calls — which is ~1.1 ms of the reported sum across ~36 phases. `peers_upd`,
  `terrain_upd`, `mod2d`, `goat`, `clouds_upd`, `stars` and `food_upd` are essentially
  all floor.
- **Engine `8a4209fa` is not shown to be slower.** It measured 17% slower, and
  then the *same source* — verified byte-identical — measured as fast as the old
  engine, depending only on how cargo built it. See §6.
- **A ±20% build-to-build spread is larger than anything else found here**, and it
  lives in the engine's compiled code: the pure-JS interpreter loop is identical
  between those two binaries, while every path that enters native code is 13–29%
  slower in the slow one. **`codegen-units = 1` + `lto = "thin"` removes it** and
  lands on the fast side, for ~7× the build time (§6).
- **The scene’s cost is per global *read*, and it is a specific kind of read.**
  §4b’s rule (“a body that names a global is not compiled”) is corrected by §4c:
  the scene’s bodies *do* compile, and what they pay is ~63 ns for every read of a
  script-level `const`/`let`/function *name* inside a loop — 25× the same read from
  a local, and 25× a global *object* property like `Math` or `rl` (2.5–7 ns),
  because the engine’s global-value cell only warms for object records (§4c). Inside
  a **mod** the cell is disabled entirely by an unclean env chain, so a global read
  there costs ~2.9 µs — which is why `mods/birds` needed its `Math` members frozen.
- **Removing global reads from four hot bodies recovered 2.1–2.3 ms/frame dry and
  ~0.8 ms more in the rain**: the grass grid 2.88 → 1.76 ms (`shadow_grass` 0.53 →
  0.28–0.36), the goat collision resolve 0.49 → 0.22 ms, the birds mod (0.70 →
  0.47–0.53 update, 0.68 → 0.31–0.37 draw), and the rain drops (0.89–0.95 →
  0.08–0.09 in a held downpour) (§4b, §5b). The arithmetic, the ~1000 draw calls and
  the behaviour of every system are unchanged; only the reads moved.
- **The frame is at vsync, so these wins show up as headroom, not as fps.** The
  sum of the phases went 14.3 → 12.0–12.2 ms dry, and a held downpour still only
  reaches 13.2 ms of a 16.7 ms budget (`boundary`, the swap wait, absorbs the rest);
  fps stayed 59–61 throughout. The budget is what changes; fps only will when the
  *sum* drops under ~16 ms with margin, or on hardware slower than this.
- **The scene side of this is done, and what is left is the engine's interface to
  it.** Every hot loop that could be moved into a parameter-only body has been
  (§5b, “what is left”). The remaining phases are counts of engine crossings — 670
  `drawLine` in rain, ~370 `drawCube` of grass, ~10 key reads a frame — or engine
  cost inside one call. The levers that are left are a batched submission path and a
  batched key read (§7.1).
- **The herd's 5.4 ms was CPU skinning, and it is gone.** With the engine's
  `gpu-skinning` build the scene routes every animated model through a skinned
  shader: `bots` 5.5–5.9 → 0.3–0.8 ms and `goat_pose` 0.79 → 0.04, ~6 ms of a
  16.6 ms budget for 7 goats, with the frame still at vsync (§7b). The grass is now
  the largest phase in the frame, by a wide margin.
- **The lever for the engine is the compile gate, then the crossing.** A frame
  here is also thousands of `rl.*` calls, but the microsecond figures §4 read off
  the probe were mostly the interpreter, not the crossing (§4b): fix the gate and
  the scene's own loops stop paying it.

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

Each logged window carries three frame-time numbers beside the phases, because a
phases' average cannot see a stutter (the engine's safe-point collections are one
long frame each — Appendix B):

```text
worst 701.1          the longest frame in the window, ms
slow 5 slowms 1022.6 frames over 30 ms (a dropped 60 Hz frame), and their total
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

**§4b supersedes the reading above.** `Math.sin` is not slow and `rl.WHITE` is not
an accessor: the *loop* is not compiled, because the function holding it names
`rl` and `Math`. The same loop in a function that names neither runs 60× faster.
The relative result (a native-touching loop got slower between the two builds)
still stands — that is a build effect on the interpreted path as well.

## 4b. What the engine actually compiles

> **Corrected by §4c.** Everything below was measured from `mods/jitprobe`, i.e. from
> inside a **mod**, whose env chain is not clean and which therefore disables the
> engine's global fast cell for every global read. The *rule* it states does not hold
> for the scene; the *measurements* are real and describe mods. Read §4c for the
> corrected, cross-engine picture before acting on anything here.

The `perf probe` loop that started this was the interpreter, not the crossing, and
the rule behind it is narrow enough to state, measure and code around.

`perf probe` reports `pureNs` (added during this work): the identical
`sink += i * 3` loop, in a function of its own with no engine call and no global
in it. Measured on the current binary it reports **9.7–56.6 ns** per iteration
(56.6 on the first probe, ~9.7 once the engine has settled) against **646–707 ns**
for the same loop beside the engine calls — a ~60× gap, which is the interpreter's
own per-step cost (~90–200 ns for the ~4 steps a loop iteration takes).

To find the *rule* rather than guess at it, `mods/jitprobe` (a throwaway
measurement mod, `jitprobe` verb) times one body per shape over 200 000
iterations, warm, after the JIT has been consulted. Nanoseconds per iteration;
four runs, same binary, same order as listed (and note these bodies are inside a
*mod* — see §4c):

| body | ns/iter | verdict |
| --- | ---: | --- |
| `sink += i * 3`, parameters only | 9.2–15.4 | compiled |
| `+` a wrapper-scope `const` | 12.8–20.9 | compiled |
| `+` a two-level member chain on that const | 17.3–28.8 | compiled |
| `+` a call to a wrapper-scope function | 55.6–56.8 | compiled |
| `+` a call to a parameter | 13.6–13.9 | compiled |
| `+` `(i + 1) ** 0.5` | 32.1–35.4 | compiled |
| `+` a `continue` | 24.2–25.5 | compiled |
| `+` an `if`/`else` | 20.8–21.7 | compiled |
| nested loops with member reads *and writes* | 30.6–34.4 | compiled |
| **`+` a true global read (`Math.PI`)** | **2830–2913** | **interpreted** |
| **`+` a global object property read** | **3030–3051** | **interpreted** |
| **`+` a call to a global function** | **3030–3032** | **interpreted** |
| **`+` `Math.sqrt(i)`** | **2829–3286** | **interpreted** |

So the gate is: **a body that names a true global is not compiled.** A global read,
not a global *call*, is enough on its own; note the last four rows are ~100× the
rows above them and that swapping `Math.sqrt(i)` for `(i + 1) ** 0.5` moves a row
from the interpreted group to the compiled one. Calls are fine — including calls
to functions the body does not know statically — and so are member reads and
writes on objects reached through a local, a parameter or a captured binding,
nested loops, `continue`, and declarations inside blocks. The engine does have
`load_ident`/`get_global` slow paths for compiled bodies, so what fails is
certification / leaf eligibility rather than the lowering — which is why this is
worth raising upstream: **the scene is written the way JS is normally written,
and normal JS is exactly what does not compile.**

This is not a fixture-only effect. All three of this session’s frame-level wins
are the rule in the scene:

| change | body | phase (ms/frame) |
| --- | --- | ---: |
| three `Math.imul`, one `Math.sin` and a `terrainHeight()` call moved out of the grass grid into parameters | `tuftField` | `tufts` 2.88 → 1.78, `shadow_grass` 0.53 → 0.36 |
| two `TUNING` reads and a `Math.sqrt` removed from the pair loop | `collidePairs` | `collide` 0.49 → 0.22 |
| every `Math.*` member frozen into a module-scope const (same functions, read as locals) | the birds mod’s step, pose and quaternion helpers | `mods_upd` 0.70 → 0.47–0.53, `mods_draw3d` 0.68 → 0.31–0.37 |
| the wind, the seed and `hash` passed in, the seed returned | `rainFall` | `rain_upd` 0.89–0.95 → 0.08–0.09 in a held downpour (§5b) |

The grass change is the cleanest evidence: the grid walks the same 600 cells, does
the same hash, and issues the same ~380 draws — only the reads moved.

There are two forms of the same fix, and which one applies is a judgement about
the call graph. The grass grid, the collision resolve and the rain drops take
**everything as a parameter** (`out, cellH, eaten, imul, sin, groundY, …`); the birds
mod instead **freezes the members at module scope** and reads them as captured
bindings, which needs no change to a signature anywhere. A module-scope `const` in a
mod lives in the mod wrapper’s scope, and reading it from a nested function is a
context-slot read, not a global one — measured at 13–18 ns/iter in the table above.
Prefer freezing when many small helpers each need the same two or three builtins;
prefer parameters when a leaf body needs one or two. **In the scene, only parameters
work**: a top-level `const` in the concatenated scene script is a global lexical
binding, and reading one costs ~63 ns a read (§4c), which is the same order as the
mod’s problem and just as worth hoisting out of a loop.

A kernel that has to hand back state — the rain’s PRNG seed advances once per
wrapped drop — returns it, since it cannot write the module’s global. And one
counter-example is on the record in §5b: precomputing *into* an array for an
interpreted consumer loses more than it saves.

## 4c. Correction: the scene *does* compile, and the cost is per read

§4b’s rule — “a body that names a true global is not compiled” — is wrong, and the
fixture that produced it could not have shown it: those bodies live inside a **mod**,
whose env chain is not clean, so the JIT disables its global fast cell for every
global read there. That is a real effect of its own (a global read costs ~2.9 µs in
a mod function where a script pays 7 ns for the same read), but it is a *mod* fact.

Re-measured with the engine’s own cross-engine corpus runner (`slag --corpus`, the
same steady-state protocol as node), the picture is per-read rather than per-body:

| workload, 1,000,000 iterations | slag jit | slag jitless | node |
| --- | ---: | ---: | ---: |
| a top-level `const` read in the loop | **63.5 ms** | 96.6 | 0.58 |
| the same value read from a local | **2.5** | 17.2 | 0.59 |
| the same value as `globalThis.K` (object record) | **2.5** | 17.3 | 86.5 |
| the same loop, literal bound (no global read at all) | 1.06 | 10.1 | 0.18 |
| `Math.PI` in the loop body | 2.12 | 16.7 | 25.7 |
| `(i + 1) ** 0.5` / `Math.sqrt(i + 1)` | 5.7 / 8.7 | 15.4 / 20.8 | 0.53 / 25.7 |
| a script-level function called per iteration | 2.33 | 18.7 | 12.6 |
| a parameter-only kernel called 1000× | 11.9 | 69.2 | 0.79 |

The scene is evaluated as a script (`context.eval(SCENE)`), so its chain *is* clean
and its bodies are compiled. What it pays is **~63 ns for every read of a
script-level `const`/`let`/function name inside a compiled loop** — 25× the same
read from a local — because the engine’s global-value cell is only warmed for
global **object-record** properties (`Math`, `rl`, host globals: 2.5–7 ns) and never
for the global **declarative** record, which is what every top-level `const` here
is: `TUNING`, `BOTS`, `CLIP`, `RAIN`, `TUFT_POOL`, `EATEN`, `TERRAIN_CELL_H`, and
every scene function *name*. The engine-side write-up, with the code comment that
gives the soundness reason, is `slag/.notes/global-read-cells.md`; the shapes are now
corpus rows under `tools/corpus/workloads/globals/`.

So §5b’s wins are real and the recipe is unchanged in practice — hoist the reads out
of the loop — but the reason is “~63 ns per declarative read”, not “the body never
compiled”. Two consequences to carry:

- **`** 0.5` for `Math.sqrt` was not the win it looked like in §4b’s table.** `Math`
  is the *cheap* kind of global in a script (2.12 ms vs 1.06 for no read at all),
  and the corpus puts `Math.sqrt` at 30 ns/iter against `** 0.5`’s 20 ns. The
  substitution still matters in a *mod*, where every global read is ~2.9 µs.
- **The magnitudes are not reconciled yet**, and this is now the most valuable open
  question in the profile: `collidePairs` still measures ~3.4 µs per pair-step, ~40×
  the corpus’s compiled kernel, and a single call to a compiled kernel measured
  ~226 µs once per frame against ~9 µs in a burst (§4b). Both point at how a
  compiled body is *reached*, not at whether it compiles.

**Open, and the next thing to chase:** the absolute cost of a *single* call to one
of these kernels does not match its cost in a burst. In the same process, the same
global-free body costs **~9 µs/call** called 2000 times in a row and **~226 µs/call**
called once per frame from the scene’s own update path (or from a console command),
stable across runs, with the measurement floor at ~2.9 µs. `collide`’s 0.22 ms per
frame matches the per-frame figure almost exactly, which suggests the scene’s
kernels are **still interpreted** and that what this session recovered is the cost
of the global reads that were removed rather than interpreter overhead in general.
What makes the per-call cost depend on the calling pattern — an eviction between
calls, the leaf-inline room check, a first-consult path — is the number to explain
in the engine: 226 µs for a body that measures 9 µs in a burst.
<br>(A second, smaller oddity in the same fixture: within one run the *same* body
measured 4147 ns/iter early and 93 ns/iter later, which is the same
pattern-dependence seen from the other side. Treat any single measurement of a
newly-called body as provisional until it is repeated.)

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

## 5b. This session: the compile gate, worked around

Same machine, same protocol, same binary flags — only the bodies named in §4b
changed. A mod change needs no rebuild at all (the client loads `mods/` at
startup), so the birds row is measured in the same binary as the two before it.
All runs are `perf on` windows from a settled client, 7 bots, 4 mods, dry.
ms/frame:

| phase | before | + scene kernels | + birds |
| --- | ---: | ---: | ---: |
| `tufts` | 2.88 | 1.78 | 1.76–1.77 |
| `shadow_grass` | 0.53 | 0.35–0.36 | 0.28–0.36 |
| `collide` | 0.49 | 0.22 | 0.21–0.22 |
| `mods_upd` | 0.69–0.77 | 0.70–0.79 | **0.47–0.53** |
| `mods_draw3d` | 0.68–0.69 | 0.68 | **0.31–0.37** |
| `shadow_tail` | 0.14–0.15 | 0.14 | 0.03–0.13 |
| `endmode3d` | 0.08 | 0.08 | 0.02–0.09 |
| **sum of phases** | **14.31** | **12.78** | **11.99–12.21** |
| `boundary` | 2.22 | 3.55 | 4.24–4.32 |
| frame total | 16.53 | 16.33 | 16.31–16.45 |
| fps | 59 | 60 | 59–60 |

Ranges are run-to-run, and one of them has a known cause: the grass cull follows the
goat, so `tufts`, `shadow_grass` and the two tail spans move with it — the runs
above drew 347–381 cubes/frame. The `mods_*` rows are the ones to read: they are
the flock, they do not depend on where the goat is, and they fell by 0.24 and 0.34
ms/frame.

Two things to read from this. The JS phases fall by 2.1–2.3 ms and `boundary`
(the swap wait) takes exactly that back: the frame was already vsync-limited at
59–60, so the win appears as **headroom** — about a third of the 16.7 ms budget
returned — not as fps. And the phases that did not change are the ones the rule
predicts: `bots` 5.45–5.5 (the herd’s CPU skinning and model draw, inside a single
engine call), `goat_pose` 0.77–0.83 (the same for the player), and the rest of the
scene, which still reads globals.

One earlier attempt in this same phase **did not** pay: replacing the birds’
`update` loop’s four `Number.isFinite` global reads with one call changed
`mods_upd` by nothing measurable. That was the right shape for the wrong body —
the cost was never in the loop, it was in the O(n²) neighbour loop inside
`stepFly` and in the ~10 small helpers each bird calls, every one of which named
`Math` in its own body. Freezing the members (§4b) is what moved it.

### The wet frame, and the rain loop

Rain is the one system whose cost scales with a count the weather sets, so it gets
its own measurement: `weather rain` holds a full downpour (`rain: 1`, ~670 drops)
for as long as the command is re-issued, and `rain2d` — which this session did *not*
change — is the control for how many drops are live.

| phase | before (natural rain, 440–610 drops) | after (held downpour, ~670 drops) |
| --- | ---: | ---: |
| `rain_upd` | 0.89–0.95 | **0.08–0.09** |
| `rain2d` | 0.44–0.61 | 0.62–0.64 |

The update loop is ~10× cheaper and it is handling *more* drops than the run it is
compared with. `rainFall` (`weather.js`) takes the wind, the seed and `hash` as
parameters and returns the advanced seed, so the body stops naming globals; at
0.08 ms for ~670 drops it is ~75 ns a drop, which is machine code (and the phase
floor below is ~0.03 of it).

`rain2d` is where the rain now spends its time: one `rl.drawLine` crossing per drop,
~670 of them. That is not a JS problem — see §7.1.

**One thing that did not work, recorded so it is not retried.** The same split
applied to `drawRain` — hoist the four rounded endpoints into a scratch number pool
in a kernel, then let the interpreted draw loop read them — made the phase **2.4×
worse**: `rain2d` 0.62 → 1.50 ms. Four indexed reads of a shared array cost an
interpreted body more than the arithmetic they replaced (a monomorphic `d.x * w` is
cheaper than `pool[o + 2]` on a 4096-number array). It is reverted, and the comment
in `drawRain` records the numbers. The recipe holds when the *kernel* keeps the work
and the interpreted body gets smaller; it backfires when the interpreted body swaps
arithmetic for indirection.

### The measurement floor

`perfMark` itself costs something, and the M19 work handed us a way to measure it:
`tune explosions.enabled 0` turns the whole explosion system off, and
`updateExplosions` then returns on its first statement.

| `fx_upd` | ms/frame |
| --- | ---: |
| system on | 0.10 |
| `tune explosions.enabled 0` | **0.03** |

A phase that does nothing but be called and marked is **0.03 ms**, and with ~36
phases in the frame that is **~1.1 ms of the reported “sum of phases”** — around 9%
of it. Two consequences for reading the tables above. Small phases are mostly floor:
`peers_upd` 0.02, `terrain_upd` 0.02, `mod2d` 0.03, `goat` 0.04, `clouds_upd` 0.05
and `stars` 0.06 have essentially nothing left to win, and “0.15 ms” for a weather or
lighting phase is ~0.12 ms of work. And the *deltas* are unaffected: both sides of
every comparison carry the same floor.

### What is left in the scene, and why it is not JS work

With the rain loop done, every hot loop in the scene that could be moved into a
parameter-only body has been: the cloud drift, the grass field, the collision
resolve, the rain drops, and — in a mod — the flock. What remains above the floor,
by measured cost:

| phase | ms | what it actually is |
| --- | ---: | --- |
| `goat_sim` | 0.26 | ~10 `rl.isKeyDown` crossings in the gait and state machine |
| `sky2d` | 0.18 | `drawSky`: shader uniform sets |
| `audio` | 0.18 | `rl.updateMusic`/`setMusicVolume` — streaming work inside the engine |
| `hud` | 0.17 | text and rectangle draws |
| `weather` | 0.15 | four small scalar functions, one call each |
| `light` | 0.15 | `updateAmbient`/`updateLight`/`updateShadow` + two `lerpColor` |
| `input` | 0.12 | camera and action key reads |
| `rain2d` | 0.62 in rain | one `drawLine` per drop |
| `goat_pose` + `bots` | 0.8 + 5.5 | CPU skinning and one model draw per goat (0.04 + 0.5 on a `gpu-skinning` build, §7b) |

Every one of those is a count of engine crossings or an engine-side cost, not
arithmetic that can be moved. The lever is submission: a batched line/cube call and
a batched key-state read (§7.1). Optimising the scene further would now
be optimising the engine's interface to it.

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
   `lto = "fat"` is a tie on frame time and twice the build. The iteration profiles
   added later (`dev` and `fast` in the root `Cargo.toml`) drop both settings on
   purpose; no number in this document was taken with either.
1. **Attack the compile gate (§4b) before the crossing.** A body that names a
true global is not compiled at all, and this scene names globals everywhere, so
the interpreter’s ~90–200 ns/step is what most of the frame is actually paying.
The JIT already has the `load_ident`/`get_global` slow paths for it, so the gate
is in certification / leaf eligibility. Whatever is decided there, the number to
beat is measured: 9–35 ns/iter compiled versus ~2900 ns/iter for the same body
with one global read in it. Relaxing it requires no changes to any scene, ours
included.
2. **Then the calling-pattern dependence (§4b).** The same global-free body costs
~9 µs/call in a burst and ~226 µs/call once per frame, in the same process. If a
compiled body can be reached reliably once per frame, the kernels this session
rewrote would go to ~0.01 ms each instead of 0.22 and ~0.9.
3. **A batched immediate-mode path.** The scene’s remaining JSON-side cost is
   almost entirely submission counts: ~670 `rl.drawLine` in a downpour, ~370
   `rl.drawCube` for the grass (twice, with the shadow pass), plus the `hud`
   rectangles and text. Anything that lets the scene submit N primitives in one
   crossing — a line/quad batch, or a mesh it can rebuild — removes most of
   `rain2d`, `tufts`, `shadow_grass` and `hud` at once. The JS round those loops is
   already as small as this engine lets it be (§5b).
4. **A batched key-state read.** `goat_sim` (0.26) and `input` (0.12) are ~10
   `rl.isKeyDown` crossings a frame between them. One call returning the state of
   the keys the scene cares about (or a bitmask) would collapse that to one or two.
5. **GPU skinning. ✅ Landed (§7b).** CPU skinning is what makes the herd cost
   5.5 ms and what forces one model per goat (`updateModelAnimation` deforms the
   mesh itself, so two goats cannot share one). Bone matrices as uniforms collapse
   the first outright -- 5.5 ms becomes 0.5 -- and leave the second as a separate
   step; it was the single largest item left in the frame.
6. **Then the per-crossing cost.** A frame is thousands of `rl.*` reads and calls;
   the two items above remove a large fraction of them by construction, and what is
   left is worth attacking one crossing at a time (argument marshalling, the texture
   registry’s `Mutex`, whether each call allocates).

### 7.2 Scene

1. **Write hot bodies the way the gate wants them (§4b).** Two forms, both in
   use now: **parameters** (`collidePairs`, `tuftField` — the members of `TUNING`
   it needs, the caches it touches, and any builtin it calls are all passed in)
   and **frozen module-scope consts** (`mods/birds`, where `PI`/`SIN`/`COS`/… are
   captured bindings instead of `Math.*`, needing no signature change anywhere).
   Let the caller, which is interpreted anyway, do the global reads and the
   `rl.*` calls. Use `** 0.5` for a square root and `x < 0 ? -x : x` for
   `Math.abs`; both keep a body compiled where the `Math` call would not.
2. ~~The birds mod is the next candidate~~ **done** (§5b): `mods_upd` 0.70 → 0.47–0.53,
   `mods_draw3d` 0.68 → 0.31–0.37. What worked was freezing `Math`’s members; what
   did not was replacing the update loop’s own `Number.isFinite` reads, because the
   cost was never in that loop. `mods/birds` is the template for the rest: the
   helpers are untouched behaviourally, they just stop naming a global.
3. **Draw the grass once.** Build the visible field as a mesh instead of ~370
   immediate-mode cubes, and/or cut the shadow pass's grass (`shadow_grass`,
   0.35 ms after this session, draws the same grass the main pass already drew).
4. **Attribute the mods.** ~0.9 ms/frame for four mods, down from 1.4; measure
   per mod and per hook before adding a fifth.
5. Keep the herd honest: `bots_ai` is 0.16 ms while `bots` (pose + draw) is
   5.5 ms. The AI is not the problem; the rendering of it is, and it is one
   engine call per bot.
6. **This pass is complete.** Every hot loop that could live in a parameter-only
   body now does — the cloud drift, the grass field, the goat collisions, the rain
   drops, and the flock in `mods/birds`. Two things to carry forward: the recipe
   needs the *interpreted* body to get smaller, not to swap arithmetic for
   indirection (the `drawRain` counter-example in §5b cost 2.4×), and in the scene
   only parameters work, because a script-level `const` is a global binding.
   Everything still above the floor is a crossing or an engine cost (§5b), so the
   next move is §7.1, not another scene edit.

### 7b. GPU skinning: the client half, measured

Item 5 above is done. The engine half is a raylib *build* switch (`gpu-skinning` in
`slag`'s feature list, `rl.GPU_SKINNING` to branch on rather than assume, and
`rl.setModelCpuSkinning(model, true)` as the per-model way back for a rig a skinned
program cannot cover). The scene half is each of the three vertex shader families
compiled twice, one routing call per animated model as it loads, and the *plain*
programs kept for the grass and the terrain mesh, which carry no bone data to read
(`slag/.notes/gpu-skinning.md`; the code is `crates/goats/src/game/lighting.js`).

Two release builds of the client differing in that one feature word, the protocol of
§1 (7 bots, 4 mods, `perf on`, 240-frame windows, dry), and the windows compared by
index — the scene's own state makes `bots` drift *within* a run in both builds
(0.39 → 0.83 skinned, 5.61 → 5.90 CPU), so only like-for-like windows are quoted:

| phase | CPU skinning | `gpu-skinning` | Δ |
| --- | ---: | ---: | ---: |
| `bots` (7 goats, lit pass) | 5.49–5.90 | 0.27–0.83 | **−5.2** |
| `goat_pose` (the player) | 0.78–0.80 | 0.04 | **−0.75** |
| `shadow_goat` | 0.10–0.14 | 0.10–0.14 | 0 |
| `shadow_bots` | 0.07–0.18 | 0.02–0.19 | 0 |
| `bots_ai` (the same state machine) | 0.11–0.14 | 0.10–0.14 | 0 |
| `cubes/frame` | 354–367 | 360–367 | 0 |
| fps | 59–60 | 59–60 | 0 |

Three things to read off it:

- **The herd's cost was the deform, not the draw.** `bots` falls 91% while `bots_ai`
  and the drawn volume do not move: what left the frame is
  `updateModelAnimation`'s per-vertex pass over every goat's mesh, which this build
  replaces with a bone-matrix fill.
- **The shadow pass never paid for skinning** — `shadow_bots` does not change either
  way: it draws the pose the lit pass left in the model, which on this path is the
  bone matrices rather than deformed vertices.
- **~6 ms of a 16.6 ms budget, and no fps.** The frame sits at vsync before and
  after (§0), so the win is headroom: it is what lets the *sum* fall further under
  the budget, exactly as the earlier scene-side rounds did.

What it does not fix: the grass (`tufts` + `shadow_grass`, 2.7 + 0.5 ms in these
runs -- this session's grass is above §0's 2.0, in *both* columns, so read those two
together rather than as a delta) is now the largest phase in the frame by a wide
margin, and one model per goat is no longer *required* — one model can serve the whole
herd as long as each instance is updated immediately before it is drawn (the notes'
§3) — though the scene keeps one per bot for now, which on this path only costs the
extra mesh copies and their load time.

The routing rules are pinned by `crates/harness/tests/skinning.rs` (17 checks): the
stub reports `rl.GPU_SKINNING` as a flag, so a case can drive each side of the branch,
and the fallback, without a GL context.

### 7c. The sky as two passes: the celestial bodies behind the clouds

M2b draws the sun and the moon as spheres on the light's own line, and the sky
shader marched its cloud slab *over* them, so a cloud that drifted across the sun
left the sun painted on the cloud. The fix is layering rather than a second march:
the sky shader gained a layer uniform, and the frame draws the air (gradient,
cirrus, glow) first, then the two bodies and the sun's glare, then the clouds alone
-- premultiplied light and the transmittance it leaves, blended
ONE / ONE-MINUS-SRC-ALPHA, which is what "in front of" has to mean for a layer that
attenuates what it covers rather than covering it with sky again. One march, and the
bodies end up under the weather.

The split is what a phase breakdown can see: `sky2d` is now the air pass and
`sky_clouds` the cloud one. Single pass against the split, the same build otherwise,
the protocol of §1 (7 bots, `--no-mods`, `perf on`, 240-frame windows, dry):

| phase | one pass | two passes |
| --- | ---: | ---: |
| `sky2d` (the air, or the whole sky) | 0.33-0.40 | 0.26-0.29 |
| `sky_clouds` (the march) | -- | 0.14-0.15 |
| **sky, together** | **0.33-0.40** | **0.40-0.44** |
| fps | 59-60 | 59-61 |

**~+0.04 ms**: a quarter of a percent of a 16.6 ms frame, and inside the spread the
single pass shows across windows on its own (0.33-0.40), so an fps reading cannot
resolve it either way. The §3 table predates the split -- read its `sky2d` row as the
whole sky.

`crates/harness/tests/celestial.rs` pins what the numbers cannot: which draws land
between the two passes, that the ground lands after them, the premultiplied blend,
and the single-pass fallback, driven by taking the blend mode away from the stub.

## 8. Caveats

- One machine, one scene, one spot in the meadow, vsync on. The numbers are a
  CPU-budget decomposition, not a GPU profile.
- Phase times are the scene's own view: submission plus synchronous work. GPU
  time would appear in `boundary`, and `boundary` is 0.07 ms.
- Weather-dependent phases (`rain_upd`, `rain2d`, cloud state) vary by design;
  the windows quoted here are dry ones, and the runs are seeded so they line up.
- The micro-probe's absolute magnitudes include interpreter overhead (§4); use
  it for the comparison, not the absolute cost of a call. §4b is the reason: the
  probe's own loops are interpreted.
- **Every phase carries a ~0.03 ms measurement floor** (≈1.1 ms of the reported
  sum across ~36 phases), measured with `tune explosions.enabled 0` (§5b). Small
  phases are mostly floor; read the dry table's deltas, not its level.
- **The rain phases only exist when it rains.** `rain_upd` and `rain2d` are 0.02–0.12
  in a dry window and 0.08/0.62 in a held downpour (`weather rain`). Quote the
  weather with any rain number — the natural timeline moves between the two.
- **A kernel’s cost depends on how it is called (§4b).** The same global-free body
  measures ~9 µs/call in a burst and ~226 µs/call once per frame. Any conclusion
  from a single call pattern must be repeated in the other before it is trusted;
  the four-run shape table in §4b was stable, the absolute per-call figure was not.
- The `collide` and `tufts` rewrites were validated with the scene harness
  (`cargo test -p harness --test scene_logic -- --ignored`, 158 checks), which
  asserts the collision invariants and that the grass field is derived rather than
  stored.
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

This session’s stages, `perf on` for 64 s (7 bots, 4 mods), before and after each
rewrite — first and last window of each run, to show the spread:

```text
before  [...] collide 0.50 tufts 2.88 shadow_grass 0.53 bots 5.46 mods_upd 0.72 cubes/frame 381 fps 59
before  [...] collide 0.49 tufts 2.87 shadow_grass 0.53 bots 5.49 mods_upd 0.69 cubes/frame 380 fps 59
after   [...] collide 0.22 tufts 1.78 shadow_grass 0.36 bots 5.48 mods_upd 0.70 cubes/frame 381 fps 60
after   [...] collide 0.22 tufts 1.75 shadow_grass 0.35 bots 5.47 mods_upd 0.79 cubes/frame 375 fps 60
birds   [...] collide 0.22 tufts 1.76 shadow_grass 0.35 bots 5.54 mods_upd 0.51 mods_draw3d 0.37 cubes/frame 372 fps 59
birds   [...] collide 0.22 tufts 1.76 shadow_grass 0.36 bots 5.53 mods_upd 0.53 mods_draw3d 0.36 cubes/frame 366 fps 59
birds2  [...] collide 0.21 tufts 1.77 shadow_grass 0.28 bots 5.45 mods_upd 0.53 mods_draw3d 0.31 cubes/frame 347 fps 60
birds2  [...] collide 0.21 tufts 1.77 shadow_grass 0.28 bots 5.45 mods_upd 0.47 mods_draw3d 0.31 cubes/frame 347 fps 60
```

The held downpour (`weather rain` re-issued every 6 s, so `rain: 1` throughout),
before the rain kernel and after it. The two runs are not the same drop count —
`rain2d` is the control:

```text
before (natural rain)  [...] rain_upd 0.95 rain2d 0.61
before (natural rain)  [...] rain_upd 0.89 rain2d 0.44
after  (held, rain 1)  [...] rain_upd 0.08 rain2d 0.62
after  (held, rain 1)  [...] rain_upd 0.08 rain2d 0.64
rejected precompute    [...] rain_upd 0.08 rain2d 1.50
```

The `birds` runs also sanity-check the flock, since the change was supposed to be
behaviour-neutral: `birds` reported all five flight states in use across the runs
(`{"idle":1,"fly":3,"perch":1,"land":1}` then
`{"fly":2,"takeoff":1,"walk":1,"idle":2}`), with `near`/`far` of 3.5–9.1 and
15.3–23.7 m from whichever anchor the flock had picked — the same ranges as before
the change.

The full shape table from §4b, one run verbatim (`jitprobe` and
`jitprobe-globals` from `mods/jitprobe`, which is a measurement fixture and not
part of the game):

```text
jitprobe N=200000 (10 ns/iter = compiled, 150+ = interpreter)
arith                  9.5 ns/iter
outer-read            13.3 ns/iter
outer-chain           18.1 ns/iter
global-read         2885.3 ns/iter
call-outer            56.3 ns/iter
call-param            13.8 ns/iter
sqrt-global         3286.1 ns/iter
pow-half              35.4 ns/iter
continue              25.5 ns/iter
if-else               21.6 ns/iter
nested-7              34.4 ns/iter
collide-current     4983.3 ns/iter
collide-leaf        4148.3 ns/iter
jitprobe-globals N=200000
outer-fn-call         17.9 ns/iter
global-fn-call      3030.2 ns/iter
global-value        3051.1 ns/iter
```

The next run of the same binary put `arith` at 15.4 and `nested-7` at 31.2 — the
ranges in §4b are the envelope of four runs, and the *grouping* was identical in
all four.

## Appendix B — the collector's share (a baseline for the GC work)

The engine collects at loop back edges: a backward `Step::Jump` and the fused
`FastLoopHead` (`runtime/src/ir.rs`), and `gc_safepoint` in compiled loops
(`jit/src/jit.rs`), each call `Agent::maybe_collect` once the allocation budget is
crossed (`crux/src/heap.rs`, `ALLOC_BUDGET = 1024`); `agent.rs` collects when the
live heap has doubled since the last one, and the collection itself
(`agent.rs::collect_garbage` → `Heap::collect_with_stack`) is a stop-the-world
mark-sweep with a conservative native-stack scan. A generational nursery is being
built for that; this is the baseline it should be measured against, and the protocol
to re-measure it with.

**Why the phase table cannot see it.** A collection is one long frame, so it is
1/240th of a window's average, and it lands in whichever phase the loop was in —
this session saw the same stall attributed to `mods_upd` (144 ms), `hud` (169),
`sky2d` (54) and `boundary` (653). Hence `worst`/`slow`/`slowms` (§2).

**Protocol.** The release client, mods on (7 bots, five mods), `setting fullscreen
off`, `perf on`, 240-frame windows. Eight forced chains four seconds apart, so
craters, effects and flung goats accumulate, then 26 s quiet:

```text
( echo "setting fullscreen off"; sleep 8; echo "perf on"; sleep 16;
  echo "fatguy boom mine"; sleep 4;      # ×8, four seconds apart
  sleep 26 ) | ./target/release/goats.exe
```

**Baseline, two runs of that protocol** (~72 s of `perf on` each, on a machine that
was also running an engine build):

| run | windows | `slow` | `slowms` | `worst` |
| --- | --- | --- | --- | --- |
| 1 | 18 | 81 | 5880 ms | 701 ms |
| 2 | 20 | 38 | 2380 ms | 363 ms |

Read that spread as the floor of what this machine can resolve: 2.4–5.9 s of stalled
time in 72 s, a 2.5× spread between runs of *identical* code. Both runs agree on the
shape: a burst around load, then clusters of stalls as the episodes accumulate, with
fps dipping to 23–50 in the windows that carry them.

**Two caveats that matter more than the numbers.** A later pair of runs measured
*every* phase ~1.6× higher — `food` 0.12 → 0.16, `audio` 0.24 → 0.49, `weather`
0.28 → 0.42 — including phases no scene change can reach: that is contention, not a
result (another build was running here). Re-measure on a quiet machine, three runs,
and compare `slow`/`slowms` — the GC's own footprint — rather than `fps`. And check
`df`: this session also hit a full system drive (`rustc-LLVM ERROR: IO failure on
output stream`), which is its own source of multi-hundred-ms stalls.

**What the scene did about its own share while this was being written** (nothing
below needs the engine's GC to be different):

- A bang used to rebuild the whole 96 m heightfield mesh — 2401 vertices, ~30 µs
each in the interpreter — for 150–650 ms, growing with the crater count. It now hands
the mesh only the box the ground changed in (`world.js`, `terrainPatches`;
`explosions.js`, `terrainDirtyAt`): 5–15 ms, and over the same 100 s chain run the
frames over 100 ms went 12 → 0 and the worst frame 650 → 82 ms. The grid's arrays are
kept and its indices are built once; re-uploading the *same* arrays measured 0.2 ms
against 13 ms for freshly allocated ones.
- A full rebuild still costs ~72 ms — the anchor moving 24 units of travel, or a
blast flinging the player across one — which is the interpreter's price for 2401
vertices. Expect it in `worst` on a run where the player is flung.
- The mods' per-frame API queries were allocating: `bump()` returned a fresh object
per candidate (up to nine a frame), and `contact()` asked `player.state()` twice and
`bots.list()` twice (the latter is a fresh array of fresh handles every call). The
fatguy asks once each now and writes its contact into module scratch
(`mods/fatguy/mod.js`). On this machine the change sits under the noise floor above.

**What to compare once the nursery lands.** `slow` and `slowms` for this protocol
(they are the collector's footprint rather than the scene's) and `worst`. If it does
its job the clusters go and `worst` falls to the scene's own high-water mark —
currently the ~72 ms anchor rebuild, which is the number the scene should then be
held to.

### The nursery landed, and it is measured (engine `58b52dd`)

The engine grew a generational nursery (`58b52dd`, "feat: add a generational nursery
collector": an O(young) minor, in-place promotion, a young-restricted stack scan and
a remembered set, with the minor paced by the young cohort and the major by retained
set growth). The lock moved to it, and the same protocol was re-run.

The end-to-end numbers are ambiguous on this machine — three runs gave `slow` 59 /
110 / 77 and `slowms` 3544 / 3786 / 2835 ms against the baseline's 81 / 5880 and
38 / 2380 — because a cross-session comparison here carries the contention above
(×1.6 on every phase) on top of the change. What is *not* ambiguous is the engine's
own per-collection telemetry, which the client now turns on with `--gc-trace`
(`crates/goats/src/main.rs`, through the embedding context's own `set_gc_trace` —
`slag` stays the only engine entrypoint the client names): 92 s of the same
protocol, 1126 collections:

| level | n | median pause | p95 | max | young (median) |
| --- | --- | --- | --- | --- | --- |
| minor | 1108 | **3.24 ms** | 3.87 ms | 6.23 ms | 8606 |
| major | 18 | 3.59 ms | 5.46 ms | 5.46 ms | — |

Total pause 3614 ms in ~92 s, and **no collection over 6.3 ms**. The baseline's
failures were single stalls of 50–670 ms in `perf`'s windows, which is what the old
full mark-sweep cost; there is nothing of that size left in the collector. Two
consequences:

- **Pause no longer tracks the retained set**, which is what the commit claimed and
  what the numbers show: a minor sweeps ~8.6k young boxes for ~3 ms whether the
  world is a minute or ten minutes old.
- **The stutter that remains is not the collector.** `perf` still reports 59–110
  frames over 30 ms per run, one of them 894 ms, and a collection cannot exceed
  6.3 ms. The scene's own high-water mark is the ~72 ms anchor rebuild (a step, or a
  blast flinging the player across one); everything else of that size is the
  machine (a full disk was measured in this same session, and an engine build ran
  beside these runs). Those are the next two things to chase, and the discipline is
  the same: `slow`/`slowms` for the frame, `--gc-trace` to exonerate the collector.

The allocation rate the nursery is eating is worth recording too: ~8.6k young boxes a
minor, 12 minors a second — **~100k allocations a second** from the scene. That is why
the mod-side allocation diet below measured under the noise: the fatguy's per-frame
scratch is ~1% of it.

### The minor's own cuts, measured (engine `de980d4`)

Eight commits landed after the nursery: the minor's unread passes and its duplicated
function roots (`73c55a9`), a closure's environment tied to its box and try-block
envs elided (`1536367`), retired lexical slots reused and reclaimed (`a3485f6`,
`ca9782d`, `16650e1`, `1a48b91`), a try frame pushed and popped in machine code
(`7a18ef1`), and the derived read caches dropped before a mark (`de980d4`). The lock
moved to `de980d4` and the same protocol ran twice — on a quiet machine this time,
which the stable phases say (`food` 0.12, `audio` 0.20, against the ×1.6 contended
pair above), so these two runs are comparable to each other and to the nursery's:

| | `58b52dd` (nursery) | `de980d4` run 1 | run 2 |
| --- | --- | --- | --- |
| minor, median | 3.24 ms | **1.40 ms** | **1.45 ms** |
| minor, p95 | 3.87 ms | 1.89 ms | 1.89 ms |
| minor, max | 6.23 ms | 3.40 ms | 3.24 ms |
| majors, n | 18 | 11 | 11 |
| major, median / max | 3.59 / 5.46 ms | 3.56 / 6.02 ms | 2.85 / 5.95 ms |
| collection time per second | 39 ms | **18.8 ms** | **18.4 ms** |
| young per minor (median) | 8606 | 8510 | 8695 |
| minors a second | 12.2 | 13.2 | 12.6 |
| `perf` `slow` / `slowms` | 59–110 / 2835–3786 ms | **27 / 1034 ms** | **20 / 785 ms** |
| `perf` `worst` | 894 ms | **90 ms** | **94 ms** |

Read together: the minor is ~2.3× cheaper and the collector's share of the wall
clock is ~2.1× smaller, at the *same* cohort size — young per minor did not move, so
the cuts took cost out of the pass rather than out of what it collects. Majors fell
by a third, which is the same statement one level up (the retained set grows more
slowly, so the trigger fires less often).

**The high-water mark has moved off the collector**, which is what the baseline
asked for. `worst` is now 90–94 ms against the nursery's 894 ms — and that 90 ms is
the scene's own business: the ~72 ms anchor rebuild (a step, or a blast flinging the
player across one) plus this machine's jitter. `slow`/`slowms` fell by ~3.5× on the
same protocol, so what is left has the shape of that rebuild rather than of a
collection. The next thing to chase is therefore scene-side, and it is now the only
thing of its size in the frame.

Two things did *not* move, and they are the record's own next leads: young per minor
(8.5–8.7k) and the allocation rate it implies — ~110k allocations a second from the
scene's own code, unchanged by the slot-reuse work, because that work reuses
*runtime* slots rather than the boxes the scene's own objects and strings make.
`--gc-trace` reports it; the nursery is simply eating it.

### The anchor rebuild, and what a crater costs (scene-side)

The nursery section above names the anchor rebuild as the frame's remaining high-water
mark — "the ~72 ms anchor rebuild (a step, or a blast flinging the player across one)".
It was four times that, and the missing term is the craters: `terrainHeight` scans the
crater list, a full-field rebuild calls it 2401 times (one per vertex), and the list is
capped at 24 (`TUNING.explosions.crater.max`).

A temporary `terrainprobe` verb timed one full-field build piece by piece on a settled
client, second pass of each phase, craters at the cap. ms for 2401 vertices:

| phase | 0 craters | 24 craters | 24, after |
| --- | --- | --- | --- |
| `terrainBuild` (the real thing, upload included) | 61.9 | **721.4** | **36.2** |
| the height pass (`terrainHeightRow`) | 42.7 | **739.1** | **9.4** |
| `terrainHeight` over the grid (the readers' path) | 43.0 | 752.8 | 463.5 |
| the crater term alone (`craterDipAt`) | 30.8 | **713.2** | 458.0 |
| the noise (`terrainShape`) | 19.2 | 20.4 | 18.7 |
| the bowl's arithmetic and `Math.sqrt` | 13.4 | 11.2 | 11.2 |
| the vertex pass (`terrainVertex`) | 28.8 | 29.9 | 36.5 |
| a plain store loop of the same size (the floor) | 25.0 | 25.4 | 23.7 |

So the hitch was a 721 ms frame at the cap, 682 ms of which was the crater scan: 11.8 us
a crater per vertex, which at ~15 operations an iteration is ~0.8 us per *operation*. The
engine interprets a loop that reads a global array and reaches through an object per
crater, and that is the whole of the number.

Three scene-side changes:

1. **The crater term is stamped, not scanned.** A crater reaches `r * 1.45` metres —
   about two cells of the 2 m grid — so it can only move the handful of vertices inside
   its own box. `terrainStampCraters` walks each crater's box and adds `craterDipOne` to
   `T_H`, instead of asking all 2401 vertices about all 24 craters: 57600 iterations
   become ~250 vertex visits. `terrainHeight` split into `terrainBaseHeight` plus the
   crater term, so the row pass writes the base and the stamp adds to it. The heights are
   the same numbers — all 2401 were compared against a fresh scan at the cap and matched
   exactly.
2. **The crater count is hoisted** in `craterDipAt`, the readers' path: re-reading
   `CRATERS.length` once per crater per call was 31% of the function (713.2 → 490.9 ms,
   one run, both shapes side by side).
3. **A vertex may not be stamped twice.** The stamp *adds* where the row pass *assigns*,
   and `terrainPatchRect` widens each patch by a cell so two patches two metres apart can
   share one, so every (build, crater) pass carries a marker in `T_STAMP` and steps over a
   cell it has already had.

At the frame, on the same client with 24 craters live and the debris gone:

| | `perf` |
| --- | --- |
| settled | `worst` 19–21, `slow` 0, `slowms` 0, 60 fps |
| a step rebuild, forced with `pos` | `worst 65.1`, `slow 1`, `slowms 65.1`, 49 fps |

Rejected, and worth the record: flattening the crater list into packed number arrays was
*slower* — 876.0 ms against 713.2 for the shipped object list (934.4 in a second run).
Six globals read per iteration against one cost more than the object fields they save.
What is expensive here is the global binding (~3.9 us inside an interpreted loop), not
the field.

What is left: the vertex pass, 2401 vertices × 11 array stores against a plain store loop
of the same size at ~24 ms, so it is at the interpreter's floor. These edits do not touch
it — the 29.9 → 36.5 spread in that row is this machine's run-to-run noise (see §8), not
a regression — and it is now crater-count independent: 36.2 ms at the cap against 28.0 ms
with no craters at all. The readers are the next lever: `craterDipAt` is still ~190 us a
call at the cap, and a bucket index would let a point query test the craters near it
rather than all of them. Below that, a step stops costing 30 ms only by not rebuilding
the field for it — keeping the mesh in local coordinates and moving it, so a step
computes one band instead of 2401 vertices.

`terrainprobe` was temporary and is not in the tree; the numbers above are its output.

### The allocation rate: what the mods read (scene-side)

The collector's section above leaves one number open -- the ~8.5k young boxes a minor,
which is the scene's own allocation rate. It is **61.7k boxes a second** before this
work, and **the two mods are ~60% of it**.

**Protocol, and a pitfall.** `--gc-trace` prints a line per collection. A window is 10 s
of settle and then 24 s, bracketed by two console commands (`ping` answers `ok pong`, so
the trace lines between the two replies are exactly the window, and `state` either side
gives the frame count). The rate is `minors/s x young per minor`, both read from the
window. The pitfall: **a window that follows a config-changing command in the same run
collapses** -- `mod disable` or `setting shadow 0` between windows left the next one with
1 minor in 1363 frames, where the same configuration alone gives ~100. One configuration
per process, applied before the settle, is the only shape that reproduced. (The first
version of this measurement summed `stack_words`, because the last field of a trace line
is not `young`; the numbers here are the corrected ones, and the pre-fix 61.7k agrees with
the 61.8k this appendix recorded before the work started -- which is the check that the
protocol is right.)

| configuration | minors/s | young/minor | boxes/s |
| --- | --- | --- | --- |
| before this work (both mods, herd 7) | 7.08 | 8708 | **61.7k** |
| after (both mods, herd 7) | 4.42 | 8521 | **37.6k** |
| mods disabled | 2.96 | 8411 | **24.9k** |
| mods disabled, `herd.count 0` | 1.04 | 8645 | **8.6k** |

The two mods cost 36.8k a second before and 12.7k after, **-65%**. The scene's own frame
is now the majority: within that 24.9k the **herd is 16.3k** -- the bots' update and draw
-- and 8.6k is everything else the scene does with no mods and no herd at all.

`goats.bots.list()` was the price of admission. With the fix reverted, ten extra calls a
frame (600 a second) took the rate from 6.25 to 13.75 minors/s, so **~105 boxes a call**
for a seven-bot herd. A handle is an object and four closures around a bot, and a closure
that captures a value costs its function, its environment *and* the captured cell: the
closures are ~12 of the 14 boxes a bot, not 4 of 5 as reading the source suggests. The
earlier note in this appendix that "the fatguy's per-frame scratch is ~1% of it" was right
about the scratch and wrong about the mod -- what a mod *reads* is the cost, and
`list`/`get`/`state` are what both mods read every frame.

The changes, in minors/s as measured, against the ~8.5k young a minor:

| change | minors/s | boxes/s | what |
| --- | --- | --- | --- |
| -- | 7.08 | 61.7k | |
| `perchTarget` asks `bots.get` for the one bot it sits on | 6.96 | 60.7k | it asked `list()` -- ~105 boxes -- to index one element, every frame, for every perched bird. Small, because few birds are on a bot at once |
| the flock's pose maths stops allocating | 6.25 | 54.7k | `bodyQuat` built five objects (three axes, two multiplies) and the two wings ten more: 16 a bird a frame. Turning the draw off entirely measured the path at 9.2k of the then-rate, so the quaternions were most of it; they now write into scratch (`qAxisInto`/`qMulInto`/`qRotInto`/`qAxisAngleInto`/`bodyQuatInto`) |
| the herd handles are pooled | 4.25 | 37.1k | one handle per bot, refreshed per read, and the array is the scene's (`APIv1.md` §4.8). `list()` costs nothing after the first read, and its three callers a frame stop paying |
| the flock's entity rows are pooled | 4.42 | 37.6k | 13 boxes a call -- *under* this protocol's resolution (the runs agree to ~3%); kept as the same waste, not as a measured win |

**61.7k -> 37.6k boxes a second, -39%**, and the mods' own share down 65%.

What is left, in the order it is worth chasing: the **herd's 16.3k** (the bots' update and
draw, not yet separated -- that is the next bisect); the mods' remaining 12.7k; and the
8.6k of everything else, which is the scene's own frame with no mods and no herd.

Two caveats, both about the idle goat: the flock anchors to the *herd* when the player is
not moving, so the birds' `updateHome` reads the herd every frame here and would
early-return in play, and a stationary goat also keeps birds perched on bots (the `get`
path) rather than on the player. Every comparison above is inside this one protocol.

### What the herd's collision pass costs, and the engine finding under it

The herd's 16.3k a second was `resolveGoatCollisions` -- one call a frame, the two
relaxation passes of `collidePairs`. Measured at herd 7 with the mods disabled (floor
2.96 minors/s = 24.9k), one configuration per process:

| | minors/s | boxes/s |
| --- | --- | --- |
| floor | 2.96 | 24.9k |
| `resolveGoatCollisions()` not called | 1.62 | 13.5k |
| the same function with `b.spec.scale` replaced by a constant | 3.00 | 25.2k |
| the same function with one relaxation pass instead of two | 2.33 | 19.5k |

The pass was **11.4k boxes a second -- 30% of the scene's whole rate -- for 56
pair-iterations a frame**, and the cost is linear in the iterations and nothing else:
replacing the only nested read in the loop with a constant changed nothing (3.00 against
2.96), and halving the passes halved the cost. ~3.4 boxes an iteration for a body of
about nine operations.

That is not a scene-side allocation. It is the interpreter: **an interpreted loop body
allocates on the order of a box per few operations**, whatever those operations are. The
notes above already say the engine interprets these loops (~730 ns an operation against
~50 compiled, §4b/§7); what this adds is that the same interpreted work *is* the
allocation rate, so the two hunts are one hunt. It is worth handing to the engine side
as its own finding.

The action, measured:

| change | minors/s | boxes/s |
| --- | --- | --- |
| before | 2.96 (mods off) / 4.42 (both mods) | 24.9k / 37.6k |
| the second relaxation pass runs only when the first moved something | 2.38 / 3.79 | 19.9k / **32.2k** |

The pass exists because "shoving a bot off the player can push it into another bot", so a
pass that moved nothing cannot have made a chain -- a chain still settles in the frame it
was made in, and the quiet frame skips half the work. The `collide` phase drops with it,
0.27 -> 0.15 ms.

Two negative results worth keeping:

- **The flock's separation is free.** `separateFlock` is the same O(N^2) shape (15 pairs a
  frame at `COUNT = 6`) and turning it off measured 3.88 minors/s against 3.79, inside
  the noise. Its body mostly `continue`s on the airborne filter, which is the same
  finding from the other side: the *operations* are charged, not the loop.
- **A spatial grid would be the wrong fix here.** The pair loop is n + n(n-1)/2
  iterations a pass (28 at seven, 210 at twenty); a grid needs an insert and a 3x3 query
  per unit, so at least ~9 cell reads each, i.e. ~10n iterations (70 at seven, 200 at
  twenty). It breaks even around twenty units and loses below that -- and the herd is
  clamped to ten. So the quadratic *shape* is bounded by a cap, and the fix that pays is
  the relaxation count; the grid is the shape to reach for if a cap rises, and that
  crossover is the number to check first.

### What the engine actually allocates for, and what is left

An earlier version of this section said ~0.36 boxes an interpreted operation and blamed
interpreter overhead for the scene's remaining rate. **That was wrong.** The tool that
settled it is kept in the tree: `perf loop <kind> <n>` arms one loop of `n` iterations a
*frame* (goat.js), so a single run can be read off both clocks -- `perf loop` replies ns
per iteration, and `--gc-trace` gives boxes per iteration. One variant per process, 200
iterations a frame, sound muted, the usual 24 s window (`bench.sh` drives the sweep):

| body (one operation an iteration) | boxes/s | ns/iteration |
| --- | --- | --- |
| `none` (unarmed) | 32777 | -- |
| `arith` (locals) | 32857 | 47.7 |
| `arithinline` (the same body in the large driver) | 32890 | **17.4** |
| `global` (a global binding read) | 32463 | 71.9 |
| `field` (an object property read) | 32908 | 78.5 |
| `fieldset` (an object property write) | 32543 | 91.9 |
| `index` (an array element read) | 32282 | 97.5 |
| `sqrt` (`Math.sqrt`) | 32850 | 82.5 |
| `call` (a small JS call) | 32162 | 97.7 |
| `mapget` (a `Map.get`) | 32901 | 174.8 |
| `maphas` (a `Map.has`) | 32520 | 179.4 |
| `mapset` (a `Map.set` on an existing key) | 32899 | 177.2 |
| `new` (one object literal) | **44311** | 172.6 |

Twelve thousand iterations a second of every one of those bodies adds **nothing** to what
the collector sweeps. Arithmetic, a global read, an object read and write, an index, a
builtin, a JS call and a Map lookup are all allocation-free, and they run at 17-98 ns an
iteration -- i.e. compiled. Only an object literal allocates, and it allocates **0.96
boxes a literal**, which is the calibration the table needed. So there is nothing in the
engine's loop, call or Map path to fix, and this scene's remaining rate is *real
objects* -- literals, closures, arrays and strings -- not interpreter overhead.

The same sweep prices the engine's operations in time, which is the other half an engine
author wants: arithmetic 48 ns, a global read 72, an object read 79, an object write 92,
an index 98, a small call 98, and a Map lookup 175-179. A Map is twice an index.

What that leaves, honestly. The herd's collision pass was 11.4k a second (measured inside
one build: `resolveGoatCollisions` not called, 24.9k -> 13.5k) and it contains no
allocation at all -- no literal, no closure, not even a builtin -- so its cost is
*indirect*: something its shoves make other code do. Of those paths, each measured inside
one build: the per-unit trap query is 2.5k (17.4k against a 19.9k floor), and the
explosion system it trips is 3.6k (21.3k against 24.9k). About 5k of the 11.4k is still
unattributed, and that is the open question this record leaves.

Two smaller corrections from the same round. `nearestTuft` builds its result object on
every improving cell instead of once, which looked like the trap query's cost -- making it
build once measured nothing at all (19.9k before and after) and was reverted rather than
kept as a tidy-up; at a 0.6 m trigger the scan is 3x3 and only a tuft inside it improves,
so that object was created at most once a call. And `tuftKey` is a *number*, not a string
(both were suspected), so the cell bookkeeping Maps allocate nothing.

# Slag Goat — Plugin ABI v1 (proposal)

**Status:** a proposal with a landed proof, not a shipped feature. No crate loads
a plugin yet; the fixtures in `fixtures/wasm/` are driven by one test,
`crates/harness/tests/plugin_abi.rs`. The plan is `ROADMAP.md` M17; the mod API
this sits beside is `APIv1.md` (whose section 11 used to say "native plugins"
and nothing else).

## 0. What this is for

Not speed.

A compiled mod is not here to be faster than the scene's JavaScript, and today it
mostly would not be: Slag executes wasm on an interpreter, with a
wasm-to-native Cranelift path present but off by default until its equivalence
gate holds corpus-wide -- while the JS path has had years of optimization behind
it, including the JIT the shipped client already enables. If speed were the goal,
the honest first move would be to keep optimizing the JS path.

This is for **language freedom**. A mod author should be able to write in Rust,
C, Zig, Go, AssemblyScript or whatever else compiles to wasm -- and reuse a
library from that ecosystem -- instead of being handed one JavaScript global and
told to like it. Performance is a debt to be paid later, the way it was paid for
JavaScript.

Two things make this cheap to try rather than a rewrite:

- The **engine already exists**. Slag's `wasm` crate is a spec-tracked WebAssembly
  core engine (decoder, validator, interpreter, SIMD, GC, exceptions, tail
  calls), and the WebAssembly JS API is a default-on runtime feature -- so the
  shipped client and the headless harness already have a `WebAssembly` global.
- The **rules already exist**. `APIv1.md` section 0 says a mod gets no
  filesystem, no path, no socket, and assets as host-registered opaque names.
  A wasm module has no ambient authority at all, so that rule stops being a
  promise and becomes a property of the sandbox.

## 1. The governing idea: the import list is the API

A plugin cannot do anything it did not declare. Everything it can reach is an
import the host provided at instantiation, so:

- **The capability list is inspectable.** `WebAssembly.Module.imports(module)`
  answers "what does this mod want?" without running it -- what the Mods screen
  shows and what a host grants from.
- **Default-deny is structural, not a check.** A module importing something the
  host does not grant fails to *link* (`unlinkable`), so there is no code path
  where a forgotten guard leaks a capability.
- **No WASI is a feature.** Mods link against a wasi-free target, so a plugin
  that tries to open a file does not get policed -- it does not link. The I/O
  wall from `APIv1.md` section 0 is enforced by the linker.
- **A missing import can encode a rule.** There is no clock import in v1, on
  purpose: a world mod that cannot read wall time cannot desync, and that is
  enforced by linking rather than by review.

The ABI is therefore unusually small: a mod's power is the length of its import
list, and that list is short by design.

## 2. The shape of a call: one crossing per frame

The ABI is built around a coarse boundary, and this is the decision that makes
the current performance situation tolerable rather than fatal.

An interpreter several times slower than JITted JavaScript is a disaster if the
plugin is called once per entity per frame, and a footnote if it is called once
per frame with a buffer. So the host does not push arguments and pull results
per entity: it writes an array of records **into the module's own linear memory**,
calls an exported function **once** with `(pointer, count, dt)`, and reads the
results back **out of that same memory** afterwards.

That has three consequences worth stating:

- The per-call overhead and the interpreter gap apply to the inner loop only --
  which is precisely what `compile` and later optimization exist to fix. The API
  does not have to change when wasm gets fast.
- Large data never crosses as values. A mod that wants to hand over a vertex
  buffer hands over a pointer and a byte count.
- The host reads and writes the module's memory directly, so buffer layout is
  part of the ABI and has to be specified, not merely implied.

## 3. The ABI

### 3.1 Scalars

| Type | Use |
| --- | --- |
| `i32` | integers, pointers (offsets into the module's memory), lengths, status codes, record counts |
| `f32` | simulation values that are stored in records |
| `f64` | simulation values that are computed, and every value the host returns |

**No `i64`.** This was found the hard way: the first fixture declared
`goats_init(seed: i64)`, and calling it from a JS host failed with "Cannot convert
a Number to a BigInt" -- a 64-bit integer is a `BigInt` across that boundary, and
several non-Rust toolchains find it awkward too. `i32` and `f64` are what every
target language and both imaginable hosts handle without ceremony.

### 3.2 Memory

The module owns its memory and **exports** it, so the host can address it.
`wasm-ld` does this with `--export-memory`; the Rust fixture relies on the
target's default. Neither side may assume the memory is small enough to
reallocate casually: a host that writes into `memory.buffer` must not have grown
the memory since it took the view.

### 3.3 Imports (namespace `goats`)

v1 is exactly two, and the fixtures implement exactly these:

| Import | Signature | Meaning |
| --- | --- | --- |
| `log` | `(ptr: i32, len: i32)` | The host reads `len` UTF-8 bytes at `ptr` and logs them under the mod's id. |
| `rng` | `(stream: i32) -> f64` | One draw from a host-owned, seeded stream. The host decides what the stream is; the *ordering* of draws is part of the ABI. |

Reserved for the version that follows, and deliberately **not** in v1, because
each is a policy decision rather than a function:

| Reserved | Why it is not v1 |
| --- | --- |
| `publish(ptr, len)` / `apply(ptr, len)` | The world-mod state surface (`APIv1.md` section 4.13). It drags in the digest, the datagram budget and the determinism rules, which is M17c's job. |
| `assets` | A plugin should reach an asset by the same opaque-name route as the scene, not by a path. Needs the asset-slot work first. |
| `now_ms()` | A clock is a divergence hazard. If it exists at all it is client-side only, and the absence of the import is what stops a world mod from using it. |
| `scene` | Any callback into the scene's own state. That re-enters JavaScript and its reentrancy rules; see section 5. |

### 3.4 Exports

| Export | Signature | Meaning |
| --- | --- | --- |
| `goats_abi` | `() -> i32` | The ABI version this module was built against. The host calls it first and refuses a module it does not know. |
| `goats_alloc` | `(len: i32) -> i32` | A buffer of `len` bytes in this module's memory. v1 does not specify an allocator; a real plugin brings its own, a fixture can bump-allocate. |
| `goats_init` | `(seed: i32) -> i32` | Called once after instantiation. `0` is success, anything else is a failure the host reports. |
| `goats_update` | `(ptr: i32, count: i32, dt: f32) -> i32` | The frame call. Returns the record count it processed. |

### 3.5 The record, and the arithmetic

One record is 16 bytes, and the layout is part of the ABI:

```
f32 x | f32 z | f32 yaw | f32 vx
```

`goats_update` must compute, for each record `i` in ascending order, exactly:

```
vx[i] = f32( f64(vx[i]) + rng(i) * f64(dt) )
```

One draw from stream `i` per record, in ascending order -- and that sentence is
the interesting one. A world mod's arithmetic is part of the compatibility set:
two hosts that agree on the ABI but differ on the order of `rng` draws, or on
whether the multiply happens in `f32` or `f64`, would simulate different worlds
from the same seed and never know. Specifying the value is not pedantry; it is
the same reason the wire format has a `PROTOCOL_VERSION`.

The fixtures' `goats_log` messages differ by language ("plugin-c: ready",
"plugin-rust: ready") so the test can tell the modules apart. Everything that
affects *state* must not differ, which is exactly the line the test draws.

### 3.6 Failure

- **A trap** (out-of-bounds access, an explicit `unreachable`, a stack
  exhaustion against the engine's depth limit) is reported per mod and the game
  carries on -- the isolation `APIv1.md` section 7 already promises for a
  throwing handler.
- **A missing import** fails at instantiation, before any code runs.
- **A wrong ABI version** fails the same way `APIv1.md` section 2.3 already fails
  a mod with the wrong `api` major: named, refused, and not loaded.
- **A runaway loop** still hangs the frame. `DEFAULT_DEPTH_LIMIT` bounds depth
  and a memory's `max_pages` bounds size, but there is no instruction budget in
  the engine today, so a plugin is no worse than a JavaScript `while (true)` and
  no better. That is a known gap, not a claim (section 7).

## 4. What the fixtures prove

`fixtures/wasm/` holds one ABI in two languages: `c/plugin.c` (clang, `wasm32`,
`-nostdlib`, no WASI) and `rust/src/lib.rs` (`wasm32-unknown-unknown`, no
`std`-dependent runtime surface). The artifacts are checked in -- a few hundred
bytes each -- so the test and CI need no wasm toolchain; `build.sh` rebuilds them.

`crates/harness/tests/plugin_abi.rs` loads both through Slag's `WebAssembly`
global with a JS host stub standing in for the Rust host, then requires:

- both negotiate `goats_abi() == 1`;
- both declare exactly `goats.log` and `goats.rng` -- the capability list, read
  off the module rather than assumed;
- both log the string the host reads out of *their* memory, each its own;
- both return the same record count;
- and, the point of the exercise, **the same `vx` values, byte for byte**, given
  the same host-provided randomness.

That last assertion is the one that matters. Two independent toolchains agreeing
on a computed result means the ABI is fully specified at the level a mod author
in a *third* language would need. If only one language could target it
conveniently, the whole idea would have failed at its single job.

## 5. The fork in the road: who drives the plugin

The fixtures are loaded through the JS `WebAssembly` API, which is what exists
today. That covers the "wasm as a compute core" shape: a mod ships wasm plus JS
glue, and the glue receives the scene's events. It does **not** free a mod from
JavaScript -- it moves the interesting code into wasm and leaves the plumbing.

The other shape is the host driving the module directly: fixed exports called
from Rust, imports implemented in Rust, no JS anywhere. That is the one that
delivers the promise, and it needs one thing that does not exist yet: from
`goats`, the `wasm` crate is not reachable. `slag`'s own dependencies are
`crux`/`runtime`/`jit`, the `wasm` crate hangs off `runtime` behind a feature,
and `Context` exposes no instantiation API. So either `goats` adds a second
dependency on the same slag git revision (which Cargo unifies, but the two
declarations then move in lockstep forever) or Slag re-exports the engine
surface. That is an **engine prerequisite (upstream Slag)**, the same shape
`ROADMAP.md` already has under M9.

Given that, the two shapes are not exclusive and not equally urgent:

1. Wasm as a compute core (works today, needs no engine change).
2. A Rust-side host driving exports, with the deterministic subset of `goats`
   (`rng`, `publish`/`apply`, world queries) implemented in Rust, and the
   scene-mutating parts staying JS for now.

## 6. Not in v1

- **`dlopen` of native dynamic libraries.** Not "later" -- out of scope for the
  mod system. There is no stable Rust ABI, per-platform artifacts multiply the
  release matrix, a loaded library cannot be unloaded safely so hot reload dies,
  a segfault takes the game with it, and native math (`-ffast-math`, x87 vs SSE,
  per-platform libm) quietly breaks the determinism a world mod needs. Everything
  it offers over wasm is *engine* access, which belongs upstream or in a fork,
  not in a downloadable mod.
- **Zero-copy engine access.** A plugin cannot hold a raylib model or point at
  the scene's state. It computes, and hands over buffers.
- **Threads and real-time callbacks.** A plugin runs synchronously inside a
  frame. Anything with a deadline (audio DSP, a render pass) is engine work.
- **A stable ABI for Rust types.** The surface is wasm, which *is* a stable ABI
  with an independent specification and many implementations.

## 7. Open questions

1. **Host-provided math.** Core wasm has no `sin`/`cos`. Either a plugin imports
   them from the host -- and then the host's platform `libm` is a determinism
   hole for world mods -- or it brings its own. The scene's JS world mods have
   the same hazard through `Math.*` today, so whatever is chosen should be
   chosen once and applied to both.
2. **An instruction budget.** Without fuel, a plugin can hang a frame. The
   engine has a depth limit and memory can be capped at instantiation; fuel is
   the missing piece.
3. **Who owns the boundary, and how far the deterministic subset reaches.** See
   section 5. The narrow path is `rng` + `publish`/`apply` in Rust; the broad one
   is a scene bridge, which brings JavaScript's reentrancy rules back in.
4. **Digest and distribution.** A client-side plugin is unhashed like any
   `side: "client"` mod. A world-side one joins the compatibility set, so the
   digest must cover the artifact's bytes *and* the ABI version -- and, because
   wasm is portable, one artifact can serve all three release targets, which is
   the property `dlopen` can never have.
5. **Reload.** An instance drops and re-instantiates cleanly, so `--watch`
   (M14g) should extend to compiled mods -- unlike a loaded dynamic library.
6. **The performance debt, as a number.** A benchmark kernel (the boid inner
   loop at N entities) measured three ways -- JS under JIT, wasm interpreter,
   wasm `compile` -- belongs in the repository, so "wasm is slow" is falsifiable
   and the day it stops being true is visible.

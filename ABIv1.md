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

A mod declares a module beside `entry` in its manifest -- a mod may have one or
the other, or both:

```json
{ "id": "com.example.wasm", "api": 1, "side": "client",
  "wasm": { "module": "plugin.wasm" } }
```

The host reads the file, refuses one that does not start with the wasm magic, and
hands the bytes to the scene as an `ArrayBuffer` through a single scene entry
point (`sceneWasmModule(id, bytes)`) -- never a path, and never as JSON, because
a module is content (`APIv1.md` section 0). The scene instantiates it with the
capabilities below and drives it. `side: "world"` is refused until the
compatibility digest covers the artifact (section 7).

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

Both signatures are shaped by *where the memory is*, not by privileges. `rng`
carries values, so it can be a native host function anywhere. `log` carries a
pointer into the module's linear memory, so whoever implements it has to be able
to read that memory -- the driver, in the shape where the JS API instantiates the
module; the Rust host, in the shape where `Store` does. Section 5.

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
| `goats_update` | `(ptr: i32, count: i32, dt: f32) -> i32` | The frame call. The return is the mod's own status: this host reports it and does not interpret it. |

### 3.5 The record

One record is 16 bytes, and the layout is part of the ABI:

```
f32 x | f32 z | f32 yaw | f32 vx
```

What the four floats *mean* is the mod's business. The host seeds them once,
hands the buffer over and reads the bytes back; it does not interpret them, and
the ABI does not say what the mod must compute. An earlier revision of this
document specified the benchmark kernel's arithmetic as though it were the ABI's,
which it never was.

Two things about the arithmetic *are* the ABI's, because a world mod's
compatibility depends on them:

- Randomness comes from `goats.rng` and never from a clock -- which is not
  importable at all -- so the stream belongs to the host.
- The number and order of draws is part of the mod's contract with its peers: two
  hosts that agree on the ABI but differ on the draw order would simulate
  different worlds from the same seed and never know. That is the same reason the
  wire format has a `PROTOCOL_VERSION`, and it is why the fixture draws once per
  record, ascending.

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

Both shapes build the `goats` namespace in the host, and the capabilities can be
Rust. The embedding API registers native functions (`Context::create_object`,
`create_function`, `register_fn`, and the re-entrant `FunctionCall::call` /
`eval`), so a capability may be a closure over host state rather than a
JavaScript function. `crates/harness/tests/plugin_abi.rs` runs the fixture with
the namespace built each way and requires the same behaviour: the implementation
language of a capability is no more part of the ABI than the implementation
language of a plugin.

So the fork is narrower than it first looks -- it is about **who instantiates the
module**, not about who implements the capabilities.

1. **The JS API instantiates it** (shipped in M17a). The host owns the driver --
   in the game it is `mods.js`, whose `sceneWasmModule` builds the import object
   and calls `WebAssembly.Instance`, then `modWasmTick` drives the module once a
   frame. The mod ships only `.wasm`. Capabilities can be host-native, and one
   that needs the scene can reach it through the re-entrant
   `FunctionCall::call`/`eval`.
2. **Rust instantiates it** (needs one thing that does not exist yet). Driving a
   module's exports from Rust, and owning its memory, means the `wasm` crate's
   `Store` -- and from `goats` that crate is not reachable: `slag`'s dependencies
   are `crux`/`runtime`/`jit`, the `wasm` crate hangs off `runtime` behind a
   feature, and `Context` exposes no instantiation API. Either `goats` takes a
   second dependency on the same git revision (Cargo unifies it, but the two
   declarations then move in lockstep forever) or Slag re-exports the engine
   surface. That is an **engine prerequisite (upstream Slag)**, the same shape
   `ROADMAP.md` already has under M9.

**What shape 2 buys, and what shape 1 costs.** Both run the same compiled code
-- the Cranelift path is the engine's default on native targets -- so the
difference is the boundary and the memory. Shape 1 pays one JS-to-wasm call per
frame: 2.2 us in isolation, and about 8 us in the benchmark's own rows, a gap
that is host-side rather than kernel and is written down there rather than
explained. It also needs a decode step in the driver for any capability that
reads the module's memory. Shape 2 owns that memory, which is what a
pointer-and-length capability needs (section 3.3), and calls into the module from
Rust, which the same 6-record call costs about 0.4 us to do. Neither is a
privilege difference: both drivers are the host's code, and the mod never sees
either.

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
3. ~~**Who owns the boundary, and how far the deterministic subset reaches.**~~
   **Settled for v1:** the scene's driver is the boundary (M17a), and its
   capabilities are host closures. The Rust-hosted shape (M17b) is the remaining
   fork, for the memory and the cheaper call, not for the capabilities.
4. **Digest and distribution.** A client-side plugin is unhashed like any
   `side: "client"` mod, and ships one portable artifact for all three release
   targets. A world-side one would join the compatibility set, so until M17c
   prices the artifact into the digest the loader refuses `wasm` on a
   `side: "world"` mod rather than let two hosts disagree silently.
5. ~~**Reload.**~~ **Settled:** `sceneModEnd` drops a compiled mod's instance, so
   `--watch` (M14g) already re-instantiates it the same way it re-reads an entry.
6. ~~**The performance debt, as a number.**~~ **Measured, and paid** (M17): the
   Cranelift path is the engine's default on native targets, and on the flock's
   kernel shape it is 12-19x faster than JavaScript with the JIT, while the
   interpreter -- what a wasm32 host would run -- is 84-197x slower per pair.
   What is left is a per-call cost on small flocks whose size the benchmark
   reports but does not yet explain. `ROADMAP.md` M17 has the table.

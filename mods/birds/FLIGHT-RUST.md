# Sharing the flight mechanics in Rust — architecture

**Status:** chosen. R0 has landed: `crates/flight` has the controller, fall
damage, bot input, pose and tuning defaults, with 35 unit tests plus a doctest
(`cargo test -p flight`). R1–R4 are the client bindings and the wire; the
*gameplay* contract is still `FLIGHT.md` and does not change.
**Question:** can most of the new flight mechanics live in Rust so both clients
share one implementation?
**Short answer:** yes — for the mechanics, as a pure `crates/flight` library with
a thin binding in each client. No, for the integration: input, modes, stats,
drawing, net and the mod API stay where they are.

This note is deliberately separate from `FLIGHT.md`. That document says *what
the feature does*; this one says *where the code lives*. With this architecture
chosen, `FLIGHT.md` §7's per-client tables are the bindings, and the maths lives
moves into one crate.

---

## 1. The seam already exists

This is not a new kind of split. Both clients already link Rust for everything
that is not the renderer:

**The raylib client** is a Rust host that embeds the Slag JavaScript engine. It
installs native globals *before* it evaluates the scene:

- `crates/goats/src/lib.rs` `run()` — `context.install_raylib()`, then
  `#[cfg(target_os = "android")] android::install(&mut context)` and
  `#[cfg(target_arch = "wasm32")] web::install(&mut context, ...)`, then
  `context.eval(SCENE)`.
- `crates/goats/src/android.rs` and `crates/goats/src/web.rs` are the pattern:
  `context.create_object()`, `JsObject::set(name, create_function(...))`,
  `context.set_global("android"|"web", surface)`.

The same scene is evaluated by two more hosts, each with the same
`Context` and the same opportunity to install a global:

- `crates/server/src/headless.rs` `Sim::start` (the dedicated `goatsd`);
- `crates/harness/src/lib.rs` `Harness::start` (the 205-case scene suite).

**The Godot client** is a GDExtension (`crates/godot`) that links the pure Rust
crates `proto`, `session`, `mods`, `pull` and `plugin` — `PORT.md` §2's own rule:
*the Rust that is pure logic is reused, the JS is not.* A pure flight crate is
exactly that kind of Rust: no engine, no window, no GDScript. It can be a class
on the extension (`#[derive(GodotClass)]` + `#[godot_api]`, the same shape as
`ModHost`/`NetBridge`) and be called from `player_goat.gd`/`bots.gd`.

So the two bindings are:

| Client | Binding | Mechanism that already exists |
| --- | --- | --- |
| raylib / `goatsd` / harness | `__flight` global in the Slag realm | `create_object` / `create_function` / `set_global` (`android.rs`, `web.rs`) |
| Godot | `Flight` GDExtension class | `#[derive(GodotClass)]` in `crates/godot/src/lib.rs` |

No new transport, no new build system, no new dependency direction.

---

## 2. What belongs in the crate

A new workspace member, `crates/flight`, with no dependencies on `proto`,
`session`, Slag or Godot. Pure `f32` maths and pure rules.

**In Rust — the mechanics**

- the tuning shape: `Config` (flight constants + their defaults and clamps);
- the flyer state: position, height, yaw, pitch, roll, airspeed, vertical speed,
  flap cooldown/count, phase;
- `step`: attitude easing, bank→yaw, airspeed easing, vertical model, flap
  burst, ceiling, ground contact;
- the transitions: `can_take_off` (the running-jump rule), `start`, `release`
  (into `fall`), fall integration, `land`;
- fall damage, including the safe-impact threshold and the health floor;
- the **bot autopilot**: the ring target, yaw/bank/pitch steering, when to flap,
  when to descend and land;
- the pose: a quaternion for yaw/pitch/roll (or an axis-angle for raylib) and
  the rider's back-point offset with the body pivot;
- the event list a step can produce (`TookOff`, `Flapped`, `Landed { impact,
  damage }`, `Released`, `Ceiling`);
- unit and property tests for all of it.

**Per client — the integration**

- reading keys/touch and handing the crate `move`/`turn`/`flap`/`release`;
- the mode machine around it (`dead`, `sleep`, `eat`, `flung`, `jump`), stats and
  energy, the death/restart path;
- world interactions: mines/airborne guards, water, portals, collisions, the
  HUD and the bleat/squawk;
- net publishing and mirroring, the wire fields, the proto enum;
- drawing the result and the mod API (`setFlight`/`fly`/`release`, state fields);
- the birds mod itself.

**Not in Rust**

- the existing gaits, bot walking/grazing AI, terrain, water, rendering, mod
  runtime. This is an additive crate for a new mechanic, not a move of the
  simulation.

The existing `FLIGHT.md` §3 rules are the crate's specification; the difference
is that they are written once, in Rust, instead of twice in JS and GDScript.

---

## 3. The crate API (sketch)

Caller-owned state, pure functions. The client owns the goat/bot numbers, so the
crate cannot become a second world that drifts from the one the client draws and
publishes.

```rust
pub struct Config { /* pitch_max, bank_max, speed, sink, flap_lift, ... */ }
impl Config {
    pub fn validate(&mut self);
    pub fn fall_damage(&self, impact: f32) -> f32;
    pub fn apply_fall_damage(&self, health: f32, impact: f32) -> f32;
}

pub enum Phase { Grounded, Fly, Fall }

pub struct State {
    pub x: f32, pub z: f32, pub y: f32,      // y is absolute base height
    pub yaw: f32, pub pitch: f32, pub roll: f32,
    pub speed: f32, pub vy: f32,
    pub flap_cool: f32, pub flaps: u32, pub flight_time: f32,
    pub phase: Phase,
}

pub struct Input {
    pub move_axis: f32,   // W +1, S -1
    pub turn_axis: f32,   // A +1, D -1
    pub flap: bool,
    pub release: bool,
    pub energy: f32,      // the flap is refused below `flap_energy`
}

pub struct Events {
    pub flapped: bool, pub flap_cost: f32, pub drain: f32,
    pub released: bool, pub ceiling: bool, pub landed: Option<Landing>,
}
pub struct Outcome { pub state: State, pub events: Events }

/// `ground` is the scene's own height function: the crate calls it at the
/// position it moves to, so landing and the ceiling are the crate's rules.
pub fn step<G: Fn(f32, f32) -> f32>(
    cfg: &Config, state: State, input: Input, dt: f32, ground: G,
) -> Outcome;

pub fn can_take_off(capable: bool, running: bool, move_axis: f32) -> bool;
pub fn start(cfg: &Config, state: State, ground_speed: f32) -> Start;
pub struct Start { pub state: State, pub energy_cost: f32 }
pub fn release(state: State) -> State;

pub struct BotContext { /* player_x/z, orbit_angle, orbit_dir, landing */ }
pub struct BotControl { pub input: Input, pub orbit_angle: f32 }
pub fn bot_input<G: Fn(f32, f32) -> f32>(
    cfg: &Config, state: &State, ctx: BotContext, dt: f32, ground: G,
) -> BotControl;

pub fn pose(state: &State) -> Quat;                 // yaw, pitch, roll
pub fn axis_angle(q: Quat) -> AxisAngle;            // the raylib form
pub fn back_point(state: &State, perch_h: f32, pivot: f32) -> [f32; 3];
```

Notes:

- **`ground` as a callback** keeps landing/ceiling/terrain-follow in one place.
  It is one cross-language call per flyer per frame, and only flyers pay it. If
  that ever profiles hot, the fallback is a two-phase API: `propose` returns the
  new `x/z`, the client samples the ground, `resolve` applies landing. The
  rules stay in the crate either way. A third option is to pass `ground_now`
  and `ground_next` as two numbers; the callback is the precise one.
- **`f32`** matches Godot's `Vector3` and the wire. The JS scene's positions are
  f64; they convert at the boundary. The player's own flight is client-local
  and the bots' flight is host-authoritative, so exact cross-client float
  equality is not a requirement — but one type avoids two answers.
- **`Config`** is seeded from `FLIGHT.md` §6.1's defaults in the crate; each
  client's tuning tree still carries the leaves for the console/mods and passes
  the current values in. `Config::validate` is the shared clamp table.
- **Events** carry the *consequences* the client applies: a flap's energy cost,
  a landing's damage. The crate does not touch health, energy, modes or sound.

---

## 4. The raylib / server / harness binding

Add one crate, `crates/flight-js`, and install its `__flight` global in the
three hosts. It is a crate rather than a module in `crates/goats` because the
server and the harness evaluate the same scene but must not link raylib, and
`slag`'s `raylib` feature is additive per crate:

```rust
// the same shape as android::install / web::install
pub fn install(context: &mut Context) {
    let surface = context.create_object().expect("the flight object");
    // step(state[], input[], dt, ground) -> [state..., events...]
    surface.set("step", context.create_function("step", 4, Box::new(|call| { ... })));
    // configure / start / release / fallDamage / applyFallDamage / botInput /
    // pose / axisAngle / backPoint
    context.set_global("__flight", surface.as_value()).expect("the flight global");
}
```

- `crates/goats/src/lib.rs` `run()` — before `context.eval(SCENE)`.
- `crates/server/src/headless.rs` `Sim::start` — before the eval.
- `crates/harness/src/lib.rs` `Harness::start` — before the eval.

Then `goat.js` and `bots.js` change only at the flight branches:

```js
// state: x, z, y, yaw, pitch, roll, speed, vy, flapCool, flaps, flightTime, phase
// input: move, turn, flap, release, energy
const out = __flight.step(stateArray, inputArray, dt, terrainHeight);
// out[0..12] is the new state; 12 flapped, 13 flap cost, 14 drain,
// 15 released, 16 ceiling, 17 landed, 18 impact, 19 damage
```

`start(state, groundSpeed)` returns the 12 state numbers plus the take-off's
energy cost at index 12; `release(state)` returns the state alone. The numbers
cross positionally rather than as objects, so a frame is one crossing per goat
and allocates nothing.

The existing `goat`/`bot` objects keep owning `x/y/z/...`; the crate is a pure
function. The `__flight` global is **internal**, not part of the `goats` mod API.
The reference already exposes `rl`/`android`/`web` to the realm, so it is not a
new sandbox hole; the name and the docs keep mods away from it. The Godot mod
realm does not see the class at all (it is on the extension, not in the mods'
Slag context).

The flat array is not cosmetic: the JavaScript side already keeps these numbers
as a plain object, and an array is one crossing rather than a dozen property
writes. For the player and a handful of flyers this could be individual calls;
if a herd takes off at once, the same API can grow a batch `stepAll(flat)` later
without changing the maths.

**Terrain:** the host has the scene's `terrainHeight` `JsValue`; the wrapper
passes a Rust closure that calls it. That is a re-entrant JS call from the host,
which Slag supports (the harness already calls scene functions), and it is the
only callback the crate needs.

---

## 5. The Godot binding

`crates/godot/src/flight.rs`, registered beside `ModHost`/`NetBridge`:

```rust
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct Flight { base: Base<RefCounted> }

#[godot_api]
impl Flight {
    #[func] fn step(&mut self, state: PackedFloat32Array, input: PackedFloat32Array,
                     dt: f32, ground: Callable) -> PackedFloat32Array { ... }
    #[func] fn start(&self, state: PackedFloat32Array, ground: Callable) -> PackedFloat32Array { ... }
    #[func] fn release(&self, state: PackedFloat32Array) -> PackedFloat32Array { ... }
    #[func] fn fall_damage(&self, impact: f32) -> f32 { ... }
    #[func] fn bot_input(&self, state: PackedFloat32Array, ctx: PackedFloat32Array) -> PackedFloat32Array { ... }
    #[func] fn pose(&self, state: PackedFloat32Array) -> Quaternion { ... }
    #[func] fn back_point(&self, state: PackedFloat32Array, perch: f32, pivot: f32) -> Vector3 { ... }
}
```

`main.gd` creates one `Flight` and hands it to the modules the way it already
hands `meadow`/`explosions`/`water`:

```gdscript
goat.flight = flight
bots.flight = flight
```

`player_goat.gd`'s `_integrate`/`step` and `bots.gd`'s `update` call it in their
`fly`/`fall` branches and write the returned numbers back. The GDScript state
machine, stats, HUD, net and drawing are unchanged. The tuning tree populates
the `Config`; a `Tuning` change rebuilds it.

The port's mod context (`ModHost`) is untouched: a mod never sees the `Flight`
class. Its `goats` surface still gets the new API members (`setFlight`, `fly`,
`release`, the state fields) from the scene, as `FLIGHT.md` §5 specifies.

---

## 6. State ownership: caller-owned, not a crate world

The recommended shape is a pure `step(state) -> state`, not a Rust-owned
`FlightWorld` with handles. Reasons:

- the client already owns `goat`/`bot` state for drawing, collisions, net,
  mods and the HUD; a second authoritative world is a second thing to keep in
  sync;
- the existing `flingY`/`goat.py` split is the precedent: an absolute height is
  the physics state and `py` is derived for everything else. The flight state is
  the same shape;
- the adapter is trivial to test: call the function, assert the numbers;
- if a hundred bots ever fly, the pure functions make a batch `stepAll` easy to
  add without changing ownership.

A crate-owned world would save a few marshalled numbers and lose the single
source of *ownership* the rest of the game relies on. It is not worth it for
this feature.

---

## 7. Performance

- Only **flyers** call the crate, not the whole herd or flock. The common frame
  has zero calls; a captured player is one; a few flying bots are a few.
- The raylib proxy global is a **global object-record property** (`__flight`),
  the cheap kind of global in the scene (`PERF.md` §4c: ~2.5–7 ns a read); the
  cost is the call crossing, not a declaration read.
- The Godot side already crosses GDScript→Rust for networking, mods and assets;
  one native call per flyer per frame is the same order.
- The flat array avoids building a dictionary/object per flyer per frame.
- The terrain callback is the one per-flyer re-entry. If a profiler shows it,
  switch to the two-phase `propose`/`resolve` or pre-sampled `ground_now`/
  `ground_next`; the public rules do not change.

No existing hot path (gait, herd, grass, water, birds' boids) gains a crossing
from this.

---

## 8. Testing

**`crates/flight` (new, `cargo test`)**

- take-off: run jump yes, walk/standing jump no, dead/sleep no;
- attitude: W/S sign of `vy`, A/D sign of `roll` and `yaw`, clamps;
- flap: impulse, cooldown, energy cost, refuses at zero energy;
- ceiling and ground contact, including a slope met while climbing;
- release → fall → impact damage, safe/low release, floor behaviour;
- bot autopilot: the ring point, steering, landing time, cooldown;
- pose: the sign convention and the rider's back point at a known pitch/roll;
- property tests: no non-finite state, angle wrap, speed clamps.

**Reference harness**

- install the `__flight` global in `Harness::start`;
- the existing scene tests drive the flight through `goat.js`/`bots.js`; the
  assertions are the same as `FLIGHT.md` §9;
- a direct crate test covers the maths without the scene. The scene test is now
  an *integration* test, which is the part the crate cannot cover.

**Godot**

- `verify_flight.gd` calls the `Flight` class directly for the maths and the pose;
- `verify_goat.gd`'s tape includes a flight run and compares the GDScript
  integration;
- `verify_herd.gd`, `verify_peers.gd`, `verify_net.gd`, `verify_mod_surface.gd`
  and `interop.sh pair` as in `FLIGHT.md` §9;
- the `verify_goat.gd` oracle can use the same `Flight` class (or the Rust
  crate through the extension) instead of a second JS transcription. The gate
  then checks the *integration* on both sides; the crate's own tests check the
  maths. That is a stronger split than two transcriptions agreeing by accident.

---

## 9. Revised slices

The gameplay slices in `FLIGHT.md` §7 become:

| Slice | Work | Test |
| --- | --- | --- |
| **R0** ✅ | `crates/flight`: config, state, step, fall, damage, pose, bot input, tests | `cargo test -p flight` — landed, 35 + doctest |
| **R1** ✅ | `crates/flight-js` + install in client/server/harness; `goat.js` flight branch; `model.js` pose; `core.js` tuning | `crates/harness/tests/flight.rs` — landed, 40 cases |
| **R2** ✅ | `crates/godot/src/flight.rs` class + `main.gd` wiring; `player_goat.gd` flight branch; `tuning.gd` leaves | `verify_flight.gd`, the `verify_goat.gd` flight tape, `verify_pose.gd` |
| **R3** ✅ | bot flight branch and autopilot in both clients; hop take-off, airborne guards, death in the air | `verify_bots.gd`, the herd section of `crates/harness/tests/flight.rs` |
| **R4** ✅ | the API surface, tuning tree, wire, mod, HUD, touch | as `FLIGHT.md` §9: the flight probe in `verify_mod_surface.gd`, the flyer basis in `verify_herd.gd`/`verify_peers.gd`, the wire fields in `verify_net.gd`, the DROP button in `touch.rs`, and `crates/harness/tests/birds.rs` for the mod |
| **R5** ✅ | joiners: `goats.peers`, the peer seat, the rider map, the local grant edge | the peer cases in `crates/harness/tests/birds.rs`, `verify_mod_surface.gd`'s `peers.list`, and `verify_peers.gd`'s mod row |

R0 is pure Rust and can land first with no client changes. R1 and R2 can land in
either order; the gameplay contract is identical. R4 is the same work as the
original plan — the crate does not change the mod or the wire.

---

## 10. What this costs, and what it does not change

**Changes**

- one new workspace crate and two thin bindings;
- the flight maths has one home, and the `FLIGHT.md` §3 rules become the crate's
  tests rather than two transcriptions;
- the JS scene is no longer the specification for flight; the crate and its
  tests are. That is the price of sharing, and it is a *new* system, so it does
  not disturb the existing "JS is the spec" rule for gaits, weather, bots, etc.
- the reference's realm gains an internal `__flight` global. The port's mod
  realm does not.

**Does not change**

- the player experience or controls;
- the mod's capture/ride/release logic;
- the API names, the net fields or the protocol bump;
- the core's existing movement, AI, rendering, weather, water or terrain.

**Risks**

- a per-flyer cross-language step; bounded above and easy to batch later;
- the terrain callback is the one re-entry; two alternatives are recorded;
- `f32` at the boundary (the wire is quantized anyway);
- a new Rust crate in the build for both clients — but both already build
  Rust, and the crate has no engine deps;
- the `__flight` name is visible in the reference realm; it is internal and
  documented as such, and the port's mod context is clean.

---

## 11. Recommendation

**Yes, if one implementation matters more than the smallest diff.** The crate
is the right home for the flight model, fall damage, the bot autopilot, the
pose maths and the tuning defaults, because those are exactly the parts that
would otherwise be transcribed twice and drift. The integration is still two
small pieces of client code — input, modes, stats, net, draw — which is
unavoidable and is the easier half to review.

**No, if the priority is "the smallest possible core change".** Inline JS +
GDScript is a smaller diff, but it is two implementations of the subtlest part
of the feature, and the port's own history says that is where the bugs live.

My recommendation is the crate, with the boundary in §2: put the mechanics in
Rust, keep the world in the clients.

If this direction is chosen, `FLIGHT.md` §7 should be rewritten to the R0–R4
slices above and §2 should point at `crates/flight`; the gameplay sections stay
as they are.

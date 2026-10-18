# A write-barrier miss in the pinned nursery collector

**Status:** fixed upstream in `f491e69a00b5d8f5275a4770cc53e01e0d6590d5`
("fix(gc): record the composite shape's write barrier"), and the goats pin is
bumped to it. The reproducer -- the portal module, whose evaluation used to trip
the verifier -- now passes on the new revision, as does the full gate. The root
cause was `436607f97fcbe0942e2c5601c6d5946b3c00a7e8` (`perf(crux): cache the
whole object-literal shape`): its new composite transition cache stored a young
shape in a possibly-old map without a write barrier. The fix adds the missing
`write_barrier_handle` call in `Map::set_composite_child`. Re-pinning backwards
was not an option: `e5329a7` predates the regressing commit but drops the wasm
stack-top fix along with hundreds of other commits.

**Claim.** Evaluating the goats scene and stepping the headless world once with
the fixture mods loaded trips the debug-only write-barrier verifier. An old
`crux::map::Map` holds a young `crux::map::Map` whose edge was never recorded.
The scene is ordinary JavaScript; the finding is sizing-sensitive, which is
consistent with a transition edge lost during a minor collection rather than a
missing barrier at one named call site.

Native debug builds only: `VERIFY_BARRIER` starts at `cfg!(debug_assertions)`
(`crates/crux/src/heap.rs:1099`), so release builds never run the verifier.

## Reproduction

Inside the goats repository at `main` (the only change is a block of top-level
JavaScript appended to the scene; nothing calls it): append exactly the module at
the end of this report to `crates/goats/src/game/net.js`, then:

```sh
cargo test -p server --bin goatsd \
  headless::tests::the_birds_fixture_loads_and_both_datagrams_fit \
  -- --test-threads=1
```

### Observed

```
thread 'headless::tests::the_birds_fixture_loads_and_both_datagrams_fit' panicked at
C:\Users\T\.cargo\git\checkouts\slag-33701fe2ffda1054\0851f84\crates\crux\src\heap.rs:2804:9:
write-barrier miss: 1 old box(es) hold a young reference the barrier never recorded
(0 imprecise entries); offenders: [("crux::map::Map", "crux::map::Map")]
```

The stack shows the detection is on the first minor collection after scene
evaluation, inside a frame step:

```
crux::heap::Heap::verify_barrier            heap.rs:2804
crux::heap::Heap::collect_minor_inner       heap.rs:2174
crux::heap::Heap::collect_minor_with_stack  heap.rs:2155
runtime::agent::Agent::maybe_collect        runtime/agent.rs:2615
runtime::agent::Agent::run_jobs_inner       runtime/agent.rs:1902
runtime::embed::Context::call               runtime/embed.rs:565
goatsd::headless::Sim::step                 crates/server/src/headless.rs:130
```

The last scene log line before the panic is the birds mod finishing its models:

```
[scene] [mod:com.github.sdgoij.goats.birds] birds: models 1004/1005/1006 tex 0
```

### Control and regression commit

The same scene and the same test pass on the older `e5329a7`, which is an
**ancestor** of the pin (the local clone's refs are stale; the commit is
`e5329a7` in the cargo checkout's history). The regression arrived with
`436607f` (`perf(crux): cache the whole object-literal shape`), which added
`Map::composite` and `Map::set_composite_child`. `Map::trace` visits the cache
(`crates/crux/src/map.rs:125`), and the insert does not call the barrier:

```rust
pub fn set_composite_child(&mut self, names: &[AtomId], child: Handle<Map>) {
    const COMPOSITE_CAP: usize = 1024;
    if self.composite.len() < COMPOSITE_CAP {
        self.composite.insert(names.into(), child);
    }
}
```

That is the old-map → young-map edge the verifier reports. The transition table
already does this correctly (`crates/crux/src/map.rs:219`, `:248`):

```rust
crate::heap::write_barrier_handle(self, child);
self.transitions.insert((key, attrs), child);
```

### Verified fix

Adding the same line to `set_composite_child` makes the reproducer pass on the
pinned revision (no other change):

```diff
     pub fn set_composite_child(&mut self, names: &[AtomId], child: Handle<Map>) {
         const COMPOSITE_CAP: usize = 1024;
         if self.composite.len() < COMPOSITE_CAP {
+            crate::heap::write_barrier_handle(self, child);
             self.composite.insert(names.into(), child);
         }
     }
```

Upstream shipped exactly this in `f491e69`. With the pin bumped, the reproducer
(`cargo test -p server --bin goatsd
headless::tests::the_birds_fixture_loads_and_both_datagrams_fit --
--test-threads=1`) is green with the portal module restored. A regression test
for it would need to force a minor collection while the verifier is on after
populating the composite cache from a map that has been promoted; the commit's
own test populates the cache but never collects.

## What is and is not the trigger

Measured on the pinned rev, all with the same test and the same command. The
base scene is `main` plus the swarm additions in `net.js`.

| added at the end of `net.js` | result |
| --- | --- |
| nothing | pass |
| 20 trivial top-level `function probeN() { return 1; }` | pass |
| 6 scalar constants + one trivial function | pass |
| a minimal IIFE: one captured `let` + 3 nested functions + returned object | pass |
| the portal module at the end of this report | **fail** |

The failure is therefore not a particular syntax construct and not simply the
number of new globals. Moving the module to the *top* of `core.js` (before the
rest of the scene evaluates) still fails, so it is not "late creation either".
What reproduces is the module's overall allocation shape during scene evaluation;
the verifier then finds the missed edge on the first minor.

## Where to look

- `crates/crux/src/heap.rs:2765` (`verify_barrier`) asserts on an old box with a
  young child and `is_remembered() == false`.
- The offender is a `Map` holding a `Map`: a `Map::transitions` value or a
  `back_pointer`.
- Both insertion sites do call the barrier:
  `crates/crux/src/map.rs:219` and `crates/crux/src/map.rs:248`
  (`write_barrier_handle(self, child)` immediately before
  `self.transitions.insert(...)`).
- The object's own map transition is barriered too (`crates/crux/src/object.rs:3588`).
- `remember_if_young` (`crates/crux/src/heap.rs:1164`) returns early when the
  target is young, and marks and remembers otherwise; a target that is young at
  barrier time and promoted before its child is reached would need the child
  traced during that same promotion. That is the shape the verifier reports.

Nothing in the scene depends on the missing edge being tolerated; the report is
that the verifier is correct and the pin fails it.

## Reproducing code

Append to `crates/goats/src/game/net.js`. None of it is called by the failing
test; evaluation is the whole trigger.

```js
// ---- portals ---------------------------------------------------------------
//
// A host found in the swarm is a ring standing in the meadow. The position is
// derived from the session ticket rather than assigned by a server, so every
// player computes the same place for the same host, and the registry -- which is
// now a gossip topic and owns no world -- never has to hand out coordinates.
// Walking into the ring joins it.
//
// Portals exist only while this client is offline. A session refuses a second
// join (`leave first`), and a ring that cannot do anything is worse than none, so
// both the drawing and the proximity check are gated on `netInSession`.

// The portal implementation is one module object rather than a dozen top-level
// names.
const PORTALS = (function () {
    const DRAWN = 8;        // rings drawn: the nearest, so a long list stays cheap
    const SEGMENTS = 24;    // beads in a ring
    const RADIUS = 1.25;    // ring radius, metres
    const MIDDLE = 1.45;    // ring centre above the ground
    const REACH = 1.6;      // how close the goat has to be to fall in

    // The ticket whose ring the goat is standing in.
    let inside = "";

    // FNV-1a.
    function hash(text) {
        let value = 2166136261 >>> 0;
        for (let i = 0; i < text.length; i++) {
            value ^= text.charCodeAt(i);
            value = Math.imul(value, 16777619) >>> 0;
        }
        return value >>> 0;
    }

    // Where a host's ring stands.
    function placement(ticket) {
        const angle = (hash(ticket) / 4294967296) * Math.PI * 2;
        const spread = (hash(ticket + "#radius") % 1000) / 1000;
        const radius = 20 + spread * 10;
        return {
            x: Math.cos(angle) * radius,
            z: Math.sin(angle) * radius,
            tangentX: -Math.sin(angle),
            tangentZ: Math.cos(angle)
        };
    }

    // The nearest few hosts, in distance order.
    function nearest() {
        const list = [];
        for (let i = 0; i < netHosts.length; i++) {
            const host = netHosts[i];
            const place = placement(host.ticket);
            const dx = place.x - goat.px;
            const dz = place.z - goat.pz;
            list.push({ host: host, place: place, d2: dx * dx + dz * dz });
        }
        list.sort(function (a, b) { return a.d2 - b.d2; });
        return list.slice(0, DRAWN);
    }

    function draw() {
        if (netInSession() || netHosts.length === 0) return;
        const list = nearest();
        const pulse = 0.75 + 0.25 * Math.sin(sceneFrames * 0.05);
        const haze = rl.color(90, 220, 255, Math.round(30 + 26 * pulse));
        const glow = rl.color(170, 250, 255, Math.round(190 + 55 * pulse));
        for (let i = 0; i < list.length; i++) {
            const place = list[i].place;
            const base = terrainHeight(place.x, place.z);
            for (let j = 0; j < SEGMENTS; j++) {
                const t = (j / SEGMENTS) * Math.PI * 2;
                const along = Math.cos(t) * RADIUS;
                const up = Math.sin(t) * RADIUS;
                const px = place.x + place.tangentX * along;
                const pz = place.z + place.tangentZ * along;
                const py = base + MIDDLE + up;
                rl.drawSphereEx(px, py, pz, 0.26, 4, 6, haze);
                rl.drawSphereEx(px, py, pz, 0.11, 4, 6, glow);
            }
        }
    }

    // World point to screen pixels, matching the 55-degree `beginMode3D` pass.
    function project(x, y, z, ex, ey, ez, tx, ty, tz) {
        let bx = ex - tx;
        let by = ey - ty;
        let bz = ez - tz;
        const back = Math.hypot(bx, by, bz);
        if (back < 0.000001) return null;
        bx /= back;
        by /= back;
        bz /= back;
        let rx = bz;
        let rz = -bx;
        const right = Math.hypot(rx, rz);
        if (right < 0.000001) return null;
        rx /= right;
        rz /= right;
        const ux = by * rz;
        const uy = bz * rx - bx * rz;
        const uz = -by * rx;

        const vx = x - ex;
        const vy = y - ey;
        const vz = z - ez;
        const viewX = vx * rx + vz * rz;
        const viewY = vx * ux + vy * uy + vz * uz;
        const depth = -(vx * bx + vy * by + vz * bz);
        if (depth <= 0.05) return null;

        const aspect = screenW / screenH;
        const f = 1 / Math.tan((55 * Math.PI / 180) * 0.5);
        const nx = ((f / aspect) * viewX) / depth;
        const ny = (f * viewY) / depth;
        if (nx < -1.4 || nx > 1.4 || ny < -1.4 || ny > 1.4) return null;
        return {
            x: Math.round((nx * 0.5 + 0.5) * screenW),
            y: Math.round((0.5 - ny * 0.5) * screenH)
        };
    }

    // The host's name above each ring.
    function labels(ex, ey, ez, tx, ty, tz) {
        if (netInSession() || netHosts.length === 0) return;
        const list = nearest();
        for (let i = 0; i < list.length; i++) {
            const host = list[i].host;
            const place = list[i].place;
            const top = terrainHeight(place.x, place.z) + MIDDLE + RADIUS + 0.35;
            const point = project(place.x, top, place.z, ex, ey, ez, tx, ty, tz);
            if (point === null) continue;
            const text = host.name + (host.clients > 1 ? "  ·  " + host.clients + " goats" : "");
            const size = 18;
            const width = text.length * size * 0.5;
            const left = Math.round(point.x - width / 2);
            const line = Math.round(point.y - size / 2);
            rl.drawRectangle(left - 7, line - 4, width + 14, size + 8, rl.color(8, 12, 16, 170));
            rl.drawText(text, left, line, size, rl.color(190, 248, 255, 240));
        }
    }

    // Walking into a ring joins that host.
    function step() {
        if (netInSession() || netJoining || uiIsOpen() || mode === "dead") return;
        let found = null;
        for (let i = 0; i < netHosts.length; i++) {
            const place = placement(netHosts[i].ticket);
            const dx = place.x - goat.px;
            const dz = place.z - goat.pz;
            if (dx * dx + dz * dz <= REACH * REACH) {
                found = netHosts[i];
                break;
            }
        }
        if (found === null) {
            inside = "";
            return;
        }
        if (inside === found.ticket) return;
        inside = found.ticket;
        netJoin(["connect", found.ticket, netJoinName === "" ? "goat" : netJoinName]);
    }

    return { placement: placement, draw: draw, labels: labels, step: step };
})();
```

`netHosts`, `netJoining`, `netJoinName`, `sceneFrames`, `goat`, `rl`,
`terrainHeight` and `uiIsOpen` are all scene globals; `step()` is never reached in
the failing test.

## Resolution

The fix was pushed as `f491e69a00b5d8f5275a4770cc53e01e0d6590d5` and the goats
pin now names it. The portal module is back in `crates/goats/src/game/net.js`,
where the reproducer lives, and the birds fixture test is green on the new
revision. A regression test that pins the barrier itself belongs in Slag; the
commit's own test populates the composite cache but never collects, which is why
the verifier found this only through an application's allocation shape.

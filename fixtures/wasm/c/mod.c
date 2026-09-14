// The `wasm` fixture mod: a mod that ships only a compiled module.
//
// The point of the fixture is the shape of the boundary, not what it computes.
// `APIv1.md` section 0 says a mod gets no filesystem, no path and no socket; a
// wasm module has no ambient authority at all, so the only things it can reach
// are the imports the host handed it at instantiation -- `goats.log`, `goats.rng`
// and (for a world mod) `goats.publish`, nothing else. The host instantiates it,
// hands it a buffer of records once a frame, and reads the results back out of
// its memory.
//
// Two things are deliberately *not* in this file, and both are the ABI's doing:
//
//   - no clock. There is no time import, so a mod that wanted to read wall time
//     could not link. That is what makes a world mod's simulation reproducible.
//   - no trigonometry. Core wasm has no `sin`/`cos`, so the wander below nudges
//     a velocity from a host draw and integrates it. A mod that wants angles
//     brings its own, or imports them from the host and takes the determinism
//     consequences.
//
// The record's 16-byte layout is the ABI's; what the four floats *mean* is this
// mod's business, and the host neither seeds nor interprets them. The driver
// does seed them, because a mod with no state would have nothing to show.
//
// Build: `fixtures/wasm/build.sh`. The artifact is checked in.

#ifndef ABI_VERSION
#define ABI_VERSION 1
#endif

// The client-side visual surface is optional and compiled in by default; a
// `world.wasm` build turns it off, because `goats.belly` is a client-local
// reading a world mod must not be able to import (see ABIv1.md 3.3).
#ifndef WANT_HUD
#define WANT_HUD 1
#endif

typedef signed int i32;
typedef unsigned char u8;

// The host's capabilities. The import list *is* the API: a module that asks for
// anything else fails to link rather than being policed.
__attribute__((import_module("goats"), import_name("log")))
extern void goats_log(const char *ptr, i32 len);

__attribute__((import_module("goats"), import_name("rng")))
extern double goats_rng(i32 stream);

// The world-mod state surface (M17c2): a world module pushes its state to the
// host once a frame, and a mirroring module receives a peer's state through the
// `goats_apply` export below. The bytes are opaque to the host, which only moves
// them -- the same rule that already governs the records.
__attribute__((import_module("goats"), import_name("publish")))
extern i32 goats_publish(const char *ptr, i32 len);

#if WANT_HUD
// The client-side visual surface: the host provides the player's belly fullness
// (0..1) and this module keeps its own "digesting" model of it, which the host
// reads back through `goats_hud` and draws on the HUD. The import is granted to
// `side: "client"` mods only, so a world mod that asks for it fails to link.
__attribute__((import_module("goats"), import_name("belly")))
extern double goats_belly(void);

static double hud_fill = 0.0;
static double hud_phase = 0.0;

// One-pole chase toward `target`; `rate` is per-second. Core wasm has no
// `sin`/`cos`, so the visible "digestion" ripple below is a triangle wave from
// this module's own phase rather than a trig import.
static double approach(double current, double target, double rate, double dt) {
    const double k = 1.0 - rate * dt;
    if (k < 0.0) {
        return target;
    }
    return target + (current - target) * k;
}
#endif

// A bump arena, so the host can be handed a buffer without either side owning an
// allocator protocol. 4 KiB covers this fixture; a real mod brings its own.
static u8 arena[4096];
static i32 used = 0;

// How many times the host has delivered a peer's state through `goats_apply`.
static i32 applied = 0;

// One record, 16 bytes: `x | z | yaw | vx`. This mod reads all four and writes
// all four, and the host only moves the bytes.
typedef struct {
    float x;
    float z;
    float yaw;
    float vx;
} Record;

static i32 text_len(const char *text) {
    i32 n = 0;
    while (text[n] != 0) {
        n += 1;
    }
    return n;
}

__attribute__((export_name("goats_abi")))
i32 goats_abi(void) {
    return ABI_VERSION;
}

__attribute__((export_name("goats_alloc")))
void *goats_alloc(i32 len) {
    const i32 start = used;
    used += len;
    return (void *)(arena + start);
}

__attribute__((export_name("goats_init")))
i32 goats_init(i32 seed) {
    (void)seed;
    const char *hello = "wasm mod: ready";
    goats_log(hello, text_len(hello));
    return 0;
}

// The coarse crossing: one call a frame, `count` records in this module's own
// memory. Each record wanders -- one host draw nudges its velocity, the velocity
// moves it -- so the module is doing real, host-seeded work and the host can see
// the result without asking it anything.
//
// The draw order is part of the contract: one call to `goats_rng(i)` per record,
// ascending, so a peer that runs the same module draws the same stream.
__attribute__((export_name("goats_update")))
i32 goats_update(Record *records, i32 count, float dt) {
    const double d = (double)dt;
    for (i32 i = 0; i < count; i += 1) {
        const double nudge = (goats_rng(i) - 0.5) * 2.0;
        double vx = (double)records[i].vx + nudge * d;
        if (vx > 4.0) {
            vx = 4.0;
        }
        if (vx < -4.0) {
            vx = -4.0;
        }
        records[i].vx = (float)vx;
        records[i].x = (float)((double)records[i].x + vx * d);
        records[i].yaw = (float)((double)records[i].yaw + d);
        records[i].z = (float)((double)records[i].z + (double)records[i].yaw * d * 0.25);
    }
#if WANT_HUD
    // The host's reading this frame, then this module's own "digestion" model:
    // chase the belly with a slow, deterministic ripple layered onto the target,
    // so the bar visibly breathes rather than echoing the host. The ripple sits
    // on the target (not the clamped output), so the one-pole chase filters it
    // instead of fighting the clamp. Client-side only, so the phase never needs
    // to be reproducible across peers.
    hud_phase += d * 0.5;
    if (hud_phase >= 1.0) {
        hud_phase -= 1.0;
    }
    const double tri = hud_phase < 0.5 ? hud_phase * 2.0 : 2.0 - hud_phase * 2.0;
    const double target = goats_belly() + (tri * 2.0 - 1.0) * 0.08;
    hud_fill = approach(hud_fill, target, 3.0, d);
    if (hud_fill < 0.0) {
        hud_fill = 0.0;
    }
    if (hud_fill > 1.0) {
        hud_fill = 1.0;
    }
#endif
    // A world mod publishes what it computed, so a peer can mirror it. The
    // host copies these bytes rather than reading them back itself: what ships
    // is exactly what the mod asked to ship, not what the host happened to read.
    (void)goats_publish((const char *)records, count * (i32)sizeof(Record));
    return count;
}

// The host has written a peer's records into this module's record buffer and
// calls here to say so. The state is already in place; a real mod would rebuild
// anything derived from it (a mesh, a sound) before the next draw. `len` is the
// byte length, so the record count is `len / 16`. A mirroring client never runs
// `goats_update`, so this is the whole of how its state changes.
__attribute__((export_name("goats_apply")))
i32 goats_apply(const Record *records, i32 len) {
    (void)records;
    applied += 1;
    return len;
}

// How many times `goats_apply` has run, so the host and the test can observe
// that a delivery happened rather than infer it.
__attribute__((export_name("goats_applies")))
i32 goats_applies(void) {
    return applied;
}

#if WANT_HUD
// The per-frame HUD contribution: the bar fill (0..1) this module computed in
// `goats_update`. Optional -- a module without it contributes nothing to the HUD.
__attribute__((export_name("goats_hud")))
double goats_hud(void) {
    return hud_fill;
}
#endif

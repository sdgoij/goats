// The `wasm` fixture mod: a mod that ships only a compiled module.
//
// The point of the fixture is the shape of the boundary, not what it computes.
// `APIv1.md` section 0 says a mod gets no filesystem, no path and no socket; a
// wasm module has no ambient authority at all, so the only things it can reach
// are the imports the host handed it at instantiation -- here `goats.log` and
// `goats.rng`, nothing else. The host instantiates it, hands it a buffer of
// records once a frame, and reads the results back out of its memory.
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

typedef signed int i32;
typedef unsigned char u8;

// The host's capabilities. The import list *is* the API: a module that asks for
// anything else fails to link rather than being policed.
__attribute__((import_module("goats"), import_name("log")))
extern void goats_log(const char *ptr, i32 len);

__attribute__((import_module("goats"), import_name("rng")))
extern double goats_rng(i32 stream);

// A bump arena, so the host can be handed a buffer without either side owning an
// allocator protocol. 4 KiB covers this fixture; a real mod brings its own.
static u8 arena[4096];
static i32 used = 0;

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
    return count;
}

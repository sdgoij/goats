// The plugin ABI v1, written in C -- one of the two reference fixtures.
//
// Why two languages: the ABI exists so a mod author is not forced into
// JavaScript. If only the language the host happens to be written in can target
// it conveniently, the ABI has failed at its one job. So it is defined once and
// built here from two toolchains that share nothing but the wasm specification.
//
// This file is deliberately core wasm: no libc, no WASI, no GC, no exception
// handling. Those are the things a toolchain may need; an ABI that required them
// would exclude much of what compiles to wasm, and linking no WASI is what makes
// the I/O wall structural -- a plugin that tries to open a file fails to link
// instead of being policed.
//
// Build: see ../build.sh.

// Scalars are i32/f32/f64 only, deliberately. An i64 parameter would force a
// BigInt on a JS host and awkward bindings in several non-Rust toolchains --
// found the hard way, by the fixture failing to call it.
#define ABI_VERSION 1

typedef signed int i32;
typedef unsigned char u8;

// --- the host's capabilities, imported under one namespace ------------------
//
// The import list *is* the API. A plugin has no ambient authority: everything it
// can do is one of these, granted by the host at instantiation. There is no
// clock import on purpose -- a world mod that cannot read wall time cannot
// desync, and that rule is then enforced by the linker rather than by review.

__attribute__((import_module("goats"), import_name("log")))
extern void goats_log(const char *ptr, i32 len);

__attribute__((import_module("goats"), import_name("rng")))
extern double goats_rng(i32 stream);

__attribute__((import_module("goats"), import_name("publish")))
extern i32 goats_publish(const char *ptr, i32 len);

// --- module state ----------------------------------------------------------

// A bump arena, so the host can hand the plugin a buffer to work in without
// either side owning an allocator protocol. 8 KiB is this fixture's whole
// footprint; a real plugin brings its own allocator.
static u8 arena[8192];
static i32 used = 0;

// One entity, 16 bytes. The layout is part of the ABI: the host writes these in
// and reads them back out, so both sides agree on the offsets.
typedef struct {
    float x;
    float z;
    float yaw;
    float vx;
} Entity;

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
    i32 start = used;
    used += len;
    return (void *)(arena + start);
}

__attribute__((export_name("goats_init")))
i32 goats_init(i32 seed) {
    (void)seed;
    const char *hello = "plugin-c: ready";
    goats_log(hello, text_len(hello));
    return 0;
}

// The coarse crossing: one call per frame carrying `count` records in the
// module's own memory, with the host reading the results back out of it. The
// arithmetic is spelled out because a world mod's math is part of the
// compatibility set, not an implementation detail -- `vx' = f32(f64(vx) +
// rng(i) * f64(dt))`, one draw per record, ascending.
__attribute__((export_name("goats_update")))
i32 goats_update(Entity *entities, i32 count, float dt) {
    for (i32 i = 0; i < count; i += 1) {
        double r = goats_rng(i);
        entities[i].vx = (float)((double)entities[i].vx + r * (double)dt);
    }
    // Publish what it computed, so a peer receives the same bytes a host read
    // back. The bytes are opaque to the host; it only moves them.
    (void)goats_publish((const char *)entities, count * (i32)sizeof(Entity));
    return count;
}

// The host has written a peer's records into this module's memory and calls here
// so the module adopts them. The reference fixture has no derived state to
// rebuild, so it reports how many bytes it took and nothing else.
__attribute__((export_name("goats_apply")))
i32 goats_apply(const Entity *entities, i32 len) {
    (void)entities;
    return len;
}

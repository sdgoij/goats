//! The plugin ABI v1, written in Rust -- the second reference fixture.
//!
//! It implements exactly the same ABI as `c/plugin.c`, in a toolchain that
//! shares nothing with it but the wasm specification. If the two disagree on a
//! single byte, the ABI is under-specified and a mod author in a third language
//! would hit the same ambiguity. The test in `crates/harness/tests/plugin_abi.rs`
//! runs both and requires the same numbers.
//!
//! Deliberately core wasm: `wasm32-unknown-unknown`, no WASI, no GC, no
//! exceptions. See the C fixture for the reasoning.
//!
//! Build: see `../build.sh`.

// Scalars are i32/f32/f64 only, deliberately: an i64 parameter forces a BigInt
// on a JS host and awkward bindings elsewhere. The fixture found that by failing.
const ABI_VERSION: i32 = 1;

// The host's capabilities, imported under one namespace. There is no clock here
// on purpose: a world mod that cannot read wall time cannot desync.
#[link(wasm_import_module = "goats")]
extern "C" {
    fn log(ptr: *const u8, len: i32);
    fn rng(stream: i32) -> f64;
    fn publish(ptr: *const u8, len: i32) -> i32;
}

/// A bump arena, so the host can hand the plugin a buffer without either side
/// owning an allocator protocol.
const ARENA_LEN: usize = 8192;
static mut ARENA: [u8; ARENA_LEN] = [0; ARENA_LEN];
static mut USED: i32 = 0;

/// One entity, 16 bytes. The layout is part of the ABI, so both sides agree on
/// the offsets whatever language wrote the module.
#[repr(C)]
pub struct Entity {
    pub x: f32,
    pub z: f32,
    pub yaw: f32,
    pub vx: f32,
}

#[no_mangle]
pub extern "C" fn goats_abi() -> i32 {
    ABI_VERSION
}

/// Returns a buffer of `len` bytes in this module's memory, which the host then
/// writes and reads directly.
///
/// # Safety
///
/// It hands out a pointer into a fixed 8 KiB arena with no bounds check, and
/// no alignment guarantee beyond the arena's own. The host is trusted to size
/// the request; a real plugin would bring a real allocator.
#[no_mangle]
pub unsafe extern "C" fn goats_alloc(len: i32) -> *mut u8 {
    let start = USED;
    USED += len;
    (&raw mut ARENA).cast::<u8>().add(start as usize)
}

#[no_mangle]
pub extern "C" fn goats_init(_seed: i32) -> i32 {
    const HELLO: &[u8] = b"plugin-rust: ready";
    unsafe { log(HELLO.as_ptr(), HELLO.len() as i32) };
    0
}

/// The coarse crossing: one call per frame carrying `count` records in this
/// module's own memory. `vx' = f32(f64(vx) + rng(i) * f64(dt))`, one draw per
/// record, ascending -- the same arithmetic, in the same order, as the C
/// fixture.
///
/// # Safety
///
/// `entities` must point at `count` valid, 16-byte, `repr(C)` records in this
/// module's memory; the ABI specifies that the host allocates them through
/// `goats_alloc`, so a correct host cannot get this wrong.
#[no_mangle]
pub unsafe extern "C" fn goats_update(entities: *mut Entity, count: i32, dt: f32) -> i32 {
    for i in 0..count {
        let r = rng(i);
        let entity = &mut *entities.add(i as usize);
        entity.vx = (f64::from(entity.vx) + r * f64::from(dt)) as f32;
    }
    // Publish what it computed, so a peer receives the same bytes a host read
    // back. One Entity is 16 bytes; the bytes are opaque to the host.
    let _ = publish(entities as *const u8, count * 16);
    count
}

/// The host has written a peer's records into this module's memory and calls
/// here so the module adopts them. The reference fixture has no derived state to
/// rebuild, so it reports how many bytes it took and nothing else.
///
/// # Safety
/// `ptr` points at `len` valid bytes in this module's memory, written by the
/// host through `goats_alloc` before the call.
#[no_mangle]
pub unsafe extern "C" fn goats_apply(_ptr: *const u8, len: i32) -> i32 {
    len
}

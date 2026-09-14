//! The plugin-ABI proof: one ABI, two `.wasm` fixtures, two toolchains that
//! share nothing but the wasm specification.
//!
//! This exists to answer one question before any of M17 is designed in earnest:
//! can an ABI be written that is *not* shaped like Rust? `fixtures/wasm/c/` and
//! `fixtures/wasm/rust/` implement the same plugin ABI (see `ABIv1.md`),
//! and this test loads both through the engine and requires the same numbers out
//! of them. If only one language can conveniently target the surface, the ABI has
//! failed at the job the whole idea exists for -- letting a mod author write in
//! whatever language they like.
//!
//! It uses Slag's `Context` directly rather than the scene harness: this is an
//! engine-level boundary, and it will move to the plugin host crate when M17a
//! lands. The host side here is a JS stub standing in for the Rust host, which
//! is exactly the shape a plugin sees either way -- the import list is the API.
//!
//! The fixtures are checked in (they are a few hundred bytes) so neither this
//! test nor CI needs a wasm toolchain; `fixtures/wasm/build.sh` rebuilds them.

use std::path::{Path, PathBuf};

use slag::Context;

/// The host stub, in JS, standing in for the eventual Rust host.
///
/// It exercises every part of the boundary that matters: the module's declared
/// imports (the capability list), a capability the host implements (`rng`, a
/// stateful per-stream generator, so the *draw order* is part of the test), a
/// capability that reads a string out of the module's own memory (`log`), and
/// the coarse crossing -- the host writes a record array into the module's
/// memory once, calls `goats_update` once, and reads the results back out.
const HOST_STUB: &str = r#"
const bytes = new Uint8Array(PLUGIN_BYTES);
const mod = new WebAssembly.Module(bytes);

const logs = [];
const state = {};
function rng(stream) {
  let s = state[stream];
  if (s === undefined) { s = (12345 + stream * 7919) % 2147483647; }
  s = (s * 48271) % 2147483647;
  state[stream] = s;
  return s / 2147483647;
}

let instance;
function readString(ptr, len) {
  const mem = new Uint8Array(instance.exports.memory.buffer);
  let out = '';
  for (let i = 0; i < len; i++) { out += String.fromCharCode(mem[ptr + i]); }
  return out;
}

instance = new WebAssembly.Instance(mod, {
  goats: {
    log: function (ptr, len) { logs.push(readString(ptr, len)); },
    rng: rng,
  },
});

const e = instance.exports;
const abi = e.goats_abi();
const init = e.goats_init(42);

// 16 bytes a record (x, z, yaw, vx); the arena is word aligned, so one view of
// the whole memory is enough and no growth happens.
const COUNT = 4;
const ptr = e.goats_alloc(COUNT * 16);
const f32 = new Float32Array(e.memory.buffer);
const base = ptr / 4;
for (let i = 0; i < COUNT; i++) {
  f32[base + i * 4 + 0] = 1.5 + i;
  f32[base + i * 4 + 1] = -2.0 - i;
  f32[base + i * 4 + 2] = 0.25;
  f32[base + i * 4 + 3] = 0;
}
const updated = e.goats_update(ptr, COUNT, 0.5);
const vx = [];
for (let i = 0; i < COUNT; i++) { vx.push(f32[base + i * 4 + 3]); }

JSON.stringify({
  abi: abi,
  init: init,
  updated: updated,
  imports: WebAssembly.Module.imports(mod).map(function (i) { return i.module + '.' + i.name; }),
  log: logs,
  vx: vx,
});
"#;

/// The version both fixtures must report. A mod's ABI version joins its digest,
/// so a fixture that drifts is caught by a test rather than by a refused join.
const ABI_VERSION: i64 = 1;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("fixtures")
        .join("wasm")
        .join(format!("{name}.wasm"))
}

/// Load one fixture through Slag and run the host stub, returning what it saw.
fn run_fixture(name: &str) -> serde_json::Value {
    let path = fixture(name);
    let bytes =
        std::fs::read(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));

    let mut context = Context::new().expect("a Slag context");
    // The module crosses as bytes, never a path -- the same rule APIv1 section 0
    // sets for every other asset.
    let buffer = context
        .array_buffer_from_bytes(&bytes)
        .expect("an ArrayBuffer for the module");
    context
        .set_global("PLUGIN_BYTES", buffer)
        .expect("set PLUGIN_BYTES");

    let value = context
        .eval(HOST_STUB)
        .unwrap_or_else(|error| panic!("{name}: the host stub failed: {error}"));
    let text = context
        .to_string(&value)
        .unwrap_or_else(|error| panic!("{name}: the stub did not return a string: {error}"));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{name}: the stub returned invalid JSON: {error}\n{text}"))
}

#[test]
fn a_c_plugin_and_a_rust_plugin_satisfy_the_same_abi() {
    let c = run_fixture("plugin-c");
    let rust = run_fixture("plugin-rust");

    // Both fixtures negotiate the same version.
    assert_eq!(c["abi"], ABI_VERSION, "the C fixture: {c}");
    assert_eq!(rust["abi"], ABI_VERSION, "the Rust fixture: {rust}");

    // The capability list is inspectable, which is what the Mods screen would
    // show and what a host grants from: two imports, nothing ambient.
    let expected = serde_json::json!(["goats.log", "goats.rng"]);
    assert_eq!(c["imports"], expected, "the C fixture's imports");
    assert_eq!(rust["imports"], expected, "the Rust fixture's imports");

    // Each fixture is really the module it claims to be -- the log is how the
    // host reads a string out of the module's own memory.
    assert_eq!(c["log"], serde_json::json!(["plugin-c: ready"]));
    assert_eq!(rust["log"], serde_json::json!(["plugin-rust: ready"]));

    // The crossing itself.
    assert_eq!(c["init"], 0);
    assert_eq!(rust["init"], 0);
    assert_eq!(c["updated"], 4, "goats_update returns the record count");
    assert_eq!(rust["updated"], 4);

    // The point of the whole fixture: the same arithmetic, in the same order,
    // with the same host-provided randomness, from two toolchains -- byte for
    // byte, because wasm's float semantics are strict.
    assert_eq!(
        c["vx"], rust["vx"],
        "the two languages disagree about the ABI's arithmetic"
    );
    let vx = c["vx"].as_array().expect("an array of f32").clone();
    assert_eq!(vx.len(), 4);
    assert!(
        vx.iter().all(|v| v.as_f64().is_some_and(|n| n > 0.0)),
        "the host's rng reached the module: {vx:?}"
    );
}

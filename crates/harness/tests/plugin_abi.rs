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
//! lands. The `goats` namespace is built twice -- once as JavaScript closures in
//! a driver stub, once as Rust native functions registered through the embedding
//! API -- because a capability's implementation language is not part of the ABI
//! either. In both, the import list is the API.
//!
//! The fixtures are checked in (they are a few hundred bytes) so neither this
//! test nor CI needs a wasm toolchain; `fixtures/wasm/build.sh` rebuilds them.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use slag::{Context, JsValue};

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
const published = [];
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
function readBytes(ptr, len) {
  const mem = new Uint8Array(instance.exports.memory.buffer);
  const out = [];
  for (let i = 0; i < len; i++) { out.push(mem[ptr + i]); }
  return out;
}

instance = new WebAssembly.Instance(mod, {
  goats: {
    log: function (ptr, len) { logs.push(readString(ptr, len)); },
    rng: rng,
    publish: function (ptr, len) { published.push(readBytes(ptr, len)); },
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

// The host hands the module a peer's state and calls goats_apply; the fixture
// returns the byte count it adopted.
const applied = e.goats_apply(ptr, COUNT * 16);

JSON.stringify({
  abi: abi,
  init: init,
  updated: updated,
  imports: WebAssembly.Module.imports(mod).map(function (i) { return i.module + '.' + i.name; }),
  log: logs,
  vx: vx,
  published: published[0],
  applied: applied,
});
"#;

/// The same driver, with the `goats` namespace supplied by the *host* as Rust
/// native functions (`GOATS_IMPORTS`) instead of by JavaScript closures. The
/// module cannot tell the difference, which is the point: the capability's
/// implementation language is not part of the ABI.
const NATIVE_HOST_STUB: &str = r#"
var MOD = new WebAssembly.Module(new Uint8Array(PLUGIN_BYTES));
var WB = new WebAssembly.Instance(MOD, { goats: GOATS_IMPORTS });
var e = WB.exports;

var abi = e.goats_abi();
var init = e.goats_init(42);

// The same records the JS-hosted stub writes, so the two runs are comparable.
const COUNT = 4;
var ptr = e.goats_alloc(COUNT * 16);
var f32 = new Float32Array(e.memory.buffer);
var base = ptr / 4;
for (var i = 0; i < COUNT; i++) {
  f32[base + i * 4 + 0] = 1.5 + i;
  f32[base + i * 4 + 1] = -2.0 - i;
  f32[base + i * 4 + 2] = 0.25;
  f32[base + i * 4 + 3] = 0;
}
var updated = e.goats_update(ptr, COUNT, 0.5);
var vx = [];
for (var i = 0; i < COUNT; i++) { vx.push(f32[base + i * 4 + 3]); }
var applied = e.goats_apply(ptr, COUNT * 16);

JSON.stringify({
  abi: abi,
  init: init,
  updated: updated,
  imports: WebAssembly.Module.imports(MOD).map(function (i) { return i.module + '.' + i.name; }),
  vx: vx,
  applied: applied,
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
    // show and what a host grants from: three imports, nothing ambient.
    let expected = serde_json::json!(["goats.log", "goats.rng", "goats.publish"]);
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

    // The world-mod state surface: both fixtures publish the same bytes for the
    // same host-provided randomness, which is what a peer actually receives --
    // the record layout and endianness are part of the ABI, not of the language.
    assert_eq!(
        c["published"], rust["published"],
        "the two languages publish different state"
    );
    let published = c["published"]
        .as_array()
        .expect("an array of bytes")
        .clone();
    assert_eq!(published.len(), 4 * 16, "4 records of 16 bytes");

    // And goats_apply accepts a peer's state the same way in both languages.
    assert_eq!(
        c["applied"],
        serde_json::json!(64),
        "the C fixture adopted the state"
    );
    assert_eq!(
        rust["applied"],
        serde_json::json!(64),
        "the Rust fixture adopted the state"
    );
}

/// The other side of the same claim: the *host's* implementation language is not
/// part of the ABI either. The `goats` namespace here is built in Rust --
/// `Context::create_function` closures over host state -- and the fixture must
/// behave exactly as it does when the namespace is JavaScript closures.
///
/// It also pins down the one rule that follows, which is about where the memory
/// is rather than about privileges: a capability that has to *read the plugin's
/// own memory* cannot be a plain native function, because the bytes are in the
/// module's linear memory and the host function only receives numbers. The
/// native `log` here therefore sees `(ptr, len)` and not the text, and the test
/// asserts exactly that. Decoding those bytes is the driver's job -- in this
/// path the driver holds the `memory.buffer`; in the Rust-hosted path (`Store`)
/// the host does.
#[test]
fn the_host_can_supply_the_capabilities_as_native_functions() {
    let reference = run_fixture("plugin-c");

    let path = fixture("plugin-c");
    let bytes =
        std::fs::read(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let mut context = Context::new().expect("a Slag context");
    let buffer = context
        .array_buffer_from_bytes(&bytes)
        .expect("an ArrayBuffer for the module");
    context
        .set_global("PLUGIN_BYTES", buffer)
        .expect("set PLUGIN_BYTES");

    // What the native `log` was handed: pointers and lengths, never the bytes.
    let seen = Rc::new(RefCell::new(Vec::<(f64, f64)>::new()));
    // What the native `publish` was handed: the same shape -- a pointer into the
    // module's memory and a length, never the bytes -- because a native host
    // cannot read that memory without owning the `Store`.
    let published = Rc::new(RefCell::new(Vec::<(f64, f64)>::new()));
    // The rng's state, owned by the host closure -- the same streams, in the same
    // order, that the JavaScript stub keeps in its own object.
    let streams = Rc::new(RefCell::new([0i64; 8]));

    let namespace = context.create_object().expect("the goats namespace");

    let rng = {
        let streams = Rc::clone(&streams);
        context
            .create_function(
                "rng",
                1,
                Box::new(move |call| {
                    let stream = call.arg(0).and_then(|v| v.as_number()).unwrap_or(0.0) as usize;
                    let mut state = streams.borrow_mut();
                    let slot = &mut state[stream % 8];
                    if *slot == 0 {
                        *slot = (12345 + stream as i64 * 7919) % 2147483647;
                    }
                    *slot = (*slot * 48271) % 2147483647;
                    Ok(JsValue::number(*slot as f64 / 2147483647.0))
                }),
            )
            .expect("the rng capability")
    };
    namespace.set("rng", rng).expect("set rng");

    let log = {
        let seen = Rc::clone(&seen);
        context
            .create_function(
                "log",
                2,
                Box::new(move |call| {
                    let ptr = call.arg(0).and_then(|v| v.as_number()).unwrap_or(0.0);
                    let len = call.arg(1).and_then(|v| v.as_number()).unwrap_or(0.0);
                    seen.borrow_mut().push((ptr, len));
                    Ok(JsValue::undefined())
                }),
            )
            .expect("the log capability")
    };
    namespace.set("log", log).expect("set log");

    let publish = {
        let published = Rc::clone(&published);
        context
            .create_function(
                "publish",
                2,
                Box::new(move |call| {
                    let ptr = call.arg(0).and_then(|v| v.as_number()).unwrap_or(0.0);
                    let len = call.arg(1).and_then(|v| v.as_number()).unwrap_or(0.0);
                    published.borrow_mut().push((ptr, len));
                    Ok(JsValue::number(0.0))
                }),
            )
            .expect("the publish capability")
    };
    namespace.set("publish", publish).expect("set publish");

    context
        .set_global("GOATS_IMPORTS", namespace.as_value())
        .expect("set GOATS_IMPORTS");

    let value = context
        .eval(NATIVE_HOST_STUB)
        .unwrap_or_else(|error| panic!("the native-hosted driver failed: {error}"));
    let text = context
        .to_string(&value)
        .expect("the driver returned a string");
    let native: serde_json::Value = serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("the driver returned invalid JSON: {error}\n{text}"));

    // The module cannot tell a Rust capability from a JavaScript one.
    assert_eq!(native["abi"], ABI_VERSION, "{native}");
    assert_eq!(
        native["imports"], reference["imports"],
        "the same capability set"
    );
    assert_eq!(
        native["vx"], reference["vx"],
        "a natively-implemented capability changed the plugin's behaviour"
    );

    // The rule: the native capability saw the message's address and length, not
    // its bytes. "plugin-c: ready" is the string the fixture logs at init.
    let seen = seen.borrow();
    assert_eq!(seen.len(), 1, "the fixture logs once at init");
    let (ptr, len) = seen[0];
    assert!(ptr > 0.0, "the pointer is into the module's memory: {ptr}");
    assert_eq!(
        len,
        "plugin-c: ready".len() as f64,
        "the native capability saw the message's length"
    );

    // The same rule for `publish`: the native capability saw the state's address
    // and length, never the bytes -- 4 records of 16 bytes.
    let published = published.borrow();
    assert_eq!(published.len(), 1, "the fixture publishes once per update");
    let (ptr, len) = published[0];
    assert!(
        ptr > 0.0,
        "the publish pointer is into the module's memory: {ptr}"
    );
    assert_eq!(
        len,
        4.0 * 16.0,
        "the native publish capability saw the state's byte length"
    );

    // The export behaves the same whichever host supplied the capabilities.
    assert_eq!(
        native["applied"], reference["applied"],
        "goats_apply is host-language-agnostic too"
    );
}

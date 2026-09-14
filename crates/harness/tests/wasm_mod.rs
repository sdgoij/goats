//! The compiled mod, through the scene's own driver: a mod that ships a `.wasm`
//! module and no JavaScript at all (M17a, `ABIv1.md`).
//!
//! What the loader half owns -- the manifest's `wasm` block, the module's bytes,
//! the refusal of a world-side module and of a file that is not a module -- is
//! `crates/mods`' own test, which runs the real loader over `mods/wasm/`. What is
//! left here is the scene half, driven by the real `mods/wasm/plugin.wasm`:
//! the host delivers bytes, the driver instantiates with the capabilities it
//! grants, the ABI version is negotiated, one coarse call a frame is made, and
//! the host reads the results back out of the module's memory.
//!
//! The module is compiled in (`include_bytes!`), like the `mods/example` fixture
//! beside it: a rebuilt or broken artifact then fails this test rather than
//! drifting from it.

use harness::Harness;
use serde_json::json;

mod support;

use support::command_json;

const ID: &str = "com.github.sdgoij.goats.wasm";

/// The shipped module: the same artifact the game and the release package carry.
const MODULE: &[u8] = include_bytes!("../../../mods/wasm/plugin.wasm");

/// The same source built against an ABI this build does not know, so the version
/// refusal has something real to refuse.
const MODULE_ABI2: &[u8] = include_bytes!("../../../fixtures/wasm/mod-abi2.wasm");

/// Enough frames for the scene to load and settle before the mod is delivered.
const SHORT: u32 = 60;

/// The records the module is working on, read back out of its memory by the host.
/// `(x, z, vx)` per record: what the values *mean* is the module's business, and
/// this is the host looking at the bytes it handed over.
const RECORDS: &str = r#"(function () {
    const live = modWasmLive.get("com.github.sdgoij.goats.wasm");
    if (live === undefined) return null;
    const view = new Float32Array(live.instance.exports.memory.buffer);
    const base = live.ptr / 4;
    const out = [];
    for (let i = 0; i < 6; i++) {
        out.push([view[base + i * 4 + 0], view[base + i * 4 + 1], view[base + i * 4 + 3]]);
    }
    return JSON.stringify(out);
})()"#;

/// A scene with the compiled mod's metadata installed, before delivery.
fn staged() -> Harness {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(SHORT).expect("run the scene");
    let table = json!([{
        "id": ID,
        "name": "Compiled Mod",
        "version": "1.0.0",
        "api": 1,
        "side": "client",
        "description": "A mod with no JavaScript.",
        "enabled": true,
        "wasm": "plugin.wasm",
    }]);
    harness
        .call("sceneMods", &[json!(table.to_string())])
        .expect("install the table");
    harness
}

/// The plugin's own report, through the console verb the docs point at.
fn plugin(harness: &mut Harness) -> serde_json::Value {
    let info = command_json(harness, &format!("mod info {ID}"));
    info["wasm"].clone()
}

/// The records as the host reads them out of the module's memory.
fn records(harness: &mut Harness) -> Vec<Vec<f64>> {
    let value = harness.eval(RECORDS).expect("read the module's memory");
    let text = value.as_str().expect("a JSON string");
    let rows: Vec<Vec<f64>> = serde_json::from_str(text).expect("rows of f64");
    rows
}

#[test]
fn the_host_instantiates_drives_and_reads_a_compiled_mod() {
    let mut harness = staged();

    // The host hands the module over as bytes; the driver reports what it made of
    // it, and the mod is listed as loaded like any other.
    let reply = harness.wasm_module(ID, MODULE).expect("deliver the module");
    assert_eq!(reply, "ok");

    let info = command_json(&mut harness, &format!("mod info {ID}"));
    assert_eq!(info["loaded"], true, "{info}");
    assert_eq!(info["failed"], false, "{info}");

    // The capability list, read off the module rather than assumed -- and the
    // string the host read out of the module's own memory when `goats_init` ran
    // through the `goats.log` capability.
    let live = plugin(&mut harness);
    assert_eq!(live["abi"], 1, "{live}");
    assert_eq!(live["imports"], json!(["goats.log", "goats.rng"]), "{live}");
    assert_eq!(live["log"], "wasm mod: ready", "{live}");
    assert_eq!(live["frames"], 0, "{live}");

    // One call a frame, for as many frames as the scene ticks.
    harness
        .call("harnessStep", &[json!(120), json!(1.0 / 60.0)])
        .expect("step");
    let live = plugin(&mut harness);
    assert_eq!(live["frames"], 120, "{live}");
    assert_eq!(live["ok"], true, "{live}");

    // And the host can see what the module computed, by reading its memory: the
    // records have moved, which is the whole point of the coarse crossing.
    let moved = records(&mut harness);
    assert_eq!(moved.len(), 6);
    assert!(
        moved.iter().any(|row| row[0] != 0.0),
        "the module should have moved its records: {moved:?}"
    );
    assert!(
        moved.iter().any(|row| row[2] != 0.0),
        "and nudged their velocities: {moved:?}"
    );
}

#[test]
fn the_same_module_replays_the_same_records() {
    // The host owns the randomness, so two runs of the same module agree -- which
    // is the property a world mod would need, and the reason there is no clock in
    // the ABI to read.
    let mut first = staged();
    first.wasm_module(ID, MODULE).expect("deliver");
    first
        .call("harnessStep", &[json!(90), json!(1.0 / 60.0)])
        .expect("step");
    let a = records(&mut first);

    let mut second = staged();
    second.wasm_module(ID, MODULE).expect("deliver");
    second
        .call("harnessStep", &[json!(90), json!(1.0 / 60.0)])
        .expect("step");
    let b = records(&mut second);

    assert_eq!(a, b, "the same module must replay the same numbers");
    assert!(a.iter().any(|row| row[0] != 0.0), "and have done work");
}

#[test]
fn a_module_built_for_another_abi_is_refused_by_name() {
    // The module's own number, not the manifest's: it is what the code in front
    // of the host was compiled against.
    let mut harness = staged();
    let reply = harness.wasm_module(ID, MODULE_ABI2).expect("deliver");
    // The reply is the category; the detail -- which ABIs -- is what the driver
    // reported through `sceneModResult`, and it is what `mod info` shows.
    assert_eq!(reply, "error unsupported abi", "{reply}");

    let info = command_json(&mut harness, &format!("mod info {ID}"));
    assert_eq!(info["failed"], true, "{info}");
    assert!(
        info["error"].as_str().unwrap_or("").contains("ABI 2"),
        "{info}"
    );

    // Nothing was left running: no module is driven and no frames are counted.
    assert_eq!(harness.eval(RECORDS).expect("read"), json!(null));
}

#[test]
fn something_that_is_not_a_module_is_refused_by_name() {
    let mut harness = staged();
    let reply = harness
        .wasm_module(ID, b"not a module at all")
        .expect("deliver");
    assert_eq!(reply, "error invalid module", "{reply}");

    let info = command_json(&mut harness, &format!("mod info {ID}"));
    assert_eq!(info["failed"], true, "{info}");
    assert!(
        info["error"]
            .as_str()
            .unwrap_or("")
            .contains("invalid module"),
        "{info}"
    );
}

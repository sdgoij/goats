//! The compiled mod, through the scene's own driver: a mod that ships a `.wasm`
//! module and no JavaScript at all (M17a, `ABIv1.md`).
//!
//! What the loader half owns -- the manifest's `wasm` block, the module's bytes,
//! and that a file that is not a module is refused -- is `crates/mods`' own test,
//! which runs the real loader over `mods/wasm/`. What is left here is the scene
//! half, driven by the real `mods/wasm/plugin.wasm`: the host delivers bytes, the
//! driver instantiates with the capabilities it grants, the ABI version is
//! negotiated, one coarse call a frame is made, and the host reads the results
//! back out of the module's memory. A `side: "world"` module runs only where the
//! world is authoritative and re-derives its streams from the session seed.
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

/// A second, world-side id, for the compatibility-set cases.
const WORLD_ID: &str = "com.example.worldwasm";

/// The records the module is working on, read back out of its memory by the host.
/// `(x, z, vx)` per record: what the values *mean* is the module's business, and
/// this is the host looking at the bytes it handed over.
fn records(harness: &mut Harness, id: &str) -> Vec<Vec<f64>> {
    let probe = format!(
        r#"(function () {{
    const live = modWasmLive.get("{id}");
    if (live === undefined) return null;
    const view = new Float32Array(live.instance.exports.memory.buffer);
    const base = live.ptr / 4;
    const out = [];
    for (let i = 0; i < 6; i++) {{
        out.push([view[base + i * 4 + 0], view[base + i * 4 + 1], view[base + i * 4 + 3]]);
    }}
    return JSON.stringify(out);
}})()"#
    );
    let value = harness.eval(&probe).expect("read the module's memory");
    let text = value.as_str().expect("a JSON string");
    serde_json::from_str(text).expect("rows of f64")
}

/// The published state of a world compiled mod, as the host ships it: the
/// base64 the mod pushed through `goats.publish` and `sceneWorldMods` folded
/// into the datagram.
fn published(harness: &mut Harness) -> String {
    harness
        .eval(&format!("sceneWorldMods().data['{WORLD_ID}']"))
        .expect("read the published state")
        .as_str()
        .expect("a base64 string")
        .to_string()
}

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
    assert_eq!(
        live["imports"],
        json!(["goats.log", "goats.rng", "goats.publish"]),
        "{live}"
    );
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
    let moved = records(&mut harness, ID);
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
    let a = records(&mut first, ID);

    let mut second = staged();
    second.wasm_module(ID, MODULE).expect("deliver");
    second
        .call("harnessStep", &[json!(90), json!(1.0 / 60.0)])
        .expect("step");
    let b = records(&mut second, ID);

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

    // Nothing was left running: no module was kept, so no frames will be counted.
    assert_eq!(
        harness
            .eval(&format!("modWasmLive.has('{ID}')"))
            .expect("read"),
        json!(false)
    );
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

/// A scene with a `side: "world"` compiled mod delivered, seeded with `seed`.
fn staged_world(seed: i64) -> Harness {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(SHORT).expect("run the scene");
    let table = json!([{
        "id": WORLD_ID,
        "name": "World Compiled",
        "version": "1.0.0",
        "api": 1,
        "side": "world",
        "enabled": true,
        "wasm": "plugin.wasm",
    }]);
    harness
        .call("sceneMods", &[json!(table.to_string())])
        .expect("install the table");
    harness
        .wasm_module(WORLD_ID, MODULE)
        .expect("deliver the module");
    // The same module serves either side: what makes it a world mod is the
    // manifest, and this is where its streams re-derive from the session seed.
    harness
        .call("sceneUseSeed", &[json!(seed)])
        .expect("set the session seed");
    harness
}

#[test]
fn a_world_compiled_mod_is_driven_and_seed_dependent() {
    // A solo host is authoritative, so a world mod runs -- and its randomness
    // comes from the session seed, so the same seed replays the same records and
    // a different seed does not. That is the rule that makes two hosts of the
    // same world agree, and the reason there is no clock in the ABI.
    let mut first = staged_world(1001);
    first
        .call("harnessStep", &[json!(80), json!(1.0 / 60.0)])
        .expect("step");
    let info = command_json(&mut first, &format!("mod info {WORLD_ID}"));
    assert_eq!(info["wasm"]["frames"], 80, "{info}");

    let mut same = staged_world(1001);
    same.call("harnessStep", &[json!(80), json!(1.0 / 60.0)])
        .expect("step");
    assert_eq!(
        records(&mut first, WORLD_ID),
        records(&mut same, WORLD_ID),
        "the same seed must replay the same world"
    );

    let mut other = staged_world(1002);
    other
        .call("harnessStep", &[json!(80), json!(1.0 / 60.0)])
        .expect("step");
    assert_ne!(
        records(&mut first, WORLD_ID),
        records(&mut other, WORLD_ID),
        "a different seed must play a different world"
    );
}

#[test]
fn a_mirroring_client_does_not_drive_a_world_compiled_mod() {
    // A joining client mirrors; it does not simulate. The same module, delivered
    // on a client, is instantiated but its frame count stops where it was.
    let mut harness = staged_world(1001);
    harness
        .call("harnessStep", &[json!(10), json!(1.0 / 60.0)])
        .expect("step");
    let info = command_json(&mut harness, &format!("mod info {WORLD_ID}"));
    assert_eq!(info["wasm"]["frames"], 10, "{info}");

    harness
        .eval("netMode = 'client'; 0")
        .expect("flip to client");
    harness
        .call("harnessStep", &[json!(10), json!(1.0 / 60.0)])
        .expect("step");
    let info = command_json(&mut harness, &format!("mod info {WORLD_ID}"));
    assert_eq!(
        info["wasm"]["frames"], 10,
        "a mirroring client must not simulate: {info}"
    );
}

#[test]
fn a_world_compiled_mod_publishes_and_replays() {
    // A world mod's state is the bytes it pushes through `publish`, folded into
    // the host's mods datagram. The bytes are opaque; the host only moves them.
    // Because the module draws from `goats.rng` (seeded) and never a clock, the
    // same seed replays the same published bytes and a different seed does not.
    let mut first = staged_world(1001);
    first
        .call("harnessStep", &[json!(80), json!(1.0 / 60.0)])
        .expect("step");
    let a = published(&mut first);
    assert!(!a.is_empty(), "a world mod must publish");

    let mut same = staged_world(1001);
    same.call("harnessStep", &[json!(80), json!(1.0 / 60.0)])
        .expect("step");
    assert_eq!(a, published(&mut same), "same seed -> same bytes");

    let mut other = staged_world(1002);
    other
        .call("harnessStep", &[json!(80), json!(1.0 / 60.0)])
        .expect("step");
    assert_ne!(
        a,
        published(&mut other),
        "different seed -> different bytes"
    );
}

#[test]
fn a_mirroring_client_applies_a_peers_published_state() {
    // The other half of the crossing: the host's published bytes reach a peer,
    // and the peer's module adopts them through `goats_apply`. A mirroring
    // client never runs `goats_update`, so this is the whole of how its state
    // moves.
    let mut host = staged_world(1001);
    host.call("harnessStep", &[json!(80), json!(1.0 / 60.0)])
        .expect("step");
    let encoded = published(&mut host);

    let mut client = staged_world(1001);
    client
        .eval("netMode = 'client'; 0")
        .expect("flip to client");
    let before = records(&mut client, WORLD_ID);
    client
        .call(
            "sceneApplyWorldMods",
            &[json!({ "data": { WORLD_ID: encoded } })],
        )
        .expect("apply");

    assert_eq!(
        records(&mut client, WORLD_ID),
        records(&mut host, WORLD_ID),
        "the client mirrors the host's published state"
    );
    assert_ne!(
        before,
        records(&mut client, WORLD_ID),
        "applying moved the records"
    );

    // The export was really called, once: the host did not just write memory.
    let applies = client
        .eval(&format!(
            "modWasmLive.get('{WORLD_ID}').instance.exports.goats_applies()"
        ))
        .expect("read the apply counter");
    assert_eq!(applies, json!(1), "goats_apply ran once");
}
